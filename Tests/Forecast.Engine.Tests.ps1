# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers create synthetic fixtures in TestDrive only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helpers are named for the collections they build.')]
param()
BeforeAll {
    . (Join-Path $PSScriptRoot 'Forecast.TestHelpers.ps1')
    $script:AsOf = [datetime]::SpecifyKind([datetime]'2026-11-05T12:00:00', [DateTimeKind]::Utc)
    $script:Window = Get-TestMonthKeys -Last '2026-10'

    function New-RateSeries {
        # Converts 30-day run rates into monthly costs so normalization recovers the rates exactly.
        param([decimal[]]$Rates, [string[]]$Months = $script:Window)
        $values = [ordered]@{}
        for ($i = 0; $i -lt $Months.Count; $i++) {
            $days = [DateTime]::DaysInMonth([int]$Months[$i].Substring(0, 4), [int]$Months[$i].Substring(5, 2))
            $values[$Months[$i]] = $Rates[$i] * [decimal]$days / 30d
        }
        return $values
    }

    function Invoke-TestModel {
        param($Dataset, $Settings, $Reviews = @{})
        InModuleScope FinOpsForecast -Parameters @{ Dataset = $Dataset; Settings = $Settings; Reviews = $Reviews; AsOf = $script:AsOf } {
            Invoke-ForecastModel -Dataset $Dataset -Settings $Settings -Reviews $Reviews -AsOf $AsOf
        }
    }

    function New-ReviewRecord {
        param($Item, [string]$Decision, [string]$Value)
        @{ $Item.Key = [pscustomobject]@{ decision = $Decision; fingerprint = $Item.Fingerprint; note = 'synthetic review'; value = $Value } }
    }
}

Describe 'Forecast engine' {
    Context 'Comparisons' {
        It 'Accounts for 11 comparisons over 12 months, starting after the first month' {
            $rates = [decimal[]](1000, 1020, 1040, 1061, 1082, 1104, 1126, 1149, 1172, 1195, 1219, 1243)
            $model = Invoke-TestModel -Dataset (New-TestDataset -Values (New-RateSeries $rates)) -Settings (New-TestSettings)
            $model.Comparisons.Items.Count | Should -Be 11
            $model.Comparisons.Expected | Should -Be 11
            $model.Comparisons.Items[0].FromMonth | Should -Be '2025-11'
            $model.Comparisons.Items[0].ToMonth | Should -Be '2025-12'
            @($model.Comparisons.Items | Where-Object Status -EQ 'Defined').Count | Should -Be 11
        }

        It 'Orders months by date key, not by the order rows arrive in' {
            $rates = [decimal[]](1000, 1100, 1050, 1200, 1180, 1250, 1300, 1280, 1350, 1400, 1390, 1450)
            $ordered = New-TestDataset -Values (New-RateSeries $rates)
            $shuffled = New-TestDataset -Values (New-RateSeries $rates)
            $shuffled.Months = @($shuffled.Months | Sort-Object { $_.Month.GetHashCode() } -Descending)
            $first = Invoke-TestModel -Dataset $ordered -Settings (New-TestSettings)
            $second = Invoke-TestModel -Dataset $shuffled -Settings (New-TestSettings)
            ($second.Comparisons.Items | ForEach-Object { "$($_.ToMonth)=$($_.Change)" }) -join ';' | Should -Be (($first.Comparisons.Items | ForEach-Object { "$($_.ToMonth)=$($_.Change)" }) -join ';')
            $second.Projection.TotalCentral | Should -Be $first.Projection.TotalCentral
        }

        It 'Normalizes month length so equal daily spend shows zero growth' {
            $values = [ordered]@{}
            foreach ($month in $script:Window) { $values[$month] = 100d * [DateTime]::DaysInMonth([int]$month.Substring(0, 4), [int]$month.Substring(5, 2)) }
            $model = Invoke-TestModel -Dataset (New-TestDataset -Values $values) -Settings (New-TestSettings)
            @($model.Comparisons.Items | Where-Object { $_.Change -ne 0 }).Count | Should -Be 0
            $model.Growth.Central | Should -Be 0
            $model.Baseline.Value | Should -Be 3000
        }

        It 'Marks a change from a zero month as undefined and requires a review' {
            $rates = [decimal[]](1000, 1000, 0, 1000, 1010, 1020, 1030, 1040, 1050, 1060, 1070, 1080)
            $dataset = New-TestDataset -Values (New-RateSeries $rates)
            $model = Invoke-TestModel -Dataset $dataset -Settings (New-TestSettings)
            $undefined = @($model.Comparisons.Items | Where-Object Status -EQ 'Undefined')
            $undefined.Count | Should -Be 1
            $undefined[0].ToMonth | Should -Be '2026-02'
            $undefined[0].Review.Decision | Should -Be 'Pending'
            $undefined[0].Retained | Should -BeFalse

            $reviewed = Invoke-TestModel -Dataset $dataset -Settings (New-TestSettings) -Reviews (New-ReviewRecord $undefined[0].Review 'Exclude')
            @($reviewed.Comparisons.Items | Where-Object Status -EQ 'Undefined')[0].Review.Decision | Should -Be 'Exclude'
        }

        It 'Flags a sustained jump and suggests a step change that keeps genuine growth' {
            $rates = [decimal[]](1000, 1010, 1020, 1030, 1040, 1600, 1616, 1632, 1648, 1664, 1680, 1696)
            $dataset = New-TestDataset -Values (New-RateSeries $rates)
            $model = Invoke-TestModel -Dataset $dataset -Settings (New-TestSettings)
            $flagged = @($model.Comparisons.Items | Where-Object Flagged)
            $flagged.Count | Should -Be 1
            $flagged[0].ToMonth | Should -Be '2026-04'
            $flagged[0].Suggestion | Should -Be 'StepChange'
            $flagged[0].Retained | Should -BeFalse

            $reviewed = Invoke-TestModel -Dataset $dataset -Settings (New-TestSettings) -Reviews (New-ReviewRecord $flagged[0].Review 'StepChange')
            @($reviewed.Comparisons.Items | Where-Object Flagged)[0].Retained | Should -BeTrue
            $reviewed.Growth.Retained | Should -Be 11
        }

        It 'Suggests excluding a one-month spike and keeps the month in actuals' {
            $rates = [decimal[]](1000, 1010, 1020, 1030, 3000, 1040, 1050, 1060, 1070, 1080, 1090, 1100)
            $dataset = New-TestDataset -Values (New-RateSeries $rates)
            $model = Invoke-TestModel -Dataset $dataset -Settings (New-TestSettings)
            $spikeIn = @($model.Comparisons.Items | Where-Object ToMonth -EQ '2026-03')[0]
            $spikeIn.Flagged | Should -BeTrue
            $spikeIn.Suggestion | Should -Be 'Exclude'
            # The drop back holds the following month, but it undoes the spike,
            # so it isn't suggested as a step change.
            $spikeOut = @($model.Comparisons.Items | Where-Object ToMonth -EQ '2026-04')[0]
            $spikeOut.Flagged | Should -BeTrue
            $spikeOut.Suggestion | Should -Be 'Exclude'
            $spikeOut.Review.Detail | Should -Match 'reverses the flagged change from 2026-02 to 2026-03'
            ($model.Window.Rows | Where-Object Month -EQ '2026-03').Headline | Should -BeGreaterThan 2900
        }

        It 'Still suggests a step change when a drop after a spike settles at a new level' {
            $rates = [decimal[]](1000, 1010, 1020, 1030, 3000, 600, 606, 612, 618, 624, 630, 636)
            $model = Invoke-TestModel -Dataset (New-TestDataset -Values (New-RateSeries $rates)) -Settings (New-TestSettings)
            @($model.Comparisons.Items | Where-Object ToMonth -EQ '2026-04')[0].Suggestion | Should -Be 'StepChange'
        }

        It 'Reopens a review when the underlying data changes' {
            $rates = [decimal[]](1000, 1010, 1020, 1030, 3000, 1040, 1050, 1060, 1070, 1080, 1090, 1100)
            $model = Invoke-TestModel -Dataset (New-TestDataset -Values (New-RateSeries $rates)) -Settings (New-TestSettings)
            $item = @($model.Comparisons.Items | Where-Object ToMonth -EQ '2026-03')[0].Review
            $corrected = $rates.Clone(); $corrected[4] = 3100
            $after = Invoke-TestModel -Dataset (New-TestDataset -Values (New-RateSeries $corrected)) -Settings (New-TestSettings) -Reviews (New-ReviewRecord $item 'Exclude')
            $reopened = @($after.Comparisons.Items | Where-Object ToMonth -EQ '2026-03')[0].Review
            $reopened.Decision | Should -Be 'Pending'
            $reopened.Stale | Should -BeTrue
        }

        It 'Reports missing months as comparisons that couldn''t be computed' {
            $values = New-RateSeries ([decimal[]](1000, 1010, 1020, 1030, 1040, 1050, 1060, 1070, 1080, 1090, 1100, 1110))
            $values['2026-05'] = $null
            $model = Invoke-TestModel -Dataset (New-TestDataset -Values $values) -Settings (New-TestSettings)
            @($model.Comparisons.Items | Where-Object Status -EQ 'MissingData').Count | Should -Be 2
        }
    }

    Context 'Baseline' {
        BeforeAll {
            $script:SpikeRates = [decimal[]](1000, 1010, 1020, 1030, 1040, 1050, 1060, 1070, 1080, 1090, 1100, 2500)
        }

        It 'Requires a separate review when the latest month is anomalous' {
            $model = Invoke-TestModel -Dataset (New-TestDataset -Values (New-RateSeries $script:SpikeRates)) -Settings (New-TestSettings)
            $model.Baseline.Review | Should -Not -BeNullOrEmpty
            $model.Baseline.Pending | Should -BeTrue
            $model.Baseline.Review.Category | Should -Be 'Baseline'
        }

        It 'Applies the <Decision> baseline decision' -ForEach @(
            @{ Decision = 'LatestMonth'; Expected = 2500 }
            @{ Decision = 'MedianLast3'; Expected = 1100 }
            @{ Decision = 'Manual'; Expected = 1234.5 }
        ) {
            $dataset = New-TestDataset -Values (New-RateSeries $script:SpikeRates)
            $first = Invoke-TestModel -Dataset $dataset -Settings (New-TestSettings)
            $value = if ($Decision -eq 'Manual') { '1234.5' } else { $null }
            $model = Invoke-TestModel -Dataset $dataset -Settings (New-TestSettings) -Reviews (New-ReviewRecord $first.Baseline.Review $Decision $value)
            $model.Baseline.Pending | Should -BeFalse
            # The synthetic rate-to-cost conversion divides by 30, so compare at eight decimals.
            [decimal]::Round($model.Baseline.Value, 8) | Should -Be ([decimal]$Expected)
        }
    }

    Context 'Projection and fiscal-year aggregation' {
        It 'Combines actuals, month-to-date, and forecast into consistent low, central, and high paths' {
            $rates = [decimal[]](1000, 1020, 1040, 1061, 1082, 1104, 1126, 1149, 1172, 1195, 1219, 1243)
            $dataset = New-TestDataset -Values (New-RateSeries $rates)
            $dataset.Months += [pscustomobject]@{
                Month = '2026-11'; Status = 'Provisional'; Days = 30; RunRate = 160d; Purchase = 0d; Adjustment = 0d; Other = 0d; Headline = 160d; Credit = 0d
                ExcludedMarketplace = 0d; ExcludedTax = 0d; ExcludedUnattributed = 0d; ExcludedBoundary = 0d; ExcludedScope = 0d
                DataThrough = [datetime]'2026-11-04'; Provenance = @(); Approved = $true; Note = ''
            }
            $settings = New-TestSettings -StartMonth 7
            $model = Invoke-TestModel -Dataset $dataset -Settings $settings
            $projection = $model.Projection
            $projection.FiscalYear.Label | Should -Be 'FY2027'
            @($projection.Rows | Where-Object Kind -EQ 'Actual').Month -join ',' | Should -Be '2026-07,2026-08,2026-09,2026-10'
            $november = @($projection.Rows | Where-Object Month -EQ '2026-11')[0]
            $november.Kind | Should -Be 'PartialActual'
            $november.DaysWithData | Should -Be 4
            $november.Actual | Should -Be 160
            @($projection.Rows | Where-Object Kind -EQ 'Forecast').Count | Should -Be 7
            $projection.TotalLow | Should -BeLessOrEqual $projection.TotalCentral
            $projection.TotalCentral | Should -BeLessOrEqual $projection.TotalHigh
            $sum = 0d; foreach ($row in $projection.Rows) { $sum += $row.TotalCentral }
            $projection.TotalCentral | Should -Be $sum
        }

        It 'Computes exact totals for a flat history' {
            $rates = [decimal[]]@(1..12 | ForEach-Object { 3000 })
            $model = Invoke-TestModel -Dataset (New-TestDataset -Values (New-RateSeries $rates)) -Settings (New-TestSettings -StartMonth 1)
            $model.Growth.Central | Should -Be 0
            # Jan-Oct 2026 actuals (100 a day) plus Nov and Dec forecast (100 a day).
            $model.Projection.TotalCentral | Should -Be (100d * 365)
            $model.Projection.TotalLow | Should -Be $model.Projection.TotalHigh
        }

        It 'Applies scheduled items by baseline treatment and recurrence' {
            $rates = [decimal[]]@(1..12 | ForEach-Object { 3000 })
            $settings = New-TestSettings -StartMonth 1
            $settings.scheduledItems = @(
                [pscustomobject]@{ id = 'ri-renewal'; type = 'Renewal'; description = 'synthetic renewal'; startMonth = '2026-12'; endMonth = ''; recurrence = 'OneTime'; amount = '5000'; baselineTreatment = 'Additive'; replacedAmount = '' }
                [pscustomobject]@{ id = 'in-baseline'; type = 'Purchase'; description = 'already billed monthly'; startMonth = '2026-11'; endMonth = ''; recurrence = 'Monthly'; amount = '700'; baselineTreatment = 'AlreadyInBaseline'; replacedAmount = '' }
                [pscustomobject]@{ id = 'swap'; type = 'BusinessChange'; description = 'replace workload'; startMonth = '2026-11'; endMonth = '2026-12'; recurrence = 'Monthly'; amount = '400'; baselineTreatment = 'ReplacesBaselineAmount'; replacedAmount = '150' }
            )
            $model = Invoke-TestModel -Dataset (New-TestDataset -Values (New-RateSeries $rates)) -Settings $settings
            $model.Schedule.Issues.Count | Should -Be 0
            $model.Projection.Scheduled | Should -Be (5000 + 0 + 250 + 250)
            $model.Projection.TotalCentral | Should -Be ((100d * 365) + 5500)
        }

        It 'Doesn''t add a scheduled purchase that already posted in the month-to-date actuals' {
            $rates = [decimal[]]@(1..12 | ForEach-Object { 3000 })
            $dataset = New-TestDataset -Values (New-RateSeries $rates)
            $dataset.Months += [pscustomobject]@{
                Month = '2026-11'; Status = 'Provisional'; Days = 30; RunRate = 400d; Purchase = 500d; Adjustment = 0d; Other = 0d; Headline = 900d; Credit = 0d
                ExcludedMarketplace = 0d; ExcludedTax = 0d; ExcludedUnattributed = 0d; ExcludedBoundary = 0d; ExcludedScope = 0d
                DataThrough = [datetime]'2026-11-04'; Provenance = @(); Approved = $true; Note = ''
            }
            $dataset.Cells = @([pscustomobject]@{ Month = '2026-11'; Stream = 'Purchase'; ChargeType = 'Purchase'; CommitmentId = '/providers/microsoft.capacity/reservationorders/ri-1'; Cost = 500d })
            $settings = New-TestSettings -StartMonth 1
            $settings.scheduledItems = @(
                [pscustomobject]@{ id = 'ri-monthly'; type = 'Purchase'; description = 'synthetic monthly RI'; startMonth = '2026-11'; endMonth = ''; recurrence = 'Monthly'; amount = '500'; baselineTreatment = 'Additive'; replacedAmount = ''; commitmentId = 'RI-1' }
                [pscustomobject]@{ id = 'unlinked'; type = 'Purchase'; description = 'no commitment'; startMonth = '2026-11'; endMonth = ''; recurrence = 'OneTime'; amount = '50'; baselineTreatment = 'Additive'; replacedAmount = '' }
            )
            $model = Invoke-TestModel -Dataset $dataset -Settings $settings
            $november = @($model.Projection.Rows | Where-Object Month -EQ '2026-11')[0]
            $december = @($model.Projection.Rows | Where-Object Month -EQ '2026-12')[0]
            $november.Kind | Should -Be 'PartialActual'
            $november.Scheduled | Should -Be 50
            $november.ScheduledAlreadyPosted | Should -Be 500
            $november.Note | Should -Match 'ri-monthly already posted'
            $november.Note | Should -Match 'unlinked have no commitment ID'
            $december.Scheduled | Should -Be 500
            # 100 a day: 900 posted, 26 remaining days forecast, plus the unlinked item.
            [decimal]::Round($november.TotalCentral, 6) | Should -Be 3550
        }

        It 'Keeps a scheduled purchase when only a refund for that commitment has posted' {
            $dataset = New-TestDataset -Values (New-RateSeries ([decimal[]]@(1..12 | ForEach-Object { 3000 })))
            $month = (New-TestDataset -Values ([ordered]@{ '2026-11' = 400 })).Months[0]
            $month.Status = 'Provisional'; $month.DataThrough = [datetime]'2026-11-04'
            $month.Purchase = -20d; $month.Headline = 380d
            $dataset.Months += $month
            $dataset.Cells = @([pscustomobject]@{ Month = '2026-11'; Stream = 'Purchase'; ChargeType = 'Refund'; CommitmentId = 'ri-synthetic'; Cost = -20d })
            $settings = New-TestSettings
            $settings.scheduledItems = @([pscustomobject]@{
                    id = 'scheduled-ri'; type = 'Purchase'; description = 'Synthetic monthly commitment'
                    startMonth = '2026-11'; endMonth = ''; recurrence = 'Monthly'; amount = '500'
                    baselineTreatment = 'Additive'; replacedAmount = ''; commitmentId = 'ri-synthetic'
                })
            $model = Invoke-TestModel -Dataset $dataset -Settings $settings
            $november = $model.Projection.Rows | Where-Object Month -EQ '2026-11'
            $november.Actual | Should -Be 380
            $november.Scheduled | Should -Be 500
            $november.ScheduledAlreadyPosted | Should -Be 0
            [decimal]::Round($november.TotalCentral, 6) | Should -Be 3480
            ($model.Projection.Rows | Where-Object Month -EQ '2026-12').Scheduled | Should -Be 500
        }

        It 'Rejects duplicate scheduled item IDs and flags near-duplicate schedules' {
            $settings = New-TestSettings
            $item = @{ type = 'Purchase'; description = 'Synthetic RI'; startMonth = '2026-12'; endMonth = ''; recurrence = 'OneTime'; amount = '100'; baselineTreatment = 'Additive'; replacedAmount = '' }
            $settings.scheduledItems = @(
                [pscustomobject](@{ id = 'dup' } + $item)
                [pscustomobject](@{ id = 'DUP' } + $item)
                [pscustomobject](@{ id = 'copy-a' } + $item)
                [pscustomobject](@{ id = 'copy-b' } + $item)
            )
            $model = Invoke-TestModel -Dataset (New-TestDataset -Values (New-RateSeries ([decimal[]]@(1..12 | ForEach-Object { 3000 })))) -Settings $settings
            @($model.Schedule.Issues | Where-Object Code -EQ 'SCH-DUPLICATE').Count | Should -Be 1
            @($model.Reviews | Where-Object Category -EQ 'Schedule').Count | Should -Be 1
        }
    }

    Context 'Backtest' {
        It 'Backtests every cutoff with a full window and a later month' {
            $months = Get-TestMonthKeys -Last '2026-10' -Count 18
            $rates = [decimal[]]@(for ($i = 0; $i -lt 18; $i++) { 1000 + (20 * $i) })
            $dataset = New-TestDataset -Values (New-RateSeries -Rates $rates -Months $months)
            $backtest = InModuleScope FinOpsForecast -Parameters @{ Dataset = $dataset; Settings = (New-TestSettings) } { Invoke-ForecastBacktest -Dataset $Dataset -Settings $Settings -LastMonth '2026-10' }
            $backtest.Status | Should -Be 'Completed'
            $backtest.Cutoffs.Count | Should -Be 6
            $backtest.Results[0].Cutoff | Should -Be '2026-04'
            $backtest.MeanAbsoluteErrorRatio | Should -BeLessThan 0.05
        }

        It 'Reports insufficient history with only twelve months' {
            $dataset = New-TestDataset -Values (New-RateSeries ([decimal[]]@(1..12 | ForEach-Object { 3000 })))
            $backtest = InModuleScope FinOpsForecast -Parameters @{ Dataset = $dataset; Settings = (New-TestSettings) } { Invoke-ForecastBacktest -Dataset $Dataset -Settings $Settings -LastMonth '2026-10' }
            $backtest.Status | Should -Be 'InsufficientHistory'
        }
    }
}
