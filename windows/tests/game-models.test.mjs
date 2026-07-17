import assert from "node:assert/strict";
import test from "node:test";
import {
  ACCESSORY_KINDS,
  CompanionPolicy,
  CROSS_EXAMINATION_QUESTIONS,
  CrossExaminationRound,
  OrderedArchiveRound,
  ShakeDetector,
  ShuffleBag,
} from "../src/shared/game-models.mjs";

test("shuffle bag covers a round and avoids boundary repeats", () => {
  const random = seededRandom(42);
  const bag = new ShuffleBag(random);
  const candidates = ["a", "b", "c", "d"];
  const draws = Array.from({ length: 40 }, () => bag.next(candidates));
  for (let index = 0; index < draws.length; index += candidates.length) {
    assert.deepEqual(new Set(draws.slice(index, index + candidates.length)), new Set(candidates));
  }
  for (let index = 1; index < draws.length; index += 1) {
    assert.notEqual(draws[index], draws[index - 1]);
  }
});

test("ordered archive rewards all valid orders exactly once", () => {
  for (let seed = 1; seed <= 120; seed += 1) {
    const round = new OrderedArchiveRound();
    const snapshot = round.start(seed, ACCESSORY_KINDS, seededRandom(seed));
    assert.equal(new Set(snapshot.order).size, 6);
    for (const kind of snapshot.order) {
      const result = round.reclaim(seed, kind);
      assert.ok(["advanced", "completed"].includes(result.type));
    }
    assert.equal(round.finish(seed), "ordered");
    assert.equal(round.finish(seed), "ignored");
  }
});

test("ordered archive fails optional order without losing ordinary collection", () => {
  const round = new OrderedArchiveRound();
  const snapshot = round.start(10, ACCESSORY_KINDS, () => 0.999);
  const wrong = snapshot.order[1];
  assert.equal(round.reclaim(10, wrong).type, "failed");
  assert.equal(round.reclaim(10, wrong).type, "duplicate");
  assert.equal(round.reclaim(9, snapshot.order[0]).type, "ignored");
  assert.equal(round.finish(10), "standard");
});

test("cross examination bank and token isolation are valid", () => {
  assert.equal(CROSS_EXAMINATION_QUESTIONS.length, 8);
  assert.deepEqual(
    new Set(CROSS_EXAMINATION_QUESTIONS.map((question) => question.contradictionIndex)),
    new Set([0, 1, 2]),
  );
  for (const question of CROSS_EXAMINATION_QUESTIONS) {
    assert.equal(question.statements.length, 3);
    assert.ok(question.statements.every((line) => line.length <= 24));
    const round = new CrossExaminationRound();
    const first = round.start(question);
    round.move(first.token, question.contradictionIndex);
    assert.equal(round.object(first.token).type, "succeeded");
    assert.equal(round.object(first.token).type, "ignored");
    const second = round.start(question);
    assert.notEqual(second.token, first.token);
    assert.equal(round.move(first.token, 1).type, "ignored");
  }
});

test("wrong objection continues and navigation stays bounded", () => {
  const question = CROSS_EXAMINATION_QUESTIONS.find((value) => value.contradictionIndex !== 0);
  const round = new CrossExaminationRound();
  const snapshot = round.start(question);
  assert.equal(round.object(snapshot.token).type, "incorrect");
  assert.equal(round.move(snapshot.token, -1).type, "boundary");
  round.move(snapshot.token, 3);
  assert.equal(round.snapshot().index, 2);
  assert.equal(round.end(snapshot.token, "timed-out"), true);
  assert.equal(round.move(snapshot.token, -1).type, "ignored");
});

test("companion policy respects focused, quiet and expiry", () => {
  const now = 10_000;
  const policy = new CompanionPolicy({ level: "balanced" });
  assert.deepEqual(policy.ambientProfile(now), {
    enabled: true,
    initialMs: 75_000,
    minimumMs: 120_000,
    maximumMs: 240_000,
    probability: 0.65,
  });
  policy.setLevel("focused");
  assert.equal(policy.ambientProfile(now).enabled, false);
  policy.setLevel("lively");
  assert.equal(policy.ambientProfile(now).initialMs, 30_000);
  policy.quiet(30, now);
  assert.equal(policy.snapshot(now).effective, "quiet");
  assert.equal(policy.ambientProfile(now).enabled, false);
  assert.equal(policy.snapshot(now + 30 * 60_000 + 1).effective, "lively");
});

test("companion policy repairs an invalid quiet window to at most 30 minutes", () => {
  const now = 50_000;
  const policy = new CompanionPolicy({
    level: "balanced",
    quietStartedAt: now + 60_000,
    quietUntil: now + 90 * 60_000,
  });
  const snapshot = policy.snapshot(now);
  assert.equal(snapshot.quietStartedAt, now);
  assert.equal(snapshot.quietUntil, now + 30 * 60_000);
  assert.equal(snapshot.effective, "quiet");
});

test("shake detector triggers once after alternating travel", () => {
  const detector = new ShakeDetector();
  const samples = [0, 50, 0, 55, 0, 60, 0];
  const results = samples.map((sample) => detector.add(sample));
  assert.equal(results.filter(Boolean).length, 1);
  assert.equal(detector.add(90), false);
  detector.reset();
  assert.equal(detector.add(0), false);
});

function seededRandom(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state * 1664525 + 1013904223) >>> 0;
    return state / 0x1_0000_0000;
  };
}
