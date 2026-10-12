<#
  MinerU 4.0.12 "Unsupported warp settings" fix - Windows helper.

  A degenerate OCR text box (four corners within a fraction of a pixel) makes
  `int(max(norm(...)))` zero, and the perspective warp kernel rejects a zero-size
  target with ValueError("Unsupported warp settings"). One such box fails the whole
  page window.

  This script edits the two source files in place. It matches exact source text, not
  line numbers, so it reports "already applied" instead of failing, and it is safe to
  re-run after every `uv tool upgrade mineru`.

      pwsh -File apply.ps1
      pwsh -File apply.ps1 -SitePackages "C:\path\to\site-packages"
      pwsh -File apply.ps1 -Revert

  After patching, restart the MinerU service so the parse server reloads the code:

      mineru server restart
#>
[CmdletBinding()]
param(
  [string]$SitePackages,
  [switch]$Revert
)

$ErrorActionPreference = 'Stop'
$NL = "`n"

function Test-SitePackages {
  param([string]$Path)
  if (-not $Path) { return $false }
  return (Test-Path -LiteralPath (Join-Path $Path 'mineru\model\ocr\image.py')) -and
         (Test-Path -LiteralPath (Join-Path $Path 'docvortex\foundation\_image_numeric.py'))
}

function Find-SitePackages {
  # 1. the uv tool install used by the MinerU docs on Windows
  if ($env:LOCALAPPDATA) {
    $candidate = Join-Path $env:LOCALAPPDATA 'uv\tools\mineru\Lib\site-packages'
    if (Test-SitePackages $candidate) { return $candidate }
  }
  # 2. next to the `mineru` command that is on PATH
  $cmd = Get-Command mineru -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) {
    foreach ($rel in @('..\Lib\site-packages', '..\..\Lib\site-packages')) {
      $candidate = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $cmd.Source) $rel))
      if (Test-SitePackages $candidate) { return $candidate }
    }
  }
  # 3. ask a Python that has MinerU
  foreach ($py in @('python', 'python3', 'py')) {
    try {
      $out = & $py -c "import os, mineru; print(os.path.dirname(os.path.dirname(mineru.__file__)))" 2>$null
      if ($LASTEXITCODE -eq 0 -and $out) {
        $candidate = ([string]$out).Trim()
        if (Test-SitePackages $candidate) { return $candidate }
      }
    } catch { }
  }
  return $null
}

$edits = @(
  @{
    File   = 'mineru\model\ocr\image.py'
    Before = '    img_crop_width = int(max(np.linalg.norm(points[0] - points[1]), np.linalg.norm(points[2] - points[3])))'
    After  = '    # A degenerate text box (four nearly coincident points) truncates to 0 through int(), and the{NL}    # perspective warp kernel rejects a zero-size target: clamp the crop to at least 1 pixel.{NL}    img_crop_width = max(1, int(max(np.linalg.norm(points[0] - points[1]), np.linalg.norm(points[2] - points[3]))))'
    AppliedMark   = 'img_crop_width = max(1, int('
    PristineMark  = 'img_crop_width = int(max(np.linalg.norm('
  },
  @{
    File   = 'mineru\model\ocr\image.py'
    Before = '    img_crop_height = int(max(np.linalg.norm(points[0] - points[3]), np.linalg.norm(points[1] - points[2])))'
    After  = '    img_crop_height = max(1, int(max(np.linalg.norm(points[0] - points[3]), np.linalg.norm(points[1] - points[2]))))'
    AppliedMark   = 'img_crop_height = max(1, int('
    PristineMark  = 'img_crop_height = int(max(np.linalg.norm('
  },
  @{
    File   = 'docvortex\foundation\_image_numeric.py'
    Before = '    if interpolation not in ("nearest", "linear", "cubic") or border not in ("constant", "replicate") or min(size) <= 0:{NL}        raise ValueError("Unsupported warp settings")'
    After  = '    if interpolation not in ("nearest", "linear", "cubic") or border not in ("constant", "replicate"):{NL}        raise ValueError("Unsupported warp settings"){NL}    # A degenerate region yields a zero-size target (the caller''s int() truncation). Zero size is{NL}    # not an invalid setting: clamp to 1 pixel so one bad box cannot fail a whole page.{NL}    size = (max(1, int(size[0])), max(1, int(size[1])))'
    AppliedMark   = 'size = (max(1, int(size[0])), max(1, int(size[1])))'
    PristineMark  = ' or min(size) <= 0:'
  }
)

if (-not $SitePackages) { $SitePackages = Find-SitePackages }
if (-not (Test-SitePackages $SitePackages)) {
  throw "Could not find a site-packages with MinerU. Pass it explicitly: -SitePackages ""<path>"""
}
Write-Host "site-packages: $SitePackages"

$action = if ($Revert) { 'revert' } else { 'apply' }
$verb = if ($Revert) { 'reverted' } else { 'applied' }
$changed = 0
$skipped = 0
$encoding = New-Object System.Text.UTF8Encoding($false)

foreach ($edit in $edits) {
  $path = Join-Path $SitePackages $edit.File
  $text = [System.IO.File]::ReadAllText($path)

  if ($Revert) { $from = $edit.After.Replace('{NL}', $NL); $to = $edit.Before.Replace('{NL}', $NL); $done = $edit.PristineMark }
  else         { $from = $edit.Before.Replace('{NL}', $NL); $to = $edit.After.Replace('{NL}', $NL); $done = $edit.AppliedMark }

  if ($text.Contains($from)) {
    [System.IO.File]::WriteAllText($path, $text.Replace($from, $to), $encoding)
    $changed++
    Write-Host ("{0,-9} {1}" -f $verb, $edit.File)
  } elseif ($text.Contains($done)) {
    $skipped++
  } else {
    throw "Cannot $action $($edit.File): neither the expected original nor the patched text is present (different MinerU version?)."
  }
}

if ($changed -eq 0) {
  $state = if ($Revert) { 'reverted' } else { 'applied' }
  Write-Host "Nothing to do: $skipped edit(s) already $state."
} else {
  Write-Host "Done: $changed edit(s) $verb ($skipped already in place)."
  Write-Host "Now restart the service so the parse server reloads: mineru server restart"
}
