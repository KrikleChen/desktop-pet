# 成步堂桌宠

成步堂龙一主题的透明桌面宠物，现同时维护 macOS 原生版和 Windows 安装版。

## Windows 10 / 11

最简单的安装方式：

1. 打开仓库右侧的 **Releases**。
2. 下载 `Chengbutang-Desktop-Pet-*-Setup.exe`。
3. 双击安装；安装完成后桌宠会自动启动，并创建桌面和开始菜单快捷方式。

目前安装包未购买商业代码签名证书。如果 Windows SmartScreen 首次提示“已保护你的电脑”，请确认文件来自本仓库，然后选择“更多信息”→“仍要运行”。

Windows 版包含：

- 透明置顶桌宠、单击/双击动作和原生右键菜单；
- 鼠标拖动、快速甩飞、碰撞和恢复；
- 六件桌面证物、有序归档和完整证据链奖励；
- 三句式交叉询问小游戏；
- 法庭记录、专注/轻陪伴/活跃及安静 30 分钟；
- 可选开机启动。

Windows 版不会读取聊天软件、剪贴板、键盘输入或网络内容，也不需要辅助功能权限。

### Windows 开发与打包

```powershell
cd windows
npm ci
npm test
npm start
npm run dist:win
```

`npm run dist:win` 会生成一键安装的 NSIS `Setup.exe`。仓库的 GitHub Actions 会在 Windows runner 上自动构建；推送 `v*` 标签时，安装包还会自动发布到 GitHub Releases。

## macOS

macOS 版使用 Swift/AppKit：

```bash
./build.sh
open build/成步堂桌宠.app
```

部分背景感知或聊天名字监听能力可能需要在系统设置中单独授权；这些能力不属于 Windows 版。
