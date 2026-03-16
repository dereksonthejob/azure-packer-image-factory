<#
.SYNOPSIS
  Post-update patch report generator. Runs AFTER both windows-update provisioner passes.
  Diffs pre vs post hotfix state, formats a structured markdown patch report, and writes
  it to C:\PatchReport\patch-report.md for upload as a build artifact.
#>

$ErrorActionPreference = "SilentlyContinue"
$ReportDir = "C:\PatchReport"
$ReportFile = "$ReportDir\patch-report.md"
$Sep = "─" * 60

function fmt-date($d) {
    if ($d -and $d -ne [datetime]::MinValue) { $d.ToString("MMM d, yyyy") } else { "—" }
}

# ── Load source image metadata ─────────────────────────────────────────────────
$meta = @{ Publisher="unknown"; Offer="unknown"; SKU="unknown"; Version="unknown"; MSPatchDate="unknown" }
if (Test-Path "$ReportDir\source-image-metadata.json") {
    try { $meta = Get-Content "$ReportDir\source-image-metadata.json" | ConvertFrom-Json } catch {}
}

# ── Load pre-update hotfixes ───────────────────────────────────────────────────
$preIds = @{}
if (Test-Path "$ReportDir\pre-update-hotfixes.csv") {
    Import-Csv "$ReportDir\pre-update-hotfixes.csv" | ForEach-Object { $preIds[$_.HotFixID] = $_ }
}

# ── Get current (post-update) hotfixes ────────────────────────────────────────
$postHotfixes = Get-HotFix | Sort-Object -Property InstalledOn -Descending

# ── Diff: newly applied by our WU provisioner passes ─────────────────────────
$newPatches = $postHotfixes | Where-Object { -not $preIds.ContainsKey($_.HotFixID) }
$lastNewPatch = ($newPatches | Sort-Object InstalledOn -Descending | Select-Object -First 1).InstalledOn

# ── Build report ──────────────────────────────────────────────────────────────
$lines = @()
$lines += "# Windows Patch Report"
$lines += "Generated: $(Get-Date -Format 'u')"
$lines += ""
$lines += "## Source Image Baseline"
$lines += "| Field | Value |"
$lines += "|-------|-------|"
$lines += "| Publisher | $($meta.Publisher) |"
$lines += "| Offer | $($meta.Offer) |"
$lines += "| SKU | $($meta.SKU) |"
$lines += "| Version | $($meta.Version) |"
$lines += "| **MS Last Patch Date** | **$($meta.MSPatchDate)** ← when Microsoft published this base image |"
$lines += ""
$lines += "## Pre-Update State (Hotfixes shipped in base image)"
$lines += "| KB | Type | Installed On |"
$lines += "|----|------|-------------|"
foreach ($hf in ($preIds.Values | Sort-Object { [datetime]$_.InstalledOn } -Descending)) {
    $lines += "| $($hf.HotFixID) | $($hf.Description) | $(fmt-date([datetime]$hf.InstalledOn)) |"
}
$lines += "| | **Total: $($preIds.Count) patches in base image** | |"
$lines += ""
$lines += "## Updates Applied This Build"
if ($newPatches.Count -gt 0) {
    $lines += "| KB | Type | Installed On |"
    $lines += "|----|------|-------------|"
    foreach ($hf in ($newPatches | Sort-Object InstalledOn -Descending)) {
        $lines += "| $($hf.HotFixID) | $($hf.Description) | $(fmt-date($hf.InstalledOn)) |"
    }
    $lines += "| | **$($newPatches.Count) update(s) applied** | |"
} else {
    $lines += "_No new updates were applied (base image was already fully patched)._"
}
$lines += ""
$lines += "## Post-Update State Summary"
$lines += "| Metric | Value |"
$lines += "|--------|-------|"
$lines += "| Total patches post-build | $($postHotfixes.Count) |"
$lines += "| New patches applied | $($newPatches.Count) |"
$lines += "| MS base image patch date | $($meta.MSPatchDate) |"
$lines += "| Latest patch applied | $(fmt-date($lastNewPatch)) |"
$lines += "| Build completed | $(Get-Date -Format 'u') |"

# ── Write and print ────────────────────────────────────────────────────────────
$report = $lines -join "`n"
$report | Set-Content $ReportFile -Encoding UTF8

Write-Host $Sep
Write-Host $report
Write-Host $Sep
Write-Host "Patch report written to: $ReportFile"
