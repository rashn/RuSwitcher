param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$images = @(
    @{ Size = 16;  Path = 'macos/Assets.xcassets/AppIcon.appiconset/icon_16.png' },
    @{ Size = 32;  Path = 'macos/Assets.xcassets/AppIcon.appiconset/icon_32.png' },
    @{ Size = 64;  Path = 'macos/Assets.xcassets/AppIcon.appiconset/icon_64.png' },
    @{ Size = 128; Path = 'macos/Assets.xcassets/AppIcon.appiconset/icon_128.png' },
    @{ Size = 256; Path = 'macos/Assets.xcassets/AppIcon.appiconset/icon_256.png' }
)

$entries = foreach ($image in $images) {
    $path = Join-Path $RepositoryRoot $image.Path
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing icon source: $path" }
    [pscustomobject]@{ Size = $image.Size; Bytes = [IO.File]::ReadAllBytes($path) }
}

$destination = Join-Path $RepositoryRoot 'windows/src/RuSwitcher.Win/Assets/RuSwitcher.ico'
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
$stream = [IO.File]::Create($destination)
$writer = [IO.BinaryWriter]::new($stream)
try {
    $writer.Write([uint16]0) # reserved
    $writer.Write([uint16]1) # icon
    $writer.Write([uint16]$entries.Count)

    $offset = 6 + (16 * $entries.Count)
    foreach ($entry in $entries) {
        $dimension = if ($entry.Size -eq 256) { 0 } else { $entry.Size }
        $writer.Write([byte]$dimension)
        $writer.Write([byte]$dimension)
        $writer.Write([byte]0) # palette
        $writer.Write([byte]0) # reserved
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$entry.Bytes.Length)
        $writer.Write([uint32]$offset)
        $offset += $entry.Bytes.Length
    }
    foreach ($entry in $entries) { $writer.Write($entry.Bytes) }
}
finally {
    $writer.Dispose()
    $stream.Dispose()
}

Write-Output $destination
