using System.Buffers.Binary;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using KeyWoo.Core;
using NAudio.Wave;

namespace KeyWoo.Windows;

/// <summary>Runs the shipped painter, PCM decoder and real overlay window without reading an audio device.</summary>
internal static class EdgeGlowVerification {
    private const int Width = 1200, Height = 144;
    internal sealed record Result(bool Passed, bool MusicRenderingPassed, bool TypingRenderingPassed,
        bool SilencePassed, bool OpacityPassed, bool ReducedMotionPassed, bool WindowLifecyclePassed,
        bool CaptureDecoderPassed, bool CaptureOptInPassed, bool DeviceCaptureTested);
    private readonly record struct Frame(RenderTargetBitmap Bitmap,byte[] Bytes,int Left,int Middle,int Right,long Light);

    internal static Result Run(string report) {
        var options = new KeyBurstVisualOptions(1,1,true,false);
        var quiet = AudioSpectrum.Silent;
        var music = new AudioSpectrum(.9,.5,.35,.85,.75);
        var typing = new EdgeGlowDynamics();
        Frame silent = Render(typing,quiet,1,options);
        Require(silent.Light == 0,"Silence must leave the bottom edge fully transparent.");
        Frame musicFrame = Render(typing,music,1,options);
        Require(musicFrame.Left > 50 && musicFrame.Right > 50 && musicFrame.Middle == 0,
            "Music must draw two side regions with a transparent center.");
        Frame treble = Render(typing,new(.1,.15,.9,.85,.75),1,options);
        Require(!treble.Bytes.AsSpan().SequenceEqual(musicFrame.Bytes),"The spectrum must change the rendered shape.");
        Frame dim = Render(typing,music,1,options with { Brightness = .25 });
        Require(dim.Light > 0 && dim.Light < musicFrame.Light,"Minimum opacity must stay visible and dim the actual pixels.");
        Frame reduced = Render(typing,music,1,options with { ReduceMotion = true });
        Require(reduced.Light > 0 && !reduced.Bytes.AsSpan().SequenceEqual(musicFrame.Bytes),"Reduced motion must draw a gentle static contour.");
        typing.Press(new(0x41,0x1e),1);
        typing.Press(new(0x20,0x39),1.05);
        Frame keyFrame = Render(typing,quiet,1.12,options);
        Require(keyFrame.Light > 0 && keyFrame.Middle > 0,"Typing must add its own bottom glow and Space ripple.");
        Require(Render(typing,quiet,15,options).Light == 0,"Typing must fade to a fully clear frame.");
        VerifyDecoder();
        VerifyOptIn();
        VerifyWindow(music);
        Save(musicFrame.Bitmap,Path.ChangeExtension(report,".edge-glow-music.png"));
        Save(keyFrame.Bitmap,Path.ChangeExtension(report,".edge-glow-typing.png"));
        return new(true,true,true,true,true,true,true,true,true,false);
    }

    private static Frame Render(EdgeGlowDynamics dynamics,AudioSpectrum spectrum,double time,KeyBurstVisualOptions options) {
        var visual = new DrawingVisual();
        using(var drawing=visual.RenderOpen())EdgeGlowDrawing.Draw(drawing,new(Width,Height),dynamics,spectrum,time,options);
        var bitmap = new RenderTargetBitmap(Width,Height,96,96,PixelFormats.Pbgra32);
        bitmap.Render(visual);
        byte[] bytes = new byte[Width*Height*4];
        bitmap.CopyPixels(bytes,Width*4,0);
        int left=0,middle=0,right=0;long light=0;
        for(int y=0;y<Height;y++)for(int x=0;x<Width;x++) {
            int index=(y*Width+x)*4;
            if(bytes[index+3]>0) {
                if(x<Width*.36)left++;else if(x>Width*.64)right++;else middle++;
            }
            light+=bytes[index]+bytes[index+1]+bytes[index+2];
        }
        return new(bitmap,bytes,left,middle,right,light);
    }

    private static void VerifyDecoder() {
        var format=WaveFormat.CreateIeeeFloatWaveFormat(48000,2);
        SystemAudioRhythm.ValidateFormat(format);
        byte[] bytes=new byte[16];
        float[] inputs=[.8f,.2f,float.NaN,.4f];
        for(int index=0;index<inputs.Length;index++)BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(index*4,4),BitConverter.SingleToInt32Bits(inputs[index]));
        float[] mono=new float[2];
        SystemAudioRhythm.DecodeMono(bytes,format,mono);
        Require(Math.Abs(mono[0]-.5f)<.00001f&&Math.Abs(mono[1]-.2f)<.00001f,"Float32 stereo must downmix with finite samples.");
        var pcm=new WaveFormat(44100,16,2);
        SystemAudioRhythm.ValidateFormat(pcm);
        byte[] shorts=new byte[4];BinaryPrimitives.WriteInt16LittleEndian(shorts,16384);BinaryPrimitives.WriteInt16LittleEndian(shorts.AsSpan(2),-8192);
        SystemAudioRhythm.DecodeMono(shorts,pcm,mono.AsSpan(0,1));
        Require(Math.Abs(mono[0]-.125f)<.00001f,"PCM16 stereo must downmix correctly.");
        var extensible=new WaveFormatExtensible(48000,32,2);
        SystemAudioRhythm.ValidateFormat(extensible);
        SystemAudioRhythm.DecodeMono(bytes,extensible,mono);
        Require(Math.Abs(mono[0]-.5f)<.00001f,"Extensible Float32 output must use its subformat.");
        bool rejected=false;
        try { SystemAudioRhythm.ValidateFormat(new WaveFormat(48000,8,2)); }catch(NotSupportedException){rejected=true;}
        Require(rejected,"Unsupported device formats must fail without interpreting malformed samples.");
    }

    private static void VerifyOptIn() {
        var controller=new SystemAudioRhythm();
        Require(!controller.Enabled&&controller.State==SystemAudioState.Stopped,"Loopback must start disabled.");
        controller.Retry();
        Require(!controller.Enabled&&controller.State==SystemAudioState.Stopped,"Retry must not opt in to loopback.");
        long generation=controller.Generation;
        controller.Dispose();
        Require(controller.Generation>generation&&controller.State==SystemAudioState.Stopped,"Disposal must invalidate capture callbacks.");
    }

    private static void VerifyWindow(AudioSpectrum music) {
        using var overlay=new KeyBurstOverlay();
        overlay.Configure(true,true,1,1,"edgeGlow");
        overlay.SetAudioSource(()=>music,true);
        Require(WaitFor(()=>overlay.Handle!=0&&overlay.IsRendering&&IsWindowVisible(overlay.Handle)),"Live spectrum must wake the bottom overlay without typing.");
        nint handle=overlay.Handle;
        const long styles=0x08000000|0x00000080|0x00000020|0x00080000|0x00000008;
        Require((GetWindowLongPtr(handle,-20).ToInt64()&styles)==styles&&GetForegroundWindow()!=handle,"Bottom light must pass clicks without taking focus.");
        Require(GetWindowRect(handle,out var bounds)&&bounds.Right-bounds.Left>340&&bounds.Bottom-bounds.Top<=400,"Bottom light must span its monitor instead of using the burst panel.");
        overlay.Enqueue(new(0x41,0x1e));
        overlay.SetSuspended(true);
        Require(!overlay.IsRendering&&!IsWindowVisible(handle),"Pausing must clear and hide bottom light.");
        overlay.SetAudioSource(()=>AudioSpectrum.Silent,false);
        overlay.SetSuspended(false);
        Pump();
        Require(!overlay.IsRendering&&!IsWindowVisible(handle),"Resuming must not revive queued keys or old spectrum.");
        overlay.SetAudioSource(()=>music,true);
        overlay.Configure(true,true,1,1,"burst");
        Pump();
        Require(!overlay.IsRendering&&!IsWindowVisible(handle),"Leaving bottom glow must stop its spectrum-driven frames.");
        overlay.Configure(false,true,1,1,"edgeGlow");
        overlay.Preview();
        Require(WaitFor(()=>overlay.IsRendering),"The bottom-glow demo must work while desktop animation is off.");
        overlay.Reset();
        Require(!overlay.IsRendering&&!IsWindowVisible(handle),"Reset must clear a bottom-glow demo.");
    }

    private static void Pump()=>Dispatcher.CurrentDispatcher.Invoke(()=>{},DispatcherPriority.Background);
    private static bool WaitFor(Func<bool> condition) {
        if(condition())return true;
        var frame=new DispatcherFrame();var clock=Stopwatch.StartNew();
        var timer=new DispatcherTimer(DispatcherPriority.Background){Interval=TimeSpan.FromMilliseconds(10)};
        timer.Tick+=(_,_)=>{if(condition()||clock.Elapsed.TotalSeconds>=2)frame.Continue=false;};
        timer.Start();try{Dispatcher.PushFrame(frame);}finally{timer.Stop();}return condition();
    }
    private static void Save(BitmapSource bitmap,string filename) {var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(bitmap));using var file=File.Create(filename);png.Save(file);}
    private static void Require(bool condition,string message){if(!condition)throw new InvalidDataException(message);}
    [StructLayout(LayoutKind.Sequential)]private struct Rect {public int Left,Top,Right,Bottom;}
    [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")]private static extern nint GetWindowLongPtr(nint window,int index);
    [DllImport("user32.dll")]private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")]private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")]private static extern bool GetWindowRect(nint window,out Rect rect);
}
