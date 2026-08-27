$ErrorActionPreference = 'Stop'

$version = $env:GITHUB_REF_NAME -replace '^v', ''
$heading = "## [$version]"
$lines = Get-Content -LiteralPath 'CHANGELOG.md' -Encoding UTF8
$start = [Array]::IndexOf($lines, ($lines | Where-Object { $_.StartsWith($heading) } | Select-Object -First 1))

if ($start -lt 0) {
    throw "CHANGELOG.md does not contain $heading"
}

$notes = [System.Collections.Generic.List[string]]::new()
for ($i = $start + 1; $i -lt $lines.Length; $i++) {
    if ($lines[$i].StartsWith('## [')) { break }
    $notes.Add($lines[$i])
}

$notesText = ($notes -join "`n").Trim()
if ([string]::IsNullOrWhiteSpace($notesText)) {
    throw "No release notes found for $version"
}

[System.IO.File]::WriteAllText(
    (Join-Path (Get-Location) 'release-notes.md'),
    $notesText + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)
