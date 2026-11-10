using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using KeyWoo.Core;
using Microsoft.Win32;

namespace KeyWoo.Windows;

internal sealed class StatisticsPresentation {
    internal string Period = "today";
    internal DateTime From = DateTime.Today;
    internal DateTime To = DateTime.Today.AddDays(1);
    internal string Search = "";
    internal bool ShowUnused;
    internal int? SelectedKey;
}

/// <summary>The statistics screen reads minute aggregates only and refreshes at most once per second.</summary>
internal sealed class StatisticsPanel : StackPanel {
    private readonly StatisticsStore store;
    private readonly bool chinese;
    private readonly StatisticsPresentation state;
    private readonly Action<string> showError;
    private readonly StackPanel content = new();
    private readonly WrapPanel ranges = new();
    private readonly WrapPanel custom = new();
    private readonly TextBlock rangeCaption = new(), inspector = new(), trendInspector = new();
    private readonly UniformGrid metrics = new();
    private readonly Grid keyboard = new();
    private readonly WrapPanel legend = new();
    private readonly StackPanel ranking = new();
    private readonly StatisticsTrendView trend;
    private readonly Dictionary<int,Button> keyButtons = [];
    private readonly Dictionary<string,Button> periodButtons = [];
    private readonly DatePicker fromDate, toDate;
    private readonly TextBox fromTime, toTime;
    private readonly TextBox search;
    private readonly CheckBox unused;
    private StatisticsSnapshot? snapshot;
    private DateTimeOffset refreshed = DateTimeOffset.MinValue;
    private int? hoveredKey;
    private bool building;
    private readonly record struct KeyboardKey(int Id, string Label, double Width = 1);
    private static readonly KeyboardKey[][] Rows = [
        [new(0x29,"`"),new(0x02,"1"),new(0x03,"2"),new(0x04,"3"),new(0x05,"4"),new(0x06,"5"),new(0x07,"6"),new(0x08,"7"),new(0x09,"8"),new(0x0a,"9"),new(0x0b,"0"),new(0x0c,"−"),new(0x0d,"="),new(0x0e,"⌫",1.8)],
        [new(0x0f,"Tab",1.4),new(0x10,"Q"),new(0x11,"W"),new(0x12,"E"),new(0x13,"R"),new(0x14,"T"),new(0x15,"Y"),new(0x16,"U"),new(0x17,"I"),new(0x18,"O"),new(0x19,"P"),new(0x1a,"["),new(0x1b,"]"),new(0x2b,"\\",1.4)],
        [new(0x3a,"Caps",1.7),new(0x1e,"A"),new(0x1f,"S"),new(0x20,"D"),new(0x21,"F"),new(0x22,"G"),new(0x23,"H"),new(0x24,"J"),new(0x25,"K"),new(0x26,"L"),new(0x27,";"),new(0x28,"'"),new(0x1c,"Enter",2.1)],
        [new(0x2a,"Shift",2.2),new(0x2c,"Z"),new(0x2d,"X"),new(0x2e,"C"),new(0x2f,"V"),new(0x30,"B"),new(0x31,"N"),new(0x32,"M"),new(0x33,","),new(0x34,"."),new(0x35,"/"),new(0x36,"Shift",2.6)],
        [new(0x1d,"Ctrl",1.3),new(0x15b,"Win",1.3),new(0x38,"Alt",1.3),new(0x39,"Space",6.3),new(0x138,"Alt",1.3),new(0x15c,"Win",1.3),new(0x15d,"Menu",1.3),new(0x11d,"Ctrl",1.3)]
    ];

    internal StatisticsPanel(StatisticsStore store, bool chinese, StatisticsPresentation state, Action<string> showError) {
        this.store = store; this.chinese = chinese; this.state = state; this.showError = showError;
        building = true;
        Margin = new(0,0,8,0);
        Background=Brush("PageBrush");
        AutomationProperties.SetAutomationId(this,"statistics-panel");
        var top = new DockPanel { Margin = new(0,0,0,10) };
        var export = Button(T("导出 CSV","Export CSV"), Export);
        DockPanel.SetDock(export,Dock.Right); top.Children.Add(export);
        foreach (var (id,zh,en) in new[] {("today","今天","Today"),("hour","近一小时","Past hour"),("week","近七天","Past week"),("custom","自定义","Custom")}) {
            string selection = id;
            var button = Button(T(zh,en),()=>{state.Period=selection;RefreshIfNeeded(true);});
            periodButtons[id] = button; ranges.Children.Add(button);
        }
        top.Children.Add(ranges); Children.Add(top);
        fromDate = new() { SelectedDate = state.From.Date, Width = 138 };
        toDate = new() { SelectedDate = state.To.Date, Width = 138 };
        fromTime = TimeBox(state.From); toTime = TimeBox(state.To);
        foreach (UIElement control in new UIElement[] { Text(T("从","From"),12,true),fromDate,fromTime,Text(T("至","To"),12,true),toDate,toTime,Button(T("更新","Apply"),ApplyCustom) }) {
            if (control is FrameworkElement element) element.Margin = new(0,0,8,0);
            custom.Children.Add(control);
        }
        custom.Margin = new(0,0,0,10); Children.Add(custom);
        rangeCaption.Foreground = Brush("MutedBrush"); rangeCaption.FontSize = 12;
        rangeCaption.Margin = new(0,0,0,16); Children.Add(rangeCaption);
        Children.Add(content);
        metrics.Columns = 4; content.Children.Add(Card(metrics));

        var heat = new StackPanel();
        heat.Children.Add(Heading(T("按键分布","Keyboard heatmap"),T("悬停查看次数，点击固定选择","Hover for details · Click to pin")));
        for (int index = 0; index < Rows.Length; index++) {
            keyboard.RowDefinitions.Add(new() { Height = GridLength.Auto });
            var row = new Grid(); Grid.SetRow(row,index);
            for (int column = 0; column < Rows[index].Length; column++) {
                var key = Rows[index][column]; row.ColumnDefinitions.Add(new() { Width = new(key.Width,GridUnitType.Star) });
                var cap = Button(key.Label,()=>{state.SelectedKey=key.Id;RefreshHeatmap();RefreshRanking();});
                cap.Padding = new(0); cap.Margin = new(2); cap.MinWidth = 0; cap.Height = 40;
                cap.FontSize = key.Label.Length > 3 ? 10 : 12; cap.HorizontalContentAlignment = HorizontalAlignment.Center;
                AutomationProperties.SetAutomationId(cap,"statistics-key-"+key.Id);
                ToolTipService.SetInitialShowDelay(cap,80); ToolTipService.SetShowDuration(cap,30000);
                cap.MouseEnter += (_,_)=>{hoveredKey=key.Id;UpdateInspector();};
                cap.MouseLeave += (_,_)=>{hoveredKey=null;UpdateInspector();};
                cap.GotKeyboardFocus += (_,_)=>{hoveredKey=key.Id;UpdateInspector();};
                cap.LostKeyboardFocus += (_,_)=>{hoveredKey=null;UpdateInspector();};
                keyButtons[key.Id]=cap; Grid.SetColumn(cap,column); row.Children.Add(cap);
            }
            keyboard.Children.Add(row);
        }
        heat.Children.Add(keyboard);
        inspector.Margin = new(2,12,0,12); inspector.FontSize=13; inspector.Foreground=Brush("TextBrush");
        AutomationProperties.SetAutomationId(inspector,"statistics-key-detail"); heat.Children.Add(inspector);
        heat.Children.Add(legend); content.Children.Add(Card(heat));

        var activity = new StackPanel();
        activity.Children.Add(Heading(T("打字趋势","Typing activity"),T("按所选时间分段累计","Totals within each time interval")));
        trend = new StatisticsTrendView(chinese) { Height = 208, Margin = new(0,8,0,0) };
        trend.Hovered += bucket => {
            trendInspector.Text = bucket is null ? TrendDescription() :
                $"{IntervalLabel(bucket.Start,bucket.End)}   ·   {Number(bucket.Count)} {T("次","presses")}";
        };
        AutomationProperties.SetAutomationId(trend,"statistics-activity");
        activity.Children.Add(trend);
        trendInspector.Foreground=Brush("MutedBrush"); trendInspector.FontSize=12; trendInspector.Margin=new(0,4,0,0);trendInspector.TextWrapping=TextWrapping.Wrap;
        activity.Children.Add(trendInspector); content.Children.Add(Card(activity));

        var details = new StackPanel();
        details.Children.Add(Heading(T("按键次数","Key counts"),T("按次数排序，点击与键盘联动","Sorted by count · Click to select")));
        var filters = new DockPanel { Margin = new(0,10,0,12) };
        unused = new() { Content=T("显示未使用的键","Include unused keys"), IsChecked=state.ShowUnused, VerticalAlignment=VerticalAlignment.Center };
        AutomationProperties.SetAutomationId(unused,"statistics-include-unused");
        DockPanel.SetDock(unused,Dock.Right); filters.Children.Add(unused);
        search = new() { Text=state.Search, MinWidth=150, MaxWidth=260, HorizontalAlignment=HorizontalAlignment.Left, Padding=new(9,6,9,6), ToolTip=T("按键名称，例如 Space、Shift、A","Find a key, such as Space, Shift or A") };
        AutomationProperties.SetName(search,T("搜索按键","Search keys")); AutomationProperties.SetAutomationId(search,"statistics-key-search");
        var searchField=new Grid {MaxWidth=260,HorizontalAlignment=HorizontalAlignment.Left};
        var searchHint=Text(T("搜索按键","Search keys"),12,true);searchHint.Margin=new(10,0,0,0);searchHint.IsHitTestVisible=false;
        searchField.Children.Add(search);searchField.Children.Add(searchHint);
        searchHint.Visibility=string.IsNullOrEmpty(search.Text)?Visibility.Visible:Visibility.Collapsed;
        search.TextChanged+=(_,_)=>searchHint.Visibility=string.IsNullOrEmpty(search.Text)?Visibility.Visible:Visibility.Collapsed;
        filters.Children.Add(searchField); details.Children.Add(filters); details.Children.Add(ranking); content.Children.Add(Card(details));
        AutomationProperties.SetAutomationId(ranking,"statistics-ranking");
        search.TextChanged += (_,_)=>{state.Search=search.Text;RefreshRanking();};
        unused.Checked += (_,_)=>{state.ShowUnused=true;RefreshRanking();};
        unused.Unchecked += (_,_)=>{state.ShowUnused=false;RefreshRanking();};
        building = false; RefreshIfNeeded(true);
    }

    internal void RefreshIfNeeded(bool force = false) {
        if (building) return;
        var now = DateTimeOffset.Now;
        if (!force && (now-refreshed).TotalSeconds < 1) return;
        refreshed = now;
        var (from,to,interval) = Range(now);
        if (!force && snapshot is not null && snapshot.Revision==store.Revision &&
            snapshot.From.ToUnixTimeSeconds()==(long)Math.Floor(from.ToUnixTimeMilliseconds()/60000d)*60 &&
            snapshot.To.ToUnixTimeSeconds()==(long)Math.Ceiling(to.ToUnixTimeMilliseconds()/60000d)*60) return;
        custom.Visibility = state.Period == "custom" ? Visibility.Visible : Visibility.Collapsed;
        foreach (var (id,button) in periodButtons) button.BorderBrush=Brush(id==state.Period?"AccentBrush":"LineBrush");
        if (to<=from) {
            rangeCaption.Text=T("结束时间需要晚于开始时间。","Choose an end after the start.");
            content.Visibility=Visibility.Collapsed; snapshot=null; return;
        }
        content.Visibility=Visibility.Visible;
        snapshot=store.Snapshot(from,to,TimeZoneInfo.Local,interval);
        rangeCaption.Text=$"{IntervalLabel(snapshot.From,snapshot.To)}   ·   {T("本机时间 · 分钟精度","Local time · Minute precision")}";
        RefreshMetrics(); RefreshHeatmap(); RefreshRanking();
        trend.SetData(snapshot.Trend);
        trendInspector.Text=TrendDescription();
    }

    private (DateTimeOffset From,DateTimeOffset To,StatisticsInterval Interval) Range(DateTimeOffset now) => state.Period switch {
        "hour" => (now.AddHours(-1),now,StatisticsInterval.FiveMinutes),
        "week" => (new DateTimeOffset(DateTime.Today.AddDays(-6)),now,StatisticsInterval.Day),
        "custom" => (new DateTimeOffset(state.From),new DateTimeOffset(state.To),StatisticsInterval.Auto),
        _ => (new DateTimeOffset(DateTime.Today),now,StatisticsInterval.Hour)
    };
    private void ApplyCustom() {
        if (!TimeSpan.TryParse(fromTime.Text,CultureInfo.InvariantCulture,out var a) ||
            !TimeSpan.TryParse(toTime.Text,CultureInfo.InvariantCulture,out var b) || a<TimeSpan.Zero || b<TimeSpan.Zero || a>=TimeSpan.FromDays(1) || b>=TimeSpan.FromDays(1)) {
            showError(T("请输入有效时间，例如 09:30。","Enter a valid time, such as 09:30.")); return;
        }
        DateTime from=(fromDate.SelectedDate??DateTime.Today).Date+a, to=(toDate.SelectedDate??DateTime.Today).Date+b;
        if (TimeZoneInfo.Local.IsInvalidTime(from)||TimeZoneInfo.Local.IsInvalidTime(to)) {
            showError(T("所选时间处于夏令时跳转，请选择其他时间。","This local time was skipped by daylight saving. Choose another time.")); return;
        }
        state.From=from;state.To=to;RefreshIfNeeded(true);
    }
    private void RefreshMetrics() {
        metrics.Children.Clear(); if(snapshot is null)return;
        AddMetric(T("总敲击","Total presses"),Number(snapshot.Total),T($"使用了 {snapshot.Counts.Count:N0} 个键",$"{snapshot.Counts.Count:N0} keys used"));
        AddMetric(T("活跃分钟","Active minutes"),Number(snapshot.ActiveMinutes),T("该分钟有按键即计入","Minutes with at least one press"));
        AddMetric(T("平均每分钟","Average per active minute"),snapshot.AveragePerActiveMinute.ToString("N1",CultureInfo.CurrentCulture),T("仅按活跃分钟计算","Calculated over active minutes"));
        AddMetric(T("最高每分钟","Peak minute"),Number(snapshot.PeakMinuteCount),snapshot.PeakMinute is DateTimeOffset at?Local(at).ToString(Local(at).Year==DateTime.Now.Year?"M/d HH:mm":"yyyy/M/d HH:mm"):T("尚无记录","No activity yet"));
    }
    private void AddMetric(string label,string value,string note) {
        var body=new StackPanel{Margin=new(0,0,12,0)};
        body.Children.Add(Text(label,12,true)); var number=Text(value,27);number.FontWeight=FontWeights.SemiBold;number.Margin=new(0,8,0,6);body.Children.Add(number);
        var explanation=Text(note,11,true);explanation.ToolTip=note;body.Children.Add(explanation);metrics.Children.Add(body);
    }
    private void RefreshHeatmap() {
        if(snapshot is null)return;
        var scale=new HeatmapScale(snapshot.Counts.FirstOrDefault()?.Count??0);
        foreach(var (id,button) in keyButtons) {
            long count=Count(id);int level=scale.Level(count);
            button.Background=HeatBrush(level);
            button.Foreground=level>=(IsDark?4:5)?new SolidColorBrush(IsDark?Color.FromRgb(20,30,50):Colors.White):Brush("TextBrush");
            button.BorderBrush=Brush(state.SelectedKey==id?"AccentBrush":"LineBrush");
            button.BorderThickness=new(state.SelectedKey==id?2:1);
            string detail=Detail(id);
            button.ToolTip=detail;AutomationProperties.SetName(button,detail);
        }
        legend.Children.Clear();
        var zero=Text(T("0 次","0 presses"),11,true);zero.Margin=new(0,2,12,2);legend.Children.Add(zero);
        foreach(var band in scale.Bands) {
            var item=new StackPanel{Orientation=Orientation.Horizontal,Margin=new(0,2,14,2)};
            item.Children.Add(new Border{Background=HeatBrush(band.Level),Width=12,Height=10,CornerRadius=new(3),Margin=new(0,0,5,0),VerticalAlignment=VerticalAlignment.Center});
            item.Children.Add(Text(band.Minimum==band.Maximum?Number(band.Minimum):$"{Number(band.Minimum)}–{Number(band.Maximum)}",11,true));
            legend.Children.Add(item);
        }
        UpdateInspector();
    }
    private void UpdateInspector() {
        int? id=hoveredKey??state.SelectedKey;
        inspector.Text=id is int key?Detail(key)+(hoveredKey is null?T("  ·  已固定","  ·  Pinned"):""):
            T("将鼠标移到按键上，查看次数与占比。","Point to a key to see its count and share.");
    }
    private string Detail(int id) {
        long count=Count(id); double share=snapshot?.Total>0?(double)count/snapshot.Total:0;
        string label=KeyLabel(id);
        return $"{label}   ·   {Number(count)} {T("次","presses")}   ·   {share:P1}";
    }
    private long Count(int id)=>snapshot?.Counts.FirstOrDefault(row=>row.Key==id)?.Count??0;
    private string KeyLabel(int id)=>snapshot?.Counts.FirstOrDefault(row=>row.Key==id)?.Label??Rows.SelectMany(row=>row).FirstOrDefault(key=>key.Id==id).Label??$"Scan {id:X}";
    private void RefreshRanking() {
        ranking.Children.Clear();if(snapshot is null)return;
        var values=snapshot.Counts.ToDictionary(row=>row.Key);
        if(state.ShowUnused)foreach(var key in Rows.SelectMany(row=>row))values.TryAdd(key.Id,new(key.Id,key.Label,0));
        var rows=values.Values.Where(row=>string.IsNullOrWhiteSpace(state.Search)||row.Label.Contains(state.Search,StringComparison.CurrentCultureIgnoreCase)||KeyLabel(row.Key).Contains(state.Search,StringComparison.CurrentCultureIgnoreCase))
            .OrderByDescending(row=>row.Count).ThenBy(row=>row.Key).ToArray();
        if(rows.Length==0) {ranking.Children.Add(Text(snapshot.Total==0?T("这段时间还没有记录。","No activity in this period yet."):T("没有匹配的按键。","No matching keys."),13,true));return;}
        long maximum=Math.Max(1,snapshot.Counts.FirstOrDefault()?.Count??0);
        var scale=new HeatmapScale(maximum);
        int rank=0;
        foreach(var row in rows) {
            rank++;
            var line=new Grid();line.ColumnDefinitions.Add(new(){Width=new(28)});line.ColumnDefinitions.Add(new(){Width=new(100)});line.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});line.ColumnDefinitions.Add(new(){Width=new(90)});line.ColumnDefinitions.Add(new(){Width=new(64)});
            void Cell(UIElement element,int column){Grid.SetColumn(element,column);line.Children.Add(element);}
            Cell(Text(rank.ToString("00"),11,true),0);Cell(Text(row.Label,13),1);
            var track=new Grid{Height=7,VerticalAlignment=VerticalAlignment.Center,Margin=new(0,0,20,0)};
            track.ColumnDefinitions.Add(new(){Width=new(Math.Max(.000001,(double)row.Count/maximum),GridUnitType.Star)});
            track.ColumnDefinitions.Add(new(){Width=new(Math.Max(.000001,1-(double)row.Count/maximum),GridUnitType.Star)});
            var rail=new Border{Background=Brush("PageBrush"),CornerRadius=new(4)};Grid.SetColumnSpan(rail,2);track.Children.Add(rail);
            if(row.Count>0)track.Children.Add(new Border{Background=HeatBrush(scale.Level(row.Count)),CornerRadius=new(4)});
            Cell(track,2);
            var count=Text(Number(row.Count),13);count.TextAlignment=TextAlignment.Right;Cell(count,3);
            var percent=Text(snapshot.Total>0?((double)row.Count/snapshot.Total).ToString("P1"):"0%",12,true);percent.TextAlignment=TextAlignment.Right;Cell(percent,4);
            var button=Button("",()=>{state.SelectedKey=row.Key;RefreshHeatmap();RefreshRanking();});button.Content=line;button.HorizontalContentAlignment=HorizontalAlignment.Stretch;
            button.Padding=new(10,10,10,10);button.Margin=new(0,0,0,4);button.BorderThickness=new(0);button.Background=Brush(state.SelectedKey==row.Key?"PageBrush":"CardBrush");button.ToolTip=Detail(row.Key);
            AutomationProperties.SetName(button,Detail(row.Key));AutomationProperties.SetAutomationId(button,"statistics-rank-"+row.Key);ranking.Children.Add(button);
        }
    }
    private string TrendDescription() {
        if(snapshot is null||snapshot.Total==0)return T("这段时间还没有记录。","No activity in this period yet.");
        string interval=snapshot.Interval switch {
            StatisticsInterval.FiveMinutes=>T("每 5 分钟","5-minute buckets"),StatisticsInterval.FifteenMinutes=>T("每 15 分钟","15-minute buckets"),
            StatisticsInterval.Hour=>T("每小时","Hourly"),StatisticsInterval.Day=>T("每天","Daily"),StatisticsInterval.Week=>T("每周","Weekly"),
            StatisticsInterval.Month=>T("每月","Monthly"),_=>T("按年分段","Yearly buckets")};
        return interval+T("  ·  悬停查看该时段次数，首尾可能不足一个完整时段。","  ·  Hover for interval totals. Edge intervals may be partial.");
    }
    private void Export() {
        var(from,to,_)=Range(DateTimeOffset.Now);if(to<=from){showError(T("请输入有效时间段。","Enter a valid time range."));return;}
        var dialog=new SaveFileDialog{FileName="KeyWoo-counts.csv",Filter="CSV|*.csv"};
        if(dialog.ShowDialog(Window.GetWindow(this))==true)try{File.WriteAllText(dialog.FileName,store.Csv(from,to),new System.Text.UTF8Encoding(true));}catch(Exception error){showError(error.Message);}
    }
    private string IntervalLabel(DateTimeOffset from,DateTimeOffset to) {
        var start=TimeZoneInfo.ConvertTime(from,TimeZoneInfo.Local);
        var end=TimeZoneInfo.ConvertTime(to,TimeZoneInfo.Local);
        bool years=start.Year!=DateTime.Now.Year||end.Year!=DateTime.Now.Year||start.Year!=end.Year;
        bool offsets=start.Offset!=end.Offset||TimeZoneInfo.Local.IsAmbiguousTime(start.DateTime)||TimeZoneInfo.Local.IsAmbiguousTime(end.DateTime);
        string format=(years?"yyyy/M/d HH:mm":"M/d HH:mm")+(offsets?" zzz":"");
        return start.ToString(format)+" — "+end.ToString(format);
    }
    private string T(string zh,string en)=>chinese?zh:en;
    private string Number(long value)=>value.ToString("N0",CultureInfo.CurrentCulture);
    private static DateTime Local(DateTimeOffset value)=>value.LocalDateTime;
    private bool IsDark=>((SolidColorBrush)Brush("CardBrush")).Color.R<100;
    private Brush Brush(string key)=>(Brush)System.Windows.Application.Current.Resources[key];
    private Brush HeatBrush(int level) {
        Color background=((SolidColorBrush)Brush("PageBrush")).Color, accent=((SolidColorBrush)Brush("AccentBrush")).Color;
        double fraction=new[]{0d,.12,.28,.48,.72,1}[Math.Clamp(level,0,5)];
        return new SolidColorBrush(Color.FromRgb((byte)(background.R+(accent.R-background.R)*fraction),(byte)(background.G+(accent.G-background.G)*fraction),(byte)(background.B+(accent.B-background.B)*fraction)));
    }
    private TextBlock Text(string text,double size=14,bool muted=false)=>new(){Text=text,FontSize=size,Foreground=Brush(muted?"MutedBrush":"TextBrush"),TextWrapping=TextWrapping.Wrap,VerticalAlignment=VerticalAlignment.Center};
    private Button Button(string label,Action action){var button=new Button{Content=label,Margin=new(0,0,6,0),Padding=new(12,7,12,7),HorizontalContentAlignment=HorizontalAlignment.Left};button.Click+=(_,_)=>action();return button;}
    private Border Card(UIElement child)=>new(){Child=child,Background=Brush("CardBrush"),Padding=new(20),CornerRadius=new(12),Margin=new(0,0,0,16)};
    private UIElement Heading(string title,string hint) {
        var row=new DockPanel{Margin=new(0,0,0,12)};var note=Text(hint,11,true);DockPanel.SetDock(note,Dock.Right);row.Children.Add(note);
        var name=Text(title,15);name.FontWeight=FontWeights.SemiBold;row.Children.Add(name);return row;
    }
    private static TextBox TimeBox(DateTime value)=>new(){Text=value.ToString("HH:mm",CultureInfo.InvariantCulture),Width=72,Padding=new(6),VerticalContentAlignment=VerticalAlignment.Center};
}

internal sealed class StatisticsTrendView(bool chinese) : FrameworkElement {
    private IReadOnlyList<StatisticsTrendBucket> buckets=[];
    private int? hovered;
    internal event Action<StatisticsTrendBucket?>? Hovered;
    internal void SetData(IReadOnlyList<StatisticsTrendBucket> values){buckets=values;hovered=null;InvalidateVisual();}
    internal StatisticsTrendView() : this(false) { }
    protected override void OnRender(DrawingContext context) {
        base.OnRender(context);
        if(ActualWidth<100||ActualHeight<80)return;
        context.DrawRectangle(Brushes.Transparent,null,new Rect(RenderSize));
        Brush accent=(Brush)System.Windows.Application.Current.Resources["AccentBrush"], muted=(Brush)System.Windows.Application.Current.Resources["MutedBrush"], line=(Brush)System.Windows.Application.Current.Resources["LineBrush"];
        double left=52,right=ActualWidth-10,top=12,bottom=ActualHeight-30,width=right-left,height=bottom-top;
        long maximum=buckets.Count==0?0:buckets.Max(bucket=>bucket.Count);
        double ceiling=NiceMaximum(maximum);
        for(int index=0;index<4;index++) {
            double y=bottom-height*index/3;
            context.DrawLine(new Pen(line,.6),new(left,y),new(right,y));
            Label(context,(ceiling*index/3).ToString("0.#",CultureInfo.CurrentCulture),new(0,y-7),muted);
        }
        if(buckets.Count==0)return;
        double step=width/buckets.Count;
        for(int index=0;index<buckets.Count;index++) {
            var bucket=buckets[index];double barHeight=height*bucket.Count/ceiling;
            if(barHeight<=0)continue;
            context.PushOpacity(hovered is null || hovered==index ? .84 : .42);
            context.DrawRoundedRectangle(accent,null,new(left+index*step+step*.15,bottom-barHeight,Math.Max(1,step*.70),barHeight),2,2);context.Pop();
        }
        foreach(int index in new[]{0,buckets.Count/2,buckets.Count-1}.Distinct()) {
            var date=buckets[index].Start.LocalDateTime;string text=date.ToString((buckets[^1].End-buckets[0].Start).TotalDays>365?"yyyy":(buckets[^1].End-buckets[0].Start).TotalDays>2?"M/d":"HH:mm");
            double x=Math.Clamp(left+(index+.5)*step-18,left,right-36);Label(context,text,new(x,bottom+10),muted);
        }
        if(maximum==0)Label(context,chinese?"暂无按键记录":"No activity yet",new(left+width/2-50,top+height/2-10),muted);
    }
    protected override void OnMouseMove(MouseEventArgs e) {
        base.OnMouseMove(e);double width=ActualWidth-62;int? index=null;
        if(width>0&&buckets.Count>0) {double x=e.GetPosition(this).X-52;if(x>=0&&x<=width)index=Math.Clamp((int)(x/width*buckets.Count),0,buckets.Count-1);}
        if(hovered==index)return;hovered=index;InvalidateVisual();Hovered?.Invoke(index is int at?buckets[at]:null);
    }
    protected override void OnMouseLeave(MouseEventArgs e){base.OnMouseLeave(e);hovered=null;InvalidateVisual();Hovered?.Invoke(null);}
    private void Label(DrawingContext context,string text,Point origin,Brush brush)=>context.DrawText(new FormattedText(text,CultureInfo.CurrentCulture,FlowDirection.LeftToRight,new Typeface("Segoe UI"),10,brush,VisualTreeHelper.GetDpi(this).PixelsPerDip),origin);
    private static double NiceMaximum(long maximum) {
        if(maximum<=3)return 3;
        double magnitude=Math.Pow(10,Math.Floor(Math.Log10(maximum))), fraction=maximum/magnitude;
        return (fraction<=1?1:fraction<=2?2:fraction<=5?5:10)*magnitude;
    }
}
