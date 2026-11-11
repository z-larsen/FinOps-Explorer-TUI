# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers that write only the private local forecast workspace; nothing in Azure changes.')]
param()

###########################################################################
# FORECAST.GUIDED.PS1
# GUIDED SETUP: SIGN IN, PICK A SOURCE AND A RANGE, REFRESH
###########################################################################
# The Setup & Review page exposes every setting. Guided setup asks only
# what a first forecast needs:
#   1. the tenant and subscriptions, through Explorer's own sign-in;
#   2. where the history comes from: live Cost Details reports, exports,
#      or monthly totals typed in;
#   3. how many months of history (fewer than 12 is Preliminary);
#   4. the fiscal year's first month, so the history also reaches any
#      fiscal-year months before the lookback window.
# Live sources follow the forecast period (fromMonth Auto), so changing the
# lookback or fiscal year later changes what the next refresh reads. Setup
# saves those settings, keeps everything else (assumptions, scheduled
# items, workloads, reviews, saved forecasts), and offers to refresh.
###########################################################################

# Up to this many subscriptions are read one by one; beyond it, the billing
# account that owns them is offered so there's one set of reports.
$script:ForecastGuidedSubscriptionLimit = 3

function ConvertTo-ForecastWorkspaceName {
    # Lowercase letters, digits, and dashes from a tenant name or domain, or
    # $null when nothing usable is left.
    param([AllowNull()][string]$Text)
    $slug = ([string]$Text).Trim().ToLowerInvariant() -replace '\.onmicrosoft\.com$', '' -replace '[^a-z0-9]+', '-'
    $slug = $slug.Trim('-')
    if ($slug.Length -gt 55) { $slug = $slug.Substring(0, 55).Trim('-') }
    if ($slug -notmatch '^[a-z0-9][a-z0-9-]*\z') { return $null }
    return $slug
}

function Get-ForecastTenantWorkspaceName {
    # The tenant's default domain, which belongs to that tenant alone, so two
    # tenants with the same display name never share a workspace and the
    # tenant ID isn't shown. Without a domain, the tenant's name plus a short
    # hash of its ID.
    param([Parameter(Mandatory)][string]$TenantId)
    $tenant = $null
    try { $tenant = @(Get-AzTenant -TenantId $TenantId -ErrorAction Stop -WarningAction SilentlyContinue)[0] }
    catch { Write-Verbose "The tenant's name isn't available: $($_.Exception.Message)" }
    $domain = [string]$tenant.DefaultDomain
    if ([string]::IsNullOrWhiteSpace($domain)) { $domain = [string]@($tenant.Domains | Where-Object { $_ })[0] }
    $slug = ConvertTo-ForecastWorkspaceName -Text $domain
    if ($slug) { return $slug }
    $name = ConvertTo-ForecastWorkspaceName -Text ([string]$tenant.Name)
    return "$(if ($name) { $name } else { 'tenant' })-$(Get-ForecastHash -Text $TenantId.Trim().ToLowerInvariant() -Length 8)"
}

function Test-ForecastWorkspaceConfigured {
    # A workspace is set up once it has a source, or uses manual inputs.
    param([Parameter(Mandatory)][string]$Root)
    $loaded = Read-ForecastStateJson -Root $Root -RelativePath 'settings.json'
    if (-not $loaded) { return $false }
    $settings = ConvertTo-ForecastSettings -Loaded $loaded
    return $settings.dataMode -eq 'Manual' -or @($settings.sources).Count -gt 0
}

function Open-ForecastTenantWorkspace {
    # Signs in, then opens the signed-in tenant's workspace. A new or empty
    # workspace goes straight to guided setup. Returns the workspace root, or
    # $null when no subscription was selected.
    param([string]$WorkspacePath, [datetime]$AsOf = [datetime]::UtcNow)
    Clear-ForecastScreen
    Write-ForecastHeading -Title 'Pre-credit forecast: sign in'
    $subscriptions = @(Select-Subscription | Where-Object { $_ })
    if ($subscriptions.Count -eq 0) {
        Write-FinOpsConsole '  No subscriptions were selected, so the forecast wasn''t opened.' -ForegroundColor Yellow
        Wait-ForecastKey
        return $null
    }
    $tenantId = [string](Get-AzContext -ErrorAction Stop).Tenant.Id
    $suggested = Get-ForecastTenantWorkspaceName -TenantId $tenantId
    $name = $suggested
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $answer = ([string](Read-ForecastText -Prompt 'Workspace for this tenant' -Default $suggested)).Trim()
        if ($answer -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z') { $name = $answer; break }
        Write-FinOpsConsole '  Use 1 to 64 letters, digits, dots, dashes, or underscores.' -ForegroundColor Yellow
    }
    $root = Get-ForecastWorkspaceRoot -WorkspaceName $name -WorkspacePath $WorkspacePath
    if (Test-ForecastWorkspaceConfigured -Root $root) {
        $settings = Get-ForecastStoredSettings -Root $root
        $described = if ($settings.dataMode -eq 'Manual') { 'manual inputs' } else { "$(@($settings.sources).Count) source(s)" }
        Write-FinOpsConsole "  Workspace '$name' is already set up with $described." -ForegroundColor Cyan
        Write-FinOpsConsole '    1  Open it'
        Write-FinOpsConsole '    2  Set it up again (assumptions, reviews, and saved forecasts are kept)'
        if ((Read-ForecastChoice -Prompt 'Choose' -Valid @('1', '2') -Default '1') -ne '2') { return $root }
    }
    $null = Start-ForecastGuidedSetup -Root $root -Subscriptions $subscriptions -AsOf $AsOf
    return $root
}

function Get-ForecastGuidedScopeLabel {
    param([Parameter(Mandatory)][object[]]$Subscriptions)
    $first = ConvertTo-ForecastSafeText ([string]$Subscriptions[0].Name) 60
    if ($Subscriptions.Count -eq 1) { return $first }
    return "$first and $($Subscriptions.Count - 1) more subscription$(if ($Subscriptions.Count -gt 2) { 's' })"
}

function Get-ForecastGuidedLiveSources {
    # Cost Details sources that follow the forecast period (fromMonth Auto):
    # one per subscription for a few, otherwise the EA or MCA billing account
    # that owns all of them when the signed-in account can confirm it.
    param(
        [Parameter(Mandatory)][object[]]$Subscriptions,
        [Parameter(Mandatory)][string]$EarliestMonth,
        [int]$GraceDays = 3,
        [Parameter(Mandatory)][datetime]$AsOf
    )
    $lastEligible = Get-ForecastLastEligibleMonth -AsOf $AsOf -GraceDays $GraceDays
    $reachable = Get-ForecastCostDetailsMonths -Source ([pscustomobject]@{ fromMonth = ''; toMonth = '' }) -Now $AsOf
    $earliest = if (@($reachable).Count) { [string]@($reachable)[0].Month } else { $EarliestMonth }
    if ([string]::CompareOrdinal($EarliestMonth, $earliest) -lt 0) {
        Write-FinOpsConsole "  Cost Management can't return $EarliestMonth anymore; it reaches back to $earliest. That month shows as missing until $(Add-ForecastMonth -MonthKey $lastEligible -Count 1) is final, a few days after it ends." -ForegroundColor Yellow
    }

    $scopes = [Collections.Generic.List[object]]::new()
    if ($Subscriptions.Count -gt $script:ForecastGuidedSubscriptionLimit) {
        Write-FinOpsConsole "  Looking for the billing account that owns these $($Subscriptions.Count) subscriptions..." -ForegroundColor DarkGray
        $accounts = Get-ForecastCostDetailsBillingScopes -Subscriptions $Subscriptions
        $accounts = @($accounts)
        if ($accounts.Count) {
            Write-FinOpsConsole "  A billing account needs one set of reports for all $($Subscriptions.Count) subscriptions; reading each subscription needs $($Subscriptions.Count)." -ForegroundColor DarkGray
            for ($i = 0; $i -lt $accounts.Count; $i++) { Write-FinOpsConsole "    $($i + 1)  $($accounts[$i].Name) ($($accounts[$i].Agreement) billing account)" }
            Write-FinOpsConsole '    S  Each subscription separately'
            $pick = Read-ForecastChoice -Prompt 'Read at' -Valid (@(1..$accounts.Count | ForEach-Object { [string]$_ }) + 'S') -Default '1'
            if ($pick -and $pick -ne 'S') {
                $account = $accounts[[int]$pick - 1]
                $scopes.Add([pscustomobject]@{ Scope = $account.Scope; Label = "$($account.Name) (live)"; Agreement = $account.Agreement; ChunkDays = 7 })
            }
        }
        else { Write-FinOpsConsole "  No single EA or MCA billing account owns all $($Subscriptions.Count) subscriptions (or this sign-in can't confirm it), so each subscription is read separately." -ForegroundColor Yellow }
    }
    if ($scopes.Count -eq 0) {
        # A subscription's month usually fits one report.
        foreach ($subscription in $Subscriptions) { $scopes.Add([pscustomobject]@{ Scope = "/subscriptions/$($subscription.Id)"; Label = "$(ConvertTo-ForecastSafeText ([string]$subscription.Name) 60) (live)"; Agreement = 'Auto'; ChunkDays = 31 }) }
    }

    $sources = [Collections.Generic.List[object]]::new()
    foreach ($entry in $scopes) {
        $scope = $null
        try { $scope = Get-ForecastCostDetailsScope -Scope $entry.Scope } catch { Write-FinOpsConsole "  Skipped $($entry.Label): $($_.Exception.Message)" -ForegroundColor Yellow; continue }
        # A stable ID per scope lets a repeated setup reuse the months already read.
        $source = [pscustomobject]@{
            id = 'live-' + (Get-ForecastHash -Text $scope.Key -Length 12); kind = 'CostDetails'; label = $entry.Label; scope = $scope.Path
            chunkDays = $entry.ChunkDays; fromMonth = 'Auto'; toMonth = ''; storageResourceId = ''; container = ''; prefix = ''; path = ''; agreement = $entry.Agreement
        }
        if (Test-ForecastSourceShown -Source $source) { $sources.Add($source) }
    }
    return , $sources.ToArray()
}

function Get-ForecastGuidedExportSources {
    param([Parameter(Mandatory)][object[]]$Subscriptions)
    Write-FinOpsConsole ''
    Write-FinOpsConsole '  Where are the exports?' -ForegroundColor White
    Write-FinOpsConsole '    1  Find them for these subscriptions and the scopes above them'
    Write-FinOpsConsole '    2  A storage account I''ll name'
    Write-FinOpsConsole '    3  A local folder with a copy of the exports'
    $found = switch (Read-ForecastChoice -Prompt 'Choose' -Valid @('1', '2', '3') -Default '1') {
        '1' { Select-ForecastDiscoveredSources -Subscriptions $Subscriptions }
        '2' { Read-ForecastStorageSource }
        '3' { Read-ForecastLocalSource }
    }
    return , @($found | Where-Object { $_ })
}

function Get-ForecastGuidedRequestCount {
    # Report requests a first refresh of these Cost Details sources makes.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sources, [Parameter(Mandatory)][datetime]$AsOf, [string]$EarliestMonth)
    $count = 0
    foreach ($source in @($Sources | Where-Object { [string]$_.kind -eq 'CostDetails' })) {
        $runs = Get-ForecastCostDetailsRuns -Source $source -Now $AsOf -EarliestMonth $EarliestMonth
        foreach ($run in @($runs)) { $count += @($run.Parts).Count }
    }
    return $count
}

function Start-ForecastGuidedSetup {
    # Asks where the history comes from and how many months to use, saves the
    # settings, and offers to refresh. Returns $true when settings were saved.
    param([Parameter(Mandatory)][string]$Root, [object[]]$Subscriptions, [datetime]$AsOf = [datetime]::UtcNow)
    Clear-ForecastScreen
    Write-ForecastHeading -Title 'Guided forecast setup'
    $Subscriptions = @($Subscriptions | Where-Object { $_ })
    if ($Subscriptions.Count -eq 0) {
        $Subscriptions = @(Select-Subscription | Where-Object { $_ })
        if ($Subscriptions.Count -eq 0) {
            Write-FinOpsConsole '  No subscriptions were selected, so nothing was set up.' -ForegroundColor Yellow
            Wait-ForecastKey
            return $false
        }
    }
    $settings = Get-ForecastStoredSettings -Root $Root
    $label = Get-ForecastGuidedScopeLabel -Subscriptions $Subscriptions
    Write-FinOpsConsole "  Forecasting: $label" -ForegroundColor Cyan
    Write-FinOpsConsole ''
    Write-FinOpsConsole '  Where should the cost history come from?' -ForegroundColor White
    Write-FinOpsConsole '    1  Live from Cost Management, with this sign-in (no exports needed)'
    Write-FinOpsConsole '    2  Cost Management exports (find them, a storage account, or a local folder)'
    Write-FinOpsConsole '    3  Monthly totals you enter yourself'
    $kind = Read-ForecastChoice -Prompt 'Choose' -Valid @('1', '2', '3') -Default '1'
    if (-not $kind) { return $false }

    $maximum = if ($kind -eq '1') { $script:ForecastReadyMonths } else { 36 }
    Write-FinOpsConsole "  $($script:ForecastReadyMonths) months can give a Ready forecast; $($script:ForecastMinimumLookbackMonths) to $($script:ForecastReadyMonths - 1) give a Preliminary one.$(if ($kind -eq '1') { ' Cost Management reaches back 12 months.' })" -ForegroundColor DarkGray
    $months = Read-ForecastInteger -Prompt 'Months of history' -Default $script:ForecastReadyMonths -Minimum $script:ForecastMinimumLookbackMonths -Maximum $maximum
    $fiscal = Read-ForecastInteger -Prompt 'Fiscal year starts in month' -Default $settings.period.fiscalYearStartMonth -Minimum 1 -Maximum 12
    $settings.period.lookbackMonths = $months
    $settings.period.windowEnd = 'Auto'
    $settings.period.fiscalYearStartMonth = $fiscal
    # Fiscal-year months before the lookback window are actuals in the
    # year's total, so the history has to reach them too.
    $earliest = Get-ForecastFirstNeededMonth -Settings $settings -AsOf $AsOf
    $windowFirst = Add-ForecastMonth -MonthKey (Get-ForecastLastEligibleMonth -AsOf $AsOf -GraceDays ([int]$settings.period.graceDays)) -Count (1 - $months)
    if ([string]::CompareOrdinal($earliest, $windowFirst) -lt 0) {
        Write-FinOpsConsole "  The fiscal year started in $earliest, before the $months-month lookback, so the history reaches back to $earliest for the year's actuals." -ForegroundColor DarkGray
    }

    $sources = @()
    if ($kind -eq '1') {
        $sources = Get-ForecastGuidedLiveSources -Subscriptions $Subscriptions -EarliestMonth $earliest -GraceDays ([int]$settings.period.graceDays) -AsOf $AsOf
        $sources = @($sources)
    }
    elseif ($kind -eq '2') {
        $sources = Get-ForecastGuidedExportSources -Subscriptions $Subscriptions
        $sources = @($sources)
    }
    if ($kind -ne '3' -and $sources.Count -eq 0) {
        Write-FinOpsConsole '  No source was set up, so nothing was changed.' -ForegroundColor Yellow
        Wait-ForecastKey
        return $false
    }

    $settings.dataMode = if ($kind -eq '3') { 'Manual' } else { 'Exports' }
    if ($kind -ne '3') { $settings.sources = $sources }
    $settings.scope.kind = 'Subscriptions'
    $settings.scope.subscriptionIds = @($Subscriptions | ForEach-Object { [string]$_.Id })
    $settings.scope.label = $label
    $settings.method.minimumRetained = Get-ForecastDefaultMinimumRetained -LookbackMonths $months
    Save-ForecastSettingsWithFeedback -Root $Root -Settings $settings
    if ($months -lt $script:ForecastReadyMonths) { Write-FinOpsConsole "  With $months months, the forecast will be Preliminary." -ForegroundColor Yellow }

    if ($kind -eq '3') {
        Write-FinOpsConsole "  Press I on the review page to enter the monthly totals from $earliest on." -ForegroundColor Cyan
        Wait-ForecastKey
        return $true
    }
    if ($kind -eq '1') {
        $requests = Get-ForecastGuidedRequestCount -Sources $sources -AsOf $AsOf -EarliestMonth $earliest
        Write-FinOpsConsole "  The first refresh asks Cost Management for $requests report$(if ($requests -ne 1) { 's' }). Each takes from a few seconds to a few minutes; later refreshes only ask for recent months." -ForegroundColor DarkGray
    }
    if (Read-ForecastYesNo -Prompt 'Refresh now' -Default $true) { Invoke-ForecastConsoleRefresh -Root $Root }
    return $true
}
