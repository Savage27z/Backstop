import { test } from "node:test";
import assert from "node:assert/strict";
import { decide } from "./strategy.js";
import { parseChat } from "./chat.js";

const cfg = { risk: "medium" as const, sizeBps: 1000, paused: false };

test("buys a dip when flat", () => {
  assert.equal(decide({ spotTick: 940, twapTick: 1000, holdingRisk: false, entryTick: null }, cfg).action, "buy");
});

test("holds when no dip", () => {
  assert.equal(decide({ spotTick: 990, twapTick: 1000, holdingRisk: false, entryTick: null }, cfg).action, "hold");
});

test("sells at stop loss and at take profit", () => {
  assert.equal(decide({ spotTick: 890, twapTick: 1000, holdingRisk: true, entryTick: 1000 }, cfg).action, "sell");
  assert.equal(decide({ spotTick: 1075, twapTick: 1000, holdingRisk: true, entryTick: 1000 }, cfg).action, "sell");
});

test("paused agent never trades", () => {
  assert.equal(decide({ spotTick: 900, twapTick: 1000, holdingRisk: false, entryTick: null }, { ...cfg, paused: true }).action, "hold");
});

test("chat cannot raise size above the vault cap", () => {
  assert.equal(parseChat("size 40%", { maxSizeBps: 2500 }).type, "rejected");
  assert.equal(parseChat("set position size to 10%", { maxSizeBps: 2500 }).type, "set");
  assert.equal(parseChat("risk low", { maxSizeBps: 2500 }).type, "set");
});
