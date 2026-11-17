#requires -Version 5.1
# 菜单跟随系统浅色/深色主题 + 系统强调色；勾选框自己绘制，去掉默认的蓝色边框。
# 由 HuaweiMouseTray.ps1 点源引入；主脚本需先把菜单赋给 $script:MenuStrip。

Add-Type -ReferencedAssemblies 'System.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll' -TypeDefinition @'
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public class ThemeColorTable : ProfessionalColorTable
{
    private readonly bool dark;
    private readonly Color accent;

    public ThemeColorTable(bool dark, Color accent)
    {
        this.dark = dark;
        this.accent = accent;
    }

    public static Color Mix(Color a, Color b, double t)
    {
        return Color.FromArgb(
            (int)(a.R + (b.R - a.R) * t),
            (int)(a.G + (b.G - a.G) * t),
            (int)(a.B + (b.B - a.B) * t));
    }

    public override Color ToolStripDropDownBackground { get { return dark ? Color.FromArgb(43, 43, 43) : Color.FromArgb(249, 249, 249); } }
    public override Color ImageMarginGradientBegin { get { return ToolStripDropDownBackground; } }
    public override Color ImageMarginGradientMiddle { get { return ToolStripDropDownBackground; } }
    public override Color ImageMarginGradientEnd { get { return ToolStripDropDownBackground; } }
    public override Color MenuBorder { get { return dark ? Color.FromArgb(72, 72, 72) : Color.FromArgb(204, 204, 204); } }
    public override Color MenuItemSelected { get { return Mix(ToolStripDropDownBackground, accent, dark ? 0.45 : 0.28); } }
    public override Color MenuItemBorder { get { return Color.Transparent; } }
    public override Color ButtonSelectedHighlight { get { return MenuItemSelected; } }
    public override Color ButtonSelectedBorder { get { return Color.Transparent; } }
    public override Color CheckBackground { get { return accent; } }
    public override Color CheckSelectedBackground { get { return accent; } }
    public override Color CheckPressedBackground { get { return accent; } }
    public override Color SeparatorDark { get { return dark ? Color.FromArgb(76, 76, 76) : Color.FromArgb(200, 200, 200); } }
    public override Color SeparatorLight { get { return ToolStripDropDownBackground; } }
}

public class ThemeRenderer : ToolStripProfessionalRenderer
{
    private readonly ThemeColorTable table;
    private readonly Color accent;

    public ThemeRenderer(ThemeColorTable table, Color accent) : base(table)
    {
        this.table = table;
        this.accent = accent;
    }

    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
    {
        ToolStripItem item = e.Item;
        if (!item.Selected && !item.Pressed)
        {
            base.OnRenderMenuItemBackground(e);
            return;
        }
        Graphics g = e.Graphics;
        Rectangle r = new Rectangle(3, 1, item.Width - 6, item.Height - 2);
        using (SolidBrush brush = new SolidBrush(table.MenuItemSelected))
        {
            g.FillRectangle(brush, r);
        }
    }

    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Rectangle r = e.ImageRectangle;

        Rectangle box = new Rectangle(r.X + 1, r.Y + 1, r.Width - 2, r.Height - 2);
        if (box.Width < 6 || box.Height < 6) { return; }

        using (GraphicsPath path = RoundedRect(box, 3))
        using (SolidBrush brush = new SolidBrush(accent))
        {
            g.FillPath(brush, path);
        }

        using (Pen pen = new Pen(Color.White, 1.7f))
        {
            pen.StartCap = LineCap.Round;
            pen.EndCap = LineCap.Round;
            pen.LineJoin = LineJoin.Round;
            PointF[] pts = new PointF[]
            {
                new PointF(box.Left + box.Width * 0.27f, box.Top + box.Height * 0.52f),
                new PointF(box.Left + box.Width * 0.44f, box.Top + box.Height * 0.70f),
                new PointF(box.Left + box.Width * 0.75f, box.Top + box.Height * 0.31f)
            };
            g.DrawLines(pen, pts);
        }
    }

    private static GraphicsPath RoundedRect(Rectangle r, int radius)
    {
        GraphicsPath path = new GraphicsPath();
        int d = radius * 2;
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}
'@

function Test-SystemDark {
    try {
        $v = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        return ([int]$v.AppsUseLightTheme -eq 0)
    } catch {
        return $false
    }
}

function Get-SystemAccent {
    foreach ($spec in @(
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'; Name = 'AccentColorMenu' },
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'; Name = 'StartColorMenu' })) {
        try {
            $raw = (Get-ItemProperty -Path $spec.Path -Name $spec.Name -ErrorAction Stop).($spec.Name)
            $v = [uint32]$raw
            $r = [int]($v -band 0xFF)
            $g = [int](($v -shr 8) -band 0xFF)
            $b = [int](($v -shr 16) -band 0xFF)
            if (($r + $g + $b) -gt 0) { return [System.Drawing.Color]::FromArgb($r, $g, $b) }
        } catch { }
    }
    return [System.Drawing.Color]::FromArgb(0, 120, 215)
}

# 递归给菜单项上色（个性化子菜单里还有子菜单）
function Set-MenuItemsTheme {
    param($Items, $Back, $Fore, $Dim)
    foreach ($item in $Items) {
        $item.BackColor = $Back
        $item.ForeColor = if ($item.Enabled) { $Fore } else { $Dim }
        if ($item.DropDownItems.Count -gt 0) {
            $item.DropDown.BackColor = $Back
            $item.DropDown.ForeColor = $Fore
            Set-MenuItemsTheme -Items $item.DropDownItems -Back $Back -Fore $Fore -Dim $Dim
        }
    }
}

function Update-MenuTheme {
    if ($null -eq $script:MenuStrip) { return }
    $dark = Test-SystemDark
    $accent = Get-SystemAccent

    $fore = if ($dark) { [System.Drawing.Color]::FromArgb(255, 255, 255) } else { [System.Drawing.Color]::FromArgb(20, 20, 20) }
    $back = if ($dark) { [System.Drawing.Color]::FromArgb(43, 43, 43) } else { [System.Drawing.Color]::FromArgb(249, 249, 249) }
    $dim = if ($dark) { [System.Drawing.Color]::FromArgb(175, 175, 175) } else { [System.Drawing.Color]::FromArgb(110, 110, 110) }

    try {
        $table = New-Object ThemeColorTable($dark, $accent)
        $script:MenuStrip.Renderer = New-Object ThemeRenderer($table, $accent)
    } catch {
        Write-Trace ("theme renderer failed: " + $_.Exception.Message)
    }

    # 按系统缩放放大勾选框（项高跟着字号走，图片边距要手动对齐）
    $dpi = 96
    try {
        $wm = Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction Stop
        if ($null -ne $wm.AppliedDPI -and $wm.AppliedDPI -gt 0) { $dpi = [int]$wm.AppliedDPI }
    } catch { }
    $scale = [math]::Max(1.0, $dpi / 96.0)
    $boxPx = [int][math]::Round(16 * $scale)
    try {
        $script:MenuStrip.ImageScalingSize = New-Object System.Drawing.Size -ArgumentList $boxPx, $boxPx
    } catch { }

    $script:MenuStrip.BackColor = $back
    $script:MenuStrip.ForeColor = $fore
    Set-MenuItemsTheme -Items $script:MenuStrip.Items -Back $back -Fore $fore -Dim $dim
}
