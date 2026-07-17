import {
  ACCESSORY_KINDS,
  CompanionPolicy,
  CROSS_EXAMINATION_QUESTIONS,
  CrossExaminationRound,
  OrderedArchiveRound,
  ShakeDetector,
  ShuffleBag,
} from "../shared/game-models.mjs";

const ACTIONS = Object.freeze({
  idle: action("idle", "", 0),
  think: action("think", "唏……真相只有一个。", 2_400, "pop", "action.think"),
  objection: action("objection", "异议！", 2_000, "shake", "action.objection"),
  slam: action("slam", "等一下！", 1_800, "impact", "action.slam"),
  sweat: action("sweat", "糟了……", 2_100, "shake", "action.sweat"),
  evidence: action("evidence", "证据就在这里。", 2_500, "pop", "action.evidence"),
  "badge-toss": action("badge-toss", "这是我的律师徽章！", 2_200, "pop", "easter.badge"),
  magatama: action("magatama", "你的心里……有锁。", 2_800, "pop", "easter.magatama"),
  stepladder: action("stepladder", "这明明是人字梯！", 2_800, "pop", "easter.stepladder"),
  thinker: action("thinker", "把“思考者”加入证物。", 2_600, "pop", "easter.thinker"),
  "decisive-evidence": action("decisive-evidence", "找到决定性的证据了！", 2_400, "pop", "easter.decisive"),
  flashlight: action("flashlight", "先把手电打开。", 3_200, "pop"),
  sleepy: action("sleepy", "就休息五分钟……", 3_000, "sleepy"),
  dropped: action("dropped", "下次先打声招呼！", 1_500, "impact"),
  thrown: action("thrown", "哇啊——！", 0, "thrown", "physics.thrown"),
  impact: action("impact", "痛！", 0, "impact"),
  dizzy: action("dizzy", "天地都在转……", 2_200, "shake"),
  "held-struggle": action("held-struggle", "放、放我下来！", 0, "shake"),
  "leg-struggle": action("leg-struggle", "为什么偏偏拽脚啊！", 0, "shake"),
});

const INTERACTIVE_ACTIONS = [
  "think", "objection", "slam", "sweat", "evidence",
  "badge-toss", "magatama", "stepladder", "thinker", "decisive-evidence",
];
const AMBIENT_ACTIONS = ["think", "sleepy", "badge-toss", "evidence"];
const ACCESSORY_LABELS = Object.freeze({
  "attorney-badge": "徽",
  "case-file": "卷",
  magatama: "玉",
  evidence: "证",
  pen: "笔",
  "sticky-note": "签",
});
const ACCESSORY_RESPONSES = Object.freeze({
  "attorney-badge": ["badge-toss", "律师徽章可不能弄丢……接住了！"],
  "case-file": ["evidence", "案件资料，一页也不能少。"],
  magatama: ["magatama", "勾玉也回来了。得好好收着。"],
  evidence: ["decisive-evidence", "这份证物很关键，归档。"],
  pen: ["think", "我的笔！刚才的思路还没记完。"],
  "sticky-note": ["evidence", "便签也要按顺序整理。"],
});

const COURT_CATALOG = Object.freeze([
  recordDefinition("action.think", "思考案情", "认真梳理过一次线索。"),
  recordDefinition("action.objection", "异议！", "让响亮的反驳划破了安静。"),
  recordDefinition("action.slam", "拍桌", "以律师的气势拍下桌面。"),
  recordDefinition("action.sweat", "紧张冒汗", "见过他措手不及的一面。"),
  recordDefinition("action.evidence", "查看证物", "请他仔细查看过证物。"),
  recordDefinition("easter.badge", "律师徽章", "律师身份轻快地登场。"),
  recordDefinition("easter.magatama", "勾玉与心灵枷锁", "察觉到话语背后的秘密。"),
  recordDefinition("easter.stepladder", "梯子还是人字梯", "认真争论了工具的准确叫法。"),
  recordDefinition("easter.thinker", "思考者", "特别的摆设进入了记录。"),
  recordDefinition("easter.decisive", "决定性证据", "举起了足以改变局面的证据。"),
  recordDefinition("physics.thrown", "空中的辩护人", "快速拖动后松手，经历一次甩飞。"),
  recordDefinition("physics.scatter", "散落的法庭记录", "六件随身道具散落在桌面。"),
  recordDefinition("challenge.full-archive", "完整证据链", "六件证物全部回收归档。"),
  recordDefinition("challenge.ordered-archive", "完美归档", "六件证物按指定顺序完整归档。"),
  recordDefinition("challenge.cross-examination", "交叉询问", "从三句证言中找出真正的矛盾。"),
]);

const dom = {
  root: document.querySelector("#pet-root"),
  stage: document.querySelector("#pet-stage"),
  image: document.querySelector("#pet-image"),
  dialogue: document.querySelector("#dialogue"),
  toast: document.querySelector("#unlock-toast"),
  objection: document.querySelector("#objection-burst"),
  ordered: document.querySelector("#ordered-hud"),
  cross: document.querySelector("#cross-controls"),
  previous: document.querySelector("#cross-previous"),
  next: document.querySelector("#cross-next"),
  object: document.querySelector("#cross-object"),
  crossClose: document.querySelector("#cross-close"),
  court: document.querySelector("#court-panel"),
  courtList: document.querySelector("#court-list"),
  courtClose: document.querySelector("#court-close"),
};

const assetURLs = new Map();
const interactiveBag = new ShuffleBag();
const ambientBag = new ShuffleBag();
const questionBag = new ShuffleBag();
const orderedRound = new OrderedArchiveRound();
const crossRound = new CrossExaminationRound();
const shakeDetector = new ShakeDetector();
const collection = new Set();
const courtProgress = loadJSON("court-progress", {});
const savedPolicy = loadJSON("companion-policy", {});
const companionPolicy = new CompanionPolicy(savedPolicy);

let currentAction = "idle";
let actionTimer;
let idleTimer;
let quietTimer;
let clickTimer;
let objectionHideTimer;
let objectionFinishTimer;
let pointerState;
let suppressClickUntil = 0;
let activeAccessorySession;
let pendingAccessoryReward;
let crossToken;
let crossTimeout;
let crossFeedbackTimer;
let crossSequenceTimers = [];
let currentToast;
let toastTimer;
const toastQueue = [];

await preloadAssets();
wireInteractions();
showIdle();
showTemporaryMessage("单击随机动作 · 双击异议 · 右键菜单", 4_000);
scheduleIdle();
scheduleQuietExpiry();
window.desktopPet.rendererReady();

async function preloadAssets() {
  const names = new Set(Object.values(ACTIONS).map((entry) => `${entry.asset}-cg.png`));
  await Promise.all([...names].map(async (name) => {
    assetURLs.set(name, await window.desktopPet.assetUrl(name));
  }));
}

function wireInteractions() {
  dom.stage.addEventListener("mousedown", beginPointerInteraction);
  document.addEventListener("mousemove", continuePointerInteraction);
  document.addEventListener("mouseup", endPointerInteraction);
  document.addEventListener("contextmenu", showContextMenu);

  dom.previous.addEventListener("click", () => navigateCross(-1));
  dom.next.addEventListener("click", () => navigateCross(1));
  dom.object.addEventListener("click", objectDuringCross);
  dom.crossClose.addEventListener("click", () => cancelCross(true));
  dom.courtClose.addEventListener("click", closeCourtRecord);

  window.desktopPet.onMenuCommand(handleMenuCommand);
  window.desktopPet.onMenuClosed(() => {
    presentDeferredFeedback();
    scheduleIdle();
  });
  window.desktopPet.onMotionEvent(handleMotionEvent);
  window.desktopPet.onAccessoryEvent(handleAccessoryEvent);
}

function beginPointerInteraction(event) {
  if (event.button !== 0) return;
  if (!dom.court.classList.contains("hidden")) return;
  cancelCross(false);
  markInteraction();
  pointerState = {
    startX: event.screenX,
    startY: event.screenY,
    samples: [{ x: event.screenX, y: event.screenY, time: performance.now() }],
    dragging: false,
  };
  shakeDetector.reset();
  event.preventDefault();
}

function continuePointerInteraction(event) {
  if (!pointerState) return;
  const distance = Math.hypot(event.screenX - pointerState.startX, event.screenY - pointerState.startY);
  if (!pointerState.dragging && distance > 4) {
    pointerState.dragging = true;
    dom.stage.classList.add("dragging");
    window.desktopPet.dragStart(pointerState.startX, pointerState.startY);
    performAction("held-struggle", { autoReset: false, record: false });
  }
  if (!pointerState.dragging) return;

  window.desktopPet.dragMove(event.screenX, event.screenY);
  const now = performance.now();
  pointerState.samples.push({ x: event.screenX, y: event.screenY, time: now });
  pointerState.samples = pointerState.samples.filter((sample) => now - sample.time <= 140);
  if (shakeDetector.add(event.screenX)) window.desktopPet.scatterAccessories();
}

function endPointerInteraction(event) {
  if (!pointerState || event.button !== 0) return;
  const state = pointerState;
  pointerState = undefined;
  dom.stage.classList.remove("dragging");

  if (state.dragging) {
    const now = performance.now();
    const first = state.samples.find((sample) => now - sample.time <= 110) ?? state.samples[0];
    const deltaSeconds = Math.max(0.016, (now - first.time) / 1_000);
    const velocity = {
      x: (event.screenX - first.x) / deltaSeconds,
      y: (event.screenY - first.y) / deltaSeconds,
    };
    window.desktopPet.dragEnd(velocity.x, velocity.y);
    if (Math.hypot(velocity.x, velocity.y) >= 650) {
      performAction("thrown", { autoReset: false });
    } else {
      performAction("dropped");
    }
    suppressClickUntil = performance.now() + 300;
    return;
  }

  if (performance.now() < suppressClickUntil) return;
  if (clickTimer) {
    clearTimeout(clickTimer);
    clickTimer = undefined;
    performAction("objection");
  } else {
    clickTimer = setTimeout(() => {
      clickTimer = undefined;
      performAction(interactiveBag.next(INTERACTIVE_ACTIONS));
    }, 260);
  }
}

function showContextMenu(event) {
  event.preventDefault();
  cancelCross(true);
  closeCourtRecord(false);
  markInteraction();
  const policy = companionPolicy.snapshot();
  window.desktopPet.showContextMenu({
    activity: policy.level,
    quietUntil: policy.quietUntil,
  });
}

function handleMenuCommand({ command, value }) {
  switch (command) {
    case "random":
      performAction(interactiveBag.next(INTERACTIVE_ACTIONS));
      break;
    case "help":
      showTemporaryMessage("单击随机 · 双击异议 · 拖动搬家", 3_500);
      break;
    case "action":
      if (ACTIONS[value]) performAction(value);
      break;
    case "cross-examination":
      startCrossExamination();
      break;
    case "activity":
      if (companionPolicy.setLevel(value)) {
        persistPolicy();
        showTemporaryMessage(
          value === "focused" ? "已切换为专注：不再自动演出。"
            : value === "lively" ? "已切换为活跃陪伴。" : "已切换为轻陪伴。",
          2_400,
        );
      }
      break;
    case "quiet-start":
      companionPolicy.quiet();
      persistPolicy();
      scheduleQuietExpiry();
      showTemporaryMessage("好，30 分钟内我会安静待着。", 2_800);
      break;
    case "quiet-cancel":
      companionPolicy.cancelQuiet();
      persistPolicy();
      scheduleQuietExpiry();
      showTemporaryMessage("安静模式已结束。", 2_200);
      break;
    case "court-record":
      showCourtRecord();
      break;
    default:
      break;
  }
  scheduleIdle();
}

function performAction(name, options = {}) {
  const definition = ACTIONS[name] ?? ACTIONS.idle;
  const {
    message = definition.phrase,
    autoReset = definition.duration > 0,
    record = true,
  } = options;

  clearTimeout(actionTimer);
  actionTimer = undefined;
  suspendToast();
  currentAction = name;
  dom.image.src = assetURLs.get(`${definition.asset}-cg.png`) ?? "";
  dom.image.className = "";
  void dom.image.offsetWidth;
  if (definition.animation) dom.image.classList.add(definition.animation);

  if (name === "objection") {
    showObjectionBurst();
    hideDialogue();
  } else if (message) {
    hideObjectionBurst();
    showDialogue(message, name === "decisive-evidence" ? "courtroom" : "");
  } else {
    hideObjectionBurst();
    hideDialogue();
  }

  if (record && definition.recordId) recordCourtEntry(definition.recordId);
  if (autoReset) actionTimer = setTimeout(showIdle, definition.duration);
}

function showIdle() {
  clearTimeout(actionTimer);
  actionTimer = undefined;
  if (crossToken) return;
  currentAction = "idle";
  dom.image.src = assetURLs.get("idle-cg.png") ?? "";
  dom.image.className = "";
  hideObjectionBurst();
  hideDialogue();
  presentDeferredFeedback();
  scheduleIdle();
}

function showObjectionBurst() {
  clearTimeout(objectionHideTimer);
  clearTimeout(objectionFinishTimer);
  dom.objection.className = "objection-burst";
  void dom.objection.offsetWidth;
  dom.objection.classList.add("active");
  objectionHideTimer = setTimeout(hideObjectionBurst, 1_300);
}

function hideObjectionBurst() {
  clearTimeout(objectionHideTimer);
  clearTimeout(objectionFinishTimer);
  objectionHideTimer = undefined;
  objectionFinishTimer = undefined;
  if (dom.objection.classList.contains("hidden")
      || dom.objection.classList.contains("exiting")) return;
  dom.objection.classList.remove("active");
  dom.objection.classList.add("exiting");
  objectionFinishTimer = setTimeout(() => {
    dom.objection.className = "objection-burst hidden";
    objectionFinishTimer = undefined;
  }, 160);
}

function showTemporaryMessage(message, duration) {
  markInteraction();
  clearTimeout(actionTimer);
  actionTimer = undefined;
  showDialogue(message);
  actionTimer = setTimeout(showIdle, duration);
}

function showDialogue(message, style = "") {
  dom.dialogue.textContent = message;
  dom.dialogue.className = `dialogue${style ? ` ${style}` : ""}`;
}

function hideDialogue() {
  dom.dialogue.className = "dialogue hidden";
  dom.dialogue.textContent = "";
}

function startCrossExamination() {
  markInteraction();
  window.desktopPet.cancelAccessories();
  cancelCross(false);
  closeCourtRecord(false);
  const question = questionBag.next(CROSS_EXAMINATION_QUESTIONS);
  const snapshot = crossRound.start(question);
  crossToken = snapshot.token;
  dom.cross.classList.remove("hidden");
  presentCrossStatement();
  crossTimeout = setTimeout(() => timeoutCross(snapshot.token), 15_000);
}

function presentCrossStatement() {
  const snapshot = crossRound.snapshot();
  if (!snapshot || snapshot.token !== crossToken || snapshot.phase !== "active") return;
  dom.previous.disabled = snapshot.index === 0;
  dom.next.disabled = snapshot.index === 2;
  dom.object.textContent = `异议 · ${snapshot.index + 1}/3`;
  performAction("think", {
    message: `证言 ${snapshot.index + 1}/3：${snapshot.statement}`,
    autoReset: false,
    record: false,
  });
}

function navigateCross(delta) {
  if (!crossToken) return;
  markInteraction();
  clearTimeout(crossFeedbackTimer);
  crossFeedbackTimer = undefined;
  crossRound.move(crossToken, delta);
  presentCrossStatement();
}

function objectDuringCross() {
  if (!crossToken) return;
  markInteraction();
  clearTimeout(crossFeedbackTimer);
  const result = crossRound.object(crossToken);
  if (result.type === "incorrect") {
    performAction("sweat", { message: result.hint, autoReset: false, record: false });
    crossFeedbackTimer = setTimeout(presentCrossStatement, 1_500);
    return;
  }
  if (result.type !== "succeeded") return;

  clearTimeout(crossTimeout);
  crossTimeout = undefined;
  crossToken = undefined;
  dom.cross.classList.add("hidden");
  recordCourtEntry("challenge.cross-examination");
  performAction("objection", { autoReset: false, record: false });
  crossSequenceTimers.push(setTimeout(() => {
    performAction("decisive-evidence", {
      message: result.conclusion,
      autoReset: false,
      record: false,
    });
  }, 1_250));
  crossSequenceTimers.push(setTimeout(showIdle, 4_200));
}

function timeoutCross(token) {
  if (crossToken !== token || !crossRound.end(token, "timed-out")) return;
  crossToken = undefined;
  crossTimeout = undefined;
  dom.cross.classList.add("hidden");
  performAction("think", {
    message: "这句证言先记下来，下次再找矛盾。",
    autoReset: false,
    record: false,
  });
  crossSequenceTimers.push(setTimeout(showIdle, 2_400));
}

function cancelCross(restore) {
  clearTimeout(crossTimeout);
  clearTimeout(crossFeedbackTimer);
  crossTimeout = undefined;
  crossFeedbackTimer = undefined;
  crossSequenceTimers.forEach(clearTimeout);
  crossSequenceTimers = [];
  if (crossToken) crossRound.end(crossToken, "cancelled");
  const hadRound = Boolean(crossToken) || !dom.cross.classList.contains("hidden");
  crossToken = undefined;
  dom.cross.classList.add("hidden");
  if (restore && hadRound) showIdle();
}

function handleAccessoryEvent(event) {
  switch (event.type) {
    case "started": {
      cancelCross(false);
      closeCourtRecord(false);
      activeAccessorySession = event.sessionId;
      collection.clear();
      const snapshot = orderedRound.start(event.sessionId, event.kinds);
      renderOrderedHUD(snapshot);
      recordCourtEntry("physics.scatter");
      performAction("leg-struggle", { autoReset: false, record: false });
      break;
    }
    case "reclaimed": {
      if (event.sessionId !== activeAccessorySession || collection.has(event.kind)) return;
      collection.add(event.kind);
      const orderedResult = orderedRound.reclaim(event.sessionId, event.kind);
      if (orderedResult.snapshot) renderOrderedHUD(orderedResult.snapshot);
      const [actionName, baseMessage] = ACCESSORY_RESPONSES[event.kind];
      const orderMessage = orderedResult.type === "failed" ? " · 顺序断了，继续普通归档"
        : orderedResult.type === "completed" ? " · 顺序完全吻合"
          : orderedResult.type === "advanced" ? ` · 有序 ${orderedResult.snapshot.completedCount}/6` : "";
      performAction(actionName, {
        message: `${baseMessage}  已归档 ${collection.size}/6${orderMessage}`,
        record: false,
      });
      break;
    }
    case "finished": {
      if (event.sessionId !== activeAccessorySession) return;
      const allReclaimed = collection.size === ACCESSORY_KINDS.length;
      const outcome = allReclaimed ? orderedRound.finish(event.sessionId) : "ignored";
      activeAccessorySession = undefined;
      dom.ordered.className = "ordered-hud hidden";
      dom.ordered.replaceChildren();
      if (allReclaimed) {
        recordCourtEntry("challenge.full-archive");
        if (outcome === "ordered") recordCourtEntry("challenge.ordered-archive");
        pendingAccessoryReward = outcome === "ordered" ? "ordered" : "standard";
      } else {
        orderedRound.cancel(event.sessionId);
      }
      if (currentAction === "leg-struggle" || !actionTimer) showIdle();
      break;
    }
    default:
      break;
  }
}

function renderOrderedHUD(snapshot) {
  if (!snapshot) {
    dom.ordered.className = "ordered-hud hidden";
    return;
  }
  dom.ordered.className = `ordered-hud ${snapshot.phase}`;
  dom.ordered.replaceChildren(...snapshot.order.map((kind, index) => {
    const chip = document.createElement("span");
    chip.className = "order-chip";
    if (snapshot.phase === "failed") chip.classList.add("failed");
    else if (index < snapshot.completedCount) chip.classList.add("done");
    else if (index === snapshot.completedCount && snapshot.phase === "active") chip.classList.add("current");
    chip.textContent = ACCESSORY_LABELS[kind];
    chip.title = kind;
    return chip;
  }));
  dom.ordered.setAttribute(
    "aria-label",
    `有序归档，已完成 ${snapshot.completedCount} 件，${snapshot.phase === "active" ? `下一件 ${ACCESSORY_LABELS[snapshot.next]}` : snapshot.phase}`,
  );
}

function handleMotionEvent(event) {
  switch (event.type) {
    case "throw-start":
      performAction("thrown", { autoReset: false });
      break;
    case "bounce":
      performAction("impact", {
        message: event.severity === "heavy" ? "痛——！" : event.severity === "medium" ? "痛！" : "唔！",
        autoReset: false,
        record: false,
      });
      break;
    case "settled":
      performAction(event.severity === "light" ? "dropped" : "dizzy", {
        message: event.severity === "heavy" ? "天地都在转……这下真的很重！" : undefined,
        record: false,
      });
      break;
    default:
      break;
  }
}

function presentDeferredFeedback() {
  if (currentAction !== "idle" || crossToken || !dom.court.classList.contains("hidden")) return;
  if (pendingAccessoryReward) {
    const reward = pendingAccessoryReward;
    pendingAccessoryReward = undefined;
    setTimeout(() => performAction("decisive-evidence", {
      message: reward === "ordered"
        ? "顺序也完全吻合。现在，证据链没有缺口了！"
        : "六件证物全部归档。这就是完整的证据链！",
      record: false,
    }), 160);
    return;
  }
  showNextToast();
}

function recordCourtEntry(id) {
  const definition = COURT_CATALOG.find((entry) => entry.id === id);
  if (!definition) return;
  const now = Date.now();
  const existing = courtProgress[id];
  courtProgress[id] = {
    count: (existing?.count ?? 0) + 1,
    unlockedAt: existing?.unlockedAt ?? now,
    lastSeen: now,
  };
  localStorage.setItem("court-progress", JSON.stringify(courtProgress));
  if (!existing) {
    toastQueue.push(definition.title);
    presentDeferredFeedback();
  }
}

function showNextToast() {
  if (currentAction !== "idle" || crossToken || pendingAccessoryReward) return;
  if (!currentToast) currentToast = toastQueue.shift();
  if (!currentToast) return;
  dom.toast.textContent = `★ 新记录：${currentToast}`;
  dom.toast.classList.remove("hidden");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    dom.toast.classList.add("hidden");
    currentToast = undefined;
    showNextToast();
  }, 2_000);
}

function suspendToast() {
  clearTimeout(toastTimer);
  toastTimer = undefined;
  dom.toast.classList.add("hidden");
}

function showCourtRecord() {
  markInteraction();
  cancelCross(false);
  window.desktopPet.cancelAccessories();
  dom.court.classList.remove("hidden");
  suspendToast();
  renderCourtRecord();
}

function closeCourtRecord(restore = true) {
  const wasOpen = !dom.court.classList.contains("hidden");
  dom.court.classList.add("hidden");
  if (restore && wasOpen) showIdle();
}

function renderCourtRecord() {
  dom.courtList.replaceChildren(...COURT_CATALOG.map((definition) => {
    const progress = courtProgress[definition.id];
    const entry = document.createElement("article");
    entry.className = `court-entry${progress ? "" : " locked"}`;
    const title = document.createElement("strong");
    title.textContent = progress ? definition.title : "未解锁";
    const detail = document.createElement("span");
    detail.textContent = progress
      ? `${definition.detail} · 触发 ${progress.count} 次`
      : "继续互动，也许会发现新的记录。";
    entry.append(title, detail);
    return entry;
  }));
}

function markInteraction() {
  suspendToast();
  clearTimeout(idleTimer);
  idleTimer = undefined;
}

function scheduleIdle() {
  clearTimeout(idleTimer);
  const profile = companionPolicy.ambientProfile();
  if (!profile.enabled) return;
  const delay = profile.minimumMs + Math.random() * (profile.maximumMs - profile.minimumMs);
  idleTimer = setTimeout(() => {
    const trulyIdle = currentAction === "idle"
      && !crossToken
      && dom.court.classList.contains("hidden")
      && activeAccessorySession === undefined;
    if (trulyIdle && Math.random() <= profile.probability) {
      performAction(ambientBag.next(AMBIENT_ACTIONS), { record: true });
    } else {
      scheduleIdle();
    }
  }, delay);
}

function scheduleQuietExpiry() {
  clearTimeout(quietTimer);
  const snapshot = companionPolicy.snapshot();
  if (!snapshot.quietUntil) return;
  quietTimer = setTimeout(() => {
    companionPolicy.snapshot();
    persistPolicy();
    scheduleIdle();
  }, Math.max(0, snapshot.quietUntil - Date.now()));
}

function persistPolicy() {
  localStorage.setItem("companion-policy", JSON.stringify(companionPolicy.snapshot()));
  scheduleIdle();
}

function action(asset, phrase, duration, animation = "", recordId = undefined) {
  return Object.freeze({ asset, phrase, duration, animation, recordId });
}

function recordDefinition(id, title, detail) {
  return Object.freeze({ id, title, detail });
}

function loadJSON(key, fallback) {
  try {
    const value = JSON.parse(localStorage.getItem(key) ?? "null");
    return value && typeof value === "object" ? value : fallback;
  } catch {
    return fallback;
  }
}
