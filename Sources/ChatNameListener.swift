import AppKit
import ApplicationServices

/// 通过 macOS 辅助功能 API 检测当前输入框中新出现的
/// “成步堂龙一”或“成步堂”。
///
/// 监听器只读取当前获得焦点、可编辑且非安全输入框的值。正文仅在一次轮询的
/// 局部变量中短暂存在；不会记录、持久化或联网发送。跨轮询只保留控件哈希和
/// “目标名字当前是否存在”的布尔值，用于避免重复触发。
@MainActor
final class ChatNameListener {
    enum Status: Equatable {
        /// 用户主动停止，或尚未调用 `start`。
        case stopped

        /// 已请求启动，但辅助功能权限尚未授予；监听器会自动等待授权。
        case waitingForPermission

        /// 权限有效，且当前焦点是支持的可编辑文本控件。
        case running

        /// 权限有效，但当前焦点不是受支持的普通可编辑文本控件。
        case unsupportedFocusedElement
    }

    /// 检测到目标名字从“不存在”变为“存在”时，在主线程调用。
    var onNameDetected: (() -> Void)?

    /// 状态或诊断原因变化时在主线程调用。
    ///
    /// 即使 `Status` 枚举值相同，只要 `lastDiagnostic` 发生变化也会回调，
    /// 方便界面更新气泡提示。
    var onStatusChanged: ((Status) -> Void)?

    /// 当前监听状态。
    private(set) var status: Status = .stopped

    /// 不包含输入正文的最近诊断信息，可直接用于界面提示。
    private(set) var lastDiagnostic: String?

    /// 是否已经获得权限并在轮询焦点控件。
    ///
    /// `unsupportedFocusedElement` 仍表示监听器正在运行，所以此值为 `true`。
    private(set) var isRunning = false

    private struct ElementKey: Hashable {
        let processID: pid_t
        let elementHash: CFHashCode
    }

    private struct Candidate {
        let element: AXUIElement
        let isDeclaredEditableAncestor: Bool
    }

    private enum Resolution {
        case supported(element: AXUIElement, text: String)
        case unsupported(diagnostic: String)
    }

    private let mentionDetector = ChatNameMentionDetector()
    private let pollInterval: TimeInterval
    private let permissionPollInterval: TimeInterval = 0.75
    private let systemWideElement = AXUIElementCreateSystemWide()
    private let maximumRememberedElements = 64
    private let maximumAncestorDepth = 10

    // Chromium 在 contenteditable 的焦点位于后代节点时提供这两个属性。
    // 它们不是当前 macOS SDK 的公开常量，因此按 Chromium 使用的 AX 名称访问。
    private let editableAncestorAttribute = "AXEditableAncestor"
    private let highestEditableAncestorAttribute = "AXHighestEditableAncestor"

    private var contentTimer: Timer?
    private var permissionTimer: Timer?
    private var wantsToRun = false
    private var targetPresenceByElement: [ElementKey: Bool] = [:]
    private var elementRecency: [ElementKey] = []

    init(pollInterval: TimeInterval = 0.35) {
        self.pollInterval = max(0.2, pollInterval)
    }

    deinit {
        contentTimer?.invalidate()
        permissionTimer?.invalidate()
    }

    /// 请求启动监听。
    ///
    /// 若权限弹窗出现后 API 暂时返回 `false`，监听器会进入
    /// `waitingForPermission` 并自动轮询授权状态；用户勾选本应用后会自动启动，
    /// 不需要再次点击菜单。
    ///
    /// - Parameter promptIfNeeded: 未授权时是否触发系统辅助功能权限提示。
    /// - Returns: 当前已经获得权限并开始轮询时为 `true`；正在等待授权时为
    ///   `false`。返回 `false` 不代表启动请求被取消。
    @discardableResult
    func start(promptIfNeeded: Bool = false) -> Bool {
        wantsToRun = true

        if AXIsProcessTrusted() {
            beginContentPollingIfNeeded()
            return true
        }

        if promptIfNeeded {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)

            // 授权可能在弹窗调用与此处之间完成。
            if AXIsProcessTrusted() {
                beginContentPollingIfNeeded()
                return true
            }
        }

        enterPermissionWaitingState()
        return false
    }

    /// 停止权限等待和正文轮询，并清除内存中的布尔/哈希去重状态。
    func stop() {
        wantsToRun = false
        permissionTimer?.invalidate()
        permissionTimer = nil
        contentTimer?.invalidate()
        contentTimer = nil
        isRunning = false
        clearDeduplicationState()
        updateStatus(.stopped, diagnostic: "名字监听已关闭。")
    }

    private func enterPermissionWaitingState() {
        contentTimer?.invalidate()
        contentTimer = nil
        isRunning = false
        updateStatus(
            .waitingForPermission,
            diagnostic: "等待辅助功能权限；勾选本应用后会自动开始监听。"
        )

        guard permissionTimer == nil else { return }
        let timer = Timer(timeInterval: permissionPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkPendingPermission()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func checkPendingPermission() {
        guard wantsToRun else {
            stop()
            return
        }
        guard AXIsProcessTrusted() else { return }
        beginContentPollingIfNeeded()
    }

    private func beginContentPollingIfNeeded() {
        permissionTimer?.invalidate()
        permissionTimer = nil

        guard wantsToRun else { return }

        if contentTimer == nil {
            clearDeduplicationState()
            let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pollFocusedTextElement()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            contentTimer = timer
        }

        isRunning = true
        updateStatus(.running, diagnostic: "名字监听正在运行。")
        pollFocusedTextElement()
    }

    private func pollFocusedTextElement() {
        guard wantsToRun else {
            stop()
            return
        }

        guard AXIsProcessTrusted() else {
            enterPermissionWaitingState()
            return
        }

        guard let focusedElement: AXUIElement = copyAttribute(
            kAXFocusedUIElementAttribute,
            from: systemWideElement
        ) else {
            updateStatus(
                .unsupportedFocusedElement,
                diagnostic: "当前没有可读取的输入焦点。"
            )
            return
        }

        switch resolveEditableTextElement(from: focusedElement) {
        case let .unsupported(diagnostic):
            updateStatus(.unsupportedFocusedElement, diagnostic: diagnostic)

        case let .supported(element, text):
            updateStatus(.running, diagnostic: "正在监听当前可编辑文本框。")
            detectTargetName(in: text, from: element)
        }
    }

    private func resolveEditableTextElement(from focusedElement: AXUIElement) -> Resolution {
        let candidates = collectCandidates(from: focusedElement)

        // 在读取任何 AXValue 之前先检查焦点及其可编辑祖先链。第三方控件若使用
        // Password/Secure 命名的角色或子角色，也按安全输入框处理。
        if candidates.contains(where: { isSecureTextElement($0.element) }) {
            return .unsupported(diagnostic: "当前是安全输入框，已跳过且未读取内容。")
        }

        var foundSupportedRole = false
        var foundEditableControl = false

        for candidate in candidates {
            guard let role: String = copyAttribute(kAXRoleAttribute, from: candidate.element) else {
                continue
            }

            guard isSupportedRole(
                role,
                declaredEditableAncestor: candidate.isDeclaredEditableAncestor
            ) else {
                continue
            }
            foundSupportedRole = true

            guard isEditable(
                candidate.element,
                role: role,
                declaredEditableAncestor: candidate.isDeclaredEditableAncestor
            ) else {
                continue
            }
            foundEditableControl = true

            if let text = copyTextValue(from: candidate.element) {
                return .supported(element: candidate.element, text: text)
            }
        }

        if foundEditableControl {
            return .unsupported(diagnostic: "当前输入框未提供可读取的文本值。")
        }
        if foundSupportedRole {
            return .unsupported(diagnostic: "当前文本控件不可编辑，已跳过。")
        }
        return .unsupported(diagnostic: "当前焦点不是支持的可编辑文本框。")
    }

    private func collectCandidates(from focusedElement: AXUIElement) -> [Candidate] {
        var result: [Candidate] = []

        func append(_ element: AXUIElement?, declaredEditableAncestor: Bool) {
            guard let element else { return }
            guard !result.contains(where: { CFEqual($0.element, element) }) else { return }
            result.append(
                Candidate(
                    element: element,
                    isDeclaredEditableAncestor: declaredEditableAncestor
                )
            )
        }

        // 优先读取 Chromium/Safari 暴露的可编辑根节点。网页 contenteditable 的
        // focused element 可能只是其内部 AXStaticText/AXGroup 后代。
        let highestEditable: AXUIElement? = copyAttribute(
            highestEditableAncestorAttribute,
            from: focusedElement
        )
        let editable: AXUIElement? = copyAttribute(
            editableAncestorAttribute,
            from: focusedElement
        )
        append(highestEditable, declaredEditableAncestor: true)
        append(editable, declaredEditableAncestor: true)
        append(focusedElement, declaredEditableAncestor: false)

        var current = focusedElement
        for _ in 0..<maximumAncestorDepth {
            guard let parent: AXUIElement = copyAttribute(kAXParentAttribute, from: current) else {
                break
            }
            append(parent, declaredEditableAncestor: false)
            current = parent
        }

        return result
    }

    private func isSupportedRole(_ role: String, declaredEditableAncestor: Bool) -> Bool {
        if role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String) {
            return true
        }

        // Chromium 某些版本把 contenteditable 根节点映射为 AXGroup；只有当
        // 浏览器明确把它声明为可编辑祖先时才接受，避免读取普通网页容器。
        return declaredEditableAncestor
            && (role == (kAXGroupRole as String) || role == "AXWebArea")
    }

    private func isEditable(
        _ element: AXUIElement,
        role: String,
        declaredEditableAncestor: Bool
    ) -> Bool {
        if let enabled: Bool = copyAttribute(kAXEnabledAttribute, from: element), !enabled {
            return false
        }

        if let editable: Bool = copyAttribute(kAXIsEditableAttribute, from: element) {
            return editable
        }

        if isAttributeSettable(kAXValueAttribute, on: element)
            || isAttributeSettable(kAXSelectedTextRangeAttribute, on: element) {
            return true
        }

        // Chromium 的 contenteditable 根节点可能没有公开 AXIsEditable，但会
        // 通过 AXEditableAncestor/AXHighestEditableAncestor 明确标记自身。
        if declaredEditableAncestor,
           (role == (kAXGroupRole as String) || role == "AXWebArea") {
            return true
        }

        return false
    }

    /// 必须在读取 AXValue 之前调用。
    private func isSecureTextElement(_ element: AXUIElement) -> Bool {
        let role: String? = copyAttribute(kAXRoleAttribute, from: element)
        let subrole: String? = copyAttribute(kAXSubroleAttribute, from: element)
        let secureSubrole = kAXSecureTextFieldSubrole as String

        if role == secureSubrole || subrole == secureSubrole {
            return true
        }

        return [role, subrole]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains("secure") || $0.contains("password") }
    }

    private func copyTextValue(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        ) == .success else {
            return nil
        }

        if let string = value as? String {
            return string
        }
        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }
        return nil
    }

    private func detectTargetName(in text: String, from element: AXUIElement) {
        let key = elementKey(for: element)
        let containsTarget = mentionDetector.containsTarget(in: text)
        let previouslyContainedTarget = targetPresenceByElement[key] ?? false

        remember(containsTarget, for: key)

        guard containsTarget, !previouslyContainedTarget else { return }
        onNameDetected?()
    }

    private func elementKey(for element: AXUIElement) -> ElementKey {
        var processID: pid_t = 0
        AXUIElementGetPid(element, &processID)
        return ElementKey(processID: processID, elementHash: CFHash(element))
    }

    private func remember(_ containsTarget: Bool, for key: ElementKey) {
        targetPresenceByElement[key] = containsTarget

        if let oldIndex = elementRecency.firstIndex(of: key) {
            elementRecency.remove(at: oldIndex)
        }
        elementRecency.append(key)

        while elementRecency.count > maximumRememberedElements {
            let expiredKey = elementRecency.removeFirst()
            targetPresenceByElement.removeValue(forKey: expiredKey)
        }
    }

    private func clearDeduplicationState() {
        targetPresenceByElement.removeAll(keepingCapacity: false)
        elementRecency.removeAll(keepingCapacity: false)
    }

    private func updateStatus(_ newStatus: Status, diagnostic: String?) {
        let changed = status != newStatus || lastDiagnostic != diagnostic
        status = newStatus
        lastDiagnostic = diagnostic
        guard changed else { return }
        onStatusChanged?(newStatus)
    }

    private func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &settable
        )
        return result == .success && settable.boolValue
    }

    private func copyAttribute<T>(
        _ attribute: String,
        from element: AXUIElement
    ) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? T
    }
}
