import Foundation

struct MusicTrack: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var bpm: Int?
    var duration: TimeInterval
    var url: URL?
    var isBuiltIn: Bool
    var isGenerative: Bool { url?.scheme == "keywoo-ai" }
    var displayTitle: String { isBuiltIn ? L(title) : title }
    var displaySubtitle: String { L(subtitle) }

    init(id: String, title: String, subtitle: String, bpm: Int? = nil,
         duration: TimeInterval = 0, url: URL? = nil, isBuiltIn: Bool = false) {
        self.id = id; self.title = title; self.subtitle = subtitle
        self.bpm = bpm; self.duration = duration; self.url = url; self.isBuiltIn = isBuiltIn
    }
}

enum MusicLibrary {
    static var generativeTrack: MusicTrack? {
        guard GenerativeMusicRuntime.locate() != nil else { return nil }
        return MusicTrack(id: "local-ai", title: "AI · 乐句共奏", subtitle: "音乐持续 · 词句推动变奏",
                          url: URL(string: "keywoo-ai://local"), isBuiltIn: true)
    }
    static let builtInTracks: [MusicTrack] = [
        MusicTrack(id: "after-hours", title: "After Hours", subtitle: "夜色书桌 · 温暖 Lo-fi",
                   bpm: 78, duration: 128 * 60.0 / 78, isBuiltIn: true),
        MusicTrack(id: "soft-current", title: "Soft Current", subtitle: "柔光流动 · 轻电子",
                   bpm: 88, duration: 128 * 60.0 / 88, isBuiltIn: true)
    ]

    static func url(for track: MusicTrack) -> URL? {
        if let url = track.url { return url }
        guard track.isBuiltIn, builtInTracks.contains(where: { $0.id == track.id }) else { return nil }
        let filename = "keywoo-\(track.id).wav"
        let directories = [
            Bundle.main.resourceURL?.appendingPathComponent("Music", isDirectory: true),
            Bundle.main.bundleURL.appendingPathComponent("KeyDance_KeyDance.bundle/Music", isDirectory: true),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("KeyDance_KeyDance.bundle/Music", isDirectory: true),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/Music", isDirectory: true),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/KeyDance/Resources/Music", isDirectory: true)
        ].compactMap { $0 }
        return directories.map { $0.appendingPathComponent(filename) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
