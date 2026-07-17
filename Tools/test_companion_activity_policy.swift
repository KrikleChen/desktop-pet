import Foundation

@main
struct CompanionActivityPolicyTestMain {
    static func main() {
        testDefaultPersistenceAndProfiles()
        testLegacyMigrationAndInvalidFallback()
        testQuietBoundaryAndBaseSwitch()
        testClockRollbackAndExtremeFutureClamp()
        testInteractionPolicy()
        testFocusedHasNoAmbientAcross24Hours()
        print("陪伴档位、静默覆盖与待机策略自检通过。")
    }

    private static func testDefaultPersistenceAndProfiles() {
        withDefaults { defaults in
            let policy = CompanionActivityPolicy(
                defaults: defaults,
                now: { date(1_000) }
            )
            precondition(policy.baseLevel == .balanced, "默认档必须是 balanced")
            precondition(policy.resolve().effectiveActivity == .balanced)
            precondition(policy.idleProfile() == .profile(for: .balanced))

            policy.setBaseLevel(.lively)
            let restored = CompanionActivityPolicy(
                defaults: defaults,
                now: { date(1_001) }
            )
            precondition(restored.baseLevel == .lively, "基础档应跨实例持久化")

            let focused = CompanionIdleProfile.profile(for: .focused)
            let balanced = CompanionIdleProfile.profile(for: .balanced)
            let lively = CompanionIdleProfile.profile(for: .lively)
            precondition(focused.initialDelay > balanced.initialDelay)
            precondition(balanced.initialDelay > lively.initialDelay)
            precondition(focused.opportunityProbability < balanced.opportunityProbability)
            precondition(balanced.opportunityProbability < lively.opportunityProbability)
            precondition(!focused.isSchedulingEnabled)
            precondition(balanced.isSchedulingEnabled && lively.isSchedulingEnabled)
        }
    }

    private static func testLegacyMigrationAndInvalidFallback() {
        withDefaults { defaults in
            defaults.set(
                CompanionActivityLevel.focused.rawValue,
                forKey: CompanionActivityPolicy.legacyBaseLevelStorageKey
            )
            defaults.set(
                2_200.0,
                forKey: CompanionActivityPolicy.legacyQuietUntilStorageKey
            )
            let migrated = CompanionActivityPolicy(
                defaults: defaults,
                now: { date(1_000) }
            )
            precondition(migrated.baseLevel == .focused)
            precondition(migrated.resolve().effectiveActivity == .quiet)
            precondition(
                defaults.data(forKey: CompanionActivityPolicy.storageKey) != nil,
                "旧键应迁移到统一状态"
            )

            let restored = CompanionActivityPolicy(
                defaults: defaults,
                now: { date(2_200) }
            )
            precondition(restored.resolve().effectiveActivity == .focused)
        }

        withDefaults { defaults in
            let invalidState: [String: Any] = [
                "version": 2,
                "baseLevel": "hyperactive",
                "quietStartedAt": NSNull(),
                "quietUntil": NSNull(),
            ]
            defaults.set(
                try! JSONSerialization.data(withJSONObject: invalidState),
                forKey: CompanionActivityPolicy.storageKey
            )
            let repaired = CompanionActivityPolicy(
                defaults: defaults,
                now: { date(500) }
            )
            precondition(repaired.baseLevel == .balanced, "非法档位必须回退 balanced")
            precondition(repaired.resolve().effectiveActivity == .balanced)
        }

        withDefaults { defaults in
            defaults.set("broken-data", forKey: CompanionActivityPolicy.storageKey)
            defaults.set("also-invalid", forKey: CompanionActivityPolicy.legacyBaseLevelStorageKey)
            let fallback = CompanionActivityPolicy(
                defaults: defaults,
                now: { date(500) }
            )
            precondition(fallback.baseLevel == .balanced, "损坏存储也必须安全回退")
        }
    }

    private static func testQuietBoundaryAndBaseSwitch() {
        withDefaults { defaults in
            var now = date(1_000)
            let policy = CompanionActivityPolicy(defaults: defaults, now: { now })
            policy.setBaseLevel(.focused)
            let quiet = policy.beginQuiet()
            precondition(quiet.effectiveActivity == .quiet)
            precondition(quiet.quietUntil == date(2_800))

            // quiet 期间只修改基础档，不暗自取消用户的 30 分钟覆盖。
            policy.setBaseLevel(.lively)
            now = date(2_799)
            precondition(policy.resolve().effectiveActivity == .quiet, "29:59 仍应静默")

            now = date(2_800)
            let expired = policy.resolve()
            precondition(expired.effectiveActivity == .lively, "30:00 应立即恢复基础档")
            precondition(expired.quietUntil == nil)

            now = date(3_000)
            _ = policy.beginQuiet()
            policy.cancelQuiet()
            precondition(policy.resolve().effectiveActivity == .lively, "显式取消应立即恢复")
        }
    }

    private static func testClockRollbackAndExtremeFutureClamp() {
        withDefaults { defaults in
            var now = date(1_000)
            let policy = CompanionActivityPolicy(defaults: defaults, now: { now })
            _ = policy.beginQuiet()

            now = date(900) // 系统时钟倒退 100 秒
            let rolledBack = policy.resolve()
            precondition(rolledBack.effectiveActivity == .quiet)
            precondition(
                rolledBack.quietUntil == date(2_700),
                "时钟回拨不得让 quiet 剩余时间超过 30 分钟"
            )
        }

        withDefaults { defaults in
            let extremeState: [String: Any] = [
                "version": 2,
                "baseLevel": CompanionActivityLevel.focused.rawValue,
                "quietStartedAt": 9_000_000_000.0,
                "quietUntil": 9_000_001_800.0,
            ]
            defaults.set(
                try! JSONSerialization.data(withJSONObject: extremeState),
                forKey: CompanionActivityPolicy.storageKey
            )
            let repaired = CompanionActivityPolicy(
                defaults: defaults,
                now: { date(500) }
            )
            let snapshot = repaired.resolve()
            precondition(snapshot.effectiveActivity == .quiet)
            precondition(
                snapshot.quietUntil == date(2_300),
                "极端未来截止时间必须钳制到 now + 30 分钟"
            )
        }
    }

    private static func testInteractionPolicy() {
        withDefaults { defaults in
            var now = date(1_000)
            let policy = CompanionActivityPolicy(defaults: defaults, now: { now })

            for level in CompanionActivityLevel.allCases {
                policy.setBaseLevel(level)
                precondition(policy.allows(.explicitInteraction), "所有基础档都必须允许显式互动")
                let expectedAmbient = level != .focused
                precondition(
                    policy.allows(.ambient) == expectedAmbient,
                    "focused 必须禁用 ambient，balanced/lively 应允许"
                )
            }

            _ = policy.beginQuiet()
            precondition(policy.allows(.explicitInteraction), "quiet 不得屏蔽用户主动互动")
            precondition(!policy.allows(.ambient), "quiet 应禁止自动环境动作")
            let quietProfile = policy.idleProfile()
            precondition(!quietProfile.allowsAmbientActivity)
            precondition(quietProfile.opportunityProbability == 0)

            now = date(2_800)
            precondition(policy.allows(.ambient), "quiet 过期后 ambient 应自动恢复")
        }
    }

    private static func testFocusedHasNoAmbientAcross24Hours() {
        withDefaults { defaults in
            let start: TimeInterval = 50_000
            var now = date(start)
            let policy = CompanionActivityPolicy(defaults: defaults, now: { now })
            policy.setBaseLevel(.focused)

            var allowedAmbientOpportunities = 0
            // 逐分钟推进整整 24 小时，每次都重新 resolve，模拟长时间运行。
            for minute in 0...1_440 {
                now = date(start + TimeInterval(minute * 60))
                let snapshot = policy.resolve()
                precondition(snapshot.effectiveActivity == .focused)
                precondition(!snapshot.idleProfile.isSchedulingEnabled)
                precondition(snapshot.idleProfile.opportunityProbability == 0)
                if policy.allows(.ambient, at: now) {
                    allowedAmbientOpportunities += 1
                }
                precondition(policy.allows(.explicitInteraction, at: now))
            }

            precondition(
                allowedAmbientOpportunities == 0,
                "focused 持续 24h 的自主动作许可数必须为 0"
            )
        }
    }

    private static func date(_ timestamp: TimeInterval) -> Date {
        Date(timeIntervalSince1970: timestamp)
    }

    private static func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "com.ymatrix.phoenix-desktop-pet.companion-policy-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("无法创建隔离的陪伴策略测试存储")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
