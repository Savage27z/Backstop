// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/BackstopVault.sol";

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }

    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract MockMarket {
    MockToken public usdt;
    MockToken public whsk;
    uint256 public priceUsdtPerWhsk;

    constructor(MockToken u, MockToken w) { usdt = u; whsk = w; priceUsdtPerWhsk = 1e6; }

    function setPrice(uint256 p) external { priceUsdtPerWhsk = p; }

    function expectedOut(address tin, address, uint256 amt) external view returns (uint256) {
        return tin == address(usdt) ? (amt * 1e18) / priceUsdtPerWhsk : (amt * priceUsdtPerWhsk) / 1e18;
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata p) external returns (uint256 out) {
        out = this.expectedOut(p.tokenIn, p.tokenOut, p.amountIn);
        require(out >= p.amountOutMinimum, "slippage");
        MockToken(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        MockToken(p.tokenOut).mint(p.recipient, out);
    }
}

contract BackstopVaultTest is Test {
    MockToken usdt;
    MockToken whsk;
    MockMarket market;
    BackstopVault vault;

    address operator;
    address agent = address(0xA6E47);
    address alice = address(0xA1);
    address bob = address(0xB0B);

    uint256 constant BOND = 100e6;

    function setUp() public {
        operator = address(this);
        usdt = new MockToken();
        whsk = new MockToken();
        market = new MockMarket(usdt, whsk);
        usdt.mint(operator, BOND);
        usdt.mint(alice, 300e6);
        usdt.mint(bob, 200e6);

        BackstopVault.Params memory p = BackstopVault.Params({
            asset: address(usdt),
            riskToken: address(whsk),
            router: address(market),
            oracle: address(market),
            poolFee: 3000,
            agent: agent,
            bond: BOND,
            seniorCapMultiple: 5,
            seniorProfitBps: 7000,
            maxTradeBps: 2500,
            maxSlippageBps: 100,
                exitSlippageBps: 2000,
            cooldown: 60,
            stopBps: 8000,
            tradingDuration: 1 days
        });
        vault = new BackstopVault(p);
        usdt.approve(address(vault), BOND);
        vault.postBond();

        vm.prank(alice);
        usdt.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdt.approve(address(vault), type(uint256).max);
    }

    function _fund() internal {
        vm.prank(alice);
        vault.deposit(300e6);
        vm.prank(bob);
        vault.deposit(200e6);
        vm.prank(operator);
        vault.startTrading();
    }

    function _buyAll(uint256 amountIn) internal {
        uint256 minOut = (market.expectedOut(address(usdt), address(whsk), amountIn) * 99) / 100;
        vm.prank(agent);
        vault.buy(amountIn, minOut);
    }

    function _unwindAndSettle() internal {
        uint256 bal = whsk.balanceOf(address(vault));
        if (bal > 0) {
            uint256 minOut = (market.expectedOut(address(whsk), address(usdt), bal) * 99) / 100;
            vm.prank(agent);
            vault.unwind(minOut);
        }
        vm.prank(operator);
        vault.settle();
    }

    function test_BondIsPostedByOperator() public view {
        assertEq(usdt.balanceOf(address(vault)), BOND);
        assertEq(vault.seniorCapacity(), 500e6);
    }

    function test_DepositCapEnforced() public {
        usdt.mint(alice, 1000e6);
        vm.startPrank(alice);
        vault.deposit(500e6);
        vm.expectRevert(BackstopVault.CapExceeded.selector);
        vault.deposit(1);
        vm.stopPrank();
    }

    function test_ProfitSharedByFixedSplit() public {
        _fund();
        _buyAll(100e6);
        market.setPrice(1.2e6);
        usdt.mint(address(market), 0);
        _unwindAndSettleWithLiquidity();

        uint256 finalBal = usdt.balanceOf(address(vault));
        uint256 profit = finalBal - 600e6;
        assertGt(profit, 0);
        assertEq(vault.seniorPayoutTotal(), 500e6 + (profit * 7000) / 10_000);
        assertEq(vault.operatorPayout(), finalBal - vault.seniorPayoutTotal());
    }

    function _unwindAndSettleWithLiquidity() internal {
        usdt.mint(address(market), 0);
        uint256 bal = whsk.balanceOf(address(vault));
        uint256 minOut = (market.expectedOut(address(whsk), address(usdt), bal) * 99) / 100;
        vm.prank(agent);
        vault.unwind(minOut);
        vm.prank(operator);
        vault.settle();
    }

    function test_BondAbsorbsLossBeforeSenior() public {
        _fund();
        _buyAll(100e6);
        market.setPrice(0.6e6);
        _unwindAndSettleWithLiquidity();

        uint256 finalBal = usdt.balanceOf(address(vault));
        assertLt(finalBal, 600e6);
        assertGe(finalBal, 500e6);
        assertEq(vault.seniorPayoutTotal(), 500e6);
        assertEq(vault.operatorPayout(), finalBal - 500e6);

        vm.prank(alice);
        uint256 a = vault.claimSenior();
        vm.prank(bob);
        uint256 b = vault.claimSenior();
        assertEq(a, 300e6);
        assertEq(b, 200e6);
    }

    function test_OnlyAgentCanTrade() public {
        _fund();
        vm.expectRevert(BackstopVault.NotAuthorized.selector);
        vault.buy(1e6, 0);
    }

    function test_TradeSizeCap() public {
        _fund();
        vm.prank(agent);
        vm.expectRevert(BackstopVault.TradeTooLarge.selector);
        vault.buy(151e6, 0);
    }

    function test_SeniorPrincipalIsSafeByConstruction() public {
        _fund();
        vm.prank(agent);
        vm.expectRevert(BackstopVault.ExposureTooHigh.selector);
        vault.buy(101e6, 0);

        _buyAll(100e6);
        market.setPrice(0.01e6);
        uint256 bal = whsk.balanceOf(address(vault));
        uint256 minOut = (market.expectedOut(address(whsk), address(usdt), bal) * 80) / 100;
        vm.prank(agent);
        vault.unwind(minOut);
        assertEq(bal > 0, true);
        vault.settle();
        assertEq(vault.seniorPayoutTotal(), 500e6);
    }

    function test_CooldownEnforced() public {
        _fund();
        vm.warp(1000);
        _buyAll(10e6);
        vm.prank(agent);
        vm.expectRevert(BackstopVault.CooldownActive.selector);
        vault.buy(1e6, 0);
        vm.warp(block.timestamp + 61);
        _buyAll(10e6);
    }

    function test_SlippageFloorEnforced() public {
        _fund();
        vm.prank(agent);
        vm.expectRevert(BackstopVault.SlippageTooLoose.selector);
        vault.buy(10e6, 0);
    }

    function test_StopTriggersAndHaltsTrading() public {
        _fund();
        _buyAll(100e6);
        vm.expectRevert(BackstopVault.StopNotReached.selector);
        vault.triggerStop();

        market.setPrice(0.1e6);
        vault.triggerStop();
        assertTrue(vault.stopped());

        vm.warp(block.timestamp + 61);
        vm.prank(agent);
        vm.expectRevert(BackstopVault.TradingHalted.selector);
        vault.buy(1e6, 0);
    }

    function test_AnyoneCanUnwindAfterStop() public {
        _fund();
        _buyAll(100e6);
        market.setPrice(0.1e6);
        vault.triggerStop();
        uint256 bal = whsk.balanceOf(address(vault));
        uint256 minOut = (market.expectedOut(address(whsk), address(usdt), bal) * 99) / 100;
        vm.prank(address(0xBEEF));
        vault.unwind(minOut);
        vault.settle();
        assertEq(uint256(vault.phase()), uint256(BackstopVault.Phase.Settled));
    }

    function test_CannotSettleWithOpenPosition() public {
        _fund();
        _buyAll(10e6);
        vm.prank(operator);
        vm.expectRevert(BackstopVault.PositionOpen.selector);
        vault.settle();
    }

    function test_DepositsClosedAfterTradingStarts() public {
        _fund();
        vm.prank(alice);
        vm.expectRevert(BackstopVault.WrongPhase.selector);
        vault.deposit(1);
    }

    function test_CannotClaimTwice() public {
        _fund();
        _unwindAndSettle();
        vm.startPrank(alice);
        vault.claimSenior();
        vm.expectRevert(BackstopVault.NothingToClaim.selector);
        vault.claimSenior();
        vm.stopPrank();
    }

    function testFuzz_ConservationOfFunds(uint256 priceBps) public {
        priceBps = bound(priceBps, 500, 30_000);
        _fund();
        _buyAll(100e6);
        market.setPrice((1e6 * priceBps) / 10_000);
        uint256 bal = whsk.balanceOf(address(vault));
        uint256 minOut = (market.expectedOut(address(whsk), address(usdt), bal) * 99) / 100;
        vm.prank(agent);
        vault.unwind(minOut);
        vm.prank(operator);
        vault.settle();
        assertEq(vault.seniorPayoutTotal() + vault.operatorPayout(), usdt.balanceOf(address(vault)));
        assertGe(vault.seniorPayoutTotal(), usdt.balanceOf(address(vault)) >= 500e6 ? 500e6 : usdt.balanceOf(address(vault)));
    }
}
