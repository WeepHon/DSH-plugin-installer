<#
  DSH 插件安装器 · 图形界面
  ------------------------------------------------------------------
  不需要启动 DSH。双击「开始安装.bat」即可运行。
  真正的安装逻辑在 core\dsh-plugin-core.ps1，本文件只负责界面与流程编排。
#>

param(
    [switch]$SelfTest
)

# 用 .bat 隐藏窗口启动时，任何未捕获的错误都必须弹框，否则用户什么都看不到
trap {
    $msg = ($_ | Out-String)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show($msg, 'DSH 插件安装器 - 出错了', 'OK', 'Error') | Out-Null
    } catch { }
    exit 1
}

$ErrorActionPreference = 'Stop'
$script:CorePath = Join-Path $PSScriptRoot 'core\dsh-plugin-core.ps1'
$script:UnlockCorePath = Join-Path $PSScriptRoot 'core\dsh-unlock-core.ps1'
if (-not (Test-Path -LiteralPath $script:CorePath)) {
    [System.Windows.Forms.MessageBox]::Show("找不到核心文件：`n$script:CorePath", 'DSH 插件安装器') | Out-Null
    exit 1
}
. $script:CorePath
if (-not (Test-Path -LiteralPath $script:UnlockCorePath)) {
    [System.Windows.Forms.MessageBox]::Show("找不到核心文件：`n$script:UnlockCorePath", 'DSH 插件安装器') | Out-Null
    exit 1
}
. $script:UnlockCorePath
$script:FallbackCorePath = Join-Path $PSScriptRoot 'core\dsh-fallback-core.ps1'
if (Test-Path -LiteralPath $script:FallbackCorePath) { . $script:FallbackCorePath }

$script:LogDir = Join-Path $PSScriptRoot 'logs'
$script:JobTimer = $null
$script:Shell = $null
$script:LastLogText = ''
$script:CurrentPluginInfo = $null
$script:ProfilesCache = @()
$script:Platform = $null

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, Microsoft.VisualBasic

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DSH 插件安装器" Height="1090" Width="920"
        WindowStartupLocation="CenterScreen"
        Background="#F3F5FA"
        FontFamily="Microsoft YaHei UI"
        ResizeMode="CanMinimize">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#4F46E5"/>
    <SolidColorBrush x:Key="Muted" Color="#6B7280"/>
    <SolidColorBrush x:Key="Line" Color="#E5E8F0"/>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="18,14,18,16"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#111827"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="ValueText" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#111827"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="FlatButton" TargetType="Button">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#374151"/>
      <Setter Property="BorderBrush" Value="#D7DBE7"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#F2F4F9"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource FlatButton}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="26,9"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="7" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#4338CA"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Foreground" Value="#1F2937"/>
      <Setter Property="Margin" Value="0,0,22,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="BorderBrush" Value="#D7DBE7"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Padding" Value="6,4"/>
    </Style>
  </Window.Resources>

  <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="0,0,4,0">
  <Grid Margin="20,16,20,14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="150"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- 标题 -->
    <Border Grid.Row="0" Margin="0,0,0,14">
      <Grid>
        <StackPanel>
          <TextBlock Text="DSH 插件安装器" FontSize="20" FontWeight="Bold" Foreground="#111827"/>
          <TextBlock Text="不用打开 DeepSeek Harness，直接把插件装到正确位置" FontSize="12.5"
                     Foreground="{StaticResource Muted}" Margin="0,4,0,0"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- 环境 -->
    <Border Grid.Row="1" Style="{StaticResource Card}">
      <StackPanel>
        <Grid>
          <TextBlock Text="① 运行环境" Style="{StaticResource CardTitle}"/>
          <Button x:Name="BtnRefresh" Content="重新检测" Style="{StaticResource FlatButton}"
                  HorizontalAlignment="Right" VerticalAlignment="Top" Padding="10,4"/>
        </Grid>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="88"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="78"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Grid.RowDefinitions>
            <RowDefinition Height="26"/>
            <RowDefinition Height="26"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Grid.Column="0" Text="DSH 主目录" Style="{StaticResource FieldLabel}"/>
          <TextBlock Grid.Row="0" Grid.Column="1" x:Name="TxtDshHome" Style="{StaticResource ValueText}"/>
          <TextBlock Grid.Row="0" Grid.Column="2" Text="安装通道" Style="{StaticResource FieldLabel}"/>
          <TextBlock Grid.Row="0" Grid.Column="3" x:Name="TxtCli" Style="{StaticResource ValueText}" MaxWidth="330"/>
          <TextBlock Grid.Row="1" Grid.Column="0" Text="桌面版位置" Style="{StaticResource FieldLabel}"/>
          <TextBlock Grid.Row="1" Grid.Column="1" x:Name="TxtAppDir" Style="{StaticResource ValueText}"/>
          <TextBlock Grid.Row="1" Grid.Column="2" Text="配置目录" Style="{StaticResource FieldLabel}"/>
          <TextBlock Grid.Row="1" Grid.Column="3" x:Name="TxtProfiles" Style="{StaticResource ValueText}"/>
        </Grid>
      </StackPanel>
    </Border>

    <!-- 插件 -->
    <Border Grid.Row="2" Style="{StaticResource Card}">
      <StackPanel>
        <TextBlock Text="② 选择插件" Style="{StaticResource CardTitle}"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="8"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="6"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <ComboBox Grid.Column="0" x:Name="CmbPlugin" Height="32" VerticalContentAlignment="Center"
                    ToolTip="这里列出自动找到的插件（plugins 文件夹、桌面、下载）"/>
          <Button Grid.Column="2" x:Name="BtnBrowse" Content="选择文件夹…" Style="{StaticResource FlatButton}"/>
          <Button Grid.Column="4" x:Name="BtnBrowseZip" Content="选择压缩包…" Style="{StaticResource FlatButton}"/>
        </Grid>
        <Border Background="#F7F8FC" CornerRadius="7" Padding="12,9,12,10" Margin="0,10,0,0">
          <StackPanel>
            <TextBlock x:Name="TxtPluginName" FontSize="13" FontWeight="SemiBold" Foreground="#111827" Text="尚未选择插件"/>
            <TextBlock x:Name="TxtPluginDesc" FontSize="11.5" Foreground="#4B5563" Margin="0,3,0,0"
                       TextWrapping="Wrap" MaxHeight="32" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="TxtPluginMeta" FontSize="11.5" Foreground="{StaticResource Muted}" Margin="0,4,0,0"
                       TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="TxtPluginPath" FontSize="10.5" Foreground="#9CA3AF" Margin="0,2,0,0"
                       TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </Border>
      </StackPanel>
    </Border>

    <!-- 选项 -->
    <Border Grid.Row="3" Style="{StaticResource Card}">
      <StackPanel>
        <TextBlock Text="③ 安装到哪里" Style="{StaticResource CardTitle}"/>
        <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
          <CheckBox x:Name="ChkDesktop" Content="桌面版 DeepSeek Harness"/>
          <CheckBox x:Name="ChkWeb" Content="Web 版（浏览器打开的那种）"/>
        </StackPanel>
        <TextBlock Text="高级选项（一般不用管）" FontSize="11.5" Foreground="{StaticResource Muted}" Margin="0,0,0,8"/>
        <StackPanel Orientation="Horizontal">
          <CheckBox x:Name="ChkEnable" Content="同时打开插件功能开关" IsChecked="True"
                    ToolTip="写入 profile 的 cordis.patch.yml，等于在插件详情卡里把开关拨到开启"/>
          <CheckBox x:Name="ChkManual" Content="备用安装模式"
                    ToolTip="不调用官方命令行，直接改配置文件和 node_modules，用于命令行不可用时"/>
          <CheckBox x:Name="ChkForce" Content="允许版本不兼容"
                    ToolTip="插件要求的 DSH 版本与当前不符时仍然安装"/>
        </StackPanel>
      </StackPanel>
    </Border>

    <!-- 解除限制 -->
    <Border Grid.Row="4" Style="{StaticResource Card}">
      <StackPanel>
        <Grid>
          <TextBlock Text="④ 解除插件版本限制（可选）" Style="{StaticResource CardTitle}"/>
          <TextBlock x:Name="TxtUnlockState" HorizontalAlignment="Right" VerticalAlignment="Top"
                     FontSize="11.5" Foreground="#9CA3AF" Text="检测中…"/>
        </Grid>
        <TextBlock FontSize="11.5" Foreground="#6B7280" TextWrapping="Wrap" Margin="0,0,0,10"
                   Text="插件装上后却被自动停用，或提示「与当前 DSH 版本不兼容」时，点「解除限制」可以让版本检查永远通过。不备份大文件：还原时把插入的那一行删掉即可，字节级一致。DSH 更新后补丁会被覆盖，勾选下面的「自动修复」就会自动重打。操作前请先完全退出 DeepSeek Harness。"/>
        <StackPanel Orientation="Horizontal">
          <Button x:Name="BtnUnlock" Content="解除限制" Style="{StaticResource FlatButton}" Margin="0,0,10,0"/>
          <Button x:Name="BtnRestoreOfficial" Content="还原官方文件" Style="{StaticResource FlatButton}" Margin="0,0,18,0"/>
          <CheckBox x:Name="ChkAutoHeal" Content="DSH 更新后自动修复（推荐）" VerticalAlignment="Center"
                    ToolTip="官方更新把文件覆盖掉以后，下次打开安装器会自动重新打上补丁"/>
        </StackPanel>
      </StackPanel>
    </Border>

    <!-- 应急开关 -->
    <Border Grid.Row="5" Style="{StaticResource Card}">
      <StackPanel>
        <Grid>
          <TextBlock Text="⑤ 官方加强检测时的应急开关（一般用不到）" Style="{StaticResource CardTitle}"/>
          <TextBlock x:Name="TxtFallbackState" HorizontalAlignment="Right" VerticalAlignment="Top"
                     FontSize="11.5" Foreground="#9CA3AF" Text="检测中…"/>
        </Grid>
        <TextBlock FontSize="11.5" Foreground="#6B7280" TextWrapping="Wrap" Margin="0,0,0,10"
                   Text="只有出现「改完文件 DeepSeek Harness 打不开」时才需要这里。两种办法二选一，随时能撤销，都不动你的插件和配置。同样请先完全退出 DeepSeek Harness。"/>
        <StackPanel Orientation="Horizontal">
          <Button x:Name="BtnDirOn" Content="改用目录加载" Style="{StaticResource FlatButton}" Margin="0,0,10,0"
                  ToolTip="把 app.asar 摊开成 resources\app 目录来加载，绕开 asar 校验；会多占约 360 MB 磁盘"/>
          <Button x:Name="BtnDirOff" Content="还原成 asar 加载" Style="{StaticResource FlatButton}" Margin="0,0,10,0"
                  ToolTip="删掉 resources\app 目录，把 app.asar 改回来"/>
          <Button x:Name="BtnFuseOff" Content="降低检测强度" Style="{StaticResource FlatButton}" Margin="0,0,10,0"
                  ToolTip="改 DeepSeek Harness.exe 里的校验开关；代价是 exe 的官方数字签名失效，Windows 可能提示未知发布者"/>
          <Button x:Name="BtnFuseRestore" Content="恢复官方签名状态" Style="{StaticResource FlatButton}"
                  ToolTip="把改过的开关恢复成官方原值，exe 也回到原样"/>
        </StackPanel>
      </StackPanel>
    </Border>

    <!-- 按钮 -->
    <Grid Grid.Row="6" Margin="0,2,0,12">
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Left">
        <Button x:Name="BtnInstall" Content="开始安装" Style="{StaticResource PrimaryButton}" Margin="0,0,10,0"/>
        <Button x:Name="BtnStatus" Content="检查状态" Style="{StaticResource FlatButton}" Margin="0,0,10,0"/>
        <Button x:Name="BtnUninstall" Content="卸载" Style="{StaticResource FlatButton}" Margin="0,0,10,0"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <ProgressBar x:Name="BarBusy" Width="120" Height="5" IsIndeterminate="True" Visibility="Collapsed"
                     Foreground="{StaticResource Accent}" Background="#E8EAF3" BorderThickness="0" Margin="0,0,12,0"
                     VerticalAlignment="Center"/>
        <Button x:Name="BtnOpenLog" Content="打开日志" Style="{StaticResource FlatButton}" Margin="0,0,10,0"/>
        <Button x:Name="BtnClose" Content="关闭" Style="{StaticResource FlatButton}"/>
      </StackPanel>
    </Grid>

    <!-- 日志 -->
    <Border Grid.Row="7" Background="#0F172A" CornerRadius="10" Padding="0" Margin="0,0,0,10">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="运行日志" Foreground="#94A3B8" FontSize="11.5" Margin="14,10,0,6"/>
        <TextBox Grid.Row="1" x:Name="LogBox" Background="Transparent" BorderThickness="0" Foreground="#D7E0F0"
                 FontFamily="Consolas, Microsoft YaHei UI" FontSize="11.5" IsReadOnly="True"
                 TextWrapping="Wrap" Padding="14,0,14,8" Margin="0,0,4,4"
                 VerticalContentAlignment="Top" VerticalScrollBarVisibility="Auto"
                 HorizontalScrollBarVisibility="Disabled"/>
      </Grid>
    </Border>

    <!-- 状态栏 -->
    <TextBlock Grid.Row="8" x:Name="TxtStatus" FontSize="11.5" Foreground="{StaticResource Muted}"
               Text="准备就绪"/>
  </Grid>
  </ScrollViewer>
</Window>
'@

function Show-Fatal {
    param([string]$Message)
    try {
        [System.Windows.Forms.MessageBox]::Show($Message, 'DSH 插件安装器', 'OK', 'Error') | Out-Null
    } catch {
        Write-Host $Message
    }
}

# ------------------------------------------------------------------ 启动

try {
    $script:Shell = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
try {
    $icoFile = Join-Path $PSScriptRoot 'app.ico'
    if (Test-Path -LiteralPath $icoFile) {
        $script:Shell.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($icoFile)
    }
} catch { }
} catch {
    Show-Fatal ("界面加载失败：`n" + $_.Exception.Message)
    exit 1
}

$ctl = @{}
foreach ($n in @('TxtDshHome','TxtAppDir','TxtCli','TxtProfiles','CmbPlugin','BtnBrowse','BtnBrowseZip',
                 'TxtPluginName','TxtPluginDesc','TxtPluginMeta','TxtPluginPath','ChkDesktop','ChkWeb','ChkEnable','ChkManual',
                 'ChkForce','BtnInstall','BtnStatus','BtnUninstall','BtnOpenLog','BtnClose','BtnRefresh','LogBox',
                 'BarBusy','TxtStatus','TxtUnlockState','BtnUnlock','BtnRestoreOfficial','ChkAutoHeal',
                 'TxtFallbackState','BtnDirOn','BtnDirOff','BtnFuseOff','BtnFuseRestore')) {
    $ctl[$n] = $script:Shell.FindName($n)
}

function Write-UiLog {
    param([string]$Text)
    if (-not $Text) { return }
    $ctl.LogBox.AppendText($Text + "`r`n")
    $ctl.LogBox.ScrollToEnd()
}

function Set-UiBusy {
    param([bool]$Busy, [string]$Status = $null)
    $ctl.BtnInstall.IsEnabled = -not $Busy
    $ctl.BtnUninstall.IsEnabled = -not $Busy
    $ctl.BtnStatus.IsEnabled = -not $Busy
    $ctl.BtnRefresh.IsEnabled = -not $Busy
    $ctl.CmbPlugin.IsEnabled = -not $Busy
    $ctl.BtnBrowse.IsEnabled = -not $Busy
    $ctl.BtnBrowseZip.IsEnabled = -not $Busy
    $ctl.ChkDesktop.IsEnabled = -not $Busy
    $ctl.ChkWeb.IsEnabled = -not $Busy
    $ctl.ChkEnable.IsEnabled = -not $Busy
    $ctl.ChkManual.IsEnabled = -not $Busy
    $ctl.ChkForce.IsEnabled = -not $Busy
    $ctl.BtnUnlock.IsEnabled = -not $Busy
    $ctl.BtnRestoreOfficial.IsEnabled = -not $Busy
    $ctl.BtnDirOn.IsEnabled = -not $Busy
    $ctl.BtnDirOff.IsEnabled = -not $Busy
    $ctl.BtnFuseOff.IsEnabled = -not $Busy
    $ctl.BtnFuseRestore.IsEnabled = -not $Busy
    if ($Busy) { $ctl.BarBusy.Visibility = 'Visible' } else { $ctl.BarBusy.Visibility = 'Collapsed' }
    if ($Status) { $ctl.TxtStatus.Text = $Status }
}

function Update-EnvironmentCard {
    $home_ = Get-DshHomePath
    $ctl.TxtDshHome.Text = $home_
    $app = Find-DshApp
    if ($app) { $ctl.TxtAppDir.Text = $app } else { $ctl.TxtAppDir.Text = '未找到（未安装桌面版？）' }
    $cli = Find-DshCli
    if ($cli) {
        $ver = Get-DshRuntimeVersion -Cli $cli
        $kind = if ($cli.Kind -eq 'desktop') { '桌面版自带命令行' } else { 'npm 全局命令行' }
        $ctl.TxtCli.Text = ('{0}  ·  DSH {1}' -f $kind, $(if ($ver) { $ver } else { '版本未知' }))
    } else {
        $ctl.TxtCli.Text = '未找到命令行（将使用备用安装模式）'
    }

    $script:ProfilesCache = Get-DshProfiles
    if (@($script:ProfilesCache).Count -eq 0) {
        $ctl.TxtProfiles.Text = '还没有任何配置（请先启动一次 DSH）'
        $ctl.ChkDesktop.IsEnabled = $false
        $ctl.ChkWeb.IsEnabled = $false
    } else {
        $names = @()
        foreach ($p in $script:ProfilesCache) {
            $tag = if ($p.Initialized) { '' } else { '（未初始化）' }
            $names += ($p.Name + $tag)
        }
        $ctl.TxtProfiles.Text = ($names -join '   |   ')
        $hasDesktop = @($script:ProfilesCache | Where-Object { $_.Name -eq 'desktop' -and $_.Initialized }).Count -gt 0
        $hasWeb = @($script:ProfilesCache | Where-Object { $_.Name -eq 'web' }).Count -gt 0
        $ctl.ChkDesktop.IsEnabled = $hasDesktop
        $ctl.ChkWeb.IsEnabled = $hasWeb
        if ($hasDesktop) { $ctl.ChkDesktop.IsChecked = $true }
        elseif ($hasWeb -and -not $hasDesktop) { $ctl.ChkWeb.IsChecked = $true }
    }
}

function Get-SelectedPluginPath {
    $p = $ctl.CmbPlugin.SelectedItem
    if ($p -and $p.Path) { return $p.Path }
    if ($p -and $p -is [string]) { return $p }
    return $null
}

function Update-PluginCard {
    param([string]$Path)
    $script:CurrentPluginInfo = $null
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        $ctl.TxtPluginName.Text = '尚未选择插件'
        $ctl.TxtPluginDesc.Text = '把插件文件夹或 .zip 放进本目录的 plugins 文件夹，或点右边的按钮选择'
        $ctl.TxtPluginMeta.Text = ''
        $ctl.TxtPluginPath.Text = ''
        return
    }
    try {
        $src = Resolve-PluginSource -Path $Path
        $info = Read-PluginInfo -Dir $src
        $script:CurrentPluginInfo = $info
        $ctl.TxtPluginName.Text = ('{0}   v{1}' -f $info.Name, $info.Version)
        $desc = if ($info.Description) { $info.Description } else { '（插件未填写说明）' }
        $req = if ($info.EngineRange) { $info.EngineRange } else { '不限' }
        $cli = Find-DshCli
        $runtime = if ($cli) { Get-DshRuntimeVersion -Cli $cli } else { $null }
        $compatText = ''
        if ($info.EngineRange -and $runtime) {
            $check = Test-SemVerRange -Version $runtime -Range $info.EngineRange
            if ($check.Unknown) { $compatText = '   · 版本要求无法解析' }
            elseif ($check.InRange) { $compatText = '   · 与当前版本兼容' }
            else { $compatText = '   · 与当前 DSH 版本不兼容，需要勾选"允许版本不兼容"' }
        }
        $flag = ''
        if ($info.HasBundle) { $flag += '[随 DSH 启动加载] ' }
        if ($info.HasClient) { $flag += '[含界面部分] ' }
        if (-not $info.MainOk) { $flag += '[缺少 main 文件，可能无法运行] ' }
        $ctl.TxtPluginDesc.Text = $desc
        $ctl.TxtPluginMeta.Text = ('要求 DSH {0}{1}{2}{3}' -f $req, $compatText, $(if ($flag.Trim()) { '   ·  ' } else { '' }), $flag.Trim())
        $ctl.TxtPluginPath.Text = $src
    } catch {
        $ctl.TxtPluginName.Text = '这个插件读不出来'
        $ctl.TxtPluginDesc.Text = ''
        $ctl.TxtPluginMeta.Text = $_.Exception.Message
        $ctl.TxtPluginPath.Text = $Path
    }
}

function Update-PluginList {
    $ctl.CmbPlugin.Items.Clear()
    $found = Find-CandidatePlugins
    if (@($found).Count -eq 0) {
        $ctl.CmbPlugin.Items.Add([pscustomobject]@{ Label = '（没有自动找到插件，请点"选择文件夹…"）'; Path = $null }) | Out-Null
        $ctl.CmbPlugin.SelectedIndex = 0
        Update-PluginCard -Path $null
        return
    }
    foreach ($f in $found) { $ctl.CmbPlugin.Items.Add($f) | Out-Null }
    $ctl.CmbPlugin.DisplayMemberPath = 'Label'
    $ctl.CmbPlugin.SelectedIndex = 0
    Update-PluginCard -Path (Get-SelectedPluginPath)
}

# ------------------------------------------------------------------ 解除限制卡片

function Get-UiBrush {
    param([string]$Hex)
    $conv = New-Object System.Windows.Media.BrushConverter
    return $conv.ConvertFromString($Hex)
}

function Update-UnlockCard {
    try {
        $ctl.TxtUnlockState.Foreground = Get-UiBrush '#9CA3AF'
        $st = Get-UnlockStatus
    } catch {
        $ctl.TxtUnlockState.Text = '无法检测：' + $_.Exception.Message
        return
    }
    $script:UnlockStatus = $st
    $ctl.ChkAutoHeal.IsChecked = [bool]$st.AutoHeal
    if (-not $st.Supported) {
        $ctl.TxtUnlockState.Text = '暂不可用：' + $st.Reason
        $ctl.TxtUnlockState.Foreground = Get-UiBrush '#B45309'
        return
    }
    if ($st.Applied) {
        $text = '已解除（随时可还原）'
        if ($st.SignatureRisk) { $text = '已解除 · 含签名校验' }
        $ctl.TxtUnlockState.Text = $text
        $ctl.TxtUnlockState.Foreground = Get-UiBrush '#047857'
    } else {
        $text = '未解除（官方原版）'
        if ($st.SignatureRisk) { $text = '未解除 · 官方已加签名校验' }
        $ctl.TxtUnlockState.Text = $text
    }
}

function Update-FallbackCard {
    $script:FallbackStatus = $null
    $st = $null
    try {
        $st = Get-FallbackStatus
    } catch {
        $ctl.TxtFallbackState.Text = '无法检测：' + $_.Exception.Message
        $ctl.TxtFallbackState.Foreground = Get-UiBrush '#B45309'
        return
    }
    $script:FallbackStatus = $st
    if (-not $st.Supported) {
        $ctl.TxtFallbackState.Text = '暂不可用：' + $st.Reason
        $ctl.TxtFallbackState.Foreground = Get-UiBrush '#B45309'
        return
    }
    $parts = @()
    $parts += $(if ($st.DirMode) { '目录模式' } else { 'asar 模式' })
    $parts += $(if ($st.FuseIntegrityOn) { '完整性校验=开' } else { '完整性校验=关' })
    if ($st.FuseChanged) { $parts += '已改过开关' }
    if (-not $st.SignatureOk) { $parts += '签名已失效' }
    $ctl.TxtFallbackState.Text = ($parts -join ' · ')
    if ($st.DirMode -or $st.FuseChanged -or -not $st.SignatureOk) {
        $ctl.TxtFallbackState.Foreground = Get-UiBrush '#B45309'
    } else {
        $ctl.TxtFallbackState.Foreground = Get-UiBrush '#9CA3AF'
    }
}

# ------------------------------------------------------------------ 后台任务

function Start-Worker {
    param([hashtable]$Parameters, [string]$Status)

    $logName = ('{0}-{1}.log' -f $Parameters['Action'], (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $logPath = Join-Path $script:LogDir $logName
    $Parameters['LogFile'] = $logPath

    $script:LastLogText = ''
    $ctl.LogBox.Clear()

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    [void]$ps.AddScript({
        param($corePath, $unlockCorePath, $action, $pluginPath, $profiles, $enableConfig, $forceVersion, $manualMode,
              $pluginName, $deleteCopy, $logFile)
        . $corePath
        if ($unlockCorePath -and (Test-Path -LiteralPath $unlockCorePath)) { . $unlockCorePath }
        switch ($action) {
            'install' {
                return (Invoke-InstallWorkflow -PluginPath $pluginPath -Profiles $profiles -EnableConfig $enableConfig `
                    -ForceVersion $forceVersion -ManualMode $manualMode -LogFile $logFile)
            }
            'uninstall' {
                return (Invoke-UninstallWorkflow -PluginName $pluginName -Profiles $profiles -DeleteCopy $deleteCopy -LogFile $logFile)
            }
            'status' {
                return (Invoke-StatusWorkflow -PluginPath $pluginPath -LogFile $logFile)
            }
            'unlock' {
                return (Invoke-UnlockWorkflow -LogFile $logFile)
            }
            'restore' {
                return (Invoke-UnlockWorkflow -LogFile $logFile -Restore)
            }
            'dir-on' {
                return (Invoke-FallbackWorkflow -LogFile $logFile -Action 'dir-on')
            }
            'dir-off' {
                return (Invoke-FallbackWorkflow -LogFile $logFile -Action 'dir-off')
            }
            'fuse-off' {
                return (Invoke-FallbackWorkflow -LogFile $logFile -Action 'fuse-off')
            }
            'fuse-restore' {
                return (Invoke-FallbackWorkflow -LogFile $logFile -Action 'fuse-restore')
            }
            'autoheal' {
                return (Invoke-UnlockWorkflow -LogFile $logFile -AutoHeal)
            }
        }
    })
    [void]$ps.AddArgument($script:CorePath)
    [void]$ps.AddArgument($script:UnlockCorePath)
    [void]$ps.AddArgument($Parameters['Action'])
    [void]$ps.AddArgument($Parameters['PluginPath'])
    [void]$ps.AddArgument($Parameters['Profiles'])
    [void]$ps.AddArgument([bool]$Parameters['EnableConfig'])
    [void]$ps.AddArgument([bool]$Parameters['ForceVersion'])
    [void]$ps.AddArgument([bool]$Parameters['ManualMode'])
    [void]$ps.AddArgument($Parameters['PluginName'])
    [void]$ps.AddArgument([bool]$Parameters['DeleteCopy'])
    [void]$ps.AddArgument($logPath)

    Set-UiBusy -Busy $true -Status $Status
    $script:Job = [pscustomobject]@{ PowerShell = $ps; Runspace = $rs; Handle = $ps.BeginInvoke(); LogPath = $logPath; Action = $Parameters['Action'] }
    $script:JobTimer.Start()
}

function Read-LogTail {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } catch { return }
    if (-not $text) { return }
    if ($text.Length -gt $script:LastLogText.Length) {
        $delta = $text.Substring($script:LastLogText.Length)
        $script:LastLogText = $text
        $ctl.LogBox.AppendText($delta)
        $ctl.LogBox.ScrollToEnd()
    }
}

function Complete-Job {
    $job = $script:Job
    $script:JobTimer.Stop()
    Read-LogTail -Path $job.LogPath
    $result = $null
    $failure = ''
    try {
        $output = $job.PowerShell.EndInvoke($job.Handle)
        foreach ($o in $output) {
            if ($o -and ($o.PSObject.Properties['Ok'] -or $o.PSObject.Properties['Rows'])) { $result = $o }
        }
    } catch {
        $failure = $_.Exception.Message
    }
    try { $job.PowerShell.Dispose() } catch { }
    try { $job.Runspace.Dispose() } catch { }
    $script:Job = $null
    Set-UiBusy -Busy $false

    if ($failure) {
        $ctl.TxtStatus.Text = '出错了：' + $failure
        Write-UiLog ('错误：' + $failure)
        return
    }
    if (-not $result) {
        $ctl.TxtStatus.Text = '任务结束，但没有拿到结果（请看日志）'
        return
    }

    if ($job.Action -eq 'status') {
        $ctl.TxtStatus.Text = '检查完成'
        if (-not $result.Ok) { $ctl.TxtStatus.Text = '检查失败：' + $result.Error }
        return
    }
    if ($job.Action -in @('unlock', 'restore', 'autoheal', 'dir-on', 'dir-off', 'fuse-off', 'fuse-restore')) {
        Update-UnlockCard
        Update-FallbackCard
        if ($result.Ok) {
            $ctl.TxtStatus.Text = $result.Message
            Write-UiLog ('完成：' + $result.Message)
        } else {
            $ctl.TxtStatus.Text = '失败：' + $result.Error
            Write-UiLog ('失败：' + $result.Error)
        }
        return
    }
    if ($result.Ok) {
        $ctl.TxtStatus.Text = $result.Message
        Write-UiLog ('完成：' + $result.Message)
    } else {
        $ctl.TxtStatus.Text = '失败：' + $result.Error
        Write-UiLog ('失败：' + $result.Error)
    }
}

# ------------------------------------------------------------------ 事件

$ctl.BtnRefresh.Add_Click({
    try {
        Update-EnvironmentCard
        Update-PluginList
        Update-UnlockCard
        Update-FallbackCard
        $ctl.TxtStatus.Text = '环境已重新检测'
    } catch {
        $ctl.TxtStatus.Text = '检测失败：' + $_.Exception.Message
    }
})

$ctl.CmbPlugin.Add_SelectionChanged({
    if ($script:BusySelf) { return }
    Update-PluginCard -Path (Get-SelectedPluginPath)
})

$ctl.BtnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择插件文件夹（里面有 package.json 的那个）'
    $dlg.ShowNewFolderButton = $false
    if ($dlg.ShowDialog() -eq 'OK') {
        Update-PluginCard -Path $dlg.SelectedPath
        $item = [pscustomobject]@{ Label = ('（手动选择）  ' + (Split-Path -Leaf $dlg.SelectedPath)); Path = $dlg.SelectedPath }
        $ctl.CmbPlugin.Items.Add($item) | Out-Null
        $ctl.CmbPlugin.SelectedItem = $item
    }
})

$ctl.BtnBrowseZip.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = '选择插件压缩包'
    $dlg.Filter = '压缩包 (*.zip)|*.zip|所有文件 (*.*)|*.*'
    if ($dlg.ShowDialog() -eq 'OK') {
        Update-PluginCard -Path $dlg.FileName
        $item = [pscustomobject]@{ Label = ('（压缩包）  ' + (Split-Path -Leaf $dlg.FileName)); Path = $dlg.FileName }
        $ctl.CmbPlugin.Items.Add($item) | Out-Null
        $ctl.CmbPlugin.SelectedItem = $item
    }
})

function Get-TargetProfiles {
    $list = @()
    if ($ctl.ChkDesktop.IsChecked) { $list += 'desktop' }
    if ($ctl.ChkWeb.IsChecked) { $list += 'web' }
    return $list
}

function Confirm-TargetsOrWarn {
    $targets = Get-TargetProfiles
    if (@($targets).Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('请先勾选要安装到哪个版本（桌面版 / Web 版）。', 'DSH 插件安装器') | Out-Null
        return $null
    }
    if (Test-DshDesktopRunning) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "检测到 DeepSeek Harness 正在运行。`n安装会修改它的配置文件，建议先完全退出（包括右下角托盘图标）。`n`n仍然继续吗？",
            '建议先退出 DSH', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return $null }
    }
    return $targets
}

$ctl.BtnInstall.Add_Click({
    try {
        $path = Get-SelectedPluginPath
        if (-not $path) {
            [System.Windows.Forms.MessageBox]::Show('请先选择插件（文件夹或压缩包）。', 'DSH 插件安装器') | Out-Null
            return
        }
        $targets = Confirm-TargetsOrWarn
        if (-not $targets) { return }
        $params = @{
            Action       = 'install'
            PluginPath   = $path
            Profiles     = [string[]]$targets
            EnableConfig = [bool]$ctl.ChkEnable.IsChecked
            ForceVersion = [bool]$ctl.ChkForce.IsChecked
            ManualMode   = [bool]$ctl.ChkManual.IsChecked
            PluginName   = ''
            DeleteCopy   = $false
        }
        Start-Worker -Parameters $params -Status '正在安装，请稍候…'
    } catch {
        $ctl.TxtStatus.Text = '启动失败：' + $_.Exception.Message
    }
})

$ctl.BtnUninstall.Add_Click({
    try {
        $info = $script:CurrentPluginInfo
        $name = ''
        if ($info) { $name = $info.Name }
        if (-not $name) {
            $name = [Microsoft.VisualBasic.Interaction]::InputBox('要卸载的插件名（package.json 里的 name）：', '卸载插件', '')
        }
        if (-not $name) { return }
        $targets = Get-TargetProfiles
        if (@($targets).Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('请先勾选要卸载哪个版本（桌面版 / Web 版）。', 'DSH 插件安装器') | Out-Null
            return
        }
        $r = [System.Windows.Forms.MessageBox]::Show(
            ("确认卸载「{0}」？`n目标：{1}`n`n（安装器备份的配置文件可在 %USERPROFILE%\.dsh\plugin-installer-backups 里找回）" -f $name, ($targets -join '、')),
            '确认卸载', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        $params = @{
            Action       = 'uninstall'
            PluginPath   = ''
            Profiles     = [string[]]$targets
            EnableConfig = $false
            ForceVersion = $false
            ManualMode   = $false
            PluginName   = $name
            DeleteCopy   = $true
        }
        Start-Worker -Parameters $params -Status ('正在卸载 ' + $name + ' …')
    } catch {
        $ctl.TxtStatus.Text = '启动失败：' + $_.Exception.Message
    }
})

$ctl.BtnStatus.Add_Click({
    try {
        $path = Get-SelectedPluginPath
        $params = @{
            Action       = 'status'
            PluginPath   = $path
            Profiles     = [string[]]@()
            EnableConfig = $false
            ForceVersion = $false
            ManualMode   = $false
            PluginName   = ''
            DeleteCopy   = $false
        }
        Start-Worker -Parameters $params -Status '正在检查…'
    } catch {
        $ctl.TxtStatus.Text = '启动失败：' + $_.Exception.Message
    }
})

$ctl.BtnUnlock.Add_Click({
    try {
        $st = $script:UnlockStatus
        if (-not $st) { Update-UnlockCard; $st = $script:UnlockStatus }
        if ($st -and -not $st.Supported) {
            [System.Windows.Forms.MessageBox]::Show(('现在无法操作：' + $st.Reason), 'DSH 插件安装器', 'OK', 'Warning') | Out-Null
            return
        }
        if ($st -and $st.Running) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "DeepSeek Harness 现在正在运行，改主程序会失败。`n`n请先完全退出（包括右下角托盘图标），退出后再点一次。`n`n仍然继续吗？",
                '请先退出 DSH', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
        }
        if ($st -and $st.Applied) {
            $r = [System.Windows.Forms.MessageBox]::Show('插件版本限制已经解除过了，要再做一次吗？', 'DSH 插件安装器', 'YesNo', 'Question')
            if ($r -ne 'Yes') { return }
        } else {
            $msg = "接下来会改写 DSH 主程序里的一个文件，让「插件版本检查」永远通过。`n`n· 不备份大文件，随时能一键还原（删掉插入的那一行即可）`n· 改完会在沙盒里真跑一遍，确认补丁确实生效才替换`n· 大约需要半分钟（要写 116 MB）`n· 操作期间请不要打开 DeepSeek Harness`n`n继续吗？"
            $r = [System.Windows.Forms.MessageBox]::Show($msg, '解除插件版本限制', 'YesNo', 'Question')
            if ($r -ne 'Yes') { return }
        }
        Start-Worker -Parameters @{ Action = 'unlock' } -Status '正在解除限制，请稍候…'
    } catch {
        $ctl.TxtStatus.Text = '启动失败：' + $_.Exception.Message
    }
})

$ctl.BtnRestoreOfficial.Add_Click({
    try {
        $st = $script:UnlockStatus
        if (-not $st) { Update-UnlockCard; $st = $script:UnlockStatus }
        if ($st -and $st.Running) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "DeepSeek Harness 现在正在运行，请先完全退出（包括托盘图标）。`n`n仍然继续吗？",
                '请先退出 DSH', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
        }
        $r = [System.Windows.Forms.MessageBox]::Show(
            "把 DSH 主程序还原成官方原版文件？`n`n还原后，插件版本限制会恢复成官方行为（版本不兼容的插件又会被停用）。`n`n继续吗？",
            '还原官方文件', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        Start-Worker -Parameters @{ Action = 'restore' } -Status '正在还原官方文件，请稍候…'
    } catch {
        $ctl.TxtStatus.Text = '启动失败：' + $_.Exception.Message
    }
})

$ctl.ChkAutoHeal.Add_Click({
    try {
        $prefs = Read-UnlockPrefs
        $prefs.AutoHeal = [bool]$ctl.ChkAutoHeal.IsChecked
        Write-UnlockPrefs -Prefs $prefs
        Write-UiLog ('自动修复已' + $(if ($prefs.AutoHeal) { '开启' } else { '关闭' }))
    } catch {
        $ctl.TxtStatus.Text = '保存设置失败：' + $_.Exception.Message
    }
})

$ctl.BtnDirOn.Add_Click({
    try {
        $st = $script:FallbackStatus
        if (-not $st) { Update-FallbackCard; $st = $script:FallbackStatus }
        if ($st -and $st.DirMode) { $ctl.TxtStatus.Text = '现在已经是目录模式了'; return }
        $r = [System.Windows.Forms.MessageBox]::Show(
            "改用「目录加载」？`n`n会把 resources\app.asar 摊开成 resources\app 目录（约 360 MB，一万多个文件），然后把 app.asar 改名。`n`n· 好处：asar 都不存在了，asar 完整性校验也就无从对比`n· 代价：多占约 360 MB 磁盘，启动稍慢`n· 随时可以点「还原成 asar 加载」改回来`n`n操作前请完全退出 DeepSeek Harness。继续吗？",
            '改用目录加载', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        Start-Worker -Parameters @{ Action = 'dir-on' } -Status '正在切换成目录模式，请稍候…'
    } catch {
        $ctl.TxtStatus.Text = '启动失败：' + $_.Exception.Message
    }
})

$ctl.BtnDirOff.Add_Click({
    try {
        $st = $script:FallbackStatus
        if (-not $st) { Update-FallbackCard; $st = $script:FallbackStatus }
        if ($st -and -not $st.DirMode) { $ctl.TxtStatus.Text = '现在本来就是 asar 方式'; return }
        $r = [System.Windows.Forms.MessageBox]::Show(
            "还原成 asar 加载？`n`n会删掉 resources\app 目录，并把 app.asar.disabled 改回 app.asar。`n`n继续吗？",
            '还原成 asar 加载', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        Start-Worker -Parameters @{ Action = 'dir-off' } -Status '正在还原成 asar 方式，请稍候…'
    } catch {
        $ctl.TxtStatus.Text = '启动失败：' + $_.Exception.Message
    }
})

$ctl.BtnFuseOff.Add_Click({
    try {
        $st = $script:FallbackStatus
        if (-not $st) { Update-FallbackCard; $st = $script:FallbackStatus }
        if ($st -and -not $st.FuseIntegrityOn) { $ctl.TxtStatus.Text = '这个版本本来就没开 asar 完整性校验，不用降'; return }
        $r = [System.Windows.Forms.MessageBox]::Show(
            "降低检测强度？`n`n会修改 DeepSeek Harness.exe 里的一个开关，关掉 asar 完整性校验。`n`n※ 代价：exe 的官方数字签名会失效，Windows 可能提示「未知发布者」。`n※ 随时可以点「恢复官方签名状态」改回原值（我们记了原值）。`n`n操作前请完全退出 DeepSeek Harness。继续吗？",
            '降低检测强度', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
        Start-Worker -Parameters @{ Action = 'fuse-off' } -Status '正在修改开关，请稍候…'
    } catch {
        $ctl.TxtStatus.Text = '启动失败：' + $_.Exception.Message
    }
})

$ctl.BtnFuseRestore.Add_Click({
    try {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "把改过的开关恢复成官方原值？`n`n恢复后 exe 与官方发布时逐字节一致，数字签名也回来了。`n`n继续吗？",
            '恢复官方签名状态', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        Start-Worker -Parameters @{ Action = 'fuse-restore' } -Status '正在恢复开关，请稍候…'
    } catch {
        $ctl.TxtStatus.Text = '启动失败：' + $_.Exception.Message
    }
})

$ctl.BtnOpenLog.Add_Click({
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList $script:LogDir
    } catch { }
})

$ctl.BtnClose.Add_Click({ $script:Shell.Close() })

$script:JobTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:JobTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:JobTimer.Add_Tick({
    if (-not $script:Job) { $script:JobTimer.Stop(); return }
    Read-LogTail -Path $script:Job.LogPath
    if ($script:Job.PowerShell.InvocationStateInfo.State -ne 'Running') {
        Complete-Job
    }
})

# ------------------------------------------------------------------ 自检

if ($SelfTest) {
    Write-Host '自检：XAML 加载成功'
    Write-Host ('自检：DSH 主目录 = ' + (Get-DshHomePath))
    $app = Find-DshApp
    Write-Host ('自检：桌面版 = ' + $(if ($app) { $app } else { '未找到' }))
    $cli = Find-DshCli
    if ($cli) {
        Write-Host ('自检：命令行 = ' + $cli.Path + '（' + $cli.Kind + '）')
        Write-Host ('自检：DSH 版本 = ' + (Get-DshRuntimeVersion -Cli $cli))
    } else {
        Write-Host '自检：命令行 = 未找到'
    }
    $profs = Get-DshProfiles
    foreach ($p in $profs) { Write-Host ('自检：profile ' + $p.Name + ' 已初始化=' + $p.Initialized) }
    $cands = Find-CandidatePlugins
    foreach ($c in $cands) { Write-Host ('自检：候选插件 ' + $c.Label + ' -> ' + $c.Path) }
    $rv = Test-SemVerRange -Version '0.2.0-rc.2' -Range '>=0.1.0'
    Write-Host ('自检：版本范围 0.2.0-rc.2 in >=0.1.0 = ' + $rv.InRange)
    $rv2 = Test-SemVerRange -Version '0.2.0-rc.2' -Range '>=0.3.0'
    Write-Host ('自检：版本范围 0.2.0-rc.2 in >=0.3.0 = ' + $rv2.InRange)
    try {
        $us = Get-UnlockStatus
        Write-Host ('自检：解除限制 supported=' + $us.Supported + ' reason=' + $us.Reason + ' applied=' + $us.Applied + ' fuseBlocked=' + $us.FuseBlocked)
        Write-Host ('自检：目标文件 = ' + $us.ModuleEntry + '  补丁点 = ' + $us.PatchId + '  签名校验迹象 = ' + $us.SignatureRisk + '  自动修复 = ' + $us.AutoHeal)
    } catch { Write-Host ('自检：解除限制检测失败 ' + $_.Exception.Message) }
    try {
        $fs = Get-FallbackStatus
        Write-Host ('自检：应急开关 supported=' + $fs.Supported + ' dirMode=' + $fs.DirMode + ' 完整性校验=' + $fs.FuseIntegrityOn + ' 只从asar加载=' + $fs.FuseOnlyAsarOn + ' 签名=' + $fs.SignatureOk + ' 空闲=' + $fs.FreeMB + 'MB')
    } catch { Write-Host ('自检：应急开关检测失败 ' + $_.Exception.Message) }
    Write-Host '自检结束'
    exit 0
}

Update-EnvironmentCard
Update-PluginList
Update-UnlockCard
Update-FallbackCard
Set-UiBusy -Busy $false
$ctl.TxtStatus.Text = '准备就绪：选择插件后点「开始安装」'
Write-UiLog '运行日志会显示在这里。点「开始安装」后，每一步都会实时写在这里。'

# 官方更新把补丁冲掉以后，这里会自动重打（不问用户，因为是他自己开的）
function Invoke-StartupAutoHeal {
    try {
        $st = $script:UnlockStatus
        if (-not $st -or -not $st.Supported -or -not $st.AutoHeal) { return }
        if ($st.Applied -or $st.FuseBlocked) { return }
        if (-not (Read-UnlockState)) { return }
        if ($st.Running) {
            Write-UiLog '检测到 DSH 更新过、补丁已失效；等 DeepSeek Harness 退出后会自动修复。'
            return
        }
        Write-UiLog '检测到 DSH 更新过、补丁已失效，正在自动修复…'
        Start-Worker -Parameters @{ Action = 'autoheal' } -Status '正在自动修复补丁…'
    } catch { }
}
$script:Shell.Add_ContentRendered({ Invoke-StartupAutoHeal })

[void]$script:Shell.ShowDialog()
