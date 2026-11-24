import { createPublicClient, createWalletClient, http, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { erc20Abi, oracleAbi, poolAbi, vaultAbi } from "./abi.js";
import { decide, type Decision, type StrategyConfig } from "./strategy.js";

export interface AgentEnv {
  rpcUrl: string;
  vault: Address;
  oracle: Address;
  pool: Address;
  usdt: Address;
  whsk: Address;
  agentKey?: Hex;
  intervalMs: number;
}

export interface LogEntry {
  at: number;
  action: Decision["action"];
  reason: string;
  executed: boolean;
  detail?: string;
}

export class Agent {
  cfg: StrategyConfig = { risk: "medium", sizeBps: 1000, paused: false };
  log: LogEntry[] = [];
  entryTick: number | null = null;
  private client;
  private wallet;
  private timer?: NodeJS.Timeout;

  constructor(readonly env: AgentEnv) {
    this.client = createPublicClient({ transport: http(env.rpcUrl) });
    if (env.agentKey) {
      const account = privateKeyToAccount(env.agentKey);
      this.wallet = createWalletClient({ account, transport: http(env.rpcUrl) });
    }
  }

  get dryRun() {
    return !this.wallet;
  }

  start() {
    this.timer = setInterval(() => void this.step().catch((e) => this.push("hold", String(e.message ?? e), false)), this.env.intervalMs);
  }

  stop() {
    clearInterval(this.timer);
  }

  private push(action: Decision["action"], reason: string, executed: boolean, detail?: string) {
    this.log.unshift({ at: Date.now(), action, reason, executed, detail });
    this.log.length = Math.min(this.log.length, 200);
  }

  async status() {
    const { vault, oracle, pool, usdt, whsk } = this.env;
    const read = <T,>(address: Address, abi: any, functionName: string, args: any[] = []) =>
      this.client.readContract({ address, abi, functionName, args } as any) as Promise<T>;

    const [phase, stopped, bond, senior, mtm, floor, capital, spot, twap, usdtBal, whskBal] = await Promise.all([
      read<number>(vault, vaultAbi, "phase"),
      read<boolean>(vault, vaultAbi, "stopped"),
      read<bigint>(vault, vaultAbi, "bond"),
      read<bigint>(vault, vaultAbi, "seniorTotal"),
      read<bigint>(vault, vaultAbi, "markToMarket"),
      read<bigint>(vault, vaultAbi, "stopFloor"),
      read<bigint>(vault, vaultAbi, "capital"),
      read<readonly [bigint, number]>(pool, poolAbi, "slot0"),
      read<number>(oracle, oracleAbi, "twapTick"),
      read<bigint>(usdt, erc20Abi, "balanceOf", [vault]),
      read<bigint>(whsk, erc20Abi, "balanceOf", [vault]),
    ]);

    const pnl = mtm - capital;
    const bondLoss = pnl < 0n ? (-pnl > bond ? bond : -pnl) : 0n;
    const seniorLoss = pnl < 0n && -pnl > bond ? -pnl - bond : 0n;
    return {
      phase: ["Funding", "Trading", "Settled"][phase],
      stopped,
      bond,
      senior,
      capital,
      markToMarket: mtm,
      stopFloor: floor,
      pnl,
      bondRemaining: bond - bondLoss,
      seniorLoss,
      spotTick: spot[1],
      twapTick: twap,
      usdt: usdtBal,
      whsk: whskBal,
      holdingRisk: whskBal > 0n,
      dryRun: this.dryRun,
      config: this.cfg,
    };
  }

  async step(): Promise<LogEntry> {
    const s = await this.status();
    if (s.phase !== "Trading") {
      this.push("hold", `vault is in the ${s.phase} phase`, false);
      return this.log[0];
    }
    if (s.stopped) {
      this.push("hold", "circuit breaker is active; only unwinding is allowed", false);
      return this.log[0];
    }

    const d = decide({ spotTick: s.spotTick, twapTick: s.twapTick, holdingRisk: s.holdingRisk, entryTick: this.entryTick }, this.cfg);
    if (d.action === "hold") {
      this.push("hold", d.reason, false);
      return this.log[0];
    }

    const { vault, oracle, usdt, whsk } = this.env;
    const slippage = BigInt(await this.client.readContract({ address: vault, abi: vaultAbi, functionName: "maxSlippageBps" })) ;
    const tokenIn = d.action === "buy" ? usdt : whsk;
    const tokenOut = d.action === "buy" ? whsk : usdt;
    const amountIn = d.action === "buy" ? (s.capital * BigInt(this.cfg.sizeBps)) / 10_000n : s.whsk;
    const expected = await this.client.readContract({ address: oracle, abi: oracleAbi, functionName: "expectedOut", args: [tokenIn, tokenOut, amountIn] });
    const minOut = (expected * (10_000n - slippage + 10n)) / 10_000n;

    if (!this.wallet) {
      this.push(d.action, d.reason, false, `dry run: would ${d.action} ${amountIn} with minOut ${minOut}`);
      return this.log[0];
    }

    const hash = await this.wallet.writeContract({
      chain: null,
      address: vault,
      abi: vaultAbi,
      functionName: d.action,
      args: [amountIn, minOut],
    });
    await this.client.waitForTransactionReceipt({ hash });
    this.entryTick = d.action === "buy" ? s.spotTick : null;
    this.push(d.action, d.reason, true, hash);
    return this.log[0];
  }

  async unwind() {
    if (!this.wallet) throw new Error("dry run mode has no agent key");
    const { vault, oracle, usdt, whsk } = this.env;
    const bal = await this.client.readContract({ address: whsk, abi: erc20Abi, functionName: "balanceOf", args: [vault] });
    if (bal === 0n) return "nothing to unwind";
    const expected = await this.client.readContract({ address: oracle, abi: oracleAbi, functionName: "expectedOut", args: [whsk, usdt, bal] });
    const hash = await this.wallet.writeContract({ chain: null, address: vault, abi: vaultAbi, functionName: "unwind", args: [(expected * 9_700n) / 10_000n] });
    await this.client.waitForTransactionReceipt({ hash });
    this.entryTick = null;
    this.push("sell", "unwound on request", true, hash);
    return hash;
  }
}
