import Foundation
import SwiftUI
import AppKit

@main
@MainActor
enum Launcher {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--audio-demo"), arguments.count > index + 1 {
            do {
                let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                let paths = try OfflineSoundRenderer.writeDemos(to: directory)
                paths.forEach { print($0.path) }
            } catch {
                fputs("Audio demo failed: \(error)\n", stderr)
                exit(1)
            }
            return
        }
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("KeyDance", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let lockURL = directory.appendingPathComponent("instance.lock")
            guard let lease = try ProcessInstanceLock.acquire(at: lockURL) else {
                activateExistingInstance(lockURL: lockURL)
                return
            }
            // Keep the descriptor alive throughout SwiftUI/AppKit's event loop.
            // No AppModel, statistics store, or audio engine exists before here.
            withExtendedLifetime(lease) { KeyDanceApp.main() }
        } catch {
            fputs("KeyWoo could not acquire its instance lock: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func activateExistingInstance(lockURL: URL) {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            if let pid = ProcessInstanceLock.ownerProcessIdentifier(at: lockURL), pid != getpid(),
               let application = NSRunningApplication(processIdentifier: pid),
               application.bundleIdentifier == "app.keydance.mac", !application.isTerminated,
               application.isFinishedLaunching {
                application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                // Opening the already running app also asks SwiftUI to reopen a
                // closed main window; activation alone only raises open windows.
                if let url = application.bundleURL { NSWorkspace.shared.open(url) }
                return
            }
            // The holder can be between taking the lock and registering with
            // AppKit. Give that same process time to finish; never start another.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while ProcessInfo.processInfo.systemUptime < deadline
    }
}
