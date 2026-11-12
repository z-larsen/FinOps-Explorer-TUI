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
#   2. how many months of history (fewer than 12 is Preliminary);
#   3. the fiscal year's first month, so the history also reaches any
#      fiscal-year months before the lookback window;
#   4. where the history comes from: exports, live Cost Details reports,
#      or monthly totals typed in. A screen first explains how the
#      forecast is built and how long each way of reading these months
#      takes, fastest first. H on the review page shows it again.
# Live sources follow the forecast period (fromMonth Auto), so changing the
# lookback or fiscal year later changes what the next refresh reads. Setup
# saves those settings, keeps everything else (assumptions, scheduled
# items, workloads, reviews, saved forecasts), and offers to refresh.
###########################################################################

# Up to this many subscriptions are read one by one; beyond it, the billing
# account that owns them is offered so there's one set of reports.
$script:ForecastGuidedSubscriptionLimit = 3
# Rough seconds per Cost Details report, for the time estimates. A
# subscription's monthly report took about 35 seconds on a live tenant. A
# billing account's weekly report covers every subscription, so it's
# assumed to take about a minute. Neither is a limit.
$script:ForecastSubscriptionReportSeconds = 35
$script:ForecastBillingReportSeconds = 60
# Weekly reports in a whole month, for estimating later refreshes.
$script:ForecastBillingReportsPerMonth = 5
# Exports can reach further back than Cost Details.
$script:ForecastGuidedExportMonths = 36
# The last billing-account check, so H on the review page can show it
# without asking Azure again. Guided setup always checks afresh.
$script:ForecastBillingCheck = $null
$script:ForecastGuidePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../docs/forecast.md'))

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
    # BillingCheck is a check guided setup already made; without one, the
    # billing account is looked up here.
    param(
        [Parameter(Mandatory)][object[]]$Subscriptions,
        [Parameter(Mandatory)][string]$EarliestMonth,
        [int]$GraceDays = $script:ForecastDefaultGraceDays,
        [Parameter(Mandatory)][datetime]$AsOf,
        [AllowNull()]$BillingCheck
    )
    $lastEligible = Get-ForecastLastEligibleMonth -AsOf $AsOf -GraceDays $GraceDays
    $reachable = Get-ForecastCostDetailsMonths -Source ([pscustomobject]@{ fromMonth = ''; toMonth = '' }) -Now $AsOf
    $earliest = if (@($reachable).Count) { [string]@($reachable)[0].Month } else { $EarliestMonth }
    if ([string]::CompareOrdinal($EarliestMonth, $earliest) -lt 0) {
        Write-FinOpsConsole "  Cost Management can't return $EarliestMonth anymore; it reaches back to $earliest. That month shows as missing until $(Add-ForecastMonth -MonthKey $lastEligible -Count 1) is final, a few days after it ends." -ForegroundColor Yellow
    }

    $scopes = [Collections.Generic.List[object]]::new()
    if ($Subscriptions.Count -gt $script:ForecastGuidedSubscriptionLimit) {
        if ($null -eq $BillingCheck) { $BillingCheck = Get-ForecastGuidedBillingCheck -Subscriptions $Subscriptions }
        $accounts = @($BillingCheck.Accounts | Where-Object { $_ })
        if ($accounts.Count) {
            Write-FinOpsConsole "  A billing account needs one set of reports for all $($Subscriptions.Count) subscriptions; reading each subscription needs $($Subscriptions.Count)." -ForegroundColor DarkGray
            for ($i = 0; $i -lt $accounts.Count; $i++) { Write-FinOpsConsole "    $($i + 1)  $($accounts[$i].Name) ($($accounts[$i].Agreement) billing account)" }
            Write-FinOpsConsole '    S  Each subscription separately'
            # The default matches the faster of the two in the time estimates.
            $counts = Get-ForecastLiveReportCount -EarliestMonth $EarliestMonth -AsOf $AsOf
            $billingFaster = $counts.Weekly * $script:ForecastBillingReportSeconds -le $Subscriptions.Count * $counts.Months * $script:ForecastSubscriptionReportSeconds
            $pick = Read-ForecastChoice -Prompt 'Read at' -Valid (@(1..$accounts.Count | ForEach-Object { [string]$_ }) + 'S') -Default $(if ($billingFaster) { '1' } else { 'S' })
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

function Get-ForecastGuidedRequestEstimate {
    # Report requests a first refresh of these Cost Details sources makes,
    # and roughly how long they take.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sources, [Parameter(Mandatory)][datetime]$AsOf, [string]$EarliestMonth)
    $count = 0
    $seconds = 0
    foreach ($source in @($Sources | Where-Object { [string]$_.kind -eq 'CostDetails' })) {
        $runs = Get-ForecastCostDetailsRuns -Source $source -Now $AsOf -EarliestMonth $EarliestMonth
        $parts = 0
        foreach ($run in @($runs)) { $parts += @($run.Parts).Count }
        $count += $parts
        $seconds += $parts * (Get-ForecastReportSeconds -Source $source)
    }
    return [pscustomobject]@{ Count = $count; Seconds = $seconds }
}

# -- How it works and how long it takes --------------------------------------

function ConvertTo-ForecastDurationPart {
    # Rounds to whole minutes under 15, then 5 minutes, then half hours
    # under 10 hours, then whole hours. Number 0 means under a minute.
    param([Parameter(Mandatory)][double]$Seconds)
    $minutes = [math]::Max(0, $Seconds) / 60
    if ($minutes -lt 1) { return [pscustomobject]@{ Number = 0d; Unit = 'minute' } }
    $rounded = if ($minutes -lt 15) { [math]::Round($minutes, [MidpointRounding]::AwayFromZero) } else { 5 * [math]::Round($minutes / 5, [MidpointRounding]::AwayFromZero) }
    if ($rounded -lt 60) { return [pscustomobject]@{ Number = [double]$rounded; Unit = 'minute' } }
    $hours = $minutes / 60
    $number = if ($hours -lt 10) { [math]::Round($hours * 2, [MidpointRounding]::AwayFromZero) / 2 } else { [math]::Round($hours, [MidpointRounding]::AwayFromZero) }
    return [pscustomobject]@{ Number = [double]$number; Unit = 'hour' }
}

function Format-ForecastDuration {
    # "about 20 minutes", or with UpToSeconds a range such as "about 1 to
    # 2.5 hours".
    param([Parameter(Mandatory)][double]$Seconds, [double]$UpToSeconds = -1)
    $number = { param($Part) $Part.Number.ToString('0.#', $script:ForecastInvariant) }
    $unit = { param($Part) "$($Part.Unit)$(if ($Part.Number -ne 1) { 's' })" }
    $low = ConvertTo-ForecastDurationPart -Seconds $Seconds
    $lowText = if ($low.Number -eq 0) { 'under a minute' } else { "$(& $number $low) $(& $unit $low)" }
    if ($UpToSeconds -lt 0) { return $(if ($low.Number -eq 0) { $lowText } else { "about $lowText" }) }
    $high = ConvertTo-ForecastDurationPart -Seconds $UpToSeconds
    $highText = if ($high.Number -eq 0) { 'under a minute' } else { "$(& $number $high) $(& $unit $high)" }
    if ($high.Number -eq 0 -or ($high.Number -eq $low.Number -and $high.Unit -eq $low.Unit)) { return $(if ($high.Number -eq 0) { $highText } else { "about $highText" }) }
    if ($low.Number -eq 0) { return "up to about $highText" }
    if ($low.Unit -eq $high.Unit) { return "about $(& $number $low) to $highText" }
    return "about $lowText to $highText"
}

function Get-ForecastReportSeconds {
    param([Parameter(Mandatory)]$Source)
    if ([string]$Source.scope -like '/subscriptions/*') { return $script:ForecastSubscriptionReportSeconds }
    return $script:ForecastBillingReportSeconds
}

function Get-ForecastLiveReportCount {
    # The months a live read covers from EarliestMonth (only as far back as
    # Cost Management reaches), and the weekly reports they need at a
    # billing account. Each subscription needs one report a month.
    param([Parameter(Mandatory)][string]$EarliestMonth, [Parameter(Mandatory)][datetime]$AsOf)
    $months = Get-ForecastCostDetailsMonths -Source ([pscustomobject]@{ fromMonth = 'Auto'; toMonth = '' }) -Now $AsOf -EarliestMonth $EarliestMonth
    $months = @($months)
    $weekly = 0
    foreach ($plan in $months) {
        $chunks = Get-ForecastCostDetailsChunks -Start $plan.Start -End $plan.End -Days 7
        $weekly += $chunks.Count
    }
    return [pscustomobject]@{ Months = $months.Count; Weekly = $weekly }
}

function Get-ForecastBillingCheckKey {
    param([AllowEmptyCollection()][string[]]$SubscriptionIds)
    $ids = @($SubscriptionIds | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Sort-Object -Unique)
    return Get-ForecastHash -Text ($ids -join ',')
}

function Get-ForecastGuidedBillingCheck {
    # Whether this sign-in can read the one EA or MCA billing account that
    # owns all these subscriptions. Always asks Azure, and keeps the result
    # for H on the review page.
    param([Parameter(Mandatory)][object[]]$Subscriptions)
    Write-FinOpsConsole "  Looking for the billing account that owns these $($Subscriptions.Count) subscriptions..." -ForegroundColor DarkGray
    $accounts = Get-ForecastCostDetailsBillingScopes -Subscriptions $Subscriptions
    $accounts = @($accounts)
    $script:ForecastBillingCheck = [pscustomobject]@{ Key = Get-ForecastBillingCheckKey -SubscriptionIds @($Subscriptions | ForEach-Object { [string]$_.Id }); Accounts = $accounts }
    return $script:ForecastBillingCheck
}

function Get-ForecastReadApproach {
    # How a workspace reads its history: Manual, Exports, Billing, or Subscriptions.
    param([Parameter(Mandatory)]$Settings)
    if ($Settings.dataMode -eq 'Manual') { return , @('Manual') }
    $kinds = foreach ($source in @($Settings.sources | Where-Object { $_ })) {
        if ([string]$source.kind -ne 'CostDetails') { 'Exports' }
        elseif ([string]$source.scope -like '/subscriptions/*') { 'Subscriptions' }
        else { 'Billing' }
    }
    return , @($kinds | Sort-Object -Unique)
}

function Get-ForecastReadEstimate {
    # Each way to read the history, exports first and then the live reads
    # fastest first, with the reports and rough time for the first read and
    # each later refresh. BillingCheck is $null when the billing account
    # wasn't checked; its Accounts are empty when this sign-in can't read
    # one. The billing account is only an option for more subscriptions than
    # ForecastGuidedSubscriptionLimit. Recommendation is set for more than
    # the minimum lookback.
    param(
        [Parameter(Mandatory)][int]$SubscriptionCount,
        [Parameter(Mandatory)][int]$LookbackMonths,
        [Parameter(Mandatory)][string]$EarliestMonth,
        [Parameter(Mandatory)][datetime]$AsOf,
        [AllowNull()]$BillingCheck
    )
    $counts = Get-ForecastLiveReportCount -EarliestMonth $EarliestMonth -AsOf $AsOf
    $reach = if ($LookbackMonths -gt $script:ForecastReadyMonths) { " Live reads reach back $($script:ForecastReadyMonths) months." } else { '' }
    $exports = [pscustomobject]@{
        Key = 'Exports'; Name = 'Cost Management exports'; Reports = $null; Seconds = $null; Available = $null; Status = ''
        FirstRead = 'usually minutes, depending on file size'; Later = 'only new export files'
        Needs = "Needs exports that cover $EarliestMonth on, and Storage Blob Data Reader or a local copy."
    }
    $live = [Collections.Generic.List[object]]::new()
    if ($SubscriptionCount -gt $script:ForecastGuidedSubscriptionLimit) {
        $accounts = if ($null -ne $BillingCheck) { @($BillingCheck.Accounts | Where-Object { $_ }) } else { @() }
        $available = if ($null -eq $BillingCheck) { $null } else { $accounts.Count -gt 0 }
        $status = if ($null -eq $available) { 'not checked yet; guided setup (G) checks it' } elseif ($available) { "available: $(ConvertTo-ForecastSafeText ([string]$accounts[0].Name) 60) ($($accounts[0].Agreement))" } else { 'not available with this sign-in' }
        $seconds = $counts.Weekly * $script:ForecastBillingReportSeconds
        $perMonth = $script:ForecastBillingReportsPerMonth
        $live.Add([pscustomobject]@{
                Key = 'Billing'; Name = 'Live, at the billing account'; Reports = $counts.Weekly; Seconds = $seconds; Available = $available; Status = $status
                FirstRead = "$($counts.Weekly) report$(if ($counts.Weekly -ne 1) { 's' }), $(Format-ForecastDuration $seconds)"
                Later = "$perMonth to $(2 * $perMonth), $(Format-ForecastDuration ($perMonth * $script:ForecastBillingReportSeconds) -UpToSeconds (2 * $perMonth * $script:ForecastBillingReportSeconds))"
                Needs = "Needs an EA or MCA billing reader role.$reach"
            })
    }
    $reports = $SubscriptionCount * $counts.Months
    $seconds = $reports * $script:ForecastSubscriptionReportSeconds
    $live.Add([pscustomobject]@{
            Key = 'Subscriptions'; Name = 'Live, each subscription'; Reports = $reports; Seconds = $seconds; Available = $null; Status = ''
            FirstRead = "$reports report$(if ($reports -ne 1) { 's' }), $(Format-ForecastDuration $seconds)"
            Later = "$SubscriptionCount to $(2 * $SubscriptionCount), $(Format-ForecastDuration ($SubscriptionCount * $script:ForecastSubscriptionReportSeconds) -UpToSeconds (2 * $SubscriptionCount * $script:ForecastSubscriptionReportSeconds))"
            Needs = "Needs Cost Management Reader on each subscription (EA or MCA only).$reach"
        })
    $ordered = @($live | Sort-Object -Property Seconds -Stable)
    $recommendation = ''
    if ($LookbackMonths -gt $script:ForecastMinimumLookbackMonths) {
        $recommendation = "More than $($script:ForecastMinimumLookbackMonths) months? Use exports if they already cover these months"
        $fallback = @($ordered | Where-Object { $_.Available -ne $false })[0]
        $billing = @($ordered | Where-Object Key -EQ 'Billing')[0]
        if ($fallback.Key -eq 'Billing') { $recommendation += "; if not, read at the billing account$(if ($null -eq $fallback.Available) { ' with a billing reader role' })." }
        elseif ($billing -and $billing.Available -eq $false -and $billing.Seconds -lt $fallback.Seconds) { $recommendation += '. With a billing reader role, one set of reports would cover every subscription.' }
        else { $recommendation += '.' }
    }
    return [pscustomobject]@{ Options = @($exports) + $ordered; Recommendation = $recommendation }
}

function Write-ForecastHowItWorks {
    # How the forecast is built, then each way to read the history, fastest
    # first. InUse marks the ways this workspace already reads.
    param(
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)][int]$SubscriptionCount,
        [Parameter(Mandatory)][string]$EarliestMonth,
        [Parameter(Mandatory)][datetime]$AsOf,
        [AllowNull()]$BillingCheck,
        [string[]]$InUse = @(),
        [switch]$Guided
    )
    $guide = if (Test-Path -LiteralPath $script:ForecastGuidePath) { $script:ForecastGuidePath } else { 'docs\forecast.md in the FinOps Explorer folder' }
    Write-FinOpsConsole '  How the forecast is built' -ForegroundColor White
    Write-FinOpsConsole '    1. Reads each month''s actual cost before Azure credits and Prepayment are applied.'
    Write-FinOpsConsole '    2. Measures how the run rate changed from one month to the next.'
    Write-FinOpsConsole '    3. Projects the rest of the fiscal year from the latest month at the median change;'
    Write-FinOpsConsole "       the low-to-high range runs $(if (Test-ForecastShortHistory -Settings $Settings) { "from the lowest to the highest of those changes until there are $($script:ForecastReadyMonths) months, then P$($Settings.method.lowPercentile) to P$($Settings.method.highPercentile)" } else { "from P$($Settings.method.lowPercentile) to P$($Settings.method.highPercentile) of those changes" })."
    Write-FinOpsConsole '    4. Flags unusual months for you to review, and adds the purchases and changes you schedule.'
    Write-FinOpsConsole "    More detail: $guide" -ForegroundColor DarkGray
    Write-FinOpsConsole ''
    if ($SubscriptionCount -lt 1) {
        Write-FinOpsConsole '  Time estimates need the subscriptions in 2 Scope.' -ForegroundColor DarkGray
        return
    }
    $estimate = Get-ForecastReadEstimate -SubscriptionCount $SubscriptionCount -LookbackMonths ([int]$Settings.period.lookbackMonths) -EarliestMonth $EarliestMonth -AsOf $AsOf -BillingCheck $BillingCheck
    $options = @($estimate.Options)
    Write-FinOpsConsole "  How long reading the history takes, fastest first ($SubscriptionCount subscription$(if ($SubscriptionCount -ne 1) { 's' }), from $EarliestMonth)" -ForegroundColor White
    for ($i = 0; $i -lt $options.Count; $i++) {
        $option = $options[$i]
        $rank = if ($i -eq 0) { 'Fastest' } elseif ($i -eq $options.Count - 1) { 'Slowest' } else { 'Next' }
        Write-FinOpsConsole ('    {0,-9} {1}' -f $rank, $option.Name) -ForegroundColor $(if ($option.Available -eq $false) { 'DarkGray' } else { 'White' }) -NoNewline
        if ($option.Status) {
            $color = if ($option.Available -eq $true) { 'Green' } elseif ($option.Available -eq $false) { 'Yellow' } else { 'DarkGray' }
            Write-FinOpsConsole ": $($option.Status)" -ForegroundColor $color -NoNewline
        }
        if ($option.Key -in $InUse) { Write-FinOpsConsole ' (in use)' -ForegroundColor Cyan -NoNewline }
        Write-FinOpsConsole ''
        Write-FinOpsConsole "              First read $($option.FirstRead); each later refresh $($option.Later)."
        Write-FinOpsConsole "              $($option.Needs)" -ForegroundColor DarkGray
    }
    if ($estimate.Recommendation) { Write-FinOpsConsole "  $($estimate.Recommendation)" -ForegroundColor Cyan }
    Write-FinOpsConsole '  Later refreshes keep every finished month and read only this month, plus last month until it''s final.' -ForegroundColor DarkGray
    Write-FinOpsConsole "  No access to any of these? Type in monthly totals from invoices ($(if ($Guided) { '3 below' } else { 'G, then 3' }))." -ForegroundColor DarkGray
}

function Show-ForecastHowItWorks {
    # H on the review page: the overview and time estimates for this
    # workspace. It doesn't ask Azure anything; the billing account shows
    # as in use, as guided setup last found it, or not checked yet.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][datetime]$AsOf)
    $settings = Get-ForecastStoredSettings -Root $Root
    $ids = if ($settings.scope.kind -eq 'Subscriptions') { @($settings.scope.subscriptionIds | Where-Object { $_ }) } else { @() }
    $billingCheck = $null
    $billingSource = @($settings.sources | Where-Object { $_ -and [string]$_.kind -eq 'CostDetails' -and [string]$_.scope -notlike '/subscriptions/*' })[0]
    if ($billingSource) { $billingCheck = [pscustomobject]@{ Accounts = @([pscustomobject]@{ Name = ([string]$billingSource.label -replace ' \(live\)$', ''); Agreement = [string]$billingSource.agreement }) } }
    elseif ($script:ForecastBillingCheck -and $script:ForecastBillingCheck.Key -eq (Get-ForecastBillingCheckKey -SubscriptionIds $ids)) { $billingCheck = $script:ForecastBillingCheck }
    Clear-ForecastScreen
    Write-ForecastHeading -Title 'How the forecast works'
    if ($settings.scope.label) { Write-FinOpsConsole "  Forecasting: $(ConvertTo-ForecastSafeText ([string]$settings.scope.label) 120)" -ForegroundColor Cyan }
    Write-FinOpsConsole ''
    Write-ForecastHowItWorks -Settings $settings -SubscriptionCount $ids.Count -EarliestMonth (Get-ForecastFirstNeededMonth -Settings $settings -AsOf $AsOf) -AsOf $AsOf -BillingCheck $billingCheck -InUse (Get-ForecastReadApproach -Settings $settings)
    Wait-ForecastKey
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
    Write-FinOpsConsole "  $($script:ForecastReadyMonths) months can give a Ready forecast; $($script:ForecastMinimumLookbackMonths) to $($script:ForecastReadyMonths - 1) give a Preliminary one. Live reads reach back $($script:ForecastReadyMonths) months; exports up to $($script:ForecastGuidedExportMonths)." -ForegroundColor DarkGray
    $months = Read-ForecastInteger -Prompt 'Months of history' -Default $script:ForecastReadyMonths -Minimum $script:ForecastMinimumLookbackMonths -Maximum $script:ForecastGuidedExportMonths
    $fiscal = Read-ForecastInteger -Prompt 'Fiscal year starts in month' -Default $settings.period.fiscalYearStartMonth -Minimum 1 -Maximum 12
    $settings.period.lookbackMonths = $months
    $settings.period.windowEnd = 'Auto'
    $settings.period.fiscalYearStartMonth = $fiscal
    # Fiscal-year months before the lookback window are actuals in the
    # year's total, so the history has to reach them too.
    $earliest = Get-ForecastFirstNeededMonth -Settings $settings -AsOf $AsOf
    $windowFirst = Add-ForecastMonth -MonthKey (Get-ForecastLastEligibleMonth -AsOf $AsOf -GraceDays ([int]$settings.period.graceDays)) -Count (1 - $months)
    # Checked before the estimates, so they can say whether the billing
    # account can be read, and reused if the history is read live.
    $billingCheck = $null
    if ($Subscriptions.Count -gt $script:ForecastGuidedSubscriptionLimit) { $billingCheck = Get-ForecastGuidedBillingCheck -Subscriptions $Subscriptions }

    Clear-ForecastScreen
    Write-ForecastHeading -Title 'Guided forecast setup: how it works'
    Write-FinOpsConsole "  Forecasting: $label; $months months of history" -ForegroundColor Cyan
    if ([string]::CompareOrdinal($earliest, $windowFirst) -lt 0) {
        Write-FinOpsConsole "  The fiscal year started in $earliest, before the $months-month lookback, so the history reaches back to $earliest for the year's actuals." -ForegroundColor DarkGray
    }
    Write-FinOpsConsole ''
    Write-ForecastHowItWorks -Settings $settings -SubscriptionCount $Subscriptions.Count -EarliestMonth $earliest -AsOf $AsOf -BillingCheck $billingCheck -Guided
    Write-FinOpsConsole ''
    Write-FinOpsConsole '  Where should the cost history come from?' -ForegroundColor White
    Write-FinOpsConsole '    1  Live from Cost Management, with this sign-in (no exports needed)'
    Write-FinOpsConsole '    2  Cost Management exports (find them, a storage account, or a local folder)'
    Write-FinOpsConsole '    3  Monthly totals you enter yourself'
    $kind = Read-ForecastChoice -Prompt 'Choose' -Valid @('1', '2', '3') -Default '1'
    if (-not $kind) { return $false }
    if ($kind -eq '1' -and $months -gt $script:ForecastReadyMonths) {
        $months = $script:ForecastReadyMonths
        $settings.period.lookbackMonths = $months
        $earliest = Get-ForecastFirstNeededMonth -Settings $settings -AsOf $AsOf
        Write-FinOpsConsole "  Cost Management reaches back $months months, so live reads use $months months of history." -ForegroundColor Yellow
    }

    $sources = @()
    if ($kind -eq '1') {
        $sources = Get-ForecastGuidedLiveSources -Subscriptions $Subscriptions -EarliestMonth $earliest -GraceDays ([int]$settings.period.graceDays) -AsOf $AsOf -BillingCheck $billingCheck
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
        $requests = Get-ForecastGuidedRequestEstimate -Sources $sources -AsOf $AsOf -EarliestMonth $earliest
        Write-FinOpsConsole "  The first refresh asks Cost Management for $($requests.Count) report$(if ($requests.Count -ne 1) { 's' }), $(Format-ForecastDuration $requests.Seconds). Leave this window open; later refreshes only ask for recent months." -ForegroundColor DarkGray
    }
    if (Read-ForecastYesNo -Prompt 'Refresh now' -Default $true) { Invoke-ForecastConsoleRefresh -Root $Root }
    return $true
}
