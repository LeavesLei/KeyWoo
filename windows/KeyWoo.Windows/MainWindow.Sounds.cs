using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using KeyWoo.Core;

namespace KeyWoo.Windows;

public sealed partial class MainWindow {
    private enum CatalogCategory { Recorded, Fun }
    private sealed record CategoryOption(CatalogCategory Category, string Name);
    private sealed record SoundProfile(string Chinese, string English, string ChineseDetail, string EnglishDetail);
    private static readonly string[] SoundOrder = [
        "rainy75", "whiteFox", "unicomp", "technicsYellow", "laneAlps", "macbookPro", "topre",
        "oreo", "panda", "purple", "red", "blue", "brown", "black",
        "streetBeat", "mahjongTiles", "hermes", "woodDesk", "mahjong"
    ];

    private CatalogCategory? browsedSoundCategory;
    private string soundQuery = "";
    private bool screenKeyboardExpanded, recordingDetailsExpanded;
    private TextBlock? currentSound, currentSoundDetail, soundAvailability;
    private Border? currentSoundIcon;
    private TextBlock? recordingSource, recordingDetail, recordingCredit;
    private FrameworkElement? soundVersionControl;
    private readonly Dictionary<string, TextBlock> soundIndicators = [];
    private bool CanPreviewSound => enabled && !sessionLocked && !powerSuspended && !closing && audio is not null && audioError is null;

    private UIElement Sounds() {
        var panel = Panel();
        panel.Children.Add(CurrentSoundCard());
        panel.Children.Add(SoundCatalog());
        return panel;
    }

    private Border CurrentSoundCard() {
        var current = Panel();
        var header = new DockPanel();

        var previewButton = MakeButton(T("▶ 试听", "▶ Preview"), async (_, _) => await PreviewSequence());
        previewButton.Background = Brush("AccentBrush");
        previewButton.Foreground = Brush("OnAccentBrush");
        previewButton.BorderBrush = Brush("AccentBrush");
        previewButton.Margin = new Thickness(12, 0, 0, 0);
        previewButton.MinHeight = 34;
        previewButton.FontWeight = FontWeights.SemiBold;
        previewButton.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetAutomationId(previewButton, "sound-preview");
        AutomationProperties.SetName(previewButton, T("试听当前音色", "Preview current sound"));
        soundPreviewButtons.Add(previewButton);
        DockPanel.SetDock(previewButton, Dock.Right);
        header.Children.Add(previewButton);

        currentSoundIcon = new Border {
            Width = 50, Height = 50, CornerRadius = new CornerRadius(11),
            Background = Brush("SelectedBrush"), Margin = new Thickness(0, 0, 13, 0),
            VerticalAlignment = VerticalAlignment.Center,
            Child = SoundIcon(CatalogCategory.Recorded)
        };
        DockPanel.SetDock(currentSoundIcon, Dock.Left);
        header.Children.Add(currentSoundIcon);

        var identification = Panel();
        identification.Children.Add(Text(T("当前音色", "Current sound"), 11, muted: true));
        currentSound = Text("", 23);
        currentSound.FontWeight = FontWeights.SemiBold;
        currentSound.Margin = new Thickness(0, 2, 0, 2);
        AutomationProperties.SetAutomationId(currentSound, "current-sound-title");
        AutomationProperties.SetHeadingLevel(currentSound, AutomationHeadingLevel.Level2);
        identification.Children.Add(currentSound);
        currentSoundDetail = Text("", 12, muted: true);
        identification.Children.Add(currentSoundDetail);
        header.Children.Add(identification);
        current.Children.Add(header);

        soundAvailability = Text("", 11, muted: true);
        soundAvailability.Margin = new Thickness(0, 8, 0, 0);
        current.Children.Add(soundAvailability);
        current.Children.Add(SoundDivider(14, 12));

        var controls = new DockPanel();
        soundVersionControl = RecordingVersionControl();
        DockPanel.SetDock(soundVersionControl, Dock.Right);
        controls.Children.Add(soundVersionControl);
        controls.Children.Add(VolumeControl());
        current.Children.Add(controls);
        current.Children.Add(PracticeControl());
        current.Children.Add(SoundDivider(12, 0));
        current.Children.Add(KeyboardDisclosure());
        current.Children.Add(SoundDivider(0, 0));
        current.Children.Add(RecordingDisclosure());
        return Card(current);
    }

    private DockPanel RecordingVersionControl() {
        string label = T("录音版本", "Recording version");
        string detail = T("原音保留录音原貌；Hi-Fi 减少低频杂音和尾部底噪。",
            "Original preserves the source recording. Hi-Fi reduces low-end noise and noise in the tail.");
        var help = Help(detail);
        help.Margin = new Thickness(4, 0, 0, 0);
        var version = new ComboBox {
            ItemsSource = new KeyValuePair<bool, string>[] { new(false, T("原音", "Original")), new(true, T("Hi-Fi 高保真", "Hi-Fi")) },
            DisplayMemberPath = "Value", SelectedValuePath = "Key", SelectedValue = settings.HiFiEnabled,
            Width = 115, ToolTip = detail, VerticalAlignment = VerticalAlignment.Center
        };
        AutomationProperties.SetAutomationId(version, "recording-version");
        AutomationProperties.SetName(version, label);
        version.SelectionChanged += async (_, _) => {
            if (building || version.SelectedValue is not bool hiFi || settings.HiFiEnabled == hiFi) return;
            settings.HiFiEnabled = hiFi;
            if (audio is not null) audio.Mixer.HiFiEnabled = hiFi;
            SaveSoon();
            await PreviewSequence();
        };
        var row = new DockPanel { Margin = new Thickness(13, 0, 0, 0) };
        DockPanel.SetDock(help, Dock.Right);
        row.Children.Add(help);
        row.Children.Add(version);
        return row;
    }

    private DockPanel VolumeControl() {
        string title = T("音量", "Volume");
        var row = new DockPanel();
        var label = Text(title, 12, muted: true);
        label.VerticalAlignment = VerticalAlignment.Center;
        label.Margin = new Thickness(0, 0, 7, 0);
        label.ToolTip = T("0% 静音，仍记录按键次数。", "At 0%, sound is muted and key presses are still counted.");
        row.Children.Add(label);

        string Percent(double stored) => ControlScale.KeyboardVolume.DisplayValue(stored).ToString("0.##%", CultureInfo.CurrentCulture);
        var restore = MakeButton(T("推荐", "Recommended"), (_, _) => { });
        restore.ToolTip = T("恢复推荐音量", "Restore recommended volume");
        restore.Padding = new Thickness(8, 4, 8, 4);
        restore.Margin = new Thickness(0);
        restore.FontSize = 11;
        restore.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetAutomationId(restore, "keyboard-volume-reset");
        DockPanel.SetDock(restore, Dock.Right);
        row.Children.Add(restore);

        var value = Text(Percent(settings.Volume), 12, muted: true);
        value.Width = 61;
        value.TextAlignment = TextAlignment.Right;
        value.VerticalAlignment = VerticalAlignment.Center;
        value.Margin = new Thickness(4, 0, 8, 0);
        DockPanel.SetDock(value, Dock.Right);
        row.Children.Add(value);
        var slider = new Slider {
            Minimum = 0, Maximum = 1, SmallChange = .01, LargeChange = .05,
            Value = ControlScale.KeyboardVolume.DisplayValue(settings.Volume),
            TickPlacement = TickPlacement.None, VerticalAlignment = VerticalAlignment.Center
        };
        AutomationProperties.SetAutomationId(slider, "keyboard-volume");
        AutomationProperties.SetName(slider, title);
        slider.ValueChanged += (_, _) => {
            if (building) return;
            settings.Volume = ControlScale.KeyboardVolume.StoredValue(slider.Value);
            value.Text = Percent(settings.Volume);
            if (audio is not null) audio.Mixer.Volume = (float)settings.Volume;
            SaveSoon();
        };
        restore.Click += (_, _) => slider.Value = ControlScale.KeyboardVolume.DisplayValue(1);
        row.Children.Add(slider);
        return row;
    }

    private DockPanel PracticeControl() {
        var row = new DockPanel { Margin = new Thickness(0, 12, 0, 0) };
        var label = Text(T("试打", "Try typing"), 12, muted: true);
        label.VerticalAlignment = VerticalAlignment.Center;
        label.Margin = new Thickness(0, 0, 10, 0);
        label.ToolTip = T("实体键盘的输入会计入统计，试打文字不会保存。",
            "Physical keystrokes count toward statistics. Practice text is never saved.");
        row.Children.Add(label);

        var input = new TextBox { MinHeight = 34, VerticalContentAlignment = VerticalAlignment.Center };
        practice = input;
        string prompt = T("在这里打字试听", "Type here to try the sound");
        var clear = ClearSoundTextButton(input, T("清空试打文字", "Clear practice text"));
        DockPanel.SetDock(clear, Dock.Right);
        row.Children.Add(clear);
        row.Children.Add(SoundTextInput(input, prompt, "practice-input"));
        return row;
    }

    private Grid SoundTextInput(TextBox input, string prompt, string automationId) {
        AutomationProperties.SetAutomationId(input, automationId);
        AutomationProperties.SetName(input, prompt);
        input.Padding = new Thickness(10, 4, 10, 4);
        input.Background = Brush("RaisedBrush");
        input.Foreground = Brush("TextBrush");
        input.CaretBrush = Brush("TextBrush");
        input.BorderBrush = Brush("LineBrush");
        input.GotKeyboardFocus += (_, _) => input.BorderBrush = Brush("AccentBrush");
        input.LostKeyboardFocus += (_, _) => input.BorderBrush = Brush("LineBrush");
        var watermark = Text(prompt, 13, muted: true);
        watermark.IsHitTestVisible = false;
        watermark.VerticalAlignment = VerticalAlignment.Center;
        watermark.Margin = new Thickness(11, 0, 11, 0);
        watermark.Visibility = input.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetAccessibilityView(watermark, AccessibilityView.Raw);
        input.TextChanged += (_, _) => watermark.Visibility = input.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        var field = new Grid();
        field.Children.Add(input);
        field.Children.Add(watermark);
        return field;
    }

    private Button ClearSoundTextButton(TextBox input, string name) {
        var button = MakeButton("×", (_, _) => { input.Clear(); input.Focus(); });
        button.Width = 30;
        button.Padding = new Thickness(4);
        button.Margin = new Thickness(5, 0, 0, 0);
        button.VerticalAlignment = VerticalAlignment.Stretch;
        button.ToolTip = name;
        button.IsEnabled = input.Text.Length != 0;
        AutomationProperties.SetName(button, name);
        input.TextChanged += (_, _) => button.IsEnabled = input.Text.Length != 0;
        return button;
    }

    private Expander KeyboardDisclosure() {
        var panel = Panel();
        panel.Margin = new Thickness(0, 5, 0, 8);
        (int Virtual, int Scan, double Width)[][] rows = [
            [(81,16,1),(87,17,1),(69,18,1),(82,19,1),(84,20,1),(89,21,1),(85,22,1),(73,23,1),(79,24,1),(80,25,1)],
            [(65,30,1),(83,31,1),(68,32,1),(70,33,1),(71,34,1),(72,35,1),(74,36,1),(75,37,1),(76,38,1)],
            [(90,44,1),(88,45,1),(67,46,1),(86,47,1),(66,48,1),(78,49,1),(77,50,1)],
            [(9,15,1.25),(32,57,4.5),(13,28,1.5),(8,14,1.5)]
        ];
        foreach (var row in rows) {
            var keys = new Grid { Margin = new Thickness(0, 0, 0, 4) };
            foreach (var (vk, scan, width) in row) {
                var key = new PhysicalKey(vk, scan);
                string name = KeyboardKeys.Name(vk, Chinese);
                var button = MakeButton(name, async (_, _) => await PreviewKey(key.MacCode));
                button.Padding = new Thickness(3, 3, 3, 3);
                button.FontSize = 11;
                button.MinHeight = 29;
                button.Margin = new Thickness(2, 0, 2, 0);
                AutomationProperties.SetAutomationId(button, "sound-key-" + key.MacCode);
                soundPreviewButtons.Add(button);
                keyButtons[key.Id] = button;
                Grid.SetColumn(button, keys.ColumnDefinitions.Count);
                keys.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(width, GridUnitType.Star) });
                keys.Children.Add(button);
            }
            panel.Children.Add(keys);
        }
        panel.ToolTip = T("点击试听，不计入统计。", "Click to preview without counting.");
        var disclosure = new Expander { Header = T("屏幕键盘", "On-screen keyboard"), Content = panel, IsExpanded = screenKeyboardExpanded };
        AutomationProperties.SetAutomationId(disclosure, "sound-screen-keyboard");
        disclosure.Expanded += (_, _) => screenKeyboardExpanded = true;
        disclosure.Collapsed += (_, _) => screenKeyboardExpanded = false;
        return disclosure;
    }

    private Expander RecordingDisclosure() {
        var panel = Panel();
        panel.Margin = new Thickness(0, 5, 0, 6);
        recordingSource = Text("", 12);
        recordingSource.FontWeight = FontWeights.SemiBold;
        panel.Children.Add(recordingSource);
        recordingDetail = Text("", 12, muted: true);
        recordingDetail.Margin = new Thickness(0, 4, 0, 2);
        panel.Children.Add(recordingDetail);
        recordingCredit = Text("", 11, muted: true);
        panel.Children.Add(recordingCredit);
        var notices = MakeButton(T("来源与许可证", "Sources and licenses"),
            (_, _) => OpenFile(Path.Combine(AppContext.BaseDirectory, "Assets", "KeyboardSounds", "THIRD-PARTY-NOTICES.md")));
        notices.HorizontalAlignment = HorizontalAlignment.Left;
        notices.Margin = new Thickness(0, 8, 0, 0);
        notices.Padding = new Thickness(9, 4, 9, 4);
        panel.Children.Add(notices);
        var disclosure = new Expander { Header = T("声音细节", "Sound details"), Content = panel, IsExpanded = recordingDetailsExpanded };
        AutomationProperties.SetAutomationId(disclosure, "sound-recording-details");
        disclosure.Expanded += (_, _) => recordingDetailsExpanded = true;
        disclosure.Collapsed += (_, _) => recordingDetailsExpanded = false;
        return disclosure;
    }

    private Border SoundCatalog() {
        var catalog = Panel();
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        var clearFilter = MakeButton(T("显示当前音色", "Show current sound"), (_, _) => { });
        clearFilter.Margin = new Thickness(0);
        clearFilter.Padding = new Thickness(8, 4, 8, 4);
        clearFilter.FontSize = 12;
        AutomationProperties.SetAutomationId(clearFilter, "sound-category-current");
        DockPanel.SetDock(clearFilter, Dock.Right);
        header.Children.Add(clearFilter);
        var title = Text(T("音色库", "Sound library"), 16);
        title.FontWeight = FontWeights.SemiBold;
        title.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level2);
        header.Children.Add(title);
        catalog.Children.Add(header);

        var category = new ComboBox {
            ItemsSource = new[] {
                new CategoryOption(CatalogCategory.Recorded, T("键盘实录", "Recorded keyboards")),
                new CategoryOption(CatalogCategory.Fun, T("趣味音效", "Fun sounds"))
            },
            DisplayMemberPath = nameof(CategoryOption.Name), SelectedValuePath = nameof(CategoryOption.Category),
            Width = 180, Margin = new Thickness(0, 0, 10, 0)
        };
        AutomationProperties.SetAutomationId(category, "sound-category");
        AutomationProperties.SetName(category, T("音色分类", "Sound category"));
        var search = new TextBox { MinHeight = 34, VerticalContentAlignment = VerticalAlignment.Center, Text = soundQuery };
        var searchClear = ClearSoundTextButton(search, T("清除搜索", "Clear search"));
        AutomationProperties.SetAutomationId(searchClear, "sound-search-clear");
        var filters = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        filters.Children.Add(category);
        DockPanel.SetDock(searchClear, Dock.Right);
        filters.Children.Add(searchClear);
        filters.Children.Add(SoundTextInput(search, T("搜索名称、轴体或材质", "Search names, switches or materials"), "sound-catalog-search"));
        catalog.Children.Add(filters);

        var grid = new UniformGrid { Columns = 3, Margin = new Thickness(-3, 0, -3, 0) };
        grid.SizeChanged += (_, change) => grid.Columns = Math.Clamp((int)(change.NewSize.Width / 184), 2, 5);
        AutomationProperties.SetAutomationId(grid, "sound-catalog");
        catalog.Children.Add(grid);
        var emptyText = Text("", 13, muted: true);
        emptyText.TextAlignment = TextAlignment.Center;
        var empty = new Border {
            Child = emptyText, Background = Brush("RaisedBrush"), CornerRadius = new CornerRadius(8),
            Padding = new Thickness(12, 23, 12, 23)
        };
        AutomationProperties.SetAutomationId(empty, "sound-catalog-empty");
        catalog.Children.Add(empty);

        void FillPresets() {
            grid.Children.Clear();
            presetButtons.Clear();
            soundIndicators.Clear();
            var visible = soundBank?.Presets
                .Where(preset => CategoryOf(preset) == (CatalogCategory?)category.SelectedValue && MatchesSearch(preset))
                .OrderBy(preset => Array.IndexOf(SoundOrder, preset.Id) is int index && index >= 0 ? index : SoundOrder.Length)
                .ThenBy(PresetName, StringComparer.CurrentCultureIgnoreCase)
                .ToArray() ?? [];
            foreach (var preset in visible) grid.Children.Add(SoundPresetTile(preset));
            grid.Visibility = visible.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            empty.Visibility = visible.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            emptyText.Text = soundBank is null ? T("正在加载音色…", "Loading sounds…") : T("没有匹配的音色", "No matching sounds");
            clearFilter.Visibility = soundBank is not null && !visible.Any(preset => preset.Id == settings.Preset)
                ? Visibility.Visible : Visibility.Collapsed;
            UpdatePresets();
        }

        search.TextChanged += (_, _) => { soundQuery = search.Text; FillPresets(); };
        search.PreviewKeyDown += (_, e) => {
            if (e.Key != Key.Escape || search.Text.Length == 0) return;
            search.Clear();
            e.Handled = true;
        };
        category.SelectionChanged += (_, _) => {
            if (category.SelectedValue is CatalogCategory selected && !building) browsedSoundCategory = selected;
            FillPresets();
        };
        clearFilter.Click += (_, _) => {
            if (SelectedSound is not { } selected) return;
            category.SelectedValue = CategoryOf(selected);
            search.Clear();
            if (presetButtons.TryGetValue(selected.Id, out var button)) { button.BringIntoView(); button.Focus(); }
        };
        refreshSoundCatalog = () => {
            category.SelectedValue = browsedSoundCategory ?? (SelectedSound is { } selected ? CategoryOf(selected) : CatalogCategory.Recorded);
            FillPresets();
        };
        refreshSoundCatalog();
        return Card(catalog);
    }

    private Button SoundPresetTile(SoundPreset preset) {
        string id = preset.Id;
        var button = MakeButton("", async (_, _) => {
            if (settings.Preset != id) {
                settings.Preset = id;
                if (audio is not null) audio.Mixer.Style = id;
                UpdatePresets();
                SaveSoon();
            }
            await PreviewSequence();
        });
        button.MinHeight = 61;
        button.Margin = new Thickness(3, 0, 3, 6);
        button.Padding = new Thickness(10, 6, 9, 6);
        button.HorizontalContentAlignment = HorizontalAlignment.Stretch;

        var row = new DockPanel();
        var profile = ProfileOf(preset);
        var indicator = Text("", 12, muted: true);
        indicator.Width = 14;
        indicator.Margin = new Thickness(3, 0, 0, 0);
        indicator.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetAccessibilityView(indicator, AccessibilityView.Raw);
        DockPanel.SetDock(indicator, Dock.Right);
        row.Children.Add(indicator);

        var labels = Panel();
        var title = Text(PresetName(preset), 13);
        title.FontWeight = FontWeights.SemiBold;
        labels.Children.Add(title);
        var tag = Text(T(profile.Chinese, profile.English), 11, muted: true);
        tag.Margin = new Thickness(0, 2, 0, 0);
        labels.Children.Add(tag);
        row.Children.Add(labels);
        button.Content = row;
        button.ToolTip = T(profile.ChineseDetail, profile.EnglishDetail);
        AutomationProperties.SetAutomationId(button, "preset-" + id);
        AutomationProperties.SetName(button, PresetName(preset));
        presetButtons[id] = button;
        soundIndicators[id] = indicator;
        return button;
    }

    private SoundPreset? SelectedSound => soundBank?.Presets.FirstOrDefault(preset => preset.Id == settings.Preset);
    private static CatalogCategory CategoryOf(SoundPreset preset) => preset.Category == SoundCategory.RecordedKeyboard ? CatalogCategory.Recorded : CatalogCategory.Fun;

    private bool MatchesSearch(SoundPreset preset) {
        var words = soundQuery.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) return true;
        var profile = ProfileOf(preset);
        var fields = string.Join(" ", PresetName(preset), preset.Id, preset.Title, preset.TitleZh,
            profile.Chinese, profile.English, profile.ChineseDetail, profile.EnglishDetail);
        return words.All(word => CultureInfo.CurrentCulture.CompareInfo.IndexOf(fields, word, CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace) >= 0);
    }

    private void UpdatePresets() => UpdateSoundSummary();

    private void UpdateSoundSummary() {
        var selected = SelectedSound;
        if (currentSound is not null) currentSound.Text = selected is not null ? PresetName(selected)
            : soundBank is null && audioError is null ? T("正在加载音色…", "Loading sounds…") : T("音色暂不可用", "Sound unavailable");
        if (selected is not null) {
            var profile = ProfileOf(selected);
            if (currentSoundDetail is not null) currentSoundDetail.Text = T(profile.ChineseDetail, profile.EnglishDetail);
            if (currentSoundIcon is not null) currentSoundIcon.Child = SoundIcon(CategoryOf(selected));
            if (recordingSource is not null) recordingSource.Text = selected.Category == SoundCategory.Synthesized
                ? T("合成拟音", "Synthesized sound") : T("真实录音", "Live recording");
            if (recordingDetail is not null) recordingDetail.Text = RecordingDescription(selected);
            if (recordingCredit is not null) recordingCredit.Text = RecordingCredit(selected);
        }
        if (soundVersionControl is not null) soundVersionControl.Visibility =
            soundBank?.HiFiPacks.ContainsKey(settings.Preset) == true ? Visibility.Visible : Visibility.Collapsed;

        string? unavailable = sessionLocked || powerSuspended ? T("系统休眠期间暂停试听。", "Preview is paused while the system is locked or asleep.")
            : !enabled ? T("继续运行后即可试听。", "Resume KeyWoo to preview sounds.")
            : audio is null || audioError is not null
                ? audioError is null ? T("正在连接音频…", "Connecting audio…") : T("音频暂不可用。", "Audio is unavailable.")
                : null;
        foreach (var button in soundPreviewButtons) {
            button.IsEnabled = CanPreviewSound;
            button.ToolTip = unavailable ?? T("点击试听，不计入统计。", "Preview without counting toward statistics.");
        }
        if (soundAvailability is not null) {
            soundAvailability.Text = unavailable ?? "";
            soundAvailability.Visibility = unavailable is null ? Visibility.Collapsed : Visibility.Visible;
        }
        foreach (var (id, button) in presetButtons) {
            bool active = id == settings.Preset;
            button.BorderBrush = Brush(active ? "AccentBrush" : "LineBrush");
            button.Background = Brush(active ? "SelectedBrush" : "CardBrush");
            AutomationProperties.SetItemStatus(button, active ? T("已选择", "Selected") : T("未选择", "Not selected"));
            var marker = soundIndicators[id];
            marker.Text = active ? "✓" : CanPreviewSound ? "▸" : "";
            marker.Foreground = Brush(active ? "AccentBrush" : "MutedBrush");
        }
    }

    private string PresetName(SoundPreset preset) => preset.Id switch {
        "topre" => T("Topre 静电容", "Topre"),
        "oreo" => "Everglide Oreo",
        "panda" => "Holy Panda",
        "purple" => T("Everglide 水晶紫", "Everglide Crystal Purple"),
        "red" => T("Cherry 红轴 · ABS", "Cherry Red · ABS"),
        "blue" => T("Cherry 青轴 · ABS", "Cherry Blue · ABS"),
        "brown" => T("Cherry 茶轴 · PBT", "Cherry Brown · PBT"),
        "black" => T("Cherry 黑轴 · PBT", "Cherry Black · PBT"),
        "bluePBT" => T("Cherry 青轴 · PBT", "Cherry Blue · PBT"),
        "brownABS" => T("Cherry 茶轴 · ABS", "Cherry Brown · ABS"),
        "blackABS" => T("Cherry 黑轴 · ABS", "Cherry Black · ABS"),
        "typewriter" => T("打字机", "Typewriter"),
        "bubble" => T("泡泡", "Bubble"),
        "woodblock" => T("木鱼", "Woodblock"),
        "paper" => T("纸笺", "Paper"),
        "raindrop" => T("水滴", "Raindrop"),
        "brick" => T("积木", "Brick"),
        "arcade" => T("街机", "Arcade"),
        "laser" => T("激光", "Laser"),
        "mahjong" => T("麻将", "Mahjong"),
        _ => Chinese ? preset.TitleZh ?? preset.Title : preset.Title
    };

    private static SoundProfile ProfileOf(SoundPreset preset) => preset.Id switch {
        "rainy75" => new("柔和 · 实录", "Soft · Recorded", "柔厚触底，带短促铝壳共鸣", "Soft bottom-out with a short aluminum case resonance"),
        "whiteFox" => new("段落 · 实录", "Tactile · Recorded", "利落段落，清晰的触底颗粒", "Crisp Hako Purple tactility and a defined bottom-out"),
        "unicomp" => new("复古 · 实录", "Vintage · Recorded", "复古弹簧声，清脆有金属余韵", "Crisp buckling springs with a metallic ring"),
        "technicsYellow" => new("线性 · 实录", "Linear · Recorded", "顺滑线性，低沉紧实的老键盘声", "Smooth Gateron Yellow switches with a tight, low sound"),
        "laneAlps" => new("复古 · 实录", "Vintage · Recorded", "老式电信键盘，短促干脆", "Short, crisp Alps switches from a vintage telephone keyboard"),
        "macbookPro" => new("柔和 · 实录", "Soft · Recorded", "短行程轻触，带自然回弹", "Light, short-travel taps with natural release"),
        "topre" => new("柔和 · 实录", "Soft · Recorded", "柔软厚实，静电容键盘录音", "Soft and rounded electrocapacitive keyboard"),
        "red" or "black" or "blackABS" => new("线性 · 实录", "Linear · Recorded", "顺滑按下，清晰触底", "Smooth press with a distinct bottom-out"),
        "blue" or "bluePBT" => new("点击 · 实录", "Clicky · Recorded", "清脆的点击与回弹", "Crisp click and release"),
        "brown" or "brownABS" or "oreo" or "purple" or "panda" => new("段落 · 实录", "Tactile · Recorded", "段落清楚，按键起落有细节", "Distinct tactile sound with a clear press and release"),
        "hermes" => new("复古 · 实录", "Vintage · Recorded", "金属字锤、空格与行尾铃", "Metal typebars, a physical spacebar and carriage bell"),
        "mahjongTiles" => new("硬质 · 实录", "Hard · Recorded", "真实牌面轻碰，大键更扎实", "Real mahjong tile taps with heavier accents on larger keys"),
        "woodDesk" => new("柔和 · 实录", "Soft · Recorded", "指尖叩木，轻重有别", "Gentle fingertip taps on wood"),
        "streetBeat" => new("嘻哈 · 合成", "Hip-hop · Synthesized", "低音底鼓、紧实军鼓和清脆踩镲", "Deep kicks, tight snares and crisp hi-hats"),
        "mahjong" => new("硬质 · 合成", "Hard · Synthesized", "短促的瓷牌碰击声", "A short ceramic tile clack"),
        "brick" => new("硬质 · 合成", "Hard · Synthesized", "塑料积木卡扣，短而扎实", "The short, solid snap of plastic bricks"),
        "typewriter" => new("复古 · 合成", "Vintage · Synthesized", "金属字锤与短促机械回弹", "Metallic typebars with a short mechanical release"),
        "bubble" => new("轻盈 · 合成", "Light · Synthesized", "柔软啵声，轻盈弹开", "A soft, light bubble pop"),
        "raindrop" => new("轻盈 · 合成", "Light · Synthesized", "清脆的单颗水滴声", "A single, crisp falling drop"),
        "woodblock" => new("自然拟音 · 合成", "Foley · Synthesized", "温暖木质敲击，干净收尾", "Warm wood tap with a clean tail"),
        "paper" => new("自然拟音 · 合成", "Foley · Synthesized", "短促纸张揉折与轻擦", "Short paper folds and rustles"),
        "arcade" => new("电子 · 合成", "Electronic · Synthesized", "复古像素短音", "Short retro arcade notes"),
        "laser" => new("电子 · 合成", "Electronic · Synthesized", "轻巧科幻扫频，快速收尾", "Light sci-fi sweep with a fast tail"),
        _ when preset.Category == SoundCategory.Synthesized => new("合成", "Synthesized", "键舞合成音效", "A KeyWoo synthesized sound"),
        _ => new("实录", "Recorded", "真实录音采样", "Samples from a live recording")
    };

    private string RecordingDescription(SoundPreset preset) => preset.Id switch {
        "rainy75" or "unicomp" or "technicsYellow" or "laneAlps" =>
            T("从真实打字录音选出多组敲击，并按音色分组。每段敲击在按下时完整播放。",
                "Keystrokes are taken from a live typing recording and grouped by timbre. Each sample plays in full on press."),
        "whiteFox" or "macbookPro" =>
            T("从录音中分离触底与回弹，再按音色分组。原录音未标注键位。",
                "Press and release sounds are separated and grouped by timbre. The source recording has no key labels."),
        "panda" => T("五种普通键录音，空格、回车和退格分别采录。",
            "Five recordings cover ordinary keys, with dedicated space, Enter and Backspace recordings."),
        "hermes" => T("Hermes Precisa 305 实录。空格保留原机空格声，回车播放原机行尾铃。",
            "A Hermes Precisa 305 recording, with its spacebar on Space and its carriage bell on Enter."),
        "mahjongTiles" or "woodDesk" => T("从实物录音选取独立短音，大键用另一组敲击，松开时静音。",
            "Short sounds isolated from a real recording. Larger keys use distinct taps and release is silent."),
        "streetBeat" => T("空格是底鼓，回车是军鼓，Shift 是拍手，字母是闭镲。",
            "Space plays a kick, Enter a snare, Shift a clap and letters a closed hi-hat."),
        _ when preset.Category == SoundCategory.Synthesized => T("普通键和大键有不同音色，按下与松开各有细微变化。",
            "Regular keys and larger keys have distinct sounds, with subtle press and release variations."),
        _ => T("部分键位复用音色相近的实录。能清楚分离的回弹跟随松开。",
            "Keys with similar sounds share some recordings. Isolated release sounds play on key up.")
    };

    private string RecordingCredit(SoundPreset preset) => preset.Id switch {
        "panda" => "Thomas Lai / kbsim",
        "macbookPro" or "hermes" or "woodDesk" => "Joseph Sardin / BigSoundBank",
        "mahjongTiles" => "Detective_Lemons / Freesound",
        "rainy75" => "Techrul / Freesound",
        "whiteFox" => "grcekh / Freesound",
        "unicomp" => "SamsterBirdies / Freesound",
        "technicsYellow" or "laneAlps" => "zrrion / Freesound",
        _ when preset.Category == SoundCategory.Synthesized => T("键舞合成音效", "Synthesized by KeyWoo"),
        _ => "Hải Nguyễn / Mechvibes"
    };

    private UIElement SoundIcon(CatalogCategory category) {
        var icon = WorkspaceIcon(category == CatalogCategory.Recorded
            ? "M 1,4 H 15 V 12 H 1 Z M 4,7 H 5 M 7.5,7 H 8.5 M 11,7 H 12 M 5,9.5 H 11"
            : "M 1,8 H 3 L 5,4 L 7,12 L 10,2 L 12,10 L 14,8 H 16", Brush("AccentBrush"));
        icon.Width = 23;
        icon.Height = 23;
        return icon;
    }

    private Border SoundDivider(double top, double bottom) => new() {
        Background = Brush("LineBrush"), Height = 1, Margin = new Thickness(0, top, 0, bottom)
    };
}
