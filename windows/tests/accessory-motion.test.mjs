import assert from "node:assert/strict";
import test from "node:test";
import {
  ACCESSORY_MOTIONS,
  accessoryMotionPosition,
  accessoryPathPosition,
  easedProgress,
} from "../src/shared/accessory-motion.mjs";

test("six accessory motions retain the macOS durations", () => {
  assert.deepEqual(
    Object.fromEntries(Object.entries(ACCESSORY_MOTIONS).map(([kind, motion]) => [kind, motion.durationMs])),
    {
      "attorney-badge": 560,
      "case-file": 700,
      magatama: 620,
      evidence: 550,
      pen: 480,
      "sticky-note": 740,
    },
  );
});

test("six accessory trails retain the macOS styles and tail fractions", () => {
  assert.deepEqual(
    Object.fromEntries(Object.entries(ACCESSORY_MOTIONS).map(([kind, motion]) => [
      kind,
      [motion.trailStyle, motion.trailFraction],
    ])),
    {
      "attorney-badge": ["goldenArc", 0.30],
      "case-file": ["fileFlutter", 0.27],
      magatama: ["cyanSpirit", 0.38],
      evidence: ["redBlueEmphasis", 0.29],
      pen: ["penFineLine", 0.23],
      "sticky-note": ["paperPieces", 0.32],
    },
  );
});

test("every accessory curve starts and ends at its requested centers", () => {
  const start = { x: 100, y: 300 };
  const destination = { x: 700, y: 120 };
  for (const kind of Object.keys(ACCESSORY_MOTIONS)) {
    assert.deepEqual(accessoryMotionPosition(kind, start, destination, 0), start);
    assert.deepEqual(accessoryPathPosition(kind, start, destination, 0), start);
    const end = accessoryMotionPosition(kind, start, destination, 1);
    assert.ok(Math.abs(end.x - destination.x) < 1e-8);
    assert.ok(Math.abs(end.y - destination.y) < 1e-8);
  }
  assert.equal(easedProgress(0.5), 0.5);
});
