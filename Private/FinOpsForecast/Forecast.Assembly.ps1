# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
param()

###########################################################################
# FORECAST.ASSEMBLY.PS1
# COMBINE SELECTED RUNS INTO ONE CONTINUOUS MONTHLY HISTORY
###########################################################################
# Rules, in order, for every cell of every selected run-month:
# 1. Overlap:  a subscription-month that two selected (scope, dataset)
#              groups both carry for the same agreement is a conflict. A
#              reviewer picks the group to keep; the other is excluded.
# 2. Boundary: EA rows on or after the migration date and MCA rows before it
#              are excluded so EA and MCA histories never overlap.
# 3. Scope:    selected subscriptions, or a billing profile (its MCA rows,
#              including rows without a subscription, plus EA rows for the
#              same subscriptions so history continues across a migration).
# 4. Filters:  credits never count; tax and Marketplace count only when the
#              settings include them. Unclassified publishers need a review.
# Everything excluded is reported, and every month reconciles to the raw
# totals of its selected runs.
###########################################################################

function Test-ForecastBillingProfileMatch {
    param([AllowNull()][string]$CellProfile, [Parameter(Mandatory)][string]$Target)
    $value = ([string]$CellProfile).Trim().ToLowerInvariant()
    if (-not $value) { return $false }
    if ($value -eq $Target) { return $true }
    return $value.EndsWith("/billingprofiles/$Target") -or $Target.EndsWith("/billingprofiles/$value")
}

function Merge-ForecastExportHistory {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results,
        [Parameter(Mandatory)]$Selection,
        [Parameter(Mandatory)]$Settings,
        [Collections.IDictionary]$Reviews
    )
    $scopeKey = Get-ForecastScopeKey -Settings $Settings
    $issues = [Collections.Generic.List[object]]::new()
    foreach ($issue in @($Selection.Issues)) { $issues.Add($issue) }
    $reviewItems = [Collections.Generic.List[object]]::new()
    foreach ($item in @($Selection.Reviews)) { $reviewItems.Add($item) }
    $byRun = @{}
    foreach ($result in $Results) { $byRun[[string]$result.RunKey] = $result }
    # A selected run's own warnings (for example rows outside its declared
    # dates) apply to the months it feeds, so they surface with them.
    $firstSelectedMonth = @{}
    foreach ($selected in @($Selection.Selection)) {
        if (-not $firstSelectedMonth.ContainsKey([string]$selected.RunKey)) { $firstSelectedMonth[[string]$selected.RunKey] = [string]$selected.Month }
    }
    foreach ($runKey in $firstSelectedMonth.Keys) {
        foreach ($issue in @($byRun[$runKey].Issues | Where-Object { $_.Severity -in 'Warn', 'Fail' })) {
            $issues.Add((New-ForecastIssue -Code $issue.Code -Severity $issue.Severity -Message "Run $(ConvertTo-ForecastSafeText $byRun[$runKey].RunId 80): $($issue.Message)" -Subject $firstSelectedMonth[$runKey]))
        }
    }
    $names = @{}
    foreach ($result in ($Results | Sort-Object { if ($_.Submitted) { [datetime]$_.Submitted } else { [datetime]::MinValue } })) {
        foreach ($entry in $result.SubscriptionNames.GetEnumerator()) { $names[$entry.Key] = $entry.Value }
    }

    # Gather the selected cells with their group context, indexing each run's
    # cells by month once instead of scanning them per selection.
    $entries = [Collections.Generic.List[object]]::new()
    $cellsByRunMonth = @{}
    foreach ($selected in @($Selection.Selection)) {
        $runKey = [string]$selected.RunKey
        if (-not $cellsByRunMonth.ContainsKey($runKey)) {
            $index = @{}
            foreach ($cell in @($byRun[$runKey].Cells)) {
                $cellMonth = [string]$cell.Month
                if (-not $index.ContainsKey($cellMonth)) { $index[$cellMonth] = [Collections.Generic.List[object]]::new() }
                $index[$cellMonth].Add($cell)
            }
            $cellsByRunMonth[$runKey] = $index
        }
        $monthCells = $cellsByRunMonth[$runKey][[string]$selected.Month]
        if ($null -eq $monthCells) { continue }
        foreach ($cell in $monthCells) { $entries.Add([pscustomobject]@{ Cell = $cell; Selected = $selected; Disposition = $null }) }
    }

    # 1. Overlapping groups for the same subscription, month, and agreement.
    # Charges without a subscription are keyed by billing profile instead, so
    # they follow the same decision rather than counting once per group.
    $getCarrierKey = {
        param($Cell)
        $holder = if ($Cell.SubscriptionId) { "sub:$($Cell.SubscriptionId)" } else { "profile:$($Cell.BillingProfileId)" }
        "$($Cell.Month)|$holder|$($Cell.Agreement)"
    }
    $carriers = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $entries) {
        if ($entry.Cell.Boundary -ne 'In') { continue }
        $key = & $getCarrierKey $entry.Cell
        if (-not $carriers.ContainsKey($key)) { $carriers[$key] = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal) }
        [void]$carriers[$key].Add([string]$entry.Selected.GroupKey)
    }
    $winners = @{}
    $conflictSets = @{}
    foreach ($pair in $carriers.GetEnumerator()) {
        if ($pair.Value.Count -lt 2) { continue }
        $setKey = (@($pair.Value) -join ' + ')
        if (-not $conflictSets.ContainsKey($setKey)) { $conflictSets[$setKey] = [Collections.Generic.List[string]]::new() }
        $conflictSets[$setKey].Add($pair.Key)
    }
    foreach ($set in $conflictSets.GetEnumerator()) {
        $options = [string[]]@($set.Key -split ' \+ ')
        $months = @($set.Value | ForEach-Object { ($_ -split '\|')[0] } | Sort-Object -Unique)
        $review = New-ForecastReviewItem -Key "overlap:${scopeKey}:$(Get-ForecastHash -Text $set.Key)" -Fingerprint (Get-ForecastHash -Text $set.Key) -Category 'Overlap' -Reviews $Reviews `
            -Title 'Overlapping export scopes' -Subject ($months -join ', ') `
            -Detail "These export groups carry the same subscriptions in $($months.Count) month(s) ($($months[0]) to $($months[-1])): $($options -join '; '). Keeping both would count the charges twice. Choose the group to keep." `
            -Options $options -Suggested $options[0]
        $reviewItems.Add($review)
        $winner = if ($review.Decision -ne 'Pending') { $review.Decision } else { $options[0] }
        foreach ($key in $set.Value) { $winners[$key] = $winner }
    }

    # 3. Scope membership.
    $target = ([string]$Settings.scope.billingProfileId).Trim().ToLowerInvariant()
    $scopeSubscriptions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($Settings.scope.kind -eq 'BillingProfile') {
        foreach ($entry in $entries) {
            if ($entry.Cell.Agreement -eq 'MCA' -and $entry.Cell.SubscriptionId -and (Test-ForecastBillingProfileMatch -CellProfile $entry.Cell.BillingProfileId -Target $target)) { [void]$scopeSubscriptions.Add([string]$entry.Cell.SubscriptionId) }
        }
        if ($scopeSubscriptions.Count -eq 0) { $issues.Add((New-ForecastIssue -Code 'SCOPE-EMPTY' -Message "No MCA rows match billing profile '$(ConvertTo-ForecastSafeText $target 120)'. Check the billing profile ID and that the export covers it.")) }
    }
    else { foreach ($id in @($Settings.scope.subscriptionIds)) { $normalized = ConvertTo-ForecastSubscriptionId -Value $id; if ($normalized) { [void]$scopeSubscriptions.Add($normalized) } } }

    # Unclassified publishers need a decision per agreement before they count.
    # The decision is tied to the set of publisher names, not amounts, so new
    # daily data doesn't reopen it; a new publisher does.
    $unclassified = @{}
    foreach ($entry in $entries) {
        if ($entry.Cell.PublisherClass -ne 'Unclassified' -or $entry.Cell.Stream -in 'Credit', 'Tax') { continue }
        $side = [string]$entry.Cell.Agreement
        if (-not $unclassified.ContainsKey($side)) { $unclassified[$side] = [pscustomobject]@{ Rows = 0L; Total = 0d; Names = [Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase) } }
        $unclassified[$side].Rows += [long]$entry.Cell.Rows
        $unclassified[$side].Total += [decimal]$entry.Cell.Cost
        [void]$unclassified[$side].Names.Add(([string]$entry.Cell.PublisherName).Trim())
    }
    $publisherDecision = @{}
    foreach ($side in $unclassified.Keys) {
        $stats = $unclassified[$side]
        $publisherNames = @($stats.Names | ForEach-Object { $_.ToLowerInvariant() })
        $shown = (@($stats.Names | Select-Object -First 10 | ForEach-Object { ConvertTo-ForecastSafeText $_ 60 }) -join ', ') + $(if ($stats.Names.Count -gt 10) { ", and $($stats.Names.Count - 10) more" } else { '' })
        $review = New-ForecastReviewItem -Key "publisher:${scopeKey}:$side" -Fingerprint (Get-ForecastHash -Text ($publisherNames -join '|')) -Category 'Publisher' -Reviews $Reviews -Subject $side `
            -Title "Unclassified publisher on $side rows" `
            -Detail "$($stats.Rows) row(s) totaling $(Format-ForecastAmount $stats.Total) name a publisher other than Microsoft but aren't marked Marketplace: $shown. Microsoft Learn documents PublisherType as 'Azure' for every EA row, so EA Marketplace charges can look like this. Treat them as Marketplace (excluded by default) or as Microsoft charges. Until you decide, they're treated as Marketplace." `
            -Options @('TreatAsMarketplace', 'TreatAsMicrosoft') -Suggested 'TreatAsMarketplace'
        $reviewItems.Add($review)
        $publisherDecision[$side] = $review.Decision
    }

    $includeMarketplace = [bool]$Settings.filters.includeMarketplace
    $includeTax = [bool]$Settings.filters.includeTax
    $included = [Collections.Generic.List[object]]::new()
    $monthTotals = @{}
    $newTotals = { [pscustomobject]@{ RunRate = 0d; Purchase = 0d; Adjustment = 0d; Other = 0d; Credit = 0d; Marketplace = 0d; Tax = 0d; Unattributed = 0d; Boundary = 0d; Scope = 0d; Overlap = 0d; Currencies = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) } }
    $unknownTypes = @{}
    $entriesByRunMonth = @{}
    $agreementsByMonth = @{}
    foreach ($entry in $entries) {
        $cell = $entry.Cell
        $month = [string]$cell.Month
        $runMonthKey = "$month|$($entry.Selected.RunKey)"
        if (-not $entriesByRunMonth.ContainsKey($runMonthKey)) { $entriesByRunMonth[$runMonthKey] = [Collections.Generic.List[object]]::new() }
        $entriesByRunMonth[$runMonthKey].Add($entry)
        if (-not $agreementsByMonth.ContainsKey($month)) { $agreementsByMonth[$month] = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }
        [void]$agreementsByMonth[$month].Add([string]$cell.Agreement)
        if (-not $monthTotals.ContainsKey($month)) { $monthTotals[$month] = & $newTotals }
        $totals = $monthTotals[$month]
        $cost = [decimal]$cell.Cost
        $carrierKey = & $getCarrierKey $cell
        $inScope = if ($Settings.scope.kind -eq 'BillingProfile') {
            ($cell.Agreement -eq 'MCA' -and (Test-ForecastBillingProfileMatch -CellProfile $cell.BillingProfileId -Target $target)) -or
            ($cell.Agreement -ne 'MCA' -and $cell.SubscriptionId -and $scopeSubscriptions.Contains([string]$cell.SubscriptionId))
        }
        else { $cell.SubscriptionId -and $scopeSubscriptions.Contains([string]$cell.SubscriptionId) }
        $publisher = [string]$cell.PublisherClass
        if ($publisher -eq 'Unclassified') { $publisher = if ($publisherDecision[[string]$cell.Agreement] -eq 'TreatAsMicrosoft') { 'Microsoft' } else { 'Marketplace' } }

        $disposition = if ($cell.Boundary -eq 'In' -and $winners.ContainsKey($carrierKey) -and $winners[$carrierKey] -ne $entry.Selected.GroupKey) { 'Overlap' }
        elseif ($cell.Boundary -ne 'In') { 'Boundary' }
        elseif (-not $inScope) { if ($cell.SubscriptionId) { 'Scope' } else { 'Unattributed' } }
        elseif ($cell.Stream -eq 'Credit') { 'Credit' }
        elseif ($cell.Stream -eq 'Tax' -and -not $includeTax) { 'Tax' }
        elseif ($publisher -eq 'Marketplace' -and -not $includeMarketplace) { 'Marketplace' }
        else { 'Included' }
        $entry.Disposition = $disposition
        switch ($disposition) {
            'Included' {
                switch ($cell.Stream) {
                    'RunRate' { $totals.RunRate += $cost }
                    'Purchase' { $totals.Purchase += $cost }
                    'Adjustment' { $totals.Adjustment += $cost }
                    default { $totals.Other += $cost }
                }
                [void]$totals.Currencies.Add([string]$cell.Currency)
                if ($cell.Stream -eq 'Other') {
                    if (-not $unknownTypes.ContainsKey($cell.ChargeType)) { $unknownTypes[$cell.ChargeType] = 0d }
                    $unknownTypes[$cell.ChargeType] += $cost
                }
                $included.Add([pscustomobject]@{
                        Month = $month; SourceId = $entry.Selected.SourceId; RunId = $entry.Selected.RunId; OriginalScope = $entry.Selected.Scope; Dataset = $entry.Selected.Dataset
                        Agreement = $cell.Agreement; SubscriptionId = $cell.SubscriptionId; ResourceGroup = $cell.ResourceGroup; Tag = $cell.Tag
                        ChargeType = $cell.ChargeType; Stream = $cell.Stream; PublisherClass = $publisher; PricingModel = $cell.PricingModel
                        CommitmentId = $cell.CommitmentId; Frequency = $cell.Frequency; BillingProfileId = $cell.BillingProfileId; Currency = $cell.Currency
                        Cost = $cost; Rows = [long]$cell.Rows; CoveredRows = [long]$cell.CoveredRows; OnDemandEquivalent = $cell.OnDemandEquivalent
                    })
            }
            'Credit' { $totals.Credit += $cost }
            'Tax' { $totals.Tax += $cost }
            'Marketplace' { $totals.Marketplace += $cost }
            'Unattributed' { $totals.Unattributed += $cost }
            'Boundary' { $totals.Boundary += $cost }
            'Scope' { $totals.Scope += $cost }
            'Overlap' { $totals.Overlap += $cost }
        }
    }

    foreach ($type in $unknownTypes.Keys) {
        $reviewItems.Add((New-ForecastReviewItem -Key "chargetype:${scopeKey}:$type" -Fingerprint (Get-ForecastHash -Text $type) -Category 'ChargeType' -Reviews $Reviews -Subject $type `
                    -Title "Unrecognized charge type '$type'" -Detail "Rows with this charge type total $(Format-ForecastAmount $unknownTypes[$type]). They're kept in actuals but left out of growth estimation. Acknowledge after checking what they are." `
                    -Options @('Acknowledged') -Suggested 'Acknowledged'))
    }

    # 2. Migration boundary checks.
    $agreements = @($entries | Where-Object { $_.Disposition -ne 'Scope' -and $_.Cell.Agreement -in 'EA', 'MCA' } | ForEach-Object { [string]$_.Cell.Agreement } | Sort-Object -Unique)
    $boundary = if ($Settings.migration.boundaryDate) { ConvertFrom-ForecastDate -Value $Settings.migration.boundaryDate } else { $null }
    if ($agreements.Count -gt 1 -and -not $boundary) {
        $firstMca = @($entries | Where-Object { $_.Cell.Agreement -eq 'MCA' } | ForEach-Object { [string]$_.Cell.Month } | Sort-Object)[0]
        $issues.Add((New-ForecastIssue -Code 'BND-MISSING' -Message "EA and MCA data are both present. Set the migration boundary date (MCA data starts in $firstMca) so the two histories don't overlap."))
    }
    $boundaryTotal = 0d
    foreach ($totals in $monthTotals.Values) { $boundaryTotal += $totals.Boundary }
    if ($boundary -and @($entries | Where-Object Disposition -EQ 'Boundary').Count -gt 0) {
        $reviewItems.Add((New-ForecastReviewItem -Key "boundary:$scopeKey" -Fingerprint (Get-ForecastHash -Text "$($Settings.migration.boundaryDate)|$(Format-ForecastDecimal $boundaryTotal)") -Category 'Boundary' -Reviews $Reviews `
                    -Title 'Rows excluded by the migration boundary' -Subject ([string]$Settings.migration.boundaryDate) `
                    -Detail "EA rows dated on or after $($Settings.migration.boundaryDate) and MCA rows dated before it total $(Format-ForecastAmount $boundaryTotal) and were excluded. Confirm the boundary is the transition date." `
                    -Options @('Acknowledged') -Suggested 'Acknowledged'))
    }
    $boundaryMonth = if ($boundary) { ConvertTo-ForecastMonthKey -Date $boundary } else { $null }

    # Months, completeness, and reconciliation.
    $selectedByMonth = @{}
    $groupMonths = @{}
    foreach ($selected in @($Selection.Selection)) {
        if (-not $selectedByMonth.ContainsKey($selected.Month)) { $selectedByMonth[$selected.Month] = [Collections.Generic.List[object]]::new() }
        $selectedByMonth[$selected.Month].Add($selected)
        if (-not $groupMonths.ContainsKey($selected.GroupKey)) { $groupMonths[$selected.GroupKey] = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal) }
        [void]$groupMonths[$selected.GroupKey].Add($selected.Month)
    }
    $rows = [Collections.Generic.List[object]]::new()
    $reconciliation = [Collections.Generic.List[object]]::new()
    $currencies = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($month in (@($selectedByMonth.Keys) | Sort-Object)) {
        $selectedRuns = $selectedByMonth[$month]
        $totals = if ($monthTotals.ContainsKey($month)) { $monthTotals[$month] } else { & $newTotals }
        foreach ($currency in $totals.Currencies) { [void]$currencies.Add($currency) }
        $notes = [Collections.Generic.List[string]]::new()
        foreach ($group in $groupMonths.GetEnumerator()) {
            if ($group.Value.Contains($month)) { continue }
            if ([string]::CompareOrdinal($month, $group.Value.Min) -gt 0 -and [string]::CompareOrdinal($month, $group.Value.Max) -lt 0) { $notes.Add("No run for $($group.Key) in this month.") }
        }
        if ($boundaryMonth -eq $month -and $boundary.Day -gt 1) {
            $sides = if ($agreementsByMonth.ContainsKey($month)) { $agreementsByMonth[$month] } else { [Collections.Generic.HashSet[string]]::new() }
            if (-not $sides.Contains('EA') -or -not $sides.Contains('MCA')) { $notes.Add('The migration happens mid-month, but only one agreement''s data is present for this month.') }
        }
        $final = @($selectedRuns | Where-Object { -not $_.Final }).Count -eq 0
        $status = if ($notes.Count) { 'Incomplete' } elseif ($final) { 'Complete' } else { 'Provisional' }
        # A whole month read before the grace period ended can still change.
        if ($status -eq 'Provisional' -and @($selectedRuns | Where-Object { -not $_.Final -and $_.Coverage -in 'Full', 'Unknown' }).Count) {
            $notes.Add("Read less than $([int]$Settings.period.graceDays) days after the month ended, before it counted as final.")
        }
        if ($totals.Currencies.Count -gt 1) { $notes.Add("Multiple billing currencies: $(@($totals.Currencies) -join ', ').") }
        $through = $null; $observedThrough = $null
        $coverageDates = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
        $monthStart = Get-ForecastMonthStart -MonthKey $month
        $lastDay = (Get-ForecastMonthEnd -MonthKey $month).AddDays(-1)
        foreach ($selected in $selectedRuns) {
            $runResult = $byRun[[string]$selected.RunKey]
            $stat = @($runResult.MonthStats | Where-Object Month -EQ $month)[0]
            $runThrough = if ($stat -and $stat.Through) { [datetime]$stat.Through } else { $null }
            if ($runThrough -and ($null -eq $observedThrough -or $runThrough -lt $observedThrough)) { $observedThrough = $runThrough }
            if ($runResult.HasManifest -and $runResult.Start -and $runResult.End) {
                $coveredEnd = Get-ForecastRunLastDate -Start $runResult.Start -End $runResult.End
                if ($coveredEnd -gt $lastDay) { $coveredEnd = $lastDay }
                # A configured full-month range can be delivered before month end.
                # Only elapsed days (or a day already carrying charges) are covered.
                if ($runResult.Submitted -and $coveredEnd -ge ([datetime]$runResult.Submitted).Date) {
                    $coveredEnd = ([datetime]$runResult.Submitted).Date.AddDays(-1)
                }
                if ($runThrough -and $runThrough -gt $coveredEnd) { $coveredEnd = $runThrough }
                if ($coveredEnd -ge $monthStart) { $runThrough = $coveredEnd }
            }
            if ($runThrough -and ($null -eq $through -or $runThrough -lt $through)) { $through = $runThrough }
            if ($runThrough) { [void]$coverageDates.Add($runThrough.ToString('yyyy-MM-dd', $script:ForecastInvariant)) }
            $raw = if ($stat) { [decimal]$stat.Total } else { 0d }
            $rawRows = if ($stat) { [long]$stat.Rows } else { 0L }
            $runEntries = $entriesByRunMonth["$month|$($selected.RunKey)"]
            $sum = @{}
            foreach ($disposition in 'Included', 'Credit', 'Tax', 'Marketplace', 'Unattributed', 'Boundary', 'Scope', 'Overlap') { $sum[$disposition] = 0d }
            if ($runEntries) { foreach ($runEntry in $runEntries) { $sum[$runEntry.Disposition] += [decimal]$runEntry.Cell.Cost } }
            $accounted = 0d
            foreach ($value in $sum.Values) { $accounted += $value }
            $outsideCost = if ($firstSelectedMonth[[string]$selected.RunKey] -eq $month) { [decimal]$runResult.OutsideTotal } else { 0d }
            $outsideRows = if ($firstSelectedMonth[[string]$selected.RunKey] -eq $month) { [long]$runResult.OutsideRows } else { 0L }
            $raw += $outsideCost; $rawRows += $outsideRows; $accounted += $outsideCost
            $reconciliation.Add([pscustomobject]@{
                    Month = $month; Source = $selected.Label; RunId = $selected.RunId; Final = $selected.Final; Rows = $rawRows; RawTotal = $raw
                    IncludedHeadline = $sum.Included; Credits = $sum.Credit; ExcludedTax = $sum.Tax; ExcludedMarketplace = $sum.Marketplace
                    ExcludedUnattributed = $sum.Unattributed; ExcludedBoundary = $sum.Boundary; ExcludedScope = $sum.Scope; ExcludedOverlap = $sum.Overlap
                    ExcludedOutsideRange = $outsideCost
                    Difference = $raw - $accounted; Note = if ($selected.Superseded.Count) { "Replaces $($selected.Superseded.Count) earlier run(s)." } else { '' }
                })
            if ($stat -and $stat.PositiveRefundRows -gt 0) {
                $reviewItems.Add((New-ForecastReviewItem -Key "refund:${scopeKey}:${month}:$($selected.RunKey)" -Fingerprint (Get-ForecastHash -Text "$($selected.RunKey)|$($stat.PositiveRefundRows)") -Category 'Refund' -Reviews $Reviews -Subject $month -Required $false `
                            -Title "Positive refund rows in $month" -Detail "$($stat.PositiveRefundRows) refund row(s) total $(Format-ForecastAmount $stat.PositiveRefundTotal) with a positive sign. Signs are kept exactly as exported; check whether these are reversals." `
                            -Options @('Acknowledged') -Suggested 'Acknowledged'))
            }
        }
        if ($status -ne 'Complete' -and $coverageDates.Count -gt 1) {
            $status = 'Incomplete'
            $notes.Add('Selected runs have different coverage cutoffs.')
            $issues.Add((New-ForecastIssue -Code 'RUN-COVERAGE' -Message "Selected runs for $month cover different dates ($(@($coverageDates) -join ', ')). Refresh until their cutoffs align; one remaining-days forecast would count some days twice." -Subject $month))
        }
        if ($status -eq 'Complete' -and $observedThrough -and $observedThrough.Date -lt $lastDay) {
            $gap = [int]($lastDay - $observedThrough.Date).TotalDays
            $notes.Add("Last charge is dated $gap day(s) before month end.")
            $issues.Add((New-ForecastIssue -Code 'RUN-EARLYEND' -Severity 'Warn' -Message "$month is final, but its last charge is dated $($observedThrough.ToString('yyyy-MM-dd', $script:ForecastInvariant)), $gap day(s) before month end. Check the export covers the whole month." -Subject $month))
        }
        $runRate = $totals.RunRate
        $rows.Add([pscustomobject]@{
                Month = $month; Status = $status; Days = Get-ForecastDaysInMonth -MonthKey $month
                RunRate = $runRate; Purchase = $totals.Purchase; Adjustment = $totals.Adjustment; Other = $totals.Other
                Headline = $runRate + $totals.Purchase + $totals.Adjustment + $totals.Other; Credit = $totals.Credit
                ExcludedMarketplace = $totals.Marketplace; ExcludedTax = $totals.Tax; ExcludedUnattributed = $totals.Unattributed
                ExcludedBoundary = $totals.Boundary; ExcludedScope = $totals.Scope; ExcludedOverlap = $totals.Overlap
                DataThrough = $through; Provenance = @($selectedRuns | ForEach-Object { "$($_.Label): run $($_.RunId)$(if ($_.Final) { '' } else { ' (not final)' })" })
                Approved = $true; Note = ($notes -join ' ')
            })
    }
    if ($currencies.Count -gt 1) { $issues.Add((New-ForecastIssue -Code 'CUR-MIXED' -Message "The history mixes billing currencies ($(@($currencies) -join ', ')). Amounts in different currencies can't be added together; scope the forecast to one currency.")) }
    foreach ($row in $reconciliation) {
        if (Test-ForecastMaterialDifference $row.Difference) {
            $shown = if ([math]::Abs([decimal]$row.Difference) -ge 0.01d) { Format-ForecastAmount $row.Difference } else { ([decimal]$row.Difference).ToString('G', $script:ForecastInvariant) }
            $issues.Add((New-ForecastIssue -Code 'REC-DIFF' -Message "$($row.Month) $($row.Source) doesn't reconcile: $shown is unaccounted for." -Subject $row.Month))
        }
    }

    # Recurring purchases that no scheduled item covers would be missing from
    # the forecast, because purchases aren't grown with the run rate.
    $completeMonths = @($rows | Where-Object Status -EQ 'Complete' | ForEach-Object Month | Sort-Object | Select-Object -Last 3)
    $commitments = @{}
    foreach ($cell in $included) {
        if ($cell.Stream -ne 'Purchase' -or -not $cell.CommitmentId -or $cell.ChargeType -ne 'Purchase') { continue }
        if (-not $commitments.ContainsKey($cell.CommitmentId)) { $commitments[$cell.CommitmentId] = [pscustomobject]@{ Months = [Collections.Generic.HashSet[string]]::new(); Recurring = $false; Last = 0d } }
        [void]$commitments[$cell.CommitmentId].Months.Add($cell.Month)
        if ($cell.Frequency -match '^(?i)recurring$') { $commitments[$cell.CommitmentId].Recurring = $true }
        if ($cell.Month -eq $completeMonths[-1]) { $commitments[$cell.CommitmentId].Last += [decimal]$cell.Cost }
    }
    $scheduledText = (@($Settings.scheduledItems | ForEach-Object { "$($_.id) $($_.commitmentId) $($_.description)" }) -join ' ').ToLowerInvariant()
    $recurring = [Collections.Generic.List[object]]::new()
    foreach ($entry in $commitments.GetEnumerator()) {
        $inRecent = $completeMonths.Count -eq 3 -and @($completeMonths | Where-Object { $entry.Value.Months.Contains($_) }).Count -eq 3
        if (-not ($inRecent -or ($entry.Value.Recurring -and $completeMonths.Count -and $entry.Value.Months.Contains($completeMonths[-1])))) { continue }
        $recurring.Add([pscustomobject]@{ CommitmentId = $entry.Key; LastAmount = $entry.Value.Last; Months = @($entry.Value.Months | Sort-Object) })
        if ($scheduledText.Contains($entry.Key) -or @($Settings.scheduledItems | Where-Object { Test-ForecastCommitmentMatch -Scheduled ([string]$_.commitmentId) -Posted $entry.Key }).Count) { continue }
        $reviewItems.Add((New-ForecastReviewItem -Key "recurring:${scopeKey}:$($entry.Key)" -Fingerprint (Get-ForecastHash -Text $entry.Key) -Category 'RecurringPurchase' -Reviews $Reviews -Subject $entry.Key `
                    -Title "Recurring purchase without a scheduled item" -Detail "Commitment $($entry.Key) was billed $(Format-ForecastAmount $entry.Value.Last) in $($completeMonths[-1]) and recurs. Purchases aren't grown with the run rate, so add a scheduled item (include the commitment ID) or confirm it won't recur." `
                    -Options @('Scheduled', 'NotRecurring') -Suggested 'Scheduled'))
    }

    $population = @{}
    foreach ($cell in $included) {
        if ($cell.Stream -ne 'RunRate' -or -not $cell.SubscriptionId) { continue }
        if (-not $population.ContainsKey($cell.SubscriptionId)) { $population[$cell.SubscriptionId] = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }
        [void]$population[$cell.SubscriptionId].Add($cell.Month)
    }
    $latestThrough = @($rows | Where-Object DataThrough | ForEach-Object { [datetime]$_.DataThrough } | Sort-Object)[-1]
    [pscustomobject]@{
        Mode = 'Exports'; Currency = if ($currencies.Count -eq 1) { @($currencies)[0] } elseif ($currencies.Count -gt 1) { 'Mixed' } else { '' }
        Months = $rows.ToArray(); Cells = $included.ToArray(); Reviews = $reviewItems.ToArray(); Issues = $issues.ToArray()
        Reconciliation = $reconciliation.ToArray(); Runs = @($Selection.Selection); SubscriptionNames = $names
        RecurringPurchases = $recurring.ToArray(); Population = $population; ScopeSubscriptions = @($scopeSubscriptions)
        DataThrough = $latestThrough
    }
}
