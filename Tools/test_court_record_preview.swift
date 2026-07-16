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
        let recordID = CourtRecordID.action(.think)!

        CourtRecordActionRecorder.record(.think, in: store)
        let beforePreview = store.count(for: recordID)
        CourtRecordActionRecorder.record(.think, in: store, enabled: false)
        let afterPreview = store.count(for: recordID)

        precondition(beforePreview == 1, "真实思考动作应记录一次")
        precondition(afterPreview == beforePreview, "预览前后思考图鉴计数必须不变")
        print("图鉴预览隔离自检通过。")
    }
}
