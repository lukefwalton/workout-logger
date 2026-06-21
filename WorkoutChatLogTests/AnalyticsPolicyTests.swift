import XCTest
@testable import WorkoutChatLog

final class AnalyticsPolicyTests: XCTestCase {

    private let policy = AnalyticsPolicy.default

    func testWorkingEquivalentSetTypesCountTowardVolume() {
        XCTAssertTrue(policy.countsTowardVolume(.working))
        XCTAssertTrue(policy.countsTowardVolume(.dropset))
        XCTAssertTrue(policy.countsTowardVolume(.myorep))
        XCTAssertTrue(policy.countsTowardVolume(.amrap))
    }

    func testWarmupAndBackoffDoNotCountTowardVolume() {
        XCTAssertFalse(policy.countsTowardVolume(.warmup))
        XCTAssertFalse(policy.countsTowardVolume(.backoff))
    }

    func testHardSetByRIRThreshold() {
        XCTAssertTrue(policy.isHardSet(setType: .working, rir: 2))
        XCTAssertTrue(policy.isHardSet(setType: .working, rir: 4), "RIR at the threshold is hard")
        XCTAssertFalse(policy.isHardSet(setType: .working, rir: 6))
    }

    func testNullRIRCountsAsHardByDefault() {
        XCTAssertTrue(policy.isHardSet(setType: .working, rir: nil))
    }

    func testNullRIRRespectsPolicyWhenDisabled() {
        var strict = AnalyticsPolicy()
        strict.countNullRIRAsHard = false
        XCTAssertFalse(strict.isHardSet(setType: .working, rir: nil))
    }

    func testNonWorkingSetTypeIsNeverHard() {
        XCTAssertFalse(policy.isHardSet(setType: .warmup, rir: 0))
        XCTAssertFalse(policy.isHardSet(setType: .backoff, rir: nil))
    }

    func testPolicyIsCodableRoundTrip() throws {
        var custom = AnalyticsPolicy()
        custom.hardSetRIRThreshold = 2
        custom.countNullRIRAsHard = false
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(AnalyticsPolicy.self, from: data)
        XCTAssertEqual(decoded, custom)
    }
}
