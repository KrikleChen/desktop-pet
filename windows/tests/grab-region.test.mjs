import assert from "node:assert/strict";
import test from "node:test";
import {
  buildCharacterMask,
  classifyGrabRegion,
  detectGrabRegion,
} from "../src/shared/grab-region.mjs";

test("grab region classification matches macOS thresholds", () => {
  assert.equal(classifyGrabRegion(0.5, 0.8), "hair/head");
  assert.equal(classifyGrabRegion(0.5, 0.2), "leg");
  assert.equal(classifyGrabRegion(0.1, 0.5), "arm");
  assert.equal(classifyGrabRegion(0.5, 0.5), "collar/torso");
});

test("alpha mask ignores detached decoration and transparent pixels", () => {
  const alpha = new Uint8Array(100);
  for (let y = 2; y <= 8; y += 1) {
    for (let x = 3; x <= 6; x += 1) alpha[y * 10 + x] = 255;
  }
  alpha[9] = 255;
  const mask = buildCharacterMask({ width: 10, height: 10, alpha });
  assert.ok(mask);
  assert.equal(
    detectGrabRegion(mask, { x: 4.5, y: 3 }, { left: 0, top: 0, width: 10, height: 10 }),
    "hair/head",
  );
  assert.equal(
    detectGrabRegion(mask, { x: 9, y: 0 }, { left: 0, top: 0, width: 10, height: 10 }),
    undefined,
  );
});
