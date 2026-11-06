using KeyWoo.Core;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wave;
using System.Runtime.InteropServices;
using System.Windows.Threading;
namespace KeyWoo.Windows;

internal sealed class AudioOutput : IDisposable, IWaveProvider {
    private WasapiOut? output;
    private readonly Dispatcher dispatcher=Dispatcher.CurrentDispatcher;
    private readonly DispatcherTimer recovery;
    private readonly MMDeviceEnumerator devices;
    private readonly DeviceNotifications notifications;
    private int attempts;
    private volatile bool disposed;
    public SampleMixer Mixer { get; }
    public WaveFormat WaveFormat { get; }=WaveFormat.CreateIeeeFloatWaveFormat(SampleBank.SampleRate,2);
    public event Action<string>? Failed;
    public event Action? Recovered;
    public AudioOutput(SampleBank bank) {
        Mixer=new(bank);
        recovery=new DispatcherTimer(DispatcherPriority.Background,dispatcher){Interval=TimeSpan.FromMilliseconds(500)};
        recovery.Tick+=(_,_)=>{
            recovery.Stop();if(disposed)return;attempts++;
            try{RestartCore();Recovered?.Invoke();}catch(Exception ex){Failed?.Invoke(ex.Message);}
        };
        devices=new MMDeviceEnumerator();notifications=new DeviceNotifications(()=>QueueRecovery(true));
        try{devices.RegisterEndpointNotificationCallback(notifications);}catch{devices.Dispose();throw;}
    }
    public void Start() {
        if(disposed||output is not null)return;
        WasapiOut? device=null;
        try {
            device=new WasapiOut(AudioClientShareMode.Shared,true,20);
            device.Init(this);
            var activeDevice=device;
            device.PlaybackStopped+=(_,e)=>{
                if(e.Exception is null||disposed||!ReferenceEquals(output,activeDevice))return;
                Failed?.Invoke(e.Exception.Message);QueueRecovery(false);
            };
            output=device;device.Play();
        } catch { output=null;device?.Dispose();QueueRecovery(false);throw; }
    }
    // Called on the UI dispatcher only. Device callbacks merely schedule this;
    // teardown never runs on the audio thread or keyboard hook thread.
    public void Restart() { attempts=0;recovery.Stop();RestartCore(); }
    private void RestartCore() { StopOutput();Mixer.Reset();Start(); }
    private void QueueRecovery(bool deviceChanged) {
        if(disposed||dispatcher.HasShutdownStarted)return;
        dispatcher.BeginInvoke(()=>{
            if(disposed)return;if(deviceChanged)attempts=0;
            if(attempts<3){recovery.Stop();recovery.Start();}
        });
    }
    private void StopOutput(){var old=output;output=null;old?.Stop();old?.Dispose();}
    public int Read(byte[] buffer,int offset,int count) {count-=count%8;Mixer.Read(MemoryMarshal.Cast<byte,float>(buffer.AsSpan(offset,count)));return count;}
    public void Dispose(){if(disposed)return;disposed=true;recovery.Stop();try{devices.UnregisterEndpointNotificationCallback(notifications);}finally{devices.Dispose();StopOutput();}}
    private sealed class DeviceNotifications(Action changed) : IMMNotificationClient {
        public void OnDefaultDeviceChanged(DataFlow flow,Role role,string id){if(flow==DataFlow.Render&&role==Role.Console)changed();}
        public void OnDeviceAdded(string id){}
        public void OnDeviceRemoved(string id){}
        public void OnDeviceStateChanged(string id,DeviceState state){}
        public void OnPropertyValueChanged(string id,PropertyKey key){}
    }
}
