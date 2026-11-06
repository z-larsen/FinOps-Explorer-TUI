# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
param()

###########################################################################
# FORECAST.BACKTEST.PS1
# HISTORICAL BACKTEST OF THE RUN-RATE METHOD
###########################################################################
# For each cutoff month with a full lookback window before it and at least
# one later complete month, the method is fitted on that window and its
# run-rate forecast is compared with the run-rate actuals that followed.
#
# The backtest can't replay human review decisions made later, so it uses
# the automatic rule: flagged and undefined changes are excluded, and an
# anomalous latest month uses the median of the last three months. Results
# describe how this method would have performed, not a calibrated accuracy.
###########################################################################

function Invoke-ForecastBacktest {
    param(
        [Parameter(Mandatory)]$Dataset,
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)][string]$LastMonth
    )
    $length = [int]$Settings.period.lookbackMonths
    $horizonLimit = [math]::Max(1, [int]$Settings.method.backtestHorizon)
    $usable = Invoke-ForecastSort -Items @($Dataset.Months | Where-Object { (Test-ForecastMonthUsable $_) -and [string]::CompareOrdinal([string]$_.Month, $LastMonth) -le 0 }) `
            -Comparison { param($a, $b) [string]::CompareOrdinal([string]$a.Month, [string]$b.Month) }
    $byMonth = @{}
    foreach ($row in $usable) { $byMonth[[string]$row.Month] = $row }

    $results = [Collections.Generic.List[object]]::new()
    $cutoffs = [Collections.Generic.List[string]]::new()
    foreach ($row in $usable) {
        $cutoff = [string]$row.Month
        $first = Add-ForecastMonth -MonthKey $cutoff -Count (-1 * ($length - 1))
        $windowMonths = Get-ForecastMonthSpan -First $first -Last $cutoff
        if (@($windowMonths | Where-Object { -not $byMonth.ContainsKey($_) }).Count -gt 0) { continue }
        $next = Add-ForecastMonth -MonthKey $cutoff -Count 1
        if (-not $byMonth.ContainsKey($next)) { continue }
        $windowRows = @($windowMonths | ForEach-Object { $byMonth[$_] })
        $comparisons = Get-ForecastComparisons -Rows $windowRows -Settings $Settings -Reviews @{}
        foreach ($comparison in $comparisons.Items) {
            if ($comparison.Flagged) { $comparison.Retained = $false }
        }
        $growth = Get-ForecastGrowth -Comparisons $comparisons -Settings $Settings
        if (-not $growth.Sufficient) { continue }
        $lastComparison = @($comparisons.Items)[-1]
        $baseline = Get-ForecastNormalizedRunRate $byMonth[$cutoff]
        if ($lastComparison.Flagged -or $lastComparison.Status -eq 'Undefined') {
            $baseline = Get-ForecastMedian -Values ([decimal[]]@($windowRows | Select-Object -Last 3 | ForEach-Object { Get-ForecastNormalizedRunRate $_ }))
        }
        $cutoffs.Add($cutoff)
        for ($h = 1; $h -le $horizonLimit; $h++) {
            $month = Add-ForecastMonth -MonthKey $cutoff -Count $h
            if (-not $byMonth.ContainsKey($month)) { break }
            $days = [decimal](Get-ForecastDaysInMonth -MonthKey $month)
            $actual = [decimal]$byMonth[$month].RunRate
            $forecast = @{}
            foreach ($path in 'Low', 'Central', 'High') {
                $forecast[$path] = [decimal]$baseline * (Get-ForecastCompound -Rate ([decimal]$growth.$path) -Periods $h) * ($days / 30d)
            }
            $errorRatio = if ($actual -gt 0) { ($forecast.Central - $actual) / $actual } else { $null }
            $results.Add([pscustomobject]@{
                    Cutoff = $cutoff; Month = $month; Horizon = $h; Actual = $actual
                    ForecastLow = $forecast.Low; ForecastCentral = $forecast.Central; ForecastHigh = $forecast.High
                    ErrorRatio = $errorRatio
                    InRange = ($actual -ge [math]::Min($forecast.Low, $forecast.High) -and $actual -le [math]::Max($forecast.Low, $forecast.High))
                })
        }
    }
    $scored = @($results | Where-Object { $null -ne $_.ErrorRatio })
    $mape = $null; $bias = $null; $coverage = $null
    if ($scored.Count) {
        $absolute = 0d; $signed = 0d
        foreach ($result in $scored) { $absolute += [math]::Abs([decimal]$result.ErrorRatio); $signed += [decimal]$result.ErrorRatio }
        $mape = $absolute / [decimal]$scored.Count
        $bias = $signed / [decimal]$scored.Count
    }
    if ($results.Count) { $coverage = [decimal]@($results | Where-Object InRange).Count / [decimal]$results.Count }
    $status = if ($results.Count) { 'Completed' } else { 'InsufficientHistory' }
    $note = if ($results.Count) {
        "$($cutoffs.Count) cutoff(s), $($results.Count) forecast month(s). Uses automatic exclusions, not review decisions."
    }
    else { "Backtesting needs at least $($length + 1) consecutive complete months, so each cutoff has a full lookback window and a later month to compare." }
    [pscustomobject]@{
        Status = $status; Note = $note; Cutoffs = $cutoffs.ToArray(); Results = $results.ToArray()
        MeanAbsoluteErrorRatio = $mape; MeanErrorRatio = $bias; ObservedInRangeRatio = $coverage
    }
}
