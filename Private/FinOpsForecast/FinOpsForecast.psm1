# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

###########################################################################
# FINOPSFORECAST.PSM1
# MODULE LOADER FOR THE PRE-CREDIT FORECAST
###########################################################################
# Purpose: Extends FinOps Explorer with pre-credit forecasting and workload
#          growth analysis, reusing Explorer's authentication, storage
#          readers, private report folders, and console helpers.
#
# Reuse model:
# - FinOpsMultitool.psm1 provides the storage, export, billing scope, and
#   private-directory helpers.
# - Explorer's console and report helpers are nested inside
#   Invoke-FinOpsMultitool, so they're loaded from that script's syntax
#   tree. Loading fails if a helper is missing or defined twice, which
#   catches drift after a Toolkit sync instead of running stale copies.
###########################################################################

$multitoolRoot = Join-Path $PSScriptRoot '../FinOpsMultitool'
Import-Module (Join-Path $multitoolRoot 'FinOpsMultitool.psm1') -ErrorAction Stop

$script:ForecastSharedHelpers = @(
    'Write-FinOpsConsole', 'Get-MenuWidth', 'Test-FinOpsRichConsole', 'Move-FinOpsCursorLine', 'Read-FinOpsAnswer',
    'Protect-FinOpsExportText', 'ConvertTo-FinOpsExportCell', 'Get-FinOpsReportRoot', 'Assert-FinOpsReportPath',
    'New-FinOpsReportDirectory', 'Write-FinOpsReportFile', 'Select-Subscription'
)
$explorerScript = Join-Path $multitoolRoot 'Invoke-FinOpsMultitool.ps1'
$parseErrors = $null
$parseTokens = $null
$explorerAst = [Management.Automation.Language.Parser]::ParseFile($explorerScript, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "FinOps Explorer's launcher couldn't be parsed, so the forecast can't load its shared helpers." }
$helperDefinitions = $explorerAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $script:ForecastSharedHelpers
    }, $true)
foreach ($helperName in $script:ForecastSharedHelpers) {
    $matchingDefinitions = @($helperDefinitions | Where-Object Name -EQ $helperName)
    if ($matchingDefinitions.Count -ne 1) { throw "FinOps Explorer helper '$helperName' was found $($matchingDefinitions.Count) times; the forecast needs exactly one definition." }
    . ([scriptblock]::Create($matchingDefinitions[0].Extent.Text))
}
Remove-Variable -Name explorerAst, helperDefinitions, matchingDefinitions, parseErrors, parseTokens -ErrorAction SilentlyContinue

foreach ($file in @(
        'Forecast.Common.ps1', 'Forecast.Settings.ps1', 'Forecast.Schema.ps1', 'Forecast.Engine.ps1', 'Forecast.Backtest.ps1',
        'Forecast.Workloads.ps1', 'Forecast.Inputs.ps1', 'Forecast.Sources.ps1', 'Forecast.CostDetails.ps1', 'Forecast.Ingest.ps1', 'Forecast.Selection.ps1',
        'Forecast.Assembly.ps1', 'Forecast.Validation.ps1', 'Forecast.State.ps1', 'Forecast.Reports.ps1', 'Forecast.Html.ps1',
        'Forecast.Session.ps1', 'Forecast.Console.ps1', 'Forecast.ConsoleEdit.ps1'
    )) {
    . (Join-Path $PSScriptRoot $file)
}

Export-ModuleMember -Function 'Invoke-FinOpsForecast', 'Select-FinOpsExplorerMode'
