import AppKit

@main
struct AccessoryReclaimMotionTestMain {
    static func main() {
        testStableKindsAndEvents()
        testMotionConfigurations()
        testNegativeScreenGeometry()
        testReclaimGate()
        testPreviewSessionBinding()
        print("六类道具回收轨迹纯几何/配置自检通过。")
    }

    private static func testStableKindsAndEvents() {
        let expected: [(kind: AccessoryKind, id: Int, name: String)] = [
            (.attorneyBadge, 0, "律师徽章"),
            (.caseFile, 1, "案件文件"),
            (.magatama, 2, "勾玉"),
            (.evidence, 3, "证物"),
            (.pen, 4, "笔"),
            (.stickyNote, 5, "便签")
        ]
        precondition(AccessoryKind.allCases.count == expected.count, "道具类型数量必须稳定为六类")

        for entry in expected {
            precondition(entry.kind.rawValue == entry.id, "道具 rawValue 顺序发生变化")
            precondition(entry.kind.displayName == entry.name, "道具显示名与稳定槽位不匹配")
            precondition(AccessoryKind(rawValue: entry.id) == entry.kind, "id 无法还原道具类型")
            precondition(
                AccessoryReclaimEvent(kind: entry.kind) == AccessoryReclaimEvent(
                    kind: entry.kind,
                    id: entry.id
                ),
                "默认事件 id 必须等于稳定槽位 id"
            )
        }
    }

    private static func testMotionConfigurations() {
        let motions = AccessoryKind.allCases.map(\.reclaimMotion)
        for motion in motions {
            precondition(
                (0.45...0.75).contains(motion.duration),
                "所有回收动画必须在 0.45～0.75 秒内完成"
            )
            precondition((0...1).contains(motion.trailFraction), "尾迹长度比例必须有效")
        }

        for leftIndex in motions.indices {
            for rightIndex in motions.indices where rightIndex > leftIndex {
                precondition(
                    motions[leftIndex].curve != motions[rightIndex].curve,
                    "六类道具必须使用不同曲线"
                )
                precondition(
                    motions[leftIndex].trailStyle != motions[rightIndex].trailStyle,
                    "六类道具必须使用不同尾迹形态"
                )
            }
        }

        precondition(
            abs(AccessoryKind.pen.reclaimMotion.rotationTurns) > 1,
            "笔应采用清晰但克制的旋入"
        )
        precondition(
            AccessoryKind.stickyNote.reclaimMotion.swingAmplitude
                > AccessoryKind.attorneyBadge.reclaimMotion.swingAmplitude,
            "便签摆动应明显强于徽章"
        )
    }

    private static func testNegativeScreenGeometry() {
        let visibleFrame = NSRect(x: -1_920, y: 24, width: 1_920, height: 1_031)
        let itemSize = NSSize(width: 40, height: 30)
        let start = NSPoint(x: -1_865, y: 65)
        let destinationOrigin = AccessoryReclaimGeometry.destinationOrigin(
            itemSize: itemSize,
            near: NSPoint(x: 80, y: 1_200),
            inside: visibleFrame
        )
        let destination = NSPoint(
            x: destinationOrigin.x + itemSize.width * 0.5,
            y: destinationOrigin.y + itemSize.height * 0.5
        )

        var midpoints: [NSPoint] = []
        for kind in AccessoryKind.allCases {
            let samples = AccessoryReclaimGeometry.sampledCenters(
                from: start,
                to: destination,
                itemSize: itemSize,
                inside: visibleFrame,
                motion: kind.reclaimMotion,
                sampleCount: 81
            )
            precondition(samples.count == 81, "轨迹采样数量错误")
            requireNear(samples[0], start, message: "轨迹必须从道具当前位置开始")
            requireNear(samples[samples.count - 1], destination, message: "轨迹必须到达当前回收坐标")

            for point in samples {
                precondition(point.x >= visibleFrame.minX + itemSize.width * 0.5)
                precondition(point.x <= visibleFrame.maxX - itemSize.width * 0.5)
                precondition(point.y >= visibleFrame.minY + itemSize.height * 0.5)
                precondition(point.y <= visibleFrame.maxY - itemSize.height * 0.5)
            }
            midpoints.append(AccessoryReclaimGeometry.interpolatedCenter(in: samples, progress: 0.5))
        }

        for leftIndex in midpoints.indices {
            for rightIndex in midpoints.indices where rightIndex > leftIndex {
                let delta = hypot(
                    midpoints[leftIndex].x - midpoints[rightIndex].x,
                    midpoints[leftIndex].y - midpoints[rightIndex].y
                )
                precondition(delta > 0.5, "六类曲线的中段形态不应重合")
            }
        }

        precondition(AccessoryReclaimGeometry.easedProgress(-1) == 0)
        precondition(AccessoryReclaimGeometry.easedProgress(0) == 0)
        precondition(AccessoryReclaimGeometry.easedProgress(1) == 1)
        precondition(AccessoryReclaimGeometry.easedProgress(2) == 1)
    }

    private static func testReclaimGate() {
        var state = AccessoryReclaimState()
        precondition(!state.beginReclaim(), "道具落地前不可点击回收")
        precondition(state.markLanded(), "首次落地应打开回收门闩")
        precondition(!state.markLanded(), "落地事件必须幂等")
        precondition(state.beginReclaim(), "首次落地后点击应开始回收")
        precondition(!state.beginReclaim(), "重复点击不得重复回收")
    }

    private static func testPreviewSessionBinding() {
        var sessions = AccessoryScatterSessionState()
        let oldSessionID = sessions.beginSession()
        let currentSessionID = sessions.beginSession()
        var currentItemState = AccessoryReclaimState()
        precondition(currentItemState.markLanded())

        precondition(oldSessionID < currentSessionID)
        precondition(
            !sessions.permitsPreviewReclaim(
                requestedSessionID: oldSessionID,
                itemSessionID: currentSessionID,
                reclaimState: currentItemState
            ),
            "旧预览任务不得跨轮触发任一道具的回收轨迹"
        )
        precondition(
            sessions.permitsPreviewReclaim(
                requestedSessionID: currentSessionID,
                itemSessionID: currentSessionID,
                reclaimState: currentItemState
            ),
            "当前轮已落地道具应可进入对应回收轨迹"
        )
        precondition(currentItemState.beginReclaim())
        precondition(
            !sessions.permitsPreviewReclaim(
                requestedSessionID: currentSessionID,
                itemSessionID: currentSessionID,
                reclaimState: currentItemState
            ),
            "同一 token 也不得重复启动回收"
        )
    }

    private static func requireNear(_ actual: NSPoint, _ expected: NSPoint, message: String) {
        precondition(
            abs(actual.x - expected.x) < 0.001 && abs(actual.y - expected.y) < 0.001,
            message
        )
    }
}
