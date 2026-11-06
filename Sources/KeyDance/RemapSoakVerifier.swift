import Foundation

/// CPU-only deterministic regression workload for the long-running QA command.
/// It does not construct/post CGEvents, open a device, inspect permissions, read
/// entered text, or touch the user's configuration. Each invocation starts fresh.
enum RemapSoakVerifier {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    private struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var x = state
            x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
            x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
            return x ^ (x >> 31)
        }
    }

    static func exercise(seed: UInt64) throws -> Int {
        var checked = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure(description: "Remap soak seed \(seed): \(message)") }
        }
        func feed(_ state: inout RemapStateMachine, _ input: RemapInput) -> RemapDecision {
            checked += 1
            return state.process(input)
        }
        func profile(_ rules: [RemapRule]) -> RemapProfile { RemapProfile(name: "isolated soak", rules: rules) }
        func rule(_ source: UInt16, _ target: UInt16, mods: RemapModifiers = [], output: RemapModifiers = [], extras: Bool = false) -> RemapRule {
            .init(trigger: .init(keyCode: source, modifiers: mods, allowsExtraModifiers: extras), action: .key(code: target, modifiers: output))
        }

        // Exact vs inclusive matching, including preserving additional flags.
        var exact = RemapStateMachine(profile: profile([rule(0, 11, mods: [.control])]))
        let rejected = feed(&exact, .init(.down, keyCode: 0, modifiers: [.control, .shift]))
        try require(!rejected.suppressOriginal, "exact trigger consumed an extra modifier")
        _ = feed(&exact, .init(.up, keyCode: 0))
        let accepted = feed(&exact, .init(.down, keyCode: 0, modifiers: [.control]))
        try require(accepted.suppressOriginal && accepted.outputs.count == 1, "exact trigger did not map")
        _ = feed(&exact, .init(.up, keyCode: 0))
        var inclusive = RemapStateMachine(profile: profile([rule(0, 11, extras: true)]))
        let extra = feed(&inclusive, .init(.down, keyCode: 0, modifiers: [.shift, .command]))
        try require(extra.outputs == [.key(code: 11, isDown: true, isRepeat: false, modifiers: [.shift, .command])], "extra modifiers were lost")
        _ = feed(&inclusive, .init(.up, keyCode: 0))

        // Every new Fn-Space press gives a pair; OS repeats never retrigger it.
        var media = RemapStateMachine(profile: profile([.init(trigger: .init(keyCode: 49, modifiers: .fn), action: .media(.playPause))]))
        for _ in 0..<8 {
            let down = feed(&media, .init(.down, keyCode: 49, modifiers: .fn))
            try require(down.outputs == [.media(.playPause, isDown: true)], "Fn-Space did not begin exactly once")
            for _ in 0..<6 {
                let repeated = feed(&media, .init(.down, keyCode: 49, modifiers: .fn, isRepeat: true))
                try require(repeated.suppressOriginal && repeated.outputs.isEmpty, "media auto-repeat leaked")
            }
            let up = feed(&media, .init(.up, keyCode: 49))
            try require(up.outputs == [.media(.playPause, isDown: false)], "media release lost when Fn released first")
        }

        // Most-recent active layer wins; releasing a layer cannot change an
        // already-held key's output. Caps is a toggle, Right Option is a hold.
        let lower = RemapLayer(name: "hold"), upper = RemapLayer(name: "toggle")
        var layers = RemapStateMachine(profile: .init(name: "layers", layers: [lower, upper], layerKeys: [
            .init(keyCode: 61, layerID: lower.id), .init(keyCode: 57, layerID: upper.id, mode: .toggle)
        ], rules: [
            rule(4, 0),
            .init(trigger: .init(keyCode: 4, layerID: lower.id), action: .key(code: 123, modifiers: [])),
            .init(trigger: .init(keyCode: 4, layerID: upper.id), action: .key(code: 124, modifiers: []))
        ]))
        _ = feed(&layers, .init(.down, keyCode: 61, modifiers: .option))
        _ = feed(&layers, .init(.tap, keyCode: 57, modifiers: [.option, .capsLock]))
        let top = feed(&layers, .init(.down, keyCode: 4, modifiers: [.option, .capsLock]))
        try require(top.outputs == [.key(code: 124, isDown: true, isRepeat: false, modifiers: [])], "layer precedence or modifier suppression failed")
        _ = feed(&layers, .init(.tap, keyCode: 57, modifiers: .option))
        _ = feed(&layers, .init(.up, keyCode: 61))
        let layerUp = feed(&layers, .init(.up, keyCode: 4))
        try require(layerUp.outputs == [.key(code: 124, isDown: false, isRepeat: false, modifiers: [])], "layer release rebound held key")
        try require(layers.activeLayerIDs.isEmpty, "layer stayed active after both releases")

        // One output owned by two sources; release it only after the last owner.
        var shared = RemapStateMachine(profile: profile([rule(0, 11), rule(1, 11)]))
        _ = feed(&shared, .init(.down, keyCode: 0))
        let second = feed(&shared, .init(.down, keyCode: 1))
        let firstUp = feed(&shared, .init(.up, keyCode: 0))
        try require(second.outputs.isEmpty && firstUp.outputs.isEmpty && shared.heldOutputKeys == [11], "shared target ownership broke")
        _ = feed(&shared, .init(.up, keyCode: 1))
        try require(shared.heldOutputKeys.isEmpty, "last shared owner did not release")

        // A physically down target only owns that OS key if it passed through.
        var aliases = RemapStateMachine(profile: profile([rule(0, 11), rule(11, 8)]))
        _ = feed(&aliases, .init(.down, keyCode: 0))
        _ = feed(&aliases, .init(.down, keyCode: 11))
        let aliasUp = feed(&aliases, .init(.up, keyCode: 0))
        try require(aliasUp.outputs == [.key(code: 11, isDown: false, isRepeat: false, modifiers: [])], "suppressed target was mistaken for visible physical ownership")
        _ = feed(&aliases, .init(.up, keyCode: 11))
        var preexisting = RemapStateMachine(profile: profile([rule(0, 11)]))
        preexisting.seedPhysicalKeys([11])
        let seededDown = feed(&preexisting, .init(.down, keyCode: 0))
        let seededUp = feed(&preexisting, .init(.up, keyCode: 0))
        try require(seededDown.outputs.isEmpty && seededUp.outputs.isEmpty && preexisting.physicalHeld == [11], "startup-held target lost ownership")
        _ = feed(&preexisting, .init(.up, keyCode: 11))

        // A retired layer modifier remains filtered until its physical up. The
        // opposite side is a separate legitimate owner, including across reset.
        var quarantine = RemapStateMachine(profile: .init(name: "quarantine", layers: [lower],
            layerKeys: [.init(keyCode: 61, layerID: lower.id)]))
        _ = feed(&quarantine, .init(.down, keyCode: 58, modifiers: .option))
        _ = feed(&quarantine, .init(.down, keyCode: 61, modifiers: .option))
        _ = quarantine.releaseAll()
        let withLeft = feed(&quarantine, .init(.down, keyCode: 4, modifiers: .option))
        try require(withLeft.passthroughModifiers == .option, "quarantine removed the still-held opposite modifier")
        _ = feed(&quarantine, .init(.up, keyCode: 58, modifiers: .option))
        let withoutLeft = feed(&quarantine, .init(.down, keyCode: 38, modifiers: .option))
        try require(withoutLeft.passthroughModifiers == [], "quarantined layer modifier leaked into text")
        _ = feed(&quarantine, .init(.up, keyCode: 61))

        // Editor recording must drain the recorded hold, not merely its first
        // down; otherwise Command-Q autorepeat can run after capture completes.
        var shield = RemapCaptureShield()
        checked += 2
        try require(shield.shouldSuppress(.init(.down, keyCode: 55, modifiers: .command), isCapturing: true), "recorded modifier leaked")
        try require(shield.shouldSuppress(.init(.down, keyCode: 12, modifiers: .command), isCapturing: true), "recorded shortcut leaked")
        for _ in 0..<8 {
            checked += 1
            try require(shield.shouldSuppress(.init(.down, keyCode: 12, modifiers: .command, isRepeat: true), isCapturing: false), "recorded shortcut repeat escaped after completion")
        }
        checked += 3
        try require(shield.shouldSuppress(.init(.up, keyCode: 12), isCapturing: false), "recorded shortcut up escaped")
        try require(shield.shouldSuppress(.init(.up, keyCode: 55), isCapturing: false), "recorded modifier up escaped")
        try require(!shield.shouldSuppress(.init(.down, keyCode: 12), isCapturing: false) && !shield.isDraining,
                    "recording permanently blocked a fresh key")

        // Modifier removal before source-up and profile replacement are distinct
        // release paths. A reconfigured held source stays blocked until its up.
        var changing = RemapStateMachine(profile: profile([rule(0, 8, mods: [.option], output: [.command, .shift])]))
        _ = feed(&changing, .init(.down, keyCode: 0, modifiers: .option))
        _ = feed(&changing, .init(.up, keyCode: 58))
        let reset = changing.replaceProfile(profile([rule(0, 36)]))
        try require(reset.count == 3 && changing.heldOutputKeys.isEmpty, "configuration did not release output chord")
        let quarantined = feed(&changing, .init(.down, keyCode: 0, isRepeat: true))
        try require(quarantined.suppressOriginal && quarantined.outputs.isEmpty, "reconfiguration leaked old repeat")
        _ = feed(&changing, .init(.up, keyCode: 0))
        let changed = feed(&changing, .init(.down, keyCode: 0))
        try require(changed.outputs == [.key(code: 36, isDown: true, isRepeat: false, modifiers: [])], "new press did not use new rule")
        _ = changing.releaseAll()
        let blockedUp = feed(&changing, .init(.up, keyCode: 0))
        try require(blockedUp.suppressOriginal && blockedUp.outputs.isEmpty, "disable did not quarantine old source")

        // Seeded interleaving stress. Sources and target identities are disjoint
        // here, so an independent output ledger can assert balanced transitions.
        var random = RemapStateMachine(profile: profile([
            rule(0, 11), rule(1, 11), rule(2, 8, output: .command),
            rule(3, 9, output: [.command, .shift]),
            .init(trigger: .init(keyCode: 49), action: .media(.volumeUp))
        ]))
        var rng = RNG(state: seed)
        let codes: [UInt16] = [0, 1, 2, 3, 49]
        var sources = Set<UInt16>()
        var outputKeys = Set<UInt16>()
        var mediaOwners = 0
        func observe(_ outputs: [RemapOutput]) throws {
            for output in outputs {
                switch output {
                case let .key(code, down, repeated, _):
                    if repeated { try require(outputKeys.contains(code), "repeat preceded output down") }
                    else if down { try require(outputKeys.insert(code).inserted, "duplicate output down") }
                    else { try require(outputKeys.remove(code) != nil, "output up had no owner") }
                case let .media(_, down):
                    mediaOwners += down ? 1 : -1
                    try require(mediaOwners >= 0, "media up had no owner")
                }
            }
        }
        for index in 0..<512 {
            let code = codes[Int(rng.next() % UInt64(codes.count))]
            if index % 37 == 0 {
                let before = random.heldOutputKeys
                let injected = feed(&random, .init(.down, keyCode: code, isInjected: true))
                try require(injected == RemapDecision() && random.heldOutputKeys == before, "injected event changed state")
            }
            let input: RemapInput
            if sources.contains(code) {
                if rng.next() % 3 == 0 { input = .init(.down, keyCode: code, isRepeat: true) }
                else { input = .init(.up, keyCode: code); sources.remove(code) }
            } else { input = .init(.down, keyCode: code); sources.insert(code) }
            let result = feed(&random, input)
            try require(result.suppressOriginal, "mapped random source leaked")
            try observe(result.outputs)
            try require(random.physicalHeld == sources, "physical held state diverged")
        }
        try observe(random.releaseAll())
        try require(outputKeys.isEmpty && mediaOwners == 0 && random.heldOutputKeys.isEmpty && random.physicalHeld.isEmpty,
                    "final release left a held output")
        for code in sources {
            let up = feed(&random, .init(.up, keyCode: code))
            try require(up.suppressOriginal && up.outputs.isEmpty, "final physical release escaped quarantine")
        }
        return checked
    }
}
