using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using KeyWoo.Core;

namespace KeyWoo.Windows;

/// A visual-only desktop overlay. The keyboard hook only queues physical keys;
/// the UI dispatcher owns both the animation state and the native window.
internal sealed class KeyBurstOverlay : IDisposable
{
    private const double PanelWidth = 340;
    private const double PanelHeight = 224;
    private const double EdgeMargin = 24;
    private const int ExNoActivate = 0x08000000;
    private const int ExToolWindow = 0x0080;
    private const int ExTransparent = 0x0020;
    private const int ExTopmost = 0x0008;
    private const uint PositionNoActivate = 0x0010;
    private const uint PositionNoOwnerZOrder = 0x0200;
    private const uint PositionNoMove = 0x0002;
    private const uint PositionNoSize = 0x0001;
    private const uint PositionNoZOrder = 0x0004;
    private const uint PositionShowWindow = 0x0040;
    private static readonly Size PanelSize = new(PanelWidth, PanelHeight);
    private static readonly DemoStroke[] Demo =
    [
        new(0, new(0x41, 0x1e)), new(.22, new(0x53, 0x1f)),
        new(.37, new(0x44, 0x20)), new(.48, new(0x46, 0x21)),
        new(.57, new(0x20, 0x39)), new(.65, new(0x48, 0x23)),
        new(.74, new(0x4a, 0x24)), new(.83, new(0x4b, 0x25)),
        new(.93, new(0x4c, 0x26)), new(1.05, new(0x0d, 0x1c)),
        new(1.17, new(0x41, 0x1e)), new(1.28, new(0x53, 0x1f)),
        new(1.38, new(0x44, 0x20)), new(1.48, new(0x46, 0x21)),
        new(1.58, new(0x48, 0x23)), new(1.67, new(0x20, 0x39)),
        new(1.76, new(0x4a, 0x24)), new(1.87, new(0x4b, 0x25)),
        new(1.97, new(0x4c, 0x26)), new(2.09, new(0x0d, 0x1c))
    ];

    private readonly record struct DemoStroke(double Offset, PhysicalKey Key);
    private readonly record struct QueuedPress(PhysicalKey Key, double Time, long Token);

    private readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
    private readonly CommandQueue<QueuedPress> presses = new(128);
    private readonly KeyBurstDynamics dynamics = new();
    private readonly EdgeGlowDynamics edgeDynamics = new();
    private readonly AudioSpectrumMotion spectrumMotion = new();
    private Func<AudioSpectrum>? spectrumSource;
    private string style = "burst";
    private bool audioActive;
    private double? lastFrame;
    private Size drawingSize = PanelSize;
    private nint edgeMonitor;
    private readonly DispatcherTimer frames;
    private readonly Action wake;
    private readonly DrawingVisual visual = new();
    private readonly ScaleTransform fit = new(1, 1);
    private HwndSource? source;
    private KeyBurstVisualOptions options = new(1, 1, true, false);
    private bool enabled, suspended, disposed, shown, placementDirty;
    private double? previewStart;
    private int previewIndex;
    // The low bit allows capture. Reset changes the generation so a producer
    // that was already enqueuing cannot bring old keys back after a pause.
    private long captureToken;
    private int wakePosted, rendering;

    internal nint Handle => source is { IsDisposed: false } window ? window.Handle : 0;
    internal bool IsRendering => Volatile.Read(ref rendering) != 0;

    public KeyBurstOverlay()
    {
        wake = Wake;
        frames = new DispatcherTimer(DispatcherPriority.Render, dispatcher)
        {
            Interval = TimeSpan.FromSeconds(1.0 / 60)
        };
        frames.Tick += (_, _) => RenderFrame();
    }

    public void Configure(bool enabled, bool flashes, double intensity, double brightness, string style = "burst")
    {
        dispatcher.VerifyAccess();
        options = new(Clamp(intensity, .4, 1.5), Clamp(brightness, .25, 1), flashes, false);
        bool changed = this.enabled != enabled || this.style != style;
        this.enabled = enabled;
        this.style = style == "edgeGlow" ? "edgeGlow" : "burst";
        if (!changed) return;
        placementDirty = true;
        Reset();
        if (CanFollowAudio) RenderFrame();
    }

    public void SetSuspended(bool suspended)
    {
        dispatcher.VerifyAccess();
        if (this.suspended == suspended) return;
        this.suspended = suspended;
        Reset();
        if (CanFollowAudio) RenderFrame();
    }

    private bool CanFollowAudio => enabled && !suspended && !disposed && style == "edgeGlow" && audioActive;

    public void SetAudioSource(Func<AudioSpectrum> source, bool active) {
        dispatcher.VerifyAccess();
        spectrumSource = source;
        if (audioActive == active) return;
        audioActive = active;
        spectrumMotion.Reset();
        if (CanFollowAudio && !IsRendering) RenderFrame();
    }

    public void Enqueue(PhysicalKey key)
    {
        long token = Volatile.Read(ref captureToken);
        if ((token & 1) == 0) return;
        if (presses.TryEnqueue(new(key, Now(), token)) && !IsRendering) RequestWake();
    }

    public void Preview()
    {
        dispatcher.VerifyAccess();
        if (disposed || suspended) return;
        Reset();
        previewStart = Now();
        RenderFrame();
    }

    public void Reset()
    {
        dispatcher.VerifyAccess();
        long nextGeneration = (Volatile.Read(ref captureToken) & ~1L) + 2;
        Volatile.Write(ref captureToken, nextGeneration);
        for (int i = 0; i < presses.Capacity && presses.TryDequeue(out _); i++) { }
        StopFrames();
        Volatile.Write(ref captureToken, enabled && !suspended && !disposed ? nextGeneration | 1 : nextGeneration);
    }

    public void Dispose()
    {
        dispatcher.VerifyAccess();
        if (disposed) return;
        disposed = true;
        Reset();
        source?.Dispose();
        source = null;
    }

    private void RequestWake()
    {
        if (Interlocked.CompareExchange(ref wakePosted, 1, 0) != 0) return;
        if (dispatcher.BeginInvoke(DispatcherPriority.Render, wake).Status == DispatcherOperationStatus.Aborted)
            Volatile.Write(ref wakePosted, 0);
    }

    private void Wake()
    {
        Volatile.Write(ref wakePosted, 0);
        if (!IsRendering) RenderFrame();
    }

    private bool DrainPresses()
    {
        bool received = false;
        long token = Volatile.Read(ref captureToken);
        for (int i = 0; i < presses.Capacity && presses.TryDequeue(out var press); i++)
        {
            if ((token & 1) == 0 || press.Token != token) continue;
            if (previewStart.HasValue)
            {
                previewStart = null;
                dynamics.Reset();
                edgeDynamics.Reset();
            }
            dynamics.Press(press.Key, press.Time);
            edgeDynamics.Press(press.Key, press.Time);
            received = true;
        }
        return received;
    }

    private void RenderFrame()
    {
        if (disposed || suspended)
        {
            DrainPresses();
            return;
        }
        double now = Now();
        DrainPresses();
        if (previewStart is double start)
        {
            while (previewIndex < Demo.Length && now - start >= Demo[previewIndex].Offset)
            {
                var stroke = Demo[previewIndex++];
                dynamics.Press(stroke.Key, start + stroke.Offset);
                edgeDynamics.Press(stroke.Key, start + stroke.Offset);
            }
            if (previewIndex == Demo.Length) previewStart = null;
        }

        if (!previewStart.HasValue && !(style == "edgeGlow" ? edgeDynamics.IsVisible(now) || CanFollowAudio : dynamics.IsVisible(now)))
        {
            StopFrames();
            // Close the idle transition race. A press queued before rendering
            // was marked stopped may not have posted its own wake.
            if (DrainPresses()) RequestWake();
            return;
        }

        if (style == "edgeGlow" && GetCursorPos(out var cursor) && MonitorFromPoint(cursor, 1) != edgeMonitor) placementDirty = true;
        if ((!shown || placementDirty || Handle == 0) && !TryPlaceWindow())
        {
            StopFrames();
            if (DrainPresses()) RequestWake();
            return;
        }

        using (var drawing = visual.RenderOpen())
        {
            drawing.PushTransform(fit);
            var currentOptions = options with { ReduceMotion = !SystemParameters.ClientAreaAnimation };
            if (style == "edgeGlow") {
                double elapsed = lastFrame is double previous ? now - previous : 1.0 / 60;
                var target = CanFollowAudio ? spectrumSource?.Invoke() ?? AudioSpectrum.Silent : AudioSpectrum.Silent;
                var spectrum = spectrumMotion.Advance(target, elapsed);
                EdgeGlowDrawing.Draw(drawing, drawingSize, edgeDynamics, spectrum, now, currentOptions);
            } else {
                KeyBurstDrawing.Draw(drawing, PanelSize, dynamics, now, currentOptions);
            }
            lastFrame = now;
            drawing.Pop();
        }
        if (!shown)
        {
            if (!SetWindowPos(Handle, -1, 0, 0, 0, 0, PositionNoActivate | PositionNoOwnerZOrder |
                              PositionNoMove | PositionNoSize | PositionShowWindow))
            {
                StopFrames();
                if (DrainPresses()) RequestWake();
                return;
            }
            shown = true;
        }
        if (!IsRendering)
        {
            Volatile.Write(ref rendering, 1);
            frames.Start();
        }
    }

    private void StopFrames()
    {
        frames.Stop();
        Volatile.Write(ref rendering, 0);
        dynamics.Reset();
        edgeDynamics.Reset();
        spectrumMotion.Reset();
        lastFrame = null;
        previewStart = null;
        previewIndex = 0;
        if (!shown) return;
        if (Handle != 0) ShowWindow(Handle, 0); // SW_HIDE
        shown = false;
        using var empty = visual.RenderOpen();
    }

    private bool TryPlaceWindow()
    {
        // Follow the foreground display at the start of a row. Keep the panel
        // on that display while it is already animating.
        nint anchor = shown && Handle != 0 ? Handle : GetForegroundWindow();
        nint monitor = style == "edgeGlow" && GetCursorPos(out var point)
            ? MonitorFromPoint(point, 1) : MonitorFromWindow(anchor, 1); // MONITOR_DEFAULTTOPRIMARY
        var info = new MonitorInfo { Size = (uint)Marshal.SizeOf<MonitorInfo>() };
        if (monitor == 0 || !GetMonitorInfo(monitor, ref info)) return false;
        var work = info.Work;
        int availableWidth = work.Right - work.Left;
        int availableHeight = work.Bottom - work.Top;
        if (availableWidth <= 0 || availableHeight <= 0) return false;

        try
        {
            if (Handle == 0)
            {
                source?.Dispose();
                var parameters = new HwndSourceParameters("KeyWoo Key Burst", 1, 1)
                {
                    PositionX = work.Left,
                    PositionY = work.Top,
                    WindowStyle = unchecked((int)0x80000000), // WS_POPUP
                    // Per-pixel transparency makes this a layered window, so
                    // TRANSPARENT passes clicks to other processes below it.
                    ExtendedWindowStyle = ExNoActivate | ExToolWindow | ExTransparent | ExTopmost,
                    UsesPerPixelTransparency = true,
                    TreatAsInputRoot = false,
                    HwndSourceHook = WindowMessage
                };
                source = new HwndSource(parameters) { RootVisual = visual };
                shown = false;
            }
        }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException)
        {
            // A desktop that cannot create an overlay must not interrupt typing.
            return false;
        }

        nint window = Handle;
        if (MonitorFromWindow(window, 2) != monitor &&
            !SetWindowPos(window, 0, work.Left, work.Top, 1, 1,
                          PositionNoActivate | PositionNoOwnerZOrder | PositionNoZOrder)) return false;

        uint dpi = GetDpiForWindow(window);
        double deviceScale = dpi == 0 ? 1 : dpi / 96.0;
        if (style == "edgeGlow") {
            edgeMonitor = monitor;
            fit.ScaleX = fit.ScaleY = 1;
            drawingSize = new(availableWidth / deviceScale, Math.Min(144, availableHeight / deviceScale));
            int edgePixels = Math.Min(availableHeight, (int)Math.Ceiling(drawingSize.Height * deviceScale));
            placementDirty = false;
            return SetWindowPos(window, -1, work.Left, work.Bottom - edgePixels, availableWidth, edgePixels, PositionNoActivate | PositionNoOwnerZOrder);
        }
        drawingSize = PanelSize;
        double scale = Math.Min(1, Math.Min(availableWidth / (PanelWidth * deviceScale),
                                           availableHeight / (PanelHeight * deviceScale)));
        fit.ScaleX = fit.ScaleY = scale;
        int width = Math.Clamp((int)Math.Ceiling(PanelWidth * deviceScale * scale), 1, availableWidth);
        int height = Math.Clamp((int)Math.Ceiling(PanelHeight * deviceScale * scale), 1, availableHeight);
        int margin = (int)Math.Round(EdgeMargin * deviceScale);
        int x = work.Right - width - Math.Min(margin, availableWidth - width);
        int y = work.Bottom - height - Math.Min(margin, availableHeight - height);
        placementDirty = false;
        return SetWindowPos(window, -1, x, y, width, height, PositionNoActivate | PositionNoOwnerZOrder);
    }

    private nint WindowMessage(nint window, int message, nint wParam, nint lParam, ref bool handled)
    {
        switch (message)
        {
            case 0x0084: // WM_NCHITTEST
                handled = true;
                return -1; // HTTRANSPARENT
            case 0x0021: // WM_MOUSEACTIVATE
                handled = true;
                return 3; // MA_NOACTIVATE
            case 0x001a: // WM_SETTINGCHANGE
            case 0x007e: // WM_DISPLAYCHANGE
            case 0x02e0: // WM_DPICHANGED
                placementDirty = true;
                break;
        }
        return 0;
    }

    private static double Now() => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
    private static double Clamp(double value, double min, double max) =>
        double.IsFinite(value) ? Math.Clamp(value, min, max) : 1;

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo
    {
        public uint Size;
        public NativeRect Monitor, Work;
        public uint Flags;
    }

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out NativePoint point);

    [DllImport("user32.dll")]
    private static extern nint MonitorFromPoint(NativePoint point, uint flags);

    [DllImport("user32.dll")]
    private static extern nint GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern nint MonitorFromWindow(nint window, uint flags);

    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW")]
    private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint window);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(nint window, int command);
}
