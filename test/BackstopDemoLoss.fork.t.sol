// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/BackstopVault.sol";
import "../src/HskPoolOracle.sol";

/// Scripted loss on a fork of HSK mainnet: a whale dumps WHSK into the real pool after the agent buys.
/// Run: HSK_RPC_URL=https://mainnet.hsk.xyz forge test --match-test test_DemoLoss -vv
contract BackstopDemoLossTest is Test {
    address constant POOL = 0x4ff515761864e7838B0AdB8b5b2B8B7A068905dC;
    address constant ROUTER = 0x2c16f75b95Cf1390c328aB70e2CEE7f4b80bD8F3;
    address constant WHSK = 0xB210D2120d57b758EE163cFfb43e73728c471Cf1;
    address constant USDT = 0xF1B50eD67A9e2CC94Ad3c477779E2d4cBfFf9029;

    function _usdt(uint256 v) internal pure returns (string memory) {
        return string.concat(vm.toString(v / 1e6), ".", vm.toString((v % 1e6) / 1e4));
    }

    function test_DemoLoss() public {
        string memory rpc = vm.envOr("HSK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        HskPoolOracle oracle = new HskPoolOracle(POOL, 1800);
        address agent = address(0xA6E47);
        address backer = address(0xB0B);
        address whale = address(0x4A1E);

        BackstopVault vault = new BackstopVault(
            BackstopVault.Params({
                asset: USDT, riskToken: WHSK, router: ROUTER, oracle: address(oracle), poolFee: 3000,
                agent: agent, bond: 20e6, seniorCapMultiple: 5, seniorProfitBps: 7000,
                maxTradeBps: 5000, maxSlippageBps: 300,
                exitSlippageBps: 2000, cooldown: 0, stopBps: 8000, tradingDuration: 1 days
            })
        );
        deal(USDT, address(this), 20e6);
        IERC20(USDT).approve(address(vault), type(uint256).max);
        vault.postBond();
        deal(USDT, backer, 80e6);
        vm.startPrank(backer);
        IERC20(USDT).approve(address(vault), type(uint256).max);
        vault.deposit(80e6);
        vm.stopPrank();
        vault.startTrading();

        console2.log("Bond 20 USDT (operator), senior 80 USDT (backers), capital 100 USDT");

        uint256 amountIn = 20e6;
        uint256 buyMinOut = (oracle.expectedOut(USDT, WHSK, amountIn) * 97) / 100;
        vm.prank(agent);
        vault.buy(amountIn, buyMinOut);
        console2.log("Agent bought WHSK with 20 USDT (the whole bond is the risk budget). Vault value:", _usdt(vault.markToMarket()));

        deal(WHSK, whale, 2_000_000e18);
        vm.startPrank(whale);
        IERC20(WHSK).approve(ROUTER, type(uint256).max);
        ISwapRouter(ROUTER).exactInputSingle(
            ISwapRouter.ExactInputSingleParams(WHSK, USDT, 3000, whale, 2_000_000e18, 0, 0)
        );
        vm.stopPrank();
        console2.log("Whale dumped 2,000,000 WHSK into the pool.");

        vm.warp(block.timestamp + 1900);
        vm.roll(block.number + 100);
        console2.log("Vault value after crash (30-min average price):", _usdt(vault.markToMarket()));
        console2.log("Stop level:", _usdt(vault.stopFloor()));

        if (vault.markToMarket() < vault.stopFloor()) {
            vault.triggerStop();
            console2.log("Circuit breaker tripped. Trading halted.");
        }

        uint256 left = IERC20(WHSK).balanceOf(address(vault));
        vault.unwind((oracle.expectedOut(WHSK, USDT, left) * 80) / 100);
        console2.log("Position unwound at the post-crash price.");
        vault.settle();

        console2.log("Loss taken by the operator bond:", _usdt(100e6 - vault.seniorPayoutTotal() - vault.operatorPayout()));
        console2.log("Settled. Vault paid out:", _usdt(vault.seniorPayoutTotal() + vault.operatorPayout()));
        console2.log("Senior backers receive (put in 80):", _usdt(vault.seniorPayoutTotal()));
        console2.log("Operator receives (put in 20):", _usdt(vault.operatorPayout()));
        assertEq(vault.seniorPayoutTotal(), 80e6);
    }
}
