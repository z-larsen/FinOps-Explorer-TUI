# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
param()

###########################################################################
# FORECAST.SELECTION.PS1
# ONE APPROVED RUN PER ORIGINAL SCOPE, DATASET, AND MONTH
###########################################################################
# Daily month-to-date exports write a new cumulative run each day, and a
# rerun or correction writes another. Adding them together would count the
# same charges many times, so for every (original scope, dataset, month)
# exactly one run is selected:
# - eligible: Complete (manifest verified) or a legacy run a reviewer approved
# - selected: the eligible run submitted last
# - final:    submitted at least the grace period after the month ended
#             (Azure closes a billing period up to 72 hours after it ends)
# A newer corrected run replaces the earlier one on the next refresh, so the
# result is the same however many times it runs. A newer run that's
# incomplete never displaces an older complete one.
###########################################################################

function Get-ForecastRunGroupScope {
    param([Parameter(Mandatory)]$Result)
    if ($Result.OriginalScope) { return [string]$Result.OriginalScope }
    # Legacy runs have no manifest scope; group them by source and export folder.
    $folder = [string]$Result.Folder
    if ($folder -match '^(.*?)/\d{8}-\d{8}/') { $folder = $Matches[1] }
    return "legacy:$($Result.SourceId):$($folder.TrimEnd('/'))"
}

function Get-ForecastRunGroupLabel {
    param([string]$Scope, [string]$Dataset)
    $datasetLabel = if ($Dataset) { $Dataset } else { 'Unknown dataset' }
    return "$datasetLabel at $Scope"
}

function Get-ForecastRunCoverage {
    # Full: the run covers the whole month. MonthToDate: it starts on the
    # first but ends early (a run in progress). Partial: it starts after the
    # first, so it can't stand in for the month. Unknown: a legacy file whose
    # rows reach the month's last day; its dates come only from those rows.
    # A legacy file whose rows stop earlier counts as MonthToDate.
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$Month)
    $lastDay = (Get-ForecastMonthEnd -MonthKey $Month).AddDays(-1)
    if (-not $Result.Start) {
        $stat = @($Result.MonthStats | Where-Object Month -EQ $Month)[0]
        if ($stat -and $stat.Through -and ([datetime]$stat.Through).Date -lt $lastDay) { return 'MonthToDate' }
        return 'Unknown'
    }
    $monthStart = Get-ForecastMonthStart -MonthKey $Month
    $runStart = ([datetime]$Result.Start).Date
    $runEnd = if ($Result.End) { ([datetime]$Result.End).Date } else { $runStart }
    if ($runStart -gt $monthStart) { return 'Partial' }
    if ($runEnd -ge $lastDay) { return 'Full' }
    return 'MonthToDate'
}

function Select-ForecastRuns {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results,
        [Parameter(Mandatory)]$Settings,
        [Collections.IDictionary]$Reviews
    )
    $scopeKey = Get-ForecastScopeKey -Settings $Settings
    $grace = [int]$Settings.period.graceDays
    $issues = [Collections.Generic.List[object]]::new()
    $reviewItems = [Collections.Generic.List[object]]::new()

    # The same export run reached through two sources is one run.
    $unique = [Collections.Generic.List[object]]::new()
    $seenRuns = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($result in $Results) {
        $identity = "$($result.RunId)|$($result.Folder)"
        if ($seenRuns.ContainsKey($identity)) {
            $issues.Add((New-ForecastIssue -Code 'RUN-DUPLICATESOURCE' -Severity 'Info' -Message "Run $(ConvertTo-ForecastSafeText $result.RunId 80) appears in sources $($seenRuns[$identity]) and $($result.SourceId); it's counted once."))
            continue
        }
        $seenRuns[$identity] = [string]$result.SourceId
        $unique.Add($result)
    }

    $approved = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($result in $unique) {
        if ($result.Status -ne 'Unverified') { continue }
        $item = New-ForecastReviewItem -Key "run:${scopeKey}:$($result.RunKey)" -Fingerprint ([string]$result.Signature) -Category 'Run' -Reviews $Reviews -Subject ([string]$result.RunId) `
            -Title "Legacy export file without a manifest: $(ConvertTo-ForecastSafeText $result.RunId 120)" `
            -Detail "Without a manifest the partition list and row counts can't be verified. Approve only if you've confirmed this file is the complete actual-cost export (not amortized) for $(@($result.Months) -join ', ')." `
            -Options @('Approved', 'Rejected') -Suggested 'Rejected'
        $reviewItems.Add($item)
        if ($item.Decision -eq 'Approved') { [void]$approved.Add([string]$result.RunKey) }
    }

    $groups = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($result in $unique) {
        $scope = Get-ForecastRunGroupScope -Result $result
        foreach ($month in @($result.Months)) {
            $key = "$scope|$($result.Dataset)|$month"
            if (-not $groups.ContainsKey($key)) { $groups[$key] = [pscustomobject]@{ Scope = $scope; Dataset = [string]$result.Dataset; Month = [string]$month; Runs = [Collections.Generic.List[object]]::new() } }
            $groups[$key].Runs.Add($result)
        }
    }

    $selection = [Collections.Generic.List[object]]::new()
    $coverageRank = @{ Full = 0; Unknown = 1; MonthToDate = 2; Partial = 3 }
    foreach ($group in $groups.Values) {
        $label = Get-ForecastRunGroupLabel -Scope $group.Scope -Dataset $group.Dataset
        $candidates = foreach ($run in $group.Runs) { [pscustomobject]@{ Run = $run; Coverage = Get-ForecastRunCoverage -Result $run -Month $group.Month } }
        # Whole-month runs win over runs still in progress; within the same
        # coverage, the run submitted last wins.
        $byPreference = Invoke-ForecastSort -Items @($candidates) -Comparison {
            param($a, $b)
            $c = $coverageRank[$a.Coverage].CompareTo($coverageRank[$b.Coverage])
            if ($c) { return $c }
            $left = if ($a.Run.Submitted) { [datetime]$a.Run.Submitted } else { [datetime]::MinValue }
            $right = if ($b.Run.Submitted) { [datetime]$b.Run.Submitted } else { [datetime]::MinValue }
            $c = $right.CompareTo($left)
            if ($c) { $c } else { [string]::CompareOrdinal([string]$a.Run.RunKey, [string]$b.Run.RunKey) }
        }
        $partial = @($byPreference | Where-Object Coverage -EQ 'Partial')
        if ($partial.Count) {
            $issues.Add((New-ForecastIssue -Code 'RUN-PARTIAL' -Severity 'Warn' -Message "$($partial.Count) run(s) for $label start after the first of $($group.Month), so they don't replace a whole-month run for that month." -Subject $group.Month))
        }
        $eligible = @($byPreference | Where-Object { $_.Coverage -ne 'Partial' -and ($_.Run.Status -eq 'Complete' -or ($_.Run.Status -eq 'Unverified' -and $approved.Contains([string]$_.Run.RunKey))) })
        if ($eligible.Count -eq 0) {
            $statuses = (@($byPreference | ForEach-Object { "$($_.Run.Status)/$($_.Coverage)" } | Sort-Object -Unique) -join ', ')
            $reasons = @($byPreference | ForEach-Object { @($_.Run.Issues) } | Where-Object { $_ -and $_.Severity -eq 'Fail' } | ForEach-Object Message | Select-Object -Unique -First 2)
            $issues.Add((New-ForecastIssue -Code 'RUN-NOELIGIBLE' -Message "No complete, approved run covers $($group.Month) from its first day for $label (runs: $statuses).$(if ($reasons.Count) { ' ' + ($reasons -join ' ') })" -Subject $group.Month))
            continue
        }
        $chosen = $eligible[0]
        $newestWhole = @($byPreference | Where-Object { $_.Coverage -ne 'Partial' -and $_.Coverage -eq $chosen.Coverage })[0]
        if ($newestWhole -and $newestWhole.Run.RunKey -ne $chosen.Run.RunKey) {
            $reason = @(@($newestWhole.Run.Issues) | Where-Object { $_ -and $_.Severity -eq 'Fail' } | ForEach-Object Message | Select-Object -First 1)
            $issues.Add((New-ForecastIssue -Code 'RUN-NEWERINCOMPLETE' -Severity 'Warn' -Message "The newest run for $label in $($group.Month) is $($newestWhole.Run.Status); the earlier complete run $(ConvertTo-ForecastSafeText $chosen.Run.RunId 80) is used.$(if ($reason.Count) { ' ' + $reason[0] })" -Subject $group.Month))
        }
        # Several loose files for one month are more likely different
        # datasets or copies than reruns, so the choice is called out.
        $otherLegacy = @($byPreference | Where-Object { -not $_.Run.HasManifest -and $_.Run.RunKey -ne $chosen.Run.RunKey })
        if (-not $chosen.Run.HasManifest -and $otherLegacy.Count) {
            $issues.Add((New-ForecastIssue -Code 'RUN-LEGACYMULTI' -Severity 'Warn' -Message "$($otherLegacy.Count + 1) files without a manifest cover $($group.Month) in the same folder; only $(ConvertTo-ForecastSafeText $chosen.Run.RunId 120) is used. Remove any file that isn't the actual-cost export for that month." -Subject $group.Month))
        }
        $monthEnd = Get-ForecastMonthEnd -MonthKey $group.Month
        $final = $chosen.Coverage -in 'Full', 'Unknown' -and $chosen.Run.Submitted -and ([datetime]$chosen.Run.Submitted) -ge $monthEnd.AddDays($grace)
        $selection.Add([pscustomobject]@{
                GroupKey = "$($group.Scope)|$($group.Dataset)"; Label = $label; Scope = $group.Scope; Dataset = $group.Dataset; Month = $group.Month
                RunKey = $chosen.Run.RunKey; RunId = $chosen.Run.RunId; SourceId = $chosen.Run.SourceId; Submitted = $chosen.Run.Submitted; Final = [bool]$final
                Coverage = $chosen.Coverage
                Superseded = @($eligible | Select-Object -Skip 1 | ForEach-Object { $_.Run.RunId })
                Skipped = @($byPreference | Where-Object { $_ -notin $eligible } | ForEach-Object { "$($_.Run.RunId) ($($_.Run.Status), $($_.Coverage))" })
            })
    }
    $ordered = Invoke-ForecastSort -Items $selection.ToArray() -Comparison { param($a, $b) $c = [string]::CompareOrdinal($a.Month, $b.Month); if ($c) { $c } else { [string]::CompareOrdinal($a.GroupKey, $b.GroupKey) } }
    [pscustomobject]@{ Selection = $ordered; Issues = $issues.ToArray(); Reviews = $reviewItems.ToArray(); Runs = $unique.ToArray() }
}
