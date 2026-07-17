export const ACCESSORY_KINDS = Object.freeze([
  "attorney-badge",
  "case-file",
  "magatama",
  "evidence",
  "pen",
  "sticky-note",
]);

export class ShuffleBag {
  constructor(random = Math.random) {
    this.random = random;
    this.remaining = [];
    this.last = undefined;
    this.signature = "";
  }

  next(candidates) {
    const unique = [...new Set(candidates)];
    if (unique.length === 0) return undefined;
    if (unique.length === 1) {
      this.remaining = [];
      this.last = unique[0];
      this.signature = String(unique[0]);
      return unique[0];
    }

    const signature = unique.map(String).sort().join("\u0000");
    if (signature !== this.signature || this.remaining.length === 0) {
      this.signature = signature;
      this.remaining = shuffle(unique, this.random);
      if (this.remaining.at(-1) === this.last) {
        const replacement = this.remaining.findIndex((value) => value !== this.last);
        [this.remaining[replacement], this.remaining[this.remaining.length - 1]] = [
          this.remaining[this.remaining.length - 1],
          this.remaining[replacement],
        ];
      }
    }

    const value = this.remaining.pop();
    this.last = value;
    return value;
  }
}

export class OrderedArchiveRound {
  constructor() {
    this.sessionId = undefined;
    this.order = [];
    this.observed = new Set();
    this.completedCount = 0;
    this.phase = "inactive";
    this.lastFirst = undefined;
  }

  start(sessionId, kinds = ACCESSORY_KINDS, random = Math.random) {
    const unique = [...new Set(kinds)];
    if (unique.length !== ACCESSORY_KINDS.length
        || ACCESSORY_KINDS.some((kind) => !unique.includes(kind))) {
      this.cancel();
      return undefined;
    }

    this.order = shuffle(unique, random);
    if (this.order[0] === this.lastFirst) {
      const replacement = 1 + Math.floor(random() * (this.order.length - 1));
      [this.order[0], this.order[replacement]] = [this.order[replacement], this.order[0]];
    }
    this.lastFirst = this.order[0];
    this.sessionId = sessionId;
    this.observed = new Set();
    this.completedCount = 0;
    this.phase = "active";
    return this.snapshot();
  }

  reclaim(sessionId, kind) {
    if (sessionId !== this.sessionId || this.phase === "inactive") return { type: "ignored" };
    if (this.observed.has(kind)) return { type: "duplicate", snapshot: this.snapshot() };
    if (this.phase !== "active") return { type: "ignored" };

    this.observed.add(kind);
    if (this.order[this.completedCount] !== kind) {
      this.phase = "failed";
      return { type: "failed", snapshot: this.snapshot() };
    }

    this.completedCount += 1;
    if (this.completedCount === this.order.length) {
      this.phase = "completed";
      return { type: "completed", snapshot: this.snapshot() };
    }
    return { type: "advanced", snapshot: this.snapshot() };
  }

  finish(sessionId) {
    if (sessionId !== this.sessionId || this.phase === "inactive") return "ignored";
    const result = this.phase === "completed" ? "ordered" : "standard";
    this.cancel();
    return result;
  }

  cancel(sessionId = this.sessionId) {
    if (this.sessionId !== undefined && sessionId !== this.sessionId) return false;
    this.sessionId = undefined;
    this.order = [];
    this.observed = new Set();
    this.completedCount = 0;
    this.phase = "inactive";
    return true;
  }

  snapshot() {
    return {
      sessionId: this.sessionId,
      order: [...this.order],
      completedCount: this.completedCount,
      phase: this.phase,
      next: this.phase === "active" ? this.order[this.completedCount] : undefined,
    };
  }
}

export const CROSS_EXAMINATION_QUESTIONS = Object.freeze([
  question("blackout-label", "停电后的标签", [
    "停电时仓库里没有任何光源。",
    "停电后我看清了红色标签。",
    "那次停电持续了十分钟。",
  ], 1, "一片黑暗时不可能看清标签颜色。"),
  question("borrowed-key", "借出的钥匙", [
    "钥匙始终没离开我的口袋。",
    "我把钥匙借给保安十分钟。",
    "保安随后把钥匙还给了我。",
  ], 0, "既然借给过保安，钥匙就离开过口袋。"),
  question("warehouse-door", "唯一的出口", [
    "仓库只有一扇可通行的门。",
    "我全程守在那扇门的外面。",
    "那个人从另一扇门逃走了。",
  ], 2, "既然只有一扇门，就不存在另一个出口。"),
  question("fresh-tea", "刚沏的茶", [
    "那杯茶刚刚沏好。",
    "我摸到杯壁时它冰凉刺手。",
    "旁边的水壶还在冒热气。",
  ], 1, "刚用热水沏好的茶杯不会冰凉。"),
  question("stopped-elevator", "停运的电梯", [
    "停电后电梯立刻停运。",
    "我停电后坐电梯去了五楼。",
    "维修记录确认没有备用电源。",
  ], 1, "没有备用电源时，停运电梯无法上楼。"),
  question("sealed-envelope", "封住的信封", [
    "信封到会议开始才被拆开。",
    "会议前封口和蜡印都完好。",
    "会议前我已经读过信里的内容。",
  ], 2, "封口完好时不可能提前读到信件内容。"),
  question("short-recording", "超出的录音", [
    "这段录音总长只有三十秒。",
    "开头十秒能听见钟声。",
    "第四十秒时出现了咳嗽声。",
  ], 2, "三十秒的录音不会有第四十秒。"),
  question("fast-clock", "照片里的钟", [
    "现场的钟比标准时间慢一小时。",
    "照片文件记录的标准时间是两点。",
    "同一张照片里的现场钟指向三点。",
  ], 0, "现场钟显示三点，它应该快一小时。"),
]);

export class CrossExaminationRound {
  constructor() {
    this.sequence = 0;
    this.state = undefined;
  }

  start(question) {
    validateQuestion(question);
    this.sequence += 1;
    this.state = { token: this.sequence, question, index: 0, phase: "active" };
    return this.snapshot();
  }

  move(token, delta) {
    if (!this.isActive(token)) return { type: "ignored" };
    const next = clamp(this.state.index + delta, 0, 2);
    const moved = next !== this.state.index;
    this.state.index = next;
    return { type: moved ? "moved" : "boundary", snapshot: this.snapshot() };
  }

  object(token) {
    if (!this.isActive(token)) return { type: "ignored" };
    if (this.state.index !== this.state.question.contradictionIndex) {
      return {
        type: "incorrect",
        hint: "这句暂时解释得通，再看看前后证言。",
        snapshot: this.snapshot(),
      };
    }
    this.state.phase = "succeeded";
    return { type: "succeeded", conclusion: this.state.question.conclusion };
  }

  end(token, phase = "cancelled") {
    if (!this.isActive(token)) return false;
    this.state.phase = phase;
    return true;
  }

  snapshot() {
    if (!this.state) return undefined;
    return {
      token: this.state.token,
      question: this.state.question,
      index: this.state.index,
      statement: this.state.question.statements[this.state.index],
      phase: this.state.phase,
    };
  }

  isActive(token) {
    return this.state?.token === token && this.state.phase === "active";
  }
}

export class CompanionPolicy {
  constructor({ level = "balanced", quietUntil = 0 } = {}) {
    this.level = ["focused", "balanced", "lively"].includes(level) ? level : "balanced";
    this.quietUntil = Number.isFinite(quietUntil) ? quietUntil : 0;
  }

  setLevel(level) {
    if (!["focused", "balanced", "lively"].includes(level)) return false;
    this.level = level;
    return true;
  }

  quiet(minutes = 30, now = Date.now()) {
    this.quietUntil = now + Math.max(1, minutes) * 60_000;
  }

  cancelQuiet() {
    this.quietUntil = 0;
  }

  snapshot(now = Date.now()) {
    if (this.quietUntil <= now) this.quietUntil = 0;
    const effective = this.quietUntil > now ? "quiet" : this.level;
    return { level: this.level, quietUntil: this.quietUntil, effective };
  }

  ambientProfile(now = Date.now()) {
    const { effective } = this.snapshot(now);
    switch (effective) {
      case "focused":
      case "quiet":
        return { enabled: false, minimumMs: 0, maximumMs: 0, probability: 0 };
      case "lively":
        return { enabled: true, minimumMs: 45_000, maximumMs: 100_000, probability: 0.9 };
      default:
        return { enabled: true, minimumMs: 120_000, maximumMs: 240_000, probability: 0.65 };
    }
  }
}

export class ShakeDetector {
  constructor() {
    this.reset();
  }

  reset() {
    this.lastX = undefined;
    this.lastSign = 0;
    this.reversals = 0;
    this.travel = 0;
    this.triggered = false;
  }

  add(x) {
    if (this.triggered) return false;
    if (this.lastX === undefined) {
      this.lastX = x;
      return false;
    }
    const delta = x - this.lastX;
    this.lastX = x;
    if (Math.abs(delta) < 5) return false;
    this.travel += Math.abs(delta);
    const sign = Math.sign(delta);
    if (this.lastSign !== 0 && sign !== this.lastSign) this.reversals += 1;
    this.lastSign = sign;
    if (this.reversals >= 4 && this.travel >= 180) {
      this.triggered = true;
      return true;
    }
    return false;
  }
}

function question(id, title, statements, contradictionIndex, conclusion) {
  const value = Object.freeze({ id, title, statements: Object.freeze(statements), contradictionIndex, conclusion });
  validateQuestion(value);
  return value;
}

function validateQuestion(value) {
  if (!value?.id || !value?.title || value?.statements?.length !== 3
      || !value.statements.every((line) => typeof line === "string" && line.length > 0 && line.length <= 24)
      || !Number.isInteger(value.contradictionIndex)
      || value.contradictionIndex < 0
      || value.contradictionIndex > 2
      || !value.conclusion) {
    throw new Error("交叉询问题目格式无效");
  }
}

function shuffle(values, random) {
  const result = [...values];
  for (let index = result.length - 1; index > 0; index -= 1) {
    const replacement = Math.floor(random() * (index + 1));
    [result[index], result[replacement]] = [result[replacement], result[index]];
  }
  return result;
}

function clamp(value, minimum, maximum) {
  return Math.max(minimum, Math.min(maximum, value));
}
