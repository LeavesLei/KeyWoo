import AVFoundation
import Combine
import Foundation

struct LocalMusicTrack: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let duration: TimeInterval
    let fileName: String
    let importedAt: Date
}

/// Owns copies of imported music, never modifies or deletes the user's source.
/// The legacy app-data root intentionally remains KeyDance after the UI rename.
@MainActor
final class LocalMusicStore: ObservableObject {
    @Published private(set) var importedTracks: [LocalMusicTrack] = []
    @Published private(set) var isImporting = false
    @Published private(set) var errorMessage: String?

    let directory: URL
    private let manifestURL: URL
    private var canWrite = true

    private struct Archive: Codable { let version: Int; let tracks: [LocalMusicTrack] }
    private enum StoreError: LocalizedError {
        case corruptLibrary, invalidAudio, unavailableSource, unsafeRecord
        var errorDescription: String? {
            switch self {
            case .corruptLibrary: return L("本机音乐库暂时无法读取，已保留原文件。请先检查音乐库文件。")
            case .invalidAudio: return L("这份音频无法播放，或没有有效音频内容。请换一个 MP3、M4A、WAV、AIFF 或 FLAC 文件。")
            case .unavailableSource: return L("找不到这份音频文件。请确认文件已下载到本机。")
            case .unsafeRecord: return L("音乐库记录无效，已停止操作以保留原文件。")
            }
        }
    }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KeyDance", isDirectory: true).appendingPathComponent("Music", isDirectory: true)
        manifestURL = self.directory.appendingPathComponent("library.json")
        load()
    }

    func fileURL(for track: LocalMusicTrack) -> URL? {
        guard Self.validFileName(track.fileName) else { return nil }
        let url = directory.appendingPathComponent(track.fileName)
        guard Self.isOwnedRegularFile(url, in: directory) else { return nil }
        return url
    }

    func clearError() { errorMessage = nil }

    /// Copies and validates away from the main thread. The existing library is
    /// published only after both the complete file and its manifest are saved.
    @discardableResult
    func importFile(at source: URL) async -> LocalMusicTrack? {
        guard !isImporting else { return nil }
        guard canWrite else { errorMessage = StoreError.corruptLibrary.localizedDescription; return nil }
        isImporting = true
        errorMessage = nil
        let destination = directory
        let previous = importedTracks
        defer { isImporting = false }
        do {
            let track = try await Task.detached(priority: .userInitiated) {
                try Self.copyAndCommit(source: source, directory: destination, previous: previous)
            }.value
            importedTracks.append(track)
            return track
        } catch {
            errorMessage = Lf("导入失败：%@", L(error.localizedDescription))
            return nil
        }
    }

    /// Removes only this app's own copy. An interrupted metadata write rolls the
    /// move back, so the prior library stays usable. Source files are never known.
    @discardableResult
    func removeImportedTrack(id: String) -> Bool {
        guard !isImporting, canWrite, let track = importedTracks.first(where: { $0.id == id }) else { return false }
        guard Self.validFileName(track.fileName) else { errorMessage = StoreError.unsafeRecord.localizedDescription; return false }
        let source = directory.appendingPathComponent(track.fileName)
        let quarantine = directory.appendingPathComponent(".removed-\(UUID().uuidString)")
        let fm = FileManager.default
        var moved = false
        do {
            if fm.fileExists(atPath: source.path) {
                guard Self.isOwnedRegularFile(source, in: directory) else { throw StoreError.unsafeRecord }
                try fm.moveItem(at: source, to: quarantine)
                moved = true
            }
            let remaining = importedTracks.filter { $0.id != id }
            try Self.writeManifest(remaining, directory: directory)
            importedTracks = remaining
            errorMessage = nil
            if moved { try? fm.removeItem(at: quarantine) }
            return true
        } catch {
            if moved { try? fm.moveItem(at: quarantine, to: source) }
            errorMessage = Lf("未能移除音乐：%@", L(error.localizedDescription))
            return false
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: manifestURL))
            guard archive.version == 1, Set(archive.tracks.map(\.id)).count == archive.tracks.count,
                  Set(archive.tracks.map(\.fileName)).count == archive.tracks.count,
                  archive.tracks.allSatisfy({ Self.validFileName($0.fileName) && $0.id.hasPrefix("local:") && $0.duration.isFinite && $0.duration > 0 }) else {
                throw StoreError.corruptLibrary
            }
            importedTracks = archive.tracks
        } catch {
            canWrite = false
            errorMessage = StoreError.corruptLibrary.localizedDescription
        }
    }

    private nonisolated static func validFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
            && name == URL(fileURLWithPath: name).lastPathComponent
    }

    private nonisolated static func isOwnedRegularFile(_ url: URL, in directory: URL) -> Bool {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        return true
    }

    private nonisolated static func copyAndCommit(source: URL, directory: URL, previous: [LocalMusicTrack]) throws -> LocalMusicTrack {
        let fm = FileManager.default
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard source.isFileURL, fm.fileExists(atPath: source.path),
              (try source.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw StoreError.unavailableSource
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let uuid = UUID().uuidString.lowercased()
        let sourceExtension = source.pathExtension.lowercased()
        let ext = sourceExtension.allSatisfy({ $0.isLetter || $0.isNumber }) && sourceExtension.count <= 8 && !sourceExtension.isEmpty ? sourceExtension : "audio"
        let name = "\(uuid).\(ext)"
        let stagedDirectory = directory.appendingPathComponent(".import-\(uuid)", isDirectory: true)
        let staged = stagedDirectory.appendingPathComponent(name)
        let final = directory.appendingPathComponent(name)
        try fm.createDirectory(at: stagedDirectory, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stagedDirectory) }
        try fm.copyItem(at: source, to: staged)
        let audio: AVAudioFile
        do { audio = try AVAudioFile(forReading: staged) }
        catch { throw StoreError.invalidAudio }
        let format = audio.processingFormat
        let duration = Double(audio.length) / format.sampleRate
        guard duration.isFinite, duration > 0, format.sampleRate > 0, format.channelCount > 0,
              let sample = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(min(audio.length, 4096))) else {
            throw StoreError.invalidAudio
        }
        do { try audio.read(into: sample) } catch { throw StoreError.invalidAudio }
        guard sample.frameLength > 0 else { throw StoreError.invalidAudio }
        let title = source.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let track = LocalMusicTrack(id: "local:\(uuid)", title: title.isEmpty ? "本机音乐" : title,
                                    duration: duration, fileName: name, importedAt: Date())
        try fm.moveItem(at: staged, to: final)
        do { try writeManifest(previous + [track], directory: directory) }
        catch { try? fm.removeItem(at: final); throw error }
        return track
    }

    private nonisolated static func writeManifest(_ tracks: [LocalMusicTrack], directory: URL) throws {
        let data = try JSONEncoder().encode(Archive(version: 1, tracks: tracks))
        try data.write(to: directory.appendingPathComponent("library.json"), options: .atomic)
    }
}
