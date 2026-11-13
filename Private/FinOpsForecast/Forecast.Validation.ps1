# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers that build objects or write only the private local forecast workspace; nothing in Azure changes.')]
param()

###########################################################################
# FORECAST.VALIDATION.PS1
# READINESS GATE
###########################################################################
# A forecast is Ready only when every check passes or warns. Fail blocks
# Ready and the forecast can't be saved as a vintage. Warnings stay visible
# as labels (Partial population, Stale data) on every output.
###########################################################################

function New-ForecastCheck {
    param([string]$Id, [string]$Name, [ValidateSet('Pass', 'Warn', 'Fail')][string]$Status, [string]$Detail)
    [pscustomobject]@{ Id = $Id; Name = $Name; Status = $Status; Detail = $Detail }
}

function Get-ForecastAllReviews {
    param([Parameter(Mandatory)]$Dataset, [Parameter(Mandatory)]$Model)
    return @(@($Dataset.Reviews) + @($Model.Reviews) | Where-Object { $null -ne $_ })
}

function Format-ForecastScopeIssues {
    # One line for each scope, with the other months it fails in, so a scope
    # that fails every month doesn't hide the scopes after it.
    param([Parameter(Mandatory)][object[]]$Issues, [int]$Limit = 5)
    $groups = [ordered]@{}
    foreach ($issue in $Issues) {
        $scope = $issue.PSObject.Properties['Scope']
        $key = if ($scope -and $scope.Value) { "scope|$($scope.Value)" } else { "issue|$($groups.Count)" }
        if (-not $groups.Contains($key)) { $groups[$key] = [Collections.Generic.List[object]]::new() }
        $groups[$key].Add($issue)
    }
    $keys = @($groups.Keys)
    $lines = for ($i = 0; $i -lt [math]::Min($Limit, $keys.Count); $i++) {
        $group = $groups[$keys[$i]]
        $others = @($group | Select-Object -Skip 1 | ForEach-Object Subject | Where-Object { $_ -and $_ -ne $group[0].Subject } | Select-Object -Unique)
        "$($group[0].Message)$(if ($others.Count) { " The same applies to $($others -join ', ')." })"
    }
    $hidden = 0
    for ($i = $Limit; $i -lt $keys.Count; $i++) { $hidden += $groups[$keys[$i]].Count }
    return "$(@($lines) -join ' ')$(if ($hidden) { " (and $hidden more issue(s))" })"
}

function Get-ForecastLiveSourceName {
    # The name a live source gives its subscription, without " (live)".
    param([Parameter(Mandatory)][string]$SubscriptionId, $Settings)
    foreach ($source in @($Settings.sources | Where-Object { $_ -and [string]$_.kind -eq 'CostDetails' })) {
        if ((ConvertTo-ForecastSubscriptionId -Value ([string]$source.scope)) -eq $SubscriptionId -and $source.label) { return ([string]$source.label) -replace '\s*\(live\)$', '' }
    }
    return ''
}

function Get-ForecastScopeSubscriptionName {
    # A subscription's name from its cost rows, or else from the live source
    # that reads it; a subscription that couldn't be read has no rows.
    param([Parameter(Mandatory)][string]$SubscriptionId, $Dataset, $Settings)
    $name = [string]$Dataset.SubscriptionNames[$SubscriptionId]
    if (-not $name) { $name = Get-ForecastLiveSourceName -SubscriptionId $SubscriptionId -Settings $Settings }
    if ($name) { return "$(ConvertTo-ForecastSafeText $name 60) ($SubscriptionId)" }
    return $SubscriptionId
}

function Test-ForecastReadiness {
    param(
        [Parameter(Mandatory)]$Dataset,
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)]$Settings,
        $RefreshState,
        [AllowEmptyCollection()][object[]]$MappingIssues = @(),
        [Parameter(Mandatory)][datetime]$AsOf
    )
    $checks = [Collections.Generic.List[object]]::new()
    $labels = [Collections.Generic.List[string]]::new()
    $window = $Model.Window
    $windowMonths = @($window.Rows | ForEach-Object Month)
    $asOfUtc = ConvertFrom-ForecastDate -Value $AsOf
    $inWindow = { param($month) (Test-ForecastMonthKey $month) -and [string]::CompareOrdinal($month, $window.First) -ge 0 -and [string]::CompareOrdinal($month, (ConvertTo-ForecastMonthKey $asOfUtc)) -le 0 }

    $settingIssues = @(Test-ForecastSettings -Settings $Settings | Where-Object { -not ($Settings.dataMode -eq 'Manual' -and $_.Code -in 'SET-SOURCE', 'SET-SCOPE') })
    $settingIssues += @($Model.Issues | Where-Object { $_.Severity -eq 'Fail' -and $_.Code -like 'WIN-*' })
    $checks.Add((New-ForecastCheck -Id 'SETTINGS' -Name 'Settings' -Status $(if ($settingIssues.Count) { 'Fail' } else { 'Pass' }) -Detail $(if ($settingIssues.Count) { ($settingIssues.Message -join ' ') } else { 'Source, scope, period, and method settings are valid.' })))

    $datasetFails = @($Dataset.Issues | Where-Object { $_.Severity -eq 'Fail' -and $_.Code -notin 'REC-DIFF', 'BND-MISSING', 'CUR-MIXED' -and $_.Code -notmatch '^(SCH|MAP)-' })
    $blocking = @($datasetFails | Where-Object { -not $_.Subject -or -not (Test-ForecastMonthKey $_.Subject) -or (& $inWindow $_.Subject) })
    $outside = @($datasetFails | Where-Object { $_ -notin $blocking })
    $runWarnings = @($Dataset.Issues | Where-Object { $_.Severity -eq 'Warn' -and $_.Code -like 'RUN-*' })
    $sourceStatus = if ($blocking.Count) { 'Fail' } elseif ($outside.Count -or $runWarnings.Count) { 'Warn' } else { 'Pass' }
    $sourceDetail = if ($blocking.Count) { Format-ForecastScopeIssues -Issues $blocking }
    elseif ($outside.Count -or $runWarnings.Count) {
        $parts = @()
        if ($outside.Count) { $parts += "$($outside.Count) issue(s) in months outside the forecast period." }
        if ($runWarnings.Count) { $parts += (@($runWarnings.Message | Select-Object -First 3) -join ' ') + $(if ($runWarnings.Count -gt 3) { " (and $($runWarnings.Count - 3) more run warning(s))" } else { '' }) }
        $parts -join ' '
    }
    else { 'All selected runs are complete, with every declared partition and row verified.' }
    $checks.Add((New-ForecastCheck -Id 'SOURCE' -Name 'Source data and partitions' -Status $sourceStatus -Detail $sourceDetail))

    $notUsable = @($window.Rows | Where-Object { -not (Test-ForecastMonthUsable $_) })
    $monthDetail = if ($notUsable.Count) { (@($notUsable | ForEach-Object { "$($_.Month) $($_.Status)$(if ($_.Note) { " ($($_.Note))" })" }) -join '; ') } else { "All $($windowMonths.Count) months from $($window.First) to $($window.Last) are complete." }
    $checks.Add((New-ForecastCheck -Id 'MONTHS' -Name "Complete months ($($Settings.period.lookbackMonths) required)" -Status $(if ($notUsable.Count) { 'Fail' } else { 'Pass' }) -Detail $monthDetail))

    # A short lookback is a deliberate choice, so it warns instead of failing,
    # but the forecast can't be Ready or saved as a vintage.
    $lookback = [int]$Settings.period.lookbackMonths
    $preliminary = $lookback -lt $script:ForecastReadyMonths
    if ($preliminary) { $labels.Add("Preliminary ($lookback months of history)") }
    $historyDetail = if ($preliminary) { "$lookback months of history give $($lookback - 1) month-to-month changes. A Ready forecast needs $($script:ForecastReadyMonths) months; this one is Preliminary and can't be saved as a vintage." } else { "$lookback months of history." }
    $checks.Add((New-ForecastCheck -Id 'HISTORY' -Name 'History length' -Status $(if ($preliminary) { 'Warn' } else { 'Pass' }) -Detail $historyDetail))

    # A lookback shorter than the fiscal year so far leaves fiscal-year months
    # outside the window; without data they'd add zero to the total.
    $beforeWindow = @($Model.Projection.MissingActualMonths | Where-Object { $_ -and [string]::CompareOrdinal([string]$_, [string]$window.First) -lt 0 })
    $actualsDetail = if ($beforeWindow.Count) { "No final data for $($beforeWindow -join ', '), which are in $($Model.Projection.FiscalYear.Label) before the lookback window, so they'd count as zero. Read the history back to $($beforeWindow[0]): refresh a live source, or add exports or inputs for those months." } else { 'Every fiscal-year month before the lookback window has final data.' }
    $checks.Add((New-ForecastCheck -Id 'ACTUALS' -Name 'Fiscal-year actuals before the lookback' -Status $(if ($beforeWindow.Count) { 'Fail' } else { 'Pass' }) -Detail $actualsDetail))

    $comparisons = @($Model.Comparisons.Items)
    $missingComparisons = @($comparisons | Where-Object Status -EQ 'MissingData')
    $accounted = $comparisons.Count -eq $Model.Comparisons.Expected -and $missingComparisons.Count -eq 0
    $checks.Add((New-ForecastCheck -Id 'COMPARISONS' -Name 'Adjacent-month comparisons' -Status $(if ($accounted) { 'Pass' } else { 'Fail' }) `
                -Detail "$($comparisons.Count - $missingComparisons.Count) of $($Model.Comparisons.Expected) comparisons computed; $(@($comparisons | Where-Object Status -EQ 'Undefined').Count) undefined; $(@($comparisons | Where-Object Flagged).Count) flagged."))

    $growth = $Model.Growth
    $checks.Add((New-ForecastCheck -Id 'RETAINED' -Name 'Retained comparisons' -Status $(if ($growth.Sufficient) { 'Pass' } else { 'Fail' }) -Detail "$($growth.Retained) retained; at least $($growth.Minimum) required."))

    $currencyOk = $Dataset.Currency -match '^[A-Z]{3}$'
    $currencyProblem = @(@($Dataset.Issues | Where-Object Code -EQ 'CUR-MIXED' | ForEach-Object Message) + 'No single billing currency was found.')[0]
    $checks.Add((New-ForecastCheck -Id 'CURRENCY' -Name 'Single billing currency' -Status $(if ($currencyOk) { 'Pass' } else { 'Fail' }) -Detail $(if ($currencyOk) { "All amounts are in $($Dataset.Currency)." } else { $currencyProblem })))

    $keyIssues = @(@($Model.Issues) + @($Dataset.Issues) + @($MappingIssues) | Where-Object { $_ -and $_.Severity -eq 'Fail' -and $_.Code -match '^(SCH|MAP|INP)-' })
    $checks.Add((New-ForecastCheck -Id 'KEYS' -Name 'Unique keys and valid assumptions' -Status $(if ($keyIssues.Count) { 'Fail' } else { 'Pass' }) -Detail $(if ($keyIssues.Count) { ($keyIssues.Message | Select-Object -First 5) -join ' ' } else { 'Scheduled items, mappings, and inputs have unique, valid keys.' })))

    $boundaryIssue = @($Dataset.Issues | Where-Object Code -EQ 'BND-MISSING')
    $checks.Add((New-ForecastCheck -Id 'BOUNDARY' -Name 'EA to MCA boundary' -Status $(if ($boundaryIssue.Count) { 'Fail' } else { 'Pass' }) -Detail $(if ($boundaryIssue.Count) { $boundaryIssue[0].Message } elseif ($Settings.migration.boundaryDate) { "Boundary $($Settings.migration.boundaryDate): EA before, MCA on or after." } else { 'Only one agreement type is present.' })))

    $reconciliationIssues = @($Dataset.Issues | Where-Object { $_.Code -eq 'REC-DIFF' -and (& $inWindow $_.Subject) })
    $checks.Add((New-ForecastCheck -Id 'RECONCILE' -Name 'Reconciliation' -Status $(if ($reconciliationIssues.Count) { 'Fail' } else { 'Pass' }) -Detail $(if ($reconciliationIssues.Count) { ($reconciliationIssues.Message | Select-Object -First 3) -join ' ' } else { 'Every selected run-month reconciles: included plus excluded plus credits equals the raw total.' })))

    $freshness = [Collections.Generic.List[string]]::new()
    if ($window.Pinned) { $freshness.Add("The window is pinned to end in $($window.Last); the latest eligible month is $($window.LastEligible).") }
    $staleDays = [int]$Settings.period.staleAfterDays
    if ($RefreshState) {
        if ($RefreshState.LastAttemptResult -eq 'Failed') { $freshness.Add("The last refresh failed at $($RefreshState.LastAttemptUtc) ($(ConvertTo-ForecastSafeText $RefreshState.LastError 200)); data from the refresh at $($RefreshState.LastSuccessUtc) is shown.") }
        $lastSuccess = ConvertFrom-ForecastDate -Value $RefreshState.LastSuccessUtc
        if ($lastSuccess -and ($asOfUtc - $lastSuccess).TotalDays -gt $staleDays) { $freshness.Add("The last successful refresh was $([int]($asOfUtc - $lastSuccess).TotalDays) days ago.") }
    }
    if ($Dataset.DataThrough) {
        $age = ($asOfUtc - [datetime]$Dataset.DataThrough).TotalDays
        if ($age -gt $staleDays) { $freshness.Add("The newest charge date is $(([datetime]$Dataset.DataThrough).ToString('yyyy-MM-dd')), $([int]$age) days old.") }
    }
    if ($freshness.Count) { $labels.Add('Stale data') }
    $checks.Add((New-ForecastCheck -Id 'FRESHNESS' -Name 'Freshness' -Status $(if ($freshness.Count) { 'Warn' } else { 'Pass' }) -Detail $(if ($freshness.Count) { $freshness -join ' ' } else { 'Data and refresh are current.' })))

    if ($Dataset.Mode -eq 'Exports' -and $Dataset.Population) {
        $gaps = [Collections.Generic.List[string]]::new()
        foreach ($subscription in @($Dataset.ScopeSubscriptions | Sort-Object)) {
            $months = $Dataset.Population[$subscription]
            $missing = @($windowMonths | Where-Object { -not $months -or -not $months.Contains($_) })
            if ($missing.Count -eq $windowMonths.Count) { $gaps.Add("$(Get-ForecastScopeSubscriptionName -SubscriptionId $subscription -Dataset $Dataset -Settings $Settings) has no run-rate data in the window") }
            elseif ($missing.Count) { $gaps.Add("$(Get-ForecastScopeSubscriptionName -SubscriptionId $subscription -Dataset $Dataset -Settings $Settings) has no run-rate data in $($missing.Count) month(s), first $($missing[0])") }
        }
        if ($gaps.Count) { $labels.Add('Partial population') }
        $checks.Add((New-ForecastCheck -Id 'POPULATION' -Name 'Population' -Status $(if ($gaps.Count) { 'Warn' } else { 'Pass' }) -Detail $(if ($gaps.Count) { "Partial population: $(($gaps | Select-Object -First 5) -join '; ')$(if ($gaps.Count -gt 5) { "; and $($gaps.Count - 5) more" })." } else { 'Every subscription in scope has data in every month of the window.' })))
    }

    $baselineOk = $null -ne $Model.Baseline.Value
    $checks.Add((New-ForecastCheck -Id 'BASELINE' -Name 'Baseline' -Status $(if ($baselineOk) { 'Pass' } else { 'Fail' }) -Detail $Model.Baseline.Detail))

    $reviews = Get-ForecastAllReviews -Dataset $Dataset -Model $Model
    $pendingRequired = @($reviews | Where-Object { $_.Required -and $_.Decision -eq 'Pending' })
    $pendingOptional = @($reviews | Where-Object { -not $_.Required -and $_.Decision -eq 'Pending' })
    $exceptionStatus = if ($pendingRequired.Count) { 'Fail' } elseif ($pendingOptional.Count) { 'Warn' } else { 'Pass' }
    $exceptionDetail = if ($reviews.Count -eq 0) { 'No exceptions.' } else { "$($pendingRequired.Count) required and $($pendingOptional.Count) optional review(s) pending of $($reviews.Count)." }
    $checks.Add((New-ForecastCheck -Id 'EXCEPTIONS' -Name 'Exceptions reviewed' -Status $exceptionStatus -Detail $exceptionDetail))

    $failed = @($checks | Where-Object Status -EQ 'Fail')
    [pscustomobject]@{
        Ready = $failed.Count -eq 0 -and -not $preliminary
        Status = if ($failed.Count) { 'NotReady' } elseif ($preliminary) { 'Preliminary' } else { 'Ready' }
        Checks = $checks.ToArray()
        Labels = $labels.ToArray()
        PendingRequired = $pendingRequired
        Reviews = $reviews
    }
}
