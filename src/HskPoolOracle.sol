// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUniswapV3PoolLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @notice Time-weighted price quotes from a Uniswap-V3-style pool (HSKSwap), no external deps.
///         price(token1 per token0, raw units) = 1.0001^tick, evaluated at 1e27 precision.
contract HskPoolOracle {
    uint256 internal constant S = 1e27;
    uint256 internal constant BASE_INV = 999900009999000099990000999; // 1/1.0001 at 1e27
    int256 internal constant MAX_ABS_TICK = 700_000;

    IUniswapV3PoolLike public immutable pool;
    address public immutable token0;
    address public immutable token1;
    uint32 public immutable twapSeconds;

    error UnknownToken();

    constructor(address pool_, uint32 twapSeconds_) {
        pool = IUniswapV3PoolLike(pool_);
        token0 = pool.token0();
        token1 = pool.token1();
        twapSeconds = twapSeconds_;
    }

    function twapTick() public view returns (int24) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = twapSeconds;
        ago[1] = 0;
        (int56[] memory cum,) = pool.observe(ago);
        int56 delta = cum[1] - cum[0];
        int56 secs = int56(uint56(twapSeconds));
        int56 tick = delta / secs;
        if (delta < 0 && (delta % secs != 0)) tick--;
        return int24(tick);
    }

    function expectedOut(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256) {
        bool zeroForOne = tokenIn == token0 && tokenOut == token1;
        if (!zeroForOne && !(tokenIn == token1 && tokenOut == token0)) revert UnknownToken();

        int256 tick = twapTick();
        uint256 n = uint256(tick < 0 ? -tick : tick);
        if (n > uint256(MAX_ABS_TICK)) n = uint256(MAX_ABS_TICK);
        uint256 decay = _pow(BASE_INV, n);

        bool priceBelowOne = tick <= 0;
        // price = decay/S when tick<=0, else S/decay
        bool multiply = zeroForOne == priceBelowOne;
        if (multiply) return priceBelowOne ? (amountIn * decay) / S : (amountIn * S) / decay;
        return priceBelowOne ? (amountIn * S) / decay : (amountIn * decay) / S;
    }

    function _pow(uint256 base, uint256 exp) internal pure returns (uint256 result) {
        result = S;
        while (exp > 0) {
            if (exp & 1 == 1) result = (result * base) / S;
            base = (base * base) / S;
            exp >>= 1;
        }
    }
}
