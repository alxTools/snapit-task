# =====================================================================
#  SnapIt - Alt+Shift+S -> capture & annotate -> improved prompt ->
#           pick destination: (Terminal -> Hermes agent) or (DeepSeek ->
#           DSH Web UI prefill, not submitted).
#
#  Windows PowerShell 5.1 + WPF (color emoji). ASCII-only source: every
#  emoji is built at runtime from codepoints, so the file encoding is
#  never an issue on PS 5.1.
#
#  Usage:
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\snapit.ps1
#         -> stays in the tray, hotkey Alt+Shift+S arms the snipper
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\snapit.ps1 -Once
#         -> runs a single capture flow and exits (quick testing)
# =====================================================================
#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$Admin,
    [switch]$Focus
)
Set-StrictMode -Version 2.0

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------- native helpers
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class SnapitNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("gdi32.dll")]  public static extern bool DeleteObject(IntPtr hObject);
}

public sealed class SnapitHotkey : NativeWindow {
    public event EventHandler Pressed;
    private const int WM_HOTKEY = 0x0312;
    public int Id { get; private set; }

    public SnapitHotkey() {
        CreateParams cp = new CreateParams();
        cp.Caption = "SnapItHotkeyWindow";
        this.CreateHandle(cp);
    }

    public bool Register(uint modifiers, uint vk) {
        this.Id = 0xB00D;
        return RegisterHotKey(this.Handle, this.Id, modifiers, vk);
    }

    public void Unregister() {
        if (this.Handle != IntPtr.Zero) { UnregisterHotKey(this.Handle, this.Id); }
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY && (int)m.WParam == this.Id) {
            EventHandler h = Pressed;
            if (h != null) { h(this, EventArgs.Empty); }
            return;
        }
        base.WndProc(ref m);
    }

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")]
    static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
'@ -ReferencedAssemblies @([System.Windows.Forms.Message].Assembly.Location, [System.Object].Assembly.Location)

try { [SnapitNative]::SetProcessDPIAware() | Out-Null } catch {}

# ---------------------------------------------------------------- module glue
$script:SnapitRoot = $PSScriptRoot
if (-not $script:SnapitRoot) { $script:SnapitRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition }

. (Join-Path $script:SnapitRoot 'lib\snapit-hermes.ps1')

$script:SnapitLogFile = Join-Path (Get-SnapitHome) 'logs\snapit.log'
$script:SnapitFocusOpen = $false

# ---------------------------------------------------------------- emoji table
$script:Emo = @{
    laptop   = (Get-SnapitEmoji 0x1F4BB)                    # Terminal
    whale    = (Get-SnapitEmoji 0x1F40B)                    # DeepSeek
    mouse    = (Get-SnapitEmoji 0x1F5B1 -WithVariation)     # pointer tool
    crystal  = (Get-SnapitEmoji 0x1F52E)                    # improving...
    scissors = (Get-SnapitEmoji 0x2702 -WithVariation)      # tray
    folder   = (Get-SnapitEmoji 0x1F4C1)
    gear     = (Get-SnapitEmoji 0x2699 -WithVariation)
    tools    = (Get-SnapitEmoji 0x1F6E0 -WithVariation)     # unknown profile
    copy     = (Get-SnapitEmoji 0x1F4CB)
    trash    = (Get-SnapitEmoji 0x1F5D1)
    undo     = (Get-SnapitEmoji 0x21A9)
    ok       = (Get-SnapitEmoji 0x2713)
    cancel   = (Get-SnapitEmoji 0x2715)
    clock    = (Get-SnapitEmoji 0x23F3)
}

# ---------------------------------------------------------------- color / brush helpers
function ConvertTo-WpfBrush {
    param([string]$Hex)
    $color = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
    return New-Object System.Windows.Media.SolidColorBrush($color)
}

function ConvertTo-WpfColor {
    param([string]$Hex)
    return [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
}

# ---------------------------------------------------------------- pixel scalar helper
# PowerShell arithmetic on arrays is the "remove element" operator, so a value that
# unexpectedly arrives as Object[] (e.g. VirtualScreen.* member enumeration on some
# display configs) must be unwrapped to a plain double before any math.
function ConvertTo-SnapitPx {
    param($Value)
    if ($null -eq $Value) { return 0.0 }
    if ($Value -is [System.Array]) {
        if ($Value.Length -ge 1) { try { return [double]$Value[0] } catch { return 0.0 } }
        return 0.0
    }
    try { return [double]$Value } catch { return 0.0 }
}

# ---------------------------------------------------------------- tiny UI factories
function New-WpfTextBlock {
    param(
        [string]$Text = '',
        [double]$Size = 14,
        [string]$Color = '#E8E8EA',
        [string]$Weight = 'Normal',
        [string]$Font = 'Segoe UI',
        [switch]$EmojiFont
    )
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = $Size
    $tb.Foreground = ConvertTo-WpfBrush $Color
    switch ($Weight) {
        'Bold'      { $tb.FontWeight = [System.Windows.FontWeights]::Bold }
        'SemiBold'  { $tb.FontWeight = [System.Windows.FontWeights]::SemiBold }
        'Light'     { $tb.FontWeight = [System.Windows.FontWeights]::Light }
        default     { $tb.FontWeight = [System.Windows.FontWeights]::Normal }
    }
    if ($EmojiFont) { $tb.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI Emoji') } else { $tb.FontFamily = New-Object System.Windows.Media.FontFamily($Font) }
    return $tb
}

function New-WpfButton {
    param(
        [string]$Emoji,
        [string]$Caption,
        [string]$Sub = '',
        [double]$Width,
        [double]$Height,
        [scriptblock]$OnClick,
        [string]$Background = '#333338',
        [double]$EmojiSize = 26,
        [switch]$Vertical
    )
    $border = New-Object System.Windows.Controls.Border
    $border.Width = $Width
    $border.Height = $Height
    $border.Background = ConvertTo-WpfBrush $Background
    $border.CornerRadius = New-Object System.Windows.CornerRadius(12)
    $border.BorderBrush = ConvertTo-WpfBrush '#4A4A52'
    $border.BorderThickness = New-Object System.Windows.Thickness(1)
    $border.Cursor = [System.Windows.Input.Cursors]::Hand
    $border.Margin = New-Object System.Windows.Thickness(6)

    $stack = New-Object System.Windows.Controls.StackPanel
    if ($Vertical) { $stack.Orientation = [System.Windows.Controls.Orientation]::Vertical } else { $stack.Orientation = [System.Windows.Controls.Orientation]::Horizontal }
    $stack.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $stack.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    if ($Emoji) {
        $e = New-WpfTextBlock -Text $Emoji -Size $EmojiSize -EmojiFont
        if ($Vertical) { $e.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center }
        [void]$stack.Children.Add($e)
    }
    if ($Caption) {
        $c = New-WpfTextBlock -Text $Caption -Size 18 -Weight 'SemiBold'
        if ($Vertical) { $c.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center; $c.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0) } else { $c.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0) }
        [void]$stack.Children.Add($c)
    }
    if ($Sub) {
        $s = New-WpfTextBlock -Text $Sub -Size 12 -Color '#9A9AA2'
        if ($Vertical) { $s.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center; $s.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0) } else { $s.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0) }
        [void]$stack.Children.Add($s)
    }

    $border.Child = $stack

    $hover = $false
    $normalBrush = ConvertTo-WpfBrush $Background
    $hoverBrush  = ConvertTo-WpfBrush ($Background -replace '#', '#C8')
    $border.Add_MouseEnter(({ param($s, $e) $s.Background = $hoverBrush }).GetNewClosure())
    $border.Add_MouseLeave(({ param($s, $e) $s.Background = $normalBrush }).GetNewClosure())
    if ($OnClick) {
        $border.Add_MouseLeftButtonUp(({ param($s, $e) & $OnClick }).GetNewClosure())
    }
    return $border
}

# ---------------------------------------------------------------- window factory
function New-SnapitWindow {
    param([double]$Width, [double]$Height, [string]$Title, [switch]$Topmost)
    $w = New-Object System.Windows.Window
    $w.Title = $Title
    $w.Width = $Width
    $w.Height = $Height
    $w.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
    $w.WindowStyle = [System.Windows.WindowStyle]::SingleBorderWindow
    $w.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $w.Background = ConvertTo-WpfBrush '#1B1B1F'
    $w.ShowInTaskbar = $false
    if ($Topmost) { $w.Topmost = $true }
    $w.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
    return $w
}

# =====================================================================
#  CAPTURE OVERLAY
# =====================================================================
function Start-SnapitCapture {
    $cfg = Get-SnapitConfig

    # ---- full-screen capture (virtual desktop)
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $wpx = ConvertTo-SnapitPx $vs.Width
    $hpx = ConvertTo-SnapitPx $vs.Height
    $vsX = ConvertTo-SnapitPx $vs.X
    $vsY = ConvertTo-SnapitPx $vs.Y
    if ($wpx -le 0 -or $hpx -le 0) { return $null }

    $bmp = New-Object System.Drawing.Bitmap([int]$wpx, [int]$hpx)
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.CopyFromScreen([int]$vsX, [int]$vsY, 0, 0, (New-Object System.Drawing.Size([int]$wpx, [int]$hpx)))
        } finally { $g.Dispose() }
    } catch {
        Write-SnapitLog "screen capture failed: $($_.Exception.Message)"
        return $null
    }

    $hbm = [IntPtr]::Zero
    $source = $null
    try {
        $hbm = $bmp.GetHbitmap()
        $source = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHBitmap(
            $hbm, [IntPtr]::Zero,
            [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $source.Freeze()
    } finally {
        if ($hbm -ne [IntPtr]::Zero) { [SnapitNative]::DeleteObject($hbm) | Out-Null }
        $bmp.Dispose()
    }

    # ---- window + layers
    $win = New-Object System.Windows.Window
    $win.WindowStyle = [System.Windows.WindowStyle]::None
    $win.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $win.AllowsTransparency = $false
    $win.Background = ConvertTo-WpfBrush '#000000'
    $win.Topmost = $true
    $win.ShowInTaskbar = $false
    $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
    $win.Left = $vsX
    $win.Top = $vsY
    $win.Width = $wpx
    $win.Height = $hpx
    $win.Cursor = [System.Windows.Input.Cursors]::Cross

    $grid = New-Object System.Windows.Controls.Grid

    $img = New-Object System.Windows.Controls.Image
    $img.Source = $source
    $img.Stretch = [System.Windows.Media.Stretch]::Fill
    [void]$grid.Children.Add($img)

    $canvas = New-Object System.Windows.Controls.Canvas
    $canvas.Background = [System.Windows.Media.Brushes]::Transparent
    [void]$grid.Children.Add($canvas)
    $win.Content = $grid

    $state = @{
        phase     = 'select'          # select | tools
        region    = $null             # hashtable x y w h (canvas coords == screen px)
        tool      = 'square'
        toolColor = '#E53935'
        thick     = 4
        shapes    = New-Object System.Collections.ArrayList   # meta of committed shapes
        current   = $null             # meta of shape being drawn
        draft     = $null             # text draft control
        cancelled = $true
        dims      = New-Object System.Collections.ArrayList
        toolbar   = $null
        hint      = $null
        result    = $null
    }
    if ($cfg.toolColor) { $state.toolColor = [string]$cfg.toolColor }
    if ($cfg.toolThickness -gt 0) { $state.thick = [int]$cfg.toolThickness }
    $state.tool = $cfg.lastTool
    if ($state.tool -notin @('pointer', 'text', 'square', 'circle')) { $state.tool = 'square' }

    $accentBrush  = ConvertTo-WpfBrush '#2F81F7'
    $dimBrush     = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(70, 0, 0, 0))
    $toolBrush    = ConvertTo-WpfBrush $state.toolColor

    # ---------------- shape factories
    function New-ShapeElement {
        param($Kind, $X, $Y, $W, $H, [string]$TextContent = '')
        $meta = @{ kind = $Kind; x = [double]$X; y = [double]$Y; w = [double]$W; h = [double]$H }
        if ($Kind -eq 'text') { $meta.text = $TextContent }
        switch ($Kind) {
            'square' {
                $el = New-Object System.Windows.Shapes.Rectangle
                $el.Stroke = $toolBrush
                $el.StrokeThickness = $state.thick
                $el.Fill = [System.Windows.Media.Brushes]::Transparent
                $el.StrokeDashArray = New-Object System.Windows.Media.DoubleCollection @(4, 3)
                $meta.element = $el
                [System.Windows.Controls.Canvas]::SetLeft($el, $X); [System.Windows.Controls.Canvas]::SetTop($el, $Y); $el.Width = $W; $el.Height = $H
                [void]$canvas.Children.Add($el)
            }
            'circle' {
                $el = New-Object System.Windows.Shapes.Ellipse
                $el.Stroke = $toolBrush
                $el.StrokeThickness = $state.thick
                $el.Fill = [System.Windows.Media.Brushes]::Transparent
                $meta.element = $el
                [System.Windows.Controls.Canvas]::SetLeft($el, $X); [System.Windows.Controls.Canvas]::SetTop($el, $Y); $el.Width = $W; $el.Height = $H
                [void]$canvas.Children.Add($el)
            }
            'text' {
                $fontPx = [double]30
                if ($cfg.textFontSize -gt 0) { $fontPx = [double]$cfg.textFontSize }
                $tb = New-WpfTextBlock -Text $TextContent -Size $fontPx -Color $state.toolColor -Weight 'Bold'
                $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
                $shadow.Color = [System.Windows.Media.Colors]::Black
                $shadow.ShadowDepth = 1.5
                $shadow.BlurRadius = 1
                $shadow.Opacity = 0.95
                $tb.Effect = $shadow
                $meta.element = $tb
                [System.Windows.Controls.Canvas]::SetLeft($tb, $X); [System.Windows.Controls.Canvas]::SetTop($tb, $Y)
                [void]$canvas.Children.Add($tb)
            }
            'pointer' {
                $tb = New-WpfTextBlock -Text $script:Emo.mouse -Size 30 -EmojiFont
                $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
                $shadow.Color = [System.Windows.Media.Colors]::Black
                $shadow.ShadowDepth = 1
                $shadow.BlurRadius = 1
                $shadow.Opacity = 0.9
                $tb.Effect = $shadow
                $meta.element = $tb
                [System.Windows.Controls.Canvas]::SetLeft($tb, $X - 4); [System.Windows.Controls.Canvas]::SetTop($tb, $Y - 4)
                [void]$canvas.Children.Add($tb)
            }
        }
        return $meta
    }

    function Remove-ShapeMeta {
        param($Meta)
        if ($Meta -and $Meta.element -and $canvas.Children.Contains($Meta.element)) {
            [void]$canvas.Children.Remove($Meta.element)
        }
    }

    # ---------------- dim visuals
    function Update-DimVisuals {
        foreach ($d in $state.dims) { if ($canvas.Children.Contains($d)) { [void]$canvas.Children.Remove($d) } }
        $state.dims.Clear()
        $r = $state.region
        if (-not $r) {
            $full = New-Object System.Windows.Shapes.Rectangle
            $full.Fill = $dimBrush
            $full.Width = $canvas.ActualWidth
            $full.Height = $canvas.ActualHeight
            [System.Windows.Controls.Canvas]::SetLeft($full, 0); [System.Windows.Controls.Canvas]::SetTop($full, 0)
            [void]$canvas.Children.Add($full)
            [void]$state.dims.Add($full)
            return
        }
        # dim the four bands around the region
        $rects = @(
            @{ x = 0;        y = 0;        w = $canvas.ActualWidth; h = $r.y },
            @{ x = 0;        y = ($r.y + $r.h); w = $canvas.ActualWidth; h = ([Math]::Max(0, $canvas.ActualHeight - $r.y - $r.h)) },
            @{ x = 0;        y = $r.y;     w = $r.x;  h = $r.h },
            @{ x = ($r.x + $r.w); y = $r.y; w = ([Math]::Max(0, $canvas.ActualWidth - $r.x - $r.w)); h = $r.h }
        )
        foreach ($rc in $rects) {
            if ($rc.w -le 0 -or $rc.h -le 0) { continue }
            $el = New-Object System.Windows.Shapes.Rectangle
            $el.Fill = $dimBrush
            $el.Width = $rc.w
            $el.Height = $rc.h
            [System.Windows.Controls.Canvas]::SetLeft($el, $rc.x); [System.Windows.Controls.Canvas]::SetTop($el, $rc.y)
            [void]$canvas.Children.Add($el)
            [void]$state.dims.Add($el)
        }
        # region outline
        $out = New-Object System.Windows.Shapes.Rectangle
        $out.Stroke = $accentBrush
        $out.StrokeThickness = 2
        $out.Fill = [System.Windows.Media.Brushes]::Transparent
        $out.Width = $r.w; $out.Height = $r.h
        [System.Windows.Controls.Canvas]::SetLeft($out, $r.x); [System.Windows.Controls.Canvas]::SetTop($out, $r.y)
        [void]$canvas.Children.Add($out)
        [void]$state.dims.Add($out)
    }

    # ---------------- toolbar
    function New-ToolButton {
        param([string]$Emoji, [string]$Name, [string]$Key)
        $b = New-Object System.Windows.Controls.Border
        $b.Width = 46
        $b.Height = 40
        $b.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $b.Margin = New-Object System.Windows.Thickness(3, 0, 3, 0)
        $b.Cursor = [System.Windows.Input.Cursors]::Hand
        $tb = New-WpfTextBlock -Text $Emoji -Size 22 -EmojiFont
        $tb.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        $tb.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $b.Child = $tb
        $b.Tag = $Key
        $b.Add_MouseLeftButtonUp({
            param($s, $e)
            if ([string]$s.Tag -notin @('pointer', 'text', 'square', 'circle')) { return }
            $state.tool = $s.Tag
            $state.toolColor = $cfg.toolColor
            if ($state.draft) { Complete-TextDraft }
            Update-ToolbarHighlight
        })
        return $b
    }

    $toolButtons = @{}

    function Build-Toolbar {
        $outer = New-Object System.Windows.Controls.Border
        $outer.Background = ConvertTo-WpfBrush '#26262B'
        $outer.CornerRadius = New-Object System.Windows.CornerRadius(10)
        $outer.BorderBrush = ConvertTo-WpfBrush '#4A4A52'
        $outer.BorderThickness = New-Object System.Windows.Thickness(1)
        $outer.Padding = New-Object System.Windows.Thickness(8, 5, 8, 5)
        $outer.Tag = 'chrome'
        $stack = New-Object System.Windows.Controls.StackPanel
        $stack.Orientation = [System.Windows.Controls.Orientation]::Horizontal

        $toolButtons.pointer = New-ToolButton -Emoji $script:Emo.mouse -Name 'pointer' -Key 'pointer'
        $toolButtons.text    = New-ToolButton -Emoji 'T' -Name 'text' -Key 'text'
        $toolButtons.square  = New-ToolButton -Emoji (Get-SnapitEmoji 0x25AD) -Name 'square' -Key 'square'
        $toolButtons.circle  = New-ToolButton -Emoji (Get-SnapitEmoji 0x25EF) -Name 'circle' -Key 'circle'

        $sep = New-Object System.Windows.Controls.Border
        $sep.Width = 1; $sep.Height = 26; $sep.Background = ConvertTo-WpfBrush '#3A3A42'
        $sep.Margin = New-Object System.Windows.Thickness(6, 0, 6, 0)

        $undoB = New-ToolButton -Emoji $script:Emo.undo -Name 'undo' -Key 'undo'
        $clearB = New-ToolButton -Emoji $script:Emo.trash -Name 'clear' -Key 'clear'
        $doneB  = New-ToolButton -Emoji $script:Emo.ok -Name 'done' -Key 'done'
        $cancelB = New-ToolButton -Emoji $script:Emo.cancel -Name 'cancel' -Key 'cancel'

        foreach ($b in @($toolButtons.pointer, $toolButtons.text, $toolButtons.square, $toolButtons.circle, $sep, $undoB, $clearB, $doneB, $cancelB)) {
            [void]$stack.Children.Add($b)
        }
        $outer.Child = $stack

        # special actions
        $undoB.Add_MouseLeftButtonUp({ param($s, $e) Undo-LastShape })
        $clearB.Add_MouseLeftButtonUp({ param($s, $e) Clear-AllShapes })
        $doneB.Add_MouseLeftButtonUp({ param($s, $e) Complete-Capture })
        $cancelB.Add_MouseLeftButtonUp({ param($s, $e) $win.Close() })

        return $outer
    }

    function Update-ToolbarHighlight {
        if (-not $state.toolbar) { return }
        $stack = $state.toolbar.Child
        foreach ($child in $stack.Children) {
            if ($child.Tag -and $toolButtons.ContainsKey([string]$child.Tag)) {
                if ([string]$child.Tag -eq $state.tool) {
                    $child.Background = ConvertTo-WpfBrush '#2F6BD8'
                } else {
                    $child.Background = ConvertTo-WpfBrush '#26262B'
                }
            }
        }
    }

    function Place-Toolbar {
        $r = $state.region
        if (-not $r) { return }
        $toolbar = Build-Toolbar
        $toolbar.Measure([System.Windows.Size]::new(10000, 10000))
        $tw = $toolbar.DesiredSize.Width
        $th = $toolbar.DesiredSize.Height
        $pad = 10
        $x = $r.x + ($r.w - $tw) / 2
        if ($x -lt $pad) { $x = $pad }
        if ($x + $tw -gt $wpx - $pad) { $x = $wpx - $tw - $pad }
        $y = $r.y + $r.h + 10
        if ($y + $th -gt $hpx - 4) { $y = $r.y - $th - 10 }
        if ($y -lt 0) { $y = 0 }
        [System.Windows.Controls.Canvas]::SetLeft($toolbar, $x)
        [System.Windows.Controls.Canvas]::SetTop($toolbar, $y)
        [void]$canvas.Children.Add($toolbar)
        $state.toolbar = $toolbar
        Update-ToolbarHighlight
    }

    # ---------------- hint label
    $hintTb = New-WpfTextBlock -Text 'drag to select area  |  esc = cancel' -Size 13 -Color '#C0C0C8'
    $hintBorder = New-Object System.Windows.Controls.Border
    $hintBorder.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(160, 20, 20, 24))
    $hintBorder.CornerRadius = New-Object System.Windows.CornerRadius(8)
    $hintBorder.Padding = New-Object System.Windows.Thickness(12, 6, 12, 6)
    $hintBorder.Child = $hintTb
    [void]$canvas.Children.Add($hintBorder)
    $hintLeft = [double](($wpx - 320.0) / 2.0)
    [System.Windows.Controls.Canvas]::SetLeft($hintBorder, $hintLeft)
    [System.Windows.Controls.Canvas]::SetTop($hintBorder, $hpx - 54)
    $state.hint = $hintBorder

    function Update-Hint {
        param([string]$Text)
        if ($state.hint) { $state.hint.Child.Text = $Text }
    }

    # ---------------- text draft machinery
    function Begin-TextDraft {
        param([double]$X, [double]$Y)
        if ($state.draft) { Complete-TextDraft }
        $fontPx = [double]30
        if ($cfg.textFontSize -gt 0) { $fontPx = [double]$cfg.textFontSize }

        $box = New-Object System.Windows.Controls.TextBox
        $box.Width = 260
        $box.FontSize = $fontPx
        $box.FontWeight = [System.Windows.FontWeights]::Bold
        $box.Foreground = ConvertTo-WpfBrush $state.toolColor
        $box.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(120, 0, 0, 0))
        $box.BorderBrush = $accentBrush
        $box.BorderThickness = New-Object System.Windows.Thickness(1.5)
        $box.CaretBrush = ConvertTo-WpfBrush $state.toolColor
        $box.Padding = New-Object System.Windows.Thickness(4, 1, 4, 1)
        $box.MaxLength = 300
        $box.TextWrapping = [System.Windows.TextWrapping]::Wrap

        [System.Windows.Controls.Canvas]::SetLeft($box, $X)
        [System.Windows.Controls.Canvas]::SetTop($box, $Y)
        [void]$canvas.Children.Add($box)

        $draft = @{ box = $box; x = $X; y = $Y; fontPx = $fontPx; text = '' }
        $state.draft = $draft

        $box.Add_LostKeyboardFocus({ param($s, $e) Complete-TextDraft })
        $box.Add_PreviewKeyDown({
            param($s, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
                $e.Handled = $true
                Complete-TextDraft
                # TextBox has no ClearFocus(); WPF clears keyboard focus via the static Keyboard helper.
                [System.Windows.Input.Keyboard]::ClearFocus()
            } elseif ($e.Key -eq [System.Windows.Input.Key]::Escape) {
                $e.Handled = $true
                $d = $state.draft
                if ($d) { $state.draft = $null; Remove-ShapeMeta @{ element = $d.box } }
                # TextBox has no ClearFocus(); WPF clears keyboard focus via the static Keyboard helper.
                [System.Windows.Input.Keyboard]::ClearFocus()
            }
        })
        $box.Focus() | Out-Null
        $box.SelectAll()
    }

    function Complete-TextDraft {
        $d = $state.draft
        if (-not $d) { return }
        $state.draft = $null
        $text = $d.box.Text.Trim()
        Remove-ShapeMeta @{ element = $d.box }
        if ($text) {
            $m = New-ShapeElement 'text' ([double]$d.x) ([double]$d.y) 0 0 $text
            [void]$state.shapes.Add($m)
        }
    }

    # ---------------- undo / clear
    function Undo-LastShape {
        if ($state.draft) { Complete-TextDraft; return }
        if ($state.shapes.Count -gt 0) {
            $idx = $state.shapes.Count - 1
            Remove-ShapeMeta $state.shapes[$idx]
            $state.shapes.RemoveAt($idx)
        }
    }
    function Clear-AllShapes {
        if ($state.draft) { $d = $state.draft; $state.draft = $null; Remove-ShapeMeta @{ element = $d.box } }
        foreach ($m in @($state.shapes)) { Remove-ShapeMeta $m }
        $state.shapes.Clear()
    }

    # ---------------- capture finish
    function Complete-Capture {
        $r = $state.region
        if (-not $r) { return }
        try {
            if ($state.draft) { Complete-TextDraft }
            # hide UI chrome (dim overlays, region outline, toolbar, hints) before rendering
            foreach ($d in @($state.dims)) { if ($d) { $d.Visibility = [System.Windows.Visibility]::Collapsed } }
            if ($state.toolbar) { $state.toolbar.Visibility = [System.Windows.Visibility]::Collapsed }
            if ($state.hint) { $state.hint.Visibility = [System.Windows.Visibility]::Collapsed }
            $win.UpdateLayout()

            $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($wpx, $hpx, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
            $rtb.Render($grid)

            # pad generously: tool strokes, pointer marks and text may poke past the region edge
            $pad = 34.0
            $cx = [int][Math]::Max(0, $r.x - $pad)
            $cy = [int][Math]::Max(0, $r.y - $pad)
            $cw = [int][Math]::Min($wpx - $cx, $r.w + 2 * $pad)
            $ch = [int][Math]::Min($hpx - $cy, $r.h + 2 * $pad)
            $cropRect = New-Object System.Windows.Int32Rect($cx, $cy, $cw, $ch)
            $crop = New-Object System.Windows.Media.Imaging.CroppedBitmap($rtb, $cropRect)
            $crop.Freeze()

            $snapHome = Get-SnapitHome
            $capturesDir = Join-Path $snapHome 'captures'
            $ts = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
            $file = Join-Path $capturesDir ("capture_{0}.png" -f $ts)

            $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            [void]$encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($crop))
            $fs = [System.IO.File]::Create($file)
            try { $encoder.Save($fs) } finally { $fs.Dispose() }

            $state.result = @{ Path = $file; Bitmap = $crop }
            $state.cancelled = $false

            try {
                $crop2 = New-Object System.Windows.Media.Imaging.CroppedBitmap($rtb, $cropRect)
                $crop2.Freeze()
                [System.Windows.Clipboard]::SetImage($crop2)
            } catch { Write-SnapitLog "clipboard copy failed: $($_.Exception.Message)" }
        } catch {
            Write-SnapitLog "complete-capture error: $($_.Exception.Message)"
        } finally {
            $win.Close()
        }
    }

    # ---------------- canvas interaction
    $drag = @{ active = $false; x = 0.0; y = 0.0 }

    $canvas.Add_MouseLeftButtonDown({
        param($s, $e)

        # clicks that start on UI chrome (toolbar / hint) never reach canvas logic
        $origin = $e.OriginalSource
        if ($null -ne $origin) {
            $node = $origin
            $inChrome = $false
            while ($null -ne $node) {
                if ($node -eq $state.toolbar -or $node -eq $state.hint) { $inChrome = $true; break }
                $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
            }
            if ($inChrome) { return }
        }

        $p = $e.GetPosition($canvas)
        $state.curX = $p.X; $state.curY = $p.Y

        # an open text draft commits on outside click; do nothing else that click
        if ($state.draft) {
            Complete-TextDraft
            return
        }

        if ($state.phase -eq 'select') {
            $drag.active = $true
            $drag.x = $p.X; $drag.y = $p.Y
            $canvas.CaptureMouse()
            return
        }

        # tools phase
        $r = $state.region
        if (-not $r) { return }
        if ($p.X -lt $r.x -or $p.X -gt ($r.x + $r.w) -or $p.Y -lt $r.y -or $p.Y -gt ($r.y + $r.h)) { return }

        if ($state.tool -eq 'pointer') {
            $m = New-ShapeElement 'pointer' $p.X $p.Y 0 0
            [void]$state.shapes.Add($m)
            return
        }
        if ($state.tool -eq 'text') {
            Begin-TextDraft $p.X ($p.Y - 2)
            return
        }
        if ($state.tool -in @('square', 'circle')) {
            $drag.active = $true
            $drag.x = $p.X; $drag.y = $p.Y
            $canvas.CaptureMouse()
        }
    })

    $canvas.Add_MouseMove({
        param($s, $e)
        if (-not $drag.active) { return }
        $p = $e.GetPosition($canvas)
        $state.curX = $p.X; $state.curY = $p.Y

        $x = [Math]::Min($drag.x, $p.X)
        $y = [Math]::Min($drag.y, $p.Y)
        $w = [Math]::Abs($p.X - $drag.x)
        $h = [Math]::Abs($p.Y - $drag.y)

        if ($state.phase -eq 'select') {
            # move dims
            if (-not $state.region) { Update-DimVisuals }
            $state.region = @{ x = $x; y = $y; w = $w; h = $h }
            Update-DimVisuals
            Update-Hint ([string]::Format('selection  {0} x {1}   |   release = ok', [int]$w, [int]$h))
            return
        }

        # tools phase shape preview
        if ($state.tool -in @('square', 'circle')) {
            if ($state.current) { Remove-ShapeMeta $state.current; $state.current = $null }
            $kind = 'square'; if ($state.tool -eq 'circle') { $kind = 'circle' }
            $meta = New-ShapeElement $kind $x $y $w $h
            $state.current = $meta
        }
    })

    $canvas.Add_MouseLeftButtonUp({
        param($s, $e)
        if (-not $drag.active) { return }
        $drag.active = $false
        $canvas.ReleaseMouseCapture()
        $p = $e.GetPosition($canvas)
        $state.curX = $p.X; $state.curY = $p.Y

        $x = [Math]::Min($drag.x, $p.X)
        $y = [Math]::Min($drag.y, $p.Y)
        $w = [Math]::Abs($p.X - $drag.x)
        $h = [Math]::Abs($p.Y - $drag.y)

        if ($state.phase -eq 'select') {
            if ($w -ge 8 -and $h -ge 8) {
                $state.region = @{ x = $x; y = $y; w = $w; h = $h }
                Update-DimVisuals
                $state.phase = 'tools'
                Place-Toolbar
                Update-Hint 'draw with your tool  |  enter = done  |  esc = cancel  |  left-click empty = new marks'
            } else {
                $state.region = $null
                Update-DimVisuals
            }
            return
        }

        if ($state.tool -in @('square', 'circle')) {
            $c = $state.current
            $state.current = $null
            if ($c) {
                if ($c.w -lt 6 -or $c.h -lt 6) {
                    Remove-ShapeMeta $c
                } else {
                    # solid stroke after commit (no dashed)
                    $c.element.StrokeDashArray = $null
                    [void]$state.shapes.Add($c)
                }
            }
        }
    })

    # ---------------- keyboard
    $win.Add_PreviewKeyDown({
        param($s, $e)
        # while typing in the text tool, let the TextBox handle keys
        if ([System.Windows.Input.Keyboard]::FocusedElement -is [System.Windows.Controls.TextBox]) { return }
        if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
            $e.Handled = $true
            if ($state.draft) {
                $d = $state.draft
                $state.draft = $null
                Remove-ShapeMeta @{ element = $d.box }
                return
            }
            if ($state.current) { Remove-ShapeMeta $state.current; $state.current = $null; return }
            if ($state.phase -eq 'tools') {
                $state.phase = 'select'
                $state.region = $null
                Clear-AllShapes
                Update-DimVisuals
                if ($state.toolbar) { Remove-ShapeMeta @{ element = $state.toolbar }; $state.toolbar = $null }
                Update-Hint 'drag to select area  |  esc = cancel'
                return
            }
            $win.Close()
            return
        }
        if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
            $e.Handled = $true
            Complete-Capture
            return
        }
    })

    # undo/clear/done also accessible from keyboard
    $win.Add_PreviewKeyDown({
        param($s, $e)
        if ([System.Windows.Input.Keyboard]::FocusedElement -is [System.Windows.Controls.TextBox]) { return }
        if ($e.Key -eq [System.Windows.Input.Key]::Z -and [System.Windows.Input.Keyboard]::Modifiers -eq [System.Windows.Input.ModifierKeys]::Control) {
            $e.Handled = $true
            Undo-LastShape
        }
    })

    # ---------------- run
    Update-DimVisuals
    # ShowDialog displays and activates the previously hidden window atomically.
    $win.ShowDialog() | Out-Null

    # cleanup native
    if ($state.result) {
        # persist last used tool
        $cfg.lastTool = $state.tool
        Save-SnapitConfig $cfg
    }
    return $state.result
}

# =====================================================================
#  BACKGROUND HELPERS (improver / prefill run off the UI thread)
# =====================================================================
function Start-SnapitModuleAsync {
    param([string]$Function, [hashtable]$Named)
    $json = $Named | ConvertTo-Json -Depth 8
    $modulePath = Join-Path $script:SnapitRoot 'lib\snapit-hermes.ps1'
    $body = {
        param($mp, $fn, $js)
        . $mp
        # PS 5.1 ConvertFrom-Json has no -Depth; it parses to full depth by default
        $o = $js | ConvertFrom-Json
        $h = @{}
        foreach ($prop in $o.PSObject.Properties) { $h[$prop.Name] = $prop.Value }
        return (& $fn @h)
    }
    $ps = [System.Management.Automation.PowerShell]::Create()
    [void]$ps.AddScript($body.ToString())
    [void]$ps.AddArgument($modulePath)
    [void]$ps.AddArgument($Function)
    [void]$ps.AddArgument($json)
    $handle = $ps.BeginInvoke()
    return @{ Handle = $handle; PS = $ps }
}

function Wait-SnapitAsyncUi {
    param($Job)
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $timer.Add_Tick({
        if ($Job.Handle.IsCompleted) {
            $timer.Stop()
            $frame.Continue = $false
        }
    })
    $timer.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)

    $output = $null
    $failed = $false
    try {
        $collection = $Job.PS.EndInvoke($Job.Handle)
        if ($collection -and $collection.Count -gt 0) { $output = $collection[$collection.Count - 1] }
    } catch {
        $failed = $true
        Write-SnapitLog "background job failed: $($_.Exception.Message)"
    } finally {
        $Job.PS.Dispose()
    }
    return @{ Ok = (-not $failed); Value = $output }
}

# =====================================================================
#  IMPROVER WINDOW (simple spinner while Hermes rewrites the prompt)
# =====================================================================
function Show-ImprovingWindow {
    $w = New-SnapitWindow -Width 430 -Height 190 -Title 'SnapIt' -Topmost
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = New-Object System.Windows.Thickness(20)
    $head = New-WpfTextBlock -Text ($script:Emo.crystal + '  Hermes is reading the capture') -Size 17 -Weight 'SemiBold'
    $head.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
    $sub = New-WpfTextBlock -Text 'Rewriting your intent into one sharp prompt...' -Size 13 -Color '#9A9AA2'
    $sub.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
    $note = New-WpfTextBlock -Text 'First capture in a while? The model needs a few seconds to see the image.' -Size 12 -Color '#6F6F78'
    $note.Margin = New-Object System.Windows.Thickness(0, 14, 0, 0)
    $note.TextWrapping = [System.Windows.TextWrapping]::Wrap
    [void]$panel.Children.Add($head)
    [void]$panel.Children.Add($sub)
    [void]$panel.Children.Add($note)
    $w.Content = $panel
    return $w
}

# =====================================================================
#  DESTINATION PICKER  (the 2 big emojis)
# =====================================================================
function Show-DestinationPicker {
    param([string]$ImagePath, [string]$ImprovedText)

    $choice = $null   # 'terminal' | 'web' | $null(cancel)
    $finalText = $ImprovedText

    $w = New-SnapitWindow -Width 860 -Height 640 -Title 'SnapIt - where do you want it?'

    $root = New-Object System.Windows.Controls.StackPanel
    $root.Margin = New-Object System.Windows.Thickness(24)

    $title = New-WpfTextBlock -Text ('SnapIt' + $script:Emo.scissors) -Size 15 -Color '#9A9AA2'
    [void]$root.Children.Add($title)

    $capName = Split-Path $ImagePath -Leaf
    $sub = New-WpfTextBlock -Text ("capture saved + copied:  " + $capName) -Size 12 -Color '#6F6F78'
    [void]$root.Children.Add($sub)

    $lbl = New-WpfTextBlock -Text 'Improved prompt (edit freely)' -Size 14 -Weight 'SemiBold'
    $lbl.Margin = New-Object System.Windows.Thickness(0, 14, 0, 4)
    [void]$root.Children.Add($lbl)

    $box = New-Object System.Windows.Controls.TextBox
    $box.Text = $ImprovedText
    $box.AcceptsReturn = $true
    $box.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $box.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $box.Height = 150
    $box.Padding = New-Object System.Windows.Thickness(8)
    $box.Background = ConvertTo-WpfBrush '#141418'
    $box.Foreground = ConvertTo-WpfBrush '#E8E8EA'
    $box.BorderBrush = ConvertTo-WpfBrush '#3A3A44'
    $box.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
    $box.FontSize = 13
    [void]$root.Children.Add($box)

    $q = New-WpfTextBlock -Text 'Where should this task run?' -Size 20 -Weight 'SemiBold'
    $q.Margin = New-Object System.Windows.Thickness(0, 22, 0, 2)
    [void]$root.Children.Add($q)

    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $row.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $row.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)

    $termBtn = New-WpfButton -Emoji $script:Emo.laptop -Caption 'TERMINAL' -Sub 'Hermes agents' -Width 250 -Height 170 -EmojiSize 58 -Vertical -Background '#1E3A2A' -OnClick { $choice = 'terminal'; $w.Close() }
    $termBtn.Margin = New-Object System.Windows.Thickness(10)
    [void]$row.Children.Add($termBtn)

    $webBtn = New-WpfButton -Emoji $script:Emo.whale -Caption 'DEEPSEEK' -Sub 'DSH Web UI (18080)' -Width 250 -Height 170 -EmojiSize 58 -Vertical -Background '#1C2C4A' -OnClick { $choice = 'web'; $w.Close() }
    $webBtn.Margin = New-Object System.Windows.Thickness(10)
    [void]$row.Children.Add($webBtn)

    [void]$root.Children.Add($row)

    $foot = New-WpfTextBlock -Text 'Enter = terminal  |  W = web  |  Esc = cancel' -Size 12 -Color '#6F6F78'
    $foot.Margin = New-Object System.Windows.Thickness(0, 16, 0, 0)
    $foot.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    [void]$root.Children.Add($foot)

    $w.Add_PreviewKeyDown({
        param($s, $e)
        if ([System.Windows.Input.Keyboard]::FocusedElement -is [System.Windows.Controls.TextBox]) { return }
        if ($e.Key -eq [System.Windows.Input.Key]::Escape) { $e.Handled = $true; $w.Close(); return }
        if ($e.Key -eq [System.Windows.Input.Key]::Enter -and [System.Windows.Input.Keyboard]::Modifiers -eq 0) { $e.Handled = $true; $choice = 'terminal'; $w.Close(); return }
        if ($e.Key -eq [System.Windows.Input.Key]::W -and [System.Windows.Input.Keyboard]::Modifiers -eq 0) { $e.Handled = $true; $choice = 'web'; $w.Close(); return }
    })

    $w.Content = $root
    $w.ShowDialog() | Out-Null
    $finalText = $box.Text
    return @{ Choice = $choice; Prompt = $finalText }
}

# =====================================================================
#  PROFILE PICKER (emoji grid of Hermes profiles)
# =====================================================================
function Show-ProfilePicker {
    param($Config, [string]$ForPrompt)

    $profiles = @(Get-HermesProfiles)
    if ($profiles.Count -eq 0) {
        [System.Windows.MessageBox]::Show('No Hermes profiles found. Is hermes installed?', 'SnapIt', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return $null
    }

    $selected = $null
    $w = New-SnapitWindow -Width 760 -Height 620 -Title 'SnapIt - pick a Hermes agent'

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $wrap = New-Object System.Windows.Controls.WrapPanel
    $wrap.Margin = New-Object System.Windows.Thickness(12)

    foreach ($p in $profiles) {
        $emoji = '?'
        if ($Config.profileEmojis -and $Config.profileEmojis.ContainsKey($p.Name)) { $emoji = [string]$Config.profileEmojis[$p.Name] }
        if (-not $emoji -or $emoji -eq '') { $emoji = $script:Emo.tools }

        $card = New-Object System.Windows.Controls.Border
        $card.Width = 210
        $card.Height = 128
        $card.Margin = New-Object System.Windows.Thickness(6)
        $card.CornerRadius = New-Object System.Windows.CornerRadius(10)
        $card.Background = ConvertTo-WpfBrush '#24242A'
        $card.BorderBrush = ConvertTo-WpfBrush '#3A3A44'
        $card.BorderThickness = New-Object System.Windows.Thickness(1)
        $card.Cursor = [System.Windows.Input.Cursors]::Hand
        $card.ToolTip = $p.Description

        $inner = New-Object System.Windows.Controls.StackPanel
        $inner.Margin = New-Object System.Windows.Thickness(10)
        $e = New-WpfTextBlock -Text $emoji -Size 34 -EmojiFont
        $n = New-WpfTextBlock -Text $p.Name -Size 16 -Weight 'SemiBold'
        $d = New-WpfTextBlock -Text $p.Description -Size 11 -Color '#8A8A94'
        $d.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $d.MaxHeight = 40
        $name = $p.Name
        [void]$inner.Children.Add($e)
        [void]$inner.Children.Add($n)
        [void]$inner.Children.Add($d)
        $card.Child = $inner

        $card.Tag = $p.Name
        $card.Add_MouseLeftButtonUp({ param($s, $ev) $selected = $s.Tag; $w.Close() })

        $card.Add_MouseEnter({ param($s, $ev) $s.Background = ConvertTo-WpfBrush '#2E3A55' })
        $card.Add_MouseLeave({ param($s, $ev) $s.Background = ConvertTo-WpfBrush '#24242A' })

        [void]$wrap.Children.Add($card)
    }
    $scroll.Content = $wrap

    $root = New-Object System.Windows.Controls.DockPanel
    $title = New-WpfTextBlock -Text 'Pick the Hermes profile that becomes the active agent for this task' -Size 15 -Weight 'SemiBold'
    $title.Margin = New-Object System.Windows.Thickness(14, 12, 14, 4)
    [System.Windows.Controls.DockPanel]::SetDock($title, 'Top')
    $hint = New-WpfTextBlock -Text 'Each runs its own Hermes instance (image attached + improved prompt). Esc cancels.' -Size 12 -Color '#6F6F78'
    $hint.Margin = New-Object System.Windows.Thickness(14, 0, 14, 8)
    [System.Windows.Controls.DockPanel]::SetDock($hint, 'Top')

    [void]$root.Children.Add($title)
    [void]$root.Children.Add($hint)
    [void]$root.Children.Add($scroll)

    $w.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Escape) { $e.Handled = $true; $w.Close() }
    })

    $w.Content = $root
    $w.ShowDialog() | Out-Null
    return $selected
}

# =====================================================================
#  RESULT / INFO dialog
# =====================================================================
function Show-SnapitMessage {
    param([string]$Text, [string]$Title = 'SnapIt', [int]$Icon = 0)
    $img = [System.Windows.MessageBoxImage]::None
    if ($Icon -eq 1) { $img = [System.Windows.MessageBoxImage]::Information }
    if ($Icon -eq 2) { $img = [System.Windows.MessageBoxImage]::Warning }
    if ($Icon -eq 3) { $img = [System.Windows.MessageBoxImage]::Error }
    [System.Windows.MessageBox]::Show($Text, $Title, [System.Windows.MessageBoxButton]::OK, $img) | Out-Null
}

# =====================================================================
#  ULTRA-FOCUS PROMPT (Alt+Shift+A)
# =====================================================================
function New-SnapitFocusOverlays {
    $forms = @()
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $form = New-Object System.Windows.Forms.Form
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $form.Bounds = $screen.Bounds
        $form.BackColor = [System.Drawing.Color]::Black
        $form.Opacity = 0.82
        $form.ShowInTaskbar = $false
        $form.TopMost = $true
        $form.Text = 'SnapIt Focus Overlay'
        $form.Show()
        $forms += $form
    }
    return $forms
}

function New-SnapitFocusButton {
    param([string]$Text, [string]$Background = '#29292F', [double]$Width = 150)
    $button = New-Object System.Windows.Controls.Button
    $button.Content = $Text
    $button.Width = $Width
    $button.Height = 44
    $button.Margin = New-Object System.Windows.Thickness(5)
    $button.Padding = New-Object System.Windows.Thickness(12, 6, 12, 6)
    $button.Foreground = ConvertTo-WpfBrush '#F5F3F3'
    $button.Background = ConvertTo-WpfBrush $Background
    $button.BorderBrush = ConvertTo-WpfBrush '#505058'
    $button.BorderThickness = New-Object System.Windows.Thickness(1)
    $button.FontSize = 14
    $button.FontWeight = [System.Windows.FontWeights]::SemiBold
    $button.Cursor = [System.Windows.Input.Cursors]::Hand
    return $button
}

function Show-SnapitScheduleDialog {
    param([string]$SuggestedName = '')

    $dialog = New-SnapitWindow -Width 520 -Height 330 -Title 'Schedule SnapIt task' -Topmost
    $dialog.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $dialog.Background = ConvertTo-WpfBrush '#101013'
    $dialog.BorderBrush = ConvertTo-WpfBrush '#8E222C'
    $dialog.BorderThickness = New-Object System.Windows.Thickness(1)

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = New-Object System.Windows.Thickness(24)
    $heading = New-WpfTextBlock -Text 'Schedule Task' -Size 22 -Weight 'Bold'
    $hint = New-WpfTextBlock -Text "When should Hermes run it? Examples: 30m, every 2h, 0 9 * * *, or an ISO date/time." -Size 12 -Color '#A79EA1'
    $hint.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $hint.Margin = New-Object System.Windows.Thickness(0, 6, 0, 16)
    $scheduleLabel = New-WpfTextBlock -Text 'SCHEDULE' -Size 11 -Weight 'Bold' -Color '#D85A63'
    $scheduleBox = New-Object System.Windows.Controls.TextBox
    $scheduleBox.Height = 36
    $scheduleBox.FontSize = 15
    $scheduleBox.Padding = New-Object System.Windows.Thickness(8, 4, 8, 4)
    $scheduleBox.Text = '30m'
    $scheduleBox.Margin = New-Object System.Windows.Thickness(0, 5, 0, 12)
    $nameLabel = New-WpfTextBlock -Text 'NAME (OPTIONAL)' -Size 11 -Weight 'Bold' -Color '#D85A63'
    $nameBox = New-Object System.Windows.Controls.TextBox
    $nameBox.Height = 36
    $nameBox.FontSize = 14
    $nameBox.Padding = New-Object System.Windows.Thickness(8, 4, 8, 4)
    $nameBox.Text = $SuggestedName
    $nameBox.Margin = New-Object System.Windows.Thickness(0, 5, 0, 16)

    $buttons = New-Object System.Windows.Controls.StackPanel
    $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $buttons.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $create = New-SnapitFocusButton -Text 'Create Schedule' -Background '#176B48' -Width 160
    $cancel = New-SnapitFocusButton -Text 'Cancel' -Width 100
    [void]$buttons.Children.Add($create)
    [void]$buttons.Children.Add($cancel)
    foreach ($control in @($heading, $hint, $scheduleLabel, $scheduleBox, $nameLabel, $nameBox, $buttons)) {
        [void]$panel.Children.Add($control)
    }

    $dialog.Tag = $null
    $create.Add_Click(({
        $schedule = $scheduleBox.Text.Trim()
        if (-not $schedule) {
            $scheduleBox.BorderBrush = ConvertTo-WpfBrush '#E53935'
            $scheduleBox.Focus() | Out-Null
            return
        }
        $dialog.Tag = [pscustomobject]@{ Schedule = $schedule; Name = $nameBox.Text.Trim() }
        $dialog.DialogResult = $true
        $dialog.Close()
    }).GetNewClosure())
    $cancel.Add_Click(({ $dialog.DialogResult = $false; $dialog.Close() }).GetNewClosure())
    $dialog.Add_PreviewKeyDown(({
        param($sender, $event)
        if ($event.Key -eq [System.Windows.Input.Key]::Escape) {
            $event.Handled = $true
            $dialog.DialogResult = $false
            $dialog.Close()
        }
    }).GetNewClosure())
    $dialog.Content = $panel
    $dialog.Add_ContentRendered(({ $scheduleBox.SelectAll(); $scheduleBox.Focus() | Out-Null }).GetNewClosure())
    [void]$dialog.ShowDialog()
    return $dialog.Tag
}

function Show-SnapitFocusPanel {
    if ($script:SnapitFocusOpen) { return }
    $script:SnapitFocusOpen = $true
    Write-SnapitLog 'focus stage: begin'
    $overlays = @()
    try {
        $cfg = Get-SnapitConfig
        $harnesses = @(Get-SnapitHarnesses -Config $cfg)
        Write-SnapitLog "focus stage: harnesses=$($harnesses.Count)"
        if ($harnesses.Count -eq 0) {
            Show-SnapitMessage 'No enabled Hermes harnesses are configured.' -Icon 2
            return
        }
        $overlays = @(New-SnapitFocusOverlays)
        Write-SnapitLog "focus stage: overlays=$($overlays.Count)"
        $screen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
        $width = 1220.0
        $height = 725.0
        $win = New-SnapitWindow -Width $width -Height $height -Title 'SnapIt - Ultra Focus' -Topmost
        $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
        $win.Left = [double]($screen.Bounds.Left + (($screen.Bounds.Width - $width) / 2.0))
        $win.Top = [double]($screen.Bounds.Top + (($screen.Bounds.Height - $height) / 2.0))
        $win.Background = ConvertTo-WpfBrush '#101013'
        $win.BorderBrush = ConvertTo-WpfBrush '#8E222C'
        $win.BorderThickness = New-Object System.Windows.Thickness(1)

        $root = New-Object System.Windows.Controls.Grid
        $root.Margin = New-Object System.Windows.Thickness(28)
        foreach ($size in @('Auto', 'Auto', '*', 'Auto', 'Auto', 'Auto')) {
            $row = New-Object System.Windows.Controls.RowDefinition
            if ($size -eq '*') { $row.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) }
            else { $row.Height = [System.Windows.GridLength]::Auto }
            [void]$root.RowDefinitions.Add($row)
        }

        $header = New-Object System.Windows.Controls.Grid
        $avatarCol = New-Object System.Windows.Controls.ColumnDefinition
        $avatarCol.Width = New-Object System.Windows.GridLength(86)
        $textCol = New-Object System.Windows.Controls.ColumnDefinition
        $textCol.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        [void]$header.ColumnDefinitions.Add($avatarCol)
        [void]$header.ColumnDefinitions.Add($textCol)

        $avatarBorder = New-Object System.Windows.Controls.Border
        $avatarBorder.Width = 72
        $avatarBorder.Height = 72
        $avatarBorder.CornerRadius = New-Object System.Windows.CornerRadius(36)
        $avatarBorder.BorderBrush = ConvertTo-WpfBrush '#DE3440'
        $avatarBorder.BorderThickness = New-Object System.Windows.Thickness(2)
        $avatarPath = Join-Path $script:SnapitRoot 'assets\sektor-chibi-avatar.png'
        if (Test-Path $avatarPath) {
            $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.UriSource = New-Object System.Uri($avatarPath)
            $bitmap.EndInit()
            $brush = New-Object System.Windows.Media.ImageBrush($bitmap)
            $brush.Stretch = [System.Windows.Media.Stretch]::UniformToFill
            $avatarBorder.Background = $brush
        }
        [System.Windows.Controls.Grid]::SetColumn($avatarBorder, 0)
        [void]$header.Children.Add($avatarBorder)

        $titles = New-Object System.Windows.Controls.StackPanel
        $titles.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $title = New-WpfTextBlock -Text 'ULTRA FOCUS' -Size 27 -Weight 'Bold'
        $subtitle = New-WpfTextBlock -Text 'Write, sharpen, dispatch - or call Sektor live.' -Size 13 -Color '#A79EA1'
        $subtitle.Margin = New-Object System.Windows.Thickness(0, 5, 0, 0)
        [void]$titles.Children.Add($title)
        [void]$titles.Children.Add($subtitle)
        [System.Windows.Controls.Grid]::SetColumn($titles, 1)
        [void]$header.Children.Add($titles)
        [System.Windows.Controls.Grid]::SetRow($header, 0)
        [void]$root.Children.Add($header)

        $promptLabel = New-WpfTextBlock -Text 'PROMPT' -Size 11 -Weight 'Bold' -Color '#D85A63'
        $promptLabel.Margin = New-Object System.Windows.Thickness(0, 22, 0, 7)
        [System.Windows.Controls.Grid]::SetRow($promptLabel, 1)
        [void]$root.Children.Add($promptLabel)

        $box = New-Object System.Windows.Controls.TextBox
        $box.AcceptsReturn = $true
        $box.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $box.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
        $box.Padding = New-Object System.Windows.Thickness(16)
        $box.FontSize = 16
        $box.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
        $box.Background = ConvertTo-WpfBrush '#18181D'
        $box.Foreground = ConvertTo-WpfBrush '#F2F0F0'
        $box.BorderBrush = ConvertTo-WpfBrush '#3B3B44'
        $box.BorderThickness = New-Object System.Windows.Thickness(1)
        [System.Windows.Controls.SpellCheck]::SetIsEnabled($box, $true)
        [System.Windows.Controls.Grid]::SetRow($box, 2)
        [void]$root.Children.Add($box)

        $route = New-Object System.Windows.Controls.Grid
        $route.Margin = New-Object System.Windows.Thickness(0, 16, 0, 4)
        $labelCol = New-Object System.Windows.Controls.ColumnDefinition
        $labelCol.Width = [System.Windows.GridLength]::Auto
        $comboCol = New-Object System.Windows.Controls.ColumnDefinition
        $comboCol.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        [void]$route.ColumnDefinitions.Add($labelCol)
        [void]$route.ColumnDefinitions.Add($comboCol)
        $routeLabel = New-WpfTextBlock -Text 'Agent / harness' -Size 13 -Weight 'SemiBold'
        $routeLabel.Margin = New-Object System.Windows.Thickness(0, 8, 16, 0)
        [System.Windows.Controls.Grid]::SetColumn($routeLabel, 0)
        [void]$route.Children.Add($routeLabel)
        $combo = New-Object System.Windows.Controls.ComboBox
        $combo.Height = 36
        $combo.DisplayMemberPath = 'Name'
        $combo.IsEditable = $true
        $combo.IsReadOnly = $true
        $combo.StaysOpenOnEdit = $false
        [System.Windows.Controls.TextSearch]::SetTextPath($combo, 'Name')
        $combo.Background = ConvertTo-WpfBrush '#24242A'
        $combo.Foreground = ConvertTo-WpfBrush '#F2F0F0'
        $combo.BorderBrush = ConvertTo-WpfBrush '#505058'
        $combo.BorderThickness = New-Object System.Windows.Thickness(1)
        $combo.Padding = New-Object System.Windows.Thickness(8, 3, 8, 3)
        $combo.Resources[[System.Windows.SystemColors]::WindowBrushKey] = ConvertTo-WpfBrush '#24242A'
        $combo.Resources[[System.Windows.SystemColors]::WindowTextBrushKey] = ConvertTo-WpfBrush '#F2F0F0'
        $combo.Resources[[System.Windows.SystemColors]::HighlightBrushKey] = ConvertTo-WpfBrush '#8E222C'
        $comboItemStyle = New-Object System.Windows.Style([System.Windows.Controls.ComboBoxItem])
        $comboItemBackground = New-Object System.Windows.Setter
        $comboItemBackground.Property = [System.Windows.Controls.Control]::BackgroundProperty
        $comboItemBackground.Value = ConvertTo-WpfBrush '#24242A'
        $comboItemForeground = New-Object System.Windows.Setter
        $comboItemForeground.Property = [System.Windows.Controls.Control]::ForegroundProperty
        $comboItemForeground.Value = ConvertTo-WpfBrush '#F2F0F0'
        $comboItemPadding = New-Object System.Windows.Setter
        $comboItemPadding.Property = [System.Windows.Controls.Control]::PaddingProperty
        $comboItemPadding.Value = New-Object System.Windows.Thickness(10, 7, 10, 7)
        [void]$comboItemStyle.Setters.Add($comboItemBackground)
        [void]$comboItemStyle.Setters.Add($comboItemForeground)
        [void]$comboItemStyle.Setters.Add($comboItemPadding)
        $combo.ItemContainerStyle = $comboItemStyle
        foreach ($h in $harnesses) { [void]$combo.Items.Add($h) }
        $combo.SelectedIndex = 0
        [System.Windows.Controls.Grid]::SetColumn($combo, 1)
        [void]$route.Children.Add($combo)
        [System.Windows.Controls.Grid]::SetRow($route, 3)
        [void]$root.Children.Add($route)

        $status = New-WpfTextBlock -Text 'Ctrl+Enter sends. Escape cancels without sending.' -Size 12 -Color '#827A7D'
        $status.Margin = New-Object System.Windows.Thickness(0, 8, 0, 6)
        [System.Windows.Controls.Grid]::SetRow($status, 4)
        [void]$root.Children.Add($status)

        $actions = New-Object System.Windows.Controls.StackPanel
        $actions.Orientation = [System.Windows.Controls.Orientation]::Vertical
        $actions.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        $utilityActions = New-Object System.Windows.Controls.StackPanel
        $utilityActions.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $utilityActions.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        $dispatchActions = New-Object System.Windows.Controls.StackPanel
        $dispatchActions.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $dispatchActions.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        $improveButton = New-SnapitFocusButton -Text 'Improve prompt' -Background '#3A263F' -Width 165
        $saveButton = New-SnapitFocusButton -Text 'Save to Draft' -Background '#27425A' -Width 165
        $scheduleButton = New-SnapitFocusButton -Text 'Schedule Task' -Background '#6B4B17' -Width 165
        $sendButton = New-SnapitFocusButton -Text 'Send to Wave' -Background '#176B48' -Width 165
        $voiceButton = New-SnapitFocusButton -Text 'Voice Call' -Background '#A51E2B' -Width 150
        $cancelButton = New-SnapitFocusButton -Text 'Cancel' -Width 110
        [void]$utilityActions.Children.Add($improveButton)
        [void]$utilityActions.Children.Add($saveButton)
        [void]$utilityActions.Children.Add($scheduleButton)
        [void]$dispatchActions.Children.Add($sendButton)
        [void]$dispatchActions.Children.Add($voiceButton)
        [void]$dispatchActions.Children.Add($cancelButton)
        [void]$actions.Children.Add($utilityActions)
        [void]$actions.Children.Add($dispatchActions)
        [System.Windows.Controls.Grid]::SetRow($actions, 5)
        [void]$root.Children.Add($actions)

        $shell = New-Object System.Windows.Controls.Grid
        $mainColumn = New-Object System.Windows.Controls.ColumnDefinition
        $mainColumn.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        $draftColumn = New-Object System.Windows.Controls.ColumnDefinition
        $draftColumn.Width = New-Object System.Windows.GridLength(320)
        [void]$shell.ColumnDefinitions.Add($mainColumn)
        [void]$shell.ColumnDefinitions.Add($draftColumn)
        [System.Windows.Controls.Grid]::SetColumn($root, 0)
        [void]$shell.Children.Add($root)

        $draftBorder = New-Object System.Windows.Controls.Border
        $draftBorder.Margin = New-Object System.Windows.Thickness(0, 28, 28, 28)
        $draftBorder.Padding = New-Object System.Windows.Thickness(16)
        $draftBorder.Background = ConvertTo-WpfBrush '#15151A'
        $draftBorder.BorderBrush = ConvertTo-WpfBrush '#3B3B44'
        $draftBorder.BorderThickness = New-Object System.Windows.Thickness(1)
        $draftBorder.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $draftGrid = New-Object System.Windows.Controls.Grid
        foreach ($size in @('Auto', '*', 'Auto')) {
            $row = New-Object System.Windows.Controls.RowDefinition
            if ($size -eq '*') { $row.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) }
            else { $row.Height = [System.Windows.GridLength]::Auto }
            [void]$draftGrid.RowDefinitions.Add($row)
        }
        $draftHeader = New-Object System.Windows.Controls.StackPanel
        $draftTitle = New-WpfTextBlock -Text 'DRAFTS' -Size 16 -Weight 'Bold' -Color '#F2F0F0'
        $draftHint = New-WpfTextBlock -Text 'Select one to keep editing.' -Size 12 -Color '#918A8D'
        $draftHint.Margin = New-Object System.Windows.Thickness(0, 4, 0, 12)
        [void]$draftHeader.Children.Add($draftTitle)
        [void]$draftHeader.Children.Add($draftHint)
        [System.Windows.Controls.Grid]::SetRow($draftHeader, 0)
        [void]$draftGrid.Children.Add($draftHeader)

        $draftList = New-Object System.Windows.Controls.ListBox
        $draftList.DisplayMemberPath = 'Display'
        $draftList.Background = ConvertTo-WpfBrush '#101013'
        $draftList.Foreground = ConvertTo-WpfBrush '#F2F0F0'
        $draftList.BorderBrush = ConvertTo-WpfBrush '#34343C'
        $draftList.BorderThickness = New-Object System.Windows.Thickness(1)
        $draftList.Padding = New-Object System.Windows.Thickness(4)
        $draftList.HorizontalContentAlignment = [System.Windows.HorizontalAlignment]::Stretch
        $draftItemStyle = New-Object System.Windows.Style([System.Windows.Controls.ListBoxItem])
        $draftItemBackground = New-Object System.Windows.Setter
        $draftItemBackground.Property = [System.Windows.Controls.Control]::BackgroundProperty
        $draftItemBackground.Value = ConvertTo-WpfBrush '#202027'
        $draftItemForeground = New-Object System.Windows.Setter
        $draftItemForeground.Property = [System.Windows.Controls.Control]::ForegroundProperty
        $draftItemForeground.Value = ConvertTo-WpfBrush '#F2F0F0'
        $draftItemMargin = New-Object System.Windows.Setter
        $draftItemMargin.Property = [System.Windows.FrameworkElement]::MarginProperty
        $draftItemMargin.Value = New-Object System.Windows.Thickness(0, 0, 0, 6)
        $draftItemPadding = New-Object System.Windows.Setter
        $draftItemPadding.Property = [System.Windows.Controls.Control]::PaddingProperty
        $draftItemPadding.Value = New-Object System.Windows.Thickness(9)
        [void]$draftItemStyle.Setters.Add($draftItemBackground)
        [void]$draftItemStyle.Setters.Add($draftItemForeground)
        [void]$draftItemStyle.Setters.Add($draftItemMargin)
        [void]$draftItemStyle.Setters.Add($draftItemPadding)
        $draftList.ItemContainerStyle = $draftItemStyle
        [System.Windows.Controls.Grid]::SetRow($draftList, 1)
        [void]$draftGrid.Children.Add($draftList)

        $draftActions = New-Object System.Windows.Controls.StackPanel
        $draftActions.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $draftActions.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        $draftActions.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
        $loadDraftButton = New-SnapitFocusButton -Text 'Load Draft' -Background '#27425A' -Width 135
        $deleteDraftButton = New-SnapitFocusButton -Text 'Delete' -Background '#5B252B' -Width 105
        [void]$draftActions.Children.Add($loadDraftButton)
        [void]$draftActions.Children.Add($deleteDraftButton)
        [System.Windows.Controls.Grid]::SetRow($draftActions, 2)
        [void]$draftGrid.Children.Add($draftActions)
        $draftBorder.Child = $draftGrid
        [System.Windows.Controls.Grid]::SetColumn($draftBorder, 1)
        [void]$shell.Children.Add($draftBorder)

        $refreshDrafts = {
            $draftList.Items.Clear()
            foreach ($draftItem in @(Get-SnapitPromptDrafts)) { [void]$draftList.Items.Add($draftItem) }
            $draftTitle.Text = "DRAFTS  ($($draftList.Items.Count))"
        }.GetNewClosure()
        & $refreshDrafts

        $loadSelectedDraft = {
            $selectedDraft = $draftList.SelectedItem
            if ($null -eq $selectedDraft) { $status.Text = 'Select a draft to load.'; return }
            $box.Text = [string]$selectedDraft.Text
            $box.CaretIndex = $box.Text.Length
            for ($i = 0; $i -lt $combo.Items.Count; $i++) {
                if ([string]$combo.Items[$i].Profile -eq [string]$selectedDraft.Profile) { $combo.SelectedIndex = $i; break }
            }
            $status.Text = 'Draft loaded. Continue editing, improve it, send it, or save a new version.'
            $box.Focus() | Out-Null
        }.GetNewClosure()
        $loadDraftButton.Add_Click($loadSelectedDraft)
        $draftList.Add_MouseDoubleClick($loadSelectedDraft)
        $deleteDraftButton.Add_Click(({
            $selectedDraft = $draftList.SelectedItem
            if ($null -eq $selectedDraft) { $status.Text = 'Select a draft to delete.'; return }
            $answer = [System.Windows.MessageBox]::Show('Delete this draft?', 'SnapIt Drafts', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
            if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
            try {
                [void](Remove-SnapitPromptDraft -Path ([string]$selectedDraft.Path))
                & $refreshDrafts
                $status.Text = 'Draft deleted.'
            } catch {
                $status.Text = "Could not delete draft: $($_.Exception.Message)"
            }
        }).GetNewClosure())

        $doImprove = {
            $raw = $box.Text.Trim()
            if (-not $raw) { $status.Text = 'Write something first.'; return }
            $selectedHarness = $combo.SelectedItem
            $target = if ($selectedHarness) { [string]$selectedHarness.Profile } else { 'default' }
            $status.Text = 'Sharpening the prompt with Hermes...'
            $box.IsEnabled = $false
            $improveButton.IsEnabled = $false
            $job = Start-SnapitModuleAsync -Function 'Invoke-SnapitTextImprove' -Named @{ Text = $raw; TargetProfile = $target; Config = $cfg }
            $result = Wait-SnapitAsyncUi -Job $job
            $box.IsEnabled = $true
            $improveButton.IsEnabled = $true
            if ($result.Ok -and $result.Value -and $result.Value.Ok) {
                $box.Text = [string]$result.Value.Text
                $box.CaretIndex = $box.Text.Length
                $status.Text = 'Prompt improved. Review it, then send.'
            } else {
                $status.Text = 'Could not improve it; your original text is preserved.'
            }
            $box.Focus() | Out-Null
        }.GetNewClosure()

        $doSend = {
            $text = $box.Text.Trim()
            $selectedHarness = $combo.SelectedItem
            if (-not $text) { $status.Text = 'Write a prompt before sending.'; return }
            if (-not $selectedHarness) { $status.Text = 'Choose an agent / harness.'; return }
            $profile = [string]$selectedHarness.Profile
            $status.Text = "Opening $profile in Wave..."
            if (Start-HermesTextExecutor -ProfileName $profile -ImprovedPrompt $text -Config $cfg) {
                Write-SnapitLog "focus prompt dispatched: $profile"
                $win.Close()
            } else {
                $status.Text = 'Could not open the selected Hermes harness.'
            }
        }.GetNewClosure()

        $doSaveDraft = {
            $text = $box.Text.Trim()
            $selectedHarness = $combo.SelectedItem
            if (-not $text) { $status.Text = 'Write a prompt before saving.'; return }
            $profile = if ($selectedHarness) { [string]$selectedHarness.Profile } else { 'default' }
            try {
                $draft = Save-SnapitPromptDraft -Text $text -ProfileName $profile
                & $refreshDrafts
                if ($draftList.Items.Count -gt 0) { $draftList.SelectedIndex = 0 }
                $status.Text = "Draft saved: $([System.IO.Path]::GetFileName($draft.Path))"
            } catch {
                $status.Text = "Could not save draft: $($_.Exception.Message)"
            }
        }.GetNewClosure()

        $doSchedule = {
            $text = $box.Text.Trim()
            $selectedHarness = $combo.SelectedItem
            if (-not $text) { $status.Text = 'Write a prompt before scheduling.'; return }
            if (-not $selectedHarness) { $status.Text = 'Choose an agent / harness.'; return }
            $firstLine = @($text -split "`r?`n")[0].Trim()
            if ($firstLine.Length -gt 45) { $firstLine = $firstLine.Substring(0, 45).TrimEnd() + '...' }
            $choiceOutput = @(Show-SnapitScheduleDialog -SuggestedName ('SnapIt - ' + $firstLine))
            $choice = @($choiceOutput | Where-Object { $_ -and $_.PSObject.Properties['Schedule'] }) | Select-Object -Last 1
            if ($null -eq $choice) { $status.Text = 'Scheduling cancelled.'; return }
            $profile = [string]$selectedHarness.Profile
            $status.Text = "Creating schedule for $profile..."
            $result = New-SnapitScheduledTask -Text $text -Schedule ([string]$choice.Schedule) -ProfileName $profile -Name ([string]$choice.Name)
            if ($result.Ok) {
                Write-SnapitLog "focus prompt scheduled: $profile"
                $win.Close()
            } else {
                $status.Text = "Could not schedule task: $($result.Error)"
            }
        }.GetNewClosure()

        $improveButton.Add_Click($doImprove)
        $saveButton.Add_Click($doSaveDraft)
        $scheduleButton.Add_Click($doSchedule)
        $sendButton.Add_Click($doSend)
        $voiceButton.Add_Click(({
            $status.Text = 'Opening secure ElevenLabs voice call...'
            $voiceResult = Open-SnapitVoiceCall -Config $cfg -RootPath $script:SnapitRoot
            if ($voiceResult.Ok) { $win.Close() }
            else { $status.Text = "Voice call unavailable: $($voiceResult.Error)" }
        }).GetNewClosure())
        $cancelButton.Add_Click(({ $win.Close() }).GetNewClosure())
        $win.Add_PreviewKeyDown(({
            param($sender, $event)
            if ($event.Key -eq [System.Windows.Input.Key]::Escape) { $event.Handled = $true; $win.Close(); return }
            if ($event.Key -eq [System.Windows.Input.Key]::Enter -and (($event.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0)) {
                $event.Handled = $true
                & $doSend
            }
        }).GetNewClosure())
        $win.Content = $shell
        $win.Add_ContentRendered(({
            $combo.ApplyTemplate() | Out-Null
            $editablePart = $combo.Template.FindName('PART_EditableTextBox', $combo)
            if ($null -ne $editablePart) {
                $editablePart.Background = ConvertTo-WpfBrush '#24242A'
                $editablePart.Foreground = ConvertTo-WpfBrush '#F2F0F0'
                $editablePart.BorderThickness = New-Object System.Windows.Thickness(0)
            }
            $box.Focus() | Out-Null
        }).GetNewClosure())
        Write-SnapitLog 'focus stage: show dialog'
        $win.ShowDialog() | Out-Null
    } catch {
        Write-SnapitLog "focus panel error: $($_.Exception.Message)"
        Show-SnapitMessage ("Focus panel error: " + $_.Exception.Message) -Icon 3
    } finally {
        foreach ($overlay in @($overlays)) {
            try { $overlay.Close(); $overlay.Dispose() } catch {}
        }
        $script:SnapitFocusOpen = $false
    }
}

# =====================================================================
#  ADMIN PANEL + CONFIGURED DESTINATION PICKERS
# =====================================================================
function New-SnapitAdminGrid {
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.AutoGenerateColumns = $false
    $grid.MultiSelect = $true
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.BackgroundColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
    $grid.ForeColor = [System.Drawing.Color]::FromArgb(235, 235, 238)
    $grid.GridColor = [System.Drawing.Color]::FromArgb(60, 60, 68)
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(42, 42, 48)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $grid.EnableHeadersVisualStyles = $false
    $grid.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 35)
    $grid.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(235, 235, 238)
    $grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(52, 82, 120)
    $grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    return $grid
}

function Add-SnapitAdminRowButtons {
    param($Parent, $Grid, [string]$AddText)
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $bar.Height = 44
    $bar.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $bar.Padding = New-Object System.Windows.Forms.Padding(8, 6, 0, 0)
    $add = New-Object System.Windows.Forms.Button
    $add.Text = $AddText
    $add.AutoSize = $true
    $remove = New-Object System.Windows.Forms.Button
    $remove.Text = 'Delete selected'
    $remove.AutoSize = $true
    [void]$bar.Controls.Add($add)
    [void]$bar.Controls.Add($remove)
    [void]$Parent.Controls.Add($bar)
    $add.Add_Click(({ [void]$Grid.Rows.Add($true, '', '') }).GetNewClosure())
    $remove.Add_Click(({
        foreach ($row in @($Grid.SelectedRows)) {
            if (-not $row.IsNewRow) { $Grid.Rows.Remove($row) }
        }
    }).GetNewClosure())
}

function Show-SnapitAdminPanel {
    param($Config = $null)
    if ($null -eq $Config) { $Config = Get-SnapitConfig }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'SnapIt Admin - routing, endpoints and harnesses'
    $form.Width = 940
    $form.Height = 690
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.BackColor = [System.Drawing.Color]::FromArgb(27, 27, 31)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $form.MinimizeBox = $false

    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = [System.Windows.Forms.DockStyle]::Top
    $top.Height = 112
    $top.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 8)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'SnapIt routing control'
    $title.AutoSize = $true
    $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
    $title.Location = New-Object System.Drawing.Point(16, 10)

    $modeLabel = New-Object System.Windows.Forms.Label
    $modeLabel.Text = 'Mode'
    $modeLabel.AutoSize = $true
    $modeLabel.Location = New-Object System.Drawing.Point(18, 55)
    $mode = New-Object System.Windows.Forms.ComboBox
    $mode.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$mode.Items.Add('Ask every time')
    [void]$mode.Items.Add('AUTO - camarita routes')
    $mode.Location = New-Object System.Drawing.Point(75, 51)
    $mode.Width = 210
    $routingMode = [string](Get-SnapitValue -Item $Config -Name 'routingMode' -Default 'ask')
    $mode.SelectedIndex = $(if ($routingMode -eq 'auto') { 1 } else { 0 })

    $routerLabel = New-Object System.Windows.Forms.Label
    $routerLabel.Text = 'Router profile'
    $routerLabel.AutoSize = $true
    $routerLabel.Location = New-Object System.Drawing.Point(320, 55)
    $router = New-Object System.Windows.Forms.ComboBox
    $router.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $router.Location = New-Object System.Drawing.Point(425, 51)
    $router.Width = 220
    $profiles = @(Get-HermesProfiles)
    foreach ($p in $profiles) { [void]$router.Items.Add([string]$p.Name) }
    $routerName = [string](Get-SnapitValue -Item $Config -Name 'autoRouterProfile' -Default 'camarita')
    $router.SelectedItem = $routerName
    if ($router.SelectedIndex -lt 0 -and $router.Items.Count -gt 0) { $router.SelectedIndex = 0 }

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'AUTO asks the router only to classify; the selected Hermes agent executes visibly in Wave.'
    $hint.AutoSize = $true
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(160, 190, 220)
    $hint.Location = New-Object System.Drawing.Point(18, 84)

    [void]$top.Controls.Add($title)
    [void]$top.Controls.Add($modeLabel)
    [void]$top.Controls.Add($mode)
    [void]$top.Controls.Add($routerLabel)
    [void]$top.Controls.Add($router)
    [void]$top.Controls.Add($hint)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
    $tabs.Padding = New-Object System.Drawing.Point(18, 7)

    $endpointTab = New-Object System.Windows.Forms.TabPage
    $endpointTab.Text = 'Endpoints'
    $endpointTab.BackColor = [System.Drawing.Color]::FromArgb(27, 27, 31)
    $endpointGrid = New-SnapitAdminGrid
    $epEnabled = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $epEnabled.HeaderText = 'Enabled'; $epEnabled.Width = 80
    $epName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $epName.HeaderText = 'Name'; $epName.Width = 220
    $epUrl = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $epUrl.HeaderText = 'URL'; $epUrl.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    [void]$endpointGrid.Columns.Add($epEnabled)
    [void]$endpointGrid.Columns.Add($epName)
    [void]$endpointGrid.Columns.Add($epUrl)
    foreach ($ep in @(Get-SnapitEndpoints -Config $Config -IncludeDisabled)) {
        $idx = $endpointGrid.Rows.Add($ep.Enabled, $ep.Name, $ep.Url)
        $endpointGrid.Rows[$idx].Tag = $ep.Id
    }
    [void]$endpointTab.Controls.Add($endpointGrid)
    Add-SnapitAdminRowButtons -Parent $endpointTab -Grid $endpointGrid -AddText 'Add endpoint'

    $harnessTab = New-Object System.Windows.Forms.TabPage
    $harnessTab.Text = 'Harnesses / Hermes agents'
    $harnessTab.BackColor = [System.Drawing.Color]::FromArgb(27, 27, 31)
    $harnessGrid = New-SnapitAdminGrid
    $haEnabled = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $haEnabled.HeaderText = 'Enabled'; $haEnabled.Width = 80
    $haName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $haName.HeaderText = 'Alias'; $haName.Width = 260
    $haProfile = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $haProfile.HeaderText = 'Hermes profile'; $haProfile.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    [void]$harnessGrid.Columns.Add($haEnabled)
    [void]$harnessGrid.Columns.Add($haName)
    [void]$harnessGrid.Columns.Add($haProfile)
    foreach ($ha in @(Get-SnapitHarnesses -Config $Config -IncludeDisabled)) {
        $idx = $harnessGrid.Rows.Add($ha.Enabled, $ha.Name, $ha.Profile)
        $harnessGrid.Rows[$idx].Tag = $ha.Id
    }
    [void]$harnessTab.Controls.Add($harnessGrid)
    Add-SnapitAdminRowButtons -Parent $harnessTab -Grid $harnessGrid -AddText 'Add harness'

    [void]$tabs.TabPages.Add($endpointTab)
    [void]$tabs.TabPages.Add($harnessTab)

    $bottom = New-Object System.Windows.Forms.FlowLayoutPanel
    $bottom.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $bottom.Height = 58
    $bottom.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $bottom.Padding = New-Object System.Windows.Forms.Padding(8)
    $save = New-Object System.Windows.Forms.Button
    $save.Text = 'Save changes'
    $save.Width = 125; $save.Height = 34
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Width = 90; $cancel.Height = 34
    [void]$bottom.Controls.Add($save)
    [void]$bottom.Controls.Add($cancel)

    $cancel.Add_Click(({ $form.Close() }).GetNewClosure())
    $save.Add_Click(({
        try {
            $endpointRecords = @()
            foreach ($row in @($endpointGrid.Rows)) {
                $name = [string]$row.Cells[1].Value
                $url = [string]$row.Cells[2].Value
                if (-not $name.Trim() -and -not $url.Trim()) { continue }
                $parsedUri = $null
                if (-not $name.Trim() -or -not [uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$parsedUri) -or $parsedUri.Scheme -notin @('http', 'https')) {
                    throw "Endpoint rows require a name and an http/https URL: $name"
                }
                $id = [string]$row.Tag
                if (-not $id) { $id = 'endpoint-' + [guid]::NewGuid().ToString('N').Substring(0, 10) }
                $endpointRecords += @{ id = $id; name = $name.Trim(); url = $url.Trim(); enabled = [bool]$row.Cells[0].Value }
            }

            $knownProfiles = @($profiles | ForEach-Object { [string]$_.Name })
            $harnessRecords = @()
            foreach ($row in @($harnessGrid.Rows)) {
                $name = [string]$row.Cells[1].Value
                $profile = [string]$row.Cells[2].Value
                if (-not $name.Trim() -and -not $profile.Trim()) { continue }
                if (-not $name.Trim() -or $profile -notin $knownProfiles) {
                    throw "Harness '$name' must point to an installed Hermes profile."
                }
                $id = [string]$row.Tag
                if (-not $id) { $id = 'harness-' + [guid]::NewGuid().ToString('N').Substring(0, 10) }
                $harnessRecords += @{ id = $id; name = $name.Trim(); profile = $profile.Trim(); enabled = [bool]$row.Cells[0].Value }
            }
            if ($mode.SelectedIndex -eq 1 -and @($harnessRecords | Where-Object { $_.enabled }).Count -eq 0) {
                throw 'AUTO mode needs at least one enabled harness.'
            }
            if (-not $router.SelectedItem) { throw 'Select an installed router profile.' }

            $Config['routingMode'] = $(if ($mode.SelectedIndex -eq 1) { 'auto' } else { 'ask' })
            $Config['autoRouterProfile'] = [string]$router.SelectedItem
            $Config['terminalHost'] = 'wave'
            $Config['endpoints'] = @($endpointRecords)
            $Config['harnesses'] = @($harnessRecords)
            Save-SnapitConfig $Config
            Write-SnapitLog "admin saved: mode=$($Config['routingMode']) endpoints=$($endpointRecords.Count) harnesses=$($harnessRecords.Count)"
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'SnapIt Admin', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        }
    }).GetNewClosure())

    [void]$form.Controls.Add($tabs)
    [void]$form.Controls.Add($bottom)
    [void]$form.Controls.Add($top)
    $form.AcceptButton = $save
    $form.CancelButton = $cancel
    $form.ShowDialog() | Out-Null
}

function Show-EndpointPicker {
    param($Config)
    $items = @(Get-SnapitEndpoints -Config $Config)
    if ($items.Count -eq 0) {
        Show-SnapitMessage 'No enabled endpoints. Add one from the SnapIt Admin panel.' -Icon 2
        return $null
    }
    if ($items.Count -eq 1) { return $items[0] }
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'SnapIt - choose endpoint'
    $form.Width = 650; $form.Height = 420
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $list = New-Object System.Windows.Forms.ListBox
    $list.Dock = [System.Windows.Forms.DockStyle]::Fill
    $list.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    foreach ($item in $items) { [void]$list.Items.Add(($item.Name + '  -  ' + $item.Url)) }
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Use endpoint'; $ok.Dock = [System.Windows.Forms.DockStyle]::Bottom; $ok.Height = 42
    $selected = $null
    $choose = ({
        if ($list.SelectedIndex -ge 0) { $selected = $items[$list.SelectedIndex]; $form.Close() }
    }).GetNewClosure()
    $ok.Add_Click($choose)
    $list.Add_DoubleClick($choose)
    [void]$form.Controls.Add($list)
    [void]$form.Controls.Add($ok)
    $form.ShowDialog() | Out-Null
    return $selected
}

function Show-HarnessPicker {
    param($Config)
    $items = @(Get-SnapitHarnesses -Config $Config)
    if ($items.Count -eq 0) {
        Show-SnapitMessage 'No enabled harnesses. Add one from the SnapIt Admin panel.' -Icon 2
        return $null
    }
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'SnapIt - choose Hermes harness'
    $form.Width = 650; $form.Height = 500
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $list = New-Object System.Windows.Forms.ListBox
    $list.Dock = [System.Windows.Forms.DockStyle]::Fill
    $list.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    foreach ($item in $items) { [void]$list.Items.Add(($item.Name + '  ->  ' + $item.Profile)) }
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Open agent in Wave'; $ok.Dock = [System.Windows.Forms.DockStyle]::Bottom; $ok.Height = 42
    $selected = $null
    $choose = ({
        if ($list.SelectedIndex -ge 0) { $selected = [string]$items[$list.SelectedIndex].Profile; $form.Close() }
    }).GetNewClosure()
    $ok.Add_Click($choose)
    $list.Add_DoubleClick($choose)
    [void]$form.Controls.Add($list)
    [void]$form.Controls.Add($ok)
    $form.ShowDialog() | Out-Null
    return $selected
}

# =====================================================================
#  MAIN FLOW
# =====================================================================
function Start-SnapitFlow {
    Write-SnapitLog 'flow begin'
    # Crash recovery: if the previous run left an interrupted dispatch behind
    # (resume.json) and we have not asked yet this session, offer to re-open it.
    if (-not $script:SnapitRecoveryOffered) {
        $script:SnapitRecoveryOffered = $true
        try {
            if (Show-SnapitPendingRecovery) { return }
        } catch {
            Write-SnapitLog "pending recovery failed: $($_.Exception.Message)"
        }
    }
    try {
        $cfg = Get-SnapitConfig

        $cap = Start-SnapitCapture
        if (-not $cap) { return }
        if ($null -eq $cap.Path) { return }   # cancelled

        Write-SnapitLog "capture: $($cap.Path)"

        # ---- 1) improve
        $improved = ''
        if ($cfg.improvePrompt) {
            $cfgObj = $cfg.Clone()
            $cfgObj.Remove('__path')
            $prog = Show-ImprovingWindow
            $prog.Show()
            $prog.UpdateLayout()
            $job = Start-SnapitModuleAsync -Function 'Invoke-SnapitImprove' -Named @{ ImagePath = $cap.Path; Config = $cfgObj }
            $res = Wait-SnapitAsyncUi -Job $job
            $prog.Close()
            if ($res.Ok -and $res.Value -and $res.Value.Ok) {
                $improved = [string]$res.Value.Text
                Write-SnapitLog "improved: $($improved.Length) chars"
            } else {
                Write-SnapitLog 'improver returned nothing usable; continuing with raw capture'
            }
        }
        if (-not $improved) {
            $improved = 'Task from a SnapIt capture (see attached image): inspect the capture and do what the user marked or wrote. Context: ' + $cap.Path
        }

        Invoke-SnapitDispatch -Config $cfg -CapturePath $cap.Path -Prompt $improved
    } catch {
        # Deliberately do NOT clear the pending record here: an exception means the
        # dispatch did not complete, so the next start can still recover it.
        Write-SnapitLog "flow error: $($_.Exception.Message)"
        try {
            $e = $_.Exception
            while ($e) {
                Write-SnapitLog ("  ERRCHAIN " + $e.GetType().Name + ": " + $e.Message)
                $e = $e.InnerException
            }
            Write-SnapitLog ("  STACK: " + $_.ScriptStackTrace)
            Write-SnapitLog ("  POS: " + $_.InvocationInfo.PositionMessage)
        } catch {}
        Show-SnapitMessage ("SnapIt flow error: " + $_.Exception.Message) -Icon 3
    }
}

# =====================================================================
#  DISPATCH (checkpointed: an interrupted dispatch resumes next start)
# =====================================================================
function Invoke-SnapitDispatch {
    param($Config, [string]$CapturePath, [string]$Prompt, [switch]$SkipAuto)
    $cfg = $Config

    # Persist the pending dispatch so a crash or forced close between here and
    # completion can be recovered on the next SnapIt start (resume.json).
    Save-SnapitResume -CapturePath $CapturePath -Prompt $Prompt

    try {
        # ---- 2) AUTO: camarita classifies, then the selected harness executes.
        $routingMode = [string](Get-SnapitValue -Item $cfg -Name 'routingMode' -Default 'ask')
        if (-not $SkipAuto -and $routingMode -eq 'auto') {
            $cfgRoute = $cfg.Clone()
            $cfgRoute.Remove('__path')
            $prog = New-SnapitWindow -Width 470 -Height 170 -Title 'SnapIt AUTO' -Topmost
            $routePanel = New-Object System.Windows.Controls.StackPanel
            $routePanel.Margin = New-Object System.Windows.Thickness(20)
            $routeHead = New-WpfTextBlock -Text ($script:Emo.crystal + '  camarita is routing this capture') -Size 17 -Weight 'SemiBold'
            $routeSub = New-WpfTextBlock -Text 'Classification only - the chosen agent will open visibly in Wave.' -Size 12 -Color '#9A9AA2'
            $routeSub.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
            [void]$routePanel.Children.Add($routeHead)
            [void]$routePanel.Children.Add($routeSub)
            $prog.Content = $routePanel
            $prog.Show(); $prog.UpdateLayout()
            $routeJob = Start-SnapitModuleAsync -Function 'Invoke-SnapitAutoRoute' -Named @{
                ImagePath = $CapturePath; ImprovedPrompt = $Prompt; Config = $cfgRoute
            }
            $routeResult = Wait-SnapitAsyncUi -Job $routeJob
            $prog.Close()
            if ($routeResult.Ok -and $routeResult.Value -and $routeResult.Value.Ok) {
                $profile = [string]$routeResult.Value.Profile
                Write-SnapitLog "dispatch auto -> $profile"
                $launchJob = Start-SnapitModuleAsync -Function 'Start-HermesExecutor' -Named @{
                    ProfileName = $profile; ImagePath = $CapturePath; ImprovedPrompt = $Prompt; Config = $cfgRoute
                }
                $launchResult = Wait-SnapitAsyncUi -Job $launchJob
                if ($launchResult.Ok -and $launchResult.Value) {
                    Show-SnapitMessage ("AUTO selected '" + $profile + "'.`nThe agent is now visible in Wave with the capture and request.") -Icon 1
                    Clear-SnapitResume
                } else {
                    # Launch failed: keep the pending record so it can be retried/recovered.
                    Show-SnapitMessage 'AUTO selected an agent, but Wave/Hermes could not be launched.' -Icon 3
                }
                return
            }
            Write-SnapitLog 'auto route failed; falling back to manual selection'
            Show-SnapitMessage 'AUTO could not choose a valid harness. Falling back to manual selection.' -Icon 2
        }

        # ---- 3) manual destination picker
        $pickOutput = @(Show-DestinationPicker -ImagePath $CapturePath -ImprovedText $Prompt)
        $pick = @($pickOutput | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.Contains('Choice') }) | Select-Object -Last 1
        if ($null -eq $pick -or -not $pick['Choice']) { Clear-SnapitResume; return }

        # ---- 3a) terminal -> configured harness picker -> executor
        if ($pick['Choice'] -eq 'terminal') {
            $cfgObj2 = $cfg.Clone()
            $cfgObj2.Remove('__path')
            $profile = Show-HarnessPicker -Config $cfgObj2
            if (-not $profile) { Clear-SnapitResume; return }
            Write-SnapitLog "dispatch terminal -> $profile"
            $job = Start-SnapitModuleAsync -Function 'Start-HermesExecutor' -Named @{
                ProfileName    = $profile
                ImagePath      = $CapturePath
                ImprovedPrompt = $pick['Prompt']
                Config         = $cfgObj2
            }
            $res = Wait-SnapitAsyncUi -Job $job
            if ($res.Ok -and $res.Value) {
                Show-SnapitMessage ("Agent '" + $profile + "' launched in its own terminal.`n`nThe agent received: image + improved prompt, and runs until the task is done.`nWatch the window and interrupt (Ctrl+C) if it drifts.") -Icon 1
                Clear-SnapitResume
            } else {
                # Launch failed: keep the pending record so it can be recovered later.
                Show-SnapitMessage 'Could not launch the Hermes agent. Check hermes on PATH.' -Icon 3
            }
            return
        }

        # ---- 3b) web -> prefill the DSH Web UI (no submit)
        if ($pick['Choice'] -eq 'web') {
            $cfgObj3 = $cfg.Clone()
            $cfgObj3.Remove('__path')
            $endpoint = Show-EndpointPicker -Config $cfgObj3
            if (-not $endpoint) { Clear-SnapitResume; return }
            $cfgObj3['webUrl'] = [string]$endpoint.Url
            $prog = New-SnapitWindow -Width 400 -Height 150 -Title 'SnapIt' -Topmost
            $pPanel = New-Object System.Windows.Controls.StackPanel
            $pPanel.Margin = New-Object System.Windows.Thickness(20)
            $pHead = New-WpfTextBlock -Text ($script:Emo.whale + '  opening ' + $endpoint.Name + '...') -Size 16 -Weight 'SemiBold'
            $pSub = New-WpfTextBlock -Text 'Placing the improved prompt in the composer - nothing is submitted.' -Size 12 -Color '#9A9AA2'
            $pSub.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
            $pSub.TextWrapping = [System.Windows.TextWrapping]::Wrap
            [void]$pPanel.Children.Add($pHead)
            [void]$pPanel.Children.Add($pSub)
            $prog.Content = $pPanel
            $prog.Show()
            $prog.UpdateLayout()

            $job = Start-SnapitModuleAsync -Function 'Invoke-SnapitWebPrefill' -Named @{
                Prompt = $pick['Prompt']
                Config = $cfgObj3
            }
            $res = Wait-SnapitAsyncUi -Job $job
            $prog.Close()

            $copied = $false
            try { Set-Clipboard -Value $pick['Prompt']; $copied = $true } catch {}

            $ok = $res.Ok -and $res.Value -and $res.Value.Ok
            if ($ok) {
                Show-SnapitMessage ("The DeepSeek Web UI opened with your improved prompt in the composer.`nNOTHING was submitted - review, edit and send when ready.`n(Prompt is also on your clipboard.)") -Icon 1
            } else {
                Show-SnapitMessage ("Could not auto-place the prompt in the Web UI.`nThe Web UI should be open and the prompt is on your clipboard - paste it into the composer.") -Icon 2
            }
            Clear-SnapitResume
            return
        }
    } catch {
        # Rethrow: the caller logs it. The pending record is kept for recovery.
        throw
    }
}

# =====================================================================
#  PENDING RECOVERY (interrupted capture after crash / killed process)
# =====================================================================
function Show-SnapitPendingRecovery {
    # Returns $true when an interrupted dispatch was resumed (caller stops),
    # $false when nothing was pending or the user chose to keep/discard it.
    $rec = Get-SnapitResume
    if ($null -eq $rec) { return $false }
    $capName = Split-Path ([string]$rec.capture) -Leaf
    $preview = [string]$rec.prompt
    if ($preview.Length -gt 240) { $preview = $preview.Substring(0, 240).TrimEnd() + '...' }
    Write-SnapitLog 'pending dispatch found; offering recovery'
    $text = "SnapIt found an interrupted capture from " + $rec.createdAt + ":`n`n" +
            "image : " + $capName + "`n" +
            "prompt: " + $preview + "`n`n" +
            "The previous SnapIt session ended before this task was dispatched.`n" +
            "It was kept so your work is not lost.`n`n" +
            "Yes    = re-open it now and choose where it runs`n" +
            "No     = discard this pending capture`n" +
            "Cancel = keep it (not asked again this session)"
    $answer = [System.Windows.MessageBox]::Show($text, 'SnapIt - interrupted capture', [System.Windows.MessageBoxButton]::YesNoCancel, [System.Windows.MessageBoxImage]::Warning)
    if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
        Write-SnapitLog 'pending dispatch resumed by user'
        try {
            $cfg = Get-SnapitConfig
            Invoke-SnapitDispatch -Config $cfg -CapturePath ([string]$rec.capture) -Prompt ([string]$rec.prompt) -SkipAuto
            return $true
        } catch {
            Write-SnapitLog "pending recovery failed: $($_.Exception.Message)"
            Show-SnapitMessage ("Could not re-open the pending capture: " + $_.Exception.Message) -Icon 3
            return $false
        }
    }
    if ($answer -eq [System.Windows.MessageBoxResult]::No) {
        Clear-SnapitResume
        Write-SnapitLog 'pending dispatch discarded by user'
    }
    return $false
}

# =====================================================================
#  TRAY APP (hotkey listener)
# =====================================================================
function Start-SnapitTrayApp {
    $cfg = Get-SnapitConfig

    # ---- resilience: an unhandled UI-thread exception must never kill the tray
    $script:SnapitExitRequested = $false
    try {
        # WPF .NET event: PowerShell needs the typed delegate via add_* (plain +=
        # would treat UnhandledException as a property). Keep a strong reference so
        # the delegate is not garbage-collected.
        $disp = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
        $script:SnapitUnhandledHandler = [System.Windows.Threading.DispatcherUnhandledExceptionEventHandler]{
            param($s, $e)
            try {
                Write-SnapitLog ("unhandled UI exception: " + $e.Exception.Message)
                try { Write-SnapitLog ("  STACK: " + $e.Exception.StackTrace) } catch {}
            } catch {}
            $e.Handled = $true
        }
        $disp.add_UnhandledException($script:SnapitUnhandledHandler)
    } catch {
        Write-SnapitLog "dispatcher safety net failed: $($_.Exception.Message)"
    }

    # A stale exit marker (left by an earlier manual Exit) must not stop the
    # autostart watchdog on the next login; drop it whenever the tray starts.
    try {
        $exitMarker = Join-Path (Get-SnapitHome) '.exit'
        if (Test-Path -LiteralPath $exitMarker) { Remove-Item -LiteralPath $exitMarker -Force }
    } catch {}

    # ---- crash recovery (once per session, before hotkeys arm, so a pending
    #      dispatch can never double-fire with a fresh capture)
    $script:SnapitRecoveryOffered = $true
    if (Test-SnapitResumePending) {
        try {
            Write-SnapitLog 'pending dispatch found at startup'
            Show-SnapitPendingRecovery | Out-Null
        } catch {
            Write-SnapitLog ("pending recovery at startup failed: " + $_.Exception.Message)
        }
    }

    # ---- hotkey registration
    $mods = [uint32]0
    $vk = [uint32]0
    $hotkeyOk = $false
    $hotkeyText = 'Alt+Shift+S'
    $hk = $null
    try {
        $hotkeyText = [string]$cfg.hotkey
        if (-not $hotkeyText) { $hotkeyText = 'Alt+Shift+S' }
        $parts = $hotkeyText -split '\+'
        $keyName = $parts[$parts.Count - 1]
        foreach ($i in 0..($parts.Count - 2)) {
            switch ($parts[$i].Trim().ToLower()) {
                'alt'   { $mods = $mods -bor 0x0001 }
                'ctrl'  { $mods = $mods -bor 0x0002 }
                'shift' { $mods = $mods -bor 0x0004 }
                'win'   { $mods = $mods -bor 0x0008 }
            }
        }
        $kc = New-Object System.Windows.Forms.KeysConverter
        $keyVal = $kc.ConvertFromString($keyName.Trim())
        $vk = [uint32][int]$keyVal
        if ($vk -eq 0) { $vk = [uint32][int][System.Windows.Forms.Keys]::S }

        $hk = New-Object SnapitHotkey
        $hotkeyOk = $hk.Register($mods, $vk)
    } catch {
        Write-SnapitLog "hotkey parse failed: $($_.Exception.Message)"
    }

    if (-not $hotkeyOk) {
        Show-SnapitMessage ("Could not register hotkey '" + $hotkeyText + "'.`nAnother app may own it, or the machine is elevated/not. SnapIt will keep running in the tray; use the tray menu 'Capture now'.") -Icon 2
    }

    if ($hk) {
        $hk.Add_Pressed({
            Write-SnapitLog 'hotkey pressed'
            $d = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
            $d.BeginInvoke([System.Action]{ Start-SnapitFlow }, $null) | Out-Null
        })
    }

    # ---- independent ultra-focus hotkey (Alt+Shift+A by default)
    $promptHotkeyText = [string](Get-SnapitValue -Item $cfg -Name 'promptHotkey' -Default 'Alt+Shift+A')
    if (-not $promptHotkeyText) { $promptHotkeyText = 'Alt+Shift+A' }
    $promptMods = [uint32]0
    $promptVk = [uint32]0
    $promptHotkeyOk = $false
    $hkPrompt = $null
    try {
        $promptParts = $promptHotkeyText -split '\+'
        $promptKeyName = $promptParts[$promptParts.Count - 1]
        foreach ($i in 0..($promptParts.Count - 2)) {
            switch ($promptParts[$i].Trim().ToLower()) {
                'alt'   { $promptMods = $promptMods -bor 0x0001 }
                'ctrl'  { $promptMods = $promptMods -bor 0x0002 }
                'shift' { $promptMods = $promptMods -bor 0x0004 }
                'win'   { $promptMods = $promptMods -bor 0x0008 }
            }
        }
        $promptKeyVal = $kc.ConvertFromString($promptKeyName.Trim())
        $promptVk = [uint32][int]$promptKeyVal
        if ($promptVk -eq 0) { $promptVk = [uint32][int][System.Windows.Forms.Keys]::A }
        $hkPrompt = New-Object SnapitHotkey
        $promptHotkeyOk = $hkPrompt.Register($promptMods, $promptVk)
    } catch {
        Write-SnapitLog "prompt hotkey parse failed: $($_.Exception.Message)"
    }
    if ($hkPrompt) {
        $hkPrompt.Add_Pressed({
            Write-SnapitLog 'hotkey prompt pressed'
            $d = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
            $d.BeginInvoke([System.Action]{ Show-SnapitFocusPanel }, $null) | Out-Null
        })
    }
    if (-not $promptHotkeyOk) {
        Write-SnapitLog "could not register prompt hotkey: $promptHotkeyText"
    }

    # ---- tray icon
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::FromArgb(255, 27, 27, 31))
    $brushWhite = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString('S+', $font, $brushWhite, (New-Object System.Drawing.RectangleF(0, 0, 32, 32)), $sf)
    $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())

    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = $icon
    $notify.Text = 'SnapIt - Alt+Shift+S capture | Alt+Shift+A focus'
    $notify.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $itemCapture = New-Object System.Windows.Forms.ToolStripMenuItem('Capture now  (' + $hotkeyText + ')')
    $itemFocus   = New-Object System.Windows.Forms.ToolStripMenuItem('Focus prompt  (' + $promptHotkeyText + ')')
    $itemAdmin   = New-Object System.Windows.Forms.ToolStripMenuItem('Admin panel - routes, endpoints, harnesses')
    $itemOpen    = New-Object System.Windows.Forms.ToolStripMenuItem('Open captures folder')
    $itemConfig  = New-Object System.Windows.Forms.ToolStripMenuItem('Open config.json')
    $itemExit    = New-Object System.Windows.Forms.ToolStripMenuItem('Exit SnapIt')

    $itemCapture.Add_Click({ Start-SnapitFlow })
    $itemFocus.Add_Click({ Show-SnapitFocusPanel })
    $itemAdmin.Add_Click({ Show-SnapitAdminPanel -Config (Get-SnapitConfig) })
    $itemOpen.Add_Click({ $capturesDir = Join-Path (Get-SnapitHome) 'captures'; if (-not (Test-Path $capturesDir)) { New-Item -ItemType Directory -Path $capturesDir -Force | Out-Null }; Start-Process explorer.exe -ArgumentList $capturesDir })
    $itemConfig.Add_Click({ $cfgPath = (Get-SnapitConfig).__path; if (Test-Path $cfgPath) { Start-Process notepad.exe -ArgumentList $cfgPath } })
    $itemExit.Add_Click({ $script:SnapitExitRequested = $true; try { Set-Content -Path (Join-Path (Get-SnapitHome) '.exit') -Value '' -Encoding ASCII } catch {}; $notify.Visible = $false; try { $hk.Unregister() } catch {}; try { $hkPrompt.Unregister() } catch {}; $notify.Dispose(); $icon.Dispose(); [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })

    [void]$menu.Items.Add($itemCapture)
    [void]$menu.Items.Add($itemFocus)
    [void]$menu.Items.Add($itemAdmin)
    [void]$menu.Items.Add($itemOpen)
    [void]$menu.Items.Add($itemConfig)
    $sepItem = New-Object System.Windows.Forms.ToolStripSeparator
    [void]$menu.Items.Add($sepItem)
    [void]$menu.Items.Add($itemExit)
    $notify.ContextMenuStrip = $menu

    # double click -> capture
    $notify.Add_MouseDoubleClick({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Start-SnapitFlow }
    })

    Write-SnapitLog "SnapIt running in tray. CaptureHotkey: $hotkeyText (ok=$hotkeyOk) PromptHotkey: $promptHotkeyText (ok=$promptHotkeyOk)"

    # ---- message pump (returns when the tray is asked to shut down)
    [System.Windows.Threading.Dispatcher]::Run()

    $notify.Visible = $false
    $notify.Dispose()
    try { $hk.Unregister() } catch {}
    try { $hkPrompt.Unregister() } catch {}
    if ($script:SnapitExitRequested) {
        Write-SnapitLog '=== SnapIt tray exited by user ==='
    } else {
        Write-SnapitLog '=== SnapIt tray stopped without an explicit exit; auto-restart will relaunch it ==='
    }
}

# =====================================================================
#  AUTO-RESTART (crash / unexpected dispatcher stop)
# =====================================================================
function Restart-SnapitSelf {
    # Crash guard: never relaunch more than 4 times within 30 s (crash loop).
    $guardPath = Join-Path (Get-SnapitHome) 'restart.json'
    $now = Get-Date
    $count = 1
    $window = $now
    try {
        if (Test-Path -LiteralPath $guardPath) {
            $g = Get-Content -LiteralPath $guardPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $window = [datetime]$g.window
            $count = [int]$g.count
            if (($now - $window).TotalSeconds -gt 30) { $count = 0; $window = $now }
        }
        $count++
        if ($count -gt 4) {
            Write-SnapitLog 'auto-restart aborted (4+ crashes within 30 s); not relaunching'
            try { Remove-Item -LiteralPath $guardPath -Force } catch {}
            return
        }
        @{ count = $count; window = $window.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $guardPath -Encoding UTF8
    } catch {
        Write-SnapitLog "restart guard failed: $($_.Exception.Message)"
    }

    Write-SnapitLog 'relaunching SnapIt in a fresh process'
    try {
        $scriptPath = Join-Path $script:SnapitRoot 'snapit.ps1'
        # A tiny watcher waits for this process to exit (freeing the hotkey and the
        # single-instance mutex) before starting the replacement, then disappears.
        $inner = "Start-Sleep -Milliseconds 1200; Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','$scriptPath') -WindowStyle Hidden"
        $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner))
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-EncodedCommand', $enc) -WindowStyle Hidden
    } catch {
        Write-SnapitLog ("auto-restart launch failed: " + $_.Exception.Message)
    }
}

# =====================================================================
#  ENTRY
# =====================================================================
Write-SnapitLog "=== SnapIt start (Once=$Once Admin=$Admin Focus=$Focus) ==="

# single-instance guard (autostart + manual run should not double-register)
if (-not $Once -and -not $Admin -and -not $Focus) {
    $script:SnapitMutex = New-Object System.Threading.Mutex($false, 'Local\SnapIt.SingleInstance')
    if (-not $script:SnapitMutex.WaitOne(0)) {
        Write-SnapitLog 'another SnapIt instance is already running; exiting'
        exit 0
    }
}

if ($Focus) { Show-SnapitFocusPanel }
elseif ($Admin) { Show-SnapitAdminPanel -Config (Get-SnapitConfig) }
elseif ($Once) {
    Start-SnapitFlow
    Write-SnapitLog '=== SnapIt once-flow done ==='
} else {
    $script:SnapitExitRequested = $false
    try {
        Start-SnapitTrayApp
        if (-not $script:SnapitExitRequested) {
            Write-SnapitLog 'tray ended unexpectedly; relaunching SnapIt'
            Restart-SnapitSelf
        }
    } catch {
        Write-SnapitLog ("tray crashed: " + $_.Exception.Message)
        try {
            $ec = $_.Exception
            while ($ec) {
                Write-SnapitLog ("  ERRCHAIN " + $ec.GetType().Name + ": " + $ec.Message)
                $ec = $ec.InnerException
            }
            Write-SnapitLog ("  STACK: " + $_.ScriptStackTrace)
        } catch {}
        Write-SnapitLog 'relaunching SnapIt after crash'
        Restart-SnapitSelf
    }
    if ($script:SnapitMutex) { try { $script:SnapitMutex.ReleaseMutex() } catch {} }
}
