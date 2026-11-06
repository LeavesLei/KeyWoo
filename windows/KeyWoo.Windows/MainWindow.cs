using System.Collections.Concurrent;
using System.ComponentModel;
using System.Globalization;
using System.Text;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Threading;
using KeyWoo.Core;
using Microsoft.Win32;
using Forms=System.Windows.Forms;
namespace KeyWoo.Windows;

public sealed class MainWindow : Window {
    private readonly Settings settings;
    private readonly StatisticsStore statistics;
    private readonly KeyboardHook hook=new();
    private readonly KeyBurstOverlay keyBurst=new();
    private readonly ConcurrentQueue<(PhysicalKey Key,DateTimeOffset At)> presses=new();
    private readonly DispatcherTimer updateTimer,saveTimer;
    private readonly Forms.NotifyIcon tray=new();
    private System.Drawing.Icon? trayIcon;
    private readonly Dictionary<string,Button> presetButtons=[];
    private readonly Dictionary<int,Button> keyButtons=[];
    private readonly Dictionary<int,DateTimeOffset> highlights=[];
    private AudioOutput? audio;
    private SampleBank? soundBank;
    private Action? refreshSoundCatalog;
    private CancellationTokenSource? preview;
    private bool enabled=true,building,closing,started,hookReady,resumeAfterUnlock,sessionLocked;
    private int queuedPresses,flushing;
    private long droppedCounts;
    private DateTimeOffset lastFlush=DateTimeOffset.MinValue;
    private TabControl? tabs;
    private string? currentError;
    private string? audioError;
    private TextBlock status=new(),error=new(),session=new();
    private Button pause=new();
    private Button? keyBurstPreview;
    private CheckBox mappingCheck=new();
    private DataGrid statsGrid=new(),ruleGrid=new();
    private DatePicker fromDate=new(),toDate=new();
    private TextBox fromTime=new(),toTime=new();
    private ComboBox sourceKey=new(),targetKey=new();
    private readonly Dictionary<KeyModifiers,CheckBox> sourceModifiers=[],targetModifiers=[];
    private TextBox? practice;
    private bool Chinese=>settings.Language=="zh"||(settings.Language=="system"&&CultureInfo.CurrentUICulture.TwoLetterISOLanguageName=="zh");
    private string T(string zh,string en)=>Chinese?zh:en;
    private Brush Brush(string key)=>(Brush)System.Windows.Application.Current.Resources[key];
    public MainWindow() {
        settings=Settings.Load(out var loadError);
        statistics=new(Path.Combine(Settings.DataDirectory,"statistics.json"));
        Width=1050;Height=780;MinWidth=820;MinHeight=650;
        WindowStartupLocation=WindowStartupLocation.CenterScreen;
        hook.Pressed+=(key,at)=>{if(Interlocked.Increment(ref queuedPresses)<=8192)presses.Enqueue((key,at));else {Interlocked.Decrement(ref queuedPresses);Interlocked.Increment(ref droppedCounts);}};
        hook.Sound+=(key,down)=>{
            audio?.Mixer.Physical(key,down);
            if(down)keyBurst.Enqueue(key);
        };
        hook.Failed+=message=>Dispatcher.InvokeAsync(()=>{settings.MappingEnabled=false;mappingCheck.IsChecked=false;ShowError(message);SaveSoon();});
        updateTimer=new DispatcherTimer(TimeSpan.FromMilliseconds(100),DispatcherPriority.Background,(_,_)=>Refresh(),Dispatcher);
        saveTimer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(450)};
        saveTimer.Tick+=async(_,_)=>{saveTimer.Stop();try{await settings.SaveAsync();}catch(Exception ex){ShowError(ex.Message);}};
        Build();SetupTray();
        if(loadError is not null||statistics.Error is not null)ShowError(loadError??statistics.Error!);
        Loaded+=async(_,_)=>{if(!started){started=true;await StartAsync();}};
        Closing+=(_,e)=>{if(!closing){e.Cancel=true;Hide();}};
        SystemEvents.SessionSwitch+=SessionChanged;
        SystemEvents.UserPreferenceChanged+=PreferencesChanged;
        System.Windows.Application.Current.SessionEnding+=(_,_)=>ExitNow();
    }
    private async Task StartAsync() {
        status.Text=T("正在加载录音…","Loading recordings…");
        try {
            var bank=await Task.Run(()=>new SampleBank(Path.Combine(AppContext.BaseDirectory,"Assets","KeyboardSounds")));
            if(closing)return;
            soundBank=bank;
            if(!bank.Packs.ContainsKey(settings.Preset))settings.Preset=SampleBank.DefaultPreset;
            refreshSoundCatalog?.Invoke();
            audio=new AudioOutput(bank);audio.Mixer.Style=settings.Preset;audio.Mixer.Volume=(float)settings.Volume;
            audio.Mixer.HiFiEnabled=settings.HiFiEnabled;
            audio.Mixer.Enabled=enabled;
            audio.Failed+=message=>Dispatcher.InvokeAsync(()=>ShowAudioError(message));
            audio.Recovered+=ClearAudioError;audio.Start();
        } catch(Exception ex){ShowAudioError(ex.Message);}
        if(closing)return;
        try {
            await hook.StartAsync();
            if(closing){hook.Dispose();return;}
            hookReady=true;
            if(sessionLocked)await hook.SuspendSessionAsync();else await ConfigureHook();
            UpdatePause();
        }
        catch(Exception ex){enabled=false;audio?.Mixer.Reset();ShowError(T("全局输入启动失败：","Global input could not start: ")+ex.Message);UpdatePause();}
    }
    private void Build() {
        int previousTab=tabs?.SelectedIndex??0;var previousFrom=fromDate.SelectedDate;var previousTo=toDate.SelectedDate;string previousFromTime=fromTime.Text,previousToTime=toTime.Text;
        building=true;Language=XmlLanguage.GetLanguage(Chinese?"zh-CN":"en-US");Title=Chinese?"键舞":"KeyWoo";
        var previousPractice=practice?.Text??"";ApplyTheme();presetButtons.Clear();keyButtons.Clear();
        var shell=new DockPanel{Margin=new Thickness(28)};
        var header=new DockPanel{Margin=new Thickness(0,0,0,20)};
        pause=MakeButton("",(_,_)=>ToggleEnabled());DockPanel.SetDock(pause,Dock.Right);header.Children.Add(pause);
        var heading=new StackPanel();heading.Children.Add(new TextBlock{Text=Title,FontSize=27,FontWeight=FontWeights.SemiBold});
        status=Text(enabled?T("所有应用","All applications"):T("已暂停","Paused"),12,true);heading.Children.Add(status);header.Children.Add(heading);
        DockPanel.SetDock(header,Dock.Top);shell.Children.Add(header);
        error=Text("",12,true);error.Foreground=Brushes.DarkOrange;error.TextWrapping=TextWrapping.Wrap;error.Visibility=Visibility.Collapsed;
        DockPanel.SetDock(error,Dock.Bottom);shell.Children.Add(error);
        session=Text("",12,true);session.Margin=new Thickness(0,14,0,8);DockPanel.SetDock(session,Dock.Bottom);shell.Children.Add(session);
        tabs=new TabControl{SelectedIndex=Math.Max(0,previousTab),Background=Brush("PageBrush"),BorderThickness=new Thickness(0)};
        tabs.Items.Add(new TabItem{Header=T("键盘音效","Keyboard sounds"),Content=Scroll(Sounds())});
        tabs.Items.Add(new TabItem{Header=T("统计","Statistics"),Content=Scroll(Statistics())});
        tabs.Items.Add(new TabItem{Header=T("按键映射","Key mapping"),Content=Scroll(Mapping())});
        tabs.Items.Add(new TabItem{Header=T("设置","Settings"),Content=Scroll(Preferences())});shell.Children.Add(tabs);Content=shell;
        if(practice is not null)practice.Text=previousPractice;
        if(previousFrom is not null)fromDate.SelectedDate=previousFrom;if(previousTo is not null)toDate.SelectedDate=previousTo;
        if(!string.IsNullOrEmpty(previousFromTime))fromTime.Text=previousFromTime;if(!string.IsNullOrEmpty(previousToTime))toTime.Text=previousToTime;
        if(currentError is not null)ShowError(currentError);building=false;UpdatePause();UpdatePresets();RefreshStatistics();
    }
    private ScrollViewer Scroll(UIElement child)=>new(){Content=child,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,Margin=new Thickness(0,18,0,0)};
    private TextBlock Text(string content,double size=14,bool muted=false)=>new(){Text=content,FontSize=size,Foreground=Brush(muted?"MutedBrush":"TextBrush"),TextWrapping=TextWrapping.Wrap};
    private StackPanel Panel()=>new(){Margin=new Thickness(0,0,8,0)};
    private Button MakeButton(string title,RoutedEventHandler click) {var b=new Button{Content=title};b.Click+=click;return b;}
    private Border Card(UIElement child)=>new(){Child=child,Background=Brush("CardBrush"),Padding=new Thickness(18),CornerRadius=new CornerRadius(10),Margin=new Thickness(0,0,0,16)};
    private sealed record SoundGroup(SoundCategory Category,string Label,SoundPreset[] Presets);
    private UIElement Sounds() {
        var panel=Panel();var grid=new UniformGrid{Columns=3,Margin=new Thickness(0,0,0,12)};
        var category=new ComboBox{DisplayMemberPath=nameof(SoundGroup.Label),Width=250,HorizontalAlignment=HorizontalAlignment.Left,Margin=new Thickness(0,0,0,12)};
        var versionRow=new StackPanel{Orientation=Orientation.Horizontal,Margin=new Thickness(0,0,0,12)};
        string versionTitle=T("录音版本","Recording version");
        var versionLabel=Text(versionTitle,13,true);
        versionLabel.VerticalAlignment=VerticalAlignment.Center;
        versionLabel.Margin=new Thickness(0,0,12,0);
        versionRow.Children.Add(versionLabel);
        var version=new ComboBox {
            ItemsSource=new KeyValuePair<bool,string>[]{new(false,T("原音","Original")),new(true,T("Hi-Fi 高保真","Hi-Fi"))},
            DisplayMemberPath="Value",SelectedValuePath="Key",SelectedValue=settings.HiFiEnabled,Width=150
        };
        AutomationProperties.SetAutomationId(version,"recording-version");
        AutomationProperties.SetName(version,versionTitle);
        version.SelectionChanged+=async(_,_)=>{
            if(building||version.SelectedValue is not bool hiFi||settings.HiFiEnabled==hiFi)return;
            settings.HiFiEnabled=hiFi;
            if(audio is not null)audio.Mixer.HiFiEnabled=hiFi;
            SaveSoon();
            await PreviewSequence();
        };
        versionRow.Children.Add(version);
        void UpdateVersionVisibility()=>versionRow.Visibility=soundBank?.HiFiPacks.ContainsKey(settings.Preset)==true
            ?Visibility.Visible:Visibility.Collapsed;
        panel.Children.Add(category);
        void FillPresets() {
            grid.Children.Clear();
            presetButtons.Clear();
            if(category.SelectedItem is not SoundGroup group)return;
            foreach(var preset in group.Presets) {
                string id=preset.Id;
                var label=new StackPanel();label.Children.Add(Text(PresetName(preset),15));
                label.Children.Add(Text(preset.Category==SoundCategory.Synthesized?T("合成拟音","Synthesized"):T("真实录音","Recorded"),11,true));
                var button=MakeButton("",async(_,_)=>{
                    settings.Preset=id;
                    if(audio is not null)audio.Mixer.Style=id;
                    UpdatePresets();UpdateVersionVisibility();SaveSoon();
                    await PreviewSequence();
                });
                button.Content=label;button.MinHeight=76;button.Margin=new Thickness(0,0,10,10);button.HorizontalContentAlignment=HorizontalAlignment.Left;
                AutomationProperties.SetAutomationId(button,"preset-"+id);presetButtons[id]=button;grid.Children.Add(button);
            }
            UpdatePresets();
        }
        category.SelectionChanged+=(_,_)=>FillPresets();
        refreshSoundCatalog=()=>{
            var groups=soundBank?.Presets.GroupBy(p=>p.Category)
                .Select(g=>new SoundGroup(g.Key,$"{SoundCategoryName(g.Key)} · {g.Count()}",g.ToArray())).ToArray()??[];
            category.ItemsSource=groups;
            category.SelectedItem=groups.FirstOrDefault(g=>g.Presets.Any(p=>p.Id==settings.Preset))??groups.FirstOrDefault();
            UpdateVersionVisibility();
        };
        refreshSoundCatalog();
        panel.Children.Add(grid);
        panel.Children.Add(versionRow);
        panel.Children.Add(VolumeControl());
        var practicePanel=Panel();practicePanel.Children.Add(Text(T("试打","Try typing"),16));
        practice=new TextBox{AcceptsReturn=true,MinHeight=70,Margin=new Thickness(0,12,0,16),VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
        AutomationProperties.SetAutomationId(practice,"practice-input");practicePanel.Children.Add(practice);
        foreach(var row in new[]{new[]{(81,16),(87,17),(69,18),(82,19),(84,20),(89,21),(85,22),(73,23),(79,24),(80,25)},new[]{(65,30),(83,31),(68,32),(70,33),(71,34),(72,35),(74,36),(75,37),(76,38)},new[]{(90,44),(88,45),(67,46),(86,47),(66,48),(78,49),(77,50)},new[]{(9,15),(32,57),(13,28),(8,14)}}) {
            var keys=new UniformGrid{Columns=row.Length,Margin=new Thickness(0,0,0,6)};
            foreach(var (vk,scan) in row) {
                var key=new PhysicalKey(vk,scan);var b=MakeButton(KeyboardKeys.Name(vk,Chinese),async(_,_)=>await PreviewKey(key.MacCode));b.Padding=new Thickness(4,8,4,8);b.FontSize=12;b.Margin=new Thickness(0,0,5,0);keyButtons[key.Id]=b;keys.Children.Add(b);
            }
            practicePanel.Children.Add(keys);
        }
        practicePanel.Children.Add(Text(T("点击键帽试听不计入统计。文字只保留在当前窗口。","Clicking a key previews it without counting. Practice text stays in this window."),11,true));panel.Children.Add(Card(practicePanel));
        var sources=new Expander{Header=T("声音来源","Sound sources")};var sourcePanel=Panel();
        sourcePanel.Children.Add(Text(T("键盘实录、实录拟音和趣味合成与 macOS 版共用采样。部分录音在同类键之间复用。","Windows and macOS share the keyboard recordings, recorded foley and synthesized sounds. Some packs reuse recordings across similar keys."),12,true));
        sourcePanel.Children.Add(MakeButton(T("查看来源与许可证","View sources and licenses"),(_,_)=>OpenFile(Path.Combine(AppContext.BaseDirectory,"Assets","KeyboardSounds","THIRD-PARTY-NOTICES.md"))));sources.Content=sourcePanel;panel.Children.Add(sources);return panel;
    }

    private DockPanel VolumeControl() {
        const double standardGain = 4;
        const double standardTrack = .75;
        const double extraTrack = 1 - standardTrack;
        const double extraGain = SampleMixer.MaximumVolume - standardGain;

        var panel = new DockPanel { Margin = new Thickness(0, 0, 0, 18) };
        var previewButton = MakeButton(T("试听", "Preview"), async (_, _) => await PreviewSequence());
        DockPanel.SetDock(previewButton, Dock.Right);
        panel.Children.Add(previewButton);

        string title = T("音量", "Volume");
        var valueLabel = Text(settings.Volume.ToString("P0"), 13, true);
        valueLabel.Width = 64;
        valueLabel.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(valueLabel, Dock.Right);
        panel.Children.Add(valueLabel);

        var label = Text(title);
        label.Width = 72;
        label.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(label, Dock.Left);
        panel.Children.Add(label);

        // Reserve most of the track for the established gain range.
        var slider = new Slider {
            Minimum = 0,
            Maximum = 1,
            SmallChange = .01,
            LargeChange = .05,
            Value = settings.Volume <= standardGain
                ? settings.Volume / standardGain * standardTrack
                : standardTrack + (settings.Volume - standardGain) / extraGain * extraTrack,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 18, 0)
        };
        AutomationProperties.SetAutomationId(slider, "keyboard-volume");
        AutomationProperties.SetName(slider, $"{title} {valueLabel.Text}");
        slider.ValueChanged += (_, _) => {
            if (building) return;
            settings.Volume = slider.Value <= standardTrack
                ? slider.Value / standardTrack * standardGain
                : standardGain + (slider.Value - standardTrack) / extraTrack * extraGain;
            valueLabel.Text = settings.Volume.ToString("P0");
            AutomationProperties.SetName(slider, $"{title} {valueLabel.Text}");
            if (audio is not null) audio.Mixer.Volume = (float)settings.Volume;
            SaveSoon();
        };
        panel.Children.Add(slider);
        return panel;
    }
    private string SoundCategoryName(SoundCategory category)=>category switch {
        SoundCategory.RecordedKeyboard=>T("键盘实录","Recorded keyboards"),
        SoundCategory.RecordedFoley=>T("实录拟音","Recorded foley"),
        _=>T("趣味合成","Synthesized sounds")
    };
    private string PresetName(SoundPreset preset)=>preset.Id switch {"topre"=>T("Topre 静电容","Topre"),"oreo"=>"Everglide Oreo","panda"=>"Holy Panda","purple"=>T("Everglide 水晶紫","Everglide Crystal Purple"),"red"=>T("Cherry 红轴 · ABS","Cherry Red · ABS"),"blue"=>T("Cherry 青轴 · ABS","Cherry Blue · ABS"),"brown"=>T("Cherry 茶轴 · PBT","Cherry Brown · PBT"),"black"=>T("Cherry 黑轴 · PBT","Cherry Black · PBT"),"bluePBT"=>T("Cherry 青轴 · PBT","Cherry Blue · PBT"),"brownABS"=>T("Cherry 茶轴 · ABS","Cherry Brown · ABS"),"blackABS"=>T("Cherry 黑轴 · ABS","Cherry Black · ABS"),"typewriter"=>T("打字机","Typewriter"),"bubble"=>T("泡泡","Bubble"),"woodblock"=>T("木鱼","Woodblock"),"paper"=>T("纸笺","Paper"),"raindrop"=>T("水滴","Raindrop"),"brick"=>T("积木","Brick"),"arcade"=>T("街机","Arcade"),"laser"=>T("激光","Laser"),"mahjong"=>T("麻将","Mahjong"),_=>Chinese?preset.TitleZh??preset.Title:preset.Title};
    private void UpdatePresets(){foreach(var (id,b) in presetButtons){b.BorderBrush=Brush(id==settings.Preset?"AccentBrush":"LineBrush");b.BorderThickness=new Thickness(id==settings.Preset?2:1);}}
    // Match macOS for A/B comparison and the 96 BPM Street Beat demonstration.
    private static readonly (int Time,int[] Keys)[] RecordingPreview =
        [(0,[0]),(140,[1]),(280,[2]),(540,[49]),(850,[36]),(1150,[51])];
    private static readonly (int Time,int[] Keys)[] StreetBeatPreview =
        [(0,[49,0]),(177,[0]),(313,[0]),(489,[0]),(625,[36,56,0]),(802,[0]),(938,[49,0]),(1114,[51]),
         (1250,[49,0]),(1427,[0]),(1563,[0]),(1739,[0]),(1875,[36,56,0]),(2052,[0]),(2188,[48])];

    private Task PreviewSequence()=>PlayPreview(audio?.Mixer.Style==SampleBank.StreetBeatPreset?StreetBeatPreview:RecordingPreview);
    private Task PreviewKey(int code)=>PlayPreview([(0,[code])],Environment.TickCount);
    private async Task PlayPreview((int Time,int[] Keys)[] pattern,int take=0) {
        preview?.Cancel();preview?.Dispose();preview=new CancellationTokenSource();var token=preview.Token;
        if(!enabled||audio is null)return;
        var mixer=audio.Mixer;
        int generation=mixer.CancelPreview();
        var clock=System.Diagnostics.Stopwatch.StartNew();
        try {
            foreach(var (time,keys) in pattern) {
                await Task.Delay((int)Math.Max(0,time-clock.ElapsedMilliseconds),token);
                if(token.IsCancellationRequested||!mixer.IsPreviewCurrent(generation))return;
                foreach(int key in keys) {
                    mixer.Preview(key,true,take,generation);
                    // The mixer applies the same minimum 70 ms release delay to previews.
                    mixer.Preview(key,false,take,generation);
                }
                take++;
            }
        } catch(OperationCanceledException){}
    }
    private UIElement Statistics() {
        var panel=Panel();panel.Children.Add(Text(T("指定时间段的逐键次数","Key counts over a chosen period"),18));
        var dates=new WrapPanel{Margin=new Thickness(0,16,0,12)};
        fromDate=new DatePicker{SelectedDate=DateTime.Today,Width=145,Margin=new Thickness(0,0,6,0)};fromTime=new TextBox{Text="00:00",Width=72,Padding=new Thickness(5),Margin=new Thickness(0,0,12,0)};
        toDate=new DatePicker{SelectedDate=DateTime.Today.AddDays(1),Width=145,Margin=new Thickness(0,0,6,0)};toTime=new TextBox{Text="00:00",Width=72,Padding=new Thickness(5),Margin=new Thickness(0,0,12,0)};
        dates.Children.Add(fromDate);dates.Children.Add(fromTime);dates.Children.Add(Text(" → "));dates.Children.Add(toDate);dates.Children.Add(toTime);dates.Children.Add(MakeButton(T("更新","Update"),(_,_)=>RefreshStatistics()));
        dates.Children.Add(MakeButton(T("导出 CSV","Export CSV"),(_,_)=>ExportStatistics()));panel.Children.Add(dates);
        panel.Children.Add(Text(T("本地时间，截止时间不含；分钟边界向外取整。只保存按键次数，不保存顺序、文字或应用名称。","Local time; end is exclusive. Partial minutes round outward. Only key counts are stored—no order, text or application names."),12,true));
        statsGrid=new DataGrid{AutoGenerateColumns=false,IsReadOnly=true,CanUserAddRows=false,Height=350,Margin=new Thickness(0,16,0,0),Background=Brush("CardBrush"),Foreground=Brush("TextBrush"),RowBackground=Brush("CardBrush"),AlternatingRowBackground=Brush("PageBrush")};
        statsGrid.Columns.Add(new DataGridTextColumn{Header=T("物理键","Physical key"),Binding=new System.Windows.Data.Binding(nameof(KeyCount.Label)),Width=new DataGridLength(1,DataGridLengthUnitType.Star)});
        statsGrid.Columns.Add(new DataGridTextColumn{Header=T("扫描码","Scan code"),Binding=new System.Windows.Data.Binding(nameof(KeyCount.Key)),Width=130});
        statsGrid.Columns.Add(new DataGridTextColumn{Header=T("次数","Count"),Binding=new System.Windows.Data.Binding(nameof(KeyCount.Count)),Width=150});panel.Children.Add(statsGrid);return panel;
    }
    private bool Range(out DateTimeOffset from,out DateTimeOffset to) {
        from=to=default;
        if(!TimeSpan.TryParse(fromTime.Text,CultureInfo.InvariantCulture,out var a)||!TimeSpan.TryParse(toTime.Text,CultureInfo.InvariantCulture,out var b)||a<TimeSpan.Zero||b<TimeSpan.Zero||a>=TimeSpan.FromDays(1)||b>=TimeSpan.FromDays(1))return false;
        from=new DateTimeOffset((fromDate.SelectedDate??DateTime.Today).Date+a);to=new DateTimeOffset((toDate.SelectedDate??DateTime.Today.AddDays(1)).Date+b);return to>from;
    }
    private void RefreshStatistics(){if(Range(out var from,out var to))statsGrid.ItemsSource=statistics.Counts(from,to);}
    private void ExportStatistics() {
        if(!Range(out var from,out var to)){ShowError(T("请输入有效时间段。","Enter a valid time range."));return;}
        var dialog=new SaveFileDialog{FileName="KeyWoo-counts.csv",Filter="CSV|*.csv"};if(dialog.ShowDialog(this)==true){try{File.WriteAllText(dialog.FileName,statistics.Csv(from,to),new UTF8Encoding(true));}catch(Exception ex){ShowError(ex.Message);}}
    }
    private sealed record KeyOption(int Key,string Name,string Category);
    private sealed record RuleRow(InputRule Rule,string Source,string Target);
    private UIElement Mapping() {
        var panel=Panel();mappingCheck=new CheckBox{Content=T("启用软件按键映射","Enable software key mapping"),IsChecked=settings.MappingEnabled};
        mappingCheck.Checked+=async(_,_)=>{if(building)return;settings.MappingEnabled=true;await ConfigureHook();SaveSoon();};mappingCheck.Unchecked+=async(_,_)=>{if(building)return;settings.MappingEnabled=false;await ConfigureHook();SaveSoon();};panel.Children.Add(mappingCheck);
        panel.Children.Add(Text(T("映射仅在键舞运行且未暂停时生效。统计和音效跟随原始物理键。Fn 常被键盘固件处理；可用 Ctrl+Alt 媒体组合键替代。系统安全快捷键与更高权限窗口不保证可改。","Mappings apply while KeyWoo is running and active. Counts and sounds follow the original physical key. Fn is often handled in firmware; Ctrl+Alt media shortcuts provide an alternative. Secure shortcuts and elevated windows may not be remappable."),12,true));
        sourceModifiers.Clear();targetModifiers.Clear();
        panel.Children.Add(Text(T("按下","When pressed"),13));sourceKey=KeyChooser(0x14);panel.Children.Add(sourceKey);panel.Children.Add(ModifierOptions(sourceModifiers));
        panel.Children.Add(Text(T("改为","Send instead"),13));targetKey=KeyChooser(0x1B);panel.Children.Add(targetKey);panel.Children.Add(ModifierOptions(targetModifiers));
        var buttons=new WrapPanel{Margin=new Thickness(0,10,0,10)};
        buttons.Children.Add(MakeButton(T("添加映射","Add mapping"),async(_,_)=>{
            if(sourceKey.SelectedItem is not KeyOption s||targetKey.SelectedItem is not KeyOption t)return;
            var rule=new InputRule(s.Key,Modifiers(sourceModifiers),t.Key,Modifiers(targetModifiers));
            if(rule.Source==rule.Target&&rule.Modifiers==rule.TargetModifiers){ShowError(T("来源和目标相同。","Source and target are identical."));return;}
            settings.Rules.RemoveAll(r=>r.Source==rule.Source&&r.Modifiers==rule.Modifiers);settings.Rules.Add(rule);await RulesChanged();
        }));
        buttons.Children.Add(MakeButton(T("添加媒体组合键","Add media shortcuts"),async(_,_)=>{foreach(var rule in InputRouter.MediaShortcuts){settings.Rules.RemoveAll(r=>r.Source==rule.Source&&r.Modifiers==rule.Modifiers);settings.Rules.Add(rule);}await RulesChanged();}));
        buttons.Children.Add(MakeButton(T("移除选中","Remove selected"),async(_,_)=>{if(ruleGrid.SelectedItem is RuleRow row){settings.Rules.Remove(row.Rule);await RulesChanged();}}));panel.Children.Add(buttons);
        panel.Children.Add(Text(T("Ctrl+Alt：J 上一首 · K 播放/暂停 · L 下一首 · U/I 音量 · M 静音。","Ctrl+Alt: J previous · K play/pause · L next · U/I volume · M mute."),12,true));
        ruleGrid=new DataGrid{IsReadOnly=true,AutoGenerateColumns=false,CanUserAddRows=false,Height=210,Margin=new Thickness(0,12,0,0),Background=Brush("CardBrush"),Foreground=Brush("TextBrush"),RowBackground=Brush("CardBrush")};
        ruleGrid.Columns.Add(new DataGridTextColumn{Header=T("来源","Source"),Binding=new System.Windows.Data.Binding(nameof(RuleRow.Source)),Width=new DataGridLength(1,DataGridLengthUnitType.Star)});
        ruleGrid.Columns.Add(new DataGridTextColumn{Header=T("目标","Target"),Binding=new System.Windows.Data.Binding(nameof(RuleRow.Target)),Width=new DataGridLength(1,DataGridLengthUnitType.Star)});panel.Children.Add(ruleGrid);UpdateRules();return panel;
    }
    private ComboBox KeyChooser(int selected) {
        var options = KeyboardKeys.KeyGroups.SelectMany(group =>
            group.Keys.Select(key => new KeyOption(key, KeyboardKeys.Name(key, Chinese), CategoryName(group.Category)))).ToArray();
        var view = new ListCollectionView(options);
        view.GroupDescriptions.Add(new PropertyGroupDescription(nameof(KeyOption.Category)));
        var header = new FrameworkElementFactory(typeof(TextBlock));
        header.SetBinding(TextBlock.TextProperty, new Binding(nameof(CollectionViewGroup.Name)));
        header.SetValue(TextBlock.FontWeightProperty, FontWeights.SemiBold);
        header.SetValue(TextBlock.MarginProperty, new Thickness(6, 5, 6, 2));
        var box = new ComboBox {
            ItemsSource = view, DisplayMemberPath = nameof(KeyOption.Name), SelectedValuePath = nameof(KeyOption.Key),
            SelectedValue = selected, MaxDropDownHeight = 320, MinWidth = 220, HorizontalAlignment = HorizontalAlignment.Left
        };
        box.GroupStyle.Add(new GroupStyle { HeaderTemplate = new DataTemplate { VisualTree = header } });
        return box;
    }
    private string CategoryName(KeyCategory category) => category switch {
        KeyCategory.Media => T("媒体与音量", "Media and volume"),
        KeyCategory.Function => T("功能键", "Function keys"),
        KeyCategory.Editing => T("编辑与导航", "Editing and navigation"),
        KeyCategory.Numpad => T("数字小键盘", "Numpad"),
        KeyCategory.Modifiers => T("修饰键", "Modifiers"),
        KeyCategory.Typing => T("字母、数字与标点", "Letters, digits and punctuation"),
        KeyCategory.Browser => T("浏览器", "Browser"),
        _ => T("系统与应用", "System and apps")
    };
    private WrapPanel ModifierOptions(Dictionary<KeyModifiers,CheckBox> destination){var row=new WrapPanel();foreach(var (modifier,name) in new[]{(KeyModifiers.Control,"Ctrl"),(KeyModifiers.Alt,"Alt"),(KeyModifiers.Shift,"Shift"),(KeyModifiers.Windows,"Win")}){var c=new CheckBox{Content=name};destination[modifier]=c;row.Children.Add(c);}return row;}
    private static KeyModifiers Modifiers(Dictionary<KeyModifiers,CheckBox> source)=>source.Where(p=>p.Value.IsChecked==true).Aggregate(KeyModifiers.None,(value,p)=>value|p.Key);
    private void UpdateRules()=>ruleGrid.ItemsSource=settings.Rules.Select(r=>new RuleRow(r,KeyboardKeys.Chord(r.Source,r.Modifiers,Chinese),KeyboardKeys.Chord(r.Target,r.TargetModifiers,Chinese))).ToArray();
    private async Task RulesChanged(){UpdateRules();await ConfigureHook();SaveSoon();}
    private async Task ConfigureHook(){if(!hookReady||closing)return;try{await hook.ConfigureAsync(enabled,settings.MappingEnabled,settings.Rules.ToArray());}catch(Exception ex){ShowError(ex.Message);}}
    private UIElement Preferences() {
        var panel=Panel();panel.Children.Add(Text(T("语言","Language"),16));
        var languages=new ComboBox{ItemsSource=new KeyValuePair<string,string>[]{new("system",T("跟随系统","System")),new("zh","简体中文"),new("en","English")},DisplayMemberPath="Value",SelectedValuePath="Key",SelectedValue=settings.Language,Width=230,HorizontalAlignment=HorizontalAlignment.Left};
        languages.SelectionChanged+=(_,_)=>{if(building)return;settings.Language=(string)languages.SelectedValue;SaveSoon();Dispatcher.InvokeAsync(()=>{Build();SetupTray();});};panel.Children.Add(languages);
        panel.Children.Add(Text(T("外观","Appearance"),16));
        var appearance=new ComboBox{ItemsSource=new KeyValuePair<string,string>[]{new("system",T("跟随系统","System")),new("light",T("浅色","Light")),new("dark",T("深色","Dark"))},DisplayMemberPath="Value",SelectedValuePath="Key",SelectedValue=settings.Appearance,Width=230,HorizontalAlignment=HorizontalAlignment.Left};
        appearance.SelectionChanged+=(_,_)=>{if(building)return;settings.Appearance=(string)appearance.SelectedValue;SaveSoon();Dispatcher.InvokeAsync(Build);};panel.Children.Add(appearance);
        panel.Children.Add(KeyBurstSettings());
        panel.Children.Add(Text(T("关闭窗口后继续在托盘运行；从托盘菜单退出。所有设置仅影响本应用。","Closing the window keeps KeyWoo in the tray. Use the tray menu to quit. Appearance settings affect this app only."),12,true));
        panel.Children.Add(MakeButton(T("打开本地数据文件夹","Open local data folder"),(_,_)=>{Directory.CreateDirectory(Settings.DataDirectory);OpenFile(Settings.DataDirectory);}));
        panel.Children.Add(MakeButton(T("重新连接声音","Reconnect audio"),(_,_)=>{
            if(audio is null){ShowError(T("录音尚未加载，请重启应用。","Recordings are unavailable. Please restart KeyWoo."));return;}
            try{audio.Restart();ClearAudioError();}catch(Exception ex){ShowAudioError(ex.Message);}
        }));
        panel.Children.Add(Text(T("声音跟随系统默认输出；切换耳机后会自动重连。","Sound follows the default Windows output and reconnects when it changes."),12,true));
        panel.Children.Add(Text("KeyWoo " + (typeof(MainWindow).Assembly.GetName().Version?.ToString(3)??"1.0.0"),12,true));
        panel.Children.Add(Text(T("Windows 键盘音效版 · 不包含音乐生成。蓝牙设备自身的播放延迟仍取决于系统与耳机。","Windows keyboard sound edition · No music generation. Bluetooth playback latency also depends on Windows and your headphones."),12,true));return panel;
    }
    private Border KeyBurstSettings() {
        var panel=new StackPanel();
        var header=new DockPanel{Margin=new Thickness(0,0,0,8)};
        keyBurstPreview=MakeButton(T("演示","Demo"),(_,_)=>keyBurst.Preview());
        AutomationProperties.SetAutomationId(keyBurstPreview,"key-burst-preview");
        DockPanel.SetDock(keyBurstPreview,Dock.Right);
        header.Children.Add(keyBurstPreview);
        header.Children.Add(Text(T("桌面律动","Desktop animation"),16));
        panel.Children.Add(header);

        var show=new CheckBox{Content=T("键阵爆破","Key Burst"),IsChecked=settings.KeyBurstEnabled};
        AutomationProperties.SetAutomationId(show,"key-burst-enabled");
        show.Click+=(_,_)=>{
            settings.KeyBurstEnabled=show.IsChecked==true;
            UpdateKeyBurst();
            SaveSoon();
        };
        panel.Children.Add(show);
        panel.Children.Add(Text(T("其他应用中的键位也会短暂发光。空格打散成碎光，回车轻轻收束。演示不发声、不计数。",
            "Key labels glow briefly across apps. Space scatters them into sparks and Return draws them together. The demo is silent and does not count keystrokes."),12,true));
        var flashes=new CheckBox{Content=T("闪光效果","Flashes"),IsChecked=settings.KeyBurstFlashes,Margin=new Thickness(0,8,0,0)};
        AutomationProperties.SetAutomationId(flashes,"key-burst-flashes");
        flashes.Click+=(_,_)=>{
            settings.KeyBurstFlashes=flashes.IsChecked==true;
            UpdateKeyBurst();
            SaveSoon();
        };
        panel.Children.Add(flashes);
        panel.Children.Add(KeyBurstSlider(T("动画幅度","Motion intensity"),"key-burst-intensity",.4,1.5,
            settings.KeyBurstIntensity,value=>settings.KeyBurstIntensity=value));
        panel.Children.Add(KeyBurstSlider(T("特效透明度","Effect opacity"),"key-burst-opacity",.25,1,
            settings.KeyBurstBrightness,value=>settings.KeyBurstBrightness=value));
        var card=Card(panel);
        card.Margin=new Thickness(0,16,0,16);
        return card;
    }
    private DockPanel KeyBurstSlider(string title,string id,double minimum,double maximum,double value,Action<double> save) {
        var row=new DockPanel{Margin=new Thickness(0,8,0,0)};
        var label=Text(title,12);label.Width=112;
        DockPanel.SetDock(label,Dock.Left);row.Children.Add(label);
        var percent=Text(value.ToString("P0"),12,true);percent.Width=56;
        DockPanel.SetDock(percent,Dock.Right);row.Children.Add(percent);
        var slider=new Slider{Minimum=minimum,Maximum=maximum,Value=value,SmallChange=.05,LargeChange=.1,Margin=new Thickness(0,0,8,0)};
        AutomationProperties.SetAutomationId(slider,id);
        AutomationProperties.SetName(slider,title);
        slider.ValueChanged+=(_,_)=>{
            save(slider.Value);
            percent.Text=slider.Value.ToString("P0");
            UpdateKeyBurst();
            SaveSoon();
        };
        row.Children.Add(slider);
        return row;
    }
    private void ApplyTheme() {
        bool dark=settings.Appearance=="dark";
        if(settings.Appearance=="system")try{dark=(int?)Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize","AppsUseLightTheme",1)==0;}catch{dark=false;}
        foreach(var (name,light,night) in new[]{("PageBrush","#F5F5F7","#17191D"),("CardBrush","#FFFFFF","#24272D"),("TextBrush","#202124","#F0F2F5"),("MutedBrush","#636A75","#ADB5C3"),("LineBrush","#DDE0E5","#414650"),("AccentBrush","#2764E7","#8BB5FF")})
            System.Windows.Application.Current.Resources[name]=new SolidColorBrush((Color)ColorConverter.ConvertFromString(dark?night:light));
        Background=Brush("PageBrush");Foreground=Brush("TextBrush");
    }
    private void Refresh() {
        int budget=1024;
        while(budget-->0&&presses.TryDequeue(out var item)){Interlocked.Decrement(ref queuedPresses);statistics.Record(item.Key,item.At);highlights[item.Key.Id]=DateTimeOffset.UtcNow;}
        foreach(var (id,button) in keyButtons)button.BorderBrush=Brush(highlights.TryGetValue(id,out var at)&&(DateTimeOffset.UtcNow-at).TotalSeconds<.16?"AccentBrush":"LineBrush");
        session.Text=T($"本次 {statistics.SessionTotal:N0} 次 · 仅保存次数",$"{statistics.SessionTotal:N0} keys this session · Counts only");
        if((DateTimeOffset.UtcNow-lastFlush).TotalSeconds>=1.5&&Interlocked.CompareExchange(ref flushing,1,0)==0) {
            lastFlush=DateTimeOffset.UtcNow;_=Task.Run(async()=>{try{await statistics.FlushAsync();}finally{Interlocked.Exchange(ref flushing,0);}});
        }
        if(Interlocked.Read(ref droppedCounts)>0)ShowError(T("输入事件过多，部分次数未保存。","The input queue overflowed; some counts were not saved."));
        if(statistics.Error is not null)ShowError(statistics.Error);
    }
    private async void ToggleEnabled(){
        if(sessionLocked&&!enabled)return;
        enabled=!enabled;
        preview?.Cancel();
        if(audio is not null)audio.Mixer.Enabled=enabled;
        UpdatePause();
        await ConfigureHook();
    }
    private void UpdatePause(){
        pause.Content=enabled?T("全部暂停","Pause all"):T("继续","Resume");
        status.Text=enabled?T("所有应用","All applications"):T("已暂停","Paused");
        UpdateKeyBurst();
    }
    private void UpdateKeyBurst(){
        bool suspended=!enabled||sessionLocked||closing;
        keyBurst.SetSuspended(suspended);
        keyBurst.Configure(settings.KeyBurstEnabled,settings.KeyBurstFlashes,settings.KeyBurstIntensity,settings.KeyBurstBrightness);
        if(keyBurstPreview is not null)keyBurstPreview.IsEnabled=!suspended;
    }
    private void SaveSoon(){saveTimer.Stop();saveTimer.Start();}
    private void ShowError(string message){currentError=message;error.Text=message;error.Visibility=Visibility.Visible;}
    private void ShowAudioError(string message){audioError=T("声音连接中断：","Audio disconnected: ")+message;ShowError(audioError);}
    private void ClearAudioError(){if(audioError is not null&&currentError==audioError){currentError=null;error.Text="";error.Visibility=Visibility.Collapsed;}audioError=null;}
    private void OpenFile(string path){try{System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path){UseShellExecute=true});}catch(Exception ex){ShowError(ex.Message);}}
    private void SetupTray() {
        tray.Text=Chinese?"键舞":"KeyWoo";
        trayIcon??=Environment.ProcessPath is string exe?System.Drawing.Icon.ExtractAssociatedIcon(exe):null;
        tray.Icon=trayIcon??System.Drawing.SystemIcons.Application;tray.Visible=true;
        tray.DoubleClick-=TrayOpen;tray.DoubleClick+=TrayOpen;
        tray.ContextMenuStrip?.Dispose();var menu=new Forms.ContextMenuStrip();menu.Items.Add(T("打开键舞","Open KeyWoo"),null,(_,_)=>Dispatcher.InvokeAsync(()=>{Show();WindowState=WindowState.Normal;Activate();}));menu.Items.Add(T("暂停 / 继续","Pause / resume"),null,(_,_)=>Dispatcher.InvokeAsync(ToggleEnabled));menu.Items.Add(T("退出","Quit"),null,(_,_)=>Dispatcher.InvokeAsync(ExitNow));tray.ContextMenuStrip=menu;
    }
    private void TrayOpen(object? sender,EventArgs e){Show();WindowState=WindowState.Normal;Activate();}
    private void SessionChanged(object sender,SessionSwitchEventArgs e)=>Dispatcher.InvokeAsync(()=>{
        if(closing)return;
        if(e.Reason==SessionSwitchReason.SessionLock&&!sessionLocked){
            sessionLocked=true;
            resumeAfterUnlock=enabled;
            if(enabled)ToggleEnabled();else UpdateKeyBurst();
            if(hookReady)_=hook.SuspendSessionAsync();
        } else if(e.Reason==SessionSwitchReason.SessionUnlock&&sessionLocked){
            sessionLocked=false;
            bool resume=resumeAfterUnlock;
            resumeAfterUnlock=false;
            if(resume&&!enabled)ToggleEnabled();else UpdateKeyBurst();
        }
    });
    private void PreferencesChanged(object sender,UserPreferenceChangedEventArgs e){if(settings.Appearance=="system")Dispatcher.InvokeAsync(Build);}
    private void ExitNow() {
        if(closing)return;closing=true;preview?.Cancel();updateTimer.Stop();saveTimer.Stop();
        keyBurst.Dispose();hook.Dispose();audio?.Dispose();
        while(presses.TryDequeue(out var item))statistics.Record(item.Key,item.At);
        try{statistics.FlushAsync().GetAwaiter().GetResult();settings.SaveAsync().GetAwaiter().GetResult();}catch{}
        SystemEvents.SessionSwitch-=SessionChanged;SystemEvents.UserPreferenceChanged-=PreferencesChanged;tray.Visible=false;tray.Dispose();trayIcon?.Dispose();System.Windows.Application.Current.Shutdown();
    }
}
