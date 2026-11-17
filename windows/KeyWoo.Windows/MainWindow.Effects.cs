using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using KeyWoo.Core;

namespace KeyWoo.Windows;

public sealed partial class MainWindow {
    private readonly Dictionary<string, TextBlock> desktopStyleIndicators = [];
    private FrameworkElement? desktopAudioCard;
    private Ellipse? desktopStatusDot;
    private bool effectDetailsExpanded;

    private UIElement DesktopEffects() {
        desktopStyleIndicators.Clear();
        var page = Panel();
        var chooser = Panel();
        chooser.Children.Add(DesktopEffectsHeader());

        var choices = new Grid { Margin = new Thickness(0, 14, 0, 0) };
        choices.ColumnDefinitions.Add(new ColumnDefinition());
        choices.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(10) });
        choices.ColumnDefinitions.Add(new ColumnDefinition());
        foreach (var (style, title, column) in new[] {
            ("edgeGlow", T("底部泛光", "Bottom Glow"), 0),
            ("burst", T("键阵爆破", "Key Burst"), 2)
        }) {
            var option = DesktopStyleOption(style, title);
            Grid.SetColumn(option, column);
            choices.Children.Add(option);
        }
        chooser.Children.Add(choices);
        page.Children.Add(Card(chooser));

        var adjustments = Panel();
        adjustments.Children.Add(KeyBurstSlider(T("动画幅度", "Motion intensity"),
            T("只改变动画的起伏幅度。", "Adjusts how strongly the animation moves."),
            "key-burst-intensity", .25, 1, ControlScale.RhythmIntensity.DisplayValue(settings.KeyBurstIntensity),
            value => settings.KeyBurstIntensity = ControlScale.RhythmIntensity.StoredValue(value)));
        adjustments.Children.Add(EffectDivider());
        adjustments.Children.Add(KeyBurstSlider(T("特效透明度", "Effect opacity"),
            T("数值越低越淡，100% 保持原始亮度。", "Lower values fade the effect. At 100% it keeps its original brightness."),
            "key-burst-opacity", .25, 1, settings.KeyBurstBrightness, value => settings.KeyBurstBrightness = value));
        desktopAudioCard = DesktopAudioSettings();
        adjustments.Children.Add(desktopAudioCard);
        adjustments.Children.Add(EffectDivider());

        var more = new Expander {
            Header = T("更多选项", "More options"),
            IsExpanded = effectDetailsExpanded
        };
        AutomationProperties.SetAutomationId(more, "effects-more-options");
        more.Expanded += (_, _) => effectDetailsExpanded = true;
        more.Collapsed += (_, _) => effectDetailsExpanded = false;
        var flashes = new CheckBox {
            Content = T("闪光效果", "Flashes"),
            IsChecked = settings.KeyBurstFlashes,
            VerticalAlignment = VerticalAlignment.Center
        };
        AutomationProperties.SetAutomationId(flashes, "key-burst-flashes");
        flashes.Click += (_, _) => {
            settings.KeyBurstFlashes = flashes.IsChecked == true;
            UpdateKeyBurst();
            SaveSoon();
        };
        var flashRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(4, 0, 0, 6) };
        flashRow.Children.Add(flashes);
        flashRow.Children.Add(Help(T("允许按键触发短暂亮光。", "Lets keystrokes trigger brief flashes.")));
        more.Content = flashRow;
        adjustments.Children.Add(more);
        var controls = Card(adjustments);
        controls.Padding = new Thickness(18, 4, 18, 4);
        page.Children.Add(controls);

        UpdateDesktopControls();
        return page;
    }

    private DockPanel DesktopEffectsHeader() {
        var header = new DockPanel { MinHeight = 34 };
        desktopEnabled = EffectSwitch(T("启用特效", "Enable effects"), "key-burst-enabled", settings.KeyBurstEnabled);
        desktopEnabled.Margin = new Thickness(10, 0, 0, 0);
        desktopEnabled.Click += (_, _) => {
            settings.KeyBurstEnabled = desktopEnabled.IsChecked == true;
            UpdateKeyBurst();
            SaveSoon();
        };
        DockPanel.SetDock(desktopEnabled, Dock.Right);
        header.Children.Add(desktopEnabled);

        keyBurstPreview = MakeButton("", (_, _) => PreviewDesktopEffect());
        keyBurstPreview.Margin = new Thickness(10, 0, 0, 0);
        keyBurstPreview.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetAutomationId(keyBurstPreview, "key-burst-preview");
        DockPanel.SetDock(keyBurstPreview, Dock.Right);
        header.Children.Add(keyBurstPreview);

        var status = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        desktopStatusDot = new Ellipse { Width = 6, Height = 6, Margin = new Thickness(0, 0, 8, 0) };
        status.Children.Add(desktopStatusDot);
        var help = Help(T("选择样式会开启并演示。打字点亮特效，停手后渐隐；底部泛光不会挡住鼠标。",
            "Choose a style to enable and preview it. Effects light up when you type and fade when you stop. Clicks pass through Bottom Glow."));
        desktopStatus = Text("", 13);
        desktopStatus.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetAutomationId(desktopStatus, "desktop-effects-status");
        status.Children.Add(desktopStatus);
        status.Children.Add(help);
        header.Children.Add(status);
        return header;
    }

    private CheckBox EffectSwitch(string title, string id, bool isChecked) {
        var toggle = new CheckBox { Content = title, IsChecked = isChecked, Style = (Style)Resources["WorkspaceSwitchStyle"] };
        AutomationProperties.SetAutomationId(toggle, id);
        AutomationProperties.SetName(toggle, title);
        return toggle;
    }

    private Button DesktopStyleOption(string style, string title) {
        var content = Panel();
        content.Children.Add(new DesktopEffectThumbnail(style, Brush("RaisedBrush"), Brush("LineBrush"), Brush("AccentBrush")) {
            Height = 58, Margin = new Thickness(0, 0, 0, 9)
        });
        var caption = new DockPanel();
        var selection = Text("✓", 13);
        selection.Width = 18;
        selection.TextAlignment = TextAlignment.Right;
        selection.Foreground = Brush("AccentBrush");
        DockPanel.SetDock(selection, Dock.Right);
        caption.Children.Add(selection);
        desktopStyleIndicators[style] = selection;
        caption.Children.Add(new TextBlock {
            Text = title, FontSize = 13, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis
        });
        content.Children.Add(caption);

        var button = MakeButton("", (_, _) => SelectDesktopStyle(style));
        button.Content = content;
        button.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        button.Padding = new Thickness(9);
        AutomationProperties.SetAutomationId(button, "desktop-style-" + style);
        AutomationProperties.SetName(button, title);
        desktopStyleButtons[style] = button;
        return button;
    }

    private FrameworkElement DesktopAudioSettings() {
        var panel = Panel();
        panel.Children.Add(EffectDivider());
        var audio = new DockPanel { MinHeight = 48 };
        string title = T("跟随电脑声音", "Follow computer audio");
        var follow = EffectSwitch(title, "rhythm-follow-audio", settings.FollowSystemAudio);
        follow.Click += (_, _) => {
            settings.FollowSystemAudio = follow.IsChecked == true;
            UpdateKeyBurst();
            SaveSoon();
        };
        DockPanel.SetDock(follow, Dock.Right);
        audio.Children.Add(follow);
        audio.Children.Add(EffectControlLabel(title,
            T("低音推动柔光，中高音带动波形。分析在电脑上即时进行，不使用麦克风，不保存录音。",
              "Bass shapes the glow, and mids and treble shape the wave. Analysis runs on this PC, without a microphone or saved recordings.")));
        panel.Children.Add(audio);

        var state = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        systemAudioRetry = MakeButton(T("重试", "Retry"), (_, _) => systemAudio.Retry());
        AutomationProperties.SetAutomationId(systemAudioRetry, "rhythm-audio-retry");
        DockPanel.SetDock(systemAudioRetry, Dock.Right);
        state.Children.Add(systemAudioRetry);
        systemAudioStatus = Text("", 12, true);
        systemAudioStatus.VerticalAlignment = VerticalAlignment.Center;
        state.Children.Add(systemAudioStatus);
        panel.Children.Add(state);
        return panel;
    }

    private void SelectDesktopStyle(string style) {
        settings.DesktopStyle = style;
        settings.KeyBurstEnabled = true;
        UpdateKeyBurst();
        SaveSoon();
        if (enabled && !sessionLocked && !powerSuspended && !closing) keyBurst.Preview();
    }

    private void PreviewDesktopEffect() {
        if (!enabled || sessionLocked || powerSuspended || closing) return;
        settings.KeyBurstEnabled = true;
        UpdateKeyBurst();
        SaveSoon();
        keyBurst.Preview();
    }

    private void UpdateDesktopControls() {
        bool suspended = !enabled || sessionLocked || powerSuspended || closing;
        if (desktopEnabled is not null) desktopEnabled.IsChecked = settings.KeyBurstEnabled;
        if (keyBurstPreview is not null) {
            keyBurstPreview.Content = settings.KeyBurstEnabled ? T("演示", "Preview") : T("开启并演示", "Enable & preview");
            keyBurstPreview.IsEnabled = !suspended;
            keyBurstPreview.ToolTip = suspended ? T("继续后可演示。", "Resume KeyWoo to preview.")
                : T("只演示画面，不发声、不计数。", "Visual preview only. No sound or key counts.");
        }
        if (desktopStatusDot is not null)
            desktopStatusDot.Fill = Brush(settings.KeyBurstEnabled && !suspended ? "AccentBrush" : "MutedBrush");
        if (desktopStatus is not null)
            desktopStatus.Text = !settings.KeyBurstEnabled ? T("选择样式即可开启", "Choose a style to enable")
                : suspended ? T("已暂停，继续后显示", "Paused · Appears after resuming")
                : T("已开启 · 打字时显示", "Enabled · Appears as you type");
        foreach (var (style, button) in desktopStyleButtons) {
            bool selected = style == settings.DesktopStyle;
            button.Background = Brush(selected ? "SelectedBrush" : "CardBrush");
            button.BorderBrush = Brush(selected ? "AccentBrush" : "LineBrush");
            button.Foreground = Brush(selected ? "AccentBrush" : "TextBrush");
            desktopStyleIndicators[style].Visibility = selected ? Visibility.Visible : Visibility.Hidden;
            button.ToolTip = suspended ? T("选好样式，继续后显示。", "Choose a style. Resume KeyWoo to use it.")
                : T("选择并演示此特效", "Select and preview this effect");
            AutomationProperties.SetItemStatus(button, selected ? T("已选择", "Selected") : T("未选择", "Not selected"));
        }
        if (desktopAudioCard is not null)
            desktopAudioCard.Visibility = settings.DesktopStyle == "edgeGlow" ? Visibility.Visible : Visibility.Collapsed;
        UpdateSystemAudioState();
    }

    private DockPanel KeyBurstSlider(string title, string explanation, string id, double minimum, double maximum,
                                    double value, Action<double> save) {
        var row = new DockPanel { MinHeight = 48 };
        var label = EffectControlLabel(title, explanation);
        label.Width = 164;
        DockPanel.SetDock(label, Dock.Left);
        row.Children.Add(label);
        var percent = Text(value.ToString("P0", CultureInfo.CurrentCulture), 12, true);
        percent.Width = 52;
        percent.TextAlignment = TextAlignment.Right;
        percent.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(percent, Dock.Right);
        row.Children.Add(percent);
        var slider = new Slider {
            Minimum = minimum, Maximum = maximum, Value = value, SmallChange = .01, LargeChange = .05,
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0)
        };
        AutomationProperties.SetAutomationId(slider, id);
        AutomationProperties.SetName(slider, title);
        slider.ValueChanged += (_, _) => {
            save(slider.Value);
            percent.Text = slider.Value.ToString("P0", CultureInfo.CurrentCulture);
            UpdateKeyBurst();
            SaveSoon();
        };
        row.Children.Add(slider);
        return row;
    }

    private StackPanel EffectControlLabel(string title, string explanation) {
        var label = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var text = Text(title, 13);
        text.VerticalAlignment = VerticalAlignment.Center;
        label.Children.Add(text);
        label.Children.Add(Help(explanation));
        return label;
    }

    private Border EffectDivider() => new() { Height = 1, Background = Brush("LineBrush") };

    private void UpdateSystemAudioState() {
        keyBurst.SetAudioSource(systemAudio.Snapshot, systemAudio.State == SystemAudioState.Running);
        bool show = settings.FollowSystemAudio && settings.KeyBurstEnabled;
        if (systemAudioStatus is not null) {
            systemAudioStatus.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
            systemAudioStatus.Text = systemAudio.State switch {
                SystemAudioState.Starting => T("正在连接电脑声音…", "Connecting to computer audio…"),
                SystemAudioState.Running => T("已连接电脑声音 · 没有声音时自然淡出", "Connected to computer audio · Fades during silence"),
                SystemAudioState.Failed => T("暂时无法读取电脑声音，请检查播放设备。", "Computer audio is unavailable. Check your output device."),
                _ => !enabled ? T("继续运行后连接。", "Resume KeyWoo to connect.") : T("等待电脑声音…", "Waiting for computer audio…")
            };
        }
        if (systemAudioRetry is not null)
            systemAudioRetry.Visibility = show && systemAudio.State == SystemAudioState.Failed ? Visibility.Visible : Visibility.Collapsed;
    }
}

internal sealed class DesktopEffectThumbnail(string style, Brush surface, Brush outline, Brush accent) : FrameworkElement {
    protected override void OnRender(DrawingContext context) {
        base.OnRender(context);
        context.DrawRoundedRectangle(surface, null, new Rect(RenderSize), 6, 6);
        double center = ActualWidth / 2;
        if (style == "edgeGlow") {
            double screenWidth = Math.Min(ActualWidth - 28, 240);
            if (screenWidth <= 0) return;
            context.DrawRoundedRectangle(null, new Pen(outline, 1), new Rect(center - screenWidth / 2, 9, screenWidth, 40), 5, 5);
            for (int ring = 0; ring < 4; ring++) {
                context.PushOpacity(.06 + .04 * ring);
                context.DrawEllipse(accent, null, new Point(center, 45), screenWidth * (.39 - .04 * ring), 9 - 1.5 * ring);
                context.Pop();
            }
            context.DrawRoundedRectangle(accent, null, new Rect(center - screenWidth * .24, 47, screenWidth * .48, 2), 1, 1);
            return;
        }

        double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        string keys = "ASD";
        for (int index = 0; index < keys.Length; index++) {
            double offset = index - 1;
            double x = center + offset * 25;
            double y = index == 1 ? 22 : 36;
            context.PushTransform(new RotateTransform(offset * 12, x, y));
            context.PushOpacity(.13);
            context.DrawRoundedRectangle(accent, null, new Rect(x - 10.5, y - 11.5, 21, 23), 5, 5);
            context.Pop();
            var glyph = new FormattedText(keys[index].ToString(), CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                                          new Typeface("Segoe UI Semibold"), 12, accent, dpi);
            context.DrawText(glyph, new Point(x - glyph.Width / 2, y - glyph.Height / 2));
            context.Pop();
        }
    }
}
