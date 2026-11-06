param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
# Mechanical ICO packaging of the existing approved app icon, not new artwork.
$image=[Drawing.Image]::FromFile($Source)
$bitmap=[Drawing.Bitmap]::new(256,256,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
$graphics=[Drawing.Graphics]::FromImage($bitmap)
$memory=[IO.MemoryStream]::new()
try {
    $graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.DrawImage($image,0,0,256,256)
    $bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png)
    $png=$memory.ToArray()
    $writer=[IO.BinaryWriter]::new([IO.File]::Create($Destination))
    try {
        $writer.Write([UInt16]0);$writer.Write([UInt16]1);$writer.Write([UInt16]1)
        1..4 | ForEach-Object { $writer.Write([byte]0) }
        $writer.Write([UInt16]1);$writer.Write([UInt16]32)
        $writer.Write([UInt32]$png.Length);$writer.Write([UInt32]22);$writer.Write($png)
    } finally { $writer.Dispose() }
} finally { $memory.Dispose();$graphics.Dispose();$bitmap.Dispose();$image.Dispose() }
