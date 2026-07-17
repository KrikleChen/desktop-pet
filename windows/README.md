# Windows 版

这是成步堂桌宠的 Electron/NSIS Windows 运行层。它与根目录的 Swift/AppKit macOS 代码并存，共用 `Assets/*-cg.png` 角色素材。

- `src/main.mjs`：透明窗口、拖动/甩飞、原生菜单、证物子窗口。
- `src/preload.cjs`：最小化且白名单化的 IPC API。
- `src/renderer/`：角色界面、小游戏和交互。
- `src/shared/game-models.mjs`：可在 Node.js 中直接测试的纯状态机。
- `tests/`：随机袋、交叉询问、有序归档、陪伴策略和摇动识别测试。

本地启动：

```powershell
npm ci
npm test
npm start
```

Windows 一键安装包：

```powershell
npm run dist:win
```
