import { app, BrowserWindow, ipcMain, Menu, nativeImage, screen } from "electron";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  ACCESSORY_MOTIONS,
  accessoryMotionPosition,
  accessoryPathPosition,
  easedProgress,
} from "./shared/accessory-motion.mjs";
import { stepAccessoryPhysics } from "./shared/accessory-scatter.mjs";
import { createThrowState, stepThrowPhysics } from "./shared/throw-physics.mjs";

const moduleDirectory = path.dirname(fileURLToPath(import.meta.url));
const rendererDirectory = path.join(moduleDirectory, "renderer");
const preloadPath = path.join(moduleDirectory, "preload.cjs");
const petSize = { width: 240, height: 260 };
const accessoryKinds = [
  "attorney-badge",
  "case-file",
  "magatama",
  "evidence",
  "pen",
  "sticky-note",
];
const accessoryAssetNames = {
  "attorney-badge": "scatter-attorney-badge-cg.png",
  "case-file": "scatter-case-file-cg.png",
  magatama: "scatter-magatama-cg.png",
  evidence: "scatter-evidence-cg.png",
  pen: "scatter-pen-cg.png",
  "sticky-note": "scatter-notes-cg.png",
};

let petWindow;
let courtRecordWindow;
let courtRecordPayload;
let dragState;
let throwTimer;
let throwState;
let throwVisibleFrames = [];
let accessorySequence = 0;
let activeAccessorySession;
let accessoryPhysicsTimer;
let lastAccessoryPhysicsTime;
let accessoryWindows = new Map();
let reclaimedAccessories = new Set();
let rendererReady = false;
const assetMaskCache = new Map();

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on("second-instance", () => petWindow?.showInactive());
}

app.whenReady().then(() => {
  if (process.platform === "win32") app.setAppUserModelId("com.ymatrix.phoenix-desktop-pet");
  registerIPC();
  createPetWindow();

  if (process.argv.includes("--smoke-test")) {
    setTimeout(() => {
      if (!rendererReady) process.exitCode = 1;
      app.quit();
    }, 2_500);
  }
});

app.on("window-all-closed", () => {});

app.on("before-quit", () => {
  stopThrow();
  finishAccessorySession("quit", false);
  courtRecordWindow?.destroy();
});

function createPetWindow() {
  const display = screen.getPrimaryDisplay();
  const area = display.workArea;
  const window = new BrowserWindow({
    ...petSize,
    x: Math.round(area.x + area.width - petSize.width - 24),
    y: Math.round(area.y + area.height - petSize.height - 18),
    transparent: true,
    frame: false,
    resizable: false,
    maximizable: false,
    minimizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    hasShadow: false,
    backgroundColor: "#00000000",
    show: false,
    webPreferences: {
      preload: preloadPath,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      devTools: false,
    },
  });

  window.setAlwaysOnTop(true, "floating");
  window.setMenuBarVisibility(false);
  window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  window.webContents.on("will-navigate", (event) => event.preventDefault());
  window.once("ready-to-show", () => window.showInactive());
  window.on("closed", () => {
    petWindow = undefined;
    app.quit();
  });
  window.loadFile(path.join(rendererDirectory, "index.html"));
  petWindow = window;
}

function registerIPC() {
  ipcMain.handle("asset-url", (_event, fileName) => {
    if (!/^[a-z0-9-]+-cg\.png$/u.test(fileName)) throw new Error("Invalid asset name");
    return pathToFileURL(path.join(assetRoot(), fileName)).href;
  });

  ipcMain.handle("asset-mask", (event, fileName) => {
    if (!isPetSender(event) || !/^[a-z0-9-]+-cg\.png$/u.test(fileName)) {
      throw new Error("Invalid asset mask request");
    }
    if (assetMaskCache.has(fileName)) return assetMaskCache.get(fileName);
    const image = nativeImage.createFromPath(path.join(assetRoot(), fileName));
    const size = image.getSize();
    if (image.isEmpty() || size.width < 1 || size.height < 1 || size.width * size.height > 4_194_304) {
      throw new Error("Invalid asset image");
    }
    const bitmap = image.toBitmap();
    const alpha = new Uint8Array(size.width * size.height);
    for (let index = 0; index < alpha.length; index += 1) alpha[index] = bitmap[index * 4 + 3];
    const result = { width: size.width, height: size.height, alpha };
    assetMaskCache.set(fileName, result);
    return result;
  });

  ipcMain.handle("edge-context", (event) => {
    if (!isPetSender(event) || !petWindow || petWindow.isDestroyed()) return undefined;
    const windowFrame = petWindow.getBounds();
    return {
      windowFrame,
      workArea: screen.getDisplayMatching(windowFrame).workArea,
    };
  });

  ipcMain.on("drag-start", (event, point) => {
    if (!isPetSender(event) || !validPoint(point) || !petWindow) return;
    stopThrow();
    const [x, y] = petWindow.getPosition();
    dragState = { pointerX: point.x, pointerY: point.y, windowX: x, windowY: y };
  });

  ipcMain.on("drag-move", (event, point) => {
    if (!isPetSender(event) || !dragState || !validPoint(point) || !petWindow) return;
    const targetX = dragState.windowX + point.x - dragState.pointerX;
    const targetY = dragState.windowY + point.y - dragState.pointerY;
    petWindow.setPosition(Math.round(targetX), Math.round(targetY), false);
  });

  ipcMain.on("drag-end", (event, velocity) => {
    if (!isPetSender(event) || !petWindow) return;
    dragState = undefined;
    if (!validPoint(velocity) || Math.hypot(velocity.x, velocity.y) < 720) {
      return;
    }
    startThrow(velocity);
  });

  ipcMain.on("show-context-menu", (event, state = {}) => {
    if (!isPetSender(event) || !petWindow) return;
    showContextMenu(state);
  });

  ipcMain.on("show-court-record", (event, payload) => {
    if (!isPetSender(event)) return;
    const normalizedPayload = normalizeCourtRecordPayload(payload);
    if (normalizedPayload) showCourtRecordWindow(normalizedPayload);
  });

  ipcMain.on("close-court-record", (event) => {
    if (isPetSender(event) || isCourtRecordSender(event)) courtRecordWindow?.close();
  });

  ipcMain.on("scatter-accessories", (event) => {
    if (!isPetSender(event)) return;
    scatterAccessories();
  });

  ipcMain.on("cancel-accessories", (event) => {
    if (!isPetSender(event)) return;
    finishAccessorySession("cancelled", true);
  });

  ipcMain.on("reclaim-accessory", (event, payload) => {
    const entry = accessoryWindows.get(event.sender.id);
    if (!entry || payload?.sessionId !== entry.sessionId || payload?.kind !== entry.kind) return;
    reclaimAccessory(event.sender.id, entry);
  });

  ipcMain.on("quit-app", (event) => {
    if (isPetSender(event)) app.quit();
  });

  ipcMain.on("renderer-ready", (event) => {
    if (isPetSender(event)) rendererReady = true;
  });
}

function showCourtRecordWindow(payload) {
  courtRecordPayload = payload;
  if (courtRecordWindow && !courtRecordWindow.isDestroyed()) {
    courtRecordWindow.webContents.send("court-record-data", courtRecordPayload);
    courtRecordWindow.showInactive();
    return;
  }

  if (!petWindow || petWindow.isDestroyed()) return;
  const ownerBounds = petWindow.getBounds();
  const area = screen.getDisplayMatching(ownerBounds).workArea;
  const panelWidth = 430;
  const panelHeight = 520;
  let x = ownerBounds.x - panelWidth - 14;
  if (x < area.x + 8) x = ownerBounds.x + ownerBounds.width + 14;
  x = Math.min(Math.max(x, area.x + 8), area.x + area.width - panelWidth - 8);
  const y = Math.min(
    Math.max(Math.round(ownerBounds.y + ownerBounds.height / 2 - panelHeight / 2), area.y + 8),
    area.y + area.height - panelHeight - 8,
  );

  const window = new BrowserWindow({
    width: panelWidth,
    height: panelHeight,
    x,
    y,
    useContentSize: true,
    title: "法庭记录",
    resizable: false,
    maximizable: false,
    minimizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    autoHideMenuBar: true,
    show: false,
    webPreferences: {
      preload: preloadPath,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      devTools: false,
    },
  });
  courtRecordWindow = window;
  window.setAlwaysOnTop(true, "floating");
  window.setMenuBarVisibility(false);
  window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  window.webContents.on("will-navigate", (event) => event.preventDefault());
  window.webContents.on("did-finish-load", () => {
    window.webContents.send("court-record-data", courtRecordPayload);
  });
  window.once("ready-to-show", () => window.showInactive());
  window.on("closed", () => {
    courtRecordWindow = undefined;
    courtRecordPayload = undefined;
    sendToPet("court-record-closed", {});
  });
  window.loadFile(path.join(rendererDirectory, "court-record.html"));
}

function showContextMenu(state) {
  const sendCommand = (command, value) => sendToPet("menu-command", { command, value });
  const actionItem = (value, label) => ({
    label,
    click: () => sendCommand("action", value),
  });
  const startupEnabled = app.getLoginItemSettings().openAtLogin;
  const activity = ["focused", "balanced", "lively"].includes(state.activity)
    ? state.activity
    : "balanced";
  const quietUntil = Number.isFinite(state.quietUntil) && state.quietUntil > Date.now()
    ? state.quietUntil
    : 0;
  const quietRemainingMinutes = Math.max(1, Math.ceil((quietUntil - Date.now()) / 60_000));
  const template = [
    actionItem("objection", "异议！"),
    actionItem("slam", "拍桌"),
    actionItem("think", "思考案情"),
    actionItem("sweat", "紧张冒汗"),
    actionItem("evidence", "查看证物"),
    actionItem("idle", "恢复站立"),
    { type: "separator" },
    actionItem("badge-toss", "甩出律师徽章"),
    actionItem("magatama", "勾玉与心灵枷锁"),
    actionItem("stepladder", "梯子还是人字梯"),
    actionItem("thinker", "出示“思考者”"),
    actionItem("decisive-evidence", "决定性证据"),
    actionItem("flashlight", "打开手电筒"),
    { type: "separator" },
    { label: "随机动作", click: () => sendCommand("random") },
    { label: "操作提示", click: () => sendCommand("help") },
    { label: "开始交叉询问", click: () => sendCommand("cross-examination") },
    {
      label: "陪伴节奏",
      submenu: [
        { label: "专注（无自动动作）", type: "radio", checked: activity === "focused", click: () => sendCommand("activity", "focused") },
        { label: "轻陪伴", type: "radio", checked: activity === "balanced", click: () => sendCommand("activity", "balanced") },
        { label: "活跃", type: "radio", checked: activity === "lively", click: () => sendCommand("activity", "lively") },
        { type: "separator" },
        quietUntil
          ? { label: `取消安静（剩余约 ${quietRemainingMinutes} 分钟）`, click: () => sendCommand("quiet-cancel") }
          : { label: "安静 30 分钟", click: () => sendCommand("quiet-start") },
      ],
    },
    { type: "separator" },
    { label: "法庭记录…", click: () => sendCommand("court-record") },
    { type: "separator" },
    {
      label: "开机自动启动",
      type: "checkbox",
      checked: startupEnabled,
      click: (item) => app.setLoginItemSettings({ openAtLogin: item.checked }),
    },
    { label: "退出桌宠", click: () => app.quit() },
  ];

  const menu = Menu.buildFromTemplate(template);
  menu.popup({ window: petWindow, callback: () => sendToPet("menu-closed", {}) });
}

function scatterAccessories() {
  if (!petWindow || petWindow.isDestroyed()) return;
  finishAccessorySession("replaced", true);
  accessorySequence += 1;
  activeAccessorySession = accessorySequence;
  reclaimedAccessories = new Set();
  const sessionId = activeAccessorySession;
  const area = screen.getDisplayMatching(petWindow.getBounds()).workArea;
  const petBounds = petWindow.getBounds();

  sendToPet("accessory-event", { type: "started", sessionId, kinds: accessoryKinds });
  accessoryKinds.forEach((kind) => {
    const image = nativeImage.createFromPath(path.join(assetRoot(), accessoryAssetNames[kind]));
    const imageSize = image.getSize();
    const longSide = randomBetween(26, 42);
    const aspect = imageSize.width / Math.max(1, imageSize.height);
    const width = Math.max(4, Math.round(aspect >= 1 ? longSide : longSide * aspect));
    const height = Math.max(4, Math.round(aspect >= 1 ? longSide / aspect : longSide));
    const x = Math.round(clamp(
      petBounds.x + petBounds.width / 2 + randomBetween(-18, 18),
      area.x,
      area.x + area.width - width,
    ));
    const y = Math.round(clamp(
      petBounds.y + petBounds.height / 2 + randomBetween(-22, 12) - height,
      area.y,
      area.y + area.height - height,
    ));
    const window = new BrowserWindow({
      width,
      height,
      x,
      y,
      transparent: true,
      frame: false,
      resizable: false,
      skipTaskbar: true,
      alwaysOnTop: true,
      focusable: false,
      hasShadow: false,
      backgroundColor: "#00000000",
      show: false,
      webPreferences: {
        preload: preloadPath,
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        devTools: false,
      },
    });
    const webContentsId = window.webContents.id;
    const horizontalMagnitude = randomBetween(125, 285);
    const entry = {
      window,
      kind,
      sessionId,
      workArea: area,
      physics: {
        x,
        y,
        width,
        height,
        velocityX: horizontalMagnitude * (Math.random() < 0.5 ? -1 : 1),
        velocityY: -randomBetween(185, 335),
        restitution: randomBetween(0.34, 0.52),
        landed: false,
        restingDuration: 0,
      },
      sleeping: false,
    };
    accessoryWindows.set(webContentsId, entry);
    window.setIgnoreMouseEvents(true);
    window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
    window.once("ready-to-show", () => window.showInactive());
    window.on("closed", () => {
      clearAccessoryEntryTimers(entry);
      destroyAccessoryTrail(entry);
      if (accessoryWindows.delete(webContentsId) && accessoryWindows.size === 0) {
        finishAccessorySession("faded", true);
      }
    });
    window.loadFile(path.join(rendererDirectory, "accessory.html"), {
      query: { kind, sessionId: String(sessionId) },
    });
  });
  startAccessoryPhysics();
}

function reclaimAccessory(webContentsId, entry) {
  if (entry.sessionId !== activeAccessorySession || entry.reclaiming || !entry.physics?.landed) return;
  const motion = ACCESSORY_MOTIONS[entry.kind];
  if (!motion || entry.window.isDestroyed() || !petWindow || petWindow.isDestroyed()) return;
  entry.reclaiming = true;
  entry.sleeping = true;
  clearTimeout(entry.fadeTimer);
  clearTimeout(entry.fadeDestroyTimer);
  entry.fadeTimer = undefined;
  entry.fadeDestroyTimer = undefined;
  reclaimedAccessories.add(entry.kind);
  sendToPet("accessory-event", {
    type: "reclaimed",
    sessionId: entry.sessionId,
    kind: entry.kind,
    count: reclaimedAccessories.size,
  });
  entry.window.setIgnoreMouseEvents(true);
  entry.window.webContents.send("accessory-reclaim-start", {
    kind: entry.kind,
    durationMs: motion.durationMs,
  });

  const startBounds = entry.window.getBounds();
  const petBounds = petWindow.getBounds();
  const area = screen.getDisplayMatching(startBounds).workArea;
  const start = {
    x: startBounds.x + startBounds.width / 2,
    y: startBounds.y + startBounds.height / 2,
  };
  const destination = {
    x: clamp(petBounds.x + petBounds.width / 2 + 28, area.x + startBounds.width / 2, area.x + area.width - startBounds.width / 2),
    y: clamp(petBounds.y + petBounds.height - 108, area.y + startBounds.height / 2, area.y + area.height - startBounds.height / 2),
  };
  entry.trailWindow = createAccessoryTrailWindow(entry, area);
  const startedAt = performance.now();
  entry.reclaimTimer = setInterval(() => {
    if (entry.window.isDestroyed() || entry.sessionId !== activeAccessorySession) {
      clearInterval(entry.reclaimTimer);
      entry.reclaimTimer = undefined;
      return;
    }
    const progress = Math.min(1, (performance.now() - startedAt) / motion.durationMs);
    const point = accessoryMotionPosition(entry.kind, start, destination, progress);
    const x = clamp(Math.round(point.x - startBounds.width / 2), area.x, area.x + area.width - startBounds.width);
    const y = clamp(Math.round(point.y - startBounds.height / 2), area.y, area.y + area.height - startBounds.height);
    entry.window.setPosition(x, y, false);
    updateAccessoryTrail(entry, area, start, destination, progress);
    if (progress < 1) return;

    clearInterval(entry.reclaimTimer);
    entry.reclaimTimer = undefined;
    accessoryWindows.delete(webContentsId);
    destroyAccessoryTrail(entry);
    entry.window.destroy();
    if (accessoryWindows.size === 0) finishAccessorySession("completed", true);
  }, 16);
  entry.reclaimTimer.unref?.();
}

function finishAccessorySession(reason, notify) {
  stopAccessoryPhysics();
  const sessionId = activeAccessorySession;
  const reclaimed = [...reclaimedAccessories];
  const entries = [...accessoryWindows.values()];
  accessoryWindows.clear();
  activeAccessorySession = undefined;
  reclaimedAccessories = new Set();
  for (const entry of entries) {
    clearAccessoryEntryTimers(entry);
    destroyAccessoryTrail(entry);
    if (!entry.window.isDestroyed()) entry.window.destroy();
  }
  if (notify && sessionId !== undefined) {
    sendToPet("accessory-event", { type: "finished", sessionId, reason, reclaimed });
  }
}

function startAccessoryPhysics() {
  stopAccessoryPhysics();
  lastAccessoryPhysicsTime = performance.now();
  accessoryPhysicsTimer = setInterval(() => {
    const now = performance.now();
    const delta = (now - lastAccessoryPhysicsTime) / 1_000;
    lastAccessoryPhysicsTime = now;
    let hasMovingItem = false;

    for (const entry of accessoryWindows.values()) {
      if (entry.reclaiming || entry.sleeping || entry.window.isDestroyed()) continue;
      hasMovingItem = true;
      const result = stepAccessoryPhysics(entry.physics, entry.workArea ?? screen.getDisplayMatching(entry.window.getBounds()).workArea, delta);
      entry.physics = result.state;
      entry.window.setPosition(Math.round(result.state.x), Math.round(result.state.y), false);
      if (result.justLanded) entry.window.setIgnoreMouseEvents(false);
      if (result.sleeping) {
        entry.sleeping = true;
        scheduleAccessoryFade(entry);
      }
    }
    if (!hasMovingItem || [...accessoryWindows.values()].every((entry) => entry.sleeping || entry.reclaiming)) {
      stopAccessoryPhysics();
    }
  }, 16);
  accessoryPhysicsTimer.unref?.();
}

function stopAccessoryPhysics() {
  if (accessoryPhysicsTimer) clearInterval(accessoryPhysicsTimer);
  accessoryPhysicsTimer = undefined;
  lastAccessoryPhysicsTime = undefined;
}

function scheduleAccessoryFade(entry) {
  if (entry.fadeTimer || entry.reclaiming) return;
  entry.fadeTimer = setTimeout(() => {
    entry.fadeTimer = undefined;
    if (entry.reclaiming || entry.window.isDestroyed()
        || entry.sessionId !== activeAccessorySession) return;
    entry.window.setIgnoreMouseEvents(true);
    entry.window.webContents.send("accessory-fade", { kind: entry.kind });
    entry.fadeDestroyTimer = setTimeout(() => {
      entry.fadeDestroyTimer = undefined;
      const webContentsId = entry.window.webContents.id;
      accessoryWindows.delete(webContentsId);
      if (!entry.window.isDestroyed()) entry.window.destroy();
      if (accessoryWindows.size === 0) finishAccessorySession("faded", true);
    }, 650);
  }, randomBetween(8_000, 12_000));
  entry.fadeTimer.unref?.();
}

function clearAccessoryEntryTimers(entry) {
  if (entry.reclaimTimer) clearInterval(entry.reclaimTimer);
  clearTimeout(entry.fadeTimer);
  clearTimeout(entry.fadeDestroyTimer);
  entry.reclaimTimer = undefined;
  entry.fadeTimer = undefined;
  entry.fadeDestroyTimer = undefined;
}

function createAccessoryTrailWindow(entry, area) {
  const window = new BrowserWindow({
    width: area.width,
    height: area.height,
    x: area.x,
    y: area.y,
    useContentSize: true,
    transparent: true,
    frame: false,
    resizable: false,
    maximizable: false,
    minimizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    focusable: false,
    hasShadow: false,
    backgroundColor: "#00000000",
    show: false,
    webPreferences: {
      preload: preloadPath,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      devTools: false,
    },
  });
  window.setAlwaysOnTop(true, "floating");
  window.setIgnoreMouseEvents(true);
  window.setMenuBarVisibility(false);
  window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  window.webContents.on("will-navigate", (event) => event.preventDefault());
  window.webContents.on("did-finish-load", () => {
    if (entry.trailPayload && !window.isDestroyed()) {
      window.webContents.send("accessory-trail-update", entry.trailPayload);
    }
  });
  window.once("ready-to-show", () => window.showInactive());
  window.on("closed", () => {
    if (entry.trailWindow === window) entry.trailWindow = undefined;
  });
  window.loadFile(path.join(rendererDirectory, "accessory-trail.html"), {
    query: { kind: entry.kind },
  });
  return window;
}

function updateAccessoryTrail(entry, area, start, destination, animationProgress) {
  const motion = ACCESSORY_MOTIONS[entry.kind];
  if (!motion) return;
  const headProgress = easedProgress(animationProgress);
  const startProgress = Math.max(0, headProgress - motion.trailFraction);
  const segmentCount = Math.max(3, Math.ceil((headProgress - startProgress) * 96));
  const points = [];
  for (let index = 0; index <= segmentCount; index += 1) {
    const fraction = index / segmentCount;
    const progress = startProgress + (headProgress - startProgress) * fraction;
    const point = accessoryPathPosition(entry.kind, start, destination, progress);
    points.push({
      x: point.x - area.x,
      y: point.y - area.y,
      progress,
    });
  }
  entry.trailPayload = { kind: entry.kind, points, animationProgress };
  if (entry.trailWindow && !entry.trailWindow.isDestroyed()) {
    entry.trailWindow.webContents.send("accessory-trail-update", entry.trailPayload);
  }
}

function destroyAccessoryTrail(entry) {
  entry.trailPayload = undefined;
  if (entry.trailWindow && !entry.trailWindow.isDestroyed()) entry.trailWindow.destroy();
  entry.trailWindow = undefined;
}

function startThrow(initialVelocity) {
  stopThrow();
  if (!petWindow) return;
  const initialBounds = petWindow.getBounds();
  const targetArea = screen.getDisplayMatching(initialBounds).workArea;
  const bounds = {
    ...initialBounds,
    x: clamp(initialBounds.x, targetArea.x, targetArea.x + targetArea.width - initialBounds.width),
    y: clamp(initialBounds.y, targetArea.y, targetArea.y + targetArea.height - initialBounds.height),
  };
  petWindow.setPosition(Math.round(bounds.x), Math.round(bounds.y), false);
  throwState = createThrowState(bounds, initialVelocity);
  throwVisibleFrames = screen.getAllDisplays().map((display) => display.workArea);
  let lastTime = performance.now();
  let strongest = "light";
  sendToPet("motion-event", { type: "throw-start" });

  throwTimer = setInterval(() => {
    if (!petWindow || petWindow.isDestroyed() || !throwState) return stopThrow();
    const now = performance.now();
    const delta = (now - lastTime) / 1_000;
    lastTime = now;
    const result = stepThrowPhysics(throwState, throwVisibleFrames, delta);
    throwState = result.state;
    petWindow.setPosition(Math.round(throwState.x), Math.round(throwState.y), false);
    if (result.impact) {
      const { severity } = result.impact;
      if (severity === "heavy" || (severity === "medium" && strongest === "light")) strongest = severity;
      sendToPet("motion-event", { type: "bounce", severity });
    }

    if (result.shouldSettle || throwState.elapsed >= 4.5) {
      stopThrow();
      sendToPet("motion-event", { type: "settled", severity: strongest });
    }
  }, 16);
  throwTimer.unref?.();
}

function stopThrow() {
  if (throwTimer) clearInterval(throwTimer);
  throwTimer = undefined;
  throwState = undefined;
  throwVisibleFrames = [];
}

function sendToPet(channel, payload) {
  if (petWindow && !petWindow.isDestroyed()) petWindow.webContents.send(channel, payload);
}

function isPetSender(event) {
  return petWindow && !petWindow.isDestroyed() && event.sender.id === petWindow.webContents.id;
}

function assetRoot() {
  return app.isPackaged
    ? path.join(process.resourcesPath, "assets")
    : path.resolve(app.getAppPath(), "../Assets");
}

function isCourtRecordSender(event) {
  return courtRecordWindow
    && !courtRecordWindow.isDestroyed()
    && event.sender.id === courtRecordWindow.webContents.id;
}

function normalizeCourtRecordPayload(payload) {
  if (!payload || !Array.isArray(payload.entries) || payload.entries.length > 64) return undefined;
  const entries = [];
  for (const rawEntry of payload.entries) {
    if (!rawEntry || typeof rawEntry !== "object") return undefined;
    const definition = rawEntry.definition;
    if (!definition || typeof definition !== "object") return undefined;
    const normalizedDefinition = {};
    for (const key of ["id", "category", "icon", "title", "detail", "lockedHint"]) {
      if (typeof definition[key] !== "string" || definition[key].length > 240) return undefined;
      normalizedDefinition[key] = definition[key];
    }
    const progress = rawEntry.progress && typeof rawEntry.progress === "object"
      ? {
          count: Math.max(0, Math.min(Number(rawEntry.progress.count) || 0, Number.MAX_SAFE_INTEGER)),
          unlockedAt: Number(rawEntry.progress.unlockedAt) || 0,
          lastSeen: Number(rawEntry.progress.lastSeen) || 0,
        }
      : undefined;
    entries.push({ definition: normalizedDefinition, progress });
  }
  return { entries };
}

function validPoint(value) {
  return Number.isFinite(value?.x) && Number.isFinite(value?.y);
}

function clamp(value, minimum, maximum) {
  return Math.max(minimum, Math.min(maximum, value));
}

function randomBetween(minimum, maximum) {
  return minimum + Math.random() * (maximum - minimum);
}
