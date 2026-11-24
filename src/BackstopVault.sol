// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface ISwapRouter {
    /// SwapRouter02-style params (no deadline), as deployed by HSKSwap on chain 177.
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);
}

interface IPriceOracle {
    function expectedOut(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256);
}

/// @title BackstopVault
/// @notice One trading epoch. The operator posts a first-loss bond, backers fund a senior
///         tranche, an agent trades one pair through one router under hard limits, and
///         settlement pays losses out of the bond before touching senior principal.
contract BackstopVault {
    enum Phase { Funding, Trading, Settled }

    uint256 internal constant BPS = 10_000;

    IERC20 public immutable asset;
    IERC20 public immutable riskToken;
    ISwapRouter public immutable router;
    IPriceOracle public immutable oracle;
    uint24 public immutable poolFee;

    address public immutable operator;
    address public immutable agent;

    uint256 public immutable bond;
    uint256 public immutable seniorCapMultiple;
    uint256 public immutable seniorProfitBps;
    uint256 public immutable maxTradeBps;
    uint256 public immutable maxSlippageBps;
    uint256 public immutable exitSlippageBps;
    uint256 public immutable cooldown;
    uint256 public immutable stopBps;
    uint256 public immutable tradingDuration;

    Phase public phase;
    bool public stopped;
    bool public bondPosted;
    uint256 public seniorTotal;
    uint256 public endTime;
    uint256 public lastTradeAt;
    uint256 public seniorPayoutTotal;
    uint256 public operatorPayout;
    bool public operatorClaimed;

    mapping(address => uint256) public seniorDeposit;
    mapping(address => bool) public seniorClaimed;

    event BondPosted(uint256 amount);
    event Deposited(address indexed backer, uint256 amount);
    event TradingStarted(uint256 seniorTotal, uint256 bond, uint256 endTime);
    event Traded(bool buy, uint256 amountIn, uint256 amountOut);
    event Stopped(uint256 markToMarket, uint256 floor);
    event Settled(uint256 finalBalance, uint256 seniorPayout, uint256 operatorPayoutAmount);
    event Claimed(address indexed account, uint256 amount);

    error WrongPhase();
    error NotAuthorized();
    error CapExceeded();
    error TradeTooLarge();
    error ExposureTooHigh();
    error CooldownActive();
    error SlippageTooLoose();
    error TradingHalted();
    error StopNotReached();
    error PositionOpen();
    error NothingToClaim();
    error TransferFailed();

    struct Params {
        address asset;
        address riskToken;
        address router;
        address oracle;
        uint24 poolFee;
        address agent;
        uint256 bond;
        uint256 seniorCapMultiple;
        uint256 seniorProfitBps;
        uint256 maxTradeBps;
        uint256 maxSlippageBps;
        uint256 exitSlippageBps;
        uint256 cooldown;
        uint256 stopBps;
        uint256 tradingDuration;
    }

    constructor(Params memory p) {
        asset = IERC20(p.asset);
        riskToken = IERC20(p.riskToken);
        router = ISwapRouter(p.router);
        oracle = IPriceOracle(p.oracle);
        poolFee = p.poolFee;
        operator = msg.sender;
        agent = p.agent;
        bond = p.bond;
        seniorCapMultiple = p.seniorCapMultiple;
        seniorProfitBps = p.seniorProfitBps;
        maxTradeBps = p.maxTradeBps;
        maxSlippageBps = p.maxSlippageBps;
        exitSlippageBps = p.exitSlippageBps;
        cooldown = p.cooldown;
        stopBps = p.stopBps;
        tradingDuration = p.tradingDuration;
    }

    function postBond() external {
        if (msg.sender != operator) revert NotAuthorized();
        if (bondPosted) revert WrongPhase();
        bondPosted = true;
        _pull(msg.sender, bond);
        emit BondPosted(bond);
    }

    function capital() public view returns (uint256) {
        return seniorTotal + bond;
    }

    function seniorCapacity() public view returns (uint256) {
        return bond * seniorCapMultiple;
    }

    function markToMarket() public view returns (uint256) {
        uint256 risk = riskToken.balanceOf(address(this));
        uint256 value = asset.balanceOf(address(this));
        if (risk > 0) value += oracle.expectedOut(address(riskToken), address(asset), risk);
        return value;
    }

    function stopFloor() public view returns (uint256) {
        return capital() - (bond * stopBps) / BPS;
    }

    function deposit(uint256 amount) external {
        if (phase != Phase.Funding || !bondPosted) revert WrongPhase();
        if (seniorTotal + amount > seniorCapacity()) revert CapExceeded();
        seniorDeposit[msg.sender] += amount;
        seniorTotal += amount;
        _pull(msg.sender, amount);
        emit Deposited(msg.sender, amount);
    }

    function startTrading() external {
        if (msg.sender != operator) revert NotAuthorized();
        if (phase != Phase.Funding || !bondPosted) revert WrongPhase();
        phase = Phase.Trading;
        endTime = block.timestamp + tradingDuration;
        emit TradingStarted(seniorTotal, bond, endTime);
    }

    function buy(uint256 amountIn, uint256 minOut) external returns (uint256) {
        return _trade(true, amountIn, minOut);
    }

    function sell(uint256 amountIn, uint256 minOut) external returns (uint256) {
        return _trade(false, amountIn, minOut);
    }

    function _trade(bool isBuy, uint256 amountIn, uint256 minOut) internal returns (uint256 out) {
        if (msg.sender != agent) revert NotAuthorized();
        if (phase != Phase.Trading) revert WrongPhase();
        if (stopped || block.timestamp >= endTime) revert TradingHalted();
        if (lastTradeAt != 0 && block.timestamp < lastTradeAt + cooldown) revert CooldownActive();

        (IERC20 tokenIn, IERC20 tokenOut) = isBuy ? (asset, riskToken) : (riskToken, asset);
        if (isBuy) {
            if (amountIn > (capital() * maxTradeBps) / BPS) revert TradeTooLarge();
            if (asset.balanceOf(address(this)) < seniorTotal + amountIn) revert ExposureTooHigh();
        }
        _enforceSlippage(tokenIn, tokenOut, amountIn, minOut, maxSlippageBps);

        lastTradeAt = block.timestamp;
        out = _swap(tokenIn, tokenOut, amountIn, minOut);
        emit Traded(isBuy, amountIn, out);
    }

    function triggerStop() external {
        if (phase != Phase.Trading) revert WrongPhase();
        uint256 value = markToMarket();
        uint256 floor = stopFloor();
        if (value >= floor) revert StopNotReached();
        stopped = true;
        emit Stopped(value, floor);
    }

    function unwind(uint256 minOut) external returns (uint256 out) {
        if (phase != Phase.Trading) revert WrongPhase();
        bool privileged = msg.sender == agent || msg.sender == operator;
        if (!privileged && !stopped && block.timestamp < endTime) revert NotAuthorized();

        uint256 risk = riskToken.balanceOf(address(this));
        if (risk == 0) return 0;
        _enforceSlippage(riskToken, asset, risk, minOut, exitSlippageBps);
        out = _swap(riskToken, asset, risk, minOut);
        emit Traded(false, risk, out);
    }

    function settle() external {
        if (phase != Phase.Trading) revert WrongPhase();
        if (!stopped && block.timestamp < endTime && msg.sender != operator) revert NotAuthorized();
        if (riskToken.balanceOf(address(this)) != 0) revert PositionOpen();

        uint256 finalBalance = asset.balanceOf(address(this));
        uint256 senior = seniorTotal;
        uint256 seniorPayout;

        if (finalBalance >= senior + bond) {
            uint256 profit = finalBalance - senior - bond;
            seniorPayout = senior + (profit * seniorProfitBps) / BPS;
        } else if (finalBalance >= senior) {
            seniorPayout = senior;
        } else {
            seniorPayout = finalBalance;
        }

        seniorPayoutTotal = seniorPayout;
        operatorPayout = finalBalance - seniorPayout;
        phase = Phase.Settled;
        emit Settled(finalBalance, seniorPayout, operatorPayout);
    }

    function claimSenior() external returns (uint256 amount) {
        if (phase != Phase.Settled) revert WrongPhase();
        uint256 dep = seniorDeposit[msg.sender];
        if (dep == 0 || seniorClaimed[msg.sender]) revert NothingToClaim();
        seniorClaimed[msg.sender] = true;
        amount = (seniorPayoutTotal * dep) / seniorTotal;
        _push(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function claimOperator() external returns (uint256 amount) {
        if (phase != Phase.Settled) revert WrongPhase();
        if (msg.sender != operator) revert NotAuthorized();
        if (operatorClaimed) revert NothingToClaim();
        operatorClaimed = true;
        amount = operatorPayout;
        _push(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function _enforceSlippage(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn, uint256 minOut, uint256 slippageBps)
        internal
        view
    {
        uint256 expected = oracle.expectedOut(address(tokenIn), address(tokenOut), amountIn);
        if (minOut < (expected * (BPS - slippageBps)) / BPS) revert SlippageTooLoose();
    }

    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn, uint256 minOut) internal returns (uint256) {
        tokenIn.approve(address(router), amountIn);
        uint256 before = tokenOut.balanceOf(address(this));
        router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                fee: poolFee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        tokenIn.approve(address(router), 0);
        return tokenOut.balanceOf(address(this)) - before;
    }

    function _pull(address from, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(asset).call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, address(this), amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _push(address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(asset).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
