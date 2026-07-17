import {
  ACCESSORY_KINDS,
  CompanionPolicy,
  CROSS_EXAMINATION_QUESTIONS,
  CrossExaminationRound,
  OrderedArchiveRound,
  ShakeDetector,
  ShuffleBag,
  TeasingMemory,
} from "../shared/game-models.mjs";
import { EdgeIdleBehavior } from "../shared/edge-idle.mjs";
import { buildCharacterMask, detectGrabRegion } from "../shared/grab-region.mjs";

const ACTIONS = Object.freeze({
  idle: action("idle", "", 0, "action-idle"),
  think: action("think", "唏……真相只有一个。", 2_400, "action-think", "action.think"),
  objection: action("objection", "异议！", 2_000, "action-objection", "action.objection"),
  slam: action("slam", "等一下！", 1_800, "action-slam", "action.slam"),
  sweat: action("sweat", "糟了……", 2_100, "action-sweat", "action.sweat"),
  evidence: action("evidence", "证据就在这里。", 2_500, "action-evidence", "action.evidence"),
  "badge-toss": action("badge-toss", "这是我的律师徽章！", 2_200, "action-badge", "easter-egg.badge-toss"),
  magatama: action("magatama", "你的心里……有锁。", 2_800, "action-magatama", "easter-egg.magatama"),
  stepladder: action("stepladder", "这明明是人字梯！", 2_800, "action-stepladder", "easter-egg.stepladder"),
  thinker: action("thinker", "把“思考者”加入证物。", 2_600, "action-thinker", "easter-egg.thinker"),
  "decisive-evidence": action("decisive-evidence", "找到决定性的证据了！", 2_400, "action-decisive", "easter-egg.decisive-evidence"),
  flashlight: action("flashlight", "先把手电打开。", 3_200, "action-flashlight"),
  sleepy: action("sleepy", "就休息五分钟……", 3_000, "action-sleepy"),
  dropped: action("dropped", "下次先打声招呼！", 1_500, "action-dropped"),
  thrown: action("thrown", "哇啊——！", 0, "action-thrown", "physics.thrown"),
  impact: action("impact", "痛！", 0, "action-impact"),
  dizzy: action("dizzy", "天地都在转……", 2_200, "action-dizzy"),
  dusting: action("dusting", "我的西装……", 1_400, "action-dusting"),
  irritated: action("irritated", "下次绝对不许这样！", 2_000, "action-irritated"),
  "light-recovery": action("dizzy", "", 0, "action-light-recovery"),
  "held-struggle": action("held-struggle", "放、放我下来！", 0, "action-held"),
  "held-resigned": action("held-resigned", "……算了，随你吧。", 0, "action-resigned"),
  "hair-struggle": action("hair-struggle", "头发！别拽头发！", 0, "action-hair"),
  "hair-resigned": action("hair-resigned", "我的发型……算了。", 0, "action-hair-resigned"),
  "arm-struggle": action("arm-struggle", "等一下，胳膊要脱臼了！", 0, "action-arm"),
  "arm-resigned": action("arm-resigned", "……轻一点就好。", 0, "action-arm-resigned"),
  "leg-struggle": action("leg-struggle", "为什么偏偏拽脚啊！", 0, "action-leg"),
  "leg-resigned": action("leg-resigned", "我已经不想反抗了……", 0, "action-leg-resigned"),
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
const ACCESSORY_DISPLAY_NAMES = Object.freeze({
  "attorney-badge": "律师徽章",
  "case-file": "案件文件",
  magatama: "勾玉",
  evidence: "证物",
  pen: "笔",
  "sticky-note": "便签",
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
  recordDefinition("action.think", "经典动作", "!", "思考案情", "认真梳理过一次线索。", "也许安静片刻会有头绪。"),
  recordDefinition("action.objection", "经典动作", "!", "异议！", "让那句响亮的反驳划破了安静。", "有些矛盾需要被大声指出。"),
  recordDefinition("action.slam", "经典动作", "!", "拍桌", "以律师的气势拍下了桌面。", "关键时刻，需要一点气势。"),
  recordDefinition("action.sweat", "经典动作", "!", "紧张冒汗", "见过他措手不及的一面。", "失误有时也会带来新反应。"),
  recordDefinition("action.evidence", "经典动作", "!", "查看证物", "请他仔细查看过证物。", "真相常藏在纸面细节里。"),
  recordDefinition("easter-egg.badge-toss", "彩蛋", "★", "甩出律师徽章", "律师身份用一种轻快的方式登场。", "那枚小小的身份象征还会出现。"),
  recordDefinition("easter-egg.magatama", "彩蛋", "★", "勾玉与心灵枷锁", "察觉到话语背后隐藏的心事。", "秘密不会永远沉默。"),
  recordDefinition("easter-egg.stepladder", "彩蛋", "★", "梯子还是人字梯", "认真争论了某件工具的准确叫法。", "同一样东西，也可能有两种称呼。"),
  recordDefinition("easter-egg.thinker", "彩蛋", "★", "出示“思考者”", "一件造型特别的摆设进入了记录。", "某件会报时的摆设值得留意。"),
  recordDefinition("easter-egg.decisive-evidence", "彩蛋", "★", "决定性证据", "终于举起了足以改变局面的证据。", "继续寻找能让局势翻转的东西。"),
  recordDefinition("grab.hair/head", "抓取反应", "↕", "发型保卫战", "真的从头发附近把他拎了起来。", "角色身上还有一处不同的抓取反应。"),
  recordDefinition("grab.arm", "抓取反应", "↕", "律师的手臂", "从手臂附近触发了专属挣扎。", "角色身上还有一处不同的抓取反应。"),
  recordDefinition("grab.collar/torso", "抓取反应", "↕", "领口悬案", "从领口或躯干处把他提了起来。", "角色身上还有一处不同的抓取反应。"),
  recordDefinition("grab.leg", "抓取反应", "↕", "倒吊的辩护人", "从腿脚附近触发了完全不同的反应。", "角色身上还有一处不同的抓取反应。"),
  recordDefinition("environment.dark-place", "环境反应", "☾", "黑暗中的调查", "在真正昏暗的壁纸落点见到了怕黑反应。", "周围环境偶尔也会影响调查。"),
  recordDefinition("response.heard-name", "名字回应", "♪", "听见呼唤", "聊天输入框里新出现名字时，他作出了回应。", "一声恰当的呼唤也许会被听见。"),
  recordDefinition("physics.thrown", "桌面互动", "↗", "空中的辩护人", "快速拖动后松手，让他经历了一次完整的甩飞。", "拖动速度也可能改变松手后的结果。"),
  recordDefinition("physics.upside-down-scatter", "桌面互动", "↗", "散落的法庭记录", "倒吊摇摆时，律师随身的道具散落了一地。", "倒吊以后，试着让他左右摇摆。"),
  recordDefinition("environment.edge-rest", "环境反应", "☾", "边缘观察", "长时间靠近屏幕边缘时，他停下来观察了周围。", "让他在屏幕边缘安静待上一阵。"),
  recordDefinition("challenge.cross-examination", "庭审挑战", "◆", "交叉询问", "从三句证言中找出了真正的矛盾。", "右键菜单里，也许能开始一次短暂的庭审。"),
  recordDefinition("challenge.ordered-evidence-archive", "庭审挑战", "◆", "完美归档", "六件证物按照指定顺序完整归档。", "散落的证物，也有一条严谨的归档顺序。"),
]);

const dom = {
  root: document.querySelector("#pet-root"),
  stage: document.querySelector("#pet-stage"),
  image: document.querySelector("#pet-image"),
  dialogue: document.querySelector("#dialogue"),
  dialogueMarker: document.querySelector("#dialogue-marker"),
  dialogueText: document.querySelector("#dialogue-text"),
  toast: document.querySelector("#unlock-toast"),
  objection: document.querySelector("#objection-burst"),
  edgeMotion: document.querySelector("#edge-motion"),
  edgeStrokes: [...document.querySelectorAll(".edge-stroke")],
  edgeScan: document.querySelector(".edge-scan"),
  edgeMarker: document.querySelector(".edge-marker"),
  followUpHotspot: document.querySelector("#follow-up-hotspot"),
  followUpChoices: document.querySelector("#follow-up-choices"),
  followUpCase: document.querySelector("#follow-up-case"),
  followUpBadge: document.querySelector("#follow-up-badge"),
  followUpClose: document.querySelector("#follow-up-close"),
  ordered: document.querySelector("#ordered-hud"),
  cross: document.querySelector("#cross-controls"),
  previous: document.querySelector("#cross-previous"),
  next: document.querySelector("#cross-next"),
  object: document.querySelector("#cross-object"),
  crossClose: document.querySelector("#cross-close"),
};

const assetURLs = new Map();
const interactiveBag = new ShuffleBag();
const ambientBag = new ShuffleBag();
const questionBag = new ShuffleBag();
const orderedRound = new OrderedArchiveRound();
const crossRound = new CrossExaminationRound();
const shakeDetector = new ShakeDetector();
const teasingMemory = new TeasingMemory();
const edgeIdleBehavior = new EdgeIdleBehavior();
const grabMaskCache = new Map();
const collection = new Set();
const courtProgress = migrateCourtProgress(loadJSON("court-progress", {}));
const savedPolicy = loadJSON("companion-policy", {});
const companionPolicy = new CompanionPolicy(savedPolicy);

let currentAction = "idle";
let actionTimer;
let idleTimer;
let quietTimer;
let clickTimer;
let objectionHideTimer;
let objectionFinishTimer;
let dialogueExitTimer;
let dialogueTypeTimer;
let courtRecordOpen = false;
let isMouseInside = false;
let followUpState;
let followUpTimer;
let followUpSequenceTimers = [];
let lastExplicitInteractionAt = performance.now();
let edgeRestState;
let edgeRestTimers = [];
let currentGrabMask;
let activeAsset = "idle";
let dragResignTimer;
let throwInFlight = false;
let lastBounceAt = 0;
let throwRecoveryTimers = [];
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
scheduleIdle({ reset: true, useInitial: true });
scheduleQuietExpiry();
window.desktopPet.rendererReady();

async function preloadAssets() {
  const names = new Set(Object.values(ACTIONS).map((entry) => `${entry.asset}-cg.png`));
  await Promise.all([...names].map(async (name) => {
    assetURLs.set(name, await window.desktopPet.assetUrl(name));
  }));
  currentGrabMask = await loadGrabMask("idle");
}

function wireInteractions() {
  dom.stage.addEventListener("mousedown", beginPointerInteraction);
  dom.root.addEventListener("mouseenter", () => {
    isMouseInside = true;
    updateFollowUpHotspot();
  });
  dom.root.addEventListener("mouseleave", () => {
    isMouseInside = false;
    updateFollowUpHotspot();
  });
  document.addEventListener("mousemove", continuePointerInteraction);
  document.addEventListener("mouseup", endPointerInteraction);
  document.addEventListener("contextmenu", showContextMenu);

  dom.followUpHotspot.addEventListener("click", activateFollowUp);
  dom.followUpCase.addEventListener("click", () => playFollowUp("case"));
  dom.followUpBadge.addEventListener("click", () => playFollowUp("badge"));
  dom.followUpClose.addEventListener("click", () => cancelFollowUp(true));
  dom.previous.addEventListener("click", () => navigateCross(-1));
  dom.next.addEventListener("click", () => navigateCross(1));
  dom.object.addEventListener("click", objectDuringCross);
  dom.crossClose.addEventListener("click", () => cancelCross(true));
  window.desktopPet.onMenuCommand(handleMenuCommand);
  window.desktopPet.onMenuClosed(() => {
    presentDeferredFeedback();
    scheduleIdle();
  });
  window.desktopPet.onMotionEvent(handleMotionEvent);
  window.desktopPet.onAccessoryEvent(handleAccessoryEvent);
  window.desktopPet.onCourtRecordClosed(() => {
    const wasOpen = courtRecordOpen;
    courtRecordOpen = false;
    if (wasOpen) showIdle();
  });
}

function beginPointerInteraction(event) {
  if (event.button !== 0) return;
  if (courtRecordOpen) return;
  const region = detectGrabRegion(
    currentGrabMask,
    { x: event.clientX, y: event.clientY },
    dom.stage.getBoundingClientRect(),
  );
  if (!region) return;
  cancelFollowUp(false);
  cancelCross(false);
  markInteraction();
  pointerState = {
    startX: event.screenX,
    startY: event.screenY,
    samples: [{ x: event.screenX, y: event.screenY, time: performance.now() }],
    dragging: false,
    region,
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
    beginBeingHeld(pointerState.region);
  }
  if (!pointerState.dragging) return;

  window.desktopPet.dragMove(event.screenX, event.screenY);
  const now = performance.now();
  pointerState.samples.push({ x: event.screenX, y: event.screenY, time: now });
  pointerState.samples = pointerState.samples.filter((sample) => now - sample.time <= 140);
  if (pointerState.region === "leg" && shakeDetector.add(event.screenX)) {
    clearTimeout(dragResignTimer);
    window.desktopPet.scatterAccessories();
  }
}

function endPointerInteraction(event) {
  if (!pointerState || event.button !== 0) return;
  const state = pointerState;
  pointerState = undefined;
  clearTimeout(dragResignTimer);
  dragResignTimer = undefined;
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
    if (Math.hypot(velocity.x, velocity.y) >= 720) {
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

function beginBeingHeld(region) {
  const actionPair = {
    "hair/head": ["hair-struggle", "hair-resigned"],
    arm: ["arm-struggle", "arm-resigned"],
    "collar/torso": ["held-struggle", "held-resigned"],
    leg: ["leg-struggle", "leg-resigned"],
  }[region];
  if (!actionPair) return;

  recordCourtEntry(`grab.${region}`);
  const stage = teasingMemory.record(region === "leg" ? "legDrag" : "grab", performance.now());
  const [struggle, resigned] = actionPair;
  if (stage === "resigned") {
    performAction(resigned, {
      message: "……我就知道你还会来。",
      autoReset: false,
      record: false,
    });
    return;
  }

  performAction(struggle, {
    message: stage === "irritated" ? "又来？！我真的要抗议了！" : undefined,
    autoReset: false,
    record: false,
  });
  dragResignTimer = setTimeout(() => {
    if (!pointerState?.dragging) return;
    performAction(resigned, {
      message: stage === "irritated" ? "……你到底还要闹几次。" : undefined,
      autoReset: false,
      record: false,
    });
  }, stage === "irritated" ? 1_400 : 2_200);
}

function showContextMenu(event) {
  event.preventDefault();
  cancelFollowUp(true);
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
          2_600,
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
  clearEdgeRest();
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
  activeAsset = definition.asset;
  dom.image.src = assetURLs.get(`${definition.asset}-cg.png`) ?? "";
  activateGrabMask(definition.asset);
  dom.image.className = "";
  void dom.image.offsetWidth;
  if (definition.animation) dom.image.classList.add(definition.animation);

  if (name === "objection") {
    showObjectionBurst();
    hideDialogue();
  } else if (message) {
    hideObjectionBurst();
    showDialogue(message, dialogueStyle(name));
  } else {
    hideObjectionBurst();
    hideDialogue();
  }

  if (record && definition.recordId) recordCourtEntry(definition.recordId);
  if (autoReset) actionTimer = setTimeout(showIdle, definition.duration);
}

function showIdle() {
  clearEdgeRest();
  clearTimeout(actionTimer);
  actionTimer = undefined;
  if (crossToken) return;
  currentAction = "idle";
  activeAsset = "idle";
  dom.image.src = assetURLs.get("idle-cg.png") ?? "";
  activateGrabMask("idle");
  dom.image.className = ACTIONS.idle.animation;
  hideObjectionBurst();
  hideDialogue();
  updateFollowUpHotspot();
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

function showDialogue(message, style = "friendly") {
  clearTimeout(dialogueExitTimer);
  clearInterval(dialogueTypeTimer);
  dialogueExitTimer = undefined;
  dialogueTypeTimer = undefined;
  dom.dialogue.className = "dialogue hidden";
  dom.dialogueMarker.textContent = dialogueMarker(style);
  dom.dialogueText.textContent = style === "thought" ? "" : message;
  void dom.dialogue.offsetWidth;
  dom.dialogue.className = `dialogue ${style} entering`;

  if (style === "thought" && message) {
    const characters = [...message];
    let index = 0;
    dialogueTypeTimer = setInterval(() => {
      index += 1;
      dom.dialogueText.textContent = characters.slice(0, index).join("");
      if (index >= characters.length) {
        clearInterval(dialogueTypeTimer);
        dialogueTypeTimer = undefined;
      }
    }, 55);
  }
}

function hideDialogue() {
  clearInterval(dialogueTypeTimer);
  dialogueTypeTimer = undefined;
  if (dom.dialogue.classList.contains("hidden")
      || dom.dialogue.classList.contains("exiting")) return;
  const duration = dialogueExitDuration(dom.dialogue);
  dom.dialogue.classList.remove("entering");
  dom.dialogue.classList.add("exiting");
  dialogueExitTimer = setTimeout(() => {
    dom.dialogue.className = "dialogue hidden";
    dom.dialogueText.textContent = "";
    dom.dialogueMarker.textContent = "";
    dialogueExitTimer = undefined;
  }, duration);
}

function dialogueStyle(actionName) {
  if (actionName === "think") return "thought";
  if (["sweat", "dizzy", "light-recovery"].includes(actionName)) return "nervous";
  if (["slam", "decisive-evidence"].includes(actionName)) return "courtroom";
  if (actionName === "badge-toss") return "badge";
  if (actionName === "magatama") return "spiritual";
  if (actionName === "flashlight") return "flashlight";
  if (["held-struggle", "hair-struggle", "arm-struggle", "leg-struggle", "thrown"].includes(actionName)) return "drag-protest";
  if (["held-resigned", "hair-resigned", "arm-resigned", "leg-resigned"].includes(actionName)) return "resigned";
  if (["dropped", "impact"].includes(actionName)) return "impact";
  return "friendly";
}

function dialogueMarker(style) {
  switch (style) {
    case "thought":
    case "resigned": return "…";
    case "nervous":
    case "courtroom":
    case "drag-protest":
    case "impact": return "!";
    case "badge": return "律";
    case "spiritual": return "勾";
    case "flashlight": return "✦";
    default: return "●";
  }
}

function dialogueExitDuration(element) {
  if (element.classList.contains("thought")) return 340;
  if (element.classList.contains("nervous")) return 280;
  if (element.classList.contains("courtroom")) return 250;
  if (element.classList.contains("badge")) return 320;
  if (element.classList.contains("spiritual")) return 480;
  if (element.classList.contains("flashlight")) return 220;
  if (element.classList.contains("drag-protest")) return 300;
  if (element.classList.contains("resigned")) return 620;
  if (element.classList.contains("impact")) return 140;
  return 240;
}

function startCrossExamination() {
  markInteraction();
  cancelFollowUp(false);
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
  dom.object.textContent = `异议 · 第 ${snapshot.index + 1} 句`;
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
    dom.object.textContent = "再看看";
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
  }, 1_350));
  crossSequenceTimers.push(setTimeout(showIdle, 4_400));
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
  crossSequenceTimers.push(setTimeout(showIdle, 2_600));
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

function beginPendingFollowUp() {
  clearFollowUpTimers();
  followUpState = "pending";
  dom.followUpChoices.classList.add("hidden");
  updateFollowUpHotspot();
  followUpTimer = setTimeout(() => cancelFollowUp(true), 10_000);
}

function activateFollowUp() {
  if (followUpState !== "pending") return;
  clearFollowUpTimers();
  markInteraction();
  followUpState = "choosing";
  updateFollowUpHotspot();
  dom.followUpChoices.classList.remove("hidden");
  performAction("think", {
    message: "刚才的线索……想追问哪一边？",
    autoReset: false,
    record: false,
  });
  followUpTimer = setTimeout(() => cancelFollowUp(true), 12_000);
}

function playFollowUp(branch) {
  if (followUpState !== "choosing") return;
  clearFollowUpTimers();
  markInteraction();
  dom.followUpChoices.classList.add("hidden");

  if (branch === "case") {
    followUpState = undefined;
    startCrossExamination();
    return;
  }

  followUpState = "badge";
  performAction("badge-toss", {
    message: "这是我的律师徽章。货真价实！",
    autoReset: false,
    record: false,
  });
  scheduleFollowUpStep(5_200, () => performAction("think", {
    message: "不过，徽章本身可不能代替证据。",
    autoReset: false,
    record: false,
  }));
  scheduleFollowUpStep(11_400, () => cancelFollowUp(true));
}

function scheduleFollowUpStep(delay, operation) {
  const timer = setTimeout(() => {
    followUpSequenceTimers = followUpSequenceTimers.filter((candidate) => candidate !== timer);
    operation();
  }, delay);
  followUpSequenceTimers.push(timer);
}

function clearFollowUpTimers() {
  clearTimeout(followUpTimer);
  followUpTimer = undefined;
  followUpSequenceTimers.forEach(clearTimeout);
  followUpSequenceTimers = [];
}

function cancelFollowUp(restore) {
  const hadFollowUp = Boolean(followUpState);
  clearFollowUpTimers();
  followUpState = undefined;
  dom.followUpHotspot.classList.add("hidden");
  dom.followUpChoices.classList.add("hidden");
  if (restore && hadFollowUp) showIdle();
}

function updateFollowUpHotspot() {
  dom.followUpHotspot.classList.toggle(
    "hidden",
    followUpState !== "pending" || !isMouseInside,
  );
}

function handleAccessoryEvent(event) {
  switch (event.type) {
    case "started": {
      cancelFollowUp(false);
      cancelCross(false);
      closeCourtRecord(false);
      activeAccessorySession = event.sessionId;
      collection.clear();
      const snapshot = orderedRound.start(event.sessionId, event.kinds);
      renderOrderedHUD(snapshot);
      recordCourtEntry("physics.upside-down-scatter");
      performAction("leg-struggle", {
        message: "等一下！我的证物都掉出来了！",
        autoReset: false,
        record: false,
      });
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
        if (outcome === "ordered") recordCourtEntry("challenge.ordered-evidence-archive");
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
  const chips = snapshot.order.map((kind, index) => {
    const chip = document.createElement("span");
    chip.className = "order-chip";
    if (snapshot.phase === "failed") chip.classList.add("failed");
    else if (index < snapshot.completedCount) chip.classList.add("done");
    else if (index === snapshot.completedCount && snapshot.phase === "active") chip.classList.add("current");
    chip.textContent = ACCESSORY_LABELS[kind];
    chip.title = kind;
    return chip;
  });
  const status = document.createElement("span");
  status.className = "order-status";
  status.textContent = snapshot.phase === "failed" ? "错序"
    : snapshot.phase === "completed" ? "完成"
      : `${snapshot.completedCount}/${snapshot.order.length}`;
  dom.ordered.replaceChildren(...chips, status);
  const orderText = snapshot.order.map((kind) => ACCESSORY_DISPLAY_NAMES[kind]).join("、");
  const description = snapshot.phase === "failed"
    ? `有序证物归档失败，已完成 ${snapshot.completedCount} 件，顺序：${orderText}`
    : snapshot.phase === "completed"
      ? `有序证物归档完成，六件证物顺序：${orderText}`
      : `有序证物归档，顺序：${orderText}，已完成 ${snapshot.completedCount} 件，下一件：${ACCESSORY_DISPLAY_NAMES[snapshot.next] ?? "无"}`;
  dom.ordered.setAttribute(
    "aria-label",
    description,
  );
}

function handleMotionEvent(event) {
  switch (event.type) {
    case "throw-start": {
      cancelThrowRecovery();
      throwInFlight = true;
      lastBounceAt = 0;
      const teasingStage = teasingMemory.stage(performance.now());
      const message = teasingStage === "irritated" ? "又扔？！我正式抗议！"
        : teasingStage === "resigned" ? "……我就知道最后会被扔出去。"
          : "哇啊——！";
      performAction("thrown", { message, autoReset: false, record: false });
      break;
    }
    case "bounce": {
      const now = performance.now();
      if (now - lastBounceAt < 280) return;
      lastBounceAt = now;
      cancelThrowRecovery(false);
      const impactAction = event.severity === "light" ? "dropped" : "impact";
      const impactMessage = event.severity === "heavy" ? "痛——！"
        : event.severity === "medium" ? "痛！" : "唔！";
      const afterMessage = event.severity === "heavy" ? "这已经不是搬家了吧？！"
        : event.severity === "medium" ? "好痛……！" : "只是轻轻碰了一下……";
      performAction(impactAction, {
        message: impactMessage,
        autoReset: false,
        record: false,
      });
      scheduleThrowRecovery(650, () => {
        if (!throwInFlight) return;
        performAction("thrown", { message: afterMessage, autoReset: false, record: false });
      });
      break;
    }
    case "settled":
      throwInFlight = false;
      beginThrowLandingRecovery(event.severity);
      break;
    default:
      break;
  }
}

function beginThrowLandingRecovery(severity) {
  cancelThrowRecovery();
  if (severity === "light") {
    performAction("light-recovery", {
      message: "嘶……只是撞到头了。",
      autoReset: false,
      record: false,
    });
    scheduleThrowRecovery(1_800, showIdle);
    return;
  }

  if (severity === "medium") {
    performAction("dizzy", {
      message: "有点晕……先让我缓一下。",
      autoReset: false,
      record: false,
    });
    scheduleThrowRecovery(2_000, () => performAction("dusting", {
      message: "西装也沾上灰了……",
      autoReset: false,
      record: false,
    }));
    scheduleThrowRecovery(3_600, showIdle);
    return;
  }

  performAction("dizzy", {
    message: "天地都在转……这下真的很重！",
    autoReset: false,
    record: false,
  });
  scheduleThrowRecovery(2_200, () => performAction("dusting", {
    autoReset: false,
    record: false,
  }));
  scheduleThrowRecovery(3_700, () => performAction("irritated", {
    message: "下次绝对不许这样扔！",
    autoReset: false,
    record: false,
  }));
  scheduleThrowRecovery(5_700, showIdle);
}

function scheduleThrowRecovery(delay, operation) {
  const timer = setTimeout(() => {
    throwRecoveryTimers = throwRecoveryTimers.filter((candidate) => candidate !== timer);
    operation();
  }, delay);
  throwRecoveryTimers.push(timer);
}

function cancelThrowRecovery(endFlight = true) {
  throwRecoveryTimers.forEach(clearTimeout);
  throwRecoveryTimers = [];
  if (endFlight) throwInFlight = false;
}

function presentDeferredFeedback() {
  if (currentAction !== "idle" || crossToken || courtRecordOpen || followUpState) return;
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
  if (courtRecordOpen) presentCourtRecordWindow();
  if (!existing) {
    toastQueue.push(definition.title);
    presentDeferredFeedback();
  }
}

function showNextToast() {
  if (currentAction !== "idle" || crossToken || courtRecordOpen || followUpState || pendingAccessoryReward) return;
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
  cancelFollowUp(false);
  cancelCross(false);
  window.desktopPet.cancelAccessories();
  suspendToast();
  showIdle();
  courtRecordOpen = true;
  presentCourtRecordWindow();
}

function closeCourtRecord(restore = true) {
  const wasOpen = courtRecordOpen;
  courtRecordOpen = false;
  window.desktopPet.closeCourtRecord();
  if (restore && wasOpen) showIdle();
}

function presentCourtRecordWindow() {
  window.desktopPet.showCourtRecord({
    entries: COURT_CATALOG.map((definition) => ({
      definition,
      progress: courtProgress[definition.id],
    })),
  });
}

function markInteraction() {
  cancelThrowRecovery();
  clearEdgeRest();
  lastExplicitInteractionAt = performance.now();
  edgeIdleBehavior.resetCandidate();
  suspendToast();
  clearTimeout(idleTimer);
  idleTimer = undefined;
}

function scheduleIdle({ reset = false, useInitial = false } = {}) {
  if (idleTimer && !reset) return;
  clearTimeout(idleTimer);
  idleTimer = undefined;
  const profile = companionPolicy.ambientProfile();
  if (!profile.enabled) return;
  const delay = useInitial
    ? profile.initialMs
    : profile.minimumMs + Math.random() * (profile.maximumMs - profile.minimumMs);
  idleTimer = setTimeout(() => {
    idleTimer = undefined;
    void performScheduledIdleOpportunity(profile);
  }, delay);
}

async function performScheduledIdleOpportunity(profile) {
  if (!isTrulyIdle() || Math.random() > profile.probability) {
    scheduleIdle();
    return;
  }

  const now = performance.now();
  let context;
  try {
    context = await window.desktopPet.edgeContext();
  } catch {
    context = undefined;
  }
  if (!isTrulyIdle()) {
    scheduleIdle();
    return;
  }

  const edge = edgeIdleBehavior.evaluate({
    windowFrame: context?.windowFrame,
    workArea: context?.workArea,
    idleDurationMs: Math.max(0, now - lastExplicitInteractionAt),
    now,
    eligibility: true,
  });
  if (edge) {
    performEdgeIdle(edge);
    return;
  }

  const ambientAction = ambientBag.next(AMBIENT_ACTIONS);
  performAction(ambientAction, { record: true });
  if (["think", "evidence", "badge-toss"].includes(ambientAction)) {
    beginPendingFollowUp();
  }
}

function isTrulyIdle() {
  return currentAction === "idle"
    && !crossToken
    && !courtRecordOpen
    && !followUpState
    && !edgeRestState
    && activeAccessorySession === undefined;
}

function performEdgeIdle(edge) {
  const message = edge === "left" ? "从左边观察一下。"
    : edge === "right" ? "从右边观察一下。" : "这里视野不错。";
  performAction("think", { message, autoReset: false, record: true });
  recordCourtEntry("environment.edge-rest");
  edgeRestState = edge;
  dom.image.classList.add("action-edge-rest", `edge-${edge}`);
  configureEdgeMotion(edge, false);
  dom.edgeMotion.setAttribute("class", `edge-motion entrance edge-${edge}`);
  scheduleEdgeRestStep(620, () => {
    if (edgeRestState === edge) dom.edgeMotion.setAttribute("class", `edge-motion ambient edge-${edge}`);
  });
  scheduleEdgeRestStep(6_000, () => playEdgeRestExit(edge));
}

function playEdgeRestExit(edge) {
  if (edgeRestState !== edge) return;
  configureEdgeMotion(edge, true);
  dom.edgeMotion.setAttribute("class", `edge-motion exiting edge-${edge}`);
  scheduleEdgeRestStep(480, showIdle);
}

function scheduleEdgeRestStep(delay, operation) {
  const timer = setTimeout(() => {
    edgeRestTimers = edgeRestTimers.filter((candidate) => candidate !== timer);
    operation();
  }, delay);
  edgeRestTimers.push(timer);
}

function clearEdgeRest() {
  edgeRestTimers.forEach(clearTimeout);
  edgeRestTimers = [];
  edgeRestState = undefined;
  dom.edgeMotion.setAttribute("class", "edge-motion hidden");
  dom.image.classList.remove("action-edge-rest", "edge-left", "edge-right", "edge-bottom");
}

function configureEdgeMotion(edge, reversed) {
  const strokes = edgeMotionStrokes(edge);
  dom.edgeStrokes.forEach((path, index) => {
    path.setAttribute("pathLength", "1");
    path.setAttribute("d", quadraticPath(strokes[index], reversed));
  });
  const scan = edgeMotionScan(edge);
  const scanPath = quadraticPath(scan, false);
  dom.edgeScan.setAttribute("pathLength", "1");
  dom.edgeScan.setAttribute("d", scanPath);
  dom.edgeMarker.style.offsetPath = `path("${scanPath}")`;
}

function quadraticPath([start, control, end], reversed) {
  const [from, to] = reversed ? [end, start] : [start, end];
  const point = ([x, y]) => `${(x * 240).toFixed(2)} ${((1 - y) * 189).toFixed(2)}`;
  return `M ${point(from)} Q ${point(control)} ${point(to)}`;
}

function edgeMotionStrokes(edge) {
  if (edge === "left") return [
    [[.56, .68], [.31, .78], [.07, .72]],
    [[.48, .49], [.25, .55], [.05, .46]],
    [[.43, .31], [.22, .27], [.09, .20]],
  ];
  if (edge === "right") return [
    [[.44, .68], [.69, .78], [.93, .72]],
    [[.52, .49], [.75, .55], [.95, .46]],
    [[.57, .31], [.78, .27], [.91, .20]],
  ];
  return [
    [[.30, .72], [.24, .42], [.20, .08]],
    [[.50, .82], [.53, .46], [.50, .06]],
    [[.70, .70], [.77, .38], [.81, .10]],
  ];
}

function edgeMotionScan(edge) {
  if (edge === "left") return [[.11, .22], [.45, .52], [.13, .82]];
  if (edge === "right") return [[.89, .22], [.55, .52], [.87, .82]];
  return [[.20, .13], [.50, .54], [.80, .13]];
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
  scheduleIdle({ reset: true, useInitial: true });
}

function action(asset, phrase, duration, animation = "", recordId = undefined) {
  return Object.freeze({ asset, phrase, duration, animation, recordId });
}

function recordDefinition(id, category, icon, title, detail, lockedHint) {
  return Object.freeze({ id, category, icon, title, detail, lockedHint });
}

function migrateCourtProgress(progress) {
  const aliases = {
    "easter.badge": "easter-egg.badge-toss",
    "easter.magatama": "easter-egg.magatama",
    "easter.stepladder": "easter-egg.stepladder",
    "easter.thinker": "easter-egg.thinker",
    "easter.decisive": "easter-egg.decisive-evidence",
    "physics.scatter": "physics.upside-down-scatter",
    "challenge.ordered-archive": "challenge.ordered-evidence-archive",
  };
  for (const [legacyID, currentID] of Object.entries(aliases)) {
    if (progress[legacyID] && !progress[currentID]) progress[currentID] = progress[legacyID];
    delete progress[legacyID];
  }
  delete progress["challenge.full-archive"];
  localStorage.setItem("court-progress", JSON.stringify(progress));
  return progress;
}

function loadJSON(key, fallback) {
  try {
    const value = JSON.parse(localStorage.getItem(key) ?? "null");
    return value && typeof value === "object" ? value : fallback;
  } catch {
    return fallback;
  }
}

async function loadGrabMask(asset) {
  if (!grabMaskCache.has(asset)) {
    grabMaskCache.set(asset, window.desktopPet.assetMask(`${asset}-cg.png`)
      .then((source) => buildCharacterMask(source))
      .catch(() => undefined));
  }
  return grabMaskCache.get(asset);
}

function activateGrabMask(asset) {
  currentGrabMask = undefined;
  loadGrabMask(asset).then((mask) => {
    if (activeAsset === asset) currentGrabMask = mask;
  });
}
