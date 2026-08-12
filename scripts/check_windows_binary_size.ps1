param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Path,
    [int]$MaximumMiB = 5
)

$file = Get-Item -LiteralPath $Path -ErrorAction Stop
$maximum = $MaximumMiB * 1MB
$actualMiB = [Math]::Round($file.Length / 1MB, 2)
Write-Host "$($file.Name): $actualMiB MiB (budget: $MaximumMiB MiB)"
if ($file.Length -gt $maximum) {
    throw "Windows executable exceeds the $MaximumMiB MiB native size budget."
}
