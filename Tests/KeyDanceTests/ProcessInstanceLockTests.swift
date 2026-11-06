import Foundation
import Darwin
import Testing
@testable import KeyDance

struct ProcessInstanceLockTests {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyWooInstanceLock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("instance.lock")
    }

    @Test func independentDescriptorsCannotAcquireUntilOwnerReleases() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let acquired = try ProcessInstanceLock.acquire(at: url)
            let owner = try #require(acquired)
            try withExtendedLifetime(owner) {
                #expect(ProcessInstanceLock.ownerProcessIdentifier(at: url) == getpid())
                let competing = try ProcessInstanceLock.acquire(at: url)
                #expect(competing == nil)
            }
        }
        let acquiredReplacement = try ProcessInstanceLock.acquire(at: url)
        let replacement = try #require(acquiredReplacement)
        withExtendedLifetime(replacement) {
            #expect(ProcessInstanceLock.ownerProcessIdentifier(at: url) == getpid())
        }
    }

    @Test func anotherProcessIsBlockedThenCanAcquireAfterRelease() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        func attemptInChild() throws -> Int32 {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            child.arguments = ["-c", """
                import fcntl, os, sys
                descriptor = os.open(sys.argv[1], os.O_RDWR)
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    sys.exit(73)
                finally:
                    os.close(descriptor)
                """, url.path]
            try child.run()
            child.waitUntilExit()
            return child.terminationStatus
        }
        do {
            let acquired = try ProcessInstanceLock.acquire(at: url)
            let owner = try #require(acquired)
            try withExtendedLifetime(owner) {
                let status = try attemptInChild()
                #expect(status == 73)
            }
        }
        let statusAfterRelease = try attemptInChild()
        #expect(statusAfterRelease == 0)
    }

    @Test func symlinkCannotRedirectTheInstanceLock() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let target = url.deletingLastPathComponent().appendingPathComponent("untouched.txt")
        let original = Data("keep this file".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let rejected: Bool
        do {
            _ = try ProcessInstanceLock.acquire(at: url)
            rejected = false
        } catch { rejected = true }
        #expect(rejected)
        let after = try Data(contentsOf: target)
        #expect(after == original)
    }
}
