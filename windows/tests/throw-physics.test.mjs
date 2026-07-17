import assert from "node:assert/strict";
import test from "node:test";
import { createThrowState, stepThrowPhysics } from "../src/shared/throw-physics.mjs";

test("throw speed is capped at the macOS maximum", () => {
  const state = createThrowState(
    { x: 100, y: 100, width: 240, height: 260 },
    { x: 6_000, y: 8_000 },
  );
  assert.ok(Math.abs(Math.hypot(state.velocityX, state.velocityY) - 4_200) < 1e-8);
});

test("adjacent displays form one traversable visible desktop", () => {
  const displays = [
    { x: 0, y: 0, width: 800, height: 600 },
    { x: 800, y: 0, width: 800, height: 600 },
  ];
  const result = stepThrowPhysics({
    x: 690,
    y: 100,
    width: 240,
    height: 260,
    velocityX: 1_000,
    velocityY: -80,
    elapsed: 0,
  }, displays, 1 / 60);
  assert.equal(result.impact, undefined);
  assert.ok(result.state.x > 690);
});

test("floor impacts use pre-collision speed and settle below 175 points per second", () => {
  const displays = [{ x: 0, y: 0, width: 800, height: 600 }];
  const result = stepThrowPhysics({
    x: 300,
    y: 339,
    width: 240,
    height: 260,
    velocityX: 20,
    velocityY: 100,
    elapsed: 0,
  }, displays, 1 / 60);
  assert.equal(result.impact.severity, "light");
  assert.ok(result.impact.normalSpeed > 100);
  assert.equal(result.shouldSettle, true);
});
