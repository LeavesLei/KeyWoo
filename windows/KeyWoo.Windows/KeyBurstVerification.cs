using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using KeyWoo.Core;

namespace KeyWoo.Windows;

/// <summary>Exercise the packaged WPF drawing and window without starting a keyboard hook.</summary>
internal static class KeyBurstVerification {
    private const int Width = 340;
    private const int Height = 224;
    private static readonly KeyBurstVisualOptions Standard = new(1, 1, true, false);
    private static readonly PhysicalKey Space = new(0x20, 0x39);
    private static readonly PhysicalKey Return = new(0x0D, 0x1C);

    internal sealed record Result(bool Passed, int TypingPixels, int SpacePixels, int ReturnPixels,
        bool FadePassed, bool BrightnessPassed, bool ReducedMotionPassed, bool WindowLifecyclePassed);

    internal static Result Run(string report) {
        var word = new KeyBurstDynamics();
        var keys = new PhysicalKey[] {new(0x4B,0x25), new(0x45,0x12), new(0x59,0x15),
            new(0x57,0x11), new(0x4F,0x18), new(0x4F,0x18)};
        for (int index = 0; index < keys.Length; index++) word.Press(keys[index], index * .06);
        var typing = Render(word, .5, Standard);
        var dim = Render(word, .5, Standard with { Brightness = .25 });
        var fade = Render(word, 2.8, Standard);
        Require(typing.Pixels > 100 && typing.Brightness > 0, "Typing must draw visible colored glyphs.");
        Require(dim.Brightness > 0 && dim.Brightness < typing.Brightness, "Brightness must affect the drawn frame.");
        Require(fade.Pixels > 0 && fade.Brightness < typing.Brightness && Render(word, 3.3, Standard).Pixels == 0,
            "The row must fade and clear after inactivity.");

        word.Press(Space, .6);
        var burst = Render(word, .73, Standard);
        Require(burst.Pixels > 0 && burst.Pixels < typing.Pixels && Render(word, .87, Standard).Pixels == 0,
            "Space must leave brief fragments after the glyphs disappear.");
        var reduced = Render(word, .73, Standard with { ReduceMotion = true });
        Require(reduced.Pixels > 0 && !reduced.Data.AsSpan().SequenceEqual(burst.Data),
            "Reduced motion must use a distinct, gentle fade.");

        word.Reset();
        for (int index = 0; index < keys.Length; index++) word.Press(keys[index], index * .06);
        word.Press(Return, .6);
        var settle = Render(word, .67, Standard);
        Require(settle.Pixels > 0 && !settle.Data.AsSpan().SequenceEqual(typing.Data)
            && Render(word, .77, Standard).Pixels == 0, "Return must briefly draw the outgoing row together.");
        VerifyWindow(keys[0]);

        Save(typing.Bitmap, Path.ChangeExtension(report, ".key-burst-typing.png"));
        Save(burst.Bitmap, Path.ChangeExtension(report, ".key-burst-space.png"));
        Save(settle.Bitmap, Path.ChangeExtension(report, ".key-burst-return.png"));
        return new(true, typing.Pixels, burst.Pixels, settle.Pixels, true, true, true, true);
    }

    private sealed record Frame(RenderTargetBitmap Bitmap, byte[] Data, int Pixels, long Brightness);
    private static Frame Render(KeyBurstDynamics model, double time, KeyBurstVisualOptions options) {
        var visual = new DrawingVisual();
        using (var context = visual.RenderOpen()) {
            KeyBurstDrawing.Draw(context, new Size(Width, Height), model, time, options);
        }
        var bitmap = new RenderTargetBitmap(Width, Height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var data = new byte[Width * Height * 4];
        bitmap.CopyPixels(data, Width * 4, 0);
        int pixels = 0;
        long brightness = 0;
        for (int index = 0; index < data.Length; index += 4) {
            if (data[index + 3] > 0) pixels++;
            brightness += data[index] + data[index + 1] + data[index + 2];
        }
        return new(bitmap, data, pixels, brightness);
    }

    private static void Save(BitmapSource bitmap, string path) {
        var png = new PngBitmapEncoder();
        png.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = File.Create(path);
        png.Save(file);
    }

    private static void VerifyWindow(PhysicalKey key) {
        using var overlay = new KeyBurstOverlay();
        overlay.Configure(true, true, 1, 1);
        overlay.Enqueue(key);
        Require(WaitFor(() => overlay.Handle != 0 && overlay.IsRendering && IsWindowVisible(overlay.Handle)),
            "A queued key must start the overlay.");
        nint handle = overlay.Handle;
        const long requiredStyles = 0x08000000 | 0x00000080 | 0x00000020 | 0x00080000 | 0x00000008;
        Require((GetWindowLongPtr(handle, -20).ToInt64() & requiredStyles) == requiredStyles
            && GetForegroundWindow() != handle, "The window must be transparent, click-through, and nonactivating.");
        overlay.SetSuspended(true);
        Require(!overlay.IsRendering && !IsWindowVisible(handle), "Suspending must hide the overlay and stop frames.");
        overlay.Enqueue(key);
        overlay.SetSuspended(false);
        Require(!overlay.IsRendering && !IsWindowVisible(handle), "Resuming must clear queued keys.");
        overlay.Enqueue(key);
        overlay.SetSuspended(true);
        overlay.SetSuspended(false);
        Dispatcher.CurrentDispatcher.Invoke(() => { }, DispatcherPriority.Background);
        Require(!overlay.IsRendering && !IsWindowVisible(handle), "A posted wake must not replay keys from before a pause.");
        overlay.Configure(false, true, 1, 1);
        overlay.Preview();
        Require(WaitFor(() => overlay.IsRendering && IsWindowVisible(overlay.Handle)),
            "The demo must work independently of the global setting.");
        overlay.Reset();
        Require(!overlay.IsRendering && !IsWindowVisible(overlay.Handle), "Reset must end a demo.");
    }

    private static bool WaitFor(Func<bool> condition) {
        if (condition()) return true;
        var frame = new DispatcherFrame();
        var clock = Stopwatch.StartNew();
        var timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(10) };
        timer.Tick += (_, _) => {
            if (condition() || clock.Elapsed >= TimeSpan.FromSeconds(2)) frame.Continue = false;
        };
        timer.Start();
        try { Dispatcher.PushFrame(frame); }
        finally { timer.Stop(); }
        return condition();
    }

    private static void Require(bool success, string message) {
        if (!success) throw new InvalidDataException(message);
    }

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern nint GetWindowLongPtr(nint hwnd, int index);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(nint hwnd);
    [DllImport("user32.dll")]
    private static extern nint GetForegroundWindow();
}
