// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/BackstopVault.sol";
import "../src/HskPoolOracle.sol";

/// HSK_RPC_URL=https://mainnet.hsk.xyz forge script script/Deploy.s.sol --rpc-url $HSK_RPC_URL --broadcast
/// Env: PRIVATE_KEY (operator), AGENT (agent address), BOND (USDT, 6 decimals)
contract Deploy is Script {
    address constant POOL = 0x4ff515761864e7838B0AdB8b5b2B8B7A068905dC;
    address constant ROUTER = 0x2c16f75b95Cf1390c328aB70e2CEE7f4b80bD8F3;
    address constant WHSK = 0xB210D2120d57b758EE163cFfb43e73728c471Cf1;
    address constant USDT = 0xF1B50eD67A9e2CC94Ad3c477779E2d4cBfFf9029;

    function run() external {
        uint256 bond = vm.envUint("BOND");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        HskPoolOracle oracle = new HskPoolOracle(POOL, 1800);
        BackstopVault vault = new BackstopVault(
            BackstopVault.Params({
                asset: USDT,
                riskToken: WHSK,
                router: ROUTER,
                oracle: address(oracle),
                poolFee: 3000,
                agent: vm.envAddress("AGENT"),
                bond: bond,
                seniorCapMultiple: 5,
                seniorProfitBps: 7000,
                maxTradeBps: 2500,
                maxSlippageBps: 100,
                exitSlippageBps: 2000,
                cooldown: 60,
                stopBps: 8000,
                tradingDuration: 1 days
            })
        );
        vm.stopBroadcast();
        console2.log("oracle", address(oracle));
        console2.log("vault", address(vault));
    }
}
