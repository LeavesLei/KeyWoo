using Microsoft.Win32;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Threading;

namespace KeyWoo.Windows;

public sealed partial class MainWindow {
    private const double WorkspaceContentWidth = 1100;
    private const double WorkspaceInset = 24;

    private void Build() {
        int previousTab = tabs?.SelectedIndex ?? 0;
        var scrollOffsets = pageScrollers.ToDictionary(entry => entry.Key, entry => entry.Value.VerticalOffset);
        int previousSource = (sourceKey.SelectedItem as KeyOption)?.Key ?? 0x14;
        int previousTarget = (targetKey.SelectedItem as KeyOption)?.Key ?? 0x1B;
        var previousSourceModifiers = Modifiers(sourceModifiers);
        var previousTargetModifiers = Modifiers(targetModifiers);
        string previousPractice = practice?.Text ?? "";

        building = true;
        Language = XmlLanguage.GetLanguage(Chinese ? "zh-CN" : "en-US");
        Title = T("键舞", "KeyWoo");
        ApplyTheme();
        InterfaceStyles.Apply(this);
        presetButtons.Clear();
        keyButtons.Clear();
        soundPreviewButtons.Clear();
        navigationButtons.Clear();
        pageScrollers.Clear();
        desktopStyleButtons.Clear();

        var shell = new Grid { Background = Brush("PageBrush"), UseLayoutRounding = true };
        shell.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(188) });
        shell.ColumnDefinitions.Add(new ColumnDefinition());
        shell.Children.Add(Sidebar());

        var workspace = new DockPanel();
        Grid.SetColumn(workspace, 1);
        var toolbar = WorkspaceToolbar();
        DockPanel.SetDock(toolbar, Dock.Top);
        workspace.Children.Add(toolbar);
        workspace.Children.Add(WorkspaceTabs(previousTab));
        shell.Children.Add(workspace);
        Content = shell;

        if (practice is not null) practice.Text = previousPractice;
        sourceKey.SelectedValue = previousSource;
        targetKey.SelectedValue = previousTarget;
        foreach (var (modifier, check) in sourceModifiers) check.IsChecked = previousSourceModifiers.HasFlag(modifier);
        foreach (var (modifier, check) in targetModifiers) check.IsChecked = previousTargetModifiers.HasFlag(modifier);
        if (currentError is not null) ShowError(currentError);
        building = false;
        UpdatePause();
        UpdateNavigation();
        UpdatePresets();
        statisticsPanel?.RefreshIfNeeded(true);
        Dispatcher.InvokeAsync(() => {
            foreach (var (index, offset) in scrollOffsets)
                if (pageScrollers.TryGetValue(index, out var scroller)) scroller.ScrollToVerticalOffset(offset);
        }, DispatcherPriority.Loaded);
    }

    private Border Sidebar() {
        var sidebar = new DockPanel { Margin = new Thickness(12, 0, 12, 0) };
        var brand = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(10, 25, 0, 24) };
        var mark = new Border {
            Background = Brush("AccentBrush"), CornerRadius = new CornerRadius(8),
            Height = 30, Width = 30, Margin = new Thickness(0, 0, 9, 0),
            Child = WorkspaceIcon("M 1,4 H 15 V 12 H 1 Z M 4,7 H 5 M 7.5,7 H 8.5 M 11,7 H 12 M 5,9.5 H 11", Brush("OnAccentBrush"))
        };
        brand.Children.Add(mark);
        var brandName = Text(Title, 18);
        brandName.FontWeight = FontWeights.SemiBold;
        brandName.VerticalAlignment = VerticalAlignment.Center;
        brand.Children.Add(brandName);
        DockPanel.SetDock(brand, Dock.Top);
        sidebar.Children.Add(brand);

        var footer = new StackPanel { Margin = new Thickness(0, 0, 0, 12) };
        footer.Children.Add(NavigationItem(3));
        footer.Children.Add(new Border { Height = 1, Background = Brush("LineBrush"), Margin = new Thickness(6, 8, 6, 10) });
        status = Text("", 11, muted: true);
        status.Margin = new Thickness(10, 0, 4, 0);
        footer.Children.Add(status);
        DockPanel.SetDock(footer, Dock.Bottom);
        sidebar.Children.Add(footer);

        var navigation = new StackPanel();
        foreach (int index in new[] { 0, 4, 2, 1 }) navigation.Children.Add(NavigationItem(index));
        sidebar.Children.Add(navigation);
        return new Border {
            Child = sidebar, Background = Brush("SidebarBrush"), BorderBrush = Brush("LineBrush"),
            BorderThickness = new Thickness(0, 0, 1, 0)
        };
    }

    private Border WorkspaceToolbar() {
        var heading = new DockPanel {
            Margin = new Thickness(WorkspaceInset, 0, WorkspaceInset, 0),
            MaxWidth = WorkspaceContentWidth, MinHeight = 70
        };
        pause = MakeButton("", (_, _) => ToggleEnabled());
        pause.MinWidth = 90;
        pause.Padding = new Thickness(14, 6, 14, 6);
        pause.Margin = new Thickness(16, 0, 0, 0);
        pause.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetAutomationId(pause, "pause-all");
        pause.ToolTip = T("暂停音效、统计、桌面律动与改键。", "Pauses sounds, statistics, desktop animation and remapping.");
        DockPanel.SetDock(pause, Dock.Right);
        heading.Children.Add(pause);
        pageTitle = Text("", 23);
        pageTitle.FontWeight = FontWeights.SemiBold;
        pageTitle.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetAutomationId(pageTitle, "workspace-page-title");
        heading.Children.Add(pageTitle);

        var chrome = new DockPanel();
        error = Text("", 12);
        var errorRow = new DockPanel();
        var dismiss = MakeButton(T("关闭", "Dismiss"), (_, _) => {
            currentError = null;
            if (errorNotice is not null) errorNotice.Visibility = Visibility.Collapsed;
        });
        dismiss.Padding = new Thickness(9, 4, 9, 4);
        dismiss.Margin = new Thickness(12, 0, 0, 0);
        DockPanel.SetDock(dismiss, Dock.Right);
        errorRow.Children.Add(dismiss);
        errorRow.Children.Add(error);
        errorNotice = new Border {
            Child = errorRow, Padding = new Thickness(10), Background = Brush("SelectedBrush"),
            MaxWidth = WorkspaceContentWidth, CornerRadius = new CornerRadius(8),
            Margin = new Thickness(WorkspaceInset, 0, WorkspaceInset, 10), Visibility = Visibility.Collapsed
        };
        DockPanel.SetDock(errorNotice, Dock.Bottom);
        chrome.Children.Add(errorNotice);
        chrome.Children.Add(heading);
        return new Border {
            Child = chrome, Background = Brush("ToolbarBrush"), BorderBrush = Brush("LineBrush"),
            BorderThickness = new Thickness(0, 0, 0, 1), Padding = new Thickness(0, 0, SystemParameters.VerticalScrollBarWidth, 0)
        };
    }

    private TabControl WorkspaceTabs(int previousTab) {
        tabs = new TabControl { Background = Brush("PageBrush"), BorderThickness = new Thickness(0) };
        var host = new FrameworkElementFactory(typeof(ContentPresenter));
        host.SetBinding(ContentPresenter.ContentProperty,
            new Binding(nameof(TabControl.SelectedContent)) { RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent) });
        tabs.Template = new ControlTemplate(typeof(TabControl)) { VisualTree = host };
        foreach (var (index, content) in new[] {
            (0, Sounds()), (1, Statistics()), (2, Mapping()), (3, Preferences()), (4, DesktopEffects())
        }) {
            tabs.Items.Add(new TabItem { Header = WorkspaceTitle(index), Content = PageScroll(index, content) });
        }
        tabs.SelectionChanged += (_, eventArgs) => { if (eventArgs.Source == tabs) UpdateNavigation(); };
        tabs.SelectedIndex = Math.Clamp(previousTab, 0, 4);
        return tabs;
    }

    private ScrollViewer PageScroll(int index, UIElement child) {
        var column = new Border { Child = child, MaxWidth = WorkspaceContentWidth };
        var scroll = new ScrollViewer {
            Content = column, VerticalScrollBarVisibility = ScrollBarVisibility.Visible,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Padding = new Thickness(WorkspaceInset, 20, WorkspaceInset, 14)
        };
        pageScrollers[index] = scroll;
        return scroll;
    }

    private string WorkspaceTitle(int index) => index switch {
        1 => T("按键统计", "Key statistics"),
        2 => T("改键", "Remapping"),
        3 => T("偏好设置", "Preferences"),
        4 => T("桌面特效", "Desktop effects"),
        _ => T("键盘音效", "Keyboard sounds")
    };

    private void UpdateNavigation() {
        int selected = tabs?.SelectedIndex ?? 0;
        foreach (var (index, button) in navigationButtons) {
            bool active = index == selected;
            button.Background = active ? Brush("SelectedBrush") : Brushes.Transparent;
            button.BorderBrush = active && SystemParameters.HighContrast ? Brush("AccentBrush") : Brushes.Transparent;
            button.Foreground = Brush(active ? "AccentBrush" : "TextBrush");
            button.FontWeight = active ? FontWeights.SemiBold : FontWeights.Normal;
            AutomationProperties.SetItemStatus(button, active ? T("已选择", "Selected") : T("未选择", "Not selected"));
        }
        if (pageTitle is not null) pageTitle.Text = WorkspaceTitle(selected);
    }

    private Button NavigationItem(int index) {
        string title = WorkspaceTitle(index);
        var item = MakeButton("", (_, _) => { if (tabs is not null) tabs.SelectedIndex = index; });
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        string geometry = index switch {
            1 => "M 2,14 H 14 M 3,12 V 8 M 7,12 V 5 M 11,12 V 2",
            2 => "M 2,5 H 14 M 11,2 L 14,5 L 11,8 M 14,11 H 2 M 5,8 L 2,11 L 5,14",
            3 => "M 2,4 H 14 M 2,8 H 14 M 2,12 H 14 M 6,2 V 6 M 10,6 V 10 M 6,10 V 14",
            4 => "M 1,12 H 15 M 2,9 C 5,9 5,5 8,5 C 11,5 11,9 14,9",
            _ => "M 1,4 H 15 V 12 H 1 Z M 4,7 H 5 M 7.5,7 H 8.5 M 11,7 H 12 M 5,9.5 H 11"
        };
        var icon = WorkspaceIcon(geometry, Brush("MutedBrush"));
        icon.SetBinding(System.Windows.Shapes.Path.StrokeProperty, new Binding(nameof(Foreground)) { Source = item });
        icon.Margin = new Thickness(0, 0, 10, 0);
        row.Children.Add(icon);
        var label = new TextBlock { Text = title, FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(label);
        item.Content = row;
        item.HorizontalContentAlignment = HorizontalAlignment.Left;
        item.MinHeight = 38;
        item.Margin = new Thickness(0, 0, 0, 3);
        item.Padding = new Thickness(10, 7, 8, 7);
        AutomationProperties.SetName(item, title);
        AutomationProperties.SetAutomationId(item, "navigation-" + index);
        navigationButtons[index] = item;
        return item;
    }

    private static System.Windows.Shapes.Path WorkspaceIcon(string data, Brush stroke) => new() {
        Data = Geometry.Parse(data), Stroke = stroke, StrokeThickness = 1.35,
        StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
        StrokeLineJoin = PenLineJoin.Round, Width = 16, Height = 16, Stretch = Stretch.Uniform,
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        IsHitTestVisible = false
    };

    private void ApplyTheme() {
        bool dark = settings.Appearance == "dark";
        if (settings.Appearance == "system") {
            try {
                dark = (int?)Registry.GetValue(
                    @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                    "AppsUseLightTheme", 1) == 0;
            } catch { dark = false; }
        }
        var palette = new[] {
            ("PageBrush", "#F6F6F4", "#171716", SystemColors.WindowBrush),
            ("SidebarBrush", "#EFEEEb", "#201F1E", SystemColors.ControlBrush),
            ("ToolbarBrush", "#FAF9F7", "#201E1D", SystemColors.ControlBrush),
            ("CardBrush", "#FEFEFC", "#272524", SystemColors.WindowBrush),
            ("RaisedBrush", "#F2F1EE", "#323030", SystemColors.ControlBrush),
            ("SelectedBrush", "#EDE2DC", "#45302C", SystemColors.WindowBrush),
            ("TextBrush", "#27211F", "#F5EFEA", SystemColors.WindowTextBrush),
            ("MutedBrush", "#605752", "#B0A8A3", SystemColors.WindowTextBrush),
            ("LineBrush", "#DDD8D3", "#44413F", SystemColors.WindowTextBrush),
            ("AccentBrush", "#A34030", "#FCA58C", SystemColors.WindowTextBrush),
            ("OnAccentBrush", "#FFFFFF", "#291A17", SystemColors.WindowBrush)
        };
        foreach (var (name, light, night, contrast) in palette) {
            Brush brush = contrast;
            if (!SystemParameters.HighContrast) {
                var color = new SolidColorBrush((Color)ColorConverter.ConvertFromString(dark ? night : light));
                color.Freeze();
                brush = color;
            }
            System.Windows.Application.Current.Resources[name] = brush;
        }
        Background = Brush("PageBrush");
        Foreground = Brush("TextBrush");
    }
}
