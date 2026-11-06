using System.Globalization;
using System.Text;
using System.Text.Json;
namespace KeyWoo.Core;

public sealed record StatisticsDocument(int Schema, Dictionary<long,Dictionary<int,long>> Minutes, Dictionary<int,string> Labels);
public sealed record KeyCount(int Key,string Label,long Count);
/// UTC minute aggregates only: no text, key order, window titles or application names.
/// Range boundaries round outward to include intersecting minutes; end is exclusive.
public sealed class StatisticsStore {
    private readonly string path;
    private readonly object gate=new();
    private readonly SemaphoreSlim writer=new(1,1);
    private StatisticsDocument data=new(1,[],[]);
    private long revision,savedRevision;
    public string? Error { get; private set; }
    public long SessionTotal { get; private set; }
    private bool loadFailed;
    public StatisticsStore(string path) {
        this.path=path;
        if(!File.Exists(path)) return;
        try {
            data=JsonSerializer.Deserialize<StatisticsDocument>(File.ReadAllText(path)) ?? throw new InvalidDataException("Empty statistics");
            if(data.Schema!=1 || data.Minutes is null || data.Labels is null || data.Minutes.Values.Any(v=>v is null||v.Values.Any(c=>c<0))) throw new InvalidDataException("Invalid statistics schema");
        } catch(Exception ex) when(ex is IOException or UnauthorizedAccessException or JsonException or InvalidDataException) {
            data=new(1,[],[]); Error=ex.Message; loadFailed=true;
        }
    }
    public void Record(PhysicalKey key, DateTimeOffset at) {
        lock(gate) {
            long minute=at.ToUnixTimeSeconds()/60;
            if(!data.Minutes.TryGetValue(minute,out var counts)) data.Minutes[minute]=counts=[];
            counts[key.Id]=counts.GetValueOrDefault(key.Id)+1;
            data.Labels[key.Id]=KeyboardKeys.Name(key.VirtualKey);
            SessionTotal++; revision++;
        }
    }
    public IReadOnlyList<KeyCount> Counts(DateTimeOffset from,DateTimeOffset to) {
        if(to<=from) return [];
        long first=(long)Math.Floor(from.ToUnixTimeMilliseconds()/60000d), end=(long)Math.Ceiling(to.ToUnixTimeMilliseconds()/60000d);
        lock(gate) {
            var counts=new Dictionary<int,long>();
            foreach(var (minute,bucket) in data.Minutes) if(minute>=first&&minute<end)
                foreach(var (key,count) in bucket) counts[key]=counts.GetValueOrDefault(key)+count;
            return counts.OrderByDescending(p=>p.Value).ThenBy(p=>p.Key)
                .Select(p=>new KeyCount(p.Key,data.Labels.GetValueOrDefault(p.Key,$"Scan {p.Key:X}"),p.Value)).ToArray();
        }
    }
    public string Csv(DateTimeOffset from,DateTimeOffset to) {
        var result=new StringBuilder("physical_key,label,count\r\n");
        foreach(var row in Counts(from,to)) result.Append(row.Key).Append(",\"").Append(row.Label.Replace("\"","\"\"")).Append("\",").Append(row.Count.ToString(CultureInfo.InvariantCulture)).Append("\r\n");
        return result.ToString();
    }
    public async Task FlushAsync() {
        await writer.WaitAsync().ConfigureAwait(false);
        try {
            string json; long version;
            lock(gate) { if(loadFailed||revision==savedRevision) return; version=revision; json=JsonSerializer.Serialize(data); }
            await AtomicJson.WriteTextAsync(path,json).ConfigureAwait(false);
            lock(gate) { savedRevision=version; Error=null; }
        } catch(Exception ex) when(ex is IOException or UnauthorizedAccessException) { Error=ex.Message; }
        finally { writer.Release(); }
    }
}
public static class AtomicJson {
    public static async Task WriteTextAsync(string path,string json) {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        string temporary=path+"."+Guid.NewGuid().ToString("N")+".tmp";
        try { await File.WriteAllTextAsync(temporary,json).ConfigureAwait(false); File.Move(temporary,path,true); }
        finally { if(File.Exists(temporary)) File.Delete(temporary); }
    }
}
