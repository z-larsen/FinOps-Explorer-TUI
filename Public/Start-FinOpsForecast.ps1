# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

<#
    .SYNOPSIS
    Starts the pre-credit Azure forecast and workload-growth workflow.

    .DESCRIPTION
    The Start-FinOpsForecast command opens the Setup & Review page of the FinOps Explorer
    forecast. It explains historical growth and forecasts a fiscal year (actuals to date
    plus the remaining forecast) with a central estimate and a sensitivity range, using
    pre-credit costs: CostInBillingCurrency (EA), costInBillingCurrency (MCA), or
    BilledCost (FOCUS). Marketplace and tax are excluded by default.

    Data comes from Cost Management actual-cost or FOCUS exports in Azure Storage or a
    local copy of the export container, from ActualCost reports requested live from Cost
    Management (Cost Details), or from manual monthly inputs. Nothing in Azure is created
    or changed. Settings, review decisions, cached history, and saved forecast vintages
    are kept in a private workspace under the current user's LocalApplicationData
    directory.

    Without -WorkspaceName, an interactive run signs in first and opens a workspace named
    after the signed-in tenant. A new or empty workspace starts guided setup: where the
    history comes from, how many months, and the fiscal year's first month.

    A forecast is Ready only when every required check passes: 12 or more complete
    months, verified partitions, one currency, unique keys, reconciled totals, and
    reviewed exceptions. With 3 to 11 months it's Preliminary: reported, but never saved
    as a vintage. Reports are written to a new private folder each time.

    .PARAMETER WorkspaceName
    Name of the workspace that holds settings, reviews, cache, and vintages. Use one
    workspace per customer or scope. When omitted, interactive runs use a workspace named
    after the signed-in tenant; non-interactive runs and runs with -ConfigPath use
    'default'.

    .PARAMETER WorkspacePath
    Optional local parent directory for workspaces. The default is
    FinOpsToolkit/Explorer/Forecast under LocalApplicationData. Git repositories,
    network paths, and links are rejected.

    .PARAMETER OutputPath
    Optional local parent directory for reports. Each run creates a new private folder.

    .PARAMETER ConfigPath
    Optional JSON settings file to load into the workspace before starting. Use it to
    script the source, scope, period, and assumptions for non-interactive runs.

    .PARAMETER AsOf
    Optional date the forecast is calculated as of, in UTC. The default is now.

    .PARAMETER SkipRefresh
    Non-interactive only. Uses the cached export history instead of reading the sources.

    .PARAMETER NonInteractive
    Runs without prompts: refreshes the configured sources, evaluates the forecast, writes
    reports, and saves a vintage when the forecast is Ready. When it isn't Ready, reports
    are labeled NotReady (or Preliminary for a lookback under 12 months), no vintage is
    saved, and a non-terminating error explains why. Review decisions must already be
    recorded in the workspace.

    .PARAMETER Accessible
    Uses numbered prompts without clearing the screen.

    .EXAMPLE
    Start-FinOpsForecast

    Signs in, opens the signed-in tenant's workspace, and starts guided setup if it's new.

    .EXAMPLE
    Start-FinOpsForecast -WorkspaceName contoso-fy27

    Opens the Setup & Review page for the contoso-fy27 workspace.

    .EXAMPLE
    Start-FinOpsForecast -WorkspaceName contoso-fy27 -NonInteractive

    Refreshes the configured exports, writes reports, and saves a vintage if Ready.
#>
function Start-FinOpsForecast {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Reads Azure data only; writes only to the private local workspace and report folders.')]
    param(
        [Parameter()]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
        [string]$WorkspaceName = 'default',

        [Parameter()]
        [string]$WorkspacePath,

        [Parameter()]
        [string]$OutputPath,

        [Parameter()]
        [string]$ConfigPath,

        [Parameter()]
        [datetime]$AsOf = [datetime]::UtcNow,

        [Parameter()]
        [switch]$SkipRefresh,

        [Parameter()]
        [switch]$NonInteractive,

        [Parameter()]
        [switch]$Accessible
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "The FinOps Explorer forecast requires PowerShell 7 or later. This session is PowerShell $($PSVersionTable.PSVersion). Open PowerShell 7 with 'pwsh' and run Start-FinOpsForecast again."
    }
    $forecastModule = Join-Path -Path $PSScriptRoot -ChildPath '../Private/FinOpsForecast/FinOpsForecast.psm1'
    if (-not (Test-Path -Path $forecastModule)) {
        Write-Error "FinOps Explorer forecast files not found at '$forecastModule'. The module installation may be incomplete."
        return
    }
    Import-Module $forecastModule -Force
    Invoke-FinOpsForecast @PSBoundParameters
}
