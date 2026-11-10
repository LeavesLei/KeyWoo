using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Markup;
using System.Windows.Threading;

namespace KeyWoo.Windows;

public sealed partial class MainWindow {
    private void Build() {
        int previousTab=tabs?.SelectedIndex??0;
        var scrollOffsets=pageScrollers.ToDictionary(p=>p.Key,p=>p.Value.VerticalOffset);
        var previousSource=(sourceKey.SelectedItem as KeyOption)?.Key??0x14;
        var previousTarget=(targetKey.SelectedItem as KeyOption)?.Key??0x1B;
        var previousSourceModifiers=Modifiers(sourceModifiers);var previousTargetModifiers=Modifiers(targetModifiers);
        building=true;Language=XmlLanguage.GetLanguage(Chinese?"zh-CN":"en-US");Title=Chinese?"键舞":"KeyWoo";
        var previousPractice=practice?.Text??"";ApplyTheme();InterfaceStyles.Apply(this);presetButtons.Clear();keyButtons.Clear();
        soundPreviewButtons.Clear();navigationButtons.Clear();pageScrollers.Clear();desktopStyleButtons.Clear();
        var shell=new Grid{Background=Brush("PageBrush")};shell.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(184)});shell.ColumnDefinitions.Add(new ColumnDefinition());
        var sidebar=new DockPanel{Background=Brush("SidebarBrush"),Margin=new Thickness(0)};
        var brand=new StackPanel{Margin=new Thickness(22,28,18,30)};
        brand.Children.Add(new TextBlock{Text=Title,FontSize=23,FontWeight=FontWeights.SemiBold,Foreground=Brush("TextBrush")});
        
        DockPanel.SetDock(brand,Dock.Top);sidebar.Children.Add(brand);
        var footer=new StackPanel{Margin=new Thickness(12,12,12,14)};
        footer.Children.Add(NavigationItem(3,T("偏好设置","Preferences")));
        footer.Children.Add(new Border{Height=1,Background=Brush("LineBrush"),Margin=new Thickness(8,10,8,12)});
        status=Text("",11,true);status.Margin=new Thickness(10,0,0,0);footer.Children.Add(status);
        DockPanel.SetDock(footer,Dock.Bottom);sidebar.Children.Add(footer);
        var navigation=new StackPanel{Margin=new Thickness(12,0,12,0)};
        foreach(var (index,label) in new[]{(0,T("音效","Sounds")),(4,T("桌面特效","Desktop effects")),(2,T("改键","Remapping")),(1,T("统计","Statistics"))})
            navigation.Children.Add(NavigationItem(index,label));
        sidebar.Children.Add(navigation);shell.Children.Add(sidebar);
        var workspace=new DockPanel{Margin=new Thickness(26,24,26,0)};Grid.SetColumn(workspace,1);shell.Children.Add(workspace);
        var header=new DockPanel{Margin=new Thickness(0,0,0,18)};
        pause=MakeButton("",(_,_)=>ToggleEnabled());pause.MinWidth=104;pause.Margin=new Thickness(16,0,0,0);pause.VerticalAlignment=VerticalAlignment.Center;
        AutomationProperties.SetAutomationId(pause,"pause-all");
        pause.ToolTip=T("暂停音效、统计、桌面律动与改键。","Pauses sounds, statistics, desktop animation and remapping.");
        DockPanel.SetDock(pause,Dock.Right);header.Children.Add(pause);
        var heading=new StackPanel();pageTitle=Text("",24);AutomationProperties.SetAutomationId(pageTitle,"workspace-page-title");pageTitle.FontWeight=FontWeights.SemiBold;heading.Children.Add(pageTitle);
        header.Children.Add(heading);
        DockPanel.SetDock(header,Dock.Top);workspace.Children.Add(header);
        error=Text("",12);error.TextWrapping=TextWrapping.Wrap;
        var errorRow=new DockPanel();var dismiss=MakeButton(T("关闭","Dismiss"),(_,_)=>{currentError=null;if(errorNotice is not null)errorNotice.Visibility=Visibility.Collapsed;});
        dismiss.Padding=new Thickness(9,4,9,4);dismiss.Margin=new Thickness(12,0,0,0);DockPanel.SetDock(dismiss,Dock.Right);errorRow.Children.Add(dismiss);errorRow.Children.Add(error);
        errorNotice=new Border{Child=errorRow,Padding=new Thickness(12),Background=Brush("SelectedBrush"),CornerRadius=new CornerRadius(10),Margin=new Thickness(0,0,0,12),Visibility=Visibility.Collapsed};
        DockPanel.SetDock(errorNotice,Dock.Bottom);workspace.Children.Add(errorNotice);
        tabs=new TabControl{Background=Brush("PageBrush"),BorderThickness=new Thickness(0)};
        var host=new FrameworkElementFactory(typeof(ContentPresenter));
        host.SetBinding(ContentPresenter.ContentProperty,new Binding(nameof(TabControl.SelectedContent)){RelativeSource=new RelativeSource(RelativeSourceMode.TemplatedParent)});
        tabs.Template=new ControlTemplate(typeof(TabControl)){VisualTree=host};
        tabs.Items.Add(new TabItem{Header=T("音效","Sounds"),Content=PageScroll(0,Sounds())});
        tabs.Items.Add(new TabItem{Header=T("统计","Statistics"),Content=PageScroll(1,Statistics())});
        tabs.Items.Add(new TabItem{Header=T("改键","Remapping"),Content=PageScroll(2,Mapping())});
        tabs.Items.Add(new TabItem{Header=T("偏好设置","Preferences"),Content=PageScroll(3,Preferences())});
        tabs.Items.Add(new TabItem{Header=T("桌面特效","Desktop effects"),Content=PageScroll(4,DesktopEffects())});
        tabs.SelectionChanged+=(_,e)=>{if(e.Source==tabs)UpdateNavigation();};
        tabs.SelectedIndex=Math.Clamp(previousTab,0,4);workspace.Children.Add(tabs);Content=shell;
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
        if(pageTitle is not null)pageTitle.Text=selected switch{1=>T("按键统计","Key statistics"),2=>T("改键","Remapping"),3=>T("偏好设置","Preferences"),4=>T("桌面特效","Desktop effects"),_=>T("键盘音效","Keyboard sounds")};

    }
    private Button NavigationItem(int index,string title) {
        var item=MakeButton(title,(_,_)=>{if(tabs is not null)tabs.SelectedIndex=index;});
        item.HorizontalContentAlignment=HorizontalAlignment.Left;item.MinHeight=42;item.Margin=new Thickness(0,0,0,6);item.Padding=new Thickness(14,9,12,9);
        AutomationProperties.SetAutomationId(item,"navigation-"+index);navigationButtons[index]=item;return item;
    }
}
