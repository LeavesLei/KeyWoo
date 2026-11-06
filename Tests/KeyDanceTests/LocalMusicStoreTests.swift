import AVFoundation
import Foundation
import Testing
@testable import KeyDance

struct LocalMusicStoreTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyWooMusicTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func writeAudio(at url: URL, duration: Double = 0.25) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let frames = AVAudioFrameCount(duration * 16_000)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        pcm.frameLength = frames
        for i in 0..<Int(frames) { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 440 * 2 * .pi / 16_000) * 0.1) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: pcm)
    }

    @Test @MainActor func importCreatesOwnedCopyAndReloadsWithoutOriginalPath() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("A quiet day.wav")
        try writeAudio(at: source)
        let original = try Data(contentsOf: source)
        let library = root.appendingPathComponent("Library")
        let store = LocalMusicStore(directory: library)
        let imported = await store.importFile(at: source)
        let track = try #require(imported)
        #expect(track.title == "A quiet day")
        #expect(abs(track.duration - 0.25) < 0.001)
        #expect(!store.isImporting)
        let copyURL = try #require(store.fileURL(for: track))
        #expect(copyURL != source)
        #expect(try Data(contentsOf: copyURL) == original)
        #expect(try Data(contentsOf: source) == original)
        let archive = try String(contentsOf: library.appendingPathComponent("library.json"), encoding: .utf8)
        #expect(!archive.contains(source.path))
        let reloaded = LocalMusicStore(directory: library)
        #expect(reloaded.importedTracks == [track])
        #expect(reloaded.fileURL(for: track) == copyURL)
        try FileManager.default.removeItem(at: source)
        #expect(reloaded.fileURL(for: track) != nil, "Playback must not depend on the user's original location after import.")
    }

    @Test @MainActor func invalidImportPreservesExistingLibraryAndCleansStaging() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("valid.wav")
        try writeAudio(at: source)
        let library = root.appendingPathComponent("Library")
        let store = LocalMusicStore(directory: library)
        let imported = await store.importFile(at: source)
        let first = try #require(imported)
        let before = try Data(contentsOf: library.appendingPathComponent("library.json"))
        let invalid = root.appendingPathComponent("broken.mp3")
        try Data("not an audio stream".utf8).write(to: invalid)
        let rejected = await store.importFile(at: invalid)
        #expect(rejected == nil)
        #expect(store.importedTracks == [first])
        #expect(store.errorMessage != nil)
        #expect(try Data(contentsOf: library.appendingPathComponent("library.json")) == before)
        let contents = try FileManager.default.contentsOfDirectory(atPath: library.path)
        #expect(contents.sorted() == ["library.json", first.fileName].sorted())
    }

    @Test @MainActor func removeDeletesOnlyOwnedCopyAndPreservesSource() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.wav")
        try writeAudio(at: source)
        let library = root.appendingPathComponent("Library")
        let store = LocalMusicStore(directory: library)
        let imported = await store.importFile(at: source)
        let track = try #require(imported)
        let copy = try #require(store.fileURL(for: track))
        let removed = store.removeImportedTrack(id: track.id)
        #expect(removed)
        #expect(store.importedTracks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(LocalMusicStore(directory: library).importedTracks.isEmpty)
    }

    @Test @MainActor func corruptManifestCannotBeOverwrittenByImport() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("music.wav")
        try writeAudio(at: source)
        let library = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let manifest = library.appendingPathComponent("library.json")
        let damaged = Data("{incomplete existing manifest".utf8)
        try damaged.write(to: manifest)
        let store = LocalMusicStore(directory: library)
        #expect(store.errorMessage != nil)
        let result = await store.importFile(at: source)
        #expect(result == nil)
        #expect(try Data(contentsOf: manifest) == damaged)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.path) == ["library.json"])
    }

    @Test @MainActor func pathTraversalAndSymlinkCannotEscapeOwnedLibrary() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("outside.wav")
        try writeAudio(at: source)
        let store = LocalMusicStore(directory: library)
        let traversal = LocalMusicTrack(id: "local:test", title: "outside", duration: 1, fileName: "../outside.wav", importedAt: Date())
        #expect(store.fileURL(for: traversal) == nil)
        let link = library.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let linked = LocalMusicTrack(id: "local:link", title: "link", duration: 1, fileName: "link.wav", importedAt: Date())
        #expect(store.fileURL(for: linked) == nil)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test @MainActor func failedManifestCommitRollsBackImportAndRemoval() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.wav")
        try writeAudio(at: source)
        let library = root.appendingPathComponent("Library")
        let store = LocalMusicStore(directory: library)
        let imported = await store.importFile(at: source)
        let track = try #require(imported)
        let copy = try #require(store.fileURL(for: track))
        let originalCopy = try Data(contentsOf: copy)
        let manifest = library.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: manifest)
        // A directory occupying the manifest path reliably makes atomic commit
        // fail without changing file permissions or affecting the real library.
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        let removed = store.removeImportedTrack(id: track.id)
        #expect(!removed)
        #expect(store.importedTracks == [track])
        #expect(try Data(contentsOf: copy) == originalCopy)
        let second = await store.importFile(at: source)
        #expect(second == nil)
        #expect(store.importedTracks == [track])
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.path).sorted() == ["library.json", track.fileName].sorted())
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}
