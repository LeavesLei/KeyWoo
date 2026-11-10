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
    private const long MaximumArchiveTotal = 1_000_000_000_000;
    private StatisticsQuery? query;
    private long queryRevision = -1;
    private readonly SortedSet<long> minuteIndex = [];
    public StatisticsStore(string path) {
        this.path=path;
        if(!File.Exists(path)) return;
        try {
            data=JsonSerializer.Deserialize<StatisticsDocument>(File.ReadAllText(path)) ?? throw new InvalidDataException("Empty statistics");
            if(data.Schema!=1 || data.Minutes is null || data.Labels is null || data.Minutes.Values.Any(v=>v is null)||!SafeCounts(data.Minutes)) throw new InvalidDataException("Invalid statistics schema");
            minuteIndex.UnionWith(data.Minutes.Keys);
        } catch(Exception ex) when(ex is IOException or UnauthorizedAccessException or JsonException or InvalidDataException) {
            data=new(1,[],[]); Error=ex.Message; loadFailed=true;
        }
    }
    public void Record(PhysicalKey key, DateTimeOffset at) {
        lock(gate) {
            long minute=FloorMinute(at);
            if(!data.Minutes.TryGetValue(minute,out var counts)) { data.Minutes[minute]=counts=[]; minuteIndex.Add(minute); }
            counts[key.Id]=counts.GetValueOrDefault(key.Id)+1;
            data.Labels[key.Id]=KeyboardKeys.Name(key.VirtualKey);
            SessionTotal++; revision++;
        }
    }
    public IReadOnlyList<KeyCount> Counts(DateTimeOffset from,DateTimeOffset to) {
        if(to<=from) return [];
        long first=FloorMinute(from), end=CeilingMinute(to);
        lock(gate) {
            var counts=new Dictionary<int,long>();
            foreach(var (minute,bucket) in data.Minutes) if(minute>=first&&minute<end)
                foreach(var (key,count) in bucket) counts[key]=counts.GetValueOrDefault(key)+count;
            return counts.OrderByDescending(p=>p.Value).ThenBy(p=>p.Key)
                .Select(p=>new KeyCount(p.Key,data.Labels.GetValueOrDefault(p.Key,$"Scan {p.Key:X}"),p.Value)).ToArray();
        }
    }
    private static bool SafeCounts(Dictionary<long,Dictionary<int,long>> minutes) {
        long total = 0;
        foreach(var keys in minutes.Values) foreach(long count in keys.Values) {
            if(count<0 || count>MaximumArchiveTotal-total)return false;
            total+=count;
        }
        return true;
    }
    private static long FloorMinute(DateTimeOffset value) {
        long quotient = Math.DivRem(value.UtcTicks-DateTimeOffset.UnixEpoch.UtcTicks,TimeSpan.TicksPerMinute,out long remainder);
        return quotient-(remainder<0?1:0);
    }
    private static long CeilingMinute(DateTimeOffset value) {
        long quotient = Math.DivRem(value.UtcTicks-DateTimeOffset.UnixEpoch.UtcTicks,TimeSpan.TicksPerMinute,out long remainder);
        return quotient+(remainder>0?1:0);
    }
    public long Revision { get { lock(gate) return revision; } }
    public StatisticsSnapshot Snapshot(DateTimeOffset from, DateTimeOffset to,
        TimeZoneInfo? zone = null, StatisticsInterval interval = StatisticsInterval.Auto) {
        zone ??= TimeZoneInfo.Local;
        if (to <= from) return new(Revision, from, to, [], 0, 0, 0, null, interval, []);
        long first = FloorMinute(from);
        long end = CeilingMinute(to);
        lock(gate) {
            if (query is null || queryRevision != revision || !query.Matches(first, end, zone, interval)) {
                query = new(first, end, zone, interval);
                foreach (long minute in minuteIndex.GetViewBetween(first, end - 1)) {
                    var keys = data.Minutes[minute];
                    foreach (var (key, count) in keys)
                        query.Add(key, data.Labels.GetValueOrDefault(key, $"Scan {key:X}"), minute, count);
                }
                queryRevision = revision;
            }
            return query.Snapshot(revision);
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
