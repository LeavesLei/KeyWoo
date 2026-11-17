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
    private long? firstObservedMinute;
    private (long First, long End, StatisticsComparison Result)? previousComparison;
    public StatisticsStore(string path) {
        this.path=path;
        if(!File.Exists(path)) return;
        try {
            data=JsonSerializer.Deserialize<StatisticsDocument>(File.ReadAllText(path)) ?? throw new InvalidDataException("Empty statistics");
            if(data.Schema!=1 || data.Minutes is null || data.Labels is null || data.Minutes.Values.Any(v=>v is null)||!SafeCounts(data.Minutes)) throw new InvalidDataException("Invalid statistics schema");
            minuteIndex.UnionWith(data.Minutes.Keys);
            firstObservedMinute = minuteIndex.Where(HasActivity).Select(minute => (long?)minute).FirstOrDefault();
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
            if (firstObservedMinute is null || minute < firstObservedMinute) firstObservedMinute = minute;
            if (previousComparison is { } cached && minute >= cached.First && minute < cached.End) previousComparison = null;
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
    public static DateTimeOffset StartOfRecentDays(DateTimeOffset now, int dayCount, TimeZoneInfo zone) {
        ArgumentOutOfRangeException.ThrowIfLessThan(dayCount, 1);
        var today = TimeZoneInfo.ConvertTime(now, zone).Date;
        return StatisticsTrendPlan.ResolveLocal(today.AddDays(1 - dayCount), zone);
    }
    public IReadOnlyList<StatisticsDailyActivity> DailyActivity(DateTimeOffset now, int dayCount, TimeZoneInfo? zone = null) {
        ArgumentOutOfRangeException.ThrowIfGreaterThan(dayCount, 30);
        zone ??= TimeZoneInfo.Local;
        long first = FloorMinute(StartOfRecentDays(now, dayCount, zone));
        long end = CeilingMinute(now);
        var today = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(now, zone).DateTime);
        var firstDay = today.AddDays(1 - dayCount);
        var activeMinutes = new int[dayCount];
        if (first < end) {
            lock (gate) {
                foreach (long minute in minuteIndex.GetViewBetween(first, end - 1)) {
                    if (!HasActivity(minute)) continue;
                    var timestamp = DateTimeOffset.FromUnixTimeSeconds(minute * 60);
                    var day = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(timestamp, zone).DateTime);
                    int index = day.DayNumber - firstDay.DayNumber;
                    if (index >= 0 && index < dayCount) activeMinutes[index]++;
                }
            }
        }
        return activeMinutes.Select((count, index) => new StatisticsDailyActivity(firstDay.AddDays(index), count)).ToArray();
    }
    public IReadOnlyList<StatisticsTrendBucket> HourlyActivity(DateOnly day, DateTimeOffset now, TimeZoneInfo? zone = null) {
        zone ??= TimeZoneInfo.Local;
        var start = StatisticsTrendPlan.ResolveLocal(day.ToDateTime(TimeOnly.MinValue), zone);
        var end = StatisticsTrendPlan.ResolveLocal(day.AddDays(1).ToDateTime(TimeOnly.MinValue), zone);
        if (start > now || start >= end) return [];
        var hours = new List<(DateTimeOffset Start, DateTimeOffset End)>();
        var hourStart = start;
        // Look for changes in the local clock hour or UTC offset. This also
        // retains repeated hours and realigns after a half-hour DST change.
        for (var minute = start.AddMinutes(1); minute <= end; minute = minute.AddMinutes(1)) {
            var local = TimeZoneInfo.ConvertTime(minute, zone);
            if (minute < end && local.Hour == hourStart.Hour && local.Offset == hourStart.Offset) continue;
            hours.Add((hourStart, local));
            hourStart = local;
            if (hourStart > now) break;
        }
        lock (gate) {
            return hours.Select(hour => {
                long first = FloorMinute(hour.Start);
                long last = CeilingMinute(hour.End < now ? hour.End : now) - 1;
                long count = first <= last ? minuteIndex.GetViewBetween(first, last).Count(HasActivity) : 0;
                return new StatisticsTrendBucket(hour.Start, hour.End, count);
            }).ToArray();
        }
    }
    private bool HasActivity(long minute) {
        foreach (long count in data.Minutes[minute].Values)
            if (count > 0) return true;
        return false;
    }
    /// <summary>Compare archived minutes with a matching earlier period that starts at or after the first recorded minute.</summary>
    public StatisticsComparison? ComparePrevious(DateTimeOffset from, DateTimeOffset to,
        int? calendarDaysBack = null, TimeZoneInfo? zone = null) {
        if (to <= from) return null;
        if (calendarDaysBack is int days) ArgumentOutOfRangeException.ThrowIfLessThan(days, 1);
        zone ??= TimeZoneInfo.Local;
        long currentStart = FloorMinute(from);
        long currentEnd = CeilingMinute(to);
        long first;
        long end;
        try {
            if (calendarDaysBack is int shift) {
                var localStart = TimeZoneInfo.ConvertTime(from, zone).Date.AddDays(-shift);
                // Shift wall time before rounding. During clock changes an
                // absolute minute boundary can move to a different local hour.
                var localEnd = TimeZoneInfo.ConvertTime(to, zone).DateTime.AddDays(-shift);
                first = FloorMinute(StatisticsTrendPlan.ResolveLocal(localStart, zone));
                end = Math.Min(currentStart, CeilingMinute(StatisticsTrendPlan.ResolveLocal(localEnd, zone)));
            } else {
                first = currentStart - (currentEnd - currentStart);
                end = currentStart;
            }
        } catch (ArgumentOutOfRangeException) {
            return null;
        }
        if (end <= first || first < FloorMinute(DateTimeOffset.MinValue)) return null;
        var previousStart = MinuteDate(first);
        var previousEnd = MinuteDate(end);
        lock (gate) {
            if (firstObservedMinute is not long observed || first < observed) return null;
            if (previousComparison is { } cached && cached.First == first && cached.End == end) return cached.Result;
            long total = 0;
            int activeMinutes = 0;
            foreach (long minute in minuteIndex.GetViewBetween(first, end - 1)) {
                long presses = data.Minutes[minute].Values.Sum();
                total += presses;
                if (presses > 0) activeMinutes++;
            }
            var result = new StatisticsComparison(previousStart, previousEnd, total, activeMinutes);
            previousComparison = (first, end, result);
            return result;
        }
    }
    private static DateTimeOffset MinuteDate(long minute) => DateTimeOffset.FromUnixTimeSeconds(
        Math.Clamp(minute * 60, DateTimeOffset.MinValue.ToUnixTimeSeconds(), DateTimeOffset.MaxValue.ToUnixTimeSeconds()));
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
