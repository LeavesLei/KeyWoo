import Testing
@testable import KeyDance

struct RemapSoakVerifierTests {
    @Test func deterministicSoakCoversBoundarySeedsWithoutOSAccess() throws {
        for seed: UInt64 in [0, 1, 7, 42, 0x0123456789ABCDEF, UInt64.max] {
            let count = try RemapSoakVerifier.exercise(seed: seed)
            #expect(count > 580)
        }
    }
    @Test func sameSeedReportsTheSameNumberOfValidatedEvents() throws {
        let first = try RemapSoakVerifier.exercise(seed: 20261106)
        let second = try RemapSoakVerifier.exercise(seed: 20261106)
        #expect(first == second)
    }
}
