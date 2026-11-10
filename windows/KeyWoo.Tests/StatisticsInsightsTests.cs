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
        try {var s=new StatisticsStore(path).Snapshot(DateTimeOffset.UnixEpoch,DateTimeOffset.UnixEpoch.AddHours(1),TimeZoneInfo.Utc);Assert.Equal(0,s.ActiveMinutes);Assert.Null(s.PeakMinute);Assert.Empty(s.Counts);}
        finally {File.Delete(path);}
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
