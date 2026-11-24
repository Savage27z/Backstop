// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/BackstopVault.sol";
import "../src/HskPoolOracle.sol";

contract BackstopVaultForkTest is Test {
    address constant POOL = 0x4ff515761864e7838B0AdB8b5b2B8B7A068905dC;
    address constant ROUTER = 0x2c16f75b95Cf1390c328aB70e2CEE7f4b80bD8F3;
    address constant WHSK = 0xB210D2120d57b758EE163cFfb43e73728c471Cf1;
    address constant USDT = 0xF1B50eD67A9e2CC94Ad3c477779E2d4cBfFf9029;

    function test_RealRouterRoundTrip() public {
        string memory rpc = vm.envOr("HSK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        HskPoolOracle oracle = new HskPoolOracle(POOL, 1800);
        address agent = address(0xA6E47);
        address backer = address(0xB0B);

        BackstopVault vault = new BackstopVault(
            BackstopVault.Params({
                asset: USDT,
                riskToken: WHSK,
                router: ROUTER,
                oracle: address(oracle),
                poolFee: 3000,
                agent: agent,
                bond: 10e6,
                seniorCapMultiple: 5,
                seniorProfitBps: 7000,
                maxTradeBps: 5000,
                maxSlippageBps: 300,
                cooldown: 0,
                stopBps: 8000,
                tradingDuration: 1 days
            })
        );

        deal(USDT, address(this), 10e6);
        IERC20(USDT).approve(address(vault), type(uint256).max);
        vault.postBond();

        deal(USDT, backer, 40e6);
        vm.startPrank(backer);
        IERC20(USDT).approve(address(vault), type(uint256).max);
        vault.deposit(40e6);
        vm.stopPrank();

        vault.startTrading();

        uint256 amountIn = 10e6;
        uint256 minOut = (oracle.expectedOut(USDT, WHSK, amountIn) * 97) / 100;
        vm.prank(agent);
        uint256 got = vault.buy(amountIn, minOut);
        emit log_named_uint("bought WHSK (18dp)", got);
        assertGt(got, 0);

        uint256 bal = IERC20(WHSK).balanceOf(address(vault));
        uint256 minBack = (oracle.expectedOut(WHSK, USDT, bal) * 97) / 100;
        vm.prank(agent);
        uint256 back = vault.unwind(minBack);
        emit log_named_uint("USDT back (6dp) from 10 USDT", back);
        assertGt(back, 9e6);

        vault.settle();
        assertEq(IERC20(WHSK).balanceOf(address(vault)), 0);
        emit log_named_uint("senior payout total", vault.seniorPayoutTotal());
        emit log_named_uint("operator payout", vault.operatorPayout());
    }
}
