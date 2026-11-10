using System.Text.Json;
using System.Windows;
using KeyWoo.Core;
namespace KeyWoo.Windows;
public partial class App : System.Windows.Application {
    private Mutex? instance;
    protected override void OnStartup(StartupEventArgs e) {
        base.OnStartup(e);
        if(e.Args.Length==2&&e.Args[0]=="--verify-assets") {
            try {
                var bank=new SampleBank(Path.Combine(AppContext.BaseDirectory,"Assets","KeyboardSounds"));
                var hashes=new Dictionary<string,string>();
                var hiFiHashes=new Dictionary<string,string>();
                if(!bank.Packs.ContainsKey(SampleBank.StreetBeatPreset))throw new InvalidDataException("Missing Street Beat kit");
                foreach(var preset in bank.Presets) {
                    string original=RenderPreset(bank,preset.Id,false);
                    hashes.Add(preset.Id,original);
                    if(preset.Category==SoundCategory.Synthesized)continue;
                    if(!bank.HiFiPacks.ContainsKey(preset.Id))throw new InvalidDataException("Missing verified Hi-Fi recording: "+preset.Id);
                    string restored=RenderPreset(bank,preset.Id,true);
                    if(restored==original)throw new InvalidDataException("Hi-Fi playback matches Original: "+preset.Id);
                    hiFiHashes.Add(preset.Id,restored);
                }
                if(hashes.Values.Distinct().Count()!=hashes.Count)throw new InvalidDataException("Duplicate preset PCM");
                var keyBurst=KeyBurstVerification.Run(e.Args[1]);
                var edgeGlow=EdgeGlowVerification.Run(e.Args[1]);
                var statistics=StatisticsVerification.Run(e.Args[1]);
                File.WriteAllText(e.Args[1],JsonSerializer.Serialize(new{passed=true,presets=hashes,hiFiPresets=hiFiHashes,keyBurst,edgeGlow,statistics,deviceTested=false},new JsonSerializerOptions{WriteIndented=true}));Shutdown(0);
            } catch(Exception ex){File.WriteAllText(e.Args[1],JsonSerializer.Serialize(new{passed=false,error=ex.ToString()}));Shutdown(1);}
            return;
        }
        instance=new Mutex(true,"Local\\KeyWoo.Windows",out bool first);
        if(!first) {
            foreach(string title in new[]{"KeyWoo","键舞"}){var handle=Native.FindWindow(null,title);if(handle!=IntPtr.Zero){Native.ShowWindow(handle,9);Native.SetForegroundWindow(handle);break;}}
            Shutdown();return;
        }
        var window=new MainWindow();MainWindow=window;window.Show();
    }
    private static string RenderPreset(SampleBank bank,string id,bool hiFi) {
        var mixer=new SampleMixer(bank){Style=id,HiFiEnabled=hiFi,Volume=1};
        mixer.Physical(new PhysicalKey(0x41,0x1E),true);
        var pcm=new float[48000];
        mixer.Read(pcm);
        if(!pcm.Any(v=>Math.Abs(v)>.0001f)||pcm.Any(v=>!float.IsFinite(v)))
            throw new InvalidDataException($"Silent/non-finite {(hiFi?"Hi-Fi":"Original")} preset: {id}");
        byte[] bytes=new byte[pcm.Length*sizeof(float)];
        Buffer.BlockCopy(pcm,0,bytes,0,bytes.Length);
        return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes));
    }
    protected override void OnExit(ExitEventArgs e){instance?.Dispose();base.OnExit(e);}
}
