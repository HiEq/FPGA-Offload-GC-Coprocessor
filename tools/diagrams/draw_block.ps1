# Draw docs/images/block.png in the FOGCCC palette.
#
# Flat rectangles, square corners, orthogonal connectors, Arial Bold.
# Regenerate with:
#   powershell -ExecutionPolicy Bypass -File tools/diagrams/draw_block.ps1
param(
    [string]$Out = (Join-Path $PSScriptRoot '..\..\docs\images\block.png')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$W = 1600; $H = 1360
$bg     = [System.Drawing.ColorTranslator]::FromHtml('#ffffff')
$panel  = [System.Drawing.ColorTranslator]::FromHtml('#474747')
$inner  = [System.Drawing.ColorTranslator]::FromHtml('#262626')
$accent = [System.Drawing.ColorTranslator]::FromHtml('#007c96')
$white  = [System.Drawing.Color]::White

$bmp = New-Object System.Drawing.Bitmap $W, $H
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$g.Clear($bg)

function Font([int]$size) {
    New-Object System.Drawing.Font('Arial', [single]$size, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
}
function Fill([int]$x, [int]$y, [int]$w, [int]$h, $color) {
    $b = New-Object System.Drawing.SolidBrush $color
    $g.FillRectangle($b, $x, $y, $w, $h)
    $b.Dispose()
}
function BoxText([int]$x, [int]$y, [int]$w, [int]$h, [string[]]$lines, [int]$size) {
    $f = Font $size
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $rect = New-Object System.Drawing.RectangleF $x, $y, $w, $h
    $b = New-Object System.Drawing.SolidBrush $white
    $text = [string]::Join("`n", $lines)
    $g.DrawString($text, $f, $b, $rect, $sf)
    $b.Dispose(); $sf.Dispose(); $f.Dispose()
}
function Label([int]$x, [int]$y, [string]$text, [int]$size, $color = $white) {
    $f = Font $size
    $b = New-Object System.Drawing.SolidBrush $color
    $g.DrawString($text, $f, $b, [single]$x, [single]$y)
    $b.Dispose(); $f.Dispose()
}
function Frame([int]$x, [int]$y, [int]$w, [int]$h) {
    Fill $x $y $w $h ([System.Drawing.ColorTranslator]::FromHtml('#3d3d3d'))
    $pen = New-Object System.Drawing.Pen ([System.Drawing.ColorTranslator]::FromHtml('#6b6b6b')), 3
    $g.DrawRectangle($pen, $x, $y, $w, $h)
    $pen.Dispose()
}
function Bar([int]$x, [int]$y, [int]$w, [int]$h) { Fill $x $y $w $h $accent }

# ---------------------------------------------------------------- SoC panel
Fill 24 24 1552 820 $panel
Label 64 44 'ZYNQ 7100 SoC' 42
Frame 44 116 556 712
Frame 764 116 784 712

# PS column
$px = 64; $pw = 520; $ph = 104
Fill $px 140 $pw $ph $inner; BoxText $px 140 $pw $ph @('JamVM 8 + DaCapo','libjvm adapter (jvm-shadow)') 26
Fill $px 280 $pw $ph $inner; BoxText $px 280 $pw $ph @('fpga_gc.c driver') 28
Fill $px 420 $pw $ph $inner; BoxText $px 420 $pw $ph @('fogccc.py ctypes') 28
Fill $px 560 $pw $ph $inner; BoxText $px 560 $pw $ph @('/dev/mem map','(uncached)') 28
Label 64 770 'PS: Dual ARM Cortex-A9 | 800 MHz' 30

# PS <-> PL connectors
Bar 610 150 140 110; BoxText 610 150 140 110 @('AXI-Lite','0x43C00000','ctrl / status') 17
Bar 610 440 140 90;  BoxText 610 440 140 90  @('done/IRQ','F2P[0]') 17

# PL column: 2 x 4 module boxes
$col = @(784, 1168); $bw = 360; $bh = 104
$rows = @(140, 268, 396, 524)
$mods = @(
    @('gc_regs','regs + cmd tags'),
    @('gc_mark_engine','BFS FSM - 2 lanes'),
    @('gc_bitmapN','1M-bit - 2 banks'),
    @('gc_queue','524,288 x 20 b'),
    @('gc_freelist','free-list scan'),
    @('gc_dirty_fifo','incr. source'),
    @('gc_axi_read','dual-stream 64-bit'),
    @('gc_dump','bitmap -> DDR')
)
for ($i = 0; $i -lt 8; $i++) {
    $x = $col[$i % 2]; $y = $rows[[math]::Floor($i / 2)]
    Fill $x $y $bw $bh $inner
    BoxText $x $y $bw $bh $mods[$i] 26
}
Label 784 770 'PL: Kintex-7 FPGA | FCLK0 150 MHz | gc_top' 30

# ---------------------------------------------------------------- AXI HP path (orthogonal)
Bar 240 874 30 46          # up from the DDR graph panel
Bar 240 874 760 30         # horizontal run under the SoC
Bar 970 844 30 30          # up into the PL panel
BoxText 400 870 400 30 @('AXI HP 64-bit single-beat') 18

# ---------------------------------------------------------------- bottom row
$by = 920; $bh2 = 420

# DDR3 graph
Fill 24 $by 560 $bh2 $panel
Fill 40 940 528 110 $inner; BoxText 40 940 528 110 @('0x1E000000','64 MiB Object Graph') 24
for ($r = 0; $r -lt 6; $r++) {
    for ($c = 0; $c -lt 12; $c++) {
        Fill (64 + $c * 40) (1090 + $r * 30) 30 20 $accent
    }
}
Label 40 1270 'DDR3 Memory' 30

# UART/JTAG bar
Fill 620 $by 110 $bh2 $accent
$state = $g.Save()
$g.TranslateTransform(675, ($by + $bh2 / 2))
$g.RotateTransform(-90)
$f = Font 30; $b = New-Object System.Drawing.SolidBrush $white
$sf = New-Object System.Drawing.StringFormat
$sf.Alignment = [System.Drawing.StringAlignment]::Center
$g.DrawString('UART / JTAG', $f, $b, [single]0, [single]-20, $sf)
$b.Dispose(); $f.Dispose(); $sf.Dispose()
$g.Restore($state)

# PC
Fill 780 $by 796 $bh2 $panel; BoxText 780 $by 796 $bh2 @('PC') 44

# links: DDR -> UART -> PC (orthogonal)
Bar 584 1120 36 40
Bar 730 1120 50 40

$g.Dispose()
$dir = Split-Path -Parent $Out
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "wrote $Out"
