import Foundation

/// 用户明确选择并持久化的基础陪伴档位。
enum CompanionActivityLevel: String, CaseIterable, Codable {
    case focused
    case balanced
    case lively
}

/// 当前真正生效的活跃程度；quiet 只是有时限的额外覆盖。
enum CompanionEffectiveActivity: String, Equatable {
    case focused
    case balanced
    case lively
    case quiet
}

enum CompanionActivityOrigin {
    /// 点击、拖动、菜单等用户主动触发。
    case explicitInteraction
    /// 无用户操作时的自动待机动作。
    case ambient
}

/// 供既有待机调度器集成的纯参数。本类型不创建计时器。
struct CompanionIdleProfile: Equatable {
    let initialDelay: TimeInterval
    let subsequentDelayRange: ClosedRange<TimeInterval>
    let opportunityProbability: Double
    /// `false` 时宿主不应创建或保留任何自动待机调度。
    let isSchedulingEnabled: Bool

    var allowsAmbientActivity: Bool {
        isSchedulingEnabled
    }

    static func profile(for activity: CompanionEffectiveActivity) -> Self {
        switch activity {
        case .focused:
            return CompanionIdleProfile(
                // 时间参数只作为安全占位；调度必须由 isSchedulingEnabled 门禁。
                initialDelay: CompanionActivityPolicy.quietDuration,
                subsequentDelayRange:
                    CompanionActivityPolicy.quietDuration...CompanionActivityPolicy.quietDuration,
                opportunityProbability: 0,
                isSchedulingEnabled: false
            )
        case .balanced:
            // 保持现有待机调度的节奏作为默认档。
            return CompanionIdleProfile(
                initialDelay: 75,
                subsequentDelayRange: 120...240,
                opportunityProbability: 0.65,
                isSchedulingEnabled: true
            )
        case .lively:
            return CompanionIdleProfile(
                initialDelay: 30,
                subsequentDelayRange: 45...100,
                opportunityProbability: 0.90,
                isSchedulingEnabled: true
            )
        case .quiet:
            return CompanionIdleProfile(
                initialDelay: CompanionActivityPolicy.quietDuration,
                subsequentDelayRange:
                    CompanionActivityPolicy.quietDuration...CompanionActivityPolicy.quietDuration,
                opportunityProbability: 0,
                isSchedulingEnabled: false
            )
        }
    }
}

struct CompanionActivitySnapshot: Equatable {
    let baseLevel: CompanionActivityLevel
    let effectiveActivity: CompanionEffectiveActivity
    let quietUntil: Date?

    var idleProfile: CompanionIdleProfile {
        .profile(for: effectiveActivity)
    }
}

/// 只根据用户明确选择解析陪伴活跃度。
///
/// 不读取键盘、剪贴板或当前应用，也不推断用户是否在工作。
final class CompanionActivityPolicy {
    static let storageKey = "companionActivity.policy.v2"
    static let legacyBaseLevelStorageKey = "companionActivity.mode"
    static let legacyQuietUntilStorageKey = "companionActivity.quietUntil"
    static let quietDuration: TimeInterval = 30 * 60

    private struct StoredState: Codable {
        var version: Int
        var baseLevel: String
        var quietStartedAt: TimeInterval?
        var quietUntil: TimeInterval?
    }

    private let defaults: UserDefaults
    private let nowProvider: () -> Date
    private var quietStartedAt: TimeInterval?
    private var quietUntil: TimeInterval?

    private(set) var baseLevel: CompanionActivityLevel

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.nowProvider = now

        if
            let data = defaults.data(forKey: Self.storageKey),
            let stored = try? JSONDecoder().decode(StoredState.self, from: data)
        {
            baseLevel = CompanionActivityLevel(rawValue: stored.baseLevel) ?? .balanced
            quietStartedAt = stored.quietStartedAt
            quietUntil = stored.quietUntil
        } else {
            let legacyRaw = defaults.string(forKey: Self.legacyBaseLevelStorageKey)
            baseLevel = CompanionActivityLevel(rawValue: legacyRaw ?? "") ?? .balanced
            quietStartedAt = nil
            quietUntil = Self.finiteNumber(
                defaults.object(forKey: Self.legacyQuietUntilStorageKey)
            )
        }

        // 初始化即完成迁移与损坏数据修复，不产生任何自动活动。
        _ = resolve(at: now())
        persist()
    }

    /// 切换基础档位。如果 quiet 正在生效，它仍会持续到原截止时间。
    func setBaseLevel(_ level: CompanionActivityLevel) {
        baseLevel = level
        persist()
    }

    /// 从此刻开始静默 30 分钟。重复调用表示用户明确重新开始计时。
    @discardableResult
    func beginQuiet() -> CompanionActivitySnapshot {
        let now = sanitizedNow(nowProvider())
        quietStartedAt = now
        quietUntil = now + Self.quietDuration
        persist()
        return makeSnapshot(quietUntil: quietUntil)
    }

    func cancelQuiet() {
        guard quietStartedAt != nil || quietUntil != nil else { return }
        quietStartedAt = nil
        quietUntil = nil
        persist()
    }

    func resolve() -> CompanionActivitySnapshot {
        resolve(at: nowProvider())
    }

    /// 显式时间入口便于调度器与测试使用同一时钟。
    func resolve(at date: Date) -> CompanionActivitySnapshot {
        let now = sanitizedNow(date)
        let didChange = sanitizeQuietWindow(at: now)
        if didChange {
            persist()
        }
        return makeSnapshot(quietUntil: activeQuietUntil(at: now))
    }

    /// 明确互动始终允许；quiet 只阻止无人操作的环境动作。
    func allows(_ origin: CompanionActivityOrigin, at date: Date? = nil) -> Bool {
        switch origin {
        case .explicitInteraction:
            return true
        case .ambient:
            let snapshot = date.map(resolve(at:)) ?? resolve()
            return snapshot.idleProfile.allowsAmbientActivity
        }
    }

    func idleProfile(at date: Date? = nil) -> CompanionIdleProfile {
        let snapshot = date.map(resolve(at:)) ?? resolve()
        return snapshot.idleProfile
    }

    private func makeSnapshot(quietUntil: TimeInterval?) -> CompanionActivitySnapshot {
        if let quietUntil = quietUntil {
            return CompanionActivitySnapshot(
                baseLevel: baseLevel,
                effectiveActivity: .quiet,
                quietUntil: Date(timeIntervalSince1970: quietUntil)
            )
        }

        let effective: CompanionEffectiveActivity
        switch baseLevel {
        case .focused: effective = .focused
        case .balanced: effective = .balanced
        case .lively: effective = .lively
        }
        return CompanionActivitySnapshot(
            baseLevel: baseLevel,
            effectiveActivity: effective,
            quietUntil: nil
        )
    }

    private func activeQuietUntil(at now: TimeInterval) -> TimeInterval? {
        guard let quietUntil = quietUntil, quietUntil > now else { return nil }
        return quietUntil
    }

    /// 返回是否修改了待持久化的状态。
    private func sanitizeQuietWindow(at now: TimeInterval) -> Bool {
        guard let storedUntil = quietUntil, storedUntil.isFinite else {
            let changed = quietStartedAt != nil || quietUntil != nil
            quietStartedAt = nil
            quietUntil = nil
            return changed
        }

        guard storedUntil > now else {
            quietStartedAt = nil
            quietUntil = nil
            return true
        }

        var repairedStart = quietStartedAt
        var repairedUntil = storedUntil
        if repairedStart?.isFinite != true {
            repairedStart = max(now, storedUntil - Self.quietDuration)
        }

        // 开始时间落在“当前时间”之后通常表示系统时钟回拨。
        if let start = repairedStart, start > now {
            repairedStart = now
        }

        let maximumUntil = now.adding(Self.quietDuration)
        if repairedUntil > maximumUntil {
            repairedUntil = maximumUntil
        }
        if let start = repairedStart, repairedUntil > start.adding(Self.quietDuration) {
            repairedUntil = start.adding(Self.quietDuration)
        }

        guard repairedUntil > now else {
            quietStartedAt = nil
            quietUntil = nil
            return true
        }

        let changed = repairedStart != quietStartedAt || repairedUntil != quietUntil
        quietStartedAt = repairedStart
        quietUntil = repairedUntil
        return changed
    }

    private func sanitizedNow(_ date: Date) -> TimeInterval {
        let value = date.timeIntervalSince1970
        return value.isFinite ? value : 0
    }

    private func persist() {
        let state = StoredState(
            version: 2,
            baseLevel: baseLevel.rawValue,
            quietStartedAt: quietStartedAt,
            quietUntil: quietUntil
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func finiteNumber(_ object: Any?) -> TimeInterval? {
        guard let number = object as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }
}

private extension TimeInterval {
    func adding(_ interval: TimeInterval) -> TimeInterval {
        let result = self + interval
        return result.isFinite ? result : self
    }
}
