[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Path
)

$files = if (Test-Path $Path -PathType Container) {
    Get-ChildItem -Path $Path -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
} elseif (Test-Path $Path -PathType Leaf) {
    @($Path)
} else {
    @()
}

$utf8Bom = New-Object System.Text.UTF8Encoding (1 -eq 1)
foreach ($f in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($f)
    $hasBom = ($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)
    if (-not $hasBom) {
        $content = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($f, $content, $utf8Bom)
    }
}
