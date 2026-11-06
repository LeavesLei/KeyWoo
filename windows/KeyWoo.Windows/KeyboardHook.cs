using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using KeyWoo.Core;
namespace KeyWoo.Windows;

internal sealed class KeyboardHook : IDisposable {
    private readonly InputRouter router=new();
    private readonly Thread thread;
    private readonly Native.HookProc callback;
    private readonly TaskCompletionSource<Dispatcher> ready=new(TaskCreationOptions.RunContinuationsAsynchronously);
    private Dispatcher? dispatcher;
    private IntPtr hook;
    private bool disposed;
    private bool needsSeed;
    public event Action<PhysicalKey,DateTimeOffset>? Pressed;
    public event Action<PhysicalKey,bool>? Sound;
    public event Action<string>? Failed;
    public KeyboardHook() {
        callback=Handle;
        thread=new Thread(Run){IsBackground=true,Name="KeyWoo keyboard input"};
        thread.SetApartmentState(ApartmentState.STA);
    }
    public Task StartAsync(){thread.Start();return ready.Task;}
    private void Run() {
        try {
            dispatcher=Dispatcher.CurrentDispatcher;
            hook=Native.SetWindowsHookEx(13,callback,Native.GetModuleHandle(null),0);
            if(hook==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
            SeedAlreadyHeldKeys();
            ready.TrySetResult(dispatcher);
            Dispatcher.Run();
        } catch(Exception ex) {ready.TrySetException(ex);Failed?.Invoke(ex.Message);}
        finally {if(hook!=IntPtr.Zero){Native.UnhookWindowsHookEx(hook);hook=IntPtr.Zero;}}
    }
    public async Task ConfigureAsync(bool enabled,bool mappingEnabled,InputRule[] rules) {
        var target=await ready.Task.ConfigureAwait(false);
        await target.InvokeAsync(()=>{
            if(enabled&&needsSeed)SeedAlreadyHeldKeys();
            Send(router.Configure(enabled,mappingEnabled,rules));
        }).Task.ConfigureAwait(false);
    }
    public async Task SuspendSessionAsync() {
        var target=await ready.Task.ConfigureAwait(false);
        await target.InvokeAsync(()=>{Send(router.SuspendSession());needsSeed=true;}).Task.ConfigureAwait(false);
    }
    private void SeedAlreadyHeldKeys() {
        // Never call GetAsyncKeyState to decide the event currently in Handle:
        // its state has not been updated yet. This one-time boundary snapshot
        // runs on the message thread before accepting new mappings.
        var keys=new List<int>();
        for(int key=8;key<=254;key++) {
            if(key is 0x10 or 0x11 or 0x12)continue; // use actual left/right sides
            if((Native.GetAsyncKeyState(key)&0x8000)!=0)keys.Add(key);
        }
        router.SeedVisibleKeys(keys);needsSeed=false;
    }
    private IntPtr Handle(int code,IntPtr message,IntPtr data) {
        if(code<0)return Native.CallNextHookEx(hook,code,message,data);
        try {
            var raw=Marshal.PtrToStructure<Native.KeyboardData>(data);
            bool down=message.ToInt64() is 0x100 or 0x104;
            bool up=message.ToInt64() is 0x101 or 0x105;
            if(!down&&!up)return Native.CallNextHookEx(hook,code,message,data);
            if((raw.Flags&0x10)!=0)return Native.CallNextHookEx(hook,code,message,data);
            bool extended=(raw.Flags&1)!=0;
            var key=new PhysicalKey(KeyboardKeys.NormalizeVirtualKey((int)raw.VirtualKey,(int)raw.ScanCode,extended),(int)raw.ScanCode,extended);
            var result=router.Process(new(key,down));
            if(result.Count)Pressed?.Invoke(key,DateTimeOffset.UtcNow);
            if(result.SoundDown)Sound?.Invoke(key,true);
            // A paused release still closes the physical sound's variant token.
            if(result.SoundUp)Sound?.Invoke(key,false);
            if(result.Inject.Length>0&&!Send(result.Inject)) {
                Send(router.InjectionFailed(key.Id));
                Failed?.Invoke("Key remapping was disabled because Windows rejected synthetic input. Elevated apps may require the same privilege level.");
                return Native.CallNextHookEx(hook,code,message,data);
            }
            if(result.Suppress)return new IntPtr(1);
        } catch(Exception ex) {Failed?.Invoke(ex.Message);}
        return Native.CallNextHookEx(hook,code,message,data);
    }
    private static bool Send(KeyInjection[] keys) {
        if(keys.Length==0)return true;
        var input=keys.Select(k=>new Native.Input {Type=1,Union=new Native.InputUnion{Keyboard=new Native.KeyboardInput {
            VirtualKey=(ushort)k.VirtualKey,Flags=(k.Down?0u:2u)|(KeyboardKeys.RequiresExtendedInjection(k.VirtualKey)?1u:0u),ExtraInfo=new UIntPtr(0x4B57574F)
        }}}).ToArray();
        var original=keys.Select(k=>k.VirtualKey).Distinct().ToDictionary(k=>k,k=>(Native.GetAsyncKeyState(k)&0x8000)!=0);
        uint sent=Native.SendInput((uint)input.Length,input,Marshal.SizeOf<Native.Input>());
        if(sent==input.Length)return true;
        if(sent>0) {
            // Restore the pre-injection key state after an unlikely partial send.
            // Injected repair events are ignored by our hook, just like outputs.
            var repair=original.Select(p=>new Native.Input{Type=1,Union=new Native.InputUnion{Keyboard=new Native.KeyboardInput{VirtualKey=(ushort)p.Key,Flags=(p.Value?0u:2u)|(KeyboardKeys.RequiresExtendedInjection(p.Key)?1u:0u),ExtraInfo=new UIntPtr(0x4B57574F)}}}).ToArray();
            Native.SendInput((uint)repair.Length,repair,Marshal.SizeOf<Native.Input>());
        }
        return false;
    }
    public void Dispose() {
        if(disposed)return;disposed=true;
        if(dispatcher is not null&&!dispatcher.HasShutdownStarted) {
            dispatcher.Invoke(()=>{Send(router.Configure(false,false,[]));if(hook!=IntPtr.Zero){Native.UnhookWindowsHookEx(hook);hook=IntPtr.Zero;}dispatcher.BeginInvokeShutdown(DispatcherPriority.Send);});
        }
        if(thread.IsAlive&&Thread.CurrentThread!=thread)thread.Join(1500);
        GC.KeepAlive(callback);
    }
}
internal static class Native {
    internal delegate IntPtr HookProc(int code,IntPtr message,IntPtr data);
    [StructLayout(LayoutKind.Sequential)] internal struct KeyboardData {public uint VirtualKey,ScanCode,Flags,Time;public UIntPtr ExtraInfo;}
    [StructLayout(LayoutKind.Sequential)] internal struct Input {public uint Type;public InputUnion Union;}
    [StructLayout(LayoutKind.Explicit)] internal struct InputUnion {
        [FieldOffset(0)]public KeyboardInput Keyboard;
        [FieldOffset(0)]public MouseInput Mouse; // INPUT union must be 32 bytes on x64.
    }
    [StructLayout(LayoutKind.Sequential)]internal struct KeyboardInput{public ushort VirtualKey,Scan;public uint Flags,Time;public UIntPtr ExtraInfo;}
    [StructLayout(LayoutKind.Sequential)]internal struct MouseInput{public int X,Y;public uint MouseData,Flags,Time;public UIntPtr ExtraInfo;}
    [DllImport("user32.dll",SetLastError=true)]internal static extern IntPtr SetWindowsHookEx(int id,HookProc callback,IntPtr module,uint thread);
    [DllImport("user32.dll",SetLastError=true)]internal static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")]internal static extern IntPtr CallNextHookEx(IntPtr hook,int code,IntPtr message,IntPtr data);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)]internal static extern IntPtr GetModuleHandle(string? name);
    [DllImport("user32.dll")]internal static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll",SetLastError=true)]internal static extern uint SendInput(uint count,Input[] input,int size);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)]internal static extern IntPtr FindWindow(string? className,string name);
    [DllImport("user32.dll")]internal static extern bool ShowWindow(IntPtr window,int command);
    [DllImport("user32.dll")]internal static extern bool SetForegroundWindow(IntPtr window);
}
