using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using KeyWoo.Core;

namespace KeyWoo.Windows;

/// <summary>Exercise the shipped statistics controls and paint using isolated synthetic minute aggregates.</summary>
internal static class StatisticsVerification {
    internal sealed record Result(bool Passed, bool HeatmapTooltipPassed, bool PinnedSelectionPassed,
        bool SearchPassed, bool EmptyStatePassed, bool TrendRenderingPassed, bool NativeCurveRenderingPassed, bool DarkModePassed,
        bool MonthlyRangePassed, bool ActiveMinuteChartsPassed, bool HistoryComparisonPassed);
    internal static Result Run(string report) {
        string directory=Path.Combine(Path.GetTempPath(),"KeyWoo-stats-"+Guid.NewGuid().ToString("N"));
        var store=new StatisticsStore(Path.Combine(directory,"statistics.json"));
        var at=DateTimeOffset.Now.AddMinutes(-20);
        var a=new PhysicalKey(0x41,0x1e);var space=new PhysicalKey(0x20,0x39);
        for(int index=0;index<120;index++)store.Record(a,at.AddMinutes(index%15));
        for(int index=0;index<900;index++)store.Record(space,at.AddMinutes(index%15));
        for (int index = 0; index < 500; index++) store.Record(a, at.AddMinutes(-60 + index % 5));
        var oldTime = new DateTimeOffset(DateTime.Today.AddDays(-24).AddHours(12));
        for (int index = 0; index < 5; index++) store.Record(a, oldTime.AddMinutes(index % 3));
        var state=new StatisticsPresentation{Period="hour"};
        var panel=new StatisticsPanel(store,false,state,message=>throw new InvalidDataException(message));
        Layout(panel);
        var key=Find<Button>(panel,"statistics-key-30");
        Require(key.ToolTip is string tooltip&&tooltip.Contains("120")&&tooltip.Contains("%"),"Every physical key must expose its exact count and share.");
        key.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Require(state.SelectedKey==a.Id&&Find<TextBlock>(panel,"statistics-key-detail").Text.Contains("120"),"Clicking the whole key must pin its details.");
        var search=Find<TextBox>(panel,"statistics-key-search");search.Text="Space";
        var ranking=Find<StackPanel>(panel,"statistics-ranking");
        Require(ranking.Children.Count==1&&Find<Button>(ranking,"statistics-rank-57").ToolTip is string detail&&detail.Contains("900"),"Search must filter the actual ranked key rows.");
        search.Text="";Layout(panel);Save(panel,Path.ChangeExtension(report,".statistics-light.png"));
        var chart=Find<StatisticsTrendView>(panel,"statistics-activity");
        Require(chart.ActualWidth>300&&chart.ActualHeight>100,"The trend must occupy the available chart width.");
        Require(Find<TextBlock>(panel, "statistics-total-change").Text == "+" + 1.04.ToString("P1", CultureInfo.CurrentCulture) &&
            Find<TextBlock>(panel, "statistics-active-change").Text == "+" + 2d.ToString("P1", CultureInfo.CurrentCulture) &&
            Find<TextBlock>(panel, "statistics-comparison-period").Text.StartsWith("Compared with ", StringComparison.Ordinal),
            "The overview must compare both the selected press count and active minutes to the previous period.");
        VerifyCurve(report);
        Find<Button>(panel, "statistics-period-month").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Require(state.Period == "month" && key.ToolTip is string monthCount && monthCount.Contains("625"),
            "The monthly range must include press counts older than one week.");
        Require(Find<TextBlock>(panel, "statistics-comparison-period").Text == "Not enough recorded history to compare",
            "Missing earlier history must display as unavailable rather than zero.");
        VerifyActiveMinutes(panel, state, store, oldTime, report);
        var empty=new StatisticsPanel(new StatisticsStore(Path.Combine(directory,"empty.json")),false,new(),message=>throw new InvalidDataException(message));
        Layout(empty);Require(Find<StackPanel>(empty,"statistics-ranking").Children.Count==1,"An empty range must show a clear empty state.");
        var resources=System.Windows.Application.Current.Resources;
        string[] names=["PageBrush","CardBrush","TextBrush","MutedBrush","LineBrush","AccentBrush"];
        object[] original=names.Select(name=>resources[name]).ToArray();
        try {
            string[] values=["#181615","#292523","#F5EFE8","#B8ACA4","#453C37","#FCA58C"];
            for(int index=0;index<names.Length;index++)resources[names[index]]=new SolidColorBrush((Color)ColorConverter.ConvertFromString(values[index]));
            var dark=new StatisticsPanel(store,true,new(){Period="hour"},message=>throw new InvalidDataException(message));
            Layout(dark);Save(dark,Path.ChangeExtension(report,".statistics-dark.png"));
            Require(Find<Button>(dark,"statistics-key-30").ToolTip is string darkTooltip&&darkTooltip.Contains("120"),"The Chinese dark interface must retain its count details.");
            var darkFrame=RenderChart(Find<StatisticsTrendView>(dark,"statistics-activity"));
            Require(darkFrame.StrokeColumns>=12,$"The activity curve must remain visible with the dark theme accent. {darkFrame.Description}");
        } finally {for(int index=0;index<names.Length;index++)resources[names[index]]=original[index];}
        return new(true,true,true,true,true,true,true,true,true,true,true);
    }
    private static void VerifyActiveMinutes(StatisticsPanel panel, StatisticsPresentation state, StatisticsStore store,
        DateTimeOffset oldTime, string report) {
        var date = Find<ComboBox>(panel, "statistics-active-date");
        Require(date.Items.Count == 7 && date.SelectedIndex == 0, "Hourly activity must default to today in the 7-day view.");
        Find<Button>(panel, "statistics-active-30-days").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Require(date.Items.Count == 30 && state.Period == "month", "The activity window must change independently of the press-count range.");
        Layout(panel);
        var daily = Find<StatisticsTrendView>(panel, "statistics-daily-active-minutes");
        var selected = DateOnly.FromDateTime(oldTime.LocalDateTime);
        int daysAgo = DateOnly.FromDateTime(DateTime.Today).DayNumber - selected.DayNumber;
        daily.SelectAt(new Point(52 + (daily.ActualWidth - 62) * ((29.5 - daysAgo) / 30), 50));
        Require(state.ActivityDay == selected && date.SelectedIndex == daysAgo, "Clicking a daily point must select its date in the hourly view.");
        var dailyText = Find<TextBlock>(panel, "statistics-daily-active-detail");
        Require(dailyText.Text.Contains("3 min"), "Daily hover must report distinct recorded minutes.");
        var hourly = Find<StatisticsTrendView>(panel, "statistics-hourly-active-minutes");
        var hours = store.HourlyActivity(selected, DateTimeOffset.Now);
        var active = hours.Single(hour => hour.Count > 0);
        var midpoint = active.Start + (active.End - active.Start) / 2;
        double fraction = (midpoint - hours[0].Start).TotalSeconds / (hours[^1].End - hours[0].Start).TotalSeconds;
        hourly.HoverAt(new Point(52 + (hourly.ActualWidth - 62) * fraction, 50));
        Require(Find<TextBlock>(panel, "statistics-hourly-active-detail").Text.Contains("3 min"),
            "Hourly hover must report the selected day's active minutes for the hovered hour.");
        daily.HoverAt(new Point(-1, 0));
        hourly.HoverAt(new Point(-1, 0));
        Layout(panel);
        var dailyFrame = RenderChart(daily);
        var hourlyFrame = RenderChart(hourly);
        SaveChart(dailyFrame.Bitmap, Path.ChangeExtension(report, ".statistics-active-daily.png"));
        SaveChart(hourlyFrame.Bitmap, Path.ChangeExtension(report, ".statistics-active-hourly.png"));
        Require(dailyFrame.StrokeColumns>=12&&hourlyFrame.StrokeColumns>=12,
            $"Both activity curves must draw an accent stroke above the zero baseline. Daily: {dailyFrame.Description}. Hourly: {hourlyFrame.Description}.");
        Find<Button>(panel, "statistics-active-7-days").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Require(date.Items.Count == 7 && date.SelectedIndex == 0 && state.ActivityDay is null,
            "An older selected date must return to today when it falls outside the 7-day view.");
    }
    private static void VerifyCurve(string report) {
        var start=DateTimeOffset.Now;
        var counts=new long[]{0,3,8,2,0};
        var buckets=counts.Select((count,index)=>new StatisticsTrendBucket(start.AddMinutes(index*5),start.AddMinutes((index+1)*5),count)).ToArray();
        var curve=new StatisticsTrendView(false);
        curve.SetData(buckets);
        var active=RenderStandaloneChart(curve);
        var zero=new StatisticsTrendView(false);
        zero.SetData(buckets.Select(bucket=>bucket with { Count=0 }).ToArray());
        var empty=RenderStandaloneChart(zero);
        Require(active.ColoredPixels>100&&empty.ColoredPixels==0&&!active.Pixels.AsSpan().SequenceEqual(empty.Pixels),
            "A positive time series must paint a visible curve and area above the zero baseline.");
        StatisticsTrendBucket? selected=null;
        curve.Hovered+=bucket=>selected=bucket;
        curve.HoverAt(new Point(52+(680-62)*.3,50));
        var hovered=RenderStandaloneChart(curve);
        Require(selected==buckets[1]&&!hovered.Pixels.AsSpan().SequenceEqual(active.Pixels),
            "Hover must select the exact interval and visibly paint its dot and crosshair.");
        var sparse=new StatisticsTrendView(false);
        sparse.SetData([new(start,start.AddMinutes(1),1)]);
        Require(RenderStandaloneChart(sparse).ColoredPixels>4,"A single interval must remain visible as a point.");
        var scale=StatisticsTrendView.AxisScale(500);
        Require(scale.Step==200&&scale.Maximum==600,"Count axes must use whole 1/2/5 steps.");
        SaveChart(active.Bitmap,Path.ChangeExtension(report,".statistics-curve.png"));
        SaveChart(hovered.Bitmap,Path.ChangeExtension(report,".statistics-curve-hover.png"));
    }
    private sealed record CurveFrame(RenderTargetBitmap Bitmap,byte[] Pixels,int ColoredPixels,int StrokeColumns) {
        internal string Description => $"{Bitmap.PixelWidth}×{Bitmap.PixelHeight}, {ColoredPixels} stroke pixels across {StrokeColumns} columns";
    }
    private static CurveFrame RenderStandaloneChart(StatisticsTrendView view) {
        view.Measure(new Size(680,208));view.Arrange(new Rect(0,0,680,208));
        return RenderChart(view);
    }
    private static CurveFrame RenderChart(StatisticsTrendView view) {
        view.UpdateLayout();
        int width=(int)Math.Ceiling(view.ActualWidth),height=(int)Math.Ceiling(view.ActualHeight);
        Require(width>100&&height>80,$"The chart must receive a usable layout. Actual: {width}×{height}.");
        int stride=width*4;
        var bitmap=new RenderTargetBitmap(width,height,96,96,PixelFormats.Pbgra32);
        bitmap.Render(view);
        var bytes=new byte[stride*height];bitmap.CopyPixels(bytes,stride,0);
        var accent=((SolidColorBrush)System.Windows.Application.Current.Resources["AccentBrush"]).Color;
        var occupiedColumns=new bool[width];
        int colored=0;
        // Ignore the numeric labels and the zero baseline, where a flat curve can otherwise satisfy the check.
        for(int y=8;y<height-33;y++)for(int x=53;x<width-9;x++) {
            int index=y*stride+x*4;
            int alpha=bytes[index+3];
            // Compare the visible stroke against the theme's premultiplied BGRA color.
            if(alpha>=96&&Math.Abs(bytes[index]*255-accent.B*alpha)<=1020&&
                Math.Abs(bytes[index+1]*255-accent.G*alpha)<=1020&&Math.Abs(bytes[index+2]*255-accent.R*alpha)<=1020) {
                colored++;
                occupiedColumns[x]=true;
            }
        }
        return new(bitmap,bytes,colored,occupiedColumns.Count(column=>column));
    }
    private static void SaveChart(BitmapSource bitmap,string file) {
        var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(bitmap));using var stream=File.Create(file);png.Save(stream);
    }
    private static void Layout(FrameworkElement view) {view.Measure(new Size(880,double.PositiveInfinity));view.Arrange(new Rect(0,0,880,view.DesiredSize.Height));view.UpdateLayout();}
    private static T Find<T>(DependencyObject root,string id) where T:DependencyObject {
        if(root is T match&&AutomationProperties.GetAutomationId(root)==id)return match;
        foreach(object child in LogicalTreeHelper.GetChildren(root))if(child is DependencyObject element) {
            var found=TryFind<T>(element,id);if(found is not null)return found;
        }
        throw new InvalidDataException("Missing statistics control "+id);
    }
    private static T? TryFind<T>(DependencyObject root,string id) where T:DependencyObject {
        if(root is T match&&AutomationProperties.GetAutomationId(root)==id)return match;
        foreach(object child in LogicalTreeHelper.GetChildren(root))if(child is DependencyObject element) {
            var found=TryFind<T>(element,id);if(found is not null)return found;
        }
        return null;
    }
    private static void Save(FrameworkElement view,string file) {
        var bitmap=new RenderTargetBitmap(880,Math.Min(1600,(int)Math.Ceiling(view.ActualHeight)),96,96,PixelFormats.Pbgra32);
        bitmap.Render(view);var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(bitmap));using var stream=File.Create(file);png.Save(stream);
    }
    private static void Require(bool condition,string message){if(!condition)throw new InvalidDataException(message);}
}
