using System.Text.Json;
using KeyWoo.Core;
namespace KeyWoo.Windows;
internal sealed class Settings {
    private readonly SemaphoreSlim writer=new(1,1);
    public int Schema {get;set;}=1;
    public string Platform {get;set;}="windows";
    public string Language {get;set;}="system";
    public string Appearance {get;set;}="system";
    public string Preset {get;set;}=SampleBank.DefaultPreset;
    public double Volume {get;set;}=.5;
    public bool MappingEnabled {get;set;}
    public List<InputRule> Rules {get;set;}=[];
    public static string DataDirectory=>Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"KeyWoo");
    private static string FilePath=>Path.Combine(DataDirectory,"settings.json");
    public static Settings Load(out string? error) {
        error=null;
        try {
            if(!File.Exists(FilePath))return new();
            var s=JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath))??new();
            if(s.Schema!=1||s.Platform!="windows")throw new JsonException("Unsupported settings schema/platform");
            s.Volume=double.IsFinite(s.Volume)?Math.Clamp(s.Volume,0,SampleMixer.MaximumVolume):.5;
            if(string.IsNullOrWhiteSpace(s.Preset))s.Preset=SampleBank.DefaultPreset;
            if(s.Language is not ("system" or "zh" or "en"))s.Language="system";
            if(s.Appearance is not ("system" or "light" or "dark"))s.Appearance="system";
            s.Rules=(s.Rules??[]).Where(r=>r is not null).ToList();return s;
        } catch(Exception ex) when(ex is IOException or UnauthorizedAccessException or JsonException) {error=ex.Message;return new();}
    }
    public async Task SaveAsync() {
        await writer.WaitAsync().ConfigureAwait(false);
        try{await AtomicJson.WriteTextAsync(FilePath,JsonSerializer.Serialize(this,new JsonSerializerOptions{WriteIndented=true})).ConfigureAwait(false);}
        finally{writer.Release();}
    }
}
