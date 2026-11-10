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
        bool SearchPassed, bool EmptyStatePassed, bool TrendRenderingPassed, bool DarkModePassed);
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
        return new(true,true,true,true,true,true,true);
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
