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
    private readonly SystemAudioRhythm systemAudio=new();
    private bool powerSuspended;
    private TextBlock? systemAudioStatus;
    private Button? systemAudioRetry;
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
    private readonly bool verificationOnly;
    private int queuedPresses,flushing;
    private long droppedCounts;
    private DateTimeOffset lastFlush=DateTimeOffset.MinValue;
    private TabControl? tabs;
    private string? currentError;
    private string? audioError;
    private TextBlock status=new(),error=new(),session=new();
    private Button pause=new();
    private readonly List<Button> soundPreviewButtons=[];
    private readonly Dictionary<int,Button> navigationButtons=[];
    private readonly Dictionary<int,ScrollViewer> pageScrollers=[];
    private TextBlock? pageTitle,pageSubtitle,currentSound,soundAvailability,mappingFeedback,mappingState;
    private Button? removeRule,editRule,saveRule,cancelRule;
    private InputRule? editingRule;
    private Border? errorNotice;
    private Button? keyBurstPreview;
    private CheckBox mappingCheck=new();
    private DataGrid ruleGrid=new();
    private readonly StatisticsPresentation statisticsPresentation=new();
    private StatisticsPanel? statisticsPanel;
    private ComboBox sourceKey=new(),targetKey=new();
    private readonly Dictionary<KeyModifiers,CheckBox> sourceModifiers=[],targetModifiers=[];
    private TextBox? practice;
    private bool Chinese=>settings.Language=="zh"||(settings.Language=="system"&&CultureInfo.CurrentUICulture.TwoLetterISOLanguageName=="zh");
    private string T(string zh,string en)=>Chinese?zh:en;
    private Brush Brush(string key)=>(Brush)System.Windows.Application.Current.Resources[key];
    public MainWindow():this(null,null,null) { }
    internal MainWindow(Settings? verificationSettings,StatisticsStore? verificationStatistics,SampleBank? verificationBank) {
        verificationOnly=verificationSettings is not null;
        string? loadError=null;
        settings=verificationSettings??Settings.Load(out loadError);
        soundBank=verificationBank;
        systemAudio.StateChanged+=UpdateSystemAudioState;
        statistics=verificationStatistics??new(Path.Combine(Settings.DataDirectory,"statistics.json"));
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
        if(verificationOnly)updateTimer.Stop();
        Build();
        if(verificationOnly)return;
        SetupTray();
        if(loadError is not null||statistics.Error is not null)ShowError(loadError??statistics.Error!);
        Loaded+=async(_,_)=>{if(!started){started=true;await StartAsync();}};
        Closing+=(_,e)=>{if(!closing){e.Cancel=true;Hide();}};
        SystemEvents.SessionSwitch+=SessionChanged;
        SystemEvents.PowerModeChanged+=PowerChanged;
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
            audio.Recovered+=ClearAudioError;audio.Start();UpdateSoundSummary();
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
        int previousTab=tabs?.SelectedIndex??0;
        var scrollOffsets=pageScrollers.ToDictionary(p=>p.Key,p=>p.Value.VerticalOffset);
        var previousSource=(sourceKey.SelectedItem as KeyOption)?.Key??0x14;
        var previousTarget=(targetKey.SelectedItem as KeyOption)?.Key??0x1B;
        var previousSourceModifiers=Modifiers(sourceModifiers);var previousTargetModifiers=Modifiers(targetModifiers);
        building=true;Language=XmlLanguage.GetLanguage(Chinese?"zh-CN":"en-US");Title=Chinese?"键舞":"KeyWoo";
        var previousPractice=practice?.Text??"";ApplyTheme();InterfaceStyles.Apply(this);presetButtons.Clear();keyButtons.Clear();
        soundPreviewButtons.Clear();navigationButtons.Clear();pageScrollers.Clear();
        var shell=new Grid{Background=Brush("PageBrush")};shell.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(184)});shell.ColumnDefinitions.Add(new ColumnDefinition());
        var sidebar=new DockPanel{Background=Brush("SidebarBrush"),Margin=new Thickness(0)};
        var brand=new StackPanel{Margin=new Thickness(22,28,18,30)};
        brand.Children.Add(new TextBlock{Text=Title,FontSize=23,FontWeight=FontWeights.SemiBold,Foreground=Brush("TextBrush")});
        brand.Children.Add(Text(T("让敲击更有手感","Make every key feel good"),11,true));
        DockPanel.SetDock(brand,Dock.Top);sidebar.Children.Add(brand);
        var footer=new StackPanel{Margin=new Thickness(18,12,14,20)};
        status=Text("",12,true);status.Margin=new Thickness(0,0,0,7);footer.Children.Add(status);
        footer.Children.Add(Text(T("仅保存按键次数","Only key counts are stored"),10,true));
        DockPanel.SetDock(footer,Dock.Bottom);sidebar.Children.Add(footer);
        var navigation=new StackPanel{Margin=new Thickness(12,0,12,0)};
        foreach(var (index,label) in new[]{(0,T("音效","Sounds")),(2,T("改键","Remapping")),(1,T("统计","Statistics")),(3,T("偏好设置","Preferences"))}) {
            var item=MakeButton(label,(_,_)=>{if(tabs is not null)tabs.SelectedIndex=index;});
            item.HorizontalContentAlignment=HorizontalAlignment.Left;item.MinHeight=42;item.Margin=new Thickness(0,0,0,6);item.Padding=new Thickness(14,9,12,9);
            AutomationProperties.SetAutomationId(item,"navigation-"+index);navigationButtons[index]=item;navigation.Children.Add(item);
        }
        sidebar.Children.Add(navigation);shell.Children.Add(sidebar);
        var workspace=new DockPanel{Margin=new Thickness(26,24,26,0)};Grid.SetColumn(workspace,1);shell.Children.Add(workspace);
        var header=new DockPanel{Margin=new Thickness(0,0,0,18)};
        pause=MakeButton("",(_,_)=>ToggleEnabled());pause.MinWidth=104;pause.Margin=new Thickness(16,0,0,0);pause.VerticalAlignment=VerticalAlignment.Center;
        AutomationProperties.SetAutomationId(pause,"pause-all");
        pause.ToolTip=T("暂停音效、统计、桌面律动与改键。","Pauses sounds, statistics, desktop animation and remapping.");
        DockPanel.SetDock(pause,Dock.Right);header.Children.Add(pause);
        var heading=new StackPanel();pageTitle=Text("",24);AutomationProperties.SetAutomationId(pageTitle,"workspace-page-title");pageTitle.FontWeight=FontWeights.SemiBold;heading.Children.Add(pageTitle);
        pageSubtitle=Text("",12,true);pageSubtitle.Margin=new Thickness(0,5,0,0);heading.Children.Add(pageSubtitle);header.Children.Add(heading);
        DockPanel.SetDock(header,Dock.Top);workspace.Children.Add(header);
        error=Text("",12);error.TextWrapping=TextWrapping.Wrap;
        var errorRow=new DockPanel();var dismiss=MakeButton(T("关闭","Dismiss"),(_,_)=>{currentError=null;if(errorNotice is not null)errorNotice.Visibility=Visibility.Collapsed;});
        dismiss.Padding=new Thickness(9,4,9,4);dismiss.Margin=new Thickness(12,0,0,0);DockPanel.SetDock(dismiss,Dock.Right);errorRow.Children.Add(dismiss);errorRow.Children.Add(error);
        errorNotice=new Border{Child=errorRow,Padding=new Thickness(12),Background=Brush("SelectedBrush"),CornerRadius=new CornerRadius(10),Margin=new Thickness(0,0,0,12),Visibility=Visibility.Collapsed};
        DockPanel.SetDock(errorNotice,Dock.Bottom);workspace.Children.Add(errorNotice);
        session=Text("",11,true);session.Margin=new Thickness(0,10,0,12);DockPanel.SetDock(session,Dock.Bottom);workspace.Children.Add(session);
        tabs=new TabControl{Background=Brush("PageBrush"),BorderThickness=new Thickness(0)};
        var host=new FrameworkElementFactory(typeof(ContentPresenter));
        host.SetBinding(ContentPresenter.ContentProperty,new Binding(nameof(TabControl.SelectedContent)){RelativeSource=new RelativeSource(RelativeSourceMode.TemplatedParent)});
        tabs.Template=new ControlTemplate(typeof(TabControl)){VisualTree=host};
        tabs.Items.Add(new TabItem{Header=T("音效","Sounds"),Content=PageScroll(0,Sounds())});
        tabs.Items.Add(new TabItem{Header=T("统计","Statistics"),Content=PageScroll(1,Statistics())});
        tabs.Items.Add(new TabItem{Header=T("改键","Remapping"),Content=PageScroll(2,Mapping())});
        tabs.Items.Add(new TabItem{Header=T("偏好设置","Preferences"),Content=PageScroll(3,Preferences())});
        tabs.SelectionChanged+=(_,e)=>{if(e.Source==tabs)UpdateNavigation();};
        tabs.SelectedIndex=Math.Clamp(previousTab,0,3);workspace.Children.Add(tabs);Content=shell;
        if(practice is not null)practice.Text=previousPractice;
        sourceKey.SelectedValue=previousSource;targetKey.SelectedValue=previousTarget;
        foreach(var (modifier,check) in sourceModifiers)check.IsChecked=previousSourceModifiers.HasFlag(modifier);
        foreach(var (modifier,check) in targetModifiers)check.IsChecked=previousTargetModifiers.HasFlag(modifier);
        if(currentError is not null)ShowError(currentError);building=false;UpdatePause();UpdateNavigation();UpdatePresets();statisticsPanel?.RefreshIfNeeded(true);
        Dispatcher.InvokeAsync(()=>{foreach(var (index,offset) in scrollOffsets)if(pageScrollers.TryGetValue(index,out var scroller))scroller.ScrollToVerticalOffset(offset);},DispatcherPriority.Loaded);
    }
    private void UpdateNavigation() {
        int selected=tabs?.SelectedIndex??0;
        foreach(var (index,button) in navigationButtons) {
            button.Background=Brush(index==selected?"SelectedBrush":"SidebarBrush");
            button.BorderBrush=Brush(index==selected?"SelectedBrush":"SidebarBrush");
            button.Foreground=Brush(index==selected?"AccentBrush":"MutedBrush");
            button.FontWeight=index==selected?FontWeights.SemiBold:FontWeights.Normal;
        }
        if(pageTitle is not null)pageTitle.Text=selected switch{1=>T("按键统计","Key statistics"),2=>T("改键","Remapping"),3=>T("偏好设置","Preferences"),_=>T("键盘音效","Keyboard sounds")};
        if(pageSubtitle is not null)pageSubtitle.Text=selected switch{1=>T("查看你的打字节奏与常用按键","Explore your typing activity and most-used keys"),2=>T("把常用操作放在顺手的位置","Put everyday actions within easy reach"),3=>T("按你的习惯，调整键舞","Make KeyWoo feel at home"),_=>T("选择喜欢的声音，边打字边试听","Find a sound you enjoy, then try it as you type")};
    }
    private ScrollViewer PageScroll(int index,UIElement child) {
        var scroll=new ScrollViewer{Content=child,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled,Padding=new Thickness(0,0,8,4)};
        pageScrollers[index]=scroll;return scroll;
    }
    private TextBlock Text(string content,double size=14,bool muted=false)=>new(){Text=content,FontSize=size,Foreground=Brush(muted?"MutedBrush":"TextBrush"),TextWrapping=TextWrapping.Wrap};
    private StackPanel Panel()=>new(){Margin=new Thickness(0)};
    private Button MakeButton(string title,RoutedEventHandler click) {var b=new Button{Content=title};b.Click+=click;return b;}
    private Border Card(UIElement child)=>new(){Child=child,Background=Brush("CardBrush"),BorderBrush=Brush("LineBrush"),BorderThickness=new Thickness(1),Padding=new Thickness(18),CornerRadius=new CornerRadius(12),Margin=new Thickness(0,0,0,16)};
    private Button Help(string message) {
        var button=MakeButton("ⓘ",(_,_)=>MessageBox.Show(this,message,T("详细说明","Details"),MessageBoxButton.OK,MessageBoxImage.Information));
        button.ToolTip=message;button.Padding=new Thickness(5,1,5,1);button.Margin=new Thickness(6,0,0,0);button.MinWidth=26;
        AutomationProperties.SetName(button,T("详细说明","Details"));return button;
    }
    private DockPanel SectionTitle(string title,string? detail=null) {
        var row=new DockPanel{Margin=new Thickness(0,0,0,12)};
        if(detail is not null){var help=Help(detail);DockPanel.SetDock(help,Dock.Right);row.Children.Add(help);}
        var label=Text(title,15);label.FontWeight=FontWeights.SemiBold;row.Children.Add(label);return row;
    }
    private sealed record SoundGroup(SoundCategory Category,string Label,SoundPreset[] Presets);
    private UIElement Sounds() {
        var panel=Panel();var grid=new UniformGrid{Columns=3};
        var category=new ComboBox{DisplayMemberPath=nameof(SoundGroup.Label),Width=220,HorizontalAlignment=HorizontalAlignment.Left,Margin=new Thickness(0,0,0,0)};
        AutomationProperties.SetAutomationId(category,"sound-category");
        var current=Panel();
        current.Children.Add(SectionTitle(T("当前音色","Current sound")));
        currentSound=Text("",20);currentSound.FontWeight=FontWeights.SemiBold;currentSound.Margin=new Thickness(0,0,0,12);current.Children.Add(currentSound);
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
                button.Content=label;button.MinHeight=78;button.Margin=new Thickness(0,0,8,8);button.HorizontalContentAlignment=HorizontalAlignment.Left;
                button.ToolTip=T("选择并试听此音色。暂停时只切换音色。","Select and preview this sound. While paused, only the selection changes.");
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
        current.Children.Add(versionRow);
        current.Children.Add(VolumeControl());
        soundAvailability=Text("",11,true);current.Children.Add(soundAvailability);panel.Children.Add(Card(current));
        var catalog=Panel();var catalogHeader=new DockPanel{Margin=new Thickness(0,0,0,14)};
        DockPanel.SetDock(category,Dock.Right);catalogHeader.Children.Add(category);
        var catalogTitle=Text(T("音色库","Sound library"),15);catalogTitle.FontWeight=FontWeights.SemiBold;catalogTitle.VerticalAlignment=VerticalAlignment.Center;catalogHeader.Children.Add(catalogTitle);
        catalog.Children.Add(catalogHeader);catalog.Children.Add(grid);panel.Children.Add(Card(catalog));
        var practicePanel=Panel();var practiceHeader=SectionTitle(T("试打","Try typing"));
        var clearPractice=MakeButton(T("清空","Clear"),(_,_)=>{if(practice is not null)practice.Clear();});clearPractice.Padding=new Thickness(9,4,9,4);clearPractice.Margin=new Thickness(0);
        DockPanel.SetDock(clearPractice,Dock.Right);practiceHeader.Children.Insert(0,clearPractice);practicePanel.Children.Add(practiceHeader);
        practicePanel.Children.Add(Text(T("在这里打几个字，感受当前音色。","Type a few words here to try your current sound."),12,true));
        practice=new TextBox{AcceptsReturn=true,MinHeight=78,MaxHeight=180,FontSize=14,Margin=new Thickness(0,12,0,12),VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
        AutomationProperties.SetAutomationId(practice,"practice-input");practicePanel.Children.Add(practice);
        var keyboardPanel=Panel();
        foreach(var row in new[]{new[]{(81,16),(87,17),(69,18),(82,19),(84,20),(89,21),(85,22),(73,23),(79,24),(80,25)},new[]{(65,30),(83,31),(68,32),(70,33),(71,34),(72,35),(74,36),(75,37),(76,38)},new[]{(90,44),(88,45),(67,46),(86,47),(66,48),(78,49),(77,50)},new[]{(9,15),(32,57),(13,28),(8,14)}}) {
            var keys=new UniformGrid{Columns=row.Length,Margin=new Thickness(0,0,0,6)};
            foreach(var (vk,scan) in row) {
                var key=new PhysicalKey(vk,scan);var b=MakeButton(KeyboardKeys.Name(vk,Chinese),async(_,_)=>await PreviewKey(key.MacCode));soundPreviewButtons.Add(b);b.Padding=new Thickness(4,8,4,8);b.FontSize=12;b.Margin=new Thickness(0,0,5,0);keyButtons[key.Id]=b;keys.Children.Add(b);
            }
            keyboardPanel.Children.Add(keys);
        }
        keyboardPanel.Children.Add(Text(T("点击键帽试听不计入统计。","Clicking a key previews it without counting."),11,true));
        var keyboard=new Expander{Header=T("屏幕键盘","On-screen keyboard"),Content=keyboardPanel,Margin=new Thickness(0,0,0,0)};
        practicePanel.Children.Add(keyboard);panel.Children.Add(Card(practicePanel));
        var sources=new Expander{Header=T("声音来源","Sound sources")};var sourcePanel=Panel();sourcePanel.Margin=new Thickness(0,12,0,0);
        sourcePanel.Children.Add(Text(T("键盘实录、实录拟音和趣味合成与 macOS 版共用采样。部分录音在同类键之间复用。","Windows and macOS share the keyboard recordings, recorded foley and synthesized sounds. Some packs reuse recordings across similar keys."),12,true));
        sourcePanel.Children.Add(MakeButton(T("查看来源与许可证","View sources and licenses"),(_,_)=>OpenFile(Path.Combine(AppContext.BaseDirectory,"Assets","KeyboardSounds","THIRD-PARTY-NOTICES.md"))));sources.Content=sourcePanel;panel.Children.Add(sources);return panel;
    }

    private DockPanel VolumeControl() {
        var panel = new DockPanel { Margin = new Thickness(0, 0, 0, 18) };
        var previewButton = MakeButton(T("试听", "Preview"), async (_, _) => await PreviewSequence());
        soundPreviewButtons.Add(previewButton);AutomationProperties.SetAutomationId(previewButton,"sound-preview");
        DockPanel.SetDock(previewButton, Dock.Right);
        panel.Children.Add(previewButton);
        var restore = MakeButton(T("推荐", "Recommended"), (_, _) => { });
        restore.ToolTip = T("恢复推荐音量（6.25%）", "Restore recommended volume (6.25%)");
        AutomationProperties.SetAutomationId(restore,"keyboard-volume-reset");
        DockPanel.SetDock(restore,Dock.Right);
        panel.Children.Add(restore);
        string title = T("音量", "Volume");
        string Percent(double stored) => ControlScale.KeyboardVolume.DisplayValue(stored).ToString("0.##%",CultureInfo.CurrentCulture);
        var valueLabel = Text(Percent(settings.Volume), 13, true);
        valueLabel.Width = 72;
        valueLabel.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(valueLabel, Dock.Right);
        panel.Children.Add(valueLabel);
        var label = Text(title);
        label.Width = 72;
        label.VerticalAlignment = VerticalAlignment.Center;
        label.ToolTip = T("0% 到 100% 均匀调节；0% 静音并保留统计。", "A linear 0–100% scale. Zero mutes audio and keeps statistics active.");
        DockPanel.SetDock(label, Dock.Left);
        panel.Children.Add(label);
        var slider = new Slider {
            Minimum = 0, Maximum = 1, SmallChange = .01, LargeChange = .05,
            Value = ControlScale.KeyboardVolume.DisplayValue(settings.Volume),
            TickPlacement = TickPlacement.None, TickFrequency = .25,
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 18, 0)
        };
        AutomationProperties.SetAutomationId(slider, "keyboard-volume");
        AutomationProperties.SetName(slider, $"{title} {valueLabel.Text}");
        slider.ValueChanged += (_, _) => {
            if (building) return;
            settings.Volume = ControlScale.KeyboardVolume.StoredValue(slider.Value);
            valueLabel.Text = Percent(settings.Volume);
            AutomationProperties.SetName(slider, $"{title} {valueLabel.Text}");
            if (audio is not null) audio.Mixer.Volume = (float)settings.Volume;
            SaveSoon();
        };
        restore.Click+=(_,_)=>slider.Value=ControlScale.KeyboardVolume.DisplayValue(1);
        panel.Children.Add(slider);
        return panel;
    }
    private string SoundCategoryName(SoundCategory category)=>category switch {
        SoundCategory.RecordedKeyboard=>T("键盘实录","Recorded keyboards"),
        SoundCategory.RecordedFoley=>T("实录拟音","Recorded foley"),
        _=>T("趣味合成","Synthesized sounds")
    };
    private string PresetName(SoundPreset preset)=>preset.Id switch {"topre"=>T("Topre 静电容","Topre"),"oreo"=>"Everglide Oreo","panda"=>"Holy Panda","purple"=>T("Everglide 水晶紫","Everglide Crystal Purple"),"red"=>T("Cherry 红轴 · ABS","Cherry Red · ABS"),"blue"=>T("Cherry 青轴 · ABS","Cherry Blue · ABS"),"brown"=>T("Cherry 茶轴 · PBT","Cherry Brown · PBT"),"black"=>T("Cherry 黑轴 · PBT","Cherry Black · PBT"),"bluePBT"=>T("Cherry 青轴 · PBT","Cherry Blue · PBT"),"brownABS"=>T("Cherry 茶轴 · ABS","Cherry Brown · ABS"),"blackABS"=>T("Cherry 黑轴 · ABS","Cherry Black · ABS"),"typewriter"=>T("打字机","Typewriter"),"bubble"=>T("泡泡","Bubble"),"woodblock"=>T("木鱼","Woodblock"),"paper"=>T("纸笺","Paper"),"raindrop"=>T("水滴","Raindrop"),"brick"=>T("积木","Brick"),"arcade"=>T("街机","Arcade"),"laser"=>T("激光","Laser"),"mahjong"=>T("麻将","Mahjong"),_=>Chinese?preset.TitleZh??preset.Title:preset.Title};
    private void UpdatePresets(){foreach(var (id,b) in presetButtons){b.BorderBrush=Brush(id==settings.Preset?"AccentBrush":"LineBrush");b.Background=Brush(id==settings.Preset?"SelectedBrush":"CardBrush");b.BorderThickness=new Thickness(id==settings.Preset?2:1);}UpdateSoundSummary();}
    private void UpdateSoundSummary() {
        var selected=soundBank?.Presets.FirstOrDefault(p=>p.Id==settings.Preset);
        if(currentSound is not null)currentSound.Text=selected is null?T("正在加载音色…","Loading sounds…"):PresetName(selected);
        bool available=enabled&&!sessionLocked&&audio is not null;
        foreach(var button in soundPreviewButtons){button.IsEnabled=available;button.ToolTip=available?null:T("继续运行后即可试听。","Resume KeyWoo to preview sounds.");}
        if(soundAvailability is not null)soundAvailability.Text=!enabled?T("已暂停。继续后可试听与记录按键。","Paused. Resume to preview sounds and count key presses.")
            :audio is null?T("正在连接声音…","Connecting audio…")
            :T("音色选择后立即生效 · 试打文字不会保存","Sound changes apply immediately · Practice text is never saved");
    }
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
    private UIElement Statistics() => statisticsPanel=new StatisticsPanel(statistics,Chinese,statisticsPresentation,ShowError);
    private sealed record KeyOption(int Key,string Name,string Category);
    private sealed record RuleRow(InputRule Rule,string Source,string Target);
    private UIElement Mapping() {
        var panel=Panel();var activation=Panel();
        mappingCheck=new CheckBox{Content=T("启用改键","Enable remapping"),IsChecked=settings.MappingEnabled,FontWeight=FontWeights.SemiBold};
        AutomationProperties.SetAutomationId(mappingCheck,"remapping-enabled");
        mappingCheck.Checked+=async(_,_)=>{if(building)return;settings.MappingEnabled=true;await ConfigureHook();UpdateMappingState();SaveSoon();};
        mappingCheck.Unchecked+=async(_,_)=>{if(building)return;settings.MappingEnabled=false;await ConfigureHook();UpdateMappingState();SaveSoon();};
        var activationHeader=new DockPanel();var help=Help(T("这是电脑侧的软件映射，不会修改键盘固件。映射只在键舞运行且未暂停时生效。音效和统计跟随原始物理键。Fn 常由键盘固件处理；可用 Ctrl+Alt 等组合键替代。系统安全快捷键与管理员窗口可能无法改键。","This is software remapping on your computer; keyboard firmware stays unchanged. Rules apply while KeyWoo is running and not paused. Sounds and counts follow the physical key. Fn is often handled by firmware; use a Ctrl+Alt shortcut as an alternative. Secure shortcuts and administrator windows may not be remappable."));
        DockPanel.SetDock(help,Dock.Right);activationHeader.Children.Add(help);activationHeader.Children.Add(mappingCheck);activation.Children.Add(activationHeader);
        mappingState=Text("",12,true);mappingState.Margin=new Thickness(0,5,0,0);activation.Children.Add(mappingState);panel.Children.Add(Card(activation));
        sourceModifiers.Clear();targetModifiers.Clear();
        var editor=Panel();editor.Children.Add(SectionTitle(T("设置映射","Set up a mapping")));
        var keys=new Grid();keys.ColumnDefinitions.Add(new ColumnDefinition());keys.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(34)});keys.ColumnDefinitions.Add(new ColumnDefinition());
        var sourcePanel=Panel();sourcePanel.Children.Add(Text(T("按下","When pressed"),12,true));sourceKey=KeyChooser(0x14);sourceKey.MinWidth=0;sourceKey.HorizontalAlignment=HorizontalAlignment.Stretch;sourcePanel.Children.Add(sourceKey);sourcePanel.Children.Add(ModifierOptions(sourceModifiers));
        AutomationProperties.SetAutomationId(sourceKey,"remapping-source");keys.Children.Add(sourcePanel);
        var arrow=Text("→",21,true);arrow.HorizontalAlignment=HorizontalAlignment.Center;arrow.VerticalAlignment=VerticalAlignment.Center;Grid.SetColumn(arrow,1);keys.Children.Add(arrow);
        var targetPanel=Panel();targetPanel.Children.Add(Text(T("改为","Send instead"),12,true));targetKey=KeyChooser(0x1B);targetKey.MinWidth=0;targetKey.HorizontalAlignment=HorizontalAlignment.Stretch;targetPanel.Children.Add(targetKey);targetPanel.Children.Add(ModifierOptions(targetModifiers));
        AutomationProperties.SetAutomationId(targetKey,"remapping-target");Grid.SetColumn(targetPanel,2);keys.Children.Add(targetPanel);editor.Children.Add(keys);
        var buttons=new WrapPanel{Margin=new Thickness(0,12,0,0)};
        saveRule=MakeButton(T("添加映射","Add mapping"),async(_,_)=>{
            if(sourceKey.SelectedItem is not KeyOption source||targetKey.SelectedItem is not KeyOption target)return;
            var rule=new InputRule(source.Key,Modifiers(sourceModifiers),target.Key,Modifiers(targetModifiers));
            if(rule.Source==rule.Target&&rule.Modifiers==rule.TargetModifiers){MappingFeedback(T("请选择不同的目标按键。","Choose a different target key."));return;}
            var existing=settings.Rules.FirstOrDefault(r=>r.Source==rule.Source&&r.Modifiers==rule.Modifiers);
            if(existing is not null&&existing!=editingRule) {
                if(existing==rule){MappingFeedback(T("这条映射已经存在。","This mapping already exists."));return;}
                if(MessageBox.Show(this,T("这个组合已有映射，要替换吗？","This shortcut already has a mapping. Replace it?"),T("替换映射","Replace mapping"),MessageBoxButton.YesNo,MessageBoxImage.Question)!=MessageBoxResult.Yes)return;
            }
            if(editingRule is not null)settings.Rules.Remove(editingRule);
            settings.Rules.RemoveAll(r=>r.Source==rule.Source&&r.Modifiers==rule.Modifiers);settings.Rules.Add(rule);EndRuleEditing();await RulesChanged();
            MappingFeedback(settings.MappingEnabled&&enabled?T("映射已保存并生效。","Mapping saved and active."):T("映射已保存。启用改键并继续运行后生效。","Mapping saved. Enable remapping and resume KeyWoo to apply it."));
        });
        AutomationProperties.SetAutomationId(saveRule,"remapping-save");buttons.Children.Add(saveRule);
        cancelRule=MakeButton(T("取消编辑","Cancel editing"),(_,_)=>{EndRuleEditing();MappingFeedback("");});AutomationProperties.SetAutomationId(cancelRule,"remapping-cancel");cancelRule.Visibility=editingRule is null?Visibility.Collapsed:Visibility.Visible;buttons.Children.Add(cancelRule);
        if(editingRule is not null)saveRule.Content=T("保存修改","Save changes");
        editor.Children.Add(buttons);mappingFeedback=Text("",12,true);mappingFeedback.Margin=new Thickness(0,10,0,0);mappingFeedback.Visibility=Visibility.Collapsed;
        AutomationProperties.SetAutomationId(mappingFeedback,"remapping-feedback");editor.Children.Add(mappingFeedback);panel.Children.Add(Card(editor));
        var saved=Panel();var savedHeader=SectionTitle(T("已保存的映射","Saved mappings"));
        removeRule=MakeButton(T("删除","Delete"),async(_,_)=>{
            if(ruleGrid.SelectedItem is not RuleRow row)return;
            if(MessageBox.Show(this,T($"删除映射「{row.Source} → {row.Target}」？",$"Delete the mapping {row.Source} → {row.Target}?"),T("删除映射","Delete mapping"),MessageBoxButton.YesNo,MessageBoxImage.Question)!=MessageBoxResult.Yes)return;
            settings.Rules.Remove(row.Rule);if(editingRule==row.Rule)EndRuleEditing();await RulesChanged();MappingFeedback(T("映射已删除。","Mapping deleted."));
        });AutomationProperties.SetAutomationId(removeRule,"remapping-delete");removeRule.IsEnabled=false;removeRule.Padding=new Thickness(9,4,9,4);removeRule.Margin=new Thickness(8,0,0,0);DockPanel.SetDock(removeRule,Dock.Right);savedHeader.Children.Insert(0,removeRule);
        editRule=MakeButton(T("编辑","Edit"),(_,_)=>EditSelectedRule());AutomationProperties.SetAutomationId(editRule,"remapping-edit");editRule.IsEnabled=false;editRule.Padding=new Thickness(9,4,9,4);editRule.Margin=new Thickness(8,0,0,0);DockPanel.SetDock(editRule,Dock.Right);savedHeader.Children.Insert(1,editRule);saved.Children.Add(savedHeader);
        ruleGrid=new DataGrid{IsReadOnly=true,AutoGenerateColumns=false,CanUserAddRows=false,CanUserDeleteRows=false,SelectionMode=DataGridSelectionMode.Single,SelectionUnit=DataGridSelectionUnit.FullRow,HeadersVisibility=DataGridHeadersVisibility.Column,GridLinesVisibility=DataGridGridLinesVisibility.None,RowHeight=42,MinHeight=120,MaxHeight=300,Background=Brush("CardBrush"),Foreground=Brush("TextBrush"),RowBackground=Brush("CardBrush"),AlternatingRowBackground=Brush("RaisedBrush"),BorderThickness=new Thickness(0)};
        AutomationProperties.SetAutomationId(ruleGrid,"remapping-rules");
        ruleGrid.Columns.Add(new DataGridTextColumn{Header=T("按下","When pressed"),Binding=new Binding(nameof(RuleRow.Source)),Width=new DataGridLength(1,DataGridLengthUnitType.Star)});
        ruleGrid.Columns.Add(new DataGridTextColumn{Header=T("改为","Send instead"),Binding=new Binding(nameof(RuleRow.Target)),Width=new DataGridLength(1,DataGridLengthUnitType.Star)});
        ruleGrid.SelectionChanged+=(_,_)=>{if(removeRule is not null)removeRule.IsEnabled=ruleGrid.SelectedItem is RuleRow;if(editRule is not null)editRule.IsEnabled=ruleGrid.SelectedItem is RuleRow;};
        ruleGrid.MouseDoubleClick+=(_,_)=>EditSelectedRule();saved.Children.Add(ruleGrid);
        var media=new Expander{Header=T("媒体快捷键模板","Media shortcut template"),Margin=new Thickness(0,12,0,0)};var mediaContent=Panel();mediaContent.Margin=new Thickness(0,10,0,0);
        mediaContent.Children.Add(Text(T("Ctrl+Alt：J 上一首 · K 播放/暂停 · L 下一首 · U/I 音量 · M 静音。","Ctrl+Alt: J previous · K play/pause · L next · U/I volume · M mute."),12,true));
        var addMedia=MakeButton(T("添加模板","Add template"),async(_,_)=>{
            bool conflicts=InputRouter.MediaShortcuts.Any(rule=>settings.Rules.Any(r=>r.Source==rule.Source&&r.Modifiers==rule.Modifiers&&r!=rule));
            if(conflicts&&MessageBox.Show(this,T("模板会替换相同组合键的已有映射，继续吗？","This template replaces existing mappings for the same shortcuts. Continue?"),T("添加模板","Add template"),MessageBoxButton.YesNo,MessageBoxImage.Question)!=MessageBoxResult.Yes)return;
            foreach(var rule in InputRouter.MediaShortcuts){settings.Rules.RemoveAll(r=>r.Source==rule.Source&&r.Modifiers==rule.Modifiers);settings.Rules.Add(rule);}
            await RulesChanged();MappingFeedback(T("媒体快捷键模板已添加。","Media shortcut template added."));
        });addMedia.Margin=new Thickness(0,10,0,0);addMedia.HorizontalAlignment=HorizontalAlignment.Left;mediaContent.Children.Add(addMedia);media.Content=mediaContent;saved.Children.Add(media);panel.Children.Add(Card(saved));
        UpdateRules();UpdateMappingState();return panel;
    }
    private void EditSelectedRule() {
        if(ruleGrid.SelectedItem is not RuleRow row)return;
        editingRule=row.Rule;sourceKey.SelectedValue=row.Rule.Source;targetKey.SelectedValue=row.Rule.Target;
        foreach(var (modifier,check) in sourceModifiers)check.IsChecked=row.Rule.Modifiers.HasFlag(modifier);
        foreach(var (modifier,check) in targetModifiers)check.IsChecked=row.Rule.TargetModifiers.HasFlag(modifier);
        if(saveRule is not null)saveRule.Content=T("保存修改","Save changes");if(cancelRule is not null)cancelRule.Visibility=Visibility.Visible;
        MappingFeedback(T("修改后点「保存修改」；取消不会改变已保存的映射。","Choose Save changes to apply your edits. Cancel keeps the saved mapping unchanged."));sourceKey.BringIntoView();sourceKey.Focus();
    }
    private void EndRuleEditing(){editingRule=null;if(saveRule is not null)saveRule.Content=T("添加映射","Add mapping");if(cancelRule is not null)cancelRule.Visibility=Visibility.Collapsed;}
    private void MappingFeedback(string message){if(mappingFeedback is null)return;mappingFeedback.Text=message;mappingFeedback.Visibility=string.IsNullOrEmpty(message)?Visibility.Collapsed:Visibility.Visible;}
    private void UpdateMappingState(){if(mappingState is not null)mappingState.Text=!settings.MappingEnabled?T("已关闭 · 可以先编辑并保存规则","Off · You can still edit and save rules")
        :!enabled?T("已暂停 · 继续运行后恢复改键","Paused · Resume KeyWoo to apply your mappings")
        :!hookReady?T("正在连接键盘…","Connecting to the keyboard…")
        :T($"已启用 · {settings.Rules.Count} 条映射",$"Active · {settings.Rules.Count} mappings");}
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
    private WrapPanel ModifierOptions(Dictionary<KeyModifiers,CheckBox> destination){var row=new WrapPanel();foreach(var (modifier,name) in new[]{(KeyModifiers.Control,"Ctrl"),(KeyModifiers.Alt,"Alt"),(KeyModifiers.Shift,"Shift"),(KeyModifiers.Windows,"Win")}){var c=new CheckBox{Content=name};AutomationProperties.SetAutomationId(c,(ReferenceEquals(destination,sourceModifiers)?"source-":"target-")+name.ToLowerInvariant());destination[modifier]=c;row.Children.Add(c);}return row;}
    private static KeyModifiers Modifiers(Dictionary<KeyModifiers,CheckBox> source)=>source.Where(p=>p.Value.IsChecked==true).Aggregate(KeyModifiers.None,(value,p)=>value|p.Key);
    private void UpdateRules()=>ruleGrid.ItemsSource=settings.Rules.Select(r=>new RuleRow(r,KeyboardKeys.Chord(r.Source,r.Modifiers,Chinese),KeyboardKeys.Chord(r.Target,r.TargetModifiers,Chinese))).ToArray();
    private async Task RulesChanged(){UpdateRules();await ConfigureHook();UpdateMappingState();SaveSoon();}
    private async Task ConfigureHook(){if(!hookReady||closing)return;try{await hook.ConfigureAsync(enabled,settings.MappingEnabled,settings.Rules.ToArray());}catch(Exception ex){ShowError(ex.Message);}}
    private UIElement Preferences() {
        var panel=Panel();var general=Panel();general.Children.Add(SectionTitle(T("通用","General")));
        var languages=new ComboBox{ItemsSource=new KeyValuePair<string,string>[]{new("system",T("跟随系统","System")),new("zh","简体中文"),new("en","English")},DisplayMemberPath="Value",SelectedValuePath="Key",SelectedValue=settings.Language,Width=200,HorizontalAlignment=HorizontalAlignment.Right};
        AutomationProperties.SetAutomationId(languages,"app-language");
        languages.SelectionChanged+=(_,_)=>{if(building||languages.SelectedValue is not string language)return;settings.Language=language;SaveSoon();Dispatcher.InvokeAsync(()=>{Build();if(!verificationOnly)SetupTray();});};general.Children.Add(PreferenceRow(T("语言","Language"),languages));
        var appearance=new ComboBox{ItemsSource=new KeyValuePair<string,string>[]{new("system",T("跟随系统","System")),new("light",T("浅色","Light")),new("dark",T("深色","Dark"))},DisplayMemberPath="Value",SelectedValuePath="Key",SelectedValue=settings.Appearance,Width=200,HorizontalAlignment=HorizontalAlignment.Right};
        AutomationProperties.SetAutomationId(appearance,"app-appearance");
        appearance.SelectionChanged+=(_,_)=>{if(building||appearance.SelectedValue is not string value)return;settings.Appearance=value;SaveSoon();Dispatcher.InvokeAsync(Build);};general.Children.Add(PreferenceRow(T("外观","Appearance"),appearance));panel.Children.Add(Card(general));
        panel.Children.Add(KeyBurstSettings());
        var audioPanel=Panel();audioPanel.Children.Add(SectionTitle(T("声音输出","Audio output"),T("声音跟随 Windows 默认输出设备，切换耳机后会自动重连。蓝牙播放延迟取决于系统和耳机。","Sound follows the default Windows output and reconnects when it changes. Bluetooth latency depends on Windows and your headphones.")));
        var reconnect=MakeButton(T("重新连接声音","Reconnect audio"),(_,_)=>{
            if(audio is null){ShowError(T("录音尚未加载，请重启应用。","Recordings are unavailable. Please restart KeyWoo."));return;}
            try{audio.Restart();ClearAudioError();}catch(Exception ex){ShowAudioError(ex.Message);}
        });reconnect.Margin=new Thickness(0);audioPanel.Children.Add(PreferenceRow(T("跟随系统默认设备","Use the default system device"),reconnect));panel.Children.Add(Card(audioPanel));
        var appPanel=Panel();appPanel.Children.Add(SectionTitle(T("关于键舞","About KeyWoo")));
        appPanel.Children.Add(Text("KeyWoo " + (typeof(MainWindow).Assembly.GetName().Version?.ToString(3)??"1.0.0"),13));
        appPanel.Children.Add(Text(T("关闭窗口后会继续运行，可从系统托盘打开或退出。","KeyWoo keeps running when its window closes. Open or quit it from the system tray."),12,true));
        var data=MakeButton(T("打开数据文件夹","Open data folder"),(_,_)=>{Directory.CreateDirectory(Settings.DataDirectory);OpenFile(Settings.DataDirectory);});data.HorizontalAlignment=HorizontalAlignment.Left;data.Margin=new Thickness(0,12,0,0);appPanel.Children.Add(data);panel.Children.Add(Card(appPanel));return panel;
    }
    private DockPanel PreferenceRow(string label,UIElement control) {
        var row=new DockPanel{Margin=new Thickness(0,6,0,6),LastChildFill=true};DockPanel.SetDock(control,Dock.Right);row.Children.Add(control);
        var text=Text(label,13);text.VerticalAlignment=VerticalAlignment.Center;text.Margin=new Thickness(0,0,16,0);row.Children.Add(text);return row;
    }
    private Border KeyBurstSettings() {
        var panel=new StackPanel();
        var header=new DockPanel{Margin=new Thickness(0,0,0,8)};
        keyBurstPreview=MakeButton(T("演示","Demo"),(_,_)=>keyBurst.Preview());
        AutomationProperties.SetAutomationId(keyBurstPreview,"key-burst-preview");
        DockPanel.SetDock(keyBurstPreview,Dock.Right);
        header.Children.Add(keyBurstPreview);
        var animationTitle=Text(T("桌面律动","Desktop animation"),15);animationTitle.FontWeight=FontWeights.SemiBold;header.Children.Add(animationTitle);
        panel.Children.Add(header);
        var show=new CheckBox{Content=T("启用桌面律动","Enable desktop animation"),IsChecked=settings.KeyBurstEnabled};
        AutomationProperties.SetAutomationId(show,"key-burst-enabled");
        show.Click+=(_,_)=>{settings.KeyBurstEnabled=show.IsChecked==true;UpdateKeyBurst();SaveSoon();};
        panel.Children.Add(show);
        var selector=new ComboBox {
            ItemsSource=new KeyValuePair<string,string>[] {new("burst",T("键阵爆破","Key Burst")),new("edgeGlow",T("底部泛光","Bottom glow"))},
            DisplayMemberPath="Value",SelectedValuePath="Key",SelectedValue=settings.DesktopStyle,Margin=new Thickness(0,8,0,8),
            HorizontalAlignment=HorizontalAlignment.Left,Width=220
        };
        AutomationProperties.SetAutomationId(selector,"desktop-animation-style");
        AutomationProperties.SetName(selector,T("显示样式","Display style"));
        panel.Children.Add(selector);
        var description=Text("",12,true);
        description.Margin=new Thickness(0,0,0,8);panel.Children.Add(description);
        var audioPanel=new StackPanel{Margin=new Thickness(0,8,0,0)};
        var follow=new CheckBox{Content=T("跟随电脑声音","Follow computer audio"),IsChecked=settings.FollowSystemAudio};
        AutomationProperties.SetAutomationId(follow,"rhythm-follow-audio");
        follow.ToolTip=T("分析默认播放设备的混合声音，包含键舞自己的音效。低音推动左侧柔光，中高音带动右侧波形。只在本机即时分析，不使用麦克风，不保存录音。",
            "Analyzes the default output-device mix, including KeyWoo sounds. Bass shapes the left glow; mids and treble shape the right wave. Analysis stays in memory, with no microphone or saved recording.");
        follow.Click+=(_,_)=>{settings.FollowSystemAudio=follow.IsChecked==true;UpdateKeyBurst();SaveSoon();};
        audioPanel.Children.Add(follow);
        var audioStateRow=new DockPanel();
        systemAudioRetry=MakeButton(T("重试","Retry"),(_,_)=>systemAudio.Retry());
        AutomationProperties.SetAutomationId(systemAudioRetry,"rhythm-audio-retry");
        DockPanel.SetDock(systemAudioRetry,Dock.Right);
        audioStateRow.Children.Add(systemAudioRetry);
        systemAudioStatus=Text("",12,true);
        audioStateRow.Children.Add(systemAudioStatus);
        audioPanel.Children.Add(audioStateRow);
        panel.Children.Add(audioPanel);
        void UpdateStyleDescription() {
            bool edge=settings.DesktopStyle=="edgeGlow";
            description.Text=edge?T("光沿鼠标所在显示器的下缘亮起，停手后渐隐。鼠标可以直接穿过。","Light follows the bottom edge of the display under your pointer and fades after typing. Clicks pass through.")
                :T("按键化成发光字符，空格打散成碎光，回车轻轻收束。演示不发声、不计数。","Key labels glow briefly. Space scatters them into sparks and Return draws them together. The demo is silent and does not count keystrokes.");
            audioPanel.Visibility=edge?Visibility.Visible:Visibility.Collapsed;
        }
        selector.SelectionChanged+=(_,_)=>{
            if(building||selector.SelectedValue is not string style)return;
            settings.DesktopStyle=style;UpdateStyleDescription();UpdateKeyBurst();SaveSoon();
        };
        UpdateStyleDescription();
        var flashes=new CheckBox{Content=T("闪光效果","Flashes"),IsChecked=settings.KeyBurstFlashes,Margin=new Thickness(0,8,0,0)};
        AutomationProperties.SetAutomationId(flashes,"key-burst-flashes");
        flashes.Click+=(_,_)=>{settings.KeyBurstFlashes=flashes.IsChecked==true;UpdateKeyBurst();SaveSoon();};
        panel.Children.Add(flashes);
        panel.Children.Add(KeyBurstSlider(T("动画幅度","Motion intensity"),"key-burst-intensity",.25,1,
            ControlScale.RhythmIntensity.DisplayValue(settings.KeyBurstIntensity),value=>settings.KeyBurstIntensity=ControlScale.RhythmIntensity.StoredValue(value)));
        panel.Children.Add(KeyBurstSlider(T("特效透明度","Effect opacity"),"key-burst-opacity",.25,1,
            settings.KeyBurstBrightness,value=>settings.KeyBurstBrightness=value));
        UpdateSystemAudioState();
        return Card(panel);
    }
    private DockPanel KeyBurstSlider(string title,string id,double minimum,double maximum,double value,Action<double> save) {
        var row=new DockPanel{Margin=new Thickness(0,8,0,0)};
        var label=Text(title,12);label.Width=112;
        DockPanel.SetDock(label,Dock.Left);row.Children.Add(label);
        var percent=Text(value.ToString("0.##%"),12,true);percent.Width=64;
        DockPanel.SetDock(percent,Dock.Right);row.Children.Add(percent);
        var slider=new Slider{Minimum=minimum,Maximum=maximum,Value=value,SmallChange=.01,LargeChange=.05,
            TickPlacement=TickPlacement.None,TickFrequency=.25,Margin=new Thickness(0,0,8,0)};
        AutomationProperties.SetAutomationId(slider,id);AutomationProperties.SetName(slider,title);
        slider.ValueChanged+=(_,_)=>{
            save(slider.Value);percent.Text=slider.Value.ToString("0.##%");UpdateKeyBurst();SaveSoon();
        };
        row.Children.Add(slider);return row;
    }
    private void UpdateSystemAudioState() {
        keyBurst.SetAudioSource(systemAudio.Snapshot,systemAudio.State==SystemAudioState.Running);
        if(systemAudioStatus is not null) {
            systemAudioStatus.Visibility=settings.FollowSystemAudio?Visibility.Visible:Visibility.Collapsed;
            systemAudioStatus.Text=systemAudio.State switch {
                SystemAudioState.Starting=>T("正在连接电脑声音…","Connecting to computer audio…"),
                SystemAudioState.Running=>T("已连接电脑声音 · 没有声音时自然淡出","Connected to computer audio · Fades during silence"),
                SystemAudioState.Failed=>T("暂时无法读取电脑声音，请检查播放设备。","Computer audio is unavailable. Check your output device."),
                _=>T("继续运行后，将跟随电脑声音。","Resuming will reconnect computer audio.")
            };
        }
        if(systemAudioRetry is not null)systemAudioRetry.Visibility=systemAudio.State==SystemAudioState.Failed?Visibility.Visible:Visibility.Collapsed;
    }
    private void ApplyTheme() {
        bool dark=settings.Appearance=="dark";
        if(settings.Appearance=="system")try{dark=(int?)Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize","AppsUseLightTheme",1)==0;}catch{dark=false;}
        foreach(var (name,light,night) in new[]{("PageBrush","#F8F6F3","#181615"),("SidebarBrush","#F1ECE6","#211E1D"),("CardBrush","#FFFDFA","#292523"),("RaisedBrush","#F5F0EA","#322D2A"),("SelectedBrush","#F3E2DA","#4B3029"),("TextBrush","#29221F","#F5EFE8"),("MutedBrush","#665B54","#B8ACA4"),("LineBrush","#E2DAD1","#453C37"),("AccentBrush","#A34332","#FCA58D")})
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
        if(IsVisible&&tabs?.SelectedIndex==1)statisticsPanel?.RefreshIfNeeded();
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
        pause.Content=enabled?T("全部暂停","Pause all"):T("继续运行","Resume");
        status.Text=sessionLocked?T("锁屏时暂停","Paused while locked"):!enabled?T("已暂停","Paused"):hookReady?T("所有应用 · 已连接","All apps · Connected"):T("正在连接键盘…","Connecting keyboard…");
        UpdateSoundSummary();UpdateMappingState();UpdateKeyBurst();
    }
    private void UpdateKeyBurst(){
        bool suspended=!enabled||sessionLocked||powerSuspended||closing;
        keyBurst.SetSuspended(suspended);
        keyBurst.Configure(settings.KeyBurstEnabled,settings.KeyBurstFlashes,settings.KeyBurstIntensity,settings.KeyBurstBrightness,settings.DesktopStyle);
        systemAudio.SetEnabled(started&&!suspended&&settings.KeyBurstEnabled&&settings.DesktopStyle=="edgeGlow"&&settings.FollowSystemAudio);
        if(keyBurstPreview is not null)keyBurstPreview.IsEnabled=!suspended;
    }
    private void SaveSoon(){if(verificationOnly)return;saveTimer.Stop();saveTimer.Start();}
    internal void RebuildVerification(){if(!verificationOnly)throw new InvalidOperationException("This operation is only available to the isolated UI verifier.");Build();}
    internal void DisposeVerification(){if(!verificationOnly)throw new InvalidOperationException("This operation is only available to the isolated UI verifier.");closing=true;updateTimer.Stop();saveTimer.Stop();preview?.Cancel();systemAudio.StateChanged-=UpdateSystemAudioState;systemAudio.Dispose();keyBurst.Dispose();hook.Dispose();tray.Dispose();Close();}
    private void ShowError(string message){currentError=message;error.Text=message;if(errorNotice is not null)errorNotice.Visibility=Visibility.Visible;}
    private void ShowAudioError(string message){audioError=T("声音连接中断：","Audio disconnected: ")+message;ShowError(audioError);}
    private void ClearAudioError(){if(audioError is not null&&currentError==audioError){currentError=null;error.Text="";if(errorNotice is not null)errorNotice.Visibility=Visibility.Collapsed;}audioError=null;}
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
    private void PowerChanged(object sender,PowerModeChangedEventArgs e)=>Dispatcher.InvokeAsync(()=>{
        if(closing)return;
        if(e.Mode==PowerModes.Suspend){powerSuspended=true;UpdateKeyBurst();}
        else if(e.Mode==PowerModes.Resume){
            powerSuspended=false;UpdateKeyBurst();
            try{audio?.Restart();}catch(Exception error){ShowAudioError(error.Message);}
        }
    });
    private void PreferencesChanged(object sender,UserPreferenceChangedEventArgs e){if(settings.Appearance=="system")Dispatcher.InvokeAsync(Build);}
    private void ExitNow() {
        if(closing)return;closing=true;preview?.Cancel();updateTimer.Stop();saveTimer.Stop();
        systemAudio.StateChanged-=UpdateSystemAudioState;systemAudio.Dispose();keyBurst.Dispose();hook.Dispose();audio?.Dispose();
        while(presses.TryDequeue(out var item))statistics.Record(item.Key,item.At);
        try{statistics.FlushAsync().GetAwaiter().GetResult();settings.SaveAsync().GetAwaiter().GetResult();}catch{}
        SystemEvents.SessionSwitch-=SessionChanged;SystemEvents.PowerModeChanged-=PowerChanged;SystemEvents.UserPreferenceChanged-=PreferencesChanged;tray.Visible=false;tray.Dispose();trayIcon?.Dispose();System.Windows.Application.Current.Shutdown();
    }
}
