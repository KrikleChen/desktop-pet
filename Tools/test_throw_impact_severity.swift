import AppKit

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message):
            return message
        }
    }
}

@main
private struct ThrowImpactSeverityTests {
    static func main() throws {
        var configuration = ThrowPhysicsController.Configuration()
        configuration.minimumThrowSpeed = 720
        configuration.gravity = -1_600
        configuration.edgeRestitution = 0.20
        configuration.mediumImpactSpeed = 420
        configuration.heavyImpactSpeed = 1_100

        try expectImpact(
            velocity: CGVector(dx: 300, dy: -900),
            edge: .right,
            expectedSpeed: 300,
            expectedSeverity: .light,
            configuration: configuration,
            label: "light grazing side contact"
        )
        try expectImpact(
            velocity: CGVector(dx: -80, dy: -720),
            edge: .bottom,
            expectedSpeed: 720,
            expectedSeverity: .medium,
            configuration: configuration,
            label: "medium minimum-speed landing"
        )
        try expectImpact(
            velocity: CGVector(dx: 140, dy: -1_450),
            edge: .bottom,
            expectedSpeed: 1_450,
            expectedSeverity: .heavy,
            configuration: configuration,
            label: "heavy gravity-accelerated fall"
        )

        try expect(
            configuration.impactSeverity(forPreCollisionNormalSpeed: 419) == .light,
            "speed immediately below medium threshold must stay light"
        )
        try expect(
            configuration.impactSeverity(forPreCollisionNormalSpeed: 420) == .medium,
            "medium threshold must be inclusive"
        )
        try expect(
            configuration.impactSeverity(forPreCollisionNormalSpeed: 1_100) == .heavy,
            "heavy threshold must be inclusive"
        )

        let horizontal = CGVector(dx: -800, dy: 2_000)
        try expectNormalSpeed(horizontal, edge: .left, expected: 800, label: "left incoming")
        try expectNormalSpeed(horizontal, edge: .right, expected: 0, label: "right moving away")

        let vertical = CGVector(dx: -2_000, dy: 1_200)
        try expectNormalSpeed(vertical, edge: .top, expected: 1_200, label: "top incoming")
        try expectNormalSpeed(vertical, edge: .bottom, expected: 0, label: "bottom moving away")

        try expectNormalSpeed(
            CGVector(dx: -600, dy: -1_300),
            edge: [.left, .bottom],
            expected: 1_300,
            label: "corner uses strongest normal component"
        )

        // 回归：角落碰撞必须用完整入射速度一次性分级，不能先用水平碰撞的
        // tangential damping 把 -1300 衰减为 -884 后再判断垂直撞击。
        guard let cornerImpact = ThrowPhysicsController.BounceImpact(
            edges: [.right, .bottom],
            preCollisionVelocity: CGVector(dx: 600, dy: -1_300),
            configuration: configuration
        ) else {
            throw TestFailure.assertion("corner impact was not created")
        }
        try expect(cornerImpact.normalSpeed == 1_300, "corner must preserve original vertical speed")
        try expect(cornerImpact.severity == .heavy, "600/-1300 corner impact must stay heavy")
        let incorrectlyDampedVerticalSpeed = 1_300 * configuration.tangentialDamping
        try expect(
            incorrectlyDampedVerticalSpeed < configuration.heavyImpactSpeed,
            "fixture must demonstrate the former sequential-damping misclassification"
        )

        guard let heavyPreBounce = ThrowPhysicsController.BounceImpact(
            edges: .bottom,
            preCollisionVelocity: CGVector(dx: 0, dy: -1_200),
            configuration: configuration
        ) else {
            throw TestFailure.assertion("heavy pre-bounce impact was not created")
        }
        let reboundSpeed = heavyPreBounce.normalSpeed * configuration.edgeRestitution
        try expect(heavyPreBounce.severity == .heavy, "pre-bounce 1,200 pt/s must be heavy")
        try expect(reboundSpeed == 240, "0.2 restitution should leave a 240 pt/s rebound")
        try expect(
            configuration.impactSeverity(forPreCollisionNormalSpeed: reboundSpeed) == .light,
            "test fixture must prove post-bounce speed would misclassify the heavy impact"
        )

        print("PASS: throw impact severity (light/medium/heavy, thresholds, directions, pre-bounce capture)")
    }

    private static func expectImpact(
        velocity: CGVector,
        edge: ThrowCollisionEdges,
        expectedSpeed: CGFloat,
        expectedSeverity: ThrowPhysicsController.ImpactSeverity,
        configuration: ThrowPhysicsController.Configuration,
        label: String
    ) throws {
        guard let impact = ThrowPhysicsController.BounceImpact(
            edges: edge,
            preCollisionVelocity: velocity,
            configuration: configuration
        ) else {
            throw TestFailure.assertion("\(label): expected an incoming impact")
        }
        try expect(impact.edges == edge, "\(label): edge mismatch")
        try expect(impact.normalSpeed == expectedSpeed, "\(label): normal speed mismatch")
        try expect(impact.severity == expectedSeverity, "\(label): severity mismatch")
        try expect(
            impact.preCollisionVelocity.dx == velocity.dx &&
                impact.preCollisionVelocity.dy == velocity.dy,
            "\(label): pre-collision velocity was not preserved"
        )
    }

    private static func expectNormalSpeed(
        _ velocity: CGVector,
        edge: ThrowCollisionEdges,
        expected: CGFloat,
        label: String
    ) throws {
        let actual = ThrowPhysicsController.BounceImpact.preCollisionNormalSpeed(
            for: velocity,
            against: edge
        )
        try expect(actual == expected, "\(label): expected \(expected), got \(actual)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw TestFailure.assertion(message)
        }
    }
}
