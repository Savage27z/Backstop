import type { Risk, StrategyConfig } from "./strategy.js";

export interface ChatLimits {
  maxSizeBps: number;
}

export type ChatIntent =
  | { type: "status" }
  | { type: "why" }
  | { type: "pause" }
  | { type: "resume" }
  | { type: "unwind" }
  | { type: "set"; patch: Partial<StrategyConfig>; note: string }
  | { type: "rejected"; note: string }
  | { type: "help" };

export function parseChat(text: string, limits: ChatLimits): ChatIntent {
  const t = text.trim().toLowerCase();

  if (/^(status|position|positions|pnl|how.*(doing|going))/.test(t)) return { type: "status" };
  if (/^(why|explain|reason)/.test(t)) return { type: "why" };
  if (/^(pause|stop trading|halt)/.test(t)) return { type: "pause" };
  if (/^(resume|start trading|continue)/.test(t)) return { type: "resume" };
  if (/(unwind|close.*position|sell everything|exit)/.test(t)) return { type: "unwind" };

  const size = t.match(/(?:size|position)[^0-9]*([0-9]+(?:\.[0-9]+)?)\s*%/);
  if (size) {
    const bps = Math.round(parseFloat(size[1]) * 100);
    if (bps > limits.maxSizeBps) {
      return { type: "rejected", note: `The vault caps a single trade at ${limits.maxSizeBps / 100}% of capital, so I can't go to ${size[1]}%.` };
    }
    return { type: "set", patch: { sizeBps: bps }, note: `Trade size set to ${bps / 100}% of capital.` };
  }

  const risk = t.match(/\b(low|medium|high)\b[^.]*\brisk|risk[^.]*\b(low|medium|high)\b/);
  if (risk) {
    const level = (risk[1] ?? risk[2]) as Risk;
    return { type: "set", patch: { risk: level }, note: `Risk appetite set to ${level}. Lower risk waits for bigger dips and exits earlier.` };
  }

  return { type: "help" };
}

export const helpText =
  "I understand: status, why, pause, resume, unwind, 'size 10%', and 'risk low|medium|high'. " +
  "The trading pair, trade cap, slippage floor, cooldown and stop level are fixed by the vault contract, so chat can only tighten them.";
