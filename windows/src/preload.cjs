const { contextBridge, ipcRenderer } = require("electron");

function subscribe(channel, listener) {
  const wrapped = (_event, payload) => listener(payload);
  ipcRenderer.on(channel, wrapped);
  return () => ipcRenderer.removeListener(channel, wrapped);
}

contextBridge.exposeInMainWorld("desktopPet", {
  platform: process.platform,
  assetUrl: (fileName) => ipcRenderer.invoke("asset-url", fileName),
  assetMask: (fileName) => ipcRenderer.invoke("asset-mask", fileName),
  edgeContext: () => ipcRenderer.invoke("edge-context"),
  dragStart: (x, y) => ipcRenderer.send("drag-start", { x, y }),
  dragMove: (x, y) => ipcRenderer.send("drag-move", { x, y }),
  dragEnd: (x, y) => ipcRenderer.send("drag-end", { x, y }),
  showContextMenu: (state) => ipcRenderer.send("show-context-menu", state),
  showCourtRecord: (payload) => ipcRenderer.send("show-court-record", payload),
  closeCourtRecord: () => ipcRenderer.send("close-court-record"),
  scatterAccessories: () => ipcRenderer.send("scatter-accessories"),
  cancelAccessories: () => ipcRenderer.send("cancel-accessories"),
  reclaimAccessory: (sessionId, kind) => ipcRenderer.send("reclaim-accessory", { sessionId, kind }),
  quit: () => ipcRenderer.send("quit-app"),
  rendererReady: () => ipcRenderer.send("renderer-ready"),
  onMenuCommand: (listener) => subscribe("menu-command", listener),
  onMenuClosed: (listener) => subscribe("menu-closed", listener),
  onMotionEvent: (listener) => subscribe("motion-event", listener),
  onAccessoryEvent: (listener) => subscribe("accessory-event", listener),
  onAccessoryReclaimStart: (listener) => subscribe("accessory-reclaim-start", listener),
  onCourtRecordData: (listener) => subscribe("court-record-data", listener),
  onCourtRecordClosed: (listener) => subscribe("court-record-closed", listener),
});
