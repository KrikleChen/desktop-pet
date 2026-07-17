import assert from "node:assert/strict";
import test from "node:test";
import { EdgeIdleBehavior, nearEdge } from "../src/shared/edge-idle.mjs";

const workArea = { x: 0, y: 0, width: 1_920, height: 1_040 };

test("edge classification uses Windows top-left screen coordinates", () => {
  assert.equal(nearEdge({ x: 0, y: 300, width: 240, height: 260 }, workArea), "left");
  assert.equal(nearEdge({ x: 1_680, y: 300, width: 240, height: 260 }, workArea), "right");
  assert.equal(nearEdge({ x: 800, y: 780, width: 240, height: 260 }, workArea), "bottom");
  assert.equal(nearEdge({ x: 800, y: 300, width: 240, height: 260 }, workArea), undefined);
});

test("bottom wins exact corner ties like macOS", () => {
  assert.equal(nearEdge({ x: 0, y: 780, width: 240, height: 260 }, workArea), "bottom");
});

test("edge rest waits sixty seconds and respects the global cooldown", () => {
  const behavior = new EdgeIdleBehavior();
  const windowFrame = { x: 0, y: 300, width: 240, height: 260 };
  assert.equal(behavior.evaluate({
    windowFrame, workArea, idleDurationMs: 59_999, now: 59_999, eligibility: true,
  }), undefined);
  assert.equal(behavior.evaluate({
    windowFrame, workArea, idleDurationMs: 60_000, now: 60_000, eligibility: true,
  }), "left");
  assert.equal(behavior.evaluate({
    windowFrame: { ...windowFrame, x: 1_680 },
    workArea,
    idleDurationMs: 120_000,
    now: 120_000,
    eligibility: true,
  }), undefined);
  assert.equal(behavior.evaluate({
    windowFrame: { ...windowFrame, x: 1_680 },
    workArea,
    idleDurationMs: 240_000,
    now: 240_000,
    eligibility: true,
  }), "right");
});
