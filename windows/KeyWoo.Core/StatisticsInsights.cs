namespace KeyWoo.Core;

public sealed record HeatmapBand(int Level, long Minimum, long Maximum);
public sealed class HeatmapScale {
    public long Maximum { get; }
    public IReadOnlyList<HeatmapBand> Bands { get; }
    public HeatmapScale(long maximum) {
        Maximum = Math.Max(0, maximum);
        var bands = new List<HeatmapBand>();
        double logarithm = Math.Log(1d + Maximum);
        for (int level = 1; level <= 5 && Maximum > 0; level++) {
            long lower = (long)Math.Floor(Math.Exp(logarithm * (level - 1) / 5) - 1 + 1e-9) + 1;
            long upper = level == 5 ? Maximum : (long)Math.Floor(Math.Exp(logarithm * level / 5) - 1 + 1e-9);
            if (lower <= upper) bands.Add(new(level, lower, upper));
        }
        Bands = bands;
    }
    public int Level(long count) {
        if(count<=0||Maximum==0)return 0;
        return Bands.FirstOrDefault(band=>count<=band.Maximum)?.Level??5;
    }
}

public enum StatisticsInterval { Auto, FiveMinutes, FifteenMinutes, Hour, Day, Week, Month, Years }
public sealed record StatisticsTrendBucket(DateTimeOffset Start, DateTimeOffset End, long Count);
public sealed record StatisticsSnapshot(long Revision, DateTimeOffset From, DateTimeOffset To,
    IReadOnlyList<KeyCount> Counts, long Total, int ActiveMinutes, long PeakMinuteCount,
    DateTimeOffset? PeakMinute, StatisticsInterval Interval, IReadOnlyList<StatisticsTrendBucket> Trend) {
    public double AveragePerActiveMinute => ActiveMinutes == 0 ? 0 : (double)Total / ActiveMinutes;
}

internal sealed class StatisticsTrendPlan {
    internal readonly List<(DateTimeOffset Start, DateTimeOffset End)> Ranges = [];
    internal StatisticsInterval Interval { get; }
    private StatisticsTrendPlan(StatisticsInterval interval) { Interval = interval; }
    internal static StatisticsTrendPlan Create(DateTimeOffset from, DateTimeOffset to,
        TimeZoneInfo zone, StatisticsInterval interval) {
        double days = (to - from).TotalDays;
        if (interval == StatisticsInterval.Auto) interval = days switch {
            <= 90d / 1440 => StatisticsInterval.FiveMinutes,
            <= .5 => StatisticsInterval.FifteenMinutes,
            <= 2 => StatisticsInterval.Hour,
            <= 14 => StatisticsInterval.Day,
            <= 180 => StatisticsInterval.Week,
            <= 2192 => StatisticsInterval.Month,
            _ => StatisticsInterval.Years
        };
        var plan = new StatisticsTrendPlan(interval);
        if (to <= from) return plan;
        DateTime local = TimeZoneInfo.ConvertTime(from, zone).DateTime;
        int yearStep = Math.Max(1, (int)Math.Ceiling((to.Year - from.Year + 1) / 60.0));
        DateTime anchor = interval switch {
            StatisticsInterval.FiveMinutes => new(local.Year, local.Month, local.Day, local.Hour, local.Minute / 5 * 5, 0),
            StatisticsInterval.FifteenMinutes => new(local.Year, local.Month, local.Day, local.Hour, local.Minute / 15 * 15, 0),
            StatisticsInterval.Hour => new(local.Year, local.Month, local.Day, local.Hour, 0, 0),
            StatisticsInterval.Week => local.Date.AddDays(-((7 + (int)local.DayOfWeek - (int)DayOfWeek.Monday) % 7)),
            StatisticsInterval.Month => new(local.Year, local.Month, 1),
            StatisticsInterval.Years => new(Math.Max(1, (local.Year - 1) / yearStep * yearStep + 1), 1, 1),
            _ => local.Date
        };
        DateTimeOffset start = ResolveLocal(anchor, zone);
        // Keep the offset of the selected repeated hour when clocks go back.
        if (interval is StatisticsInterval.FiveMinutes or StatisticsInterval.FifteenMinutes or StatisticsInterval.Hour)
            start = new DateTimeOffset(anchor, TimeZoneInfo.ConvertTime(from, zone).Offset);
        while (start < to && plan.Ranges.Count < 72) {
            DateTimeOffset end;
            try {
                end = interval switch {
                    StatisticsInterval.FiveMinutes => start.AddMinutes(5),
                    StatisticsInterval.FifteenMinutes => start.AddMinutes(15),
                    StatisticsInterval.Hour => start.AddHours(1),
                    StatisticsInterval.Day => ResolveLocal(anchor.AddDays(1), zone),
                    StatisticsInterval.Week => ResolveLocal(anchor.AddDays(7), zone),
                    StatisticsInterval.Month => ResolveLocal(anchor.AddMonths(1), zone),
                    _ => ResolveLocal(anchor.AddYears(yearStep), zone)
                };
            } catch (ArgumentOutOfRangeException) { end = to; }
            if (end <= start) end = start.AddMinutes(1);
            plan.Ranges.Add((start < from ? from : start, end > to ? to : end));
            start = end;
            anchor = TimeZoneInfo.ConvertTime(start, zone).DateTime;
        }
        if (start < to) {
            var next = interval switch {
                StatisticsInterval.FiveMinutes => StatisticsInterval.FifteenMinutes,
                StatisticsInterval.FifteenMinutes => StatisticsInterval.Hour,
                StatisticsInterval.Hour => StatisticsInterval.Day,
                StatisticsInterval.Day => StatisticsInterval.Week,
                StatisticsInterval.Week => StatisticsInterval.Month,
                _ => StatisticsInterval.Years
            };
            if (interval != StatisticsInterval.Years) return Create(from,to,zone,next);
            plan.Ranges.Clear();
            plan.Ranges.Add((from,to));
        }
        return plan;
    }
    private static DateTimeOffset ResolveLocal(DateTime value, TimeZoneInfo zone) {
        value = DateTime.SpecifyKind(value, DateTimeKind.Unspecified);
        while (zone.IsInvalidTime(value)) value = value.AddMinutes(1);
        TimeSpan offset = zone.IsAmbiguousTime(value) ? zone.GetAmbiguousTimeOffsets(value).Max() : zone.GetUtcOffset(value);
        return new(value, offset);
    }
}

/// <summary>One selected-range query, rebuilt at the throttled presentation refresh.</summary>
internal sealed class StatisticsQuery {
    private readonly long first, end;
    private readonly string zoneId;
    private readonly StatisticsInterval requestedInterval;
    private readonly StatisticsTrendPlan plan;
    private readonly Dictionary<int,KeyCount> counts = [];
    private readonly Dictionary<long,long> minutes = [];
    private readonly long[] trend;
    private long total, peak;
    private long? peakMinute;
    internal StatisticsQuery(long first, long end, TimeZoneInfo zone, StatisticsInterval interval) {
        this.first = first; this.end = end; zoneId = zone.Id; requestedInterval = interval;
        plan = StatisticsTrendPlan.Create(MinuteDate(first), MinuteDate(end), zone, interval);
        trend = new long[plan.Ranges.Count];
    }
    internal bool Matches(long a, long b, TimeZoneInfo zone, StatisticsInterval interval) =>
        a == first && b == end && zone.Id == zoneId && interval == requestedInterval;
    internal void Add(int key, string label, long minute, long count) {
        if (minute < first || minute >= end || count <= 0) return;
        counts[key] = new(key, label, counts.GetValueOrDefault(key)?.Count + count ?? count);
        total += count;
        long minuteCount = minutes.GetValueOrDefault(minute) + count;
        minutes[minute] = minuteCount;
        if (minuteCount > peak || minuteCount == peak && (peakMinute is null || minute < peakMinute)) {
            peak = minuteCount; peakMinute = minute;
        }
        var timestamp = DateTimeOffset.FromUnixTimeSeconds(minute * 60);
        int low = 0, high = plan.Ranges.Count;
        while (low < high) {
            int middle = low + (high - low) / 2;
            if (plan.Ranges[middle].End <= timestamp) low = middle + 1;
            else high = middle;
        }
        if (low < trend.Length && timestamp >= plan.Ranges[low].Start) trend[low] += count;
    }
    private static DateTimeOffset MinuteDate(long minute) => DateTimeOffset.FromUnixTimeSeconds(
        Math.Clamp(minute * 60, DateTimeOffset.MinValue.ToUnixTimeSeconds(), DateTimeOffset.MaxValue.ToUnixTimeSeconds()));
    internal StatisticsSnapshot Snapshot(long revision) => new(revision,
        MinuteDate(first), MinuteDate(end),
        counts.Values.OrderByDescending(p => p.Count).ThenBy(p => p.Key).ToArray(), total, minutes.Count, peak,
        peakMinute is long at ? DateTimeOffset.FromUnixTimeSeconds(at * 60) : null, plan.Interval,
        plan.Ranges.Select((range, index) => new StatisticsTrendBucket(range.Start, range.End, trend[index])).ToArray());
}
