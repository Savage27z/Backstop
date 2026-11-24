import { parseAbi } from "viem";

export const vaultAbi = parseAbi([
  "function phase() view returns (uint8)",
  "function stopped() view returns (bool)",
  "function bond() view returns (uint256)",
  "function seniorTotal() view returns (uint256)",
  "function endTime() view returns (uint256)",
  "function maxTradeBps() view returns (uint256)",
  "function cooldown() view returns (uint256)",
  "function maxSlippageBps() view returns (uint256)",
  "function markToMarket() view returns (uint256)",
  "function stopFloor() view returns (uint256)",
  "function capital() view returns (uint256)",
  "function lastTradeAt() view returns (uint256)",
  "function buy(uint256 amountIn, uint256 minOut) returns (uint256)",
  "function sell(uint256 amountIn, uint256 minOut) returns (uint256)",
  "function unwind(uint256 minOut) returns (uint256)",
  "function triggerStop()",
]);

export const oracleAbi = parseAbi([
  "function twapTick() view returns (int24)",
  "function expectedOut(address tokenIn, address tokenOut, uint256 amountIn) view returns (uint256)",
]);

export const poolAbi = parseAbi([
  "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool)",
]);

export const erc20Abi = parseAbi(["function balanceOf(address) view returns (uint256)"]);
