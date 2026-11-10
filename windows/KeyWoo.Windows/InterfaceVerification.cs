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
        bool ThemeAndLanguagePassed,bool PreviewAvailabilityPassed,bool FullRowDisclosurePassed,
        bool VisibleLabelsPassed,bool DarkTextContrastPassed,bool RuleColumnLayoutPassed,bool NarrowLayoutPassed,int NativeScreenshots);
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
            window=new MainWindow(settings,store,bank);window.Show();Pump();var root=(FrameworkElement)window.Content;Layout(root);
            Require(!Find<Button>(root,"sound-preview").IsEnabled,"Preview must be visibly unavailable before an audio device is connected.");
            foreach(int index in new[]{0,2,1,3}) {
                Click(root,"navigation-"+index);Layout(root);
                Require(Find<TextBlock>(root,"workspace-page-title").Text==(index switch{1=>"按键统计",2=>"改键",3=>"偏好设置",_=>"键盘音效"}),"Navigation must update the workspace heading.");
                VerifyPageLabels(root,index);
                Save(root,Path.ChangeExtension(screenshotBase,$".interface-light-{index}.png"));screenshots++;
            }
            Click(root,"navigation-0");Layout(root);
            VerifyPopup(Find<ComboBox>(root,"recording-version"),Path.ChangeExtension(screenshotBase,".interface-light-recording-menu.png"));screenshots++;
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
                VerifyPageLabels(root,index);
                if(index==2)VerifyDarkMapping(root);
                Save(root,Path.ChangeExtension(screenshotBase,$".interface-dark-{index}.png"));screenshots++;
            }
            Click(root,"navigation-2");Layout(root);VerifyPopup(Find<ComboBox>(root,"remapping-source"),Path.ChangeExtension(screenshotBase,".interface-dark-key-menu.png"));screenshots++;
            Click(root,"navigation-3");Layout(root);
            window.Width=820;window.Height=650;window.UpdateLayout();Pump();root.UpdateLayout();
            Require(root.ActualWidth>=780&&root.ActualWidth<=820&&root.ActualHeight<650,"The narrow preview must use the real resized window client area, not a clipped bitmap.");
            foreach(string id in new[]{"app-language","app-appearance","key-burst-preview","key-burst-intensity","key-burst-opacity"})RequireReachable(root,Find<FrameworkElement>(root,id));
            var language=Find<ComboBox>(root,"app-language");ScrollAncestor(language)?.ScrollToTop();Pump();root.UpdateLayout();
            SaveActual(root,Path.ChangeExtension(screenshotBase,".interface-dark-narrow.png"));screenshots++;
            Find<Slider>(root,"key-burst-opacity").BringIntoView();Pump();root.UpdateLayout();
            SaveActual(root,Path.ChangeExtension(screenshotBase,".interface-dark-narrow-animation.png"));screenshots++;
            return new(true,true,true,true,true,true,true,true,true,true,true,screenshots);
        } finally {
            window?.DisposeVerification();
            for(int index=0;index<names.Length;index++)if(previous[index] is object value)resources[names[index]]=value;else resources.Remove(names[index]);
            if(Directory.Exists(directory))Directory.Delete(directory,true);
        }
    }
    private static void RequireReachable(FrameworkElement root,FrameworkElement control) {
        control.BringIntoView();Pump();root.UpdateLayout();
        var bounds=control.TransformToAncestor(root).TransformBounds(new Rect(0,0,control.ActualWidth,control.ActualHeight));
        Require(control.ActualWidth>0&&control.ActualHeight>0&&bounds.Left>=-1&&bounds.Top>=-1&&bounds.Right<=root.ActualWidth+1&&bounds.Bottom<=root.ActualHeight+1,
            $"The narrow-window {AutomationProperties.GetAutomationId(control)} control must fit in the visible client area after scrolling. Bounds={bounds}; root={root.ActualWidth}×{root.ActualHeight}");
    }
    private static ScrollViewer? ScrollAncestor(DependencyObject control) {
        for(DependencyObject? parent=VisualTreeHelper.GetParent(control);parent is not null;parent=VisualTreeHelper.GetParent(parent))if(parent is ScrollViewer scroll)return scroll;return null;
    }
    private static void SaveActual(FrameworkElement root,string file)=>Save(root,file,(int)Math.Ceiling(root.ActualWidth),(int)Math.Ceiling(root.ActualHeight));
    private static void VerifyPageLabels(DependencyObject root,int page) {
        string[] ids=page switch{0=>["recording-version","sound-category"],2=>["remapping-source","remapping-target"],3=>["app-language","app-appearance","desktop-animation-style"],_=>[]};
        foreach(string id in ids) {
            var combo=Find<ComboBox>(root,id);combo.ApplyTemplate();combo.UpdateLayout();
            string expected=combo.SelectedItem?.GetType().GetProperty(combo.DisplayMemberPath)?.GetValue(combo.SelectedItem)?.ToString()??throw new InvalidDataException("Missing display label for "+id);
            string[] visible=Visuals<TextBlock>(combo).Where(text=>text.ActualWidth>0&&text.ActualHeight>0).Select(text=>text.Text).ToArray();
            Require(visible.Contains(expected),$"The visible {id} selection must show '{expected}', not an object's ToString(). Actual: {string.Join(" | ",visible)}");
            Require(!visible.Any(IsObjectDescription),"ComboBox selections must never expose record or key-value debug text.");
        }
    }
    private static void VerifyPopup(ComboBox combo,string file) {
        combo.IsDropDownOpen=true;Pump();combo.UpdateLayout();
        try {
            var popup=(Popup?)combo.Template.FindName("PART_Popup",combo);
            Require(popup?.Child is FrameworkElement,"The actual combo popup must be created.");
            var surface=(FrameworkElement)popup!.Child;surface.UpdateLayout();
            var visible=Visuals<TextBlock>(surface).Where(text=>text.ActualWidth>0&&text.ActualHeight>0&&text.IsVisible).ToArray();
            Require(visible.Length>=2&&!visible.Any(text=>IsObjectDescription(text.Text)),"The open menu must show readable friendly labels, not object descriptions.");
            var expected=combo.SelectedItem?.GetType().GetProperty(combo.DisplayMemberPath)?.GetValue(combo.SelectedItem)?.ToString();
            Require(visible.Any(text=>text.Text==expected),"The selected option must remain readable in the actual open menu.");
            Save(surface,file,Math.Max(1,(int)Math.Ceiling(surface.ActualWidth)),Math.Max(1,(int)Math.Ceiling(surface.ActualHeight)));
        } finally {combo.IsDropDownOpen=false;Pump();}
    }
    private static bool IsObjectDescription(string value)=>value.Contains("KeyOption {")||value.Contains("SoundGroup {")||value.StartsWith("[False,")||value.StartsWith("[True,")||value.StartsWith("[en,")||value.StartsWith("[dark,");
    private static void VerifyDarkMapping(DependencyObject root) {
        var grid=Find<DataGrid>(root,"remapping-rules");grid.UpdateLayout();
        Require(grid.Columns.All(column=>column.ActualWidth>=140),"Mapping columns must have enough width for readable shortcuts.");
        var headers=Visuals<DataGridColumnHeader>(grid).Where(header=>header.Content is string).ToArray();
        Require(headers.Length==2&&headers.All(header=>Light(header.Foreground)),"Both mapping column headers must use readable dark-mode text.");
        foreach(var header in headers)Require(Visuals<TextBlock>(header).Any(text=>Light(text.Foreground)&&text.ActualWidth>20),"Column header text must be visible and have usable width.");
        var cells=Visuals<DataGridCell>(grid).ToArray();
        Require(cells.Length>=2&&cells.All(cell=>Light(cell.Foreground)&&cell.ActualWidth>=140),"Mapping cells must retain text contrast and column width.");
        Require(cells.SelectMany(Visuals<TextBlock>).All(text=>Light(text.Foreground)),"Mapping row labels must inherit the readable foreground.");
        var media=FindAll<Expander>(root).First(expander=>expander.Header?.ToString()=="Media shortcut template");
        Require(Visuals<TextBlock>(media).Any(text=>text.Text=="Media shortcut template"&&Light(text.Foreground)),"The media template disclosure must remain readable in dark mode.");
    }
    private static bool Light(Brush foreground)=>foreground is SolidColorBrush brush&&(.2126*brush.Color.R+.7152*brush.Color.G+.0722*brush.Color.B)>140;
    private static IEnumerable<T> Visuals<T>(DependencyObject root) where T:DependencyObject {
        if(root is T match)yield return match;
        for(int index=0;index<VisualTreeHelper.GetChildrenCount(root);index++)foreach(var found in Visuals<T>(VisualTreeHelper.GetChild(root,index)))yield return found;
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
