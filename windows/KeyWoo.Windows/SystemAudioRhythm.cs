using System.Buffers;
using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using KeyWoo.Core;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wave;

namespace KeyWoo.Windows;

internal enum SystemAudioState { Stopped, Starting, Running, Failed }

/// <summary>Opt-in render-device loopback. Samples are analyzed in memory and never written to disk.</summary>
internal sealed class SystemAudioRhythm : IDisposable {
    private static readonly Guid FloatFormat = new("00000003-0000-0010-8000-00aa00389b71");
    private static readonly Guid PcmFormat = new("00000001-0000-0010-8000-00aa00389b71");
    private readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
    private readonly AudioSpectrumProcessor processor = new();
    private readonly DispatcherTimer recovery;
    private MMDeviceEnumerator? devices;
    private DeviceNotifications? notifications;
    private MMDevice? endpoint;
    private WasapiCapture? capture;
    private long generation;
    private bool enabled, disposed;
    private int attempts;
    internal SystemAudioState State { get; private set; }
    internal event Action? StateChanged;
    internal AudioSpectrum Snapshot() => processor.Snapshot();

    internal SystemAudioRhythm() {
        recovery = new DispatcherTimer(DispatcherPriority.Background,dispatcher) { Interval = TimeSpan.FromMilliseconds(500) };
        recovery.Tick += (_,_) => { recovery.Stop(); if (enabled && !disposed) { attempts++; Start(); } };
    }

    internal void SetEnabled(bool value) {
        dispatcher.VerifyAccess();
        if (disposed || enabled == value) return;
        enabled = value;
        attempts = 0;
        Stop();
        if (enabled) Start();
    }

    internal void Retry() {
        dispatcher.VerifyAccess();
        if (!enabled || disposed) return;
        attempts = 0;
        Stop();
        Start();
    }

    private void Start() {
        dispatcher.VerifyAccess();
        if (!enabled || disposed || capture is not null) return;
        SetState(SystemAudioState.Starting);
        try {
            EnsureNotifications();
            endpoint = devices!.GetDefaultAudioEndpoint(DataFlow.Render,Role.Multimedia);
            var current = new ResponsiveLoopbackCapture(endpoint);
            capture = current;
            long token = Interlocked.Increment(ref generation);
            WaveFormat format = current.WaveFormat;
            ValidateFormat(format);
            current.DataAvailable += (_,args) => {
                if (Volatile.Read(ref generation) != token) return;
                int frames = args.BytesRecorded / format.BlockAlign;
                if (frames == 0) return;
                float[] samples = ArrayPool<float>.Shared.Rent(frames);
                try {
                    DecodeMono(args.Buffer.AsSpan(0,args.BytesRecorded),format,samples.AsSpan(0,frames));
                    // Stop invalidates the generation before resetting the mailbox.
                    // Hold its lock across the recheck, so an old callback cannot revive a stopped stream.
                    lock (processor) {
                        if (Volatile.Read(ref generation) == token) processor.Receive(samples.AsSpan(0,frames),format.SampleRate);
                    }
                } finally { ArrayPool<float>.Shared.Return(samples,clearArray:true); }
            };
            current.RecordingStopped += (_,args) => {
                if (disposed || dispatcher.HasShutdownStarted) return;
                dispatcher.BeginInvoke(() => {
                    if (disposed || !ReferenceEquals(capture,current)) return;
                    Stop();
                    if (!enabled) return;
                    SetState(SystemAudioState.Failed);
                    if (attempts < 3) recovery.Start();
                });
            };
            current.StartRecording();
            SetState(SystemAudioState.Running);
        } catch (Exception error) when (error is COMException or InvalidOperationException or NotSupportedException or ArgumentException) {
            Stop();
            SetState(SystemAudioState.Failed);
            if (enabled && attempts < 3) recovery.Start();
        }
    }

    private void EnsureNotifications() {
        if (devices is not null) return;
        var enumerator = new MMDeviceEnumerator();
        var listener = new DeviceNotifications(() => {
            if (disposed || dispatcher.HasShutdownStarted) return;
            dispatcher.BeginInvoke(() => {
                if (disposed || !enabled) return;
                attempts = 0;
                Stop();
                SetState(SystemAudioState.Starting);
                recovery.Start();
            });
        });
        try { enumerator.RegisterEndpointNotificationCallback(listener); }
        catch { enumerator.Dispose(); throw; }
        devices = enumerator;
        notifications = listener;
    }

    private void Stop() {
        recovery.Stop();
        Interlocked.Increment(ref generation);
        var old = capture;
        capture = null;
        try { old?.Dispose(); }
        catch (COMException) { }
        endpoint?.Dispose();
        endpoint = null;
        lock (processor) processor.Reset();
        SetState(SystemAudioState.Stopped);
    }

    private void SetState(SystemAudioState value) {
        if (State == value) return;
        State = value;
        StateChanged?.Invoke();
    }

    internal static void ValidateFormat(WaveFormat format) {
        bool floating = format.Encoding == WaveFormatEncoding.IeeeFloat || format is WaveFormatExtensible extended && extended.SubFormat == FloatFormat;
        bool pcm = format.Encoding == WaveFormatEncoding.Pcm || format is WaveFormatExtensible pcmExtended && pcmExtended.SubFormat == PcmFormat;
        if (format.Channels < 1 || format.SampleRate < 8_000 || format.BlockAlign < format.Channels * (format.BitsPerSample / 8) ||
            !(floating && format.BitsPerSample == 32 || pcm && format.BitsPerSample is 16 or 24 or 32))
            throw new NotSupportedException("Unsupported output-device format.");
    }

    internal static void DecodeMono(ReadOnlySpan<byte> data,WaveFormat format,Span<float> mono) {
        int sampleBytes = format.BitsPerSample / 8;
        bool floating = format.Encoding == WaveFormatEncoding.IeeeFloat || format is WaveFormatExtensible extended && extended.SubFormat == FloatFormat;
        int frameCount = Math.Min(mono.Length,data.Length / format.BlockAlign);
        for (int frame = 0; frame < frameCount; frame++) {
            double sum = 0;
            for (int channel = 0; channel < format.Channels; channel++) {
                var sample = data.Slice(frame*format.BlockAlign+channel*sampleBytes,sampleBytes);
                float value;
                if (floating) value = BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(sample));
                else if (sampleBytes == 2) value = BinaryPrimitives.ReadInt16LittleEndian(sample) / 32768f;
                else if (sampleBytes == 3) value = ((sample[0] | sample[1] << 8 | sample[2] << 16) << 8 >> 8) / 8388608f;
                else value = BinaryPrimitives.ReadInt32LittleEndian(sample) / 2147483648f;
                sum += float.IsFinite(value) ? Math.Clamp(value,-8,8) : 0;
            }
            mono[frame] = (float)(sum / format.Channels);
        }
    }

    internal bool Enabled => enabled;
    internal long Generation => Volatile.Read(ref generation);
    public void Dispose() {
        dispatcher.VerifyAccess();
        if (disposed) return;
        disposed = true;
        enabled = false;
        Stop();
        if (devices is not null) {
            try { if (notifications is not null) devices.UnregisterEndpointNotificationCallback(notifications); }
            finally { devices.Dispose(); }
        }
    }

    // NAudio's standard loopback uses a 100 ms buffer. The documented capture
    // constructor allows a 20 ms shared buffer and event-driven delivery on Windows 11.
    private sealed class ResponsiveLoopbackCapture(MMDevice device) : WasapiCapture(device, true, 20) {
        protected override AudioClientStreamFlags GetAudioClientStreamFlags() =>
            AudioClientStreamFlags.Loopback | base.GetAudioClientStreamFlags();
    }

    private sealed class DeviceNotifications(Action changed) : IMMNotificationClient {
        public void OnDefaultDeviceChanged(DataFlow flow,Role role,string id) { if (flow == DataFlow.Render && role == Role.Multimedia) changed(); }
        public void OnDeviceAdded(string id) { }
        public void OnDeviceRemoved(string id) { changed(); }
        public void OnDeviceStateChanged(string id,DeviceState state) { changed(); }
        public void OnPropertyValueChanged(string id,PropertyKey key) { }
    }
}
