import { app, BrowserWindow, ipcMain, Menu, nativeImage, screen } from "electron";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

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

let petWindow;
let courtRecordWindow;
let courtRecordPayload;
let dragState;
let throwTimer;
let accessorySequence = 0;
let activeAccessorySession;
let accessoryTimeout;
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
      sendToPet("motion-event", { type: "settled", severity: "light" });
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
  const positions = accessoryPositions(area, petWindow.getBounds(), accessoryKinds.length);

  sendToPet("accessory-event", { type: "started", sessionId, kinds: accessoryKinds });
  accessoryKinds.forEach((kind, index) => {
    const position = positions[index];
    const window = new BrowserWindow({
      width: 72,
      height: 72,
      x: position.x,
      y: position.y,
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
    const entry = { window, kind, sessionId };
    accessoryWindows.set(webContentsId, entry);
    window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
    window.once("ready-to-show", () => window.showInactive());
    window.on("closed", () => {
      if (accessoryWindows.delete(webContentsId) && accessoryWindows.size === 0) {
        finishAccessorySession("faded", true);
      }
    });
    window.loadFile(path.join(rendererDirectory, "accessory.html"), {
      query: { kind, sessionId: String(sessionId) },
    });
  });

  accessoryTimeout = setTimeout(() => finishAccessorySession("timeout", true), 15_000);
}

function reclaimAccessory(webContentsId, entry) {
  if (entry.sessionId !== activeAccessorySession) return;
  accessoryWindows.delete(webContentsId);
  reclaimedAccessories.add(entry.kind);
  sendToPet("accessory-event", {
    type: "reclaimed",
    sessionId: entry.sessionId,
    kind: entry.kind,
    count: reclaimedAccessories.size,
  });
  if (!entry.window.isDestroyed()) entry.window.destroy();
  if (accessoryWindows.size === 0) finishAccessorySession("completed", true);
}

function finishAccessorySession(reason, notify) {
  if (accessoryTimeout) clearTimeout(accessoryTimeout);
  accessoryTimeout = undefined;
  const sessionId = activeAccessorySession;
  const reclaimed = [...reclaimedAccessories];
  const windows = [...accessoryWindows.values()].map((entry) => entry.window);
  accessoryWindows.clear();
  activeAccessorySession = undefined;
  reclaimedAccessories = new Set();
  for (const window of windows) {
    if (!window.isDestroyed()) window.destroy();
  }
  if (notify && sessionId !== undefined) {
    sendToPet("accessory-event", { type: "finished", sessionId, reason, reclaimed });
  }
}

function startThrow(initialVelocity) {
  stopThrow();
  if (!petWindow) return;
  let velocityX = initialVelocity.x;
  let velocityY = initialVelocity.y;
  let lastTime = performance.now();
  let elapsed = 0;
  let strongest = "light";
  sendToPet("motion-event", { type: "throw-start" });

  throwTimer = setInterval(() => {
    if (!petWindow || petWindow.isDestroyed()) return stopThrow();
    const now = performance.now();
    const delta = Math.min(0.035, (now - lastTime) / 1_000);
    lastTime = now;
    elapsed += delta;
    const bounds = petWindow.getBounds();
    const area = screen.getDisplayMatching(bounds).workArea;
    let x = bounds.x + velocityX * delta;
    let y = bounds.y + velocityY * delta;
    velocityY += 1_650 * delta;
    velocityX *= Math.pow(0.55, delta);
    let impactSpeed = 0;

    if (x < area.x || x + bounds.width > area.x + area.width) {
      x = Math.max(area.x, Math.min(x, area.x + area.width - bounds.width));
      impactSpeed = Math.max(impactSpeed, Math.abs(velocityX));
      velocityX *= -0.38;
    }
    if (y < area.y || y + bounds.height > area.y + area.height) {
      y = Math.max(area.y, Math.min(y, area.y + area.height - bounds.height));
      impactSpeed = Math.max(impactSpeed, Math.abs(velocityY));
      velocityY *= -0.26;
      velocityX *= 0.72;
    }

    petWindow.setPosition(Math.round(x), Math.round(y), false);
    if (impactSpeed > 0) {
      const severity = impactSpeed > 1_250 ? "heavy" : impactSpeed > 650 ? "medium" : "light";
      if (severity === "heavy" || (severity === "medium" && strongest === "light")) strongest = severity;
      sendToPet("motion-event", { type: "bounce", severity });
    }

    const onFloor = Math.abs(y + bounds.height - (area.y + area.height)) < 2;
    if ((onFloor && Math.hypot(velocityX, velocityY) < 190) || elapsed > 4.5) {
      stopThrow();
      sendToPet("motion-event", { type: "settled", severity: strongest });
    }
  }, 16);
  throwTimer.unref?.();
}

function stopThrow() {
  if (throwTimer) clearInterval(throwTimer);
  throwTimer = undefined;
}

function accessoryPositions(area, petBounds, count) {
  const points = [
    [0.16, 0.22], [0.42, 0.14], [0.70, 0.24],
    [0.22, 0.62], [0.52, 0.72], [0.80, 0.58],
  ];
  return points.slice(0, count).map(([xRatio, yRatio], index) => {
    let x = Math.round(area.x + xRatio * (area.width - 72));
    let y = Math.round(area.y + yRatio * (area.height - 72));
    if (Math.abs(x - petBounds.x) < 110 && Math.abs(y - petBounds.y) < 160) {
      x = Math.round(area.x + ((xRatio + 0.36 + index * 0.07) % 0.9) * (area.width - 72));
    }
    return { x, y };
  });
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
