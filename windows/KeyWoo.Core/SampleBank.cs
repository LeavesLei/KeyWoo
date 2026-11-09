using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
namespace KeyWoo.Core;

public sealed record SampleClip(float[] Samples) {
    public int Frames=>Samples.Length/2;
    public float NormalizationGain {get;internal set;}=1;
}
public sealed record SamplePair(int[] Down,int[] Up);
public enum SoundCategory { RecordedKeyboard, RecordedFoley, Synthesized }
public sealed record SoundPreset(string Id, SoundCategory Category, string Title, string? TitleZh);
public sealed class SamplePack {
    public required string Id { get; init; }
    public required SampleClip[] Clips { get; init; }
    public required Dictionary<int,SamplePair> Keys { get; init; }
    public required SamplePair Fallback { get; init; }
    public KeyboardLoudness.Profile Loudness {get;internal set;}
    public SampleClip? Get(int code,bool down,int variant) {
        var pair=Keys.GetValueOrDefault(code,Fallback);
        var indices=down?pair.Down:pair.Up;
        return indices.Length==0?null:Clips[indices[(int)((uint)variant%(uint)indices.Length)]];
    }
}
public sealed class SampleBank {
    public const int SampleRate=48000;
    public const string DefaultPreset="topre";
    public const string StreetBeatPreset="streetBeat";
    private static readonly string[] PreferredOrder=[DefaultPreset,"oreo","panda","purple","red","blue","bluePBT","brown","brownABS","black","blackABS",
        StreetBeatPreset,"mahjong","typewriter","bubble","woodblock","paper","raindrop","brick","arcade","laser"];
    public IReadOnlyList<SoundPreset> Presets { get; }
    public IReadOnlyDictionary<string,SamplePack> Packs { get; }
    public IReadOnlyDictionary<string,SamplePack> HiFiPacks { get; }
    public SampleBank(string folder) {
        var recorded=ReadManifest(folder,"manifest.json");
        var synthetic=ReadManifest(folder,"synthetic-manifest.json");
        var streetBeat=ReadManifest(folder,"street-beat-manifest.json");
        var hiFi=ReadOptionalHiFiManifest(folder);
        var result=new Dictionary<string,SamplePack>();
        var hiFiResult=new Dictionary<string,SamplePack>();
        var presets=new List<SoundPreset>();
        var entries=recorded.EnumerateObject().Select(entry=>(Entry:entry, IsSynthesized:false))
            .Concat(synthetic.EnumerateObject().Concat(streetBeat.EnumerateObject()).Select(entry=>(Entry:entry, IsSynthesized:true)));
        foreach(var (entry,isSynthesized) in entries) {
            string id=entry.Name;
            var pack=entry.Value;
            if(id.Length==0||id.Any(c=>!char.IsAsciiLetterOrDigit(c)&&c!='-'&&c!='_')
                ||pack.GetProperty("file").GetString()!=$"{id}/samples.wav")
                throw new InvalidDataException("Invalid recording path");
            if(result.ContainsKey(id)) throw new InvalidDataException($"Duplicate preset: {id}");
            string? originalHash=pack.GetProperty("sha256").GetString();
            var clips=ReadClips(folder,id,"samples.wav",pack,originalHash);
            SamplePair ReadPair(JsonElement value) {
                int[] down=value.GetProperty("down").EnumerateArray().Select(i=>i.GetInt32()).ToArray();
                int[] up=value.GetProperty("up").EnumerateArray().Select(i=>i.GetInt32()).ToArray();
                if(down.Length==0||down.Concat(up).Any(i=>i<0||i>=clips.Length)) throw new InvalidDataException("Invalid clip mapping");
                return new(down,up);
            }
            var mappings=pack.GetProperty("keys").EnumerateObject().ToDictionary(p=>int.Parse(p.Name),p=>ReadPair(p.Value));
            var samples=new SamplePack { Id=id,Clips=clips,Keys=mappings,Fallback=ReadPair(pack.GetProperty("fallback")) };
            Calibrate(samples);
            result.Add(id,samples);
            if(!isSynthesized&&hiFi.ValueKind==JsonValueKind.Object&&hiFi.TryGetProperty(id,out var revision)) {
                var restored=ReadOptionalHiFiPack(folder,samples,pack,originalHash,revision);
                if(restored is not null)hiFiResult.Add(id,restored);
            }
            var category=isSynthesized?SoundCategory.Synthesized:
                pack.TryGetProperty("category",out var kind)&&kind.GetString()=="recordedFoley"?SoundCategory.RecordedFoley:SoundCategory.RecordedKeyboard;
            presets.Add(new(id,category,pack.TryGetProperty("title",out var title)?title.GetString()??id:id,
                pack.TryGetProperty("titleZh",out var titleZh)?titleZh.GetString():null));
        }
        if(!result.ContainsKey(DefaultPreset)) throw new InvalidDataException($"Missing default preset: {DefaultPreset}");
        Presets=presets.OrderBy(p=>p.Category).ThenBy(p=>{
            int index=Array.IndexOf(PreferredOrder,p.Id);
            return index<0?int.MaxValue:index;
        }).ToArray();
        Packs=result;
        HiFiPacks=hiFiResult;
    }
    private static JsonElement ReadManifest(string folder,string name) {
        using var document=JsonDocument.Parse(File.ReadAllBytes(Path.Combine(folder,name)));
        var root=document.RootElement;
        if(root.GetProperty("schema").GetInt32()!=1||root.GetProperty("sampleRate").GetInt32()!=SampleRate)
            throw new InvalidDataException($"Unsupported sample manifest: {name}");
        var packs=root.GetProperty("packs");
        if(packs.ValueKind!=JsonValueKind.Object)throw new InvalidDataException($"Invalid sample catalog: {name}");
        return packs.Clone();
    }
    private static JsonElement ReadOptionalHiFiManifest(string folder) {
        try { return ReadManifest(folder,"hifi-manifest.json"); }
        catch(Exception ex) when(ex is IOException or UnauthorizedAccessException or JsonException or InvalidDataException
            or InvalidOperationException or KeyNotFoundException or FormatException) { return default; }
    }
    private static SamplePack? ReadOptionalHiFiPack(string folder,SamplePack original,JsonElement pack,string? originalHash,JsonElement revision) {
        try {
            if(revision.GetProperty("file").GetString()!=$"{original.Id}/samples-hifi.wav"
                ||!string.Equals(revision.GetProperty("originalSHA256").GetString(),originalHash,StringComparison.OrdinalIgnoreCase))return null;
            var clips=ReadClips(folder,original.Id,"samples-hifi.wav",pack,revision.GetProperty("sha256").GetString());
            var restored=new SamplePack { Id=original.Id,Clips=clips,Keys=original.Keys,Fallback=original.Fallback };
            Calibrate(restored);
            return restored;
        } catch(Exception ex) when(ex is IOException or UnauthorizedAccessException or InvalidDataException
            or InvalidOperationException or KeyNotFoundException or OverflowException) { return null; }
    }
    private static SampleClip[] ReadClips(string folder,string id,string filename,JsonElement pack,string? expectedHash) {
        byte[] file=File.ReadAllBytes(Path.Combine(folder,id,filename));
        if(!Convert.ToHexString(SHA256.HashData(file)).Equals(expectedHash,StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException($"Recording checksum mismatch: {id}/{filename}");
        float[] pcm=DecodeWave(file);
        if(pcm.Length/2!=pack.GetProperty("frames").GetInt32())throw new InvalidDataException("Recording length mismatch");
        return pack.GetProperty("clips").EnumerateArray().Select(clip=>{
            int start=clip.GetProperty("startFrame").GetInt32(),frames=clip.GetProperty("frames").GetInt32();
            if(start<0||frames<=0||frames>SampleRate||start>pcm.Length/2-frames)throw new InvalidDataException("Invalid clip range");
            return new SampleClip(pcm.AsSpan(start*2,frames*2).ToArray());
        }).ToArray();
    }
    private static void Calibrate(SamplePack pack) {
        pack.Loudness=KeyboardLoudness.Calibrate(pack);
        foreach(var clip in pack.Clips)clip.NormalizationGain=pack.Loudness.Gain;
    }
    public static float[] DecodeWave(byte[] bytes) {
        if(bytes.Length<44||Encoding.ASCII.GetString(bytes,0,4)!="RIFF"||Encoding.ASCII.GetString(bytes,8,4)!="WAVE") throw new InvalidDataException("Not a RIFF WAV");
        int channels=0,rate=0,bits=0,encoding=0; ReadOnlySpan<byte> data=[];
        for(int cursor=12;cursor<=bytes.Length-8;) {
            string tag=Encoding.ASCII.GetString(bytes,cursor,4);
            uint size=BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(cursor+4,4));
            if(size>int.MaxValue||size>bytes.Length-cursor-8) throw new InvalidDataException("Truncated WAV");
            var chunk=bytes.AsSpan(cursor+8,(int)size);
            if(tag=="fmt ") {
                if(size<16) throw new InvalidDataException("Invalid WAV format");
                encoding=BinaryPrimitives.ReadUInt16LittleEndian(chunk);channels=BinaryPrimitives.ReadUInt16LittleEndian(chunk[2..]);
                rate=BinaryPrimitives.ReadInt32LittleEndian(chunk[4..]);bits=BinaryPrimitives.ReadUInt16LittleEndian(chunk[14..]);
                if(encoding==65534&&size>=40)encoding=BinaryPrimitives.ReadUInt16LittleEndian(chunk[24..]);
            } else if(tag=="data") data=chunk;
            cursor=checked(cursor+8+(int)size+((int)size&1));
        }
        bool integer=encoding==1&&bits==16, floating=encoding==3&&bits==32;
        int bytesPerSample=bits/8;
        if((!integer&&!floating)||channels!=2||rate!=SampleRate||data.Length==0||data.Length%(2*bytesPerSample)!=0) throw new InvalidDataException("Expected stereo 48kHz PCM16/Float32 WAV");
        var result=new float[data.Length/bytesPerSample];
        for(int i=0;i<result.Length;i++) {
            result[i]=integer?BinaryPrimitives.ReadInt16LittleEndian(data[(i*2)..])/32768f:BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(data[(i*4)..]));
            if(!float.IsFinite(result[i])||Math.Abs(result[i])>1)throw new InvalidDataException("Non-finite/out-of-range recording sample");
        }
        return result;
    }
}
