import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import type { Address, Hex } from "viem";
import { Agent } from "./agent.js";
import { helpText, parseChat } from "./chat.js";

const need = (k: string) => {
  const v = process.env[k];
  if (!v) throw new Error(`missing env ${k}`);
  return v;
};

const agent = new Agent({
  rpcUrl: process.env.RPC_URL ?? "https://mainnet.hsk.xyz",
  vault: need("VAULT") as Address,
  oracle: need("ORACLE") as Address,
  pool: (process.env.POOL ?? "0x4ff515761864e7838B0AdB8b5b2B8B7A068905dC") as Address,
  usdt: (process.env.USDT ?? "0xF1B50eD67A9e2CC94Ad3c477779E2d4cBfFf9029") as Address,
  whsk: (process.env.WHSK ?? "0xB210D2120d57b758EE163cFfb43e73728c471Cf1") as Address,
  agentKey: process.env.AGENT_KEY as Hex | undefined,
  intervalMs: Number(process.env.INTERVAL_MS ?? 15_000),
});

const maxSizeBps = Number(process.env.MAX_TRADE_BPS ?? 2500);
const html = readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), "../public/index.html"));
const json = (_k: string, v: unknown) => (typeof v === "bigint" ? v.toString() : v);

async function reply(text: string) {
  const intent = parseChat(text, { maxSizeBps });
  switch (intent.type) {
    case "status": return { reply: "Here is the current position.", status: await agent.status() };
    case "why": return { reply: agent.log[0] ? `Last decision: ${agent.log[0].action}. ${agent.log[0].reason}.` : "No decisions yet." };
    case "pause": agent.cfg.paused = true; return { reply: "Paused. The agent will hold until you resume." };
    case "resume": agent.cfg.paused = false; return { reply: "Resumed." };
    case "unwind": return { reply: `Unwind: ${await agent.unwind()}` };
    case "set": Object.assign(agent.cfg, intent.patch); return { reply: intent.note };
    case "rejected": return { reply: intent.note };
    default: return { reply: helpText };
  }
}

createServer(async (req, res) => {
  try {
    if (req.method === "GET" && req.url === "/") {
      res.writeHead(200, { "content-type": "text/html" }).end(html);
    } else if (req.method === "GET" && req.url === "/api/status") {
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ status: await agent.status(), log: agent.log.slice(0, 30) }, json));
    } else if (req.method === "POST" && req.url === "/api/chat") {
      let body = "";
      for await (const c of req) body += c;
      const { text } = JSON.parse(body);
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(await reply(String(text)), json));
    } else {
      res.writeHead(404).end();
    }
  } catch (e) {
    res.writeHead(500, { "content-type": "application/json" }).end(JSON.stringify({ error: String((e as Error).message) }));
  }
}).listen(Number(process.env.PORT ?? 3000), () => console.log("Backstop agent UI on port", process.env.PORT ?? 3000, agent.dryRun ? "(dry run)" : ""));

agent.start();
