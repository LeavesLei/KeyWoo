using KeyWoo.Core;
using Xunit;
namespace KeyWoo.Tests;

public sealed class StatisticsInsightsTests {
    private static readonly PhysicalKey A = new(0x41,0x1e), Space = new(0x20,0x39);
    private static StatisticsStore Store()=>new(Path.Combine(Path.GetTempPath(),Guid.NewGuid()+".json"));
    [Fact] public void HeatmapHasContiguousDistinctRangesAndOutlierHeadroom() {
        var scale=new HeatmapScale(10000);
        Assert.Equal(0,scale.Level(0));Assert.Equal(5,scale.Level(10000));Assert.Equal(5,scale.Bands.Count);
        long next=1;
        foreach(var band in scale.Bands){Assert.Equal(next,band.Minimum);Assert.Equal(band.Level,scale.Level(band.Minimum));Assert.Equal(band.Level,scale.Level(band.Maximum));next=band.Maximum+1;}
        Assert.Equal(10001,next);Assert.True(scale.Level(100)>scale.Level(1));
    }
    [Fact] public void TinyHeatmapsHaveNoEmptyOrOverlappingLegendRanges() {
        var empty=new HeatmapScale(0);Assert.Empty(empty.Bands);Assert.Equal(0,empty.Level(1));
        var scale=new HeatmapScale(2);Assert.Equal(2,scale.Bands.Sum(b=>b.Maximum-b.Minimum+1));
        Assert.All(scale.Bands,b=>Assert.True(b.Minimum<=b.Maximum));Assert.Equal(5,scale.Level(2));
    }
    [Fact] public void SummaryUsesPhysicalCountsAndActiveMinutesRatherThanWords() {
        var store=Store();var at=DateTimeOffset.Parse("2026-11-10T12:00:00Z");
        store.Record(A,at);store.Record(Space,at.AddSeconds(20));store.Record(A,at.AddMinutes(3));
        var summary=store.Snapshot(at,at.AddMinutes(5),TimeZoneInfo.Utc);
        Assert.Equal(3,summary.Total);Assert.Equal(2,summary.ActiveMinutes);Assert.Equal(1.5,summary.AveragePerActiveMinute);
        Assert.Equal(2,summary.PeakMinuteCount);Assert.Equal(at,summary.PeakMinute);Assert.Equal(summary.Total,summary.Trend.Sum(b=>b.Count));
    }
    [Fact] public void CachedQueriesRefreshWithoutMutatingEarlierSnapshots() {
        var store=Store();var at=DateTimeOffset.Parse("2026-11-10T12:00:00Z");store.Record(A,at);
        var first=store.Snapshot(at,at.AddHours(1),TimeZoneInfo.Utc);store.Record(Space,at.AddSeconds(10));
        var next=store.Snapshot(at,at.AddHours(1),TimeZoneInfo.Utc);
        Assert.Equal(1,first.Total);Assert.Equal(2,next.Total);Assert.True(next.Revision>first.Revision);Assert.Equal(2,next.Trend.Sum(b=>b.Count));
    }
    [Fact] public void PreviousElapsedPeriodUsesTheSameNumberOfRoundedMinutesWithoutOverlap() {
        var store = Store();
        var start = DateTimeOffset.Parse("2026-11-12T12:00:00Z");
        store.Record(A, start.AddMinutes(-4));
        store.Record(A, start.AddMinutes(-3));
        store.Record(Space, start.AddMinutes(-3).AddSeconds(20));
        store.Record(A, start.AddMinutes(-1));
        store.Record(A, start);
        var previous = store.ComparePrevious(start.AddSeconds(20), start.AddMinutes(2).AddSeconds(10), zone: TimeZoneInfo.Utc);
        Assert.NotNull(previous);
        Assert.Equal(start.AddMinutes(-3), previous.From);
        Assert.Equal(start, previous.To);
        Assert.Equal(3, previous.Total);
        Assert.Equal(2, previous.ActiveMinutes);
        store.Record(A, start.AddMinutes(1));
        Assert.Same(previous, store.ComparePrevious(start.AddSeconds(20), start.AddMinutes(2).AddSeconds(10), zone: TimeZoneInfo.Utc));
        store.Record(Space, start.AddMinutes(-1));
        var updated = store.ComparePrevious(start.AddSeconds(20), start.AddMinutes(2).AddSeconds(10), zone: TimeZoneInfo.Utc);
        Assert.Equal(4, updated!.Total);
        Assert.Equal(2, updated.ActiveMinutes);
    }
    [Theory]
    [InlineData(1)]
    [InlineData(7)]
    [InlineData(30)]
    public void PreviousCalendarPeriodUsesTheSameLocalTimeAcrossClockChanges(int days) {
        var zone = TimeZoneInfo.FindSystemTimeZoneById("America/Los_Angeles");
        var store = Store();
        var now = DateTimeOffset.Parse("2026-03-08T12:12:50-07:00");
        var start = StatisticsStore.StartOfRecentDays(now, days, zone);
        var priorStart = DateTimeOffset.Parse("2026-03-08T00:00:00-08:00").AddDays(1 - 2 * days);
        var priorEnd = DateTimeOffset.Parse("2026-03-08T12:13:00-08:00").AddDays(-days);
        store.Record(A, priorStart);
        store.Record(A, priorEnd.AddMinutes(-1));
        store.Record(A, priorEnd);
        var previous = store.ComparePrevious(start, now, days, zone);
        Assert.NotNull(previous);
        Assert.Equal(priorStart, previous.From);
        Assert.Equal(priorEnd, previous.To);
        Assert.Equal(2, previous.Total);
        Assert.Equal(2, previous.ActiveMinutes);
    }
    [Fact] public void UnrecordedHistoryDiffersFromARecordedPeriodWithNoPresses() {
        var store = Store();
        var start = DateTimeOffset.Parse("2026-11-12T00:00:00Z");
        var end = start.AddHours(9);
        Assert.Null(store.ComparePrevious(start, end, 1, TimeZoneInfo.Utc));
        store.Record(A, start);
        Assert.Null(store.ComparePrevious(start, end, 1, TimeZoneInfo.Utc));
        store.Record(A, start.AddHours(-1));
        Assert.Null(store.ComparePrevious(start, end, 1, TimeZoneInfo.Utc));
        store.Record(A, start.AddDays(-1).AddMinutes(-1));
        var previous = store.ComparePrevious(start, end, 1, TimeZoneInfo.Utc);
        Assert.NotNull(previous);
        Assert.Equal(0, previous.Total);
        Assert.Equal(0, previous.ActiveMinutes);
    }
    [Theory]
    [InlineData("2026-03-08T01:59:30-08:00", "2026-03-07T02:00:00-08:00")]
    [InlineData("2026-11-01T01:59:30-07:00", "2026-10-31T02:00:00-07:00")]
    public void PreviousCalendarPeriodRoundsAfterShiftingWallTime(string nowText, string priorEndText) {
        var zone = TimeZoneInfo.FindSystemTimeZoneById("America/Los_Angeles");
        var now = DateTimeOffset.Parse(nowText);
        var priorEnd = DateTimeOffset.Parse(priorEndText);
        var store = Store();
        store.Record(A, StatisticsStore.StartOfRecentDays(now, 2, zone).AddMinutes(-1));
        store.Record(A, priorEnd.AddMinutes(-1));
        store.Record(A, priorEnd);
        var previous = store.ComparePrevious(StatisticsStore.StartOfRecentDays(now, 1, zone), now, 1, zone);
        Assert.NotNull(previous);
        Assert.Equal(priorEnd, previous.To);
        Assert.Equal(1, previous.Total);
    }
    [Fact] public void PeakTiesChooseEarlierMinuteRegardlessOfRecordingOrder() {
        var store=Store();var at=DateTimeOffset.Parse("2026-11-10T12:00:00Z");store.Record(A,at.AddMinutes(3));store.Record(A,at);
        Assert.Equal(at,store.Snapshot(at,at.AddHours(1),TimeZoneInfo.Utc).PeakMinute);
    }
    [Fact] public void PartialRangesRoundOutwardAndClipDisplayedCalendarBuckets() {
        var store=Store();var at=DateTimeOffset.Parse("2026-11-10T12:03:00Z");store.Record(A,at);store.Record(A,at.AddMinutes(7));
        var snapshot=store.Snapshot(at.AddSeconds(15),at.AddMinutes(7),TimeZoneInfo.Utc,StatisticsInterval.FiveMinutes);
        Assert.Equal(1,snapshot.Total);Assert.Equal(at,snapshot.Trend[0].Start);Assert.Equal(at.AddMinutes(7),snapshot.Trend[^1].End);
        Assert.Equal(snapshot.Total,snapshot.Trend.Sum(b=>b.Count));
    }
    [Fact] public void SpringClockChangeKeepsOneCalendarDayAtTwentyThreeHours() {
        var zone=TimeZoneInfo.FindSystemTimeZoneById("America/Los_Angeles");var store=Store();
        var from=new DateTimeOffset(2026,3,8,0,0,0,TimeSpan.FromHours(-8));var to=new DateTimeOffset(2026,3,9,0,0,0,TimeSpan.FromHours(-7));
        store.Record(A,from.AddHours(1));store.Record(A,to.AddHours(-1));var s=store.Snapshot(from,to,zone,StatisticsInterval.Day);
        Assert.Single(s.Trend);Assert.Equal(23,(s.Trend[0].End-s.Trend[0].Start).TotalHours);Assert.Equal(2,s.Trend[0].Count);
    }
    [Fact] public void RepeatedAutumnHourHasSeparateAbsoluteIntervals() {
        var zone=TimeZoneInfo.FindSystemTimeZoneById("America/Los_Angeles");var store=Store();
        var from=new DateTimeOffset(2026,11,1,0,0,0,TimeSpan.FromHours(-7));var to=from.AddHours(4);
        store.Record(A,from.AddHours(1));store.Record(Space,from.AddHours(2));var s=store.Snapshot(from,to,zone,StatisticsInterval.Hour);
        Assert.Equal(4,s.Trend.Count);Assert.Equal(2,s.Total);Assert.Equal(1,s.Trend[1].Count);Assert.Equal(1,s.Trend[2].Count);
        Assert.Equal(2,s.Trend.Select(b=>b.Start).Distinct().Count(b=>zone.IsAmbiguousTime(TimeZoneInfo.ConvertTime(b,zone).DateTime)));
    }
    [Fact] public void HugeSparseRangeRemainsBoundedAndKeepsFinalCount() {
        var store=Store();var from=DateTimeOffset.Parse("1800-01-01T00:00:00Z");var to=DateTimeOffset.Parse("2200-01-01T00:00:00Z");
        store.Record(A,from.AddMinutes(1));store.Record(Space,to.AddMinutes(-1));var s=store.Snapshot(from,to,TimeZoneInfo.Utc);
        Assert.InRange(s.Trend.Count,1,72);Assert.Equal(2,s.Trend.Sum(b=>b.Count));Assert.Equal(2,s.Total);
    }
    [Fact] public void InvalidRangeProducesAnEmptySummary() {
        var store=Store();var at=DateTimeOffset.UtcNow;var s=store.Snapshot(at,at,TimeZoneInfo.Utc);
        Assert.Equal(0,s.Total);Assert.Equal(0,s.AveragePerActiveMinute);Assert.Null(s.PeakMinute);Assert.Empty(s.Trend);
    }
    [Fact] public void BeforeEpochRecordsUseTheCorrectMinuteFloor() {
        var store=Store();var from=DateTimeOffset.Parse("1969-12-31T23:59:00Z");store.Record(A,from.AddSeconds(40));
        Assert.Equal(1,store.Snapshot(from,from.AddMinutes(1),TimeZoneInfo.Utc).Total);
    }
    [Fact] public async Task EmptySavedMinuteDoesNotCountAsActivity() {
        string path=Path.Combine(Path.GetTempPath(),Guid.NewGuid()+".json");
        await File.WriteAllTextAsync(path,"{\"Schema\":1,\"Minutes\":{\"0\":{\"30\":0}},\"Labels\":{\"30\":\"A\"}}");
        try {
            var store = new StatisticsStore(path);
            var now = DateTimeOffset.UnixEpoch.AddHours(1);
            var summary = store.Snapshot(DateTimeOffset.UnixEpoch, now, TimeZoneInfo.Utc);
            Assert.Equal(0, summary.ActiveMinutes);
            Assert.Null(summary.PeakMinute);
            Assert.Empty(summary.Counts);
            Assert.All(store.DailyActivity(now, 7, TimeZoneInfo.Utc), day => Assert.Equal(0, day.ActiveMinutes));
            Assert.All(store.HourlyActivity(new DateOnly(1970, 1, 1), now, TimeZoneInfo.Utc), hour => Assert.Equal(0, hour.Count));
        }
        finally {File.Delete(path);}
    }
    [Fact] public async Task DailyActivityUsesSavedMinuteBucketsAndLocalDates() {
        string path = Path.Combine(Path.GetTempPath(), Guid.NewGuid()+".json");
        var zone = TimeZoneInfo.CreateCustomTimeZone("Test UTC+8", TimeSpan.FromHours(8), "Test UTC+8", "Test UTC+8");
        var now = new DateTimeOffset(2026, 11, 12, 0, 5, 30, zone.BaseUtcOffset);
        var start = StatisticsStore.StartOfRecentDays(now, 30, zone);
        var today = StatisticsStore.StartOfRecentDays(now, 1, zone);
        var store = new StatisticsStore(path);
        store.Record(A, start.AddMinutes(-1));
        store.Record(A, start);
        store.Record(A, today.AddMinutes(-1));
        store.Record(A, today);
        store.Record(Space, today.AddSeconds(10));
        store.Record(A, today.AddMinutes(5));
        store.Record(A, today.AddMinutes(6));
        try {
            await store.FlushAsync();
            var restored = new StatisticsStore(path);
            var month = restored.DailyActivity(now, 30, zone);
            var week = restored.DailyActivity(now, 7, zone);
            Assert.Equal(30, month.Count);
            Assert.Equal(new DateOnly(2026, 10, 14), month[0].Day);
            Assert.Equal(new DateOnly(2026, 11, 12), month[^1].Day);
            Assert.Equal(1, month[0].ActiveMinutes);
            Assert.Equal(1, month[^2].ActiveMinutes);
            Assert.Equal(2, month[^1].ActiveMinutes);
            Assert.Equal(4, month.Sum(day => day.ActiveMinutes));
            Assert.Equal(month.Skip(23).ToArray(), week.ToArray());
        } finally { File.Delete(path); }
    }
    [Fact] public void HourlyActivityIncludesCurrentHourAndStopsAtNow() {
        var store = Store();
        var now = DateTimeOffset.Parse("2026-11-12T09:03:10Z");
        var at = DateTimeOffset.Parse("2026-11-12T09:00:00Z");
        var day = new DateOnly(2026, 11, 12);
        store.Record(A, at.AddMinutes(-1));
        store.Record(A, at);
        store.Record(Space, at.AddSeconds(20));
        store.Record(A, at.AddMinutes(3));
        store.Record(A, at.AddMinutes(4));
        var hours = store.HourlyActivity(day, now, TimeZoneInfo.Utc);
        Assert.Equal(10, hours.Count);
        Assert.Equal(3, hours.Sum(hour => hour.Count));
        Assert.Equal(2, hours[^1].Count);
        Assert.Equal(at, hours[^1].Start);
        var onHour = store.HourlyActivity(day, at, TimeZoneInfo.Utc);
        Assert.Equal(10, onHour.Count);
        Assert.Equal(0, onHour[^1].Count);
    }
    [Theory]
    [InlineData(3, 8, 23)]
    [InlineData(11, 1, 25)]
    public void HourlyActivityUsesActualHoursOnClockChangeDays(int month, int date, int hourCount) {
        var zone = TimeZoneInfo.FindSystemTimeZoneById("America/Los_Angeles");
        var store = Store();
        var day = new DateOnly(2026, month, date);
        var local = day.ToDateTime(TimeOnly.MinValue);
        var start = new DateTimeOffset(local, zone.GetUtcOffset(local));
        store.Record(A, start.AddHours(1));
        store.Record(Space, start.AddHours(2));
        var hours = store.HourlyActivity(day, start.AddDays(2), zone);
        Assert.Equal(hourCount, hours.Count);
        Assert.Equal(2, hours.Sum(hour => hour.Count));
        Assert.Equal(1, hours[1].Count);
        Assert.Equal(1, hours[2].Count);
        Assert.Equal(hourCount == 25 ? 1 : 3, hours[2].Start.Hour);
        Assert.NotEqual(hours[1].Start.Offset, hours[2].Start.Offset);
    }
    [Fact] public void HalfHourClockJumpRealignsToLocalHour() {
        var zone = TimeZoneInfo.FindSystemTimeZoneById("Australia/Lord_Howe");
        var day = new DateOnly(2026, 10, 4);
        var now = DateTimeOffset.Parse("2026-10-05T00:00:00+11:00");
        var hours = Store().HourlyActivity(day, now, zone);
        Assert.Equal(24, hours.Count);
        Assert.Equal(new TimeOnly(2, 30), TimeOnly.FromDateTime(hours[2].Start.DateTime));
        Assert.Equal(TimeSpan.FromMinutes(30), hours[2].End - hours[2].Start);
        Assert.Equal(new TimeOnly(3, 0), TimeOnly.FromDateTime(hours[3].Start.DateTime));
    }
    [Fact] public void SubMillisecondRangesStillIncludeTheirIntersectingMinute() {
        var store=Store();store.Record(A,DateTimeOffset.UnixEpoch);
        var from=DateTimeOffset.UnixEpoch.AddTicks(1);var to=from.AddTicks(1);
        Assert.Equal(1,store.Snapshot(from,to,TimeZoneInfo.Utc).Total);
        Assert.Equal(1,store.Counts(from,to).Sum(row=>row.Count));
    }

    [Fact] public void NegativeSubMillisecondRangesKeepThePreviousMinute() {
        var store=Store();var from=DateTimeOffset.UnixEpoch.AddTicks(-2);var to=DateTimeOffset.UnixEpoch.AddTicks(-1);
        store.Record(A,to);
        Assert.Equal(1,store.Snapshot(from,to,TimeZoneInfo.Utc).Total);
        Assert.Equal(1,store.Counts(from,to).Sum(row=>row.Count));
    }
    [Fact] public async Task UnsafeArchiveCountIsRejectedWithoutOverwritingIt() {
        string path=Path.Combine(Path.GetTempPath(),Guid.NewGuid()+".json");
        string original="{\"Schema\":1,\"Minutes\":{\"0\":{\"30\":9223372036854775807}},\"Labels\":{\"30\":\"A\"}}";
        await File.WriteAllTextAsync(path,original);
        try {
            var store=new StatisticsStore(path);Assert.NotNull(store.Error);
            store.Record(A,DateTimeOffset.UnixEpoch);await store.FlushAsync();
            Assert.Equal(original,await File.ReadAllTextAsync(path));
            Assert.Equal(1,store.Snapshot(DateTimeOffset.UnixEpoch,DateTimeOffset.UnixEpoch.AddMinutes(1),TimeZoneInfo.Utc).Total);
        } finally {File.Delete(path);}
    }

}
