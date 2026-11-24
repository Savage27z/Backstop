export type Risk = "low" | "medium" | "high";

export interface StrategyConfig {
  risk: Risk;
  sizeBps: number;
  paused: boolean;
}

export interface Snapshot {
  spotTick: number;
  twapTick: number;
  holdingRisk: boolean;
  entryTick: number | null;
}

export interface Decision {
  action: "buy" | "sell" | "hold";
  reason: string;
}

const entryDipTicks: Record<Risk, number> = { low: 120, medium: 60, high: 25 };
const takeProfitTicks: Record<Risk, number> = { low: 40, medium: 70, high: 120 };
const stopLossTicks: Record<Risk, number> = { low: 60, medium: 100, high: 160 };

// 1 tick is a 0.01% price move, so these thresholds read as basis points.
export function decide(s: Snapshot, cfg: StrategyConfig): Decision {
  if (cfg.paused) return { action: "hold", reason: "paused by user" };

  const dip = s.twapTick - s.spotTick;

  if (!s.holdingRisk) {
    if (dip >= entryDipTicks[cfg.risk]) {
      return {
        action: "buy",
        reason: `spot is ${dip} bps below the 30-minute average, which meets the ${cfg.risk}-risk entry of ${entryDipTicks[cfg.risk]} bps`,
      };
    }
    return { action: "hold", reason: `spot is ${dip} bps from the 30-minute average; waiting for ${entryDipTicks[cfg.risk]} bps` };
  }

  const entry = s.entryTick ?? s.twapTick;
  const gain = s.spotTick - entry;
  if (gain >= takeProfitTicks[cfg.risk]) {
    return { action: "sell", reason: `up ${gain} bps since entry, which meets the take-profit of ${takeProfitTicks[cfg.risk]} bps` };
  }
  if (-gain >= stopLossTicks[cfg.risk]) {
    return { action: "sell", reason: `down ${-gain} bps since entry, which hits the stop-loss of ${stopLossTicks[cfg.risk]} bps` };
  }
  return { action: "hold", reason: `holding; ${gain >= 0 ? "up" : "down"} ${Math.abs(gain)} bps since entry` };
}
