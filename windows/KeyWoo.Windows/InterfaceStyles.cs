using System.Windows;
using System.Windows.Markup;

namespace KeyWoo.Windows;

/// <summary>Window-scoped interaction styles shared by the four workspace pages.</summary>
internal static class InterfaceStyles {
    internal static void Apply(Window window) {
        const string markup="""
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Style TargetType="Button">
    <Setter Property="Padding" Value="14,8"/><Setter Property="Margin" Value="0,0,8,0"/>
    <Setter Property="Background" Value="{DynamicResource CardBrush}"/><Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/><Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Cursor" Value="Hand"/><Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
        <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="BorderBrush" Value="{DynamicResource AccentBrush}"/></Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="BorderBrush" Value="{DynamicResource AccentBrush}"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter Property="Opacity" Value="0.75"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.42"/><Setter Property="Cursor" Value="Arrow"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="ComboBoxItem">
    <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="Background" Value="{DynamicResource CardBrush}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem">
      <Border Background="{TemplateBinding Background}" Padding="10,8"><ContentPresenter Content="{TemplateBinding Content}" ContentTemplate="{TemplateBinding ContentTemplate}" ContentTemplateSelector="{TemplateBinding ContentTemplateSelector}" TextElement.Foreground="{TemplateBinding Foreground}"/></Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="{DynamicResource SelectedBrush}"/><Setter Property="Foreground" Value="{DynamicResource AccentBrush}"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{DynamicResource SelectedBrush}"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="DataGridColumnHeader">
    <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="Background" Value="{DynamicResource RaisedBrush}"/>
    <Setter Property="Padding" Value="12,9"/><Setter Property="HorizontalContentAlignment" Value="Left"/><Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="DataGridColumnHeader">
      <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
        <ContentPresenter Content="{TemplateBinding Content}" ContentTemplate="{TemplateBinding ContentTemplate}" ContentTemplateSelector="{TemplateBinding ContentTemplateSelector}" TextElement.Foreground="{TemplateBinding Foreground}"/>
      </Border>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="DataGridCell">
    <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="Background" Value="Transparent"/>
    <Setter Property="Padding" Value="12,8"/><Setter Property="BorderThickness" Value="0"/><Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="DataGridCell">
      <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
        <ContentPresenter Content="{TemplateBinding Content}" ContentTemplate="{TemplateBinding ContentTemplate}" ContentTemplateSelector="{TemplateBinding ContentTemplateSelector}" TextElement.Foreground="{TemplateBinding Foreground}" VerticalAlignment="Center"/>
      </Border>
      <ControlTemplate.Triggers><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{DynamicResource SelectedBrush}"/></Trigger></ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="Expander">
    <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Expander">
      <StackPanel>
        <ToggleButton Foreground="{Binding Foreground,RelativeSource={RelativeSource TemplatedParent}}" IsChecked="{Binding IsExpanded,RelativeSource={RelativeSource TemplatedParent},Mode=TwoWay}" HorizontalContentAlignment="Stretch" Cursor="Hand" FocusVisualStyle="{x:Null}">
          <ToggleButton.Template><ControlTemplate TargetType="ToggleButton">
            <Border x:Name="surface" Background="Transparent" CornerRadius="6" Padding="4,9">
              <DockPanel>
                <TextBlock x:Name="arrow" Text="›" FontSize="18" Width="22" VerticalAlignment="Center" Foreground="{DynamicResource MutedBrush}"/>
                <ContentPresenter Content="{Binding Header,RelativeSource={RelativeSource AncestorType=Expander}}" TextElement.Foreground="{TemplateBinding Foreground}" VerticalAlignment="Center"/>
              </DockPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True"><Setter TargetName="arrow" Property="Text" Value="⌄"/></Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="surface" Property="Background" Value="{DynamicResource RaisedBrush}"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="surface" Property="Background" Value="{DynamicResource SelectedBrush}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate></ToggleButton.Template>
        </ToggleButton>
        <ContentPresenter x:Name="body" ContentSource="Content" Visibility="Collapsed" Margin="0,8,0,0"/>
      </StackPanel>
      <ControlTemplate.Triggers><Trigger Property="IsExpanded" Value="True"><Setter TargetName="body" Property="Visibility" Value="Visible"/></Trigger></ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
</ResourceDictionary>
""";
        var styles=(ResourceDictionary)XamlReader.Parse(markup);
        foreach(object key in styles.Keys)window.Resources[key]=styles[key];
        window.Resources[SystemColors.HighlightBrushKey]=System.Windows.Application.Current.Resources["SelectedBrush"];
        window.Resources[SystemColors.HighlightTextBrushKey]=System.Windows.Application.Current.Resources["TextBrush"];
    }
}
