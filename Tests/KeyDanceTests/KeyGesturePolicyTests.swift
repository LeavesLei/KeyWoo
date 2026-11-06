import Testing
@testable import KeyDance

struct KeyGesturePolicyTests {
    @Test func onlyTheExplicitLargeKeysCanPerform() {
        let expected: [UInt16: DJAction] = [49: .push, 36: .lift, 76: .lift, 51: .pull,
                                           117: .pull, 48: .sweep, 57: .sweep, 56: .hold, 60: .hold]
        for code in UInt16(0)...UInt16(255) {
            let decision = ContentChangePolicy.Decision.preview(keyCode: code)
            #expect(KeyGestureRole.isPerformanceKey(code) == (expected[code] != nil))
            #expect(ContentChangePolicy.isPerformanceKey(code) == (expected[code] != nil))
            #expect(decision.action == (expected[code] ?? .none))
            #expect(expected[code] != nil ? decision.feedbackWeight > 0 : decision.feedbackWeight == 0)
            if expected[code] == nil { #expect(!decision.shouldChangeContent) }
        }
    }

    @Test func legacyDecisionInitializerHasCompatibleDefaults() {
        let value = ContentChangePolicy.Decision(role: .phrase, shouldChangeContent: true, feedbackWeight: 0.8)
        #expect(value.action == .none)
        #expect(value.duration == 0.24)
    }

    @Test func unlimitedCharacterTypingNeverPerformsOrChangesContent() {
        var policy = ContentChangePolicy()
        let silentKeys: [UInt16] = [0, 1, 12, 18, 43, 47, 50, 53, 54, 55, 58, 59, 61, 62, 63, 82, 123, 124, 125, 126]
        for i in 0..<1_000 {
            let decision = policy.receive(keyCode: silentKeys[i % silentKeys.count], timestamp: Double(i) * 0.07)
            #expect(decision.action == .none)
            #expect(decision.feedbackWeight == 0)
            #expect(!decision.shouldChangeContent)
        }
    }

    @Test func actualTypingCadenceMakesLargeKeyGesturesShorterAndShallower() {
        func trained(spacing: Double) -> ContentChangePolicy.Decision {
            var policy = ContentChangePolicy()
            var last = ContentChangePolicy.Decision.preview(keyCode: 49)
            for i in 0..<100 {
                last = policy.receive(keyCode: i % 5 == 4 ? 49 : 0, timestamp: Double(i) * spacing)
            }
            return last
        }
        let fast = trained(spacing: 0.05), slow = trained(spacing: 0.4)
        #expect(fast.action == .push && slow.action == .push)
        #expect((0.14...0.46).contains(fast.duration))
        #expect((0.14...0.46).contains(slow.duration))
        #expect(fast.duration < slow.duration - 0.1)
        #expect(fast.feedbackWeight < slow.feedbackWeight)
    }

    @Test func firstLargeKeyAfterAPauseGetsABoostEvenAfterSilentTypingResumes() {
        var policy = ContentChangePolicy()
        var before = ContentChangePolicy.Decision.preview(keyCode: 49)
        for i in 0..<60 { before = policy.receive(keyCode: 49, timestamp: Double(i) * 0.10) }
        let silent = policy.receive(keyCode: 0, timestamp: 10)
        let resumed = policy.receive(keyCode: 49, timestamp: 10.1)
        #expect(silent.feedbackWeight == 0)
        #expect(resumed.feedbackWeight > before.feedbackWeight)
        #expect(resumed.duration > before.duration)
        #expect(!resumed.shouldChangeContent)
    }

    @Test func spaceNeedsSeveralTypingGroupsAndThreeSecondsAndBareSpacesNeverCue() {
        var bare = ContentChangePolicy()
        for i in 0..<30 {
            let decision = bare.receive(keyCode: 49, timestamp: Double(i) * 0.5)
            #expect(!decision.shouldChangeContent)
        }
        var policy = ContentChangePolicy()
        let sequence: [(UInt16, Double)] = [(0, 0), (49, 0.4), (1, 0.8), (49, 1.2),
                                           (2, 1.6), (49, 2.0), (3, 2.4), (49, 3.0)]
        let decisions = sequence.map { policy.receive(keyCode: $0.0, timestamp: $0.1) }
        #expect(decisions.dropLast().allSatisfy { !$0.shouldChangeContent })
        #expect(decisions.last?.shouldChangeContent == true)
        let earlyReturn = policy.receive(keyCode: 36, timestamp: 3.2)
        let laterReturn = policy.receive(keyCode: 76, timestamp: 5.0)
        #expect(!earlyReturn.shouldChangeContent)
        #expect(laterReturn.shouldChangeContent)
    }

    @Test func returnIsRateLimitedAndOtherLargeKeysNeverChangePhrases() {
        var policy = ContentChangePolicy()
        let times = [0.0, 0.5, 1.9, 2.0]
        let decisions = times.map { policy.receive(keyCode: 36, timestamp: $0) }
        #expect(decisions.map(\.shouldChangeContent) == [true, false, false, true])
        #expect(decisions.allSatisfy { $0.action == .lift && $0.feedbackWeight > 0 })
        for code in [UInt16(51), 117, 48, 56, 60, 57] {
            var other = ContentChangePolicy()
            let decision = other.receive(keyCode: code, timestamp: 100)
            #expect(!decision.shouldChangeContent)
            #expect(decision.action != .none && decision.feedbackWeight > 0)
        }
    }

    @Test func previewsDoNotPolluteRealCadenceOrPhraseLimits() {
        var control = ContentChangePolicy(), auditioned = ContentChangePolicy()
        for i in 0..<60 {
            let code: UInt16 = i % 5 == 4 ? 49 : 0
            let expected = control.receive(keyCode: code, timestamp: Double(i) * 0.15)
            for preview in [UInt16(49), 36, 56, 0] { _ = ContentChangePolicy.Decision.preview(keyCode: preview) }
            let actual = auditioned.receive(keyCode: code, timestamp: Double(i) * 0.15)
            #expect(actual == expected)
        }
        #expect(ContentChangePolicy.Decision.preview(keyCode: 49).shouldChangeContent)
        #expect(ContentChangePolicy.Decision.preview(keyCode: 36).shouldChangeContent)
    }

    @Test func invalidTimeCannotBypassTheCueLimitAndResetStartsFresh() {
        var policy = ContentChangePolicy()
        let times: [Double] = [10, .nan, .infinity, 9, 11.9, 12]
        let decisions = times.map { policy.receive(keyCode: 36, timestamp: $0) }
        #expect(decisions.map(\.shouldChangeContent) == [true, false, false, false, false, true])
        #expect(decisions.allSatisfy { $0.action == .lift && $0.duration.isFinite && $0.feedbackWeight.isFinite })
        policy.reset()
        let fresh = policy.receive(keyCode: 36, timestamp: 0)
        #expect(fresh.shouldChangeContent)
    }
}
