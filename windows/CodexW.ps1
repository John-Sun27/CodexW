param([switch]$DumpJson)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$NativeWindowCode = @'
using System;
using System.Runtime.InteropServices;
public static class CodexUNativeWindow {
    public static readonly IntPtr HWND_BOTTOM = new IntPtr(1);
    public const UInt32 SWP_NOSIZE = 0x0001;
    public const UInt32 SWP_NOMOVE = 0x0002;
    public const UInt32 SWP_NOACTIVATE = 0x0010;
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, UInt32 uFlags);
}
'@
Add-Type -TypeDefinition $NativeWindowCode


$Script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:RepoRoot = Split-Path -Parent $Script:AppRoot
$Script:SelfPath = $MyInvocation.MyCommand.Path
$Script:IconPng = Join-Path $Script:RepoRoot 'Resources\CodexW-icon.png'
$Script:CodexHome = Join-Path $env:USERPROFILE '.codex'
$Script:AllowExit = $false
$Script:IsQuitting = $false
$Script:App = $null
$Script:KeepOnDesktopBottom = $true
$Script:TrayNotify = $null
$Script:TrayBitmap = $null
$Script:TrayIcon = $null
$Script:TrayMenuWindow = $null
$Script:SettingsDir = Join-Path $env:LOCALAPPDATA 'CodexW'
$Script:SettingsPath = Join-Path $Script:SettingsDir 'settings.json'
$Script:PositionSaveTimer = $null
$Script:Language = 'zh'
$Script:ThemeMode = 'auto'
$Script:PlanLabel = 'PLUS'
$Script:StartupRunName = 'CodexW'
$Script:AutoRefreshEnabled = $true
$Script:AutoRefreshTimer = $null
$Script:AutoRefreshMinutes = 5

function Get-PropValue {
    param($Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $prop = $Object.PSObject.Properties[$name]
        if ($null -ne $prop) { return $prop.Value }
    }
    return $null
}

function Format-TokenCount {
    param([double]$Value)
    if ($Value -ge 1000000) { return ('{0:N1}M' -f ($Value / 1000000)) }
    if ($Value -ge 1000) { return ('{0:N1}K' -f ($Value / 1000)) }
    return ('{0:N0}' -f $Value)
}

function Format-Usd {
    param([double]$Value)
    if ($Value -ge 1000) { return ('${0:N0}' -f $Value) }
    return ('${0:N2}' -f $Value)
}

function Format-ResetTime {
    param($UnixSeconds)
    if ($null -eq $UnixSeconds) { return '--' }
    try {
        $dt = [DateTimeOffset]::FromUnixTimeSeconds([int64]$UnixSeconds).LocalDateTime
        if ($dt.Date -eq (Get-Date).Date) { return $dt.ToString('HH:mm') }
        return $dt.ToString('M/d HH:mm')
    } catch { return '--' }
}

function New-TokenBucket {
    [ordered]@{
        input = [int64]0
        cached = [int64]0
        output = [int64]0
        reasoning = [int64]0
        total = [int64]0
        cost = [double]0
    }
}

function Add-TokenUsage {
    param($Bucket, $Usage, [double]$InputPrice = 5, [double]$CachedPrice = 0.5, [double]$OutputPrice = 30)
    if ($null -eq $Usage) { return }

    $input = [int64]([double](Get-PropValue $Usage @('input_tokens', 'inputTokens')))
    $cached = [int64]([double](Get-PropValue $Usage @('cached_input_tokens', 'cachedInputTokens')))
    $output = [int64]([double](Get-PropValue $Usage @('output_tokens', 'outputTokens')))
    $reasoning = [int64]([double](Get-PropValue $Usage @('reasoning_output_tokens', 'reasoningOutputTokens')))
    $total = [int64]([double](Get-PropValue $Usage @('total_tokens', 'totalTokens')))
    if ($total -le 0) { $total = $input + $output }

    $billableCached = [Math]::Min([Math]::Max($cached, 0), [Math]::Max($input, 0))
    $uncached = [Math]::Max(0, $input - $billableCached)
    $cost = ($uncached / 1000000.0 * $InputPrice) + ($billableCached / 1000000.0 * $CachedPrice) + ([Math]::Max($output, 0) / 1000000.0 * $OutputPrice)

    $Bucket.input += $input
    $Bucket.cached += $billableCached
    $Bucket.output += $output
    $Bucket.reasoning += $reasoning
    $Bucket.total += $total
    $Bucket.cost += $cost
}

function Convert-RateWindow {
    param($Window)
    if ($null -eq $Window) { return $null }
    $used = [double](Get-PropValue $Window @('used_percent', 'usedPercent'))
    [ordered]@{
        usedPercent = $used
        remainingPercent = [Math]::Max(0, [Math]::Min(100, 100 - $used))
        windowDurationMins = Get-PropValue $Window @('window_minutes', 'windowDurationMins')
        resetsAt = Get-PropValue $Window @('resets_at', 'resetsAt')
    }
}

function Get-SessionFiles {
    $files = @()
    $roots = @(
        (Join-Path $Script:CodexHome 'sessions'),
        (Join-Path $Script:CodexHome 'archived_sessions')
    )
    foreach ($root in $roots) {
        if (Test-Path $root) {
            $files += Get-ChildItem $root -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue
        }
    }
    return @($files | Sort-Object FullName -Unique)
}


function Read-SharedLines {
    param([string]$Path)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object System.IO.StreamReader($stream)
        try {
            while (($line = $reader.ReadLine()) -ne $null) { $line }
        } finally {
            $reader.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}
function Read-LocalSnapshot {
    $messages = New-Object System.Collections.Generic.List[string]
    $today = New-TokenBucket
    $seven = New-TokenBucket
    $month = New-TokenBucket
    $life = New-TokenBucket
    $daily = @{}
    $latestRate = $null
    $latestRateAt = [DateTime]::MinValue

    $now = Get-Date
    $dayStart = $now.Date
    $sevenStart = $dayStart.AddDays(-6)
    $monthStart = Get-Date -Year $now.Year -Month $now.Month -Day 1 -Hour 0 -Minute 0 -Second 0
    $files = Get-SessionFiles

    if ($files.Count -eq 0) {
        $messages.Add('未找到 Codex session 日志。')
    }

    $eventCount = 0
    foreach ($file in $files) {
        try {
            foreach ($line in (Read-SharedLines $file.FullName)) {
                if ($line -notmatch '"token_count"') { continue }
                try { $event = $line | ConvertFrom-Json } catch { continue }
                $payload = Get-PropValue $event @('payload')
                if ((Get-PropValue $payload @('type')) -ne 'token_count') { continue }

                $ts = Get-PropValue $event @('timestamp')
                try { $date = [DateTimeOffset]::Parse($ts).LocalDateTime } catch { $date = $file.LastWriteTime }
                $info = Get-PropValue $payload @('info')
                $usage = Get-PropValue $info @('last_token_usage', 'lastTokenUsage')
                if ($null -eq $usage) { continue }

                Add-TokenUsage $life $usage
                if ($date -ge $monthStart) { Add-TokenUsage $month $usage }
                if ($date -ge $sevenStart) { Add-TokenUsage $seven $usage }
                if ($date -ge $dayStart) { Add-TokenUsage $today $usage }

                $total = [int64]([double](Get-PropValue $usage @('total_tokens', 'totalTokens')))
                if ($total -le 0) {
                    $total = [int64]([double](Get-PropValue $usage @('input_tokens', 'inputTokens'))) + [int64]([double](Get-PropValue $usage @('output_tokens', 'outputTokens')))
                }
                $key = $date.ToString('yyyy-MM-dd')
                if (-not $daily.ContainsKey($key)) { $daily[$key] = [int64]0 }
                $daily[$key] += $total

                $rate = Get-PropValue $payload @('rate_limits', 'rateLimits')
                if (-not $rate) { $rate = Get-PropValue $event @('rate_limits', 'rateLimits') }
                if ($rate -and $date -gt $latestRateAt) {
                    $latestRate = $rate
                    $latestRateAt = $date
                }
                $eventCount++
            }
        } catch {
            $messages.Add('读取日志失败：' + $file.Name)
        }
    }

    if ($eventCount -eq 0 -and $files.Count -gt 0) {
        $messages.Add('未找到 Codex token_count 事件。')
    }

    $buckets = @()
    for ($i = 6; $i -ge 0; $i--) {
        $d = $dayStart.AddDays(-$i)
        $k = $d.ToString('yyyy-MM-dd')
        $label = if ($i -eq 0) { '今天' } else { $d.ToString('M/d') }
        $value = if ($daily.ContainsKey($k)) { $daily[$k] } else { 0 }
        $buckets += [ordered]@{ day = $k; label = $label; tokens = $value }
    }

    $primary = $null
    $secondary = $null
    $planType = $null
    if ($latestRate) {
        $primary = Convert-RateWindow (Get-PropValue $latestRate @('primary'))
        $secondary = Convert-RateWindow (Get-PropValue $latestRate @('secondary'))
        $planType = Get-PropValue $latestRate @('plan_type', 'planType')
    }

    [ordered]@{
        refreshedAt = (Get-Date).ToString('s')
        source = 'local-session-logs'
        codexHome = $Script:CodexHome
        account = [ordered]@{ type = 'local'; planType = $planType; emailPresent = $false }
        primary = $primary
        secondary = $secondary
        local = [ordered]@{
            today = $today
            sevenDay = $seven
            month = $month
            lifetime = $life
            dailyBuckets = $buckets
            parsedFileCount = $files.Count
            tokenEventCount = $eventCount
        }
        automations = Read-Automations
        messages = @($messages)
    }
}

function Read-Automations {
    $items = @()
    $root = Join-Path $Script:CodexHome 'automations'
    if (-not (Test-Path $root)) { return $items }
    $files = Get-ChildItem $root -Recurse -Filter 'automation.toml' -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        $text = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $text) { continue }
        $name = [regex]::Match($text, '(?m)^name\s*=\s*"([^"]*)"').Groups[1].Value
        $status = [regex]::Match($text, '(?m)^status\s*=\s*"([^"]*)"').Groups[1].Value
        $rrule = [regex]::Match($text, '(?m)^rrule\s*=\s*"([^"]*)"').Groups[1].Value
        if (-not $name) { $name = Split-Path -Leaf (Split-Path -Parent $file.FullName) }
        if (-not $status) { $status = 'UNKNOWN' }
        $items += [ordered]@{ name = $name; status = $status; rrule = $rrule; updatedAt = $file.LastWriteTime.ToString('s') }
    }
    return $items
}


function New-Brush([string]$Color) { [Windows.Media.BrushConverter]::new().ConvertFromString($Color) }
function Find($Name) { $Script:Window.FindName($Name) }
function New-ArcGeometry {
    param([double]$Cx,[double]$Cy,[double]$Radius,[double]$Start,[double]$Sweep)
    if ($Sweep -lt 0.1) { $Sweep = 0.1 }
    if ($Sweep -gt 359.8) { $Sweep = 359.8 }
    $a1 = ($Start - 90) * [Math]::PI / 180; $a2 = ($Start + $Sweep - 90) * [Math]::PI / 180
    $p1 = [Windows.Point]::new($Cx + $Radius * [Math]::Cos($a1), $Cy + $Radius * [Math]::Sin($a1)); $p2 = [Windows.Point]::new($Cx + $Radius * [Math]::Cos($a2), $Cy + $Radius * [Math]::Sin($a2))
    $fig = [Windows.Media.PathFigure]::new(); $fig.StartPoint = $p1
    $seg = [Windows.Media.ArcSegment]::new(); $seg.Point = $p2; $seg.Size = [Windows.Size]::new($Radius,$Radius); $seg.IsLargeArc = ($Sweep -gt 180); $seg.SweepDirection = [Windows.Media.SweepDirection]::Clockwise
    $fig.Segments.Add($seg); $geo = [Windows.Media.PathGeometry]::new(); $geo.Figures.Add($fig); $geo
}
function Get-RecentTaskItems { $items=@(); $files=@(Get-SessionFiles|Sort-Object LastWriteTime -Descending|Select-Object -First 6); foreach($file in $files){ $hash=[Math]::Abs($file.Name.GetHashCode()).ToString('X'); if($hash.Length -gt 4){$hash=$hash.Substring(0,4)}; $tokens=[int64]0; try{foreach($line in (Read-SharedLines $file.FullName)){if($line -match '"token_count"'){try{$obj=$line|ConvertFrom-Json}catch{continue}; $payload=Get-PropValue $obj @('payload'); $info=Get-PropValue $payload @('info'); $usage=Get-PropValue $info @('last_token_usage','lastTokenUsage'); $tokens += [int64]([double](Get-PropValue $usage @('total_tokens','totalTokens')))}}}catch{}; $items += [ordered]@{code=('COD-'+$hash); title=(Get-UiText '本地 Codex 会话' 'Local Codex Session'); detail=((Get-UiText 'New project 2' 'New project 2')+' · '+(Format-TokenCount $tokens)); updatedAt=$file.LastWriteTime} }; $items }
function Get-RelativeText([datetime]$Date){ $s=(Get-Date)-$Date; if($s.TotalMinutes -lt 60){ $n=([math]::Max(1,[int]$s.TotalMinutes)); return $n.ToString()+(Get-UiText ' 分钟前' ' min ago') } elseif($s.TotalHours -lt 24){ $n=[int]$s.TotalHours; return $n.ToString()+(Get-UiText ' 小时前' ' h ago') } else { $n=[int]$s.TotalDays; return $n.ToString()+(Get-UiText ' 天前' ' d ago') } }

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="1120" Height="900" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" Background="Transparent" WindowStartupLocation="CenterScreen" Topmost="False" ShowInTaskbar="False" FontFamily="Segoe UI, Microsoft YaHei UI">
<Grid><Border x:Name="RootShell" Margin="20" CornerRadius="36" Background="#C38AAEBC" BorderBrush="#55FFFFFF" BorderThickness="1.2"><Border.Effect><DropShadowEffect BlurRadius="28" ShadowDepth="0" Opacity="0.35" Color="#1E3744"/></Border.Effect><Grid Margin="16"><Grid.RowDefinitions><RowDefinition Height="66"/><RowDefinition Height="346"/><RowDefinition Height="*"/><RowDefinition Height="28"/></Grid.RowDefinitions>
<Grid Grid.Row="0"><StackPanel Orientation="Horizontal" VerticalAlignment="Center"><Border Width="42" Height="42" CornerRadius="10" Background="#F7FFFFFF"><Image x:Name="LogoImage" Margin="5" Stretch="Uniform"/></Border><TextBlock x:Name="BrandText" Text="CodexW" FontSize="32" FontWeight="Black" Foreground="#02080D" Margin="16,0,0,2" VerticalAlignment="Center"/></StackPanel><StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center"><Border x:Name="ThemeSwitch" Cursor="Hand" CornerRadius="7" Background="#50485561" Padding="3" Margin="0,0,46,0"><StackPanel Orientation="Horizontal"><Border x:Name="ThemeAutoSegment" Width="24" Height="24" CornerRadius="5" Background="#168DFF"><TextBlock x:Name="ThemeAutoText" Text="◐" FontSize="13" FontWeight="Black" Foreground="#FFFFFF" TextAlignment="Center" VerticalAlignment="Center" HorizontalAlignment="Center"/></Border><Border x:Name="ThemeLightSegment" Width="24" Height="24" CornerRadius="5" Background="#00000000"><TextBlock x:Name="ThemeLightText" Text="☀" FontSize="13" FontWeight="Black" Foreground="#102A38" TextAlignment="Center" VerticalAlignment="Center" HorizontalAlignment="Center"/></Border><Border x:Name="ThemeDarkSegment" Width="24" Height="24" CornerRadius="5" Background="#00000000"><TextBlock x:Name="ThemeDarkText" Text="◑" FontSize="13" FontWeight="Black" Foreground="#102A38" TextAlignment="Center" VerticalAlignment="Center" HorizontalAlignment="Center"/></Border></StackPanel></Border><Border x:Name="LanguageSwitch" Cursor="Hand" CornerRadius="6" Background="#505194AD" Padding="3" Margin="0,0,20,0"><StackPanel Orientation="Horizontal"><Border x:Name="LangZhSegment" Width="38" Height="26" CornerRadius="5" Background="#168DFF"><TextBlock x:Name="LangZhText" Text="中" FontSize="14" FontWeight="Black" Foreground="#FFFFFF" TextAlignment="Center" VerticalAlignment="Center" HorizontalAlignment="Center"/></Border><Border x:Name="LangEnSegment" Width="38" Height="26" CornerRadius="5" Background="#00000000"><TextBlock x:Name="LangEnText" Text="EN" FontSize="14" FontWeight="Black" Foreground="#102A38" TextAlignment="Center" VerticalAlignment="Center" HorizontalAlignment="Center"/></Border></StackPanel></Border><Border CornerRadius="20" Background="#D8EAF2F4" Padding="13,8" Margin="0,0,14,0"><TextBlock x:Name="PlanText" Text="PLUS" FontSize="18" FontWeight="Black" Foreground="#51616C"/></Border><Button x:Name="RefreshButton" Content="↻" Width="70" Height="48" FontSize="24" FontWeight="Bold" Background="#66D5E5EB" Foreground="#536A78" BorderThickness="0" Margin="0,0,12,0"/><Button x:Name="CloseButton" Content="×" Width="70" Height="48" FontSize="28" FontWeight="SemiBold" Background="#66D5E5EB" Foreground="#536A78" BorderThickness="0"/></StackPanel></Grid>
<Border Grid.Row="1" CornerRadius="24" Background="#58D2E9F1" Padding="22" BorderBrush="#35FFFFFF" BorderThickness="1"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="250"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Grid Grid.Column="0"><Canvas Width="220" Height="220" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,24,0,0"><Ellipse Width="190" Height="190" Canvas.Left="15" Canvas.Top="15" Stroke="#3A73909A" StrokeThickness="28"/><Ellipse Width="134" Height="134" Canvas.Left="43" Canvas.Top="43" Stroke="#4273909A" StrokeThickness="22"/><Path x:Name="PrimaryArc" Stroke="#2E6BFF" StrokeThickness="28" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Path x:Name="SecondaryArc" Stroke="#9B6EFF" StrokeThickness="22" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><TextBlock Text="5h" Canvas.Left="72" Canvas.Top="90" FontSize="15" FontWeight="Black" Foreground="#1487FF"/><TextBlock x:Name="PrimaryPercent" Text="--%" Canvas.Left="102" Canvas.Top="82" FontSize="24" FontWeight="Black" Foreground="#03090E"/><TextBlock Text="7d" Canvas.Left="72" Canvas.Top="124" FontSize="15" FontWeight="Black" Foreground="#8964FF"/><TextBlock x:Name="SecondaryPercent" Text="--%" Canvas.Left="102" Canvas.Top="116" FontSize="24" FontWeight="Black" Foreground="#03090E"/><TextBlock x:Name="RemainingLabel" Text="剩余" Canvas.Left="101" Canvas.Top="153" FontSize="15" FontWeight="Bold" Foreground="#1E333E"/></Canvas><Grid Margin="16,254,18,0" VerticalAlignment="Top"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="82"/></Grid.ColumnDefinitions><StackPanel><TextBlock x:Name="PrimaryResetLabel" Text="●  5h  重置" Foreground="#2665FF" FontSize="14" FontWeight="Bold"/><TextBlock x:Name="SecondaryResetLabel" Text="●  7d  重置" Foreground="#8D63FF" FontSize="14" FontWeight="Bold" Margin="0,12,0,0"/></StackPanel><StackPanel Grid.Column="1"><TextBlock x:Name="PrimaryReset" Text="--" FontSize="14" FontWeight="Bold" Foreground="#18313E" HorizontalAlignment="Right"/><TextBlock x:Name="SecondaryReset" Text="--" FontSize="14" FontWeight="Bold" Foreground="#18313E" HorizontalAlignment="Right" Margin="0,12,0,0"/></StackPanel></Grid></Grid><Grid Grid.Column="1" Margin="20,0,0,0"><Grid.RowDefinitions><RowDefinition Height="178"/><RowDefinition Height="124"/></Grid.RowDefinitions><Grid Grid.Row="0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
<Border Grid.Column="0" Margin="0,0,16,0" CornerRadius="12" Background="#DCEBF3F7" Padding="14"><Grid><TextBlock x:Name="TodayTitle" Text="☀  今日" FontSize="17" FontWeight="Bold" Foreground="#58666F"/><TextBlock x:Name="TodayCost" Text="$--" FontSize="16" FontWeight="Black" Foreground="#4A5962" HorizontalAlignment="Right"/><TextBlock x:Name="TodayTokens" Text="--" FontSize="32" FontWeight="Black" Foreground="#03090E" Margin="0,32,0,0"/><Border Margin="0,70,0,0" Height="12" CornerRadius="6" Background="#C5CDD6D9" VerticalAlignment="Top"><Grid><Border x:Name="TodayBarInput" Background="#0D8BFF" CornerRadius="6" HorizontalAlignment="Left" Width="28"/><Border x:Name="TodayBarCached" Background="#875EFF" CornerRadius="0" HorizontalAlignment="Left" Margin="28,0,0,0" Width="188"/><Border x:Name="TodayBarOut" Background="#FF9F0A" CornerRadius="0,6,6,0" HorizontalAlignment="Right" Width="6"/></Grid></Border><StackPanel x:Name="TodaySplit" Margin="0,84,0,0"/></Grid></Border>
<Border Grid.Column="1" Margin="0,0,16,0" CornerRadius="12" Background="#DCEBF3F7" Padding="14"><Grid><TextBlock x:Name="SevenTitle" Text="▦  近 7 天" FontSize="17" FontWeight="Bold" Foreground="#58666F"/><TextBlock x:Name="SevenCost" Text="$--" FontSize="16" FontWeight="Black" Foreground="#4A5962" HorizontalAlignment="Right"/><TextBlock x:Name="SevenTokens" Text="--" FontSize="32" FontWeight="Black" Foreground="#03090E" Margin="0,32,0,0"/><Border Margin="0,70,0,0" Height="12" CornerRadius="6" Background="#C5CDD6D9" VerticalAlignment="Top"><Grid><Border x:Name="SevenBarInput" Background="#0D8BFF" CornerRadius="6" HorizontalAlignment="Left" Width="28"/><Border x:Name="SevenBarCached" Background="#875EFF" CornerRadius="0" HorizontalAlignment="Left" Margin="28,0,0,0" Width="188"/><Border x:Name="SevenBarOut" Background="#FF9F0A" CornerRadius="0,6,6,0" HorizontalAlignment="Right" Width="6"/></Grid></Border><StackPanel x:Name="SevenSplit" Margin="0,84,0,0"/></Grid></Border>
<Border Grid.Column="2" CornerRadius="12" Background="#DCEBF3F7" Padding="14"><Grid><TextBlock x:Name="LifeTitle" Text="Σ  累计" FontSize="17" FontWeight="Bold" Foreground="#58666F"/><TextBlock x:Name="LifeCost" Text="$--" FontSize="16" FontWeight="Black" Foreground="#4A5962" HorizontalAlignment="Right"/><TextBlock x:Name="LifeTokens" Text="--" FontSize="32" FontWeight="Black" Foreground="#03090E" Margin="0,32,0,0"/><Border Margin="0,70,0,0" Height="12" CornerRadius="6" Background="#C5CDD6D9" VerticalAlignment="Top"><Grid><Border x:Name="LifeBarInput" Background="#0D8BFF" CornerRadius="6" HorizontalAlignment="Left" Width="28"/><Border x:Name="LifeBarCached" Background="#875EFF" CornerRadius="0" HorizontalAlignment="Left" Margin="28,0,0,0" Width="188"/><Border x:Name="LifeBarOut" Background="#FF9F0A" CornerRadius="0,6,6,0" HorizontalAlignment="Right" Width="6"/></Grid></Border><StackPanel x:Name="LifeSplit" Margin="0,84,0,0"/></Grid></Border>
</Grid><Border Grid.Row="1" CornerRadius="12" Background="#DCEBF3F7" Padding="14" Margin="0,12,0,0"><Grid><Grid.RowDefinitions><RowDefinition Height="30"/><RowDefinition Height="36"/><RowDefinition Height="24"/></Grid.RowDefinitions><Grid Grid.Row="0"><TextBlock x:Name="ValueTitle" Text="⌁  羊毛进度" FontSize="18" FontWeight="Black" Foreground="#03090E"/><TextBlock x:Name="ValueText" Text="$--" FontSize="24" FontWeight="Black" Foreground="#03090E" HorizontalAlignment="Right"/></Grid><Border x:Name="ValueTrack" Grid.Row="1" Height="16" CornerRadius="8" Background="#B8C8D1D6" VerticalAlignment="Center"><Grid ClipToBounds="False"><Border x:Name="ValueBar" Width="45" Height="16" HorizontalAlignment="Left" Background="#168DFF" CornerRadius="8"/><Ellipse x:Name="ValueMarkerPlus" Width="8" Height="8" Fill="#168DFF" Stroke="#DCEBF3F7" StrokeThickness="1.5" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="68,0,0,0"/><Ellipse x:Name="ValueMarkerPro100" Width="8" Height="8" Fill="#875EFF" Stroke="#DCEBF3F7" StrokeThickness="1.5" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="356,0,0,0"/><Ellipse x:Name="ValueMarkerPro200" Width="8" Height="8" Fill="#6F95FF" Stroke="#DCEBF3F7" StrokeThickness="1.5" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="716,0,0,0"/></Grid></Border><StackPanel x:Name="ValueLegendRow" Grid.Row="2" Orientation="Horizontal" VerticalAlignment="Center"><StackPanel Orientation="Horizontal" Margin="0,0,18,0"><Ellipse Width="6" Height="6" Fill="#168DFF" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="Plus" Foreground="#53616A" FontWeight="Black" FontSize="12.5"/><TextBlock Text=" $20" Foreground="#6B7881" FontWeight="Bold" FontSize="12.5"/></StackPanel><StackPanel Orientation="Horizontal" Margin="0,0,18,0"><Ellipse Width="6" Height="6" Fill="#875EFF" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="Pro100" Foreground="#53616A" FontWeight="Black" FontSize="12.5"/><TextBlock Text=" $100" Foreground="#6B7881" FontWeight="Bold" FontSize="12.5"/></StackPanel><StackPanel Orientation="Horizontal"><Ellipse Width="6" Height="6" Fill="#6F95FF" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="Pro200" Foreground="#53616A" FontWeight="Black" FontSize="12.5"/><TextBlock Text=" $200" Foreground="#6B7881" FontWeight="Bold" FontSize="12.5"/></StackPanel></StackPanel><TextBlock x:Name="FullQuotaText" Grid.Row="2" Text="下一档 Plus $20" Foreground="#53616A" FontWeight="Bold" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid></Border></Grid></Grid></Border>
<Border Grid.Row="2" Margin="0,16,0,0" CornerRadius="24" Background="#50D2E9F1" Padding="16" BorderBrush="#35FFFFFF" BorderThickness="1"><Grid><Grid.RowDefinitions><RowDefinition Height="42"/><RowDefinition Height="*"/></Grid.RowDefinitions><Grid><TextBlock x:Name="BoardTitle" Text="今日任务看板" FontSize="20" FontWeight="Black" Foreground="#061018" VerticalAlignment="Center"/><TextBlock x:Name="BoardMeta" Text="-- 事项 · --" FontSize="15" FontWeight="Bold" Foreground="#18313E" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid><Grid Grid.Row="1"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><Border Grid.Column="0" Margin="0,0,12,0" CornerRadius="14" Background="#2FFFBD42" BorderBrush="#4CFFBD42" BorderThickness="1" Padding="12"><DockPanel><TextBlock x:Name="ActiveHeader" DockPanel.Dock="Top" Text="⦿  进行中  3                         ⋯" FontSize="16" FontWeight="Black" Foreground="#061018" Margin="0,0,0,12"/><ScrollViewer VerticalScrollBarVisibility="Hidden"><StackPanel x:Name="ActiveList"/></ScrollViewer></DockPanel></Border><Border Grid.Column="1" Margin="0,0,12,0" CornerRadius="14" Background="#22C7D2D8" BorderBrush="#35C7D2D8" BorderThickness="1" Padding="12"><DockPanel><TextBlock x:Name="PendingHeader" DockPanel.Dock="Top" Text="○  待处理  2                         ⋯" FontSize="16" FontWeight="Black" Foreground="#061018" Margin="0,0,0,12"/><ScrollViewer VerticalScrollBarVisibility="Hidden"><StackPanel x:Name="PendingList"/></ScrollViewer></DockPanel></Border><Border Grid.Column="2" Margin="0,0,12,0" CornerRadius="14" Background="#258B6DFF" BorderBrush="#458B6DFF" BorderThickness="1" Padding="12"><DockPanel><TextBlock x:Name="ScheduledHeader" DockPanel.Dock="Top" Text="◴  定时  1                         ⋯" FontSize="16" FontWeight="Black" Foreground="#061018" Margin="0,0,0,12"/><ScrollViewer VerticalScrollBarVisibility="Hidden"><StackPanel x:Name="ScheduledList"/></ScrollViewer></DockPanel></Border><Border Grid.Column="3" CornerRadius="14" Background="#2634C759" BorderBrush="#4434C759" BorderThickness="1" Padding="12"><DockPanel><TextBlock x:Name="DoneHeader" DockPanel.Dock="Top" Text="●  完成  0                         ⋯" FontSize="16" FontWeight="Black" Foreground="#061018" Margin="0,0,0,12"/><Grid><TextBlock x:Name="EmptyDoneText" Text="◌&#x0a;暂无" FontSize="16" FontWeight="Bold" Foreground="#55708089" TextAlignment="Center" HorizontalAlignment="Center" VerticalAlignment="Center"/></Grid></DockPanel></Border></Grid></Grid></Border><StackPanel x:Name="FooterCluster" Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,34,-4"><Border x:Name="AutoRefreshToggle" Cursor="Hand" CornerRadius="9" Background="#168DFF" Padding="8,2" Margin="0,0,12,0"><TextBlock x:Name="AutoRefreshText" Text="自动 5m" Foreground="#FFFFFF" FontSize="13" FontWeight="Black"/></Border><TextBlock x:Name="FooterText" Text="刷新 --   ⌘W" Foreground="#102A38" FontSize="15" FontWeight="Black"/></StackPanel></Grid></Border></Grid>
</Window>
'@


function Send-WindowToBottom {
    if (-not $Script:Window -or -not $Script:KeepOnDesktopBottom) { return }
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($Script:Window)
        if ($helper.Handle -ne [IntPtr]::Zero) {
            [void][CodexUNativeWindow]::SetWindowPos($helper.Handle, [CodexUNativeWindow]::HWND_BOTTOM, 0, 0, 0, 0, [CodexUNativeWindow]::SWP_NOMOVE -bor [CodexUNativeWindow]::SWP_NOSIZE -bor [CodexUNativeWindow]::SWP_NOACTIVATE)
        }
    } catch {}
}

function Show-MainWindow { if ($Script:Window) { Close-TrayMenu; $Script:Window.Show(); $Script:Window.WindowState = [Windows.WindowState]::Normal; Send-WindowToBottom } }
function Hide-ToTray { if ($Script:Window) { Save-WindowPlacement; Close-TrayMenu; $Script:Window.Hide() } }
function Set-Text($Name, [string]$Value) {
    $el = Find $Name
    if ($el) { try { $el.Text = $Value } catch {} }
}
function Set-Brush($Name, [string]$Property, [string]$Color) {
    $el = Find $Name
    if ($el) { try { $el.$Property = New-Brush $Color } catch {} }
}
function Get-UiText([string]$Zh, [string]$En) {
    if ($Script:Language -eq 'en') { return $En }
    return $Zh
}
function Set-SegmentVisual($SegmentName, $TextName, [bool]$Active) {
    if ($Active) {
        Set-Brush $SegmentName 'Background' '#168DFF'
        Set-Brush $TextName 'Foreground' '#FFFFFF'
    } else {
        Set-Brush $SegmentName 'Background' '#00000000'
        Set-Brush $TextName 'Foreground' '#102A38'
    }
}
function Set-AutoRefreshVisual {
    Set-Text 'AutoRefreshText' (Get-UiText '自动 5m' 'Auto 5m')
    if ($Script:AutoRefreshEnabled) {
        Set-Brush 'AutoRefreshToggle' 'Background' '#168DFF'
        Set-Brush 'AutoRefreshText' 'Foreground' '#FFFFFF'
    } else {
        Set-Brush 'AutoRefreshToggle' 'Background' '#45D5E5EB'
        Set-Brush 'AutoRefreshText' 'Foreground' '#536A78'
    }
}
function Apply-Theme {
    $shellColor = '#C38AAEBC'
    $themeBg = '#50485561'
    if ($Script:ThemeMode -eq 'light') {
        $shellColor = '#D5D9EEF4'
        $themeBg = '#5889AFC2'
    } elseif ($Script:ThemeMode -eq 'dark') {
        $shellColor = '#C0476270'
        $themeBg = '#60404A57'
    }
    $root = Find 'RootShell'
    if ($root) { $root.Background = New-Brush $shellColor }
    $switch = Find 'ThemeSwitch'
    if ($switch) { $switch.Background = New-Brush $themeBg }
    Set-SegmentVisual 'ThemeAutoSegment' 'ThemeAutoText' ($Script:ThemeMode -eq 'auto')
    Set-SegmentVisual 'ThemeLightSegment' 'ThemeLightText' ($Script:ThemeMode -eq 'light')
    Set-SegmentVisual 'ThemeDarkSegment' 'ThemeDarkText' ($Script:ThemeMode -eq 'dark')
}
function Set-ThemeMode([string]$Mode) {
    $Script:ThemeMode = $Mode
    Apply-Theme
    Send-WindowToBottom
}
function Toggle-Theme {
    if ($Script:ThemeMode -eq 'auto') { Set-ThemeMode 'light' }
    elseif ($Script:ThemeMode -eq 'light') { Set-ThemeMode 'dark' }
    else { Set-ThemeMode 'auto' }
}
function Apply-Language {
    Set-SegmentVisual 'LangZhSegment' 'LangZhText' ($Script:Language -eq 'zh')
    Set-SegmentVisual 'LangEnSegment' 'LangEnText' ($Script:Language -eq 'en')
    Set-Text 'PlanText' $Script:PlanLabel
    Set-Text 'RemainingLabel' (Get-UiText '剩余' 'Remaining')
    Set-Text 'PrimaryResetLabel' (Get-UiText '●  5h  重置' '●  5h  Reset')
    Set-Text 'SecondaryResetLabel' (Get-UiText '●  7d  重置' '●  7d  Reset')
    Set-Text 'TodayTitle' (Get-UiText '☀  今日' '☀  Today')
    Set-Text 'SevenTitle' (Get-UiText '▦  近 7 天' '▦  7 Days')
    Set-Text 'LifeTitle' (Get-UiText 'Σ  累计' 'Σ  Total')
    Set-Text 'ValueTitle' (Get-UiText '⌁  羊毛进度' '⌁  Value Progress')
    Set-Text 'FullQuotaText' (Get-UiText '下一档 Plus $20' 'Next Plus $20')
    Set-Text 'BoardTitle' (Get-UiText '今日任务看板' 'Today Board')
    Set-Text 'ActiveHeader' (Get-UiText '⦿  进行中  3                         ⋯' '⦿  Active  3                         ⋯')
    Set-Text 'PendingHeader' (Get-UiText '○  待处理  2                         ⋯' '○  Pending  2                        ⋯')
    Set-Text 'ScheduledHeader' (Get-UiText '◴  定时  1                         ⋯' '◴  Scheduled  1                      ⋯')
    Set-Text 'DoneHeader' (Get-UiText '●  完成  0                         ⋯' '●  Done  0                           ⋯')
    Set-Text 'EmptyDoneText' ('◌' + [Environment]::NewLine + (Get-UiText '暂无' 'Empty'))
    Set-Text 'BoardMeta' ('--' + (Get-UiText ' 事项 · ' ' items · ') + '--')
    Set-Text 'FooterText' ((Get-UiText '刷新 ' 'Refresh ') + '--   ⌘W')
    Set-AutoRefreshVisual
    Apply-Theme
}
function Set-Language([string]$Language) {
    $Script:Language = $Language
    Apply-Language
    Update-Ui
    Send-WindowToBottom
}
function Toggle-Language {
    if ($Script:Language -eq 'zh') { Set-Language 'en' } else { Set-Language 'zh' }
}
function Test-CodexRunning {
    try {
        return ($null -ne (Get-Process -Name 'Codex','codex','OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1))
    } catch { return $false }
}
function Invoke-AutoRefreshTick {
    if (-not $Script:AutoRefreshEnabled) { return }
    if (Test-CodexRunning) { Update-Ui }
}
function Start-AutoRefreshTimer {
    if (-not $Script:AutoRefreshTimer) {
        $Script:AutoRefreshTimer = [Windows.Threading.DispatcherTimer]::new()
        $Script:AutoRefreshTimer.Interval = [TimeSpan]::FromMinutes($Script:AutoRefreshMinutes)
        $Script:AutoRefreshTimer.Add_Tick({ Invoke-AutoRefreshTick })
    }
    if ($Script:AutoRefreshEnabled -and -not $Script:AutoRefreshTimer.IsEnabled) { $Script:AutoRefreshTimer.Start() }
}
function Stop-AutoRefreshTimer {
    if ($Script:AutoRefreshTimer -and $Script:AutoRefreshTimer.IsEnabled) { $Script:AutoRefreshTimer.Stop() }
}
function Set-AutoRefreshEnabled([bool]$Enabled) {
    $Script:AutoRefreshEnabled = $Enabled
    if ($Enabled) { Start-AutoRefreshTimer } else { Stop-AutoRefreshTimer }
    Set-AutoRefreshVisual
}
function Toggle-AutoRefresh { Set-AutoRefreshEnabled (-not $Script:AutoRefreshEnabled) }
function Get-LegacyStartupCommand {
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $powershell)) { $powershell = 'powershell.exe' }
    return ('"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "{1}"' -f $powershell, $Script:SelfPath)
}
function Get-StartupLauncherPath { Join-Path $Script:SettingsDir 'Start-CodexW-hidden.vbs' }
function Update-StartupLauncher {
    if (-not (Test-Path $Script:SettingsDir)) { New-Item -ItemType Directory -Path $Script:SettingsDir -Force | Out-Null }
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $powershell)) { $powershell = 'powershell.exe' }
    $launcher = Get-StartupLauncherPath
    $workDir = ($Script:AppRoot -replace '"', '""')
    $psPath = ($powershell -replace '"', '""')
    $scriptPath = ($Script:SelfPath -replace '"', '""')
    $lines = @(
        'Set sh = CreateObject("WScript.Shell")',
        ('sh.CurrentDirectory = "{0}"' -f $workDir),
        ('sh.Run """{0}"" -NoProfile -ExecutionPolicy Bypass -STA -File ""{1}""", 0, False' -f $psPath, $scriptPath)
    )
    Set-Content -LiteralPath $launcher -Value $lines -Encoding ASCII
    return $launcher
}
function Get-StartupCommand {
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    if (-not (Test-Path $wscript)) { $wscript = 'wscript.exe' }
    return ('"{0}" "{1}"' -f $wscript, (Update-StartupLauncher))
}
function Get-StartupEnabled {
    try {
        $props = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $Script:StartupRunName -ErrorAction Stop
        $current = [string]$props.($Script:StartupRunName)
        return ($current -eq (Get-StartupCommand) -or $current -eq (Get-LegacyStartupCommand) -or $current -like '*CodexW.ps1*')
    } catch { return $false }
}
function Set-StartupEnabled([bool]$Enabled) {
    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if ($Enabled) {
        New-ItemProperty -Path $runPath -Name $Script:StartupRunName -Value (Get-StartupCommand) -PropertyType String -Force | Out-Null
    } else {
        Remove-ItemProperty -Path $runPath -Name $Script:StartupRunName -ErrorAction SilentlyContinue
    }
}
function Repair-StartupCommand {
    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    try {
        $props = Get-ItemProperty -Path $runPath -Name $Script:StartupRunName -ErrorAction Stop
        $current = [string]$props.($Script:StartupRunName)
        $target = Get-StartupCommand
        if ($current -ne $target -and ($current -eq (Get-LegacyStartupCommand) -or $current -like '*CodexW.ps1*')) {
            New-ItemProperty -Path $runPath -Name $Script:StartupRunName -Value $target -PropertyType String -Force | Out-Null
        }
    } catch {}
}
function Get-AppSettingsMap {
    $map = [ordered]@{}
    if (Test-Path $Script:SettingsPath) {
        try {
            $obj = Get-Content -Raw -LiteralPath $Script:SettingsPath | ConvertFrom-Json
            foreach ($prop in $obj.PSObject.Properties) { $map[$prop.Name] = $prop.Value }
        } catch {}
    }
    return $map
}
function Save-AppSettings($Map) {
    try {
        if (-not (Test-Path $Script:SettingsDir)) { New-Item -ItemType Directory -Path $Script:SettingsDir -Force | Out-Null }
        $Map | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Script:SettingsPath -Encoding UTF8
    } catch {}
}
function Test-WindowPlacementVisible([double]$Left, [double]$Top, [double]$Width, [double]$Height) {
    if ($Width -le 80 -or $Height -le 80) { return $false }
    $right = $Left + $Width
    $bottom = $Top + $Height
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $area = $screen.WorkingArea
        $visibleWidth = [Math]::Max(0, [Math]::Min($right, $area.Right) - [Math]::Max($Left, $area.Left))
        $visibleHeight = [Math]::Max(0, [Math]::Min($bottom, $area.Bottom) - [Math]::Max($Top, $area.Top))
        if ($visibleWidth -ge 160 -and $visibleHeight -ge 120) { return $true }
    }
    return $false
}
function Restore-WindowPlacement {
    if (-not $Script:Window) { return }
    $settings = Get-AppSettingsMap
    if (-not $settings.Contains('window')) { return }
    try {
        $win = $settings['window']
        $left = [double]$win.left
        $top = [double]$win.top
        $width = [double]$win.width
        $height = [double]$win.height
        if (Test-WindowPlacementVisible $left $top $width $height) {
            $Script:Window.WindowStartupLocation = [Windows.WindowStartupLocation]::Manual
            $Script:Window.Left = $left
            $Script:Window.Top = $top
        }
    } catch {}
}
function Save-WindowPlacement {
    if (-not $Script:Window -or $Script:Window.WindowState -ne [Windows.WindowState]::Normal) { return }
    try {
        if ([double]::IsNaN($Script:Window.Left) -or [double]::IsNaN($Script:Window.Top)) { return }
        $settings = Get-AppSettingsMap
        $settings['window'] = [ordered]@{
            left = [Math]::Round([double]$Script:Window.Left, 2)
            top = [Math]::Round([double]$Script:Window.Top, 2)
            width = [Math]::Round([double]$Script:Window.Width, 2)
            height = [Math]::Round([double]$Script:Window.Height, 2)
        }
        Save-AppSettings $settings
    } catch {}
}
function Queue-WindowPlacementSave {
    if (-not $Script:PositionSaveTimer) {
        $Script:PositionSaveTimer = [Windows.Threading.DispatcherTimer]::new()
        $Script:PositionSaveTimer.Interval = [TimeSpan]::FromMilliseconds(700)
        $Script:PositionSaveTimer.Add_Tick({ $Script:PositionSaveTimer.Stop(); Save-WindowPlacement })
    }
    if ($Script:PositionSaveTimer.IsEnabled) { $Script:PositionSaveTimer.Stop() }
    $Script:PositionSaveTimer.Start()
}
function Toggle-TrayWindow { if ($Script:Window -and $Script:Window.IsVisible) { Hide-ToTray } else { Show-MainWindow } }
function Close-TrayMenu {
    $menu = $Script:TrayMenuWindow
    if (-not $menu) { return }
    $Script:TrayMenuWindow = $null
    try { $menu.Close() } catch {}
}
function Dispose-TrayIcon { Close-TrayMenu; if ($Script:TrayNotify) { $Script:TrayNotify.Visible = $false; $Script:TrayNotify.Dispose(); $Script:TrayNotify = $null }; if ($Script:TrayIcon) { $Script:TrayIcon.Dispose(); $Script:TrayIcon = $null }; if ($Script:TrayBitmap) { $Script:TrayBitmap.Dispose(); $Script:TrayBitmap = $null } }
function Quit-CodexW {
    if ($Script:IsQuitting) { return }
    $Script:IsQuitting = $true
    $Script:AllowExit = $true
    try { Save-WindowPlacement } catch {}
    try { Stop-AutoRefreshTimer } catch {}
    $shutdown = {
        try {
            Close-TrayMenu
            if ($Script:Window) {
                try { $Script:Window.Close() } catch {}
            }
            Dispose-TrayIcon
            $app = [Windows.Application]::Current
            if ($app) { $app.Shutdown(0) }
        } catch {
            try { Dispose-TrayIcon } catch {}
            [Environment]::Exit(0)
        }
    }
    try {
        if ($Script:Window -and $Script:Window.Dispatcher) {
            [void]$Script:Window.Dispatcher.BeginInvoke([Action]$shutdown, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
        } else {
            & $shutdown
        }
    } catch {
        & $shutdown
    }
}
function Invoke-TrayMenuAction([scriptblock]$Action) {
    try {
        Close-TrayMenu
        if ($Action) { & $Action }
    } catch {
        try {
            [System.Windows.Forms.MessageBox]::Show(('菜单操作失败：' + $_.Exception.Message), 'CodexW', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        } catch {}
    }
}
function Convert-ScreenPointToDip([System.Drawing.Point]$Point) {
    $dip = [Windows.Point]::new([double]$Point.X, [double]$Point.Y)
    try {
        $source = [Windows.PresentationSource]::FromVisual($Script:Window)
        if ($source -and $source.CompositionTarget) {
            return $source.CompositionTarget.TransformFromDevice.Transform($dip)
        }
    } catch {}
    try {
        $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        try { return [Windows.Point]::new($dip.X / ($g.DpiX / 96.0), $dip.Y / ($g.DpiY / 96.0)) } finally { $g.Dispose() }
    } catch {}
    return $dip
}
function New-TrayMenuRow([string]$Label, [string]$Glyph, [bool]$Checked, [scriptblock]$Action, [bool]$Danger = $false) {
    $boundAction = if ($Action) { $Action.GetNewClosure() } else { $null }
    $row = [Windows.Controls.Border]::new()
    $row.Height = 34
    $row.Margin = [Windows.Thickness]::new(0, 1, 0, 1)
    $row.Padding = [Windows.Thickness]::new(7, 0, 7, 0)
    $row.CornerRadius = [Windows.CornerRadius]::new(9)
    $row.Background = New-Brush '#00FFFFFF'
    $row.Cursor = [Windows.Input.Cursors]::Hand
    $grid = [Windows.Controls.Grid]::new()
    $iconCol = [Windows.Controls.ColumnDefinition]::new(); $iconCol.Width = [Windows.GridLength]::new(18); $grid.ColumnDefinitions.Add($iconCol) | Out-Null
    $labelCol = [Windows.Controls.ColumnDefinition]::new(); $labelCol.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star); $grid.ColumnDefinitions.Add($labelCol) | Out-Null
    $checkCol = [Windows.Controls.ColumnDefinition]::new(); $checkCol.Width = [Windows.GridLength]::new(16); $grid.ColumnDefinitions.Add($checkCol) | Out-Null
    $icon = [Windows.Controls.TextBlock]::new()
    $icon.Text = $Glyph
    $icon.Width = 18
    $icon.FontSize = 14
    $icon.FontWeight = 'Black'
    $icon.Foreground = New-Brush ($(if ($Danger) { '#D94A54' } else { '#51616C' }))
    $icon.VerticalAlignment = 'Center'
    $text = [Windows.Controls.TextBlock]::new()
    $text.Text = $Label
    $text.FontSize = 13.5
    $text.FontWeight = 'Bold'
    $text.Foreground = New-Brush ($(if ($Danger) { '#B9313B' } else { '#102A38' }))
    $text.VerticalAlignment = 'Center'
    $text.TextTrimming = [Windows.TextTrimming]::None
    [Windows.Controls.Grid]::SetColumn($text, 1)
    $check = [Windows.Controls.TextBlock]::new()
    $check.Text = $(if ($Checked) { '●' } else { '' })
    $check.Width = 16
    $check.FontSize = 13
    $check.FontWeight = 'Black'
    $check.Foreground = New-Brush '#168DFF'
    $check.HorizontalAlignment = 'Right'
    $check.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($check, 2)
    $grid.Children.Add($icon) | Out-Null
    $grid.Children.Add($text) | Out-Null
    $grid.Children.Add($check) | Out-Null
    $row.Child = $grid
    $row.Add_MouseEnter({ param($sender,$e) $sender.Background = New-Brush '#66D5E5EB' })
    $row.Add_MouseLeave({ param($sender,$e) $sender.Background = New-Brush '#00FFFFFF' })
    $row.Add_MouseLeftButtonUp({ param($sender,$e) $e.Handled = $true; Invoke-TrayMenuAction $boundAction }.GetNewClosure())
    return $row
}
function Show-TrayMenu([System.Drawing.Point]$ScreenPoint = [System.Windows.Forms.Control]::MousePosition) {
    Close-TrayMenu
    if ($null -eq $ScreenPoint) { $ScreenPoint = [System.Windows.Forms.Control]::MousePosition }
    $menu = [Windows.Window]::new()
    $menu.Width = 188
    $menu.SizeToContent = [Windows.SizeToContent]::Height
    $menu.WindowStyle = [Windows.WindowStyle]::None
    $menu.ResizeMode = [Windows.ResizeMode]::NoResize
    $menu.AllowsTransparency = $true
    $menu.Background = [Windows.Media.Brushes]::Transparent
    $menu.ShowInTaskbar = $false
    $menu.Topmost = $true
    $menu.FontFamily = $Script:Window.FontFamily
    $shell = [Windows.Controls.Border]::new()
    $shell.CornerRadius = [Windows.CornerRadius]::new(16)
    $shell.Padding = [Windows.Thickness]::new(7)
    $shell.Background = New-Brush '#E6A8C5D2'
    $shell.BorderBrush = New-Brush '#70FFFFFF'
    $shell.BorderThickness = [Windows.Thickness]::new(1)
    $shadow = [Windows.Media.Effects.DropShadowEffect]::new()
    $shadow.BlurRadius = 22
    $shadow.ShadowDepth = 0
    $shadow.Opacity = 0.32
    $shadow.Color = [Windows.Media.ColorConverter]::ConvertFromString('#1E3744')
    $shell.Effect = $shadow
    $stack = [Windows.Controls.StackPanel]::new()
    $stack.Children.Add((New-TrayMenuRow (Get-UiText '显示 / 隐藏' 'Show / Hide') '◐' $false { Toggle-TrayWindow })) | Out-Null
    $stack.Children.Add((New-TrayMenuRow (Get-UiText '刷新' 'Refresh') '↻' $false { Show-MainWindow; Update-Ui })) | Out-Null
    $stack.Children.Add((New-TrayMenuRow (Get-UiText '贴在桌面底层' 'Keep On Desktop') '▾' $Script:KeepOnDesktopBottom { $Script:KeepOnDesktopBottom = -not $Script:KeepOnDesktopBottom; if ($Script:KeepOnDesktopBottom) { Send-WindowToBottom } })) | Out-Null
    $stack.Children.Add((New-TrayMenuRow (Get-UiText '开机自启动' 'Launch At Login') '⏻' (Get-StartupEnabled) {
        try { Set-StartupEnabled (-not (Get-StartupEnabled)) } catch { [System.Windows.Forms.MessageBox]::Show(('开机自启动设置失败：' + $_.Exception.Message), 'CodexW', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null }
    })) | Out-Null
    $line = [Windows.Controls.Border]::new()
    $line.Height = 1
    $line.Margin = [Windows.Thickness]::new(8, 7, 8, 7)
    $line.Background = New-Brush '#45FFFFFF'
    $stack.Children.Add($line) | Out-Null
    $stack.Children.Add((New-TrayMenuRow (Get-UiText '退出' 'Quit') '×' $false { Quit-CodexW } $true)) | Out-Null
    $shell.Child = $stack
    $menu.Content = $shell
    $point = Convert-ScreenPointToDip $ScreenPoint
    $vw = [System.Windows.SystemParameters]::VirtualScreenWidth
    $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
    $vl = [System.Windows.SystemParameters]::VirtualScreenLeft
    $vt = [System.Windows.SystemParameters]::VirtualScreenTop
    $shell.Measure([Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $menuHeight = [Math]::Max(1, $shell.DesiredSize.Height)
    $left = $point.X - 18
    if (($left + $menu.Width) -gt ($vl + $vw - 8)) { $left = $point.X - $menu.Width + 18 }
    $top = $point.Y + 10
    if (($top + $menuHeight) -gt ($vt + $vh - 8)) { $top = $point.Y - $menuHeight - 10 }
    $menu.Left = [Math]::Max($vl + 8, [Math]::Min($left, $vl + $vw - $menu.Width - 8))
    $menu.Top = [Math]::Max($vt + 8, [Math]::Min($top, $vt + $vh - $menuHeight - 8))
    $menu.Add_Deactivated({ Close-TrayMenu })
    $Script:TrayMenuWindow = $menu
    [void]$menu.Show()
    $menu.Activate() | Out-Null
}
function Initialize-TrayIcon {
    if ($Script:TrayNotify) { return }
    $notify = New-Object System.Windows.Forms.NotifyIcon
    if (Test-Path $Script:IconPng) {
        $Script:TrayBitmap = [System.Drawing.Bitmap]::FromFile($Script:IconPng)
        $Script:TrayIcon = [System.Drawing.Icon]::FromHandle($Script:TrayBitmap.GetHicon())
        $notify.Icon = $Script:TrayIcon
    } else {
        $notify.Icon = [System.Drawing.SystemIcons]::Application
    }
    $notify.Text = 'CodexW'
    $notify.Add_MouseUp({ param($sender,$e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { Show-TrayMenu ([System.Windows.Forms.Control]::MousePosition) } })
    $notify.Add_DoubleClick({ Toggle-TrayWindow })
    $notify.Visible = $true
    $Script:TrayNotify = $notify
}

function Load-Window {
    [xml]$xml = $xaml
    $reader = New-Object System.Xml.XmlNodeReader $xml
    $Script:Window = [Windows.Markup.XamlReader]::Load($reader)
    if (Test-Path $Script:IconPng) { (Find 'LogoImage').Source = [Windows.Media.Imaging.BitmapImage]::new([Uri]$Script:IconPng) }
    Restore-WindowPlacement
    Repair-StartupCommand
    Initialize-TrayIcon
    $Script:Window.Add_SourceInitialized({ Send-WindowToBottom })
    $Script:Window.Add_ContentRendered({ Update-Ui; Send-WindowToBottom })
    $Script:Window.Add_LocationChanged({ if ($Script:Window -and $Script:Window.IsVisible -and $Script:Window.WindowState -eq [Windows.WindowState]::Normal) { Queue-WindowPlacementSave } })
    $Script:Window.Add_MouseLeftButtonDown({ try { Close-TrayMenu; $Script:Window.DragMove() } catch {} })
    (Find 'CloseButton').Add_Click({ Hide-ToTray })
    (Find 'RefreshButton').Add_Click({ Update-Ui })
    (Find 'AutoRefreshToggle').Add_PreviewMouseLeftButtonDown({ param($sender,$e) $e.Handled = $true; Toggle-AutoRefresh })
    (Find 'ThemeAutoSegment').Add_PreviewMouseLeftButtonDown({ param($sender,$e) $e.Handled = $true; Set-ThemeMode 'auto' })
    (Find 'ThemeLightSegment').Add_PreviewMouseLeftButtonDown({ param($sender,$e) $e.Handled = $true; Set-ThemeMode 'light' })
    (Find 'ThemeDarkSegment').Add_PreviewMouseLeftButtonDown({ param($sender,$e) $e.Handled = $true; Set-ThemeMode 'dark' })
    (Find 'LangZhSegment').Add_PreviewMouseLeftButtonDown({ param($sender,$e) $e.Handled = $true; Set-Language 'zh' })
    (Find 'LangEnSegment').Add_PreviewMouseLeftButtonDown({ param($sender,$e) $e.Handled = $true; Set-Language 'en' })
    Set-Text 'PlanText' $Script:PlanLabel
    Apply-Language
    Start-AutoRefreshTimer
    $Script:Window.Add_StateChanged({ if ($Script:Window.WindowState -eq [Windows.WindowState]::Minimized) { Hide-ToTray } })
    $Script:Window.Add_Closing({
        if (-not $Script:AllowExit) {
            $_.Cancel = $true
            Hide-ToTray
        } else {
            Save-WindowPlacement
            Stop-AutoRefreshTimer
            Dispose-TrayIcon
        }
    })
}
function Add-SplitRow($Panel, [string]$DotColor, [string]$Label, [string]$Value) {
    $row=[Windows.Controls.Grid]::new(); $row.Height=21
    $row.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())|Out-Null
    $valueCol=[Windows.Controls.ColumnDefinition]::new(); $valueCol.Width=[Windows.GridLength]::new(72); $row.ColumnDefinitions.Add($valueCol)|Out-Null
    $left=[Windows.Controls.StackPanel]::new(); $left.Orientation='Horizontal'
    $dot=[Windows.Controls.TextBlock]::new(); $dot.Text='●'; $dot.Foreground=New-Brush $DotColor; $dot.FontSize=12.5; $dot.FontWeight='Bold'; $dot.VerticalAlignment='Center'; $dot.Margin=[Windows.Thickness]::new(0,0,7,0)
    $name=[Windows.Controls.TextBlock]::new(); $name.Text=$Label; $name.Foreground=New-Brush '#53616A'; $name.FontSize=12.5; $name.FontWeight='Bold'; $name.VerticalAlignment='Center'
    $left.Children.Add($dot)|Out-Null; $left.Children.Add($name)|Out-Null
    $num=[Windows.Controls.TextBlock]::new(); $num.Text=$Value; $num.Foreground=New-Brush '#53616A'; $num.FontSize=12.5; $num.FontWeight='Bold'; $num.HorizontalAlignment='Right'; $num.TextAlignment='Right'; $num.VerticalAlignment='Center'
    [Windows.Controls.Grid]::SetColumn($num,1)
    $row.Children.Add($left)|Out-Null; $row.Children.Add($num)|Out-Null; $Panel.Children.Add($row)|Out-Null
}
function Set-SplitLine($Prefix, $Bucket) { $uncached=[Math]::Max(0,$Bucket.input-$Bucket.cached); $panel=Find ($Prefix+'Split'); $panel.Children.Clear(); Add-SplitRow $panel '#0D8BFF' (Get-UiText '未缓存' 'Uncached') (Format-TokenCount $uncached); Add-SplitRow $panel '#875EFF' (Get-UiText '缓存' 'Cached') (Format-TokenCount $Bucket.cached); Add-SplitRow $panel '#FF9F0A' (Get-UiText '输出' 'Output') (Format-TokenCount $Bucket.output); $total=[Math]::Max(1,$uncached+$Bucket.cached+$Bucket.output); $max=210.0; $inW=[Math]::Max(12,$max*$uncached/$total); $caW=[Math]::Max(18,$max*$Bucket.cached/$total); $outW=[Math]::Max(4,$max*$Bucket.output/$total); (Find ($Prefix+'BarInput')).Width=$inW; (Find ($Prefix+'BarCached')).Margin=[Windows.Thickness]::new($inW,0,0,0); (Find ($Prefix+'BarCached')).Width=$caW; (Find ($Prefix+'BarOut')).Width=$outW }
function Add-TaskCard($Panel,$Item,[string]$Accent,[string]$Chip,[string]$ChipBg){ $border=[Windows.Controls.Border]::new(); $border.Margin=[Windows.Thickness]::new(0,0,0,12); $border.Padding=[Windows.Thickness]::new(12); $border.CornerRadius=[Windows.CornerRadius]::new(10); $border.Background=New-Brush '#DDEBF0F4'; $border.BorderBrush=New-Brush '#70FFFFFF'; $border.BorderThickness=[Windows.Thickness]::new(1); $stack=[Windows.Controls.StackPanel]::new(); $border.Child=$stack; $top=[Windows.Controls.DockPanel]::new(); $code=[Windows.Controls.TextBlock]::new(); $code.Text=$Item.code; $code.FontWeight='Bold'; $code.FontSize=13; $code.Foreground=New-Brush '#65727B'; $time=[Windows.Controls.TextBlock]::new(); $time.Text=Get-RelativeText $Item.updatedAt; $time.FontSize=12; $time.Foreground=New-Brush '#89949A'; $time.HorizontalAlignment='Right'; [Windows.Controls.DockPanel]::SetDock($time,'Right'); $top.Children.Add($time)|Out-Null; $top.Children.Add($code)|Out-Null; $stack.Children.Add($top)|Out-Null; $title=[Windows.Controls.TextBlock]::new(); $title.Text=$Item.title; $title.FontWeight='Black'; $title.FontSize=14; $title.Foreground=New-Brush '#111820'; $title.Margin=[Windows.Thickness]::new(0,8,0,4); $stack.Children.Add($title)|Out-Null; $detail=[Windows.Controls.TextBlock]::new(); $detail.Text=$Item.detail; $detail.FontWeight='SemiBold'; $detail.FontSize=12.5; $detail.Foreground=New-Brush '#626B72'; $detail.Margin=[Windows.Thickness]::new(0,0,0,10); $stack.Children.Add($detail)|Out-Null; $chipBorder=[Windows.Controls.Border]::new(); $chipBorder.Background=New-Brush $ChipBg; $chipBorder.CornerRadius=[Windows.CornerRadius]::new(14); $chipBorder.Padding=[Windows.Thickness]::new(10,4,10,4); $chipBorder.HorizontalAlignment='Left'; $txt=[Windows.Controls.TextBlock]::new(); $txt.Text=$Chip; $txt.FontWeight='Black'; $txt.FontSize=12; $txt.Foreground=New-Brush $Accent; $chipBorder.Child=$txt; $stack.Children.Add($chipBorder)|Out-Null; $Panel.Children.Add($border)|Out-Null }
function Update-Ui { $s=Read-LocalSnapshot; $p=if($s.primary){[double]$s.primary.remainingPercent}else{0}; $q=if($s.secondary){[double]$s.secondary.remainingPercent}else{0}; (Find 'PrimaryArc').Data=New-ArcGeometry 110 110 80 -90 (360*$p/100); (Find 'SecondaryArc').Data=New-ArcGeometry 110 110 56 -90 (360*$q/100); (Find 'PrimaryPercent').Text=('{0:N0}%' -f $p); (Find 'SecondaryPercent').Text=('{0:N0}%' -f $q); (Find 'PrimaryReset').Text=Format-ResetTime $s.primary.resetsAt; (Find 'SecondaryReset').Text=Format-ResetTime $s.secondary.resetsAt; (Find 'TodayTokens').Text=Format-TokenCount $s.local.today.total; (Find 'TodayCost').Text=Format-Usd $s.local.today.cost; Set-SplitLine 'Today' $s.local.today; (Find 'SevenTokens').Text=Format-TokenCount $s.local.sevenDay.total; (Find 'SevenCost').Text=Format-Usd $s.local.sevenDay.cost; Set-SplitLine 'Seven' $s.local.sevenDay; (Find 'LifeTokens').Text=Format-TokenCount $s.local.lifetime.total; (Find 'LifeCost').Text=Format-Usd $s.local.lifetime.cost; Set-SplitLine 'Life' $s.local.lifetime; $valueAmount=[double]$s.local.month.cost; $trackElement=Find 'ValueTrack'; $valueTrack=if($trackElement -and $trackElement.ActualWidth -gt 20){[double]$trackElement.ActualWidth}else{720.0}; $plusLimit=20.0; $pro100Limit=100.0; $pro200Limit=200.0; (Find 'ValueText').Text=Format-Usd $valueAmount; $valueWidth=[Math]::Max(0,[Math]::Min($valueTrack,$valueTrack*$valueAmount/$pro200Limit)); (Find 'ValueBar').Width=$valueWidth; (Find 'ValueMarkerPlus').Margin=[Windows.Thickness]::new([Math]::Max(0,($valueTrack*$plusLimit/$pro200Limit)-4),0,0,0); (Find 'ValueMarkerPro100').Margin=[Windows.Thickness]::new([Math]::Max(0,($valueTrack*$pro100Limit/$pro200Limit)-4),0,0,0); (Find 'ValueMarkerPro200').Margin=[Windows.Thickness]::new([Math]::Max(0,$valueTrack-4),0,0,0); if($valueAmount -lt $plusLimit){(Find 'FullQuotaText').Text=Get-UiText '下一档 Plus $20' 'Next Plus $20'} elseif($valueAmount -lt $pro100Limit){(Find 'FullQuotaText').Text=Get-UiText '下一档 Pro100 $100' 'Next Pro100 $100'} elseif($valueAmount -lt $pro200Limit){(Find 'FullQuotaText').Text=Get-UiText '下一档 Pro200 $200' 'Next Pro200 $200'} else {(Find 'FullQuotaText').Text=Get-UiText '已超过 Pro200 $200' 'Past Pro200 $200'}; $active=Find 'ActiveList'; $pending=Find 'PendingList'; $scheduled=Find 'ScheduledList'; $active.Children.Clear(); $pending.Children.Clear(); $scheduled.Children.Clear(); $recent=@(Get-RecentTaskItems); for($i=0;$i -lt [Math]::Min(3,$recent.Count);$i++){Add-TaskCard $active $recent[$i] '#FF3B30' ($(if($i -eq 2){'Active'}else{'High'})) '#26FF3B30'}; for($i=3;$i -lt [Math]::Min(5,$recent.Count);$i++){Add-TaskCard $pending $recent[$i] '#FF9F0A' ($(if($i -eq 4){'Idle'}else{'Medium'})) '#26FF9F0A'}; $autos=@($s.automations|Where-Object{$_.status -eq 'ACTIVE'}); if($autos.Count -gt 0){Add-TaskCard $scheduled $autos[0] '#8B6DFF' 'Cron' '#268B6DFF'}; (Find 'BoardMeta').Text=([Math]::Min(6,$recent.Count+$autos.Count)).ToString()+(Get-UiText ' 事项 · ' ' items · ')+(Get-Date).ToString('HH:mm'); (Find 'FooterText').Text=(Get-UiText '刷新 ' 'Refresh ')+(Get-Date).ToString('HH:mm')+'   ⌘W'; Set-AutoRefreshVisual }
if ($DumpJson) { Read-LocalSnapshot | ConvertTo-Json -Depth 12; exit 0 }
Load-Window
Update-Ui
[void]$Script:Window.Show(); Send-WindowToBottom; $Script:App = [Windows.Application]::new(); $Script:App.Add_DispatcherUnhandledException({ param($sender,$e) $e.Handled = $true; try { [System.Windows.Forms.MessageBox]::Show(('CodexW 发生错误：' + $e.Exception.Message), 'CodexW', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null } catch {} }); [void]$Script:App.Run($Script:Window)
