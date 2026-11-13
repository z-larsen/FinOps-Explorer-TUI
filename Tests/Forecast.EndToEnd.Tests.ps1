# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers create synthetic fixtures in TestDrive only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helpers are named for the collections they build.')]
param()
BeforeAll {
    . (Join-Path $PSScriptRoot 'Forecast.TestHelpers.ps1')
    $script:AsOf = [datetime]::SpecifyKind([datetime]'2026-11-07T12:00:00', [DateTimeKind]::Utc)
    $script:Exports = Join-Path $TestDrive 'exports'
    $script:Workspaces = Join-Path $TestDrive 'workspaces'
    $script:Reports = Join-Path $TestDrive 'reports'
    $script:Months = Get-TestMonthKeys -Last '2026-10' -Count 13

    function Get-MonthTotal { param([string]$Month, [decimal]$Rate) $Rate * [decimal][DateTime]::DaysInMonth([int]$Month.Substring(0, 4), [int]$Month.Substring(5, 2)) / 30d }

    for ($i = 0; $i -lt $script:Months.Count; $i++) {
        $month = $script:Months[$i]
        $alphaRate = [decimal]::Round(1000d * [decimal][math]::Pow(1.02, $i), 2)
        $rows = @(
            New-SyntheticMonthRows -Month $month -Total (Get-MonthTotal $month $alphaRate) -Subscription 'A' -Workload 'app-alpha'
            New-SyntheticMonthRows -Month $month -Total (Get-MonthTotal $month 500) -Subscription 'B' -Workload 'app-beta'
            New-SyntheticMonthRows -Month $month -Total (Get-MonthTotal $month 3) -Subscription 'B' -Workload '=SUM(1+1)' -Days 1
            New-SyntheticMonthRows -Month $month -Total (Get-MonthTotal $month 2) -Subscription 'B' -Workload '<script>alert(1)</script>' -Days 1
        )
        $null = New-SyntheticExportRun -Root $script:Exports -Kind 'EA' -Month $month -Parts @(, $rows) -Gzip
    }
    $settings = New-TestSettings -Root $script:Exports -Subscriptions @('A', 'B') -StartMonth 7
    $script:Config = Join-Path $TestDrive 'forecast-config.json'
    $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:Config

    function Invoke-TestRun {
        param([hashtable]$Extra = @{})
        $parameters = @{ NonInteractive = $true; WorkspaceName = 'synthetic'; WorkspacePath = $script:Workspaces; OutputPath = $script:Reports; AsOf = $script:AsOf } + $Extra
        Invoke-FinOpsForecast @parameters
    }

    function Read-ReportCsv { param([string]$Directory, [string]$Name) Import-Csv -LiteralPath (Join-Path $Directory $Name) }
}

Describe 'Forecast end to end' {
    It 'Produces a Ready forecast, a vintage, and the full report set' {
        $script:Result = Invoke-TestRun -Extra @{ ConfigPath = $script:Config; ErrorAction = 'Stop' }
        $script:Result.Ready | Should -BeTrue
        $script:Result.Vintage | Should -Not -BeNullOrEmpty
        $script:Result.FiscalYear | Should -Be 'FY2027'
        $script:Result.Currency | Should -Be 'USD'
        $script:Result.TotalLow | Should -BeLessOrEqual $script:Result.TotalCentral
        $script:Result.TotalCentral | Should -BeLessOrEqual $script:Result.TotalHigh
        $expected = 'backtest.csv', 'forecast-checks.csv', 'forecast-comparisons.csv', 'forecast-fiscal-year.csv', 'forecast-history.csv', 'forecast-monthly.csv',
        'forecast-provenance.csv', 'forecast-reconciliation.csv', 'forecast-report.html', 'forecast-reviews.csv', 'forecast-scheduled-items.csv', 'forecast-summary.txt',
        'purchases.csv', 'workload-monthly.csv', 'workloads.csv'
        foreach ($name in $expected) { Join-Path $script:Result.ReportDirectory $name | Should -Exist }
    }

    It 'Discloses the method and labels the range as sensitivity' {
        $summary = Get-Content -LiteralPath (Join-Path $script:Result.ReportDirectory 'forecast-summary.txt') -Raw
        $summary | Should -Match 'Status: Ready'
        $summary | Should -Match 'Sensitivity range'
        $summary | Should -Match 'not a calibrated confidence interval'
        $summary | Should -Match '11 adjacent-month comparisons'
        $summary | Should -Match 'Low and high totals each follow one growth path'
        @(Read-ReportCsv $script:Result.ReportDirectory 'forecast-comparisons.csv').Count | Should -Be 11
        @(Read-ReportCsv $script:Result.ReportDirectory 'forecast-monthly.csv').Count | Should -Be 12
        @(Read-ReportCsv $script:Result.ReportDirectory 'forecast-reconciliation.csv' | Where-Object { [decimal]$_.Difference -ne 0 }).Count | Should -Be 0
    }

    It 'Escapes untrusted text in CSV and HTML' {
        $workloads = @(Read-ReportCsv $script:Result.ReportDirectory 'workloads.csv')
        $workloads.Count | Should -Be 4
        @($workloads | Where-Object { $_.WorkloadName -like '*SUM(1+1)*' })[0].WorkloadName | Should -Be "'=SUM(1+1)"
        $html = Get-Content -LiteralPath (Join-Path $script:Result.ReportDirectory 'forecast-report.html') -Raw
        $html | Should -Not -Match '<script>alert'
        $html | Should -Match '&lt;script&gt;alert'
        $html | Should -Match "Content-Security-Policy"
        $html | Should -Match 'not a confidence interval'
        # Nothing on the page loads from the network.
        $html | Should -Not -Match '<(link|img|iframe|object|embed)\b|\ssrc=|url\(\s*[''"]?https?:'
    }

    It 'Opens the HTML report on an overview, with a tab for each section' {
        $html = Get-Content -LiteralPath (Join-Path $script:Result.ReportDirectory 'forecast-report.html') -Raw
        $tabs = [regex]::Matches($html, '<button type="button" class="tab(?<active> active)?" role="tab" id="tabbtn-(?<id>[a-z-]+)"[^>]*>(?<label>[^<]+)</button>')
        @($tabs | ForEach-Object { $_.Groups['label'].Value }) | Should -Be @('Overview', 'Fiscal year by month', 'Monthly history', 'Adjacent-month comparisons', 'Workloads', 'Checks', 'Exceptions and reviews', 'Backtest', 'Reconciliation', 'Method and disclosure')
        @($tabs | Where-Object { $_.Groups['active'].Success } | ForEach-Object { $_.Groups['id'].Value }) | Should -Be @('overview')
        foreach ($tab in $tabs) { $html | Should -Match "<section id=""tab-$($tab.Groups['id'].Value)"" class=""tabpane$(if ($tab.Groups['active'].Success) { ' active' })"" role=""tabpanel""" }
        # One column per fiscal-year month in the overview chart, and a totals row in the month table.
        $chart = [regex]::Match($html, '(?s)<svg id="chart-fiscal-year".*?</svg>').Value
        ([regex]::Matches($chart, '<g class="col">')).Count | Should -Be 12
        $central = [regex]::Escape((InModuleScope FinOpsForecast -Parameters @{ Value = $script:Result.TotalCentral } { Format-ForecastAmount $Value }))
        $html | Should -Match "(?s)<table class=""report-table"" id=""table-fiscal-year"".*<tfoot><tr><td>Total</td>.*$central"
        $html | Should -Match '<h3>Growth and sensitivity</h3><ul><li>'
    }

    It 'Splits the fiscal year into quarters that add up to its totals' {
        $quarters = InModuleScope FinOpsForecast -Parameters @{ Base = $script:Workspaces; AsOf = $script:AsOf } {
            $session = Invoke-ForecastEvaluation -Root (Get-ForecastWorkspaceRoot -WorkspaceName 'synthetic' -WorkspacePath $Base) -AsOf $AsOf
            [pscustomobject]@{ Projection = $session.Model.Projection; Rows = Get-ForecastQuarterRows -Projection $session.Model.Projection }
        }
        @($quarters.Rows).Count | Should -Be 4
        $quarters.Rows[0].Months | Should -Be 'July to September 2026'
        $sums = @{ Actual = 0d; Forecast = 0d; Scheduled = 0d; TotalLow = 0d; TotalCentral = 0d; TotalHigh = 0d }
        foreach ($quarter in $quarters.Rows) { foreach ($name in @($sums.Keys)) { $sums[$name] += [decimal]$quarter.$name } }
        # Summing by quarter rounds differently from summing by month, in the 28th digit.
        foreach ($name in 'TotalLow', 'TotalCentral', 'TotalHigh') { [decimal]::Round($sums[$name], 10) | Should -Be ([decimal]::Round([decimal]$quarters.Projection.$name, 10)) -Because $name }
        [decimal]::Round($sums.Actual + $sums.Forecast + $sums.Scheduled, 10) | Should -Be ([decimal]::Round([decimal]$quarters.Projection.TotalCentral, 10))
    }

    It 'Saves the vintage with exact amounts' {
        $vintages = InModuleScope FinOpsForecast -Parameters @{ Base = $script:Workspaces } { Get-ForecastVintages -Root (Get-ForecastWorkspaceRoot -WorkspaceName 'synthetic' -WorkspacePath $Base) }
        @($vintages).Count | Should -Be 1
        [decimal]::Parse($vintages[0].TotalCentral, [cultureinfo]::InvariantCulture) | Should -Be $script:Result.TotalCentral
        $vintages[0].Vintage.provenance.Count | Should -Be 13
    }

    It 'Uses the cache with SkipRefresh' {
        $result = Invoke-TestRun -Extra @{ SkipRefresh = $true; ErrorAction = 'Stop' }
        $result.Refresh | Should -BeNullOrEmpty
        $result.TotalCentral | Should -Be $script:Result.TotalCentral
    }

    It 'Blocks Ready, skips the vintage, and labels reports when an anomaly needs review' {
        $before = @(InModuleScope FinOpsForecast -Parameters @{ Base = $script:Workspaces } { Get-ForecastVintages -Root (Get-ForecastWorkspaceRoot -WorkspaceName 'synthetic' -WorkspacePath $Base) }).Count
        $month = '2026-05'
        $spike = @(New-SyntheticMonthRows -Month $month -Total (Get-MonthTotal $month 9000) -Subscription 'A' -Workload 'app-alpha')
        $null = New-SyntheticExportRun -Root $script:Exports -Kind 'EA' -Month $month -Submitted ([datetime]'2026-06-20') -Parts @(, $spike)
        $result = Invoke-FinOpsForecast -NonInteractive -WorkspaceName 'synthetic' -WorkspacePath $script:Workspaces -OutputPath $script:Reports -AsOf $script:AsOf -ErrorAction SilentlyContinue -ErrorVariable forecastErrors
        $result.Ready | Should -BeFalse
        $result.Vintage | Should -BeNullOrEmpty
        @($forecastErrors | Where-Object { $_.FullyQualifiedErrorId -like 'FinOpsForecastNotReady*' }).Count | Should -BeGreaterThan 0
        (Get-Content -LiteralPath (Join-Path $result.ReportDirectory 'forecast-summary.txt') -Raw) | Should -Match 'Status: NotReady'
        # The overview says it isn't ready and links each pending review to its tab.
        $html = Get-Content -LiteralPath (Join-Path $result.ReportDirectory 'forecast-report.html') -Raw
        $html | Should -Match '<div class="value">Not ready</div>'
        $html | Should -Match '<a class="report-jump" data-target="tab-reviews" href="#reviews-heading">\d+ required reviews?</a> to decide in FinOps Explorer: [^<]*Anomalous change'
        $html | Should -Match '<h2 id="reviews-heading" tabindex="-1">'
        $vintages = InModuleScope FinOpsForecast -Parameters @{ Base = $script:Workspaces } { Get-ForecastVintages -Root (Get-ForecastWorkspaceRoot -WorkspaceName 'synthetic' -WorkspacePath $Base) }
        @($vintages).Count | Should -Be $before
        $reviews = @(Read-ReportCsv $result.ReportDirectory 'forecast-reviews.csv' | Where-Object { $_.Category -eq 'Anomaly' -and $_.Decision -eq 'Pending' })
        $reviews.Count | Should -BeGreaterThan 0
    }
}
