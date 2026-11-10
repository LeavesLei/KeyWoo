using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using KeyWoo.Core;

namespace KeyWoo.Windows;

public sealed partial class MainWindow {
    private UIElement DesktopEffects() {
        var page=Panel();
        var activation=Panel();
        var header=new DockPanel();
        keyBurstPreview=MakeButton("",(_,_)=>PreviewDesktopEffect());
        AutomationProperties.SetAutomationId(keyBurstPreview,"key-burst-preview");
        keyBurstPreview.Margin=new Thickness(12,0,0,0);DockPanel.SetDock(keyBurstPreview,Dock.Right);header.Children.Add(keyBurstPreview);
        desktopEnabled=new CheckBox{Content=T("桌面特效","Desktop effects"),IsChecked=settings.KeyBurstEnabled,FontSize=15,FontWeight=FontWeights.SemiBold,VerticalAlignment=VerticalAlignment.Center};
        AutomationProperties.SetAutomationId(desktopEnabled,"key-burst-enabled");
        desktopEnabled.Click+=(_,_)=>{settings.KeyBurstEnabled=desktopEnabled.IsChecked==true;UpdateKeyBurst();SaveSoon();};
        header.Children.Add(desktopEnabled);activation.Children.Add(header);
        desktopStatus=Text("",12,true);desktopStatus.Margin=new Thickness(0,9,0,0);AutomationProperties.SetAutomationId(desktopStatus,"desktop-effects-status");activation.Children.Add(desktopStatus);
        page.Children.Add(Card(activation));

        var styles=Panel();
        styles.Children.Add(SectionTitle(T("选择样式","Choose a style"),T("点击样式即可开启并预览。特效跟随真实按键，停手后自然淡出。预览不播放声音，也不计入按键统计。","Click a style to enable and preview it. Effects follow your keystrokes and fade when you stop. The preview plays no sound and adds no key counts.")));
        var choices=new Grid();choices.ColumnDefinitions.Add(new());choices.ColumnDefinitions.Add(new(){Width=new GridLength(12)});choices.ColumnDefinitions.Add(new());
        foreach(var (style,title,detail,index) in new[]{("burst",T("键阵爆破","Key Burst"),T("发光字符与碎光","Glowing keys and sparks"),0),("edgeGlow",T("底部泛光","Bottom Glow"),T("沿屏幕底边柔和亮起","A soft glow along the screen edge"),2)}) {
            var content=Panel();content.Children.Add(new DesktopEffectThumbnail(style){Height=108,Margin=new Thickness(0,0,0,12)});
            content.Children.Add(Text(title,14));content.Children.Add(new TextBlock{Text=detail,FontSize=11,Foreground=Brush("MutedBrush"),TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,5,0,0)});
            var button=MakeButton("",(_,_)=>SelectDesktopStyle(style));button.Content=content;button.HorizontalContentAlignment=HorizontalAlignment.Stretch;
            button.Padding=new Thickness(12);button.Margin=new Thickness(0);button.ToolTip=T("选用并预览","Enable and preview");
            AutomationProperties.SetAutomationId(button,"desktop-style-"+style);AutomationProperties.SetName(button,title);desktopStyleButtons[style]=button;
            Grid.SetColumn(button,index);choices.Children.Add(button);
        }
        styles.Children.Add(choices);page.Children.Add(Card(styles));

        var adjustments=Panel();adjustments.Children.Add(SectionTitle(T("效果设置","Effect settings")));
        adjustments.Children.Add(KeyBurstSlider(T("动画幅度","Motion intensity"),"key-burst-intensity",.25,1,
            ControlScale.RhythmIntensity.DisplayValue(settings.KeyBurstIntensity),value=>settings.KeyBurstIntensity=ControlScale.RhythmIntensity.StoredValue(value)));
        adjustments.Children.Add(KeyBurstSlider(T("特效透明度","Effect opacity"),"key-burst-opacity",.25,1,
            settings.KeyBurstBrightness,value=>settings.KeyBurstBrightness=value));
        var flashes=new CheckBox{Content=T("闪光效果","Flashes"),IsChecked=settings.KeyBurstFlashes,Margin=new Thickness(0,16,0,0)};
        AutomationProperties.SetAutomationId(flashes,"key-burst-flashes");
        flashes.Click+=(_,_)=>{settings.KeyBurstFlashes=flashes.IsChecked==true;UpdateKeyBurst();SaveSoon();};adjustments.Children.Add(flashes);page.Children.Add(Card(adjustments));

        var audioPanel=Panel();
        audioPanel.Children.Add(SectionTitle(T("跟随电脑声音","Follow computer audio"),T("分析默认播放设备的混合声音，包含键舞自己的音效。低音推动左侧柔光，中高音带动右侧波形。只在本机即时分析，不使用麦克风，不保存录音。",
            "Analyzes the default output-device mix, including KeyWoo sounds. Bass shapes the left glow; mids and treble shape the right wave. Analysis stays in memory, with no microphone or saved recording.")));
        var follow=new CheckBox{Content=T("让泛光跟随电脑声音","Let the glow follow computer audio"),IsChecked=settings.FollowSystemAudio};
        AutomationProperties.SetAutomationId(follow,"rhythm-follow-audio");
        follow.Click+=(_,_)=>{settings.FollowSystemAudio=follow.IsChecked==true;UpdateKeyBurst();SaveSoon();};audioPanel.Children.Add(follow);
        var audioStateRow=new DockPanel();systemAudioRetry=MakeButton(T("重试","Retry"),(_,_)=>systemAudio.Retry());
        AutomationProperties.SetAutomationId(systemAudioRetry,"rhythm-audio-retry");DockPanel.SetDock(systemAudioRetry,Dock.Right);audioStateRow.Children.Add(systemAudioRetry);
        systemAudioStatus=Text("",12,true);audioStateRow.Children.Add(systemAudioStatus);audioPanel.Children.Add(audioStateRow);
        desktopAudioCard=Card(audioPanel);page.Children.Add(desktopAudioCard);
        UpdateDesktopControls();UpdateSystemAudioState();return page;
    }
    private Border? desktopAudioCard;

    private void SelectDesktopStyle(string style) {
        settings.DesktopStyle=style;
        settings.KeyBurstEnabled=true;
        UpdateKeyBurst();SaveSoon();
        if(enabled&&!sessionLocked&&!powerSuspended&&!closing)keyBurst.Preview();
    }
    private void PreviewDesktopEffect() {
        if(!enabled||sessionLocked||powerSuspended||closing)return;
        settings.KeyBurstEnabled=true;UpdateKeyBurst();SaveSoon();keyBurst.Preview();
    }
    private void UpdateDesktopControls() {
        bool suspended=!enabled||sessionLocked||powerSuspended||closing;
        if(desktopEnabled is not null)desktopEnabled.IsChecked=settings.KeyBurstEnabled;
        if(keyBurstPreview is not null) {
            keyBurstPreview.Content=settings.KeyBurstEnabled?T("预览","Preview"):T("开启并预览","Enable & preview");
            keyBurstPreview.IsEnabled=!suspended;
            keyBurstPreview.ToolTip=suspended?T("继续运行后可预览。","Resume KeyWoo to preview."):T("只演示画面，不发声、不计数。","Visual preview only. No sound or key counts.");
        }
        if(desktopStatus is not null)desktopStatus.Text=!settings.KeyBurstEnabled?T("已关闭 · 选择样式即可开启","Off · Choose a style to enable")
            :suspended?T("已启用 · 当前暂停","Enabled · Currently paused")
            :T("已开启 · 打字时出现，停手后渐隐","Enabled · Appears as you type, then fades");
        foreach(var (style,button) in desktopStyleButtons) {
            bool selected=style==settings.DesktopStyle;
            button.Background=Brush(selected?"SelectedBrush":"CardBrush");button.BorderBrush=Brush(selected?"AccentBrush":"LineBrush");
            button.BorderThickness=new Thickness(selected?1.5:1);
            button.ToolTip=suspended?T("选择样式，继续运行后生效。","Choose a style. Resume KeyWoo to use it."):T("选用并预览","Enable and preview");
            AutomationProperties.SetItemStatus(button,selected?T("已选择","Selected"):T("未选择","Not selected"));
        }
        if(desktopAudioCard is not null)desktopAudioCard.Visibility=settings.DesktopStyle=="edgeGlow"?Visibility.Visible:Visibility.Collapsed;
        UpdateSystemAudioState();
    }
    private DockPanel KeyBurstSlider(string title,string id,double minimum,double maximum,double value,Action<double> save) {
        var row=new DockPanel{Margin=new Thickness(0,8,0,0)};
        var label=Text(title,12);label.Width=112;DockPanel.SetDock(label,Dock.Left);row.Children.Add(label);
        var percent=Text(value.ToString("0.##%",CultureInfo.CurrentCulture),12,true);percent.Width=64;DockPanel.SetDock(percent,Dock.Right);row.Children.Add(percent);
        var slider=new Slider{Minimum=minimum,Maximum=maximum,Value=value,SmallChange=.01,LargeChange=.05,TickPlacement=System.Windows.Controls.Primitives.TickPlacement.None,Margin=new Thickness(0,0,8,0)};
        AutomationProperties.SetAutomationId(slider,id);AutomationProperties.SetName(slider,title);
        slider.ValueChanged+=(_,_)=>{save(slider.Value);percent.Text=slider.Value.ToString("0.##%",CultureInfo.CurrentCulture);UpdateKeyBurst();SaveSoon();};
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
                _=>!settings.KeyBurstEnabled?T("开启桌面特效后连接。","Enable desktop effects to connect.")
                    :!enabled?T("继续运行后连接。","Resume KeyWoo to connect."):T("等待电脑声音…","Waiting for computer audio…")
            };
        }
        if(systemAudioRetry is not null)systemAudioRetry.Visibility=systemAudio.State==SystemAudioState.Failed?Visibility.Visible:Visibility.Collapsed;
    }
}

/// Static samples use the same drawing code as the desktop overlay.
internal sealed class DesktopEffectThumbnail(string style):FrameworkElement {
    protected override void OnRender(DrawingContext context) {
        base.OnRender(context);
        context.DrawRoundedRectangle(new SolidColorBrush(Color.FromRgb(26,25,32)),null,new Rect(RenderSize),8,8);
        context.PushClip(new RectangleGeometry(new Rect(RenderSize),8,8));
        var design=style=="edgeGlow"?new Size(340,144):new Size(340,224);
        double scale=Math.Min(ActualWidth/design.Width,ActualHeight/design.Height);
        context.PushTransform(new TranslateTransform((ActualWidth-design.Width*scale)/2,(ActualHeight-design.Height*scale)/2));
        context.PushTransform(new ScaleTransform(scale,scale));
        if(style=="edgeGlow") {
            var model=new EdgeGlowDynamics();
            foreach(int key in new[]{0x41,0x53,0x44,0x46,0x20})model.Press(new PhysicalKey(key,0),.72+(key%4)*.02);
            EdgeGlowDrawing.Draw(context,design,model,new AudioSpectrum(.4,.3,.2,.35),.89,new(1,1,true,false));
        } else {
            var model=new KeyBurstDynamics();model.Press(new PhysicalKey(0x41,0x1e),.6);model.Press(new PhysicalKey(0x53,0x1f),.72);model.Press(new PhysicalKey(0x44,0x20),.84);
            KeyBurstDrawing.Draw(context,design,model,.92,new(1,1,true,false));
        }
        context.Pop();context.Pop();context.Pop();
    }
}
