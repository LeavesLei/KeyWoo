import Foundation

/// Optional local research runtime. The portable app still works without the
/// separately downloaded model; availability never triggers a download.
struct GenerativeMusicRuntime {
    let pythonURL: URL
    let workerURL: URL
    let modelDirectory: URL

    static func locate() -> Self? {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let roots = [
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent(),
            sourceRoot,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ]
        let workers = [
            Bundle.main.resourceURL?.appendingPathComponent("AI/mrt2-live-worker.py"),
            sourceRoot.appendingPathComponent("Sources/KeyDance/Resources/AI/mrt2-live-worker.py")
        ].compactMap { $0 }
        let files = FileManager.default
        guard let worker = workers.first(where: { files.fileExists(atPath: $0.path) }) else { return nil }
        for root in roots {
            let python = root.appendingPathComponent(".build/mrt2-venv/bin/python")
            let models = root.appendingPathComponent(".build/mrt2-assets")
            let verified = models.appendingPathComponent("verified-runtime.json")
            let checkpoint = models.appendingPathComponent("magenta-rt-v2/models/mrt2_small/mrt2_small.mlxfn")
            guard files.isExecutableFile(atPath: python.path), files.fileExists(atPath: verified.path), files.fileExists(atPath: checkpoint.path) else { continue }
            return Self(pythonURL: python, workerURL: worker, modelDirectory: models)
        }
        return nil
    }
}

enum MusicPlaybackFactory {
    static func make(url: URL) throws -> MusicPlayback {
        if url.scheme == "keywoo-ai" {
            guard let runtime = GenerativeMusicRuntime.locate() else {
                throw NSError(domain: "KeyWooAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "本机音乐模型尚未准备好，请先选择内置音乐。"])
            }
            return try PhraseMusicPlayback(runtime: runtime)
        }
        return try NativeMusicPlayback(url: url)
    }
}
