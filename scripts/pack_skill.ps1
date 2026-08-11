# Pack the a-share-vcp-system skill into an installable .skill file.
# Usage: powershell -ExecutionPolicy Bypass -File scripts/pack_skill.ps1
# Output: dist/a-share-vcp-system.skill (zip containing SKILL.md at top level)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$src = Join-Path $PSScriptRoot '..\skills\a-share-vcp-system'
$distDir = Join-Path $PSScriptRoot '..\dist'
$out = Join-Path $distDir 'a-share-vcp-system.skill'

if (-not (Test-Path (Join-Path $src 'SKILL.md'))) { Write-Output 'ERROR: SKILL.md not found'; exit 1 }
if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir | Out-Null }
if (Test-Path $out) { Remove-Item $out -Force }

# -Force includes hidden files (.skill-metadata.yaml); wildcard '*' alone would skip them
$files = Get-ChildItem -Force -Path $src -File
$zip = [System.IO.Compression.ZipFile]::Open($out, 'Create')
foreach ($f in $files) {
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $f.Name, 'Optimal') | Out-Null
}
$zip.Dispose()
Write-Output ('PACKED ' + $files.Count + ' files -> ' + (Resolve-Path $out).Path)
