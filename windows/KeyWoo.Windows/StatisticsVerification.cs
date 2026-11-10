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
        bool SearchPassed, bool EmptyStatePassed, bool TrendRenderingPassed, bool NativeCurveRenderingPassed, bool DarkModePassed);
    internal static Result Run(string report) {
        string directory=Path.Combine(Path.GetTempPath(),"KeyWoo-stats-"+Guid.NewGuid().ToString("N"));
        var store=new StatisticsStore(Path.Combine(directory,"statistics.json"));
        var at=DateTimeOffset.Now.AddMinutes(-20);
        var a=new PhysicalKey(0x41,0x1e);var space=new PhysicalKey(0x20,0x39);
        for(int index=0;index<120;index++)store.Record(a,at.AddMinutes(index%15));
        for(int index=0;index<900;index++)store.Record(space,at.AddMinutes(index%15));
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
        VerifyCurve(report);
        var empty=new StatisticsPanel(new StatisticsStore(Path.Combine(directory,"empty.json")),false,new(),message=>throw new InvalidDataException(message));
        Layout(empty);Require(Find<StackPanel>(empty,"statistics-ranking").Children.Count==1,"An empty range must show a clear empty state.");
        var resources=System.Windows.Application.Current.Resources;
        string[] names=["PageBrush","CardBrush","TextBrush","MutedBrush","LineBrush","AccentBrush"];
        object[] original=names.Select(name=>resources[name]).ToArray();
        try {
            string[] values=["#17191D","#24272D","#F0F2F5","#ADB5C3","#414650","#8BB5FF"];
            for(int index=0;index<names.Length;index++)resources[names[index]]=new SolidColorBrush((Color)ColorConverter.ConvertFromString(values[index]));
            var dark=new StatisticsPanel(store,true,new(){Period="hour"},message=>throw new InvalidDataException(message));
            Layout(dark);Save(dark,Path.ChangeExtension(report,".statistics-dark.png"));
            Require(Find<Button>(dark,"statistics-key-30").ToolTip is string darkTooltip&&darkTooltip.Contains("120"),"The Chinese dark interface must retain its count details.");
        } finally {for(int index=0;index<names.Length;index++)resources[names[index]]=original[index];}
        return new(true,true,true,true,true,true,true,true);
    }
    private static void VerifyCurve(string report) {
        var start=DateTimeOffset.Now;
        var counts=new long[]{0,3,8,2,0};
        var buckets=counts.Select((count,index)=>new StatisticsTrendBucket(start.AddMinutes(index*5),start.AddMinutes((index+1)*5),count)).ToArray();
        var curve=new StatisticsTrendView(false);
        curve.SetData(buckets);
        var active=RenderChart(curve);
        var zero=new StatisticsTrendView(false);
        zero.SetData(buckets.Select(bucket=>bucket with { Count=0 }).ToArray());
        var empty=RenderChart(zero);
        Require(active.ColoredPixels>100&&empty.ColoredPixels==0&&!active.Pixels.AsSpan().SequenceEqual(empty.Pixels),
            "A positive time series must paint a visible curve and area above the zero baseline.");
        StatisticsTrendBucket? selected=null;
        curve.Hovered+=bucket=>selected=bucket;
        curve.HoverAt(new Point(52+(680-62)*.3,50));
        var hovered=RenderChart(curve);
        Require(selected==buckets[1]&&!hovered.Pixels.AsSpan().SequenceEqual(active.Pixels),
            "Hover must select the exact interval and visibly paint its dot and crosshair.");
        var sparse=new StatisticsTrendView(false);
        sparse.SetData([new(start,start.AddMinutes(1),1)]);
        Require(RenderChart(sparse).ColoredPixels>4,"A single interval must remain visible as a point.");
        var scale=StatisticsTrendView.AxisScale(500);
        Require(scale.Step==200&&scale.Maximum==600,"Count axes must use whole 1/2/5 steps.");
        SaveChart(active.Bitmap,Path.ChangeExtension(report,".statistics-curve.png"));
        SaveChart(hovered.Bitmap,Path.ChangeExtension(report,".statistics-curve-hover.png"));
    }
    private sealed record CurveFrame(RenderTargetBitmap Bitmap,byte[] Pixels,int ColoredPixels);
    private static CurveFrame RenderChart(StatisticsTrendView view) {
        view.Width=680;view.Height=208;
        view.Measure(new Size(680,208));view.Arrange(new Rect(0,0,680,208));view.UpdateLayout();
        var bitmap=new RenderTargetBitmap(680,208,96,96,PixelFormats.Pbgra32);
        bitmap.Render(view);
        var bytes=new byte[680*208*4];bitmap.CopyPixels(bytes,680*4,0);
        int colored=0;
        for(int y=12;y<176;y++)for(int x=60;x<665;x++) {
            int index=(y*680+x)*4;
            if(bytes[index+3]>0&&bytes[index]>=12&&bytes[index]>bytes[index+1]*1.1&&bytes[index]>bytes[index+2]*1.25)colored++;
        }
        return new(bitmap,bytes,colored);
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
