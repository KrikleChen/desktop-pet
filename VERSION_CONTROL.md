# 版本控制审计记录

更新时间：2026-07-16（Asia/Shanghai）

## 分支用途

- `main`：仅接收通过完整构建与交互验收的可发布版本；当前尚未创建。
- `integration/desktop-pet`：保存并发开发中的完整集成快照；当前首次检查点位于此分支。
- `feature/*`：后续用于隔离未完成、构建失败或存在冲突的单项功能。

## 基线审计

- 远端 `origin`：`https://github.com/KrikleChen/-.git`；首次 fetch 时无分支或标签，属于空仓库。
- 纳管范围：20 个 Swift 源文件、3 个 Swift 工具脚本、50 个 PNG 原始/处理后资产、`Info.plist`、`build.sh` 与项目文档。
- 排除范围：`build/`、Swift/Xcode 可再生构建状态、系统元数据、日志和临时文件。
- 敏感信息扫描未发现密钥、token、密码、私钥或本机绝对路径；非构建目录未发现超过 20 MiB 的文件。

## 构建门禁

构建命令：

```sh
./build.sh
```

当前结论：失败，不允许进入 `main`。2026-07-16 首次检查发现 `Sources/DailyCase.swift` 的条件编译自检含顶层表达式，Swift 编译器报 `expressions are not allowed at the top level`；同一次构建还检测到该文件被并发 worker 修改。此检查点只作为 WIP 集成基线。

## 待验收项

- 等待并发 worker 稳定 `DailyCase.swift` 与 `DailyCasePanelController.swift` 后重跑全工程构建。
- 逐项复审背景识别、差异化台词、图鉴、今日一案、待机追问、抛掷物理、倒吊散落、姓名监听。
- 核对运行时资源引用、关键交互回归和各功能 worker 的自测结论。
- 全工程构建和验收通过后，才可将集成分支合入并推送 `main`。
