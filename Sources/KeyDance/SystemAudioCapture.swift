import Foundation
import Combine
import CoreAudio

/// Captures other processes' digital output, never a microphone or an input device.
/// The callback is snapshotted by start(), runs on a serial IO queue, and must
/// remain fast: use a bounded analysis/mailbox rather than dispatching every
/// buffer to the main actor. Transient mono batches target 10.7 ms (512 frames
/// at 48 kHz), bounded to 128...1,024 frames. The 8 kHz minimum uses 16 ms.
/// It must not synchronously wait for the main thread or call capture lifecycle
/// methods: stop() waits for the current bounded callback to finish.
@MainActor
final class SystemAudioCapture: ObservableObject {
    enum State: Equatable {
        case stopped, starting, running, failed(String)
    }

    typealias SampleHandler = @Sendable ([Float], Double) -> Void
    @Published private(set) var status: State = .stopped
    var onSamples: SampleHandler?

    private let controlQueue = DispatchQueue(label: "app.keydance.system-audio.control", qos: .userInitiated)
    private var session: (any SystemAudioCaptureSession)?
    private var deliveryGate: SystemAudioDeliveryGate?
    private var generation = 0
    private var routeRestartTask: Task<Void, Never>?

    func start() async throws {
        if status == .starting || status == .running { return }
        guard #available(macOS 14.2, *) else {
            let error = SystemAudioCaptureError.unsupportedVersion
            status = .failed(error.localizedDescription)
            throw error
        }
        generation &+= 1
        let ticket = generation
        let gate = SystemAudioDeliveryGate()
        deliveryGate = gate
        let handler = onSamples
        let queue = controlQueue
        status = .starting
        let routeChanged: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.scheduleRouteRestart(generation: ticket) }
        }
        do {
            let created: any SystemAudioCaptureSession = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let capture = try ProcessTapCaptureSession(controlQueue: queue, gate: gate,
                                                                  handler: handler, routeChanged: routeChanged)
                        continuation.resume(returning: capture)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            guard generation == ticket, !Task.isCancelled else {
                gate.cancel()
                queue.async { created.stop() }
                if generation == ticket { deliveryGate = nil; status = .stopped }
                throw CancellationError()
            }
            session = created
            status = .running
        } catch {
            gate.cancel()
            if generation == ticket {
                deliveryGate = nil
                status = error is CancellationError ? .stopped : .failed(error.localizedDescription)
            }
            throw error
        }
    }

    /// Finishes any current bounded delivery and revokes all further callbacks;
    /// a consumer may safely reset its analysis/mailbox after this returns.
    /// HAL destruction is serialized with any in-flight start/restart.
    func stop() {
        generation &+= 1
        routeRestartTask?.cancel()
        routeRestartTask = nil
        deliveryGate?.cancel()
        deliveryGate = nil
        let previous = session
        session = nil
        status = .stopped
        if let previous { controlQueue.async { previous.stop() } }
    }

    private func scheduleRouteRestart(generation ticket: Int) {
        guard generation == ticket, status == .running else { return }
        routeRestartTask?.cancel()
        routeRestartTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.generation == ticket, self.status == .running else { return }
            self.routeRestartTask = nil
            self.stop()
            do { try await self.start() } catch { /* start publishes the failure. */ }
        }
    }

    deinit {
        routeRestartTask?.cancel()
        deliveryGate?.cancel()
        if let session { controlQueue.async { session.stop() } }
    }
}

private protocol SystemAudioCaptureSession: AnyObject, Sendable {
    func stop()
}

private final class SystemAudioDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func cancel() { lock.lock(); active = false; lock.unlock() }

    /// Keep validation and delivery in one critical section. cancel() cannot
    /// return while an already-admitted batch is still writing to the consumer.
    func withActive(_ body: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return false }
        body()
        return true
    }
}

private enum SystemAudioCaptureError: LocalizedError {
    case unsupportedVersion, missingProcess, unsupportedFormat
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "System audio capture requires macOS 14.2 or later."
        case .missingProcess: return "Unable to identify KeyWoo's audio process. Resume sound and try again."
        case .unsupportedFormat: return "The system audio tap returned an unsupported PCM format."
        case let .coreAudio(operation, status): return "\(operation) failed (Core Audio \(status))."
        }
    }
}

/// All HAL resource mutation is confined to the owner's serial control queue.
/// The IO closure retains only its decoder and delivery gate, never this session.
@available(macOS 14.2, *)
private final class ProcessTapCaptureSession: SystemAudioCaptureSession, @unchecked Sendable {
    private let controlQueue: DispatchQueue
    private let ioQueue = DispatchQueue(label: "app.keydance.system-audio.io", qos: .userInitiated)
    private let gate: SystemAudioDeliveryGate
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var started = false
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(controlQueue: DispatchQueue, gate: SystemAudioDeliveryGate,
         handler: SystemAudioCapture.SampleHandler?, routeChanged: @escaping @Sendable () -> Void) throws {
        self.controlQueue = controlQueue
        self.gate = gate
        do {
            try checkActive()
            var processID = getpid()
            var processObject = AudioObjectID(kAudioObjectUnknown)
            var processSize = UInt32(MemoryLayout<AudioObjectID>.size)
            var processAddress = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &processAddress,
                                                 UInt32(MemoryLayout<pid_t>.size), &processID, &processSize, &processObject),
                      "Find own audio process")
            guard processObject != kAudioObjectUnknown else { throw SystemAudioCaptureError.missingProcess }

            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [processObject])
            description.name = "KeyWoo System Audio Visualizer"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tapID), "Create system audio tap")
            try checkActive()
            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var formatAddress = Self.address(kAudioTapPropertyFormat)
            try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &format), "Read tap format")
            let decoder = try SystemAudioPCMDecoder(format: format, gate: gate, handler: handler)

            // The aggregate has only the tap as an input. It contains no physical
            // microphone and is never selected as any system default device.
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "KeyWoo Private Audio Capture",
                kAudioAggregateDeviceUIDKey: "app.keydance.system-audio.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                // A true value can make AudioDeviceStart wait for a source to
                // begin playing. Starting while the desktop is silent must work.
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID), "Create private capture device")
            try checkActive()
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { _, input, _, _, _ in
                decoder.consume(input)
            }, "Register capture callback")
            try checkActive()
            try check(AudioDeviceStart(aggregateID, ioProcID), "Start system audio capture")
            started = true
            try checkActive()

            // Rebuild with the new sample rate/route. No polling and no PCM is
            // sent through this lifecycle callback.
            addListener(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice,
                        callback: routeChanged)
            addListener(object: tapID, selector: kAudioTapPropertyFormat, callback: routeChanged)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        gate.cancel()
        for (object, savedAddress, block) in listeners {
            var address = savedAddress
            AudioObjectRemovePropertyListenerBlock(object, &address, controlQueue, block)
        }
        listeners.removeAll()
        if aggregateID != kAudioObjectUnknown {
            if started { AudioDeviceStop(aggregateID, ioProcID); started = false }
            if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID); self.ioProcID = nil }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func addListener(object: AudioObjectID, selector: AudioObjectPropertySelector,
                             callback: @escaping @Sendable () -> Void) {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in callback() }
        if AudioObjectAddPropertyListenerBlock(object, &address, controlQueue, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    private func checkActive() throws { if !gate.isActive { throw CancellationError() } }
    private func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw SystemAudioCaptureError.coreAudio(operation, status) }
    }
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

/// The HAL calls this object only on ioQueue. It bounds both memory and work per
/// callback; unusually large buffers retain the newest 8,192 frames, keeping a
/// visualizer current instead of building a playback backlog. Smaller batches
/// avoid accumulating several HAL callbacks just to fill a large analysis block;
/// they cannot make data arrive before the HAL delivers its own input buffer.
private final class SystemAudioPCMDecoder: @unchecked Sendable {
    private let sampleRate: Double
    private let sampleBytes: Int
    private let isFloat: Bool
    private let expectedChannels: Int
    private let gate: SystemAudioDeliveryGate
    private let handler: SystemAudioCapture.SampleHandler?
    private var batch: [Float]
    private var filled = 0

    init(format: AudioStreamBasicDescription, gate: SystemAudioDeliveryGate,
         handler: SystemAudioCapture.SampleHandler?) throws {
        let float = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let signedInteger = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = Int(format.mChannelsPerFrame)
        let bytes = Int(format.mBitsPerChannel / 8)
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mSampleRate.isFinite, (8_000...384_000).contains(format.mSampleRate),
              (1...2).contains(channels),
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              (float && (bytes == 4 || bytes == 8)) || (signedInteger && (bytes == 2 || bytes == 4)),
              Int(format.mBytesPerFrame) == bytes * (planar ? 1 : channels) else {
            throw SystemAudioCaptureError.unsupportedFormat
        }
        sampleRate = format.mSampleRate
        sampleBytes = bytes
        isFloat = float
        expectedChannels = channels
        self.gate = gate
        self.handler = handler
        // The consumer accepts arbitrary chunk sizes and keeps energy history.
        // Scale this transport batch by time, rather than imposing 512 frames
        // even at low sample rates (which would add 64 ms at 8 kHz).
        let frameCount = min(1_024, max(128, Int((format.mSampleRate * (512.0 / 48_000.0)).rounded())))
        batch = [Float](repeating: 0, count: frameCount)
    }

    func consume(_ input: UnsafePointer<AudioBufferList>) {
        guard gate.isActive, handler != nil else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard !buffers.isEmpty, buffers.count <= expectedChannels else { return }
        var frames = Int.max
        var channels = 0
        for buffer in buffers {
            let count = Int(buffer.mNumberChannels)
            guard buffer.mData != nil, count > 0, count <= expectedChannels else { return }
            frames = min(frames, Int(buffer.mDataByteSize) / (sampleBytes * count))
            channels += count
        }
        guard channels == expectedChannels, frames > 0 else { return }
        let start = max(0, frames - 8_192)
        if start > 0 { filled = 0 }
        for frame in start..<frames {
            var sum = 0.0
            for buffer in buffers {
                let count = Int(buffer.mNumberChannels)
                guard let data = buffer.mData else { continue }
                for channel in 0..<count {
                    let offset = (frame * count + channel) * sampleBytes
                    let value: Double
                    if isFloat {
                        value = sampleBytes == 4
                            ? Double(data.loadUnaligned(fromByteOffset: offset, as: Float.self))
                            : data.loadUnaligned(fromByteOffset: offset, as: Double.self)
                    } else {
                        value = sampleBytes == 2
                            ? Double(data.loadUnaligned(fromByteOffset: offset, as: Int16.self)) / 32_768
                            : Double(data.loadUnaligned(fromByteOffset: offset, as: Int32.self)) / 2_147_483_648
                    }
                    if value.isFinite { sum += value }
                }
            }
            batch[filled] = Float(min(1, max(-1, sum / Double(channels))))
            filled += 1
            if filled == batch.count {
                guard gate.withActive({ handler?(batch, sampleRate) }) else { filled = 0; return }
                filled = 0
            }
        }
    }
}
