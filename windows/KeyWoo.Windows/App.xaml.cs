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
                foreach(var preset in bank.Presets) {
                    var mixer=new SampleMixer(bank){Style=preset.Id,Volume=1};
                    mixer.Physical(new PhysicalKey(0x41,0x1E),true);var pcm=new float[48000];mixer.Read(pcm);
                    if(!pcm.Any(v=>Math.Abs(v)>.0001f)||pcm.Any(v=>!float.IsFinite(v)))throw new InvalidDataException("Silent/non-finite preset: "+preset.Id);
                    byte[] bytes=new byte[pcm.Length*sizeof(float)];Buffer.BlockCopy(pcm,0,bytes,0,bytes.Length);
                    hashes[preset.Id]=Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes));
                }
                if(hashes.Values.Distinct().Count()!=hashes.Count)throw new InvalidDataException("Duplicate preset PCM");
                File.WriteAllText(e.Args[1],JsonSerializer.Serialize(new{passed=true,presets=hashes,deviceTested=false},new JsonSerializerOptions{WriteIndented=true}));Shutdown(0);
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
    protected override void OnExit(ExitEventArgs e){instance?.Dispose();base.OnExit(e);}
}
