# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
param()

###########################################################################
# FORECAST.REPORTS.PS1
# CSV AND TEXT OUTPUTS, AND THE METHOD DISCLOSURE
###########################################################################
# Reports go to a new private run folder from FinOps Explorer's report
# writer (local disk, owner-only, never overwritten). Every CSV cell passes
# through Explorer's formula-injection guard. CSVs carry every row; nothing
# is truncated to a top-N list.
###########################################################################

function Get-ForecastCsvAmount {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    return [decimal]::Round([decimal]$Value, 8, [MidpointRounding]::ToEven)
}

function ConvertTo-ForecastCsvLines {
    param([AllowEmptyCollection()][object[]]$Rows, [Parameter(Mandatory)][string[]]$Columns)
    $safe = foreach ($row in @($Rows)) {
        $record = [ordered]@{}
        foreach ($column in $Columns) {
            $value = $row.$column
            if ($value -is [decimal]) { $value = Get-ForecastCsvAmount $value }
            elseif ($value -is [array]) { $value = ($value | ForEach-Object { [string]$_ }) -join '; ' }
            $record[$column] = ConvertTo-FinOpsExportCell $value
        }
        [pscustomobject]$record
    }
    if (-not $safe) { return , @(($Columns | ForEach-Object { '"' + $_ + '"' }) -join ',') }
    return , @($safe | ConvertTo-Csv -NoTypeInformation)
}

function Get-ForecastDisclosure {
    param([Parameter(Mandatory)]$Model, [Parameter(Mandatory)]$Dataset, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Readiness, $Backtest)
    $currency = $Dataset.Currency
    $window = $Model.Window
    $comparisons = $Model.Comparisons
    $growth = $Model.Growth
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('BASIS')
    $lines.Add("- Pre-credit cost in the billing currency ($currency): CostInBillingCurrency (EA), costInBillingCurrency (MCA), or BilledCost (FOCUS), described by Microsoft as cost before credits or taxes. Negotiated discounts are reflected; list prices are not used.")
    $lines.Add('- Cost Management data doesn''t include Azure credits or taxes; credits found in inputs are reported but never counted.')
    $lines.Add("- Marketplace charges are $(if ($Settings.filters.includeMarketplace) { 'included' } else { 'excluded' }); tax is $(if ($Settings.filters.includeTax) { 'included' } else { 'excluded' }).")
    $lines.Add("- Source: $(if ($Dataset.Mode -eq 'Manual') { 'manual inputs with recorded evidence' } else { "$(@($Dataset.Runs).Count) selected run-month(s) from $(Get-ForecastSourceCountText -Sources @($Settings.sources)); see forecast-provenance.csv" }).")
    $lines.Add('')
    $lines.Add('LOOKBACK AND COMPARISONS')
    $lines.Add("- Window: $($window.First) to $($window.Last) ($(@($window.Rows).Count) months). The latest month eligible as final is $($window.LastEligible) (grace $($Settings.period.graceDays) days after month end).")
    if ($Readiness.Status -eq 'Preliminary' -or [int]$Settings.period.lookbackMonths -lt $script:ForecastReadyMonths) {
        $lines.Add("- PRELIMINARY: only $($Settings.period.lookbackMonths) months of history ($([int]$Settings.period.lookbackMonths - 1) month-to-month changes) were used. Growth and its range rest on very few observations, so treat this as an early indication, not a forecast to commit to. A Ready forecast needs $($script:ForecastReadyMonths) months.")
    }
    $lines.Add('- Each month is normalized to a 30-day run rate: cost / days in month x 30, using Usage charges. Unused reservation and savings plan charges appear only in amortized cost, which isn''t accepted.')
    $byHand = @($comparisons.Items | Where-Object { -not $_.Flagged -and $_.Review -and $_.Review.Category -eq 'Comparison' }).Count
    $lines.Add("- $($comparisons.Expected) adjacent-month comparisons; $(@($comparisons.Items | Where-Object Retained).Count) retained, $(@($comparisons.Items | Where-Object Status -EQ 'Undefined').Count) undefined, $(@($comparisons.Items | Where-Object Flagged).Count) flagged$(if ($byHand) { ", $byHand reviewed by hand" }).")
    $lines.Add("- Flag rule: |change - median| > max($(Format-ForecastDecimal $comparisons.K) x scaled MAD, $(Format-ForecastPercent $comparisons.MinimumDeviation)). Median $(Format-ForecastPercent $comparisons.Median); threshold $(Format-ForecastPercent $comparisons.Threshold).")
    foreach ($item in @($comparisons.Items | Where-Object { $_.Status -ne 'Defined' -or $_.Flagged -or $_.Review })) {
        $decision = if ($item.Review) { $item.Review.Decision } else { 'n/a' }
        $note = if ($item.Review -and $item.Review.Note) { " Note: $($item.Review.Note)" } else { '' }
        $lines.Add("  - $($item.FromMonth) to $($item.ToMonth): $($item.Status), change $(Format-ForecastPercent $item.Change), decision $decision, retained $($item.Retained).$note")
    }
    $lines.Add('- Actual charges are never removed from actuals. Exclusions apply only to growth estimation.')
    $lines.Add('')
    $lines.Add('GROWTH AND SENSITIVITY')
    $lines.Add("- Central growth: median of retained changes = $(Format-ForecastPercent $growth.Central 2) a month.")
    if ($growth.RangeMethod -eq 'LowestToHighest') {
        $lines.Add("- Sensitivity range: lowest to highest retained change = $(Format-ForecastPercent $growth.Low 2) to $(Format-ForecastPercent $growth.High 2) a month. With fewer than $($script:ForecastReadyMonths) months, percentiles of so few changes would be mostly interpolation, so the full observed range is used; P$($Settings.method.lowPercentile) to P$($Settings.method.highPercentile) applies from $($script:ForecastReadyMonths) months.")
    }
    else { $lines.Add("- Sensitivity range: percentile $(Format-ForecastDecimal $growth.LowPercentile) to $(Format-ForecastDecimal $growth.HighPercentile) of retained changes (linear interpolation, like Excel PERCENTILE.INC) = $(Format-ForecastPercent $growth.Low 2) to $(Format-ForecastPercent $growth.High 2) a month.") }
    $lines.Add('- This range reflects historical month-to-month variability. It is a sensitivity range, not a calibrated confidence interval.')
    $lines.Add("- Baseline: $(Format-ForecastAmount $Model.Baseline.Value $currency) a 30-day month ($($Model.Baseline.Method)). $($Model.Baseline.Detail)")
    $lines.Add('- Month j forecast = baseline x (1 + growth)^h x days(j) / 30, where h counts months after the window''s last month.')
    $lines.Add('')
    $lines.Add('FISCAL-YEAR AGGREGATION')
    $fy = $Model.Projection.FiscalYear
    $lines.Add("- $($fy.Label) runs $($fy.FirstMonth) to $($fy.LastMonth). Total = actuals for completed months + month-to-date actuals and the rest of the current month + forecast for remaining months + scheduled items.")
    $lines.Add('- Low and high totals each follow one growth path for every month. They are not sums of independent monthly percentiles.')
    $lines.Add('- Purchases, refunds, and adjustments stay in actuals but aren''t grown. Future purchases, renewals, and business changes come only from scheduled items.')
    foreach ($item in @($Model.Schedule.Valid)) {
        $lines.Add("  - $($item.id) ($($item.type), $($item.recurrence) from $($item.startMonth)$(if ($item.endMonth) { " to $($item.endMonth)" })): amount $(Format-ForecastAmount (Read-ForecastDecimal $item.amount) $currency), treatment $($item.baselineTreatment).")
    }
    $lines.Add('')
    $lines.Add('KNOWN LIMITATIONS')
    $lines.Add('- Microsoft Learn documents PublisherType as Azure for every EA row. EA rows that name a non-Microsoft publisher are treated by review decision, not guessed.')
    $lines.Add('- Learn doesn''t document the sign of Refund rows; signs are kept exactly as exported and positive refunds are flagged.')
    $lines.Add('- RoundingAdjustment rows appear only after an invoice and only at billing scope; subscription-scoped totals can differ slightly from invoices.')
    if ($Readiness.Labels.Count) { $lines.Add("- Labels: $($Readiness.Labels -join ', ').") }
    if ($Backtest) {
        $lines.Add('')
        $lines.Add('BACKTEST')
        $lines.Add("- $($Backtest.Note)")
        if ($Backtest.Status -eq 'Completed') {
            $lines.Add("- Mean absolute error $(Format-ForecastPercent $Backtest.MeanAbsoluteErrorRatio); mean error (bias) $(Format-ForecastPercent $Backtest.MeanErrorRatio); actuals inside the sensitivity range $(Format-ForecastPercent $Backtest.ObservedInRangeRatio 0) of the time. These are observed historical results, not a calibration.")
        }
    }
    return $lines.ToArray()
}

function Get-ForecastDisplayLabels {
    # Labels shown beside the status, without repeating a Preliminary status.
    param([Parameter(Mandatory)]$Readiness)
    return , @($Readiness.Labels | Where-Object { $_ -and -not ($Readiness.Status -eq 'Preliminary' -and $_ -like 'Preliminary*') })
}

function Get-ForecastSummaryLines {
    param([Parameter(Mandatory)]$Model, [Parameter(Mandatory)]$Dataset, [Parameter(Mandatory)]$Readiness, $Workloads, [string]$ScopeLabel)
    $currency = $Dataset.Currency
    $projection = $Model.Projection
    $statusLabels = Get-ForecastDisplayLabels -Readiness $Readiness
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('FinOps Explorer - pre-credit forecast')
    $lines.Add("Generated: $([datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm', $script:ForecastInvariant)) UTC; as of $(([datetime]$Model.AsOf).ToString('yyyy-MM-dd', $script:ForecastInvariant))")
    $lines.Add("Scope: $(ConvertTo-ForecastSafeText $ScopeLabel 200)")
    $lines.Add("Status: $($Readiness.Status)$(if ($statusLabels.Count) { " ($($statusLabels -join ', '))" })")
    $lines.Add('')
    $lines.Add("$($projection.FiscalYear.Label) ($($projection.FiscalYear.FirstMonth) to $($projection.FiscalYear.LastMonth)), pre-credit, $currency")
    $lines.Add("  Central estimate:  $(Format-ForecastAmount $projection.TotalCentral $currency)")
    $lines.Add("  Sensitivity range: $(Format-ForecastAmount $projection.TotalLow $currency) to $(Format-ForecastAmount $projection.TotalHigh $currency)")
    $lines.Add("  Actuals to date:   $(Format-ForecastAmount $projection.ActualToDate $currency)")
    $lines.Add("  Scheduled items:   $(Format-ForecastAmount $projection.Scheduled $currency)")
    $lines.Add('')
    $lines.Add('Checks')
    foreach ($check in $Readiness.Checks) { $lines.Add("  [$($check.Status.ToUpperInvariant())] $($check.Name): $($check.Detail)") }
    if ($Workloads -and @($Workloads.Workloads).Count) {
        $lines.Add('')
        $count = @($Workloads.Workloads).Count
        $lines.Add("Largest run-rate changes ($([math]::Min(10, $count)) of $count workloads; all are in workloads.csv and the HTML report)")
        foreach ($workload in @($Workloads.Workloads | Select-Object -First 10)) {
            $lines.Add("  $(ConvertTo-ForecastSafeText $workload.WorkloadName 60): $(Format-ForecastAmount $workload.Change $currency), $(Format-ForecastPercent $workload.Growth), share $(Format-ForecastPercent $workload.ContributionShare)$(if ($workload.Flags) { " [$($workload.Flags)]" })")
        }
    }
    return $lines.ToArray()
}

function Export-ForecastReport {
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)]$Dataset,
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)]$Readiness,
        $Workloads,
        $Backtest,
        [string]$OutputPath,
        [string]$ScopeLabel,
        [string]$VintageName
    )
    $directory = New-FinOpsReportDirectory -OutputPath $OutputPath
    $disclosure = Get-ForecastDisclosure -Model $Model -Dataset $Dataset -Settings $Settings -Readiness $Readiness -Backtest $Backtest
    $summary = @(Get-ForecastSummaryLines -Model $Model -Dataset $Dataset -Readiness $Readiness -Workloads $Workloads -ScopeLabel $ScopeLabel)
    if ($VintageName) { $summary += "Saved vintage: $VintageName" }
    Write-FinOpsReportFile -Directory $directory -Name 'forecast-summary.txt' -Lines @($summary + '' + 'METHOD' + $disclosure)

    $history = foreach ($row in @($Model.Window.Rows)) {
        $row | Select-Object *, @{ Name = 'NormalizedRunRate'; Expression = { if (Test-ForecastMonthUsable $_) { Get-ForecastNormalizedRunRate $_ } else { $null } } }
    }
    Write-FinOpsReportFile -Directory $directory -Name 'forecast-history.csv' -Lines (ConvertTo-ForecastCsvLines -Rows $history -Columns @('Month', 'Status', 'Days', 'RunRate', 'NormalizedRunRate', 'Purchase', 'Adjustment', 'Other', 'Headline', 'Credit', 'ExcludedMarketplace', 'ExcludedTax', 'ExcludedUnattributed', 'ExcludedBoundary', 'ExcludedScope', 'ExcludedOverlap', 'DataThrough', 'Provenance', 'Note'))
    $comparisonRows = foreach ($item in @($Model.Comparisons.Items)) { $item | Select-Object *, @{ Name = 'Decision'; Expression = { if ($_.Review) { $_.Review.Decision } else { $null } } }, @{ Name = 'ReviewNote'; Expression = { if ($_.Review) { $_.Review.Note } else { $null } } } }
    Write-FinOpsReportFile -Directory $directory -Name 'forecast-comparisons.csv' -Lines (ConvertTo-ForecastCsvLines -Rows $comparisonRows -Columns @('Index', 'FromMonth', 'ToMonth', 'FromRunRate', 'ToRunRate', 'Change', 'Status', 'Flagged', 'Deviation', 'Suggestion', 'Decision', 'ReviewNote', 'Retained', 'Reason'))
    Write-FinOpsReportFile -Directory $directory -Name 'forecast-monthly.csv' -Lines (ConvertTo-ForecastCsvLines -Rows $Model.Projection.Rows -Columns @('Month', 'Kind', 'Horizon', 'Days', 'DaysWithData', 'Actual', 'Scheduled', 'ScheduledAlreadyPosted', 'RunRateLow', 'RunRateCentral', 'RunRateHigh', 'TotalLow', 'TotalCentral', 'TotalHigh', 'Note'))
    $fiscal = [pscustomobject]@{
        FiscalYear = $Model.Projection.FiscalYear.Label; FirstMonth = $Model.Projection.FiscalYear.FirstMonth; LastMonth = $Model.Projection.FiscalYear.LastMonth; Currency = $Dataset.Currency
        ActualToDate = $Model.Projection.ActualToDate; Scheduled = $Model.Projection.Scheduled; TotalLow = $Model.Projection.TotalLow; TotalCentral = $Model.Projection.TotalCentral; TotalHigh = $Model.Projection.TotalHigh
        GrowthLow = $Model.Growth.Low; GrowthCentral = $Model.Growth.Central; GrowthHigh = $Model.Growth.High; Baseline = $Model.Baseline.Value; BaselineMethod = $Model.Baseline.Method
        Status = $Readiness.Status; Labels = $Readiness.Labels
    }
    Write-FinOpsReportFile -Directory $directory -Name 'forecast-fiscal-year.csv' -Lines (ConvertTo-ForecastCsvLines -Rows @($fiscal) -Columns @($fiscal.PSObject.Properties.Name))
    Write-FinOpsReportFile -Directory $directory -Name 'forecast-scheduled-items.csv' -Lines (ConvertTo-ForecastCsvLines -Rows $Model.ScheduleEffects -Columns @('Id', 'Type', 'Month', 'Amount', 'Replaced', 'Net', 'Treatment'))
    Write-FinOpsReportFile -Directory $directory -Name 'forecast-checks.csv' -Lines (ConvertTo-ForecastCsvLines -Rows $Readiness.Checks -Columns @('Id', 'Name', 'Status', 'Detail'))
    Write-FinOpsReportFile -Directory $directory -Name 'forecast-reviews.csv' -Lines (ConvertTo-ForecastCsvLines -Rows $Readiness.Reviews -Columns @('Category', 'Subject', 'Title', 'Required', 'Decision', 'Note', 'DecidedUtc', 'Stale', 'Detail', 'Key'))
    Write-FinOpsReportFile -Directory $directory -Name 'forecast-reconciliation.csv' -Lines (ConvertTo-ForecastCsvLines -Rows $Dataset.Reconciliation -Columns @('Month', 'Source', 'RunId', 'Final', 'Rows', 'RawTotal', 'IncludedHeadline', 'Credits', 'ExcludedTax', 'ExcludedMarketplace', 'ExcludedUnattributed', 'ExcludedBoundary', 'ExcludedScope', 'ExcludedOverlap', 'ExcludedOutsideRange', 'Difference', 'Note'))
    Write-FinOpsReportFile -Directory $directory -Name 'forecast-provenance.csv' -Lines (ConvertTo-ForecastCsvLines -Rows $Dataset.Runs -Columns @('Month', 'Label', 'RunId', 'SourceId', 'Submitted', 'Final', 'Superseded', 'Skipped'))
    if ($Workloads) {
        Write-FinOpsReportFile -Directory $directory -Name 'workloads.csv' -Lines (ConvertTo-ForecastCsvLines -Rows $Workloads.Workloads -Columns @('WorkloadId', 'WorkloadName', 'Source', 'Mapped', 'Flags', 'FirstMonth', 'LastMonth', 'FirstRunRate', 'LastRunRate', 'Change', 'Growth', 'ContributionShare', 'LargestIncreaseMonth', 'LargestIncreaseAmount', 'LookbackSpend', 'LatestMonthSpend', 'CoveredShareFirst', 'CoveredShareLast', 'OnDemandEquivalentLast', 'SubscriptionsLast', 'Notes'))
        $long = foreach ($workload in @($Workloads.Workloads)) {
            for ($i = 0; $i -lt $Workloads.Months.Count; $i++) { [pscustomobject]@{ WorkloadId = $workload.WorkloadId; WorkloadName = $workload.WorkloadName; Month = $Workloads.Months[$i]; RunRate = $workload.MonthlyRunRate[$i] } }
        }
        Write-FinOpsReportFile -Directory $directory -Name 'workload-monthly.csv' -Lines (ConvertTo-ForecastCsvLines -Rows @($long) -Columns @('WorkloadId', 'WorkloadName', 'Month', 'RunRate'))
        Write-FinOpsReportFile -Directory $directory -Name 'purchases.csv' -Lines (ConvertTo-ForecastCsvLines -Rows $Workloads.Purchases -Columns @('Month', 'SubscriptionId', 'ChargeType', 'CommitmentId', 'Cost'))
    }
    if ($Backtest) { Write-FinOpsReportFile -Directory $directory -Name 'backtest.csv' -Lines (ConvertTo-ForecastCsvLines -Rows $Backtest.Results -Columns @('Cutoff', 'Month', 'Horizon', 'Actual', 'ForecastLow', 'ForecastCentral', 'ForecastHigh', 'ErrorRatio', 'InRange')) }
    $html = ConvertTo-ForecastHtml -Model $Model -Dataset $Dataset -Readiness $Readiness -Workloads $Workloads -Backtest $Backtest -Disclosure $disclosure -ScopeLabel $ScopeLabel
    Write-FinOpsReportFile -Directory $directory -Name 'forecast-report.html' -Lines @($html)
    return $directory
}
