// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/HskPoolOracle.sol";

interface IPoolSlot0 {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

contract HskPoolOracleForkTest is Test {
    address constant POOL = 0x4ff515761864e7838B0AdB8b5b2B8B7A068905dC;
    address constant WHSK = 0xB210D2120d57b758EE163cFfb43e73728c471Cf1;
    address constant USDT = 0xF1B50eD67A9e2CC94Ad3c477779E2d4cBfFf9029;

    function test_QuoteMatchesSpotWithinTolerance() public {
        string memory rpc = vm.envOr("HSK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        HskPoolOracle o = new HskPoolOracle(POOL, 1800);
        (uint160 sqrtP,,,,,,) = IPoolSlot0(POOL).slot0();

        uint256 whskIn = 100e18;
        uint256 usdtOut = o.expectedOut(WHSK, USDT, whskIn);
        uint256 spotUsdt = (((whskIn * uint256(sqrtP)) >> 96) * uint256(sqrtP)) >> 96;

        emit log_named_uint("oracle 100 WHSK -> USDT (6dp)", usdtOut);
        emit log_named_uint("spot   100 WHSK -> USDT (6dp)", spotUsdt);
        assertApproxEqRel(usdtOut, spotUsdt, 0.05e18);

        uint256 back = o.expectedOut(USDT, WHSK, usdtOut);
        assertApproxEqRel(back, whskIn, 1e12);
    }
}
