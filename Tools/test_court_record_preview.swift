import AppKit
import Foundation

@main
struct CourtRecordPreviewTestMain {
    static func main() {
        let suiteName = "com.ymatrix.phoenix-desktop-pet.preview-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("无法创建隔离的图鉴测试存储")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CourtRecordStore(defaults: defaults)
        let previewActions: [PetAction] = [
            .think,
            .badgeToss,
            .evidence,
            .magatama,
            .decisiveEvidence,
        ]
        for action in previewActions {
            guard let recordID = CourtRecordID.action(action) else {
                preconditionFailure("验收动作缺少图鉴 ID：\(action.rawValue)")
            }
            CourtRecordActionRecorder.record(action, in: store)
            let beforePreview = store.count(for: recordID)
            CourtRecordActionRecorder.record(action, in: store, enabled: false)
            let afterPreview = store.count(for: recordID)

            precondition(beforePreview == 1, "真实动作应记录一次：\(action.rawValue)")
            precondition(
                afterPreview == beforePreview,
                "验收预览不得改变图鉴计数：\(action.rawValue)"
            )
        }

        testAccessoryPreviewLifecycle()
        print("图鉴预览隔离与道具预览生命周期自检通过。")
    }

    private static func testAccessoryPreviewLifecycle() {
        var lifecycle = AccessoryPreviewLifecycleState()

        let oldPreview = lifecycle.begin()
        let currentPreview = lifecycle.begin()
        precondition(!lifecycle.isCurrent(oldPreview), "新预览必须使旧延迟任务失效")
        precondition(lifecycle.isCurrent(currentPreview), "最新预览应持有生命周期")
        precondition(
            !lifecycle.finish(
                previewID: oldPreview,
                belongsToControllerSession: true,
                isPreviewDragging: true
            ),
            "旧预览完成事件不得恢复新预览的画面"
        )
        precondition(lifecycle.isCurrent(currentPreview), "旧完成事件不得消费新预览")

        precondition(
            !lifecycle.finish(
                previewID: currentPreview,
                belongsToControllerSession: false,
                isPreviewDragging: true
            ),
            "控制器 session 不匹配时不得恢复 idle"
        )
        precondition(lifecycle.isCurrent(currentPreview), "无关控制器完成事件不得消费预览")

        precondition(
            !lifecycle.finish(
                previewID: currentPreview,
                belongsToControllerSession: true,
                isPreviewDragging: false
            ),
            "用户后续动作已改变状态时不得覆盖为 idle"
        )
        precondition(lifecycle.activePreviewID == nil, "匹配的完成事件仍应结束生命周期")

        let naturallyFinishedPreview = lifecycle.begin()
        precondition(
            lifecycle.finish(
                previewID: naturallyFinishedPreview,
                belongsToControllerSession: true,
                isPreviewDragging: true
            ),
            "自然淡出或最后一件回收后应允许恢复预览拖拽状态"
        )

        let cancelledPreview = lifecycle.begin()
        precondition(lifecycle.cancel(cancelledPreview), "显式取消应结束当前预览")
        precondition(!lifecycle.cancel(cancelledPreview), "重复取消不得影响后续状态")

        let rightClickPreview = lifecycle.begin()
        precondition(
            lifecycle.cancelAndShouldRestore(
                previewID: rightClickPreview,
                belongsToControllerSession: true,
                isPreviewDragging: true
            ),
            "右键仅打开菜单时应从仍归属当前 session 的预览拖拽恢复 idle"
        )
        precondition(lifecycle.activePreviewID == nil, "右键取消后应结束预览 lifecycle")

        let replacedByUserAction = lifecycle.begin()
        precondition(
            !lifecycle.cancelAndShouldRestore(
                previewID: replacedByUserAction,
                belongsToControllerSession: true,
                isPreviewDragging: false
            ),
            "用户动作已切换状态时不得被取消预览覆盖为 idle"
        )
        precondition(
            lifecycle.activePreviewID == nil,
            "用户动作已切换时仍应结束匹配的预览 lifecycle"
        )
    }
}
