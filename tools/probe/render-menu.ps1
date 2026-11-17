Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$dir = Split-Path -Parent $PSScriptRoot
. (Join-Path $dir 'dpi-aware.ps1')
. (Join-Path $dir 'menu-theme.ps1')

$menu = New-Object System.Windows.Forms.ContextMenuStrip
foreach ($spec in @(
    @{ T = 'HUAWEI Mouse CD28S-63   电量 100% 充电中'; E = $false; C = $false },
    @{ T = '打开 HUAWEI GoPlay'; E = $true; C = $false },
    @{ T = '关闭 GoPlay 时：直接退出'; E = $true; C = $false },
    @{ T = '按电量变色'; E = $true; C = $true },
    @{ T = '设置鼠标名称…'; E = $true; C = $false },
    @{ T = '开机自动启动'; E = $true; C = $true },
    @{ T = '退出'; E = $true; C = $false })) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem
    $it.Text = $spec.T
    $it.Enabled = $spec.E
    if ($spec.C) { $it.CheckOnClick = $true; $it.Checked = $true }
    [void]$menu.Items.Add($it)
}
$script:MenuStrip = $menu
Update-MenuTheme
[void]$menu.CreateControl()
$size = $menu.PreferredSize
Write-Output "preferred: $($size.Width)x$($size.Height)"
$bmp = New-Object System.Drawing.Bitmap ($size.Width + 8), ($size.Height + 8)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(30, 30, 34))
$g.Dispose()
$menu.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 4, 4, $size.Width, $size.Height))
$bmp.Save((Join-Path $dir 'preview\menu-render.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
'渲染完成'
