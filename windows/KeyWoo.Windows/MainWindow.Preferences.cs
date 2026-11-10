using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace KeyWoo.Windows;

public sealed partial class MainWindow {
    private UIElement Preferences() {
        var panel=Panel();var general=Panel();general.Children.Add(SectionTitle(T("通用","General")));
        var languages=new ComboBox{ItemsSource=new KeyValuePair<string,string>[]{new("system",T("跟随系统","System")),new("zh","简体中文"),new("en","English")},DisplayMemberPath="Value",SelectedValuePath="Key",SelectedValue=settings.Language,Width=200,HorizontalAlignment=HorizontalAlignment.Right};
        AutomationProperties.SetAutomationId(languages,"app-language");
        languages.SelectionChanged+=(_,_)=>{if(building||languages.SelectedValue is not string language)return;settings.Language=language;SaveSoon();Dispatcher.InvokeAsync(()=>{Build();if(!verificationOnly)SetupTray();});};general.Children.Add(PreferenceRow(T("语言","Language"),languages));
        var appearance=new ComboBox{ItemsSource=new KeyValuePair<string,string>[]{new("system",T("跟随系统","System")),new("light",T("浅色","Light")),new("dark",T("深色","Dark"))},DisplayMemberPath="Value",SelectedValuePath="Key",SelectedValue=settings.Appearance,Width=200,HorizontalAlignment=HorizontalAlignment.Right};
        AutomationProperties.SetAutomationId(appearance,"app-appearance");
        appearance.SelectionChanged+=(_,_)=>{if(building||appearance.SelectedValue is not string value)return;settings.Appearance=value;SaveSoon();Dispatcher.InvokeAsync(Build);};general.Children.Add(PreferenceRow(T("外观","Appearance"),appearance));panel.Children.Add(Card(general));
        var audioPanel=Panel();audioPanel.Children.Add(SectionTitle(T("声音输出","Audio output"),T("声音跟随 Windows 默认输出设备，切换耳机后会自动重连。蓝牙播放延迟取决于系统和耳机。","Sound follows the default Windows output and reconnects when it changes. Bluetooth latency depends on Windows and your headphones.")));
        var reconnect=MakeButton(T("重新连接声音","Reconnect audio"),(_,_)=>{
            if(audio is null){ShowError(T("录音尚未加载，请重启应用。","Recordings are unavailable. Please restart KeyWoo."));return;}
            try{audio.Restart();ClearAudioError();}catch(Exception ex){ShowAudioError(ex.Message);}
        });reconnect.Margin=new Thickness(0);audioPanel.Children.Add(PreferenceRow(T("跟随系统默认设备","Use the default system device"),reconnect));panel.Children.Add(Card(audioPanel));
        var privacy=Panel();privacy.Children.Add(SectionTitle(T("使用与隐私","Use and privacy"),T("只在这台电脑上保存各键的次数。不会保存输入文字、按键顺序、剪贴板或其他应用的内容。改键是电脑侧映射，不会修改键盘固件。","Per-key totals stay on this PC. Typed text, key order, the clipboard and content from other apps are not saved. Remapping happens on this computer and never changes keyboard firmware.")));
        privacy.Children.Add(Text(T("只记次数，不记文字。","Key counts only. Never typed text."),13));panel.Children.Add(Card(privacy));
        var appPanel=Panel();appPanel.Children.Add(SectionTitle(T("关于键舞","About KeyWoo")));
        appPanel.Children.Add(Text("KeyWoo " + (typeof(MainWindow).Assembly.GetName().Version?.ToString(3)??"1.0.0"),13));
        appPanel.Children.Add(Text(T("关闭窗口后会继续运行，可从系统托盘打开或退出。","KeyWoo keeps running when its window closes. Open or quit it from the system tray."),12,true));
        var data=MakeButton(T("打开数据文件夹","Open data folder"),(_,_)=>{Directory.CreateDirectory(Settings.DataDirectory);OpenFile(Settings.DataDirectory);});data.HorizontalAlignment=HorizontalAlignment.Left;data.Margin=new Thickness(0,12,0,0);appPanel.Children.Add(data);panel.Children.Add(Card(appPanel));return panel;
    }
    private DockPanel PreferenceRow(string label,UIElement control) {
        var row=new DockPanel{Margin=new Thickness(0,6,0,6),LastChildFill=true};DockPanel.SetDock(control,Dock.Right);row.Children.Add(control);
        var text=Text(label,13);text.VerticalAlignment=VerticalAlignment.Center;text.Margin=new Thickness(0,0,16,0);row.Children.Add(text);return row;
    }
}
