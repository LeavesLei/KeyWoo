import AVFoundation
import AudioAtomics
import Combine
import CryptoKit
import Foundation
import Darwin

enum KeyboardSoundQuality: String, CaseIterable, Identifiable, Sendable {
    case original, hiFi
    var id: String { rawValue }
    var title: String { L(self == .original ? "原音" : "Hi-Fi 高保真") }
}

enum KeyboardSoundCategory: String, CaseIterable, Identifiable, Sendable {
    case recorded, fun
    var id: String { rawValue }
    var title: String { L(self == .recorded ? "键盘实录" : "趣味音效") }
}

enum KeyboardSoundStyle: String, CaseIterable, Identifiable, Sendable {
    case red, blue, brown, black, oreo, purple, topre, panda, mahjong
    case bluePBT, brownABS, blackABS
    case typewriter, bubble, woodblock, paper, raindrop, brick, arcade, laser, streetBeat
    case macbookPro, hermes, mahjongTiles, woodDesk
    var id: String { rawValue }
    var category: KeyboardSoundCategory {
        switch self {
        case .mahjong, .typewriter, .bubble, .woodblock, .paper, .raindrop, .brick, .arcade, .laser, .streetBeat,
             .hermes, .mahjongTiles, .woodDesk: return .fun
        default: return .recorded
        }
    }
    var title: String {
        switch self {
        case .red: return L("Cherry 红轴 · ABS")
        case .blue: return L("Cherry 青轴 · ABS")
        case .brown: return L("Cherry 茶轴 · PBT")
        case .black: return L("Cherry 黑轴 · PBT")
        case .oreo: return "Everglide Oreo"
        case .purple: return L("Everglide 水晶紫")
        case .topre: return L("Topre 静电容")
        case .panda: return "Holy Panda"
        case .mahjong: return L("麻将")
        case .bluePBT: return L("Cherry 青轴 · PBT")
        case .brownABS: return L("Cherry 茶轴 · ABS")
        case .blackABS: return L("Cherry 黑轴 · ABS")
        case .typewriter: return L("打字机")
        case .bubble: return L("泡泡")
        case .woodblock: return L("木鱼")
        case .paper: return L("纸笺")
        case .raindrop: return L("水滴")
        case .brick: return L("积木")
        case .arcade: return L("街机")
        case .laser: return L("激光")
        case .streetBeat: return L("街舞节拍")
        case .macbookPro: return L("MacBook Pro 键盘")
        case .hermes: return L("Hermes 打字机")
        case .mahjongTiles: return L("麻将牌实录")
        case .woodDesk: return L("木桌轻叩")
        }
    }
    var subtitle: String {
        switch self {
        case .red: return L("顺滑线性，原始 ABS 键帽录音")
        case .blue: return L("清脆点击，原始 ABS 键帽录音")
        case .brown: return L("轻柔段落，原始 PBT 键帽录音")
        case .black: return L("低沉扎实，原始 PBT 键帽录音")
        case .oreo: return L("圆润段落，保留键帽与回弹细节")
        case .purple: return L("明亮段落，按键起落清晰")
        case .topre: return L("柔软厚实，静电容键盘录音")
        case .panda: return L("饱满段落，独立按下与松开录音")
        case .mahjong: return L("合成瓷牌碰击，非真实麻将录音")
        case .bluePBT: return L("清亮点击，另一套 PBT 键帽实录")
        case .brownABS: return L("轻巧段落，另一套 ABS 键帽实录")
        case .blackABS: return L("扎实触底，另一套 ABS 键帽实录")
        case .typewriter: return L("金属字锤与短促机械回弹")
        case .bubble: return L("柔软啵声，轻盈弹开")
        case .woodblock: return L("温暖木质敲击，干净收尾")
        case .paper: return L("短促纸张揉折与轻擦")
        case .raindrop: return L("清脆水珠落下，不含背景雨声")
        case .brick: return L("塑料积木卡扣，短而扎实")
        case .arcade: return L("复古像素短音，不自动播放旋律")
        case .laser: return L("轻巧科幻扫频，快速收尾")
        case .streetBeat: return L("低音底鼓、紧实军鼓和清脆踩镲")
        case .macbookPro: return L("短行程轻触，带自然回弹")
        case .hermes: return L("金属字锤、空格与行尾铃")
        case .mahjongTiles: return L("真实牌面轻碰，大键更扎实")
        case .woodDesk: return L("指尖叩木，轻重有别")
        }
    }
    var characterTags: [String] {
        switch self {
        case .red, .black, .blackABS: return [L("线性"), L("实录")]
        case .blue, .bluePBT: return [L("点击"), L("实录")]
        case .brown, .brownABS, .oreo, .purple, .panda: return [L("段落"), L("实录")]
        case .topre, .macbookPro, .woodDesk: return [L("柔和"), L("实录")]
        case .hermes: return [L("复古"), L("实录")]
        case .mahjongTiles: return [L("硬质"), L("实录")]
        case .mahjong, .brick: return [L("硬质"), L("合成")]
        case .typewriter: return [L("复古"), L("合成")]
        case .bubble, .raindrop: return [L("轻盈"), L("合成")]
        case .woodblock, .paper: return [L("自然拟音"), L("合成")]
        case .arcade, .laser: return [L("电子"), L("合成")]
        case .streetBeat: return [L("嘻哈"), L("合成")]
        }
    }
    var symbol: String {
        switch self {
        case .red: return "circle.fill"
        case .blue, .bluePBT: return "sparkle"
        case .brown, .brownABS: return "circle.lefthalf.filled"
        case .black, .blackABS: return "circle.inset.filled"
        case .oreo: return "circle.dotted.circle.fill"
        case .purple: return "diamond.fill"
        case .topre: return "capsule.fill"
        case .panda: return "circle.grid.2x2.fill"
        case .mahjong, .mahjongTiles: return "rectangle.on.rectangle"
        case .typewriter, .hermes: return "keyboard"
        case .bubble: return "bubbles.and.sparkles"
        case .woodblock, .woodDesk: return "tree.fill"
        case .paper: return "doc.text"
        case .raindrop: return "drop.fill"
        case .brick: return "cube.fill"
        case .arcade: return "gamecontroller.fill"
        case .laser: return "bolt.fill"
        case .streetBeat: return "music.note"
        case .macbookPro: return "laptopcomputer"
        }
    }
    var isRecorded: Bool {
        switch self {
        case .hermes, .mahjongTiles, .woodDesk: return true
        default: return category == .recorded
        }
    }
    var usesNativeFoley: Bool { !isRecorded && self != .streetBeat }
    var sourceLabel: String { L(isRecorded ? "真实录音" : "合成拟音") }
    var sourceTitle: String {
        switch self {
        case .panda: return "Thomas Lai / kbsim"
        case .macbookPro, .hermes, .woodDesk: return "Joseph Sardin / BigSoundBank"
        case .mahjongTiles: return "Detective_Lemons / Freesound"
        default: return isRecorded ? "Hải Nguyễn / Mechvibes" : L("键舞合成音效")
        }
    }
    var sourceURL: String? {
        switch self {
        case .panda: return "https://github.com/tplai/kbsim"
        case .macbookPro: return "https://bigsoundbank.com/slow-macbook-pro-keyboard-2-s1729.html"
        case .hermes: return "https://bigsoundbank.com/typewriter-key-s2842.html"
        case .mahjongTiles: return "https://freesound.org/people/Detective_Lemons/sounds/785585/"
        case .woodDesk: return "https://bigsoundbank.com/impatient-finger-tapping-2-s1428.html"
        default: return isRecorded ? "https://github.com/hainguyents13/mechvibes" : nil
        }
    }
    var sourceDescription: String {
        switch self {
        case .panda: return L("五种普通键录音，空格、回车、退格分别采录；其余键复用普通键。")
        case .macbookPro: return L("从一段 MacBook Pro 打字录音挑选成对的触底与回弹。按键按音色分组，原录音未标键位。")
        case .hermes: return L("Hermes Precisa 305 实录。空格用原机空格声，回车用原机行尾铃，其余键轮换真实字锤声。")
        case .mahjongTiles, .woodDesk: return L("从实物录音选取独立短音。大键用另一组真实敲击，松开时静音。")
        case .mahjong: return L("程序合成的瓷牌拟音，不是实物录音。")
        case .streetBeat:
            return L("原创嘻哈鼓组。空格是底鼓，回车是军鼓，Shift 是拍手，退格是鼓边，Tab 是开镲，字母是闭镲。按下触发，松开静音。")
        default:
            return isRecorded ? L("原始键位录音，部分键位复用相近声音；可清楚分离的回弹跟随松开，其余保留完整敲击。") :
                L("原创程序合成；普通键与大键分别设计，包含按下、松开和三种细微变化，不是实物录音。")
        }
    }
}

enum KeyboardSoundKeyFamily: Int, CaseIterable, Sendable {
    case ordinary, space, enter, backspace, tab, modifier
    static func forKeyCode(_ code: UInt16) -> Self {
        switch code {
        case 49: return .space
        case 36, 76: return .enter
        case 51, 117: return .backspace
        case 48: return .tab
        case 54...63: return .modifier
        default: return .ordinary
        }
    }
}

struct KeyboardSoundSnapshot: Sendable {
    var attacks: UInt64 = 0
    var releases: UInt64 = 0
    var activeVoices = 0
    var maximumActiveVoices = 0
    var renderedFrames: UInt64 = 0
    var renderedBuffers: UInt64 = 0
    var droppedEvents: UInt64 = 0
    var peak = 0.0
    var rms = 0.0
    /// Queue time is enqueue → render callback consumption, not key-to-ear latency.
    var renderedAttacksWithTiming: UInt64 = 0
    var meanQueueSeconds = 0.0
    var maximumQueueSeconds = 0.0
    var lastQueueSeconds = 0.0
    var maximumRenderFrames = 0
}

struct KeyboardRecordingInfo: Sendable {
    let clipCount: Int
    let mappedKeyCount: Int
    let separateReleaseKeyCount: Int
    let sha256: String
}

/// Immutable PCM, decoded or deterministically synthesized before device start.
/// The render thread does no synthesis, resource loading, or graph rebuilding.
private final class KeyboardSoundBank: @unchecked Sendable {
    static let rate = 48_000.0
    static let variants = 3
    static let shared = KeyboardSoundBank()
    struct Clip {
        let samples: UnsafeMutablePointer<Float>
        let frames: Int
        let channels: Int
        var normalizationGain: Float = 1
    }
    private(set) var clips: [Clip] = []
    private(set) var loudness: [KeyboardSoundStyle: KeyboardLoudness.Profile] = [:]
    private(set) var hiFiLoudness: [KeyboardSoundStyle: KeyboardLoudness.Profile] = [:]
    private var mappings: [KeyboardSoundStyle: [UInt16: Pair]] = [:]
    private var fallbacks: [KeyboardSoundStyle: Pair] = [:]
    private var synthesizedOffsets: [KeyboardSoundStyle: Int] = [:]
    private var hiFiDeltas: [KeyboardSoundStyle: Int] = [:]
    private(set) var failures: Set<KeyboardSoundStyle> = []
    private(set) var information: [KeyboardSoundStyle: KeyboardRecordingInfo] = [:]
    private struct Pair: Decodable { let down: [Int]; let up: [Int] }
    private struct Entry: Decodable { let startFrame: Int; let frames: Int }
    private struct Pack: Decodable {
        let sampleRate: Double, channels: Int, file: String, sha256: String, frames: Int
        let clips: [Entry], keys: [String: Pair], fallback: Pair
    }
    private struct Manifest: Decodable { let schema: Int, sampleRate: Double; let packs: [String: Pack] }
    private struct HiFiPack: Decodable { let file: String, sha256: String, originalSHA256: String }
    private struct HiFiManifest: Decodable { let schema: Int, sampleRate: Double; let packs: [String: HiFiPack] }
    private enum LoadingFailure: Error { case missing, invalid }
    func supportsHiFi(for style: KeyboardSoundStyle) -> Bool { hiFiDeltas[style] != nil }
    func index(style: KeyboardSoundStyle, key: UInt16, released: Bool, variant: Int,
               quality: KeyboardSoundQuality = .original) -> Int {
        if let offset = synthesizedOffsets[style] {
            let family = KeyboardSoundKeyFamily.forKeyCode(key)
            return offset + (family.rawValue * 2 + (released ? 1 : 0)) * Self.variants + variant % Self.variants
        }
        guard let pair = mappings[style]?[key] ?? fallbacks[style] else { return -1 }
        let indices = released ? pair.up : pair.down
        guard !indices.isEmpty else { return -1 }
        let delta = quality == .hiFi ? hiFiDeltas[style, default: 0] : 0
        return indices[variant % indices.count] + delta
    }
    private func variantCount(style: KeyboardSoundStyle, key: UInt16) -> Int {
        if synthesizedOffsets[style] != nil { return Self.variants }
        guard let pair = mappings[style]?[key] ?? fallbacks[style] else { return 0 }
        return max(pair.down.count, pair.up.count)
    }
    static func resources() -> URL? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            // A packaged app must stand on its own. Missing resources report an
            // error, never fall through to a developer checkout or Bundle.module.
            return Bundle.main.resourceURL?.appendingPathComponent("KeyboardSounds")
        }
        var candidates: [URL] = []
        if let root = Bundle.main.resourceURL {
            candidates.append(root.appendingPathComponent("KeyboardSounds"))
            candidates.append(root.appendingPathComponent("KeyDance_KeyDance.bundle/KeyboardSounds"))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/KeyDance/Resources/KeyboardSounds"))
        #if SWIFT_PACKAGE
        // SwiftPM tests always have a resource bundle. Packaged applications
        // resolve Bundle.main first, avoiding a missing-module-bundle trap.
        if candidates.contains(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }) == false {
            candidates.append(Bundle.module.bundleURL.appendingPathComponent("KeyboardSounds"))
        }
        #endif
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
    }
    init(resourceURL: URL? = nil) {
        var result: [Clip] = []
        for style in KeyboardSoundStyle.allCases where style.usesNativeFoley {
            synthesizedOffsets[style] = result.count
            for family in KeyboardSoundKeyFamily.allCases {
                for released in [false, true] {
                    for variant in 0..<Self.variants {
                        let pcm = style == .mahjong
                            ? Self.synthesizeMahjong(family: family, released: released, variant: variant)
                            : Self.synthesizeEffect(style: style, family: family, released: released, variant: variant)
                        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: pcm.count)
                        pcm.withUnsafeBufferPointer { pointer.initialize(from: $0.baseAddress!, count: $0.count) }
                        result.append(Clip(samples: pointer, frames: pcm.count, channels: 1))
                    }
                }
            }
        }
        let root = resourceURL ?? Self.resources()
        func read<T: Decodable>(_ name: String, as type: T.Type) -> T? {
            root.flatMap { try? Data(contentsOf: $0.appendingPathComponent(name)) }
                .flatMap { try? JSONDecoder().decode(type, from: $0) }
        }
        let manifest = read("manifest.json", as: Manifest.self)
        let streetBeatManifest = read("street-beat-manifest.json", as: Manifest.self)
        let hiFiManifest = read("hifi-manifest.json", as: HiFiManifest.self)
        for style in KeyboardSoundStyle.allCases where synthesizedOffsets[style] == nil {
            do {
                let styleManifest = style == .streetBeat ? streetBeatManifest : manifest
                guard let root, let manifest = styleManifest, manifest.schema == 1, manifest.sampleRate == Self.rate,
                      let pack = manifest.packs[style.rawValue] else { throw LoadingFailure.missing }
                let offset = result.count
                let loaded = try Self.load(pack: pack, style: style, root: root)
                result.append(contentsOf: loaded)
                func translated(_ pair: Pair) -> Pair { Pair(down: pair.down.map { $0 + offset }, up: pair.up.map { $0 + offset }) }
                mappings[style] = Dictionary(uniqueKeysWithValues: pack.keys.map { (UInt16($0.key)!, translated($0.value)) })
                fallbacks[style] = translated(pack.fallback)
                if style.isRecorded {
                    information[style] = KeyboardRecordingInfo(clipCount: loaded.count, mappedKeyCount: pack.keys.count,
                        separateReleaseKeyCount: pack.keys.values.filter { !$0.up.isEmpty }.count, sha256: pack.sha256)
                    // Companions share clip boundaries and mapping with the verified original.
                    // An optional missing, stale or corrupt companion never disables Original.
                    if let hiFiManifest, hiFiManifest.schema == 1, hiFiManifest.sampleRate == Self.rate,
                       let companion = hiFiManifest.packs[style.rawValue],
                       companion.originalSHA256 == pack.sha256,
                       companion.file == "\(style.rawValue)/samples-hifi.wav",
                       let polished = try? Self.loadClips(pack: pack, root: root, path: companion.file, sha256: companion.sha256) {
                        hiFiDeltas[style] = result.count - offset
                        result.append(contentsOf: polished)
                    }
                }
            } catch { failures.insert(style) }
        }
        clips = result
        loudness = prepareLoudness(quality: .original)
        hiFiLoudness = prepareLoudness(quality: .hiFi)
    }
    deinit { for clip in clips { clip.samples.deallocate() } }

    /// The bank is shared and prepared once before starting any output device.
    /// One gain covers every contact of a preset, preserving key size, release
    /// balance, stereo imaging and the source WAVs. No analysis in the callback.
    private func prepareLoudness(quality: KeyboardSoundQuality) -> [KeyboardSoundStyle: KeyboardLoudness.Profile] {
        var measurements: [Int: KeyboardLoudness.Measurement] = [:]
        var profiles: [KeyboardSoundStyle: KeyboardLoudness.Profile] = [:]
        for style in KeyboardSoundStyle.allCases where !failures.contains(style) && (quality == .original || supportsHiFi(for: style)) {
            var energy = 0.0, peak = 0.0, styleClips = Set<Int>()
            for (key, weight) in KeyboardLoudness.calibrationKeys {
                let count = variantCount(style: style, key: key)
                for variant in 0..<count {
                    for released in [false, true] {
                        let id = index(style: style, key: key, released: released, variant: variant, quality: quality)
                        guard clips.indices.contains(id) else { continue }
                        styleClips.insert(id)
                        if measurements[id] == nil {
                            let clip = clips[id]
                            measurements[id] = KeyboardLoudness.measure(samples: UnsafePointer(clip.samples),
                                frames: clip.frames, channels: clip.channels)
                        }
                        let value = measurements[id]!
                        energy += value.energy * weight / Double(count)
                    }
                }
            }
            // Include infrequently used keys in peak protection and apply the
            // exact same gain to them; their own levels never set a new target.
            for key: UInt16 in 0..<128 {
                for variant in 0..<variantCount(style: style, key: key) {
                    for released in [false, true] {
                        let id = index(style: style, key: key, released: released, variant: variant, quality: quality)
                        if clips.indices.contains(id) { styleClips.insert(id) }
                    }
                }
            }
            for id in styleClips {
                let clip = clips[id]
                for sample in 0..<(clip.frames * clip.channels) { peak = max(peak, Double(abs(clip.samples[sample]))) }
            }
            let profile = KeyboardLoudness.profile(energy: energy, peak: peak)
            profiles[style] = profile
            for id in styleClips { clips[id].normalizationGain = profile.gain }
        }
        return profiles
    }

    /// Export the exact precomputed synthesis cache for other platform clients.
    /// Float WAV preserves every source sample; no device, mixer, or volume is
    /// involved. Explicit tooling only, never invoked during app startup.
    func exportSynthesizedResources(to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var packs: [String: Any] = [:]
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!
        var fileSettings = format.settings
        fileSettings[AVLinearPCMIsNonInterleaved] = false
        for style in KeyboardSoundStyle.allCases {
            guard let offset = synthesizedOffsets[style] else { continue }
            let selected = Array(clips[offset..<(offset + KeyboardSoundKeyFamily.allCases.count * 2 * Self.variants)])
            let total = selected.reduce(0) { $0 + $1.frames }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
            buffer.frameLength = AVAudioFrameCount(total)
            var cursor = 0, entries: [[String: Any]] = []
            for (index, clip) in selected.enumerated() {
                for frame in 0..<clip.frames {
                    buffer.floatChannelData![0][cursor + frame] = clip.samples[frame * clip.channels]
                    buffer.floatChannelData![1][cursor + frame] = clip.samples[frame * clip.channels + (clip.channels == 2 ? 1 : 0)]
                }
                entries.append(["startFrame": cursor, "frames": clip.frames,
                    "family": index / (Self.variants * 2), "edge": (index / Self.variants) % 2 == 0 ? "down" : "up",
                    "variant": index % Self.variants, "origin": "original-procedural-foley"])
                cursor += clip.frames
            }
            let folder = root.appendingPathComponent(style.rawValue)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("samples.wav")
            // Close the file before hashing so its WAV header is finalized.
            do { let file = try AVAudioFile(forWriting: url, settings: fileSettings); try file.write(from: buffer) }
            var keys: [String: Any] = [:]
            for key: UInt16 in 0..<128 {
                let first = KeyboardSoundKeyFamily.forKeyCode(key).rawValue * Self.variants * 2
                keys[String(key)] = ["down": Array(first..<(first + Self.variants)),
                    "up": Array((first + Self.variants)..<(first + Self.variants * 2))]
            }
            packs[style.rawValue] = ["file": "\(style.rawValue)/samples.wav", "sampleRate": Self.rate,
                "channels": 2, "frames": total, "clips": entries, "keys": keys,
                "fallback": ["down": [0, 1, 2], "up": [3, 4, 5]],
                "sha256": SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined(),
                "recorded": false, "license": "Original KeyWoo generated audio; distributed with the application", "author": "KeyWoo"]
        }
        let manifest: [String: Any] = ["schema": 1, "sampleRate": Self.rate, "packs": packs,
            "source": "KeyboardSoundEngine.swift deterministic foley cache",
            "processing": "Original synthesis, pre-volume, pre-limiter, no sampled third-party recordings."]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("synthetic-manifest.json"), options: .atomic)
    }

    private static func load(pack: Pack, style: KeyboardSoundStyle, root: URL) throws -> [Clip] {
        guard pack.file == "\(style.rawValue)/samples.wav", pack.sampleRate == rate, pack.channels == 2,
              pack.frames > 0, pack.frames < 48_000 * 60, !pack.clips.isEmpty, pack.clips.count < 1_000,
              !pack.keys.isEmpty, pack.keys.count <= 512, !pack.fallback.down.isEmpty,
              Set(pack.keys.keys.compactMap(UInt16.init)).count == pack.keys.count else { throw LoadingFailure.invalid }
        for (key, pair) in pack.keys {
            guard UInt16(key) != nil, !pair.down.isEmpty,
                  pair.up.isEmpty || pair.up.count == pair.down.count || (style == .panda && pair.up.count == 1),
                  (pair.down + pair.up).allSatisfy({ pack.clips.indices.contains($0) }) else { throw LoadingFailure.invalid }
        }
        guard (pack.fallback.down + pack.fallback.up).allSatisfy({ pack.clips.indices.contains($0) }),
              pack.fallback.up.isEmpty || pack.fallback.up.count == pack.fallback.down.count || (style == .panda && pack.fallback.up.count == 1),
              pack.clips.allSatisfy({ $0.startFrame >= 0 && $0.frames > 0 && $0.frames < 48_000 && $0.startFrame <= pack.frames - $0.frames }) else { throw LoadingFailure.invalid }
        return try loadClips(pack: pack, root: root, path: pack.file, sha256: pack.sha256)
    }

    private static func loadClips(pack: Pack, root: URL, path: String, sha256: String) throws -> [Clip] {
        let url = root.appendingPathComponent(path)
        let data = try Data(contentsOf: url)
        guard data.count < 25_000_000,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else { throw LoadingFailure.invalid }
        let file = try AVAudioFile(forReading: url)
        guard file.length == AVAudioFramePosition(pack.frames), file.processingFormat.sampleRate == rate,
              file.processingFormat.channelCount == 2,
              let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(pack.frames)) else { throw LoadingFailure.invalid }
        try file.read(into: pcm)
        guard Int(pcm.frameLength) == pack.frames, let channels = pcm.floatChannelData else { throw LoadingFailure.invalid }
        for frame in 0..<pack.frames {
            guard channels[0][frame].isFinite, channels[1][frame].isFinite,
                  abs(channels[0][frame]) <= 0.32, abs(channels[1][frame]) <= 0.32 else { throw LoadingFailure.invalid }
        }
        var result: [Clip] = []; result.reserveCapacity(pack.clips.count)
        for entry in pack.clips {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: entry.frames * 2)
            for frame in 0..<entry.frames {
                pointer[frame * 2] = channels[0][entry.startFrame + frame]
                pointer[frame * 2 + 1] = channels[1][entry.startFrame + frame]
            }
            result.append(Clip(samples: pointer, frames: entry.frames, channels: 2))
        }
        return result
    }

    private struct Noise {
        var state: UInt64
        mutating func next() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state & 0xFFFFFF) / Double(0x7FFFFF) - 1
        }
    }
    private struct Resonator {
        var a: Double, b: Double, scale: Double
        var previous = 0.0, older = 0.0
        init(frequency: Double, decay: Double) {
            let radius = exp(-1 / (KeyboardSoundBank.rate * decay))
            a = 2 * radius * cos(2 * .pi * frequency / KeyboardSoundBank.rate)
            b = radius * radius
            scale = 1 - radius
        }
        mutating func process(_ input: Double) -> Double {
            let output = input * scale + a * previous - b * older
            older = previous; previous = output
            return output
        }
    }
    /// Original short foley, with different excitation/material models per
    /// effect. This runs only during bank preparation, never in the callback.
    private static func synthesizeEffect(style: KeyboardSoundStyle, family: KeyboardSoundKeyFamily,
                                         released: Bool, variant: Int) -> [Float] {
        let material: Int
        let baseLength: Double
        switch style {
        case .typewriter: material = 1; baseLength = 0.084
        case .bubble: material = 2; baseLength = 0.070
        case .woodblock: material = 3; baseLength = 0.076
        case .paper: material = 4; baseLength = 0.091
        case .raindrop: material = 5; baseLength = 0.081
        case .brick: material = 6; baseLength = 0.058
        case .arcade: material = 7; baseLength = 0.065
        case .laser: material = 8; baseLength = 0.087
        default: preconditionFailure("Recorded sources and original Mahjong have separate preparation paths")
        }
        let size = [1.0, 1.38, 1.23, 0.88, 1.08, 0.83][family.rawValue]
        let color = [1.0, 0.69, 0.84, 1.17, 0.94, 1.08][family.rawValue]
        let jitter = [0.973, 1.0, 1.031][variant]
        let length = baseLength * size * (released ? 0.62 : 1)
        let frames = Int(ceil(length * rate))
        var random = Noise(state: UInt64(0x281345 + material * 3571 + family.rawValue * 137 + variant * 31 + (released ? 919 : 0)))
        var body = Resonator(frequency: Double([0, 590, 430, 740, 1400, 980, 920, 350, 510][material]) * color * jitter,
                             decay: (material == 3 ? 0.011 : 0.006) * size)
        var edge = Resonator(frequency: Double([0, 3187, 1780, 1883, 3700, 2890, 2473, 1820, 2600][material]) * color * jitter,
                             decay: (material == 1 ? 0.004 : 0.0028) * size)
        var samples = [Float](repeating: 0, count: frames)
        var low = 0.0, lower = 0.0, previous = 0.0, phase = 0.0, filtered = 0.0
        var peak = 0.0
        let contactTime = (released ? 0.0006 : 0.0011) * size
        let colorScale = color * jitter * (released ? 1.14 : 1)
        for i in 0..<frames {
            let t = Double(i) / rate
            let n = random.next()
            low += (n - low) * 0.43
            lower += (low - lower) * 0.16
            let high = low - previous; previous = low
            let contact = exp(-t / contactTime)
            var value = 0.0
            switch style {
            case .typewriter:
                // Metal typebar contact, escapement tick, then spring return.
                let secondTime = (released ? 0.006 : 0.012) * size
                let thirdTime = 0.025 * size
                let second = t >= secondTime ? exp(-(t - secondTime) / 0.0012) : 0
                let third = !released && t >= thirdTime ? exp(-(t - thirdTime) / 0.0018) : 0
                let excitation = lower * contact + high * second * 0.72 + low * third * 0.27
                value = excitation * 0.38 + body.process(excitation) * 7.2 + edge.process(excitation) * 5.8
            case .bubble:
                // A short pressure pop with a falling, heavily damped cavity.
                let frequency = (320 + 820 * exp(-t / 0.0048)) * colorScale
                phase += 2 * .pi * frequency / rate
                let cavity = sin(phase) * exp(-t / (0.0088 * size))
                value = lower * contact * 0.37 + cavity * 0.24 + body.process(lower * contact) * 1.5
            case .woodblock:
                let excitation = lower * contact
                value = excitation * 0.29 + body.process(excitation) * 13 + edge.process(excitation) * 4.1
                // Larger surfaces produce a muted second contact, not a bell.
                if family == .space && t >= 0.015 { value += lower * exp(-(t - 0.015) / 0.0018) * 0.09 }
            case .paper:
                // Broad-band irregular folds, with no periodic/pitched body.
                let fold1 = exp(-t / 0.009)
                let fold2 = t >= 0.008 * size ? exp(-(t - 0.008 * size) / 0.013) : 0
                let fold3 = t >= 0.027 * size ? exp(-(t - 0.027 * size) / 0.008) : 0
                let grain = 0.25 + 0.75 * abs(n)
                value = (high * 0.48 + lower * 0.43) * (fold1 + 0.53 * fold2 + 0.19 * fold3) * grain
            case .raindrop:
                // Water impact followed by a very brief rising bubble cavity.
                let frequency = (850 + 1_900 * (1 - exp(-t / 0.012))) * colorScale
                phase += 2 * .pi * frequency / rate
                value = lower * contact * 0.22 + sin(phase) * exp(-t / (0.009 * size)) * 0.13
                value += edge.process(low * contact) * 2.3
                if !released && family == .enter && t >= 0.027 { value += low * exp(-(t - 0.027) / 0.0023) * 0.11 }
            case .brick:
                // A hollow plastic snap with a little friction at the catch.
                let latchTime = (released ? 0.004 : 0.007) * size
                let latch = t >= latchTime ? exp(-(t - latchTime) / 0.0019) : 0
                let excitation = low * contact + high * latch * 0.46
                value = excitation * 0.42 + body.process(excitation) * 6.4 + edge.process(excitation) * 2.8
                value += lower * exp(-t / 0.005) * 0.10
            case .arcade:
                // One brief lo-fi button chirp, not an autonomous melody.
                let step = Int(t / (0.008 * size))
                let steps = [1.0, 1.0, 0.75, 0.5]
                let frequency = (released ? 580.0 : 720.0) * colorScale * steps[min(3, step)]
                phase += frequency / rate
                let pulse = phase - floor(phase) < (released ? 0.25 : 0.375) ? 1.0 : -1.0
                filtered += (pulse - filtered) * 0.28
                value = filtered * exp(-t / (0.009 * size)) * 0.14 + lower * contact * 0.07
            case .laser:
                let frequency = (190 + (released ? 1_050 : 2_100) * exp(-t / (0.014 * size))) * colorScale
                phase += 2 * .pi * frequency / rate
                value = (sin(phase) + 0.16 * sin(phase * 1.73)) * exp(-t / (0.014 * size)) * 0.14
                value += high * contact * 0.11
            default: break
            }
            let attack = min(1, t / 0.00032)
            let tail = max(0, min(1, Double(frames - 1 - i) / (rate * 0.004)))
            value *= attack * tail
            samples[i] = Float(value); peak = max(peak, abs(value))
        }
        let familyGain = [1.0, 1.06, 1.11, 0.94, 0.98, 0.77][family.rawValue]
        // Similar ordinary-key peaks, but preserve the designed envelope and
        // spectral differences. Key-up is a small separate physical gesture.
        let gain = 0.18 * familyGain * (released ? 0.34 : 1) / max(peak, 1e-9)
        for i in samples.indices { samples[i] *= Float(gain) }
        return samples
    }

    private static func synthesizeMahjong(family: KeyboardSoundKeyFamily, released: Bool, variant: Int) -> [Float] {
        let style = KeyboardSoundStyle.mahjong
        let materialIndex = 3
        let familyPitch: [Double] = [1, 0.62, 0.78, 1.13, 0.91, 0.86]
        let familyLength: [Double] = [1, 1.42, 1.25, 0.92, 1.06, 0.95]
        let durations: [Double] = [0.047, 0.063, 0.057, 0.091]
        let length = durations[materialIndex] * familyLength[family.rawValue] * (released ? 0.65 : 1)
        let count = Int((length * rate).rounded(.up))
        let variantScale = [0.974, 1.0, 1.028][variant]
        let pitch = familyPitch[family.rawValue] * variantScale * (released ? 1.17 : 1)
        let seed = UInt64(11 + materialIndex * 701 + family.rawValue * 47 + variant * 13 + (released ? 191 : 0))
        var noise = Noise(state: seed * 0x12345 + 0x98765)
        let bodyFrequency: [Double] = [310, 440, 365, 730]
        let bodyDecay: [Double] = [0.0065, 0.0045, 0.007, 0.006]
        let bodyTime = bodyDecay[materialIndex] * familyLength[family.rawValue] * (released ? 0.68 : 1)
        var body = Resonator(frequency: bodyFrequency[materialIndex] * pitch, decay: bodyTime)
        var shell = Resonator(frequency: [847, 1_413, 1_067, 2_170][materialIndex] * pitch, decay: bodyTime * 0.59)
        var edge = Resonator(frequency: [1_734, 3_791, 2_113, 3_863][materialIndex] * pitch, decay: bodyTime * 0.31)
        let cutoff: Double = style == .red ? 2_000 : style == .brown ? 3_500 : style == .mahjong ? 5_500 : 6_600
        let smoothing = 1 - exp(-2 * .pi * cutoff / rate)
        var low = 0.0, lower = 0.0, previousLow = 0.0
        var samples = [Float](repeating: 0, count: count)
        var peak = 0.0
        for frame in 0..<count {
            let t = Double(frame) / rate
            let random = noise.next()
            low += (random - low) * smoothing
            lower += (low - lower) * smoothing
            let high = low - previousLow
            previousLow = low
            let contact = exp(-t / (released ? 0.00065 : 0.0013))
            let bodyNoise = lower * contact
            var impact = bodyNoise
            if style == .blue {
                let second = max(0, t - (released ? 0.0018 : 0.0032))
                let click = t >= (released ? 0.0018 : 0.0032) ? exp(-second / 0.00075) : 0
                impact += high * click * 1.9
            } else if style == .brown {
                let bumpTime = 0.0038
                if t >= bumpTime { impact += lower * exp(-(t - bumpTime) / 0.0016) * 0.72 }
            } else if style == .mahjong {
                // Two very short hard-surface contacts, not a tuned bell tail.
                if t >= 0.0056 { impact += low * exp(-(t - 0.0056) / 0.00125) * 0.70 }
                if !released && t >= 0.0125 { impact += low * exp(-(t - 0.0125) / 0.0016) * 0.26 }
            }
            var rattle = 0.0
            if family == .space || family == .enter {
                let offset = family == .space ? 0.0065 : 0.0042
                if t >= offset {
                    rattle = (low - lower) * exp(-(t - offset) / (released ? 0.0025 : 0.005))
                    impact += rattle * (family == .space ? 0.55 : 0.28)
                }
            }
            let material = body.process(impact) * (style == .mahjong ? 5.8 : 8.0)
                + shell.process(impact) * (style == .mahjong ? 5.0 : 3.7)
                + edge.process(impact) * (style == .red ? 0.65 : style == .mahjong ? 3.8 : 2.2)
            let transient = impact * (style == .red ? 0.23 : style == .brown ? 0.30 : 0.42)
            let start = min(1, t / 0.00045)
            let end = min(1, Double(count - 1 - frame) / (rate * 0.003))
            let value = (material + transient + rattle * 0.11) * start * max(0, end)
            samples[frame] = Float(value)
            peak = max(peak, abs(value))
        }
        let basePeak: [Double] = [0.185, 0.165, 0.18, 0.19]
        let familyGain = family == .space ? 1.04 : family == .enter ? 1.08 : family == .modifier ? 0.80 : 1
        let gain = basePeak[materialIndex] * familyGain * (released ? 0.42 : 1) / max(peak, 0.000001)
        for frame in samples.indices { samples[frame] *= Float(gain) }
        return samples
    }
}

private struct KeyboardSoundCommand {
    var clip = 0, key: UInt16 = 0
    var released = false, preview = false
    var generation: UInt64 = 0
    var previewGeneration: UInt64 = 0
    var pan: Float = 0
    var enqueuedHostTime: UInt64 = 0
}

/// One main-thread writer and one audio-thread reader. Release/acquire atomics
/// publish POD commands and telemetry. All sample/voice/queue storage is allocated
/// before start; the render callback never waits for a lock or creates an object.
private final class KeyboardSoundRenderCore: @unchecked Sendable {
    static let maximumVolume = 16.0
    static let maximumVoices = 24
    static let queueCapacity = 512
    private let bank: KeyboardSoundBank
    private let normalizationEnabled: Bool
    private let commands: UnsafeMutablePointer<KeyboardSoundCommand>
    private let voices: UnsafeMutablePointer<Voice>
    private let writeIndex = KWAtomicCounterCreate(0)!, readIndex = KWAtomicCounterCreate(0)!
    private let generation = KWAtomicCounterCreate(1)!, active = KWAtomicCounterCreate(0)!
    private let previewGeneration = KWAtomicCounterCreate(1)!
    private let desiredVolume = KWAtomicCounterCreate(Double(0.55).bitPattern)!
    private let dropped = KWAtomicCounterCreate(0)!
    private let meterAttacks = KWAtomicCounterCreate(0)!, meterReleases = KWAtomicCounterCreate(0)!
    private let meterVoices = KWAtomicCounterCreate(0)!, meterMaxVoices = KWAtomicCounterCreate(0)!
    private let meterFrames = KWAtomicCounterCreate(0)!, meterBuffers = KWAtomicCounterCreate(0)!
    private let meterRMS = KWAtomicCounterCreate(0)!, meterPeak = KWAtomicCounterCreate(0)!
    private let meterTimedAttacks = KWAtomicCounterCreate(0)!, meterQueueTotal = KWAtomicCounterCreate(0)!
    private let meterQueueMax = KWAtomicCounterCreate(0)!, meterQueueLast = KWAtomicCounterCreate(0)!
    private let meterMaxRenderFrames = KWAtomicCounterCreate(0)!
    private let secondsPerHostTick: Double
    private var timedAttacks: UInt64 = 0
    private var totalQueueSeconds = 0.0, maximumQueueSeconds = 0.0, lastQueueSeconds = 0.0
    private var maximumRenderFrames = 0
    private var localGeneration: UInt64 = 1, serial: UInt64 = 0
    private var localPreviewGeneration: UInt64 = 1
    private var attacks: UInt64 = 0, releases: UInt64 = 0, framesRendered: UInt64 = 0, buffers: UInt64 = 0
    private var maximumActive = 0
    private var smoothedVolume: Float = 0.55
    private let volumeSmoothing: Float = Float(1 - exp(-1 / (KeyboardSoundBank.rate * 0.005)))

    private struct Voice {
        var clip = -1, cursor = 0, wait = 0, fade = -1
        var key: UInt16 = 0
        var released = false, preview = false
        var serial: UInt64 = 0, startFrame: UInt64 = 0
        var gainL: Float = 1, gainR: Float = 1
        // Immutable clip storage belongs to bank, which outlives every voice.
        var samples: UnsafePointer<Float>? = nil
        var sampleFrames = 0, channels = 1
    }
    init(bank: KeyboardSoundBank, normalizationEnabled: Bool = true) {
        self.bank = bank
        self.normalizationEnabled = normalizationEnabled
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerHostTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        commands = .allocate(capacity: Self.queueCapacity)
        commands.initialize(repeating: KeyboardSoundCommand(), count: Self.queueCapacity)
        voices = .allocate(capacity: Self.maximumVoices)
        voices.initialize(repeating: Voice(), count: Self.maximumVoices)
    }
    deinit {
        commands.deallocate(); voices.deallocate()
        for counter in [writeIndex, readIndex, generation, previewGeneration, active, desiredVolume, dropped, meterAttacks,
                        meterReleases, meterVoices, meterMaxVoices, meterFrames, meterBuffers, meterRMS, meterPeak,
                        meterTimedAttacks, meterQueueTotal, meterQueueMax, meterQueueLast, meterMaxRenderFrames] {
            KWAtomicCounterDestroy(counter)
        }
    }
    func setVolume(_ value: Double) {
        let clamped = value.isFinite ? min(Self.maximumVolume, max(0, value)) : 0
        KWAtomicCounterStore(desiredVolume, clamped.bitPattern)
    }
    func setActive(_ value: Bool) { KWAtomicCounterStore(active, value ? 1 : 0) }
    func invalidateVoices() { KWAtomicCounterStore(generation, KWAtomicCounterLoad(generation) &+ 1) }
    func invalidatePreviews() { KWAtomicCounterStore(previewGeneration, KWAtomicCounterLoad(previewGeneration) &+ 1) }
    func enqueue(clip: Int, key: UInt16, released: Bool, preview: Bool, pan: Float) {
        let write = KWAtomicCounterLoad(writeIndex), read = KWAtomicCounterLoad(readIndex)
        guard write - read < UInt64(Self.queueCapacity) else {
            KWAtomicCounterStore(dropped, KWAtomicCounterLoad(dropped) &+ 1); return
        }
        commands[Int(write % UInt64(Self.queueCapacity))] = KeyboardSoundCommand(clip: clip, key: key,
            released: released, preview: preview, generation: KWAtomicCounterLoad(generation),
            previewGeneration: KWAtomicCounterLoad(previewGeneration), pan: pan, enqueuedHostTime: mach_absolute_time())
        KWAtomicCounterStore(writeIndex, write &+ 1)
    }
    /// Caller has stopped the device callback (or uses the single-thread offline
    /// harness). This is never used to recycle queue slots under a live reader.
    func clearWhileQuiescent() {
        invalidateVoices()
        localGeneration = KWAtomicCounterLoad(generation)
        localPreviewGeneration = KWAtomicCounterLoad(previewGeneration)
        KWAtomicCounterStore(readIndex, KWAtomicCounterLoad(writeIndex))
        for index in 0..<Self.maximumVoices { voices[index] = Voice() }
        KWAtomicCounterStore(meterVoices, 0); KWAtomicCounterStore(meterRMS, 0); KWAtomicCounterStore(meterPeak, 0)
        smoothedVolume = Float(Double(bitPattern: KWAtomicCounterLoad(desiredVolume)))
    }
    func snapshot() -> KeyboardSoundSnapshot {
        KeyboardSoundSnapshot(attacks: KWAtomicCounterLoad(meterAttacks), releases: KWAtomicCounterLoad(meterReleases),
            activeVoices: Int(KWAtomicCounterLoad(meterVoices)), maximumActiveVoices: Int(KWAtomicCounterLoad(meterMaxVoices)),
            renderedFrames: KWAtomicCounterLoad(meterFrames), renderedBuffers: KWAtomicCounterLoad(meterBuffers),
            droppedEvents: KWAtomicCounterLoad(dropped), peak: Double(bitPattern: KWAtomicCounterLoad(meterPeak)),
            rms: Double(bitPattern: KWAtomicCounterLoad(meterRMS)),
            renderedAttacksWithTiming: KWAtomicCounterLoad(meterTimedAttacks),
            meanQueueSeconds: Double(bitPattern: KWAtomicCounterLoad(meterQueueTotal)) / Double(max(1, KWAtomicCounterLoad(meterTimedAttacks))),
            maximumQueueSeconds: Double(bitPattern: KWAtomicCounterLoad(meterQueueMax)),
            lastQueueSeconds: Double(bitPattern: KWAtomicCounterLoad(meterQueueLast)),
            maximumRenderFrames: Int(KWAtomicCounterLoad(meterMaxRenderFrames)))
    }
    private func add(_ command: KeyboardSoundCommand, at frameTime: UInt64) {
        // A complete one-shot may deliberately have no separate key-up clip.
        // Count the real release event without inventing another sound.
        if command.clip < 0 {
            if command.released { releases &+= 1 }
            return
        }
        var index = -1, oldest = UInt64.max, activeCount = 0
        var wait = 0
        for candidate in 0..<Self.maximumVoices {
            let voice = voices[candidate]
            if voice.clip < 0 { if index < 0 { index = candidate }; continue }
            activeCount += 1
            if command.released && !voice.released && voice.key == command.key && voice.preview == command.preview {
                let age = frameTime >= voice.startFrame ? Int(frameTime - voice.startFrame) : 0
                let minimumGate = command.preview ? 3_360 : 576
                wait = max(wait, max(0, minimumGate - age))
            }
        }
        if index < 0 {
            // Bounded overload: recycle the oldest, usually quiet, transient.
            // Dense typing is gain-reduced and final output has a soft ceiling.
            for candidate in 0..<Self.maximumVoices where voices[candidate].serial < oldest {
                oldest = voices[candidate].serial; index = candidate
            }
        }
        serial &+= 1
        // Normal typing retains the recording's dynamics. Only exceptional
        // overlapping transients are softened; quiet tails alone must not make
        // an ordinary 10–15 keys/second passage noticeably quieter.
        let densityGain = Float(1 / sqrt(1 + 0.08 * Double(max(0, activeCount - 8))))
        let pan = max(-0.12, min(0.12, command.pan))
        let clip = bank.clips[command.clip]
        let gain = densityGain * (normalizationEnabled ? clip.normalizationGain : 1)
        voices[index] = Voice(clip: command.clip, wait: wait, key: command.key, released: command.released,
            preview: command.preview, serial: serial, startFrame: frameTime,
            gainL: gain * (1 - max(0, pan)), gainR: gain * (1 + min(0, pan)),
            samples: UnsafePointer(clip.samples), sampleFrames: clip.frames, channels: clip.channels)
        if command.released { releases &+= 1 } else { attacks &+= 1 }
        maximumActive = max(maximumActive, min(Self.maximumVoices, activeCount + 1))
    }
    private func drainCommands(enabled: Bool, frameTime: UInt64, budget: inout Int) {
        let epoch = KWAtomicCounterLoad(generation)
        let previewEpoch = KWAtomicCounterLoad(previewGeneration)
        if epoch != localGeneration || previewEpoch != localPreviewGeneration {
            for index in 0..<Self.maximumVoices where voices[index].clip >= 0 {
                guard epoch != localGeneration || voices[index].preview else { continue }
                // A reset must not later start an already queued return click.
                if voices[index].wait > 0 { voices[index].clip = -1 }
                else { voices[index].fade = voices[index].fade >= 0 ? min(240, voices[index].fade) : 240 }
            }
            localGeneration = epoch
            localPreviewGeneration = previewEpoch
        }
        let end = KWAtomicCounterLoad(writeIndex)
        var read = KWAtomicCounterLoad(readIndex)
        // At most the fixed queue capacity is consumed per callback.
        while read < end && budget > 0 {
            let command = commands[Int(read % UInt64(Self.queueCapacity))]
            // A reset/new press can arrive between our epoch and write-index
            // loads. Leave that future command queued for the next callback.
            if command.generation > epoch { break }
            if command.generation == epoch && command.preview && command.previewGeneration > previewEpoch { break }
            if enabled && command.generation == epoch && (!command.preview || command.previewGeneration == previewEpoch) {
                if !command.released {
                    let now = mach_absolute_time()
                    lastQueueSeconds = now >= command.enqueuedHostTime ? Double(now - command.enqueuedHostTime) * secondsPerHostTick : 0
                    totalQueueSeconds += lastQueueSeconds
                    maximumQueueSeconds = max(maximumQueueSeconds, lastQueueSeconds)
                    timedAttacks &+= 1
                }
                add(command, at: frameTime)
            }
            read &+= 1; budget -= 1
        }
        KWAtomicCounterStore(readIndex, read)
    }
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let enabled = KWAtomicCounterLoad(active) != 0
        var commandBudget = Self.queueCapacity
        let volume = Float(Double(bitPattern: KWAtomicCounterLoad(desiredVolume)))
        var energy = 0.0, peak = 0.0
        for frame in 0..<frames {
            // A press arriving while a large callback is being filled need not
            // wait another entire device quantum. Work remains bounded to 512
            // commands total per callback, with no locks or allocation.
            if frame & 63 == 0 {
                drainCommands(enabled: enabled, frameTime: framesRendered + UInt64(frame), budget: &commandBudget)
            }
            var l: Float = 0, r: Float = 0
            if enabled {
                for index in 0..<Self.maximumVoices where voices[index].clip >= 0 {
                    if voices[index].wait > 0 { voices[index].wait -= 1; continue }
                    let cursor = voices[index].cursor, channels = voices[index].channels
                    let samples = voices[index].samples!
                    var sampleL = samples[cursor * channels]
                    var sampleR = samples[cursor * channels + (channels == 2 ? 1 : 0)]
                    if voices[index].fade >= 0 {
                        let fadeGain = Float(voices[index].fade) / 240
                        sampleL *= fadeGain; sampleR *= fadeGain
                        voices[index].fade -= 1
                    }
                    l += sampleL * voices[index].gainL; r += sampleR * voices[index].gainR
                    voices[index].cursor += 1
                    if voices[index].cursor >= voices[index].sampleFrames || voices[index].fade == 0 { voices[index].clip = -1 }
                }
            }
            smoothedVolume += (volume - smoothedVolume) * volumeSmoothing
            // Preserve existing gain settings through 400%. Extra boost uses
            // the same .84 knee and .98 ceiling, so quiet contacts still grow.
            let normalGain = min(1, smoothedVolume), boost = max(1, smoothedVolume)
            l = Self.limit(l * normalGain) * boost; r = Self.limit(r * normalGain) * boost
            if smoothedVolume > 2 { l = Self.boostLimit(l); r = Self.boostLimit(r) }
            left[frame] = l; right[frame] = r
            energy += Double(l) * Double(l) + Double(r) * Double(r)
            peak = max(peak, Double(abs(l)), Double(abs(r)))
        }
        framesRendered &+= UInt64(frames); buffers &+= 1
        var voiceCount = 0
        for index in 0..<Self.maximumVoices where voices[index].clip >= 0 { voiceCount += 1 }
        KWAtomicCounterStore(meterAttacks, attacks); KWAtomicCounterStore(meterReleases, releases)
        KWAtomicCounterStore(meterVoices, UInt64(voiceCount)); KWAtomicCounterStore(meterMaxVoices, UInt64(maximumActive))
        KWAtomicCounterStore(meterFrames, framesRendered); KWAtomicCounterStore(meterBuffers, buffers)
        KWAtomicCounterStore(meterRMS, sqrt(energy / Double(max(1, frames * 2))).bitPattern)
        KWAtomicCounterStore(meterPeak, peak.bitPattern)
        maximumRenderFrames = max(maximumRenderFrames, frames)
        KWAtomicCounterStore(meterTimedAttacks, timedAttacks)
        KWAtomicCounterStore(meterQueueTotal, totalQueueSeconds.bitPattern)
        KWAtomicCounterStore(meterQueueMax, maximumQueueSeconds.bitPattern)
        KWAtomicCounterStore(meterQueueLast, lastQueueSeconds.bitPattern)
        KWAtomicCounterStore(meterMaxRenderFrames, UInt64(maximumRenderFrames))
    }
    private static func boostLimit(_ value: Float) -> Float {
        let magnitude = abs(value)
        return magnitude <= 0.84 ? value : (value < 0 ? -1 : 1) * (0.84 + 0.14 * tanh((magnitude - 0.84) / 0.14))
    }
    private static func limit(_ value: Float) -> Float {
        let magnitude = abs(value)
        return magnitude <= 0.25 ? value : (value < 0 ? -1 : 1) * (0.25 + 0.17 * tanh((magnitude - 0.25) / 0.17))
    }
}

/// Independent from SoundEngine and its music transport. Callers choose which
/// mode receives input; this engine never starts, pauses, or changes any music.
@MainActor
final class KeyboardSoundEngine: ObservableObject {
    var style: KeyboardSoundStyle = .red {
        didSet {
            if style != oldValue {
                releaseAll()
                if bank.failures.contains(style) {
                    stop(); errorMessage = L("键盘音效资源缺失或损坏，请重新安装应用。")
                } else { errorMessage = nil }
            }
        }
    }
    var quality: KeyboardSoundQuality = .original {
        didSet { if quality != oldValue { cancelPreview() } }
    }
    var volume: Double = 0.55 { didSet { core.setVolume(volume) } }
    @Published private(set) var errorMessage: String?
    @Published private(set) var outputLevel = 0.0
    @Published private(set) var isRunning = false
    private let audioDeviceEnabled: Bool
    private let bank: KeyboardSoundBank
    private let core: KeyboardSoundRenderCore
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var meterTimer: Timer?
    private var held: [UInt16: (variant: Int, quality: KeyboardSoundQuality)] = [:]
    private var variantCounter = 0
    private var previewTask: Task<Void, Never>?
    var heldKeyCount: Int { held.count }
    var diagnostics: KeyboardSoundSnapshot { core.snapshot() }
    func recordingInfo(for style: KeyboardSoundStyle) -> KeyboardRecordingInfo? { bank.information[style] }
    func supportsHiFi(for style: KeyboardSoundStyle) -> Bool { bank.supportsHiFi(for: style) }
    func loudnessProfile(for style: KeyboardSoundStyle, quality: KeyboardSoundQuality = .original) -> KeyboardLoudness.Profile? {
        (quality == .hiFi ? bank.hiFiLoudness[style] : nil) ?? bank.loudness[style]
    }
    func hasIndependentRelease(keyCode: UInt16) -> Bool { bank.index(style: style, key: keyCode, released: true, variant: 0) >= 0 }
    static let sampleRate = KeyboardSoundBank.rate
    static let maximumVoices = KeyboardSoundRenderCore.maximumVoices
    static let maximumVolume = KeyboardSoundRenderCore.maximumVolume
    /// OS-reported output presentation latency; this is not an end-to-end measurement.
    var outputPresentationLatency: TimeInterval { engine?.outputNode.presentationLatency ?? 0 }
    static var recordingResourcesURL: URL? { KeyboardSoundBank.resources() }
    static func exportSynthesizedResources(to url: URL) throws { try KeyboardSoundBank.shared.exportSynthesizedResources(to: url) }

    init(audioDeviceEnabled: Bool = true, recordingResourceURL: URL? = nil,
         normalizationEnabled: Bool = true) {
        precondition(normalizationEnabled || !audioDeviceEnabled, "Raw output is reserved for offline calibration verification.")
        self.audioDeviceEnabled = audioDeviceEnabled
        let bank = recordingResourceURL.map { KeyboardSoundBank(resourceURL: $0) } ?? KeyboardSoundBank.shared
        self.bank = bank
        core = KeyboardSoundRenderCore(bank: bank, normalizationEnabled: normalizationEnabled)
        held.reserveCapacity(128)
    }
    deinit {
        previewTask?.cancel()
        meterTimer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine?.stop()
    }
    func start() {
        guard !isRunning else { return }
        guard !bank.failures.contains(style) else {
            errorMessage = L("键盘音效资源缺失或损坏，请重新安装应用。")
            return
        }
        errorMessage = nil
        do {
            // There is no active callback here. Latch the chosen initial volume
            // before first audio, so a zero-volume launch is exactly silent.
            core.clearWhileQuiescent()
            if audioDeviceEnabled {
                if engine == nil { configureEngine() }
                try engine?.start()
            }
            core.setActive(true); isRunning = true
            if audioDeviceEnabled && meterTimer == nil {
                meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.refreshMeter() }
                }
            }
        } catch {
            core.setActive(false); isRunning = false
            errorMessage = L("键盘音效无法启动，请重新开启音效。")
        }
    }
    func stop() {
        cancelPreview()
        core.setActive(false)
        engine?.stop()
        core.clearWhileQuiescent()
        held.removeAll(keepingCapacity: true)
        meterTimer?.invalidate(); meterTimer = nil
        isRunning = false; outputLevel = 0
    }
    func noteOn(keyCode: UInt16) {
        guard isRunning, held[keyCode] == nil else { return }
        cancelPreview()
        let variant = variantCounter
        variantCounter &+= 1; held[keyCode] = (variant, quality)
        enqueue(keyCode: keyCode, released: false, variant: variant, quality: quality, preview: false)
    }
    func noteOff(keyCode: UInt16) {
        // A held key releases with the same recording as its original attack.
        guard isRunning, let press = held.removeValue(forKey: keyCode) else { return }
        enqueue(keyCode: keyCode, released: true, variant: press.variant, quality: press.quality, preview: false)
    }
    /// Focus/mode reset is a brief fade, not a synthetic set of key-up sounds.
    func releaseAll() {
        cancelPreview()
        held.removeAll(keepingCapacity: true)
        core.invalidateVoices()
    }
    /// Preview owns no physical key. The render core gives it a natural 70ms
    /// down/up interval; the physical Caps Lock guard remains only 12ms.
    func preview(keyCode: UInt16 = 49) {
        cancelPreview()
        previewOne(keyCode: keyCode)
    }
    func previewSequence() {
        cancelPreview()
        guard isRunning else { return }
        let hits: [(milliseconds: Int, keys: [UInt16])]
        if style == .streetBeat {
            // One bar at 96 BPM, with swung sixteenths and layered backbeats.
            hits = [(0, [49, 0]), (177, [0]), (313, [0]), (489, [0]),
                    (625, [36, 56, 0]), (802, [0]), (938, [49, 0]), (1114, [51]),
                    (1250, [49, 0]), (1427, [0]), (1563, [0]), (1739, [0]),
                    (1875, [36, 56, 0]), (2052, [0]), (2188, [48])]
        } else {
            hits = [(0, [0]), (140, [1]), (280, [2]), (540, [49]), (850, [36]), (1150, [51])]
        }
        previewTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            for (index, hit) in hits.enumerated() {
                if hit.milliseconds > 0 {
                    try? await clock.sleep(until: start.advanced(by: .milliseconds(hit.milliseconds)))
                }
                guard !Task.isCancelled, let self, self.isRunning else { return }
                for key in hit.keys { self.previewOne(keyCode: key, variant: index) }
            }
        }
    }
    func cancelPreview() {
        previewTask?.cancel(); previewTask = nil
        core.invalidatePreviews()
    }
    private func previewOne(keyCode: UInt16, variant: Int? = nil) {
        guard isRunning else { return }
        let selected = variant ?? variantCounter
        if variant == nil { variantCounter &+= 1 }
        enqueue(keyCode: keyCode, released: false, variant: selected, quality: quality, preview: true)
        enqueue(keyCode: keyCode, released: true, variant: selected, quality: quality, preview: true)
    }
    private func enqueue(keyCode: UInt16, released: Bool, variant: Int, quality: KeyboardSoundQuality, preview: Bool) {
        let family = KeyboardSoundKeyFamily.forKeyCode(keyCode)
        let clip = bank.index(style: style, key: keyCode, released: released, variant: variant, quality: quality)
        // Very narrow mechanical placement; wide stereo would make rapid text
        // entry tiring. Large keys remain centered.
        let pan: Float = !style.isRecorded && family == .ordinary ? Float(Int(keyCode) % 7 - 3) * 0.025 : 0
        core.enqueue(clip: clip, key: keyCode, released: released, preview: preview, pan: pan)
    }
    private func configureEngine() {
        let newEngine = AVAudioEngine(), core = core
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2)!
        let source = AVAudioSourceNode(format: format) { _, _, count, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            core.render(frames: Int(count), left: left, right: right)
            return noErr
        }
        newEngine.attach(source)
        newEngine.connect(source, to: newEngine.mainMixerNode, format: format)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                         object: newEngine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning, self.engine?.isRunning == false else { return }
                do { try self.engine?.start(); self.errorMessage = nil }
                catch { self.stop(); self.errorMessage = L("键盘音效无法启动，请重新开启音效。") }
            }
        }
        engine = newEngine
    }
    private func refreshMeter() {
        let value = min(1, diagnostics.rms * 9)
        let next = value < 0.0001 ? 0 : value
        if abs(next - outputLevel) >= 0.002 || (next == 0 && outputLevel != 0) { outputLevel = next }
    }
    /// Exactly the production mixer/cache path, without an audio device. Tests
    /// control event timing by rendering between calls; allocations are outside
    /// the realtime callback. Interleaved stereo, 48kHz, Float32.
    func renderForVerification(frames: Int) -> [Float] {
        precondition(!audioDeviceEnabled && frames >= 0)
        guard frames > 0 else { return [] }
        var left = [Float](repeating: 0, count: frames), right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in core.render(frames: frames, left: l.baseAddress!, right: r.baseAddress!) }
        }
        var result = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames { result[frame * 2] = left[frame]; result[frame * 2 + 1] = right[frame] }
        refreshMeter()
        return result
    }

    /// Allocation-free offline entry for sustained stress testing. The caller
    /// owns two writable buffers of at least `frames` samples and serializes
    /// calls on the main actor. Never usable alongside a hardware callback.
    func renderIntoForVerification(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        precondition(!audioDeviceEnabled && frames >= 0)
        if frames > 0 { core.render(frames: frames, left: left, right: right) }
    }
}
