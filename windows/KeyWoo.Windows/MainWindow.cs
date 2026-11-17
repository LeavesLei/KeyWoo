using System.Collections.Concurrent;
using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Threading;
using KeyWoo.Core;
using Microsoft.Win32;
using Forms=System.Windows.Forms;
namespace KeyWoo.Windows;

public sealed partial class MainWindow : Window {
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
    private TextBlock status=new(),error=new();
    private Button pause=new();
    private readonly List<Button> soundPreviewButtons=[];
    private readonly Dictionary<int,Button> navigationButtons=[];
    private readonly Dictionary<int,ScrollViewer> pageScrollers=[];
    private TextBlock? pageTitle,mappingFeedback,mappingState;
    private Button? removeRule,editRule,saveRule,cancelRule;
    private InputRule? editingRule;
    private Border? errorNotice;
    private Button? keyBurstPreview;
    private CheckBox? desktopEnabled;
    private TextBlock? desktopStatus;
    private readonly Dictionary<string,Button> desktopStyleButtons=[];
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
    // Match macOS for A/B comparison and the 96 BPM Street Beat demonstration.
    private static readonly (int Time,int[] Keys)[] RecordingPreview =
        [(0,[0]),(140,[1]),(280,[2]),(540,[49]),(850,[36]),(1150,[51])];
    private static readonly (int Time,int[] Keys)[] StreetBeatPreview =
        [(0,[49,0]),(177,[0]),(313,[0]),(489,[0]),(625,[36,56,0]),(802,[0]),(938,[49,0]),(1114,[51]),
         (1250,[49,0]),(1427,[0]),(1563,[0]),(1739,[0]),(1875,[36,56,0]),(2052,[0]),(2188,[48])];

    private Task PreviewSequence()=>PlayPreview(audio?.Mixer.Style==SampleBank.StreetBeatPreset?StreetBeatPreview:RecordingPreview);
    private Task PreviewKey(int code)=>PlayPreview([(0,[code])],Environment.TickCount);
    private async Task PlayPreview((int Time,int[] Keys)[] pattern,int take=0) {
        if(!CanPreviewSound||audio is not { } output)return;
        preview?.Cancel();preview?.Dispose();preview=new CancellationTokenSource();var token=preview.Token;
        var mixer=output.Mixer;
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
        ruleGrid=new DataGrid{IsReadOnly=true,AutoGenerateColumns=false,CanUserAddRows=false,CanUserDeleteRows=false,EnableColumnVirtualization=false,EnableRowVirtualization=false,MinColumnWidth=180,SelectionMode=DataGridSelectionMode.Single,SelectionUnit=DataGridSelectionUnit.FullRow,HeadersVisibility=DataGridHeadersVisibility.Column,GridLinesVisibility=DataGridGridLinesVisibility.None,RowHeight=42,MinHeight=120,MaxHeight=300,Background=Brush("CardBrush"),Foreground=Brush("TextBrush"),RowBackground=Brush("CardBrush"),AlternatingRowBackground=Brush("RaisedBrush"),BorderThickness=new Thickness(0)};
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
    private void Refresh() {
        int budget=1024;
        while(budget-->0&&presses.TryDequeue(out var item)){Interlocked.Decrement(ref queuedPresses);statistics.Record(item.Key,item.At);highlights[item.Key.Id]=DateTimeOffset.UtcNow;}
        foreach(var (id,button) in keyButtons)button.BorderBrush=Brush(highlights.TryGetValue(id,out var at)&&(DateTimeOffset.UtcNow-at).TotalSeconds<.16?"AccentBrush":"LineBrush");
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
        UpdateDesktopControls();
        systemAudio.SetEnabled(started&&!suspended&&settings.KeyBurstEnabled&&settings.DesktopStyle=="edgeGlow"&&settings.FollowSystemAudio);
        if(keyBurstPreview is not null)keyBurstPreview.IsEnabled=!suspended;
    }
    private void SaveSoon(){if(verificationOnly)return;saveTimer.Stop();saveTimer.Start();}
    internal void RebuildVerification(){if(!verificationOnly)throw new InvalidOperationException("This operation is only available to the isolated UI verifier.");Build();}
    internal void DisposeVerification(){if(!verificationOnly)throw new InvalidOperationException("This operation is only available to the isolated UI verifier.");closing=true;updateTimer.Stop();saveTimer.Stop();preview?.Cancel();systemAudio.StateChanged-=UpdateSystemAudioState;systemAudio.Dispose();keyBurst.Dispose();hook.Dispose();tray.Dispose();Close();}
    private void ShowError(string message){currentError=message;error.Text=message;if(errorNotice is not null)errorNotice.Visibility=Visibility.Visible;}
    private void ShowAudioError(string message){audioError=T("声音连接中断：","Audio disconnected: ")+message;ShowError(audioError);UpdateSoundSummary();}
    private void ClearAudioError(){if(audioError is not null&&currentError==audioError){currentError=null;error.Text="";if(errorNotice is not null)errorNotice.Visibility=Visibility.Collapsed;}audioError=null;UpdateSoundSummary();}
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
        if(e.Mode==PowerModes.Suspend){powerSuspended=true;preview?.Cancel();UpdateSoundSummary();UpdateKeyBurst();}
        else if(e.Mode==PowerModes.Resume){
            powerSuspended=false;UpdateKeyBurst();
            try{if(audio is not null){audio.Restart();ClearAudioError();}else UpdateSoundSummary();}catch(Exception error){ShowAudioError(error.Message);}
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
