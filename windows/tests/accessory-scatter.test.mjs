import assert from "node:assert/strict";
import test from "node:test";
import { stepAccessoryPhysics } from "../src/shared/accessory-scatter.mjs";

const workArea = { x: 0, y: 0, width: 800, height: 600 };

test("scattered accessories use the macOS gravity and bounce coefficients", () => {
  const result = stepAccessoryPhysics({
    x: 760,
    y: 559,
    width: 40,
    height: 40,
    velocityX: 200,
    velocityY: 200,
    restitution: 0.5,
    landed: false,
    restingDuration: 0,
  }, workArea, 1 / 60);
  assert.equal(result.state.x, 760);
  assert.ok(result.state.velocityX < 0);
  assert.equal(result.state.y, 560);
  assert.equal(result.state.velocityY, -107);
  assert.equal(result.justLanded, true);
});

test("accessory becomes sleeping after a quarter second at rest", () => {
  let state = {
    x: 300,
    y: 560,
    width: 40,
    height: 40,
    velocityX: 0,
    velocityY: 0,
    restitution: 0.4,
    landed: true,
    restingDuration: 0,
  };
  let result;
  for (let index = 0; index < 16; index += 1) {
    result = stepAccessoryPhysics(state, workArea, 1 / 60);
    state = result.state;
  }
  assert.equal(result.sleeping, true);
});
