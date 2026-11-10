using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using KeyWoo.Core;

namespace KeyWoo.Windows;

/// <summary>Paint and exercise the actual workspace without input capture, audio devices or real preferences.</summary>
internal static class InterfaceVerification {
    internal sealed record Result(bool Passed,bool NavigationPassed,bool RuleEditingPassed,bool DraftPreservationPassed,
        bool ThemeAndLanguagePassed,bool PreviewAvailabilityPassed,bool FullRowDisclosurePassed,int NativeScreenshots);
    internal static Result Run(string report,SampleBank bank) {
        string directory=Path.Combine(Path.GetTempPath(),"KeyWoo-interface-"+Guid.NewGuid().ToString("N"));
        string screenshotDirectory=Path.Combine(Path.GetDirectoryName(Path.GetFullPath(report))!,"tests","interface");
        Directory.CreateDirectory(screenshotDirectory);
        string screenshotBase=Path.Combine(screenshotDirectory,Path.GetFileName(report));
        var store=new StatisticsStore(Path.Combine(directory,"statistics.json"));
        for(int index=0;index<180;index++)store.Record(new PhysicalKey(0x41,0x1e),DateTimeOffset.Now.AddMinutes(-30+index%24));
        var settings=new Settings{Language="zh",Appearance="light",Preset="red",Volume=1,Rules=[new(0x14,KeyModifiers.None,0x1b)]};
        var resources=System.Windows.Application.Current.Resources;
        string[] names=["PageBrush","SidebarBrush","CardBrush","RaisedBrush","SelectedBrush","TextBrush","MutedBrush","LineBrush","AccentBrush"];
        object?[] previous=names.Select(name=>resources.Contains(name)?resources[name]:null).ToArray();
        MainWindow? window=null;int screenshots=0;
        try {
            window=new MainWindow(settings,store,bank);var root=(FrameworkElement)window.Content;Layout(root);
            Require(!Find<Button>(root,"sound-preview").IsEnabled,"Preview must be visibly unavailable before an audio device is connected.");
            foreach(int index in new[]{0,2,1,3}) {
                Click(root,"navigation-"+index);Layout(root);
                Require(Find<TextBlock>(root,"workspace-page-title").Text==(index switch{1=>"按键统计",2=>"改键",3=>"偏好设置",_=>"键盘音效"}),"Navigation must update the workspace heading.");
                Save(root,Path.ChangeExtension(screenshotBase,$".interface-light-{index}.png"));screenshots++;
            }
            Click(root,"navigation-0");Layout(root);
            var practice=Find<TextBox>(root,"practice-input");practice.Text="KeyWoo practice stays local.";
            var sources=FindAll<Expander>(root).First(expander=>expander.Header?.ToString()=="声音来源");
            sources.ApplyTemplate();
            var disclosure=FindVisual<ToggleButton>(sources);
            Require(disclosure is not null&&disclosure.ActualWidth>=sources.ActualWidth-2,"Disclosure headers must use the full available row width.");
            disclosure!.IsChecked=true;Require(sources.IsExpanded,"The disclosure toggle must expand its content.");
            Click(root,"navigation-2");Layout(root);
            Require(!Find<Button>(root,"remapping-delete").IsEnabled&&!Find<Button>(root,"remapping-edit").IsEnabled,"Rule actions must be unavailable until a rule is selected.");
            Find<ComboBox>(root,"remapping-source").SelectedValue=0x41;
            Find<ComboBox>(root,"remapping-target").SelectedValue=0x42;
            Find<CheckBox>(root,"source-ctrl").IsChecked=true;
            Click(root,"remapping-save");
            Require(settings.Rules.Any(rule=>rule.Source==0x41&&rule.Target==0x42&&rule.Modifiers==KeyModifiers.Control),"Saving a mapping must use the selected key and modifiers.");
            var rules=Find<DataGrid>(root,"remapping-rules");rules.SelectedIndex=settings.Rules.Count-1;
            Click(root,"remapping-edit");Find<ComboBox>(root,"remapping-target").SelectedValue=0x43;
            Click(root,"remapping-cancel");
            Require(settings.Rules.Any(rule=>rule.Source==0x41&&rule.Target==0x42),"Cancel must leave the saved mapping unchanged.");
            Find<ComboBox>(root,"remapping-source").SelectedValue=0x44;
            Find<CheckBox>(root,"source-shift").IsChecked=true;
            Click(root,"navigation-1");Layout(root);Find<TextBox>(root,"statistics-key-search").Text="Space";
            Click(root,"navigation-3");Layout(root);
            Find<ComboBox>(root,"app-language").SelectedValue="en";Pump();root=(FrameworkElement)window.Content;Layout(root);
            Find<ComboBox>(root,"app-appearance").SelectedValue="dark";Pump();root=(FrameworkElement)window.Content;Layout(root);
            Require(Find<TextBox>(root,"practice-input").Text=="KeyWoo practice stays local.","Changing language and appearance must retain the practice draft.");
            Require((int?)Find<ComboBox>(root,"remapping-source").SelectedValue==0x44&&Find<CheckBox>(root,"source-shift").IsChecked==true,"Changing language and appearance must retain the unsaved mapping draft.");
            Require(Find<TextBox>(root,"statistics-key-search").Text=="Space","Changing language and appearance must retain statistics filters.");
            foreach(int index in new[]{0,2,1,3}) {
                Click(root,"navigation-"+index);Layout(root);
                Require(Find<TextBlock>(root,"workspace-page-title").Text==(index switch{1=>"Key statistics",2=>"Remapping",3=>"Preferences",_=>"Keyboard sounds"}),"English navigation must retain its selected page and translated heading.");
                Save(root,Path.ChangeExtension(screenshotBase,$".interface-dark-{index}.png"));screenshots++;
            }
            Layout(root,820,650);Save(root,Path.ChangeExtension(screenshotBase,".interface-dark-narrow.png"),820,650);screenshots++;
            return new(true,true,true,true,true,true,true,screenshots);
        } finally {
            window?.DisposeVerification();
            for(int index=0;index<names.Length;index++)if(previous[index] is object value)resources[names[index]]=value;else resources.Remove(names[index]);
            if(Directory.Exists(directory))Directory.Delete(directory,true);
        }
    }
    private static void Click(DependencyObject root,string id)=>Find<Button>(root,id).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static void Pump(){var frame=new DispatcherFrame();Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background,new Action(()=>frame.Continue=false));Dispatcher.PushFrame(frame);}
    private static void Layout(FrameworkElement root,int width=1050,int height=740){root.Measure(new Size(width,height));root.Arrange(new Rect(0,0,width,height));root.UpdateLayout();}
    private static void Save(FrameworkElement view,string file,int width=1050,int height=740){var bitmap=new RenderTargetBitmap(width,height,96,96,PixelFormats.Pbgra32);bitmap.Render(view);var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(bitmap));using var stream=File.Create(file);png.Save(stream);}
    private static T Find<T>(DependencyObject root,string id) where T:DependencyObject => FindAll<T>(root).FirstOrDefault(value=>AutomationProperties.GetAutomationId(value)==id)??throw new InvalidDataException("Missing interface control "+id);
    private static IEnumerable<T> FindAll<T>(DependencyObject root) where T:DependencyObject {
        if(root is T match)yield return match;
        foreach(object child in LogicalTreeHelper.GetChildren(root))if(child is DependencyObject element)foreach(var found in FindAll<T>(element))yield return found;
    }
    private static T? FindVisual<T>(DependencyObject root) where T:DependencyObject {
        if(root is T match)return match;
        for(int index=0;index<VisualTreeHelper.GetChildrenCount(root);index++){var found=FindVisual<T>(VisualTreeHelper.GetChild(root,index));if(found is not null)return found;}return null;
    }
    private static void Require(bool condition,string message){if(!condition)throw new InvalidDataException(message);}
}
