###########################################################################
# INVOKE-FORECASTTESTS.PS1
# RUN THE PRE-CREDIT FORECAST TEST SUITE
###########################################################################
# Purpose: Run the forecast's Pester tests with synthetic data only. No
#          Azure sign-in, network access, or real export data is used.
# Description: Runs every Tests/*.Tests.ps1 file and exits non-zero on any
# failure. The Toolkit parity test runs when -ToolkitRoot (or the
# FINOPS_TOOLKIT_ROOT environment variable) points at a FinOps Toolkit
# checkout; otherwise it's skipped. Use -Reducer PowerShell to run the whole
# suite on the PowerShell reducer instead of the compiled one.
# Prerequisites: PowerShell 7 and Pester 6.0.0.
# Usage: ./scripts/Invoke-ForecastTests.ps1 [-ToolkitRoot <path>] [-Reducer PowerShell]
###########################################################################

#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ToolkitRoot,
    [ValidateSet('Compiled', 'PowerShell')]
    [string]$Reducer = 'Compiled',
    [string]$ResultPath
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path $PSScriptRoot -Parent
if (-not (Get-Module -ListAvailable -Name Pester | Where-Object Version -GE ([version]'6.0.0'))) {
    throw 'Pester 6.0.0 or later is required. Install it with: Install-Module Pester -MinimumVersion 6.0.0 -Scope CurrentUser'
}
Import-Module Pester -MinimumVersion 6.0.0

$previousToolkit = $env:FINOPS_TOOLKIT_ROOT
$previousReducer = $env:FINOPS_FORECAST_REDUCER
try {
    if ($ToolkitRoot) { $env:FINOPS_TOOLKIT_ROOT = (Resolve-Path -LiteralPath $ToolkitRoot).Path }
    $env:FINOPS_FORECAST_REDUCER = if ($Reducer -eq 'PowerShell') { 'PowerShell' } else { $null }
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = Join-Path $repositoryRoot 'Tests'
    $configuration.Run.PassThru = $true
    $configuration.Run.Exit = $false
    $configuration.Output.Verbosity = 'Normal'
    if ($ResultPath) {
        $configuration.TestResult.Enabled = $true
        $configuration.TestResult.OutputFormat = 'NUnitXml'
        $configuration.TestResult.OutputPath = $ResultPath
    }
    $result = Invoke-Pester -Configuration $configuration
}
finally {
    $env:FINOPS_TOOLKIT_ROOT = $previousToolkit
    $env:FINOPS_FORECAST_REDUCER = $previousReducer
}

[pscustomobject]@{
    Result = $result.Result
    Passed = $result.PassedCount
    Failed = $result.FailedCount
    Skipped = $result.SkippedCount
    Reducer = $Reducer
}
if ($result.Result -ne 'Passed' -or $result.FailedCount -gt 0 -or $result.FailedContainersCount -gt 0) { exit 1 }
