###########################################################################
# TEST-TOOLKITPARITY.PS1
# COMPARE THE STANDALONE FINOPS EXPLORER TUI WITH A TOOLKIT SOURCE CHECKOUT
###########################################################################
# Purpose: Detect shared runtime drift without running scans or changing files.
# Author: Zac Larsen
# Date: September 2026
# Description: Compare the public launcher and shared runtime, allowing only
# the standalone version labels, the forecast launcher hook, the distribution
# README, and the sanitized template. The standalone forecast lives in
# Private/FinOpsForecast and Public/Start-FinOpsForecast.ps1, outside the
# compared runtime.
# Prerequisites: PowerShell 7 and a local FinOps Toolkit source checkout.
# Usage: ./scripts/Test-ToolkitParity.ps1 -ToolkitRoot <toolkit-repository>
###########################################################################

#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ToolkitRoot
)

$ErrorActionPreference = 'Stop'
$standaloneRoot = Split-Path $PSScriptRoot -Parent
$toolkitPowerShell = Join-Path $ToolkitRoot 'src/powershell'
$sourceRoot = Join-Path $toolkitPowerShell 'Private/FinOpsMultitool'
$targetRoot = Join-Path $standaloneRoot 'Private/FinOpsMultitool'
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw 'ToolkitRoot must contain src/powershell/Private/FinOpsMultitool.'
}

$exceptions = @('README.md', 'assets/skeleton.pbit')
$sourceFiles = @{}
$targetFiles = @{}
foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File) {
    $relativePath = [IO.Path]::GetRelativePath($sourceRoot, $file.FullName).Replace('\', '/')
    if ($relativePath -notin $exceptions) { $sourceFiles[$relativePath] = $file.FullName }
}
foreach ($file in Get-ChildItem -LiteralPath $targetRoot -Recurse -File) {
    $relativePath = [IO.Path]::GetRelativePath($targetRoot, $file.FullName).Replace('\', '/')
    if ($relativePath -notin $exceptions) { $targetFiles[$relativePath] = $file.FullName }
}

$differences = [Collections.Generic.List[string]]::new()
foreach ($relativePath in @($sourceFiles.Keys + $targetFiles.Keys | Sort-Object -Unique)) {
    if (-not $sourceFiles.ContainsKey($relativePath) -or -not $targetFiles.ContainsKey($relativePath)) {
        $differences.Add("Missing or extra runtime file: $relativePath")
        continue
    }
    if ($relativePath -eq 'Invoke-FinOpsMultitool.ps1') {
        $sourceText = [IO.File]::ReadAllText($sourceFiles[$relativePath]).Replace("`r`n", "`n")
        $targetText = [IO.File]::ReadAllText($targetFiles[$relativePath]).Replace("`r`n", "`n")
        $overlays = @(
            @{
                Text = "    . (Join-Path `$PSScriptRoot '../Get-VersionNumber.ps1')`n`n"
                Replacement = ''
            }
            @{
                Text = '            $reportVersion = [System.Net.WebUtility]::HtmlEncode("v$(Get-VersionNumber)")' + "`n"
                Replacement = ''
            }
            @{
                Text = '<title>FinOps Explorer TUI Report $reportVersion &mdash; $timestamp</title>'
                Replacement = '<title>FinOps Explorer TUI Report &mdash; $timestamp</title>'
            }
            @{
                Text = '<p class="meta">Version: $reportVersion &nbsp;|&nbsp; Generated:'
                Replacement = '<p class="meta">Generated:'
            }
            # Standalone only: the launcher hook that offers the pre-credit forecast.
            @{
                Text = (@(
                        '    # Standalone forecast: offer the pre-credit forecast before the scan workflow.'
                        '    $forecastModule = Join-Path $PSScriptRoot ''../FinOpsForecast/FinOpsForecast.psm1'''
                        '    if (-not $NonInteractive -and -not $Scans -and -not $DataSource -and (Test-Path -LiteralPath $forecastModule)) {'
                        '        Import-Module $forecastModule -Force'
                        '        if ((Select-FinOpsExplorerMode -Accessible:$Accessible) -eq ''Forecast'') {'
                        '            Invoke-FinOpsForecast -OutputPath $OutputPath -Accessible:$Accessible'
                        '            return'
                        '        }'
                        '    }'
                        ''
                        ''
                    ) -join "`n")
                Replacement = ''
            }
        )
        foreach ($overlay in $overlays) {
            if ([regex]::Matches($targetText, [regex]::Escape($overlay.Text)).Count -ne 1) {
                throw 'A standalone overlay changed; review the parity exceptions.'
            }
            $targetText = $targetText.Replace($overlay.Text, $overlay.Replacement)
        }
        if ($sourceText -cne $targetText) { $differences.Add("Runtime content differs: $relativePath") }
    }
    elseif ((Get-FileHash -LiteralPath $sourceFiles[$relativePath]).Hash -ne (Get-FileHash -LiteralPath $targetFiles[$relativePath]).Hash) {
        $differences.Add("Runtime content differs: $relativePath")
    }
}

$entryPoints = @('Public/Start-FinOpsExplorer.ps1', 'Public/Start-FinOpsMultitool.ps1')
foreach ($entryPoint in $entryPoints) {
    $sourceEntry = Join-Path $toolkitPowerShell $entryPoint
    $targetEntry = Join-Path $standaloneRoot $entryPoint
    if ((Get-FileHash -LiteralPath $sourceEntry).Hash -ne (Get-FileHash -LiteralPath $targetEntry).Hash) {
        $differences.Add("Public launcher differs: $entryPoint")
    }
}
if ($differences.Count -gt 0) { throw ($differences -join [Environment]::NewLine) }

[pscustomobject]@{
    Result = 'Passed'
    RuntimeFilesCompared = $sourceFiles.Count
    PublicLaunchers = 'Identical'
    VersionOverlays = 4
    ForecastHook = 'Present'
    ExcludedDistributionFiles = $exceptions
}