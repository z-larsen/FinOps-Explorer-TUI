# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers create synthetic fixtures in TestDrive only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helpers are named for the collections they build.')]
param()
BeforeAll {
    . (Join-Path $PSScriptRoot 'Forecast.TestHelpers.ps1')
    $script:Months = Get-TestMonthKeys -Last '2026-10'

    function New-TestCell {
        param(
            [string]$Month, [string]$Subscription = 'A', [string]$Tag = '', [string]$ResourceGroup = 'rg-synth', [decimal]$Cost,
            [long]$Rows = 1, [long]$Covered = 0, [string]$Stream = 'RunRate', [string]$Agreement = 'EA', [string]$Scope = '/providers/microsoft.billing/billingaccounts/1234567'
        )
        $sub = if ($script:SyntheticSubscriptions.ContainsKey($Subscription)) { $script:SyntheticSubscriptions[$Subscription] } else { $Subscription }
        [pscustomobject]@{
            Month = $Month; SourceId = 'src'; RunId = 'run'; OriginalScope = $Scope; Dataset = 'ActualCost'; Agreement = $Agreement
            SubscriptionId = $sub; ResourceGroup = $ResourceGroup; Tag = $Tag; ChargeType = if ($Stream -eq 'Purchase') { 'Purchase' } else { 'Usage' }
            Stream = $Stream; PublisherClass = 'Microsoft'; PricingModel = if ($Covered) { 'Reservation' } else { 'OnDemand' }
            CommitmentId = ''; Frequency = ''; BillingProfileId = ''; Currency = 'USD'; Cost = $Cost; Rows = $Rows; CoveredRows = $Covered; OnDemandEquivalent = 0d
        }
    }

    function New-RateCells {
        # One cell a month whose cost normalizes to the given 30-day run rate.
        param([decimal[]]$Rates, [string]$Tag, [string]$Subscription = 'A', [string]$ResourceGroup = 'rg-synth')
        for ($i = 0; $i -lt $script:Months.Count; $i++) {
            if ($Rates[$i] -eq 0) { continue }
            $days = [DateTime]::DaysInMonth([int]$script:Months[$i].Substring(0, 4), [int]$script:Months[$i].Substring(5, 2))
            New-TestCell -Month $script:Months[$i] -Tag $Tag -Subscription $Subscription -ResourceGroup $ResourceGroup -Cost ($Rates[$i] * [decimal]$days / 30d)
        }
    }

    function Invoke-TestWorkloads {
        param([object[]]$Cells, [string]$Mode = 'Tag', [object[]]$Rules = @(), [string[]]$Months = $script:Months, [hashtable]$Names = @{ $script:SyntheticSubscriptions.A = 'sub-synth-a'; $script:SyntheticSubscriptions.B = 'sub-synth-b' })
        $settings = New-TestSettings
        $settings.workloads.mode = $Mode
        InModuleScope FinOpsForecast -Parameters @{ Cells = $Cells; Settings = $settings; Rules = $Rules; Months = $Months; Names = $Names } {
            Get-ForecastWorkloadAnalysis -Cells $Cells -Months $Months -Settings $Settings -Rules $Rules -SubscriptionNames $Names
        }
    }

    function Get-Workload { param($Analysis, [string]$Id) @($Analysis.Workloads | Where-Object WorkloadId -EQ $Id)[0] }
    function Round8 { param($Value) if ($null -eq $Value) { return $null } [decimal]::Round([decimal]$Value, 8) }
}

Describe 'Workload analysis' {
    Context 'Identity' {
        It 'Groups by <Mode> and maps unidentified spend to Unmapped' -ForEach @(
            @{ Mode = 'Tag'; ExpectedId = 'tag:app-alpha' }
            @{ Mode = 'ResourceGroup'; ExpectedId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-synth' }
            @{ Mode = 'Subscription'; ExpectedId = '11111111-1111-1111-1111-111111111111' }
        ) {
            $cells = @(New-RateCells -Rates ([decimal[]]@(1..12 | ForEach-Object { 1000 })) -Tag 'app-alpha')
            $cells += New-TestCell -Month '2026-10' -Tag '' -ResourceGroup '' -Cost 5
            $analysis = Invoke-TestWorkloads -Cells $cells -Mode $Mode
            Get-Workload $analysis $ExpectedId | Should -Not -BeNullOrEmpty
            if ($Mode -ne 'Subscription') {
                $unmapped = Get-Workload $analysis "unmapped:$($script:SyntheticSubscriptions.A)"
                $unmapped.Flags | Should -Match 'Unmapped'
                $unmapped.WorkloadName | Should -Be 'Unmapped (sub-synth-a)'
            }
        }

        It 'Adds a short ID when different workloads share a display name' {
            $flat = [decimal[]]@(1..12 | ForEach-Object { 1000 })
            $cells = @(New-RateCells -Rates $flat -Subscription 'A') + @(New-RateCells -Rates $flat -Subscription 'B') + @(New-RateCells -Rates $flat -Subscription 'C')
            $names = @{ $script:SyntheticSubscriptions.A = 'Pay-As-You-Go'; $script:SyntheticSubscriptions.B = 'pay-as-you-go'; $script:SyntheticSubscriptions.C = 'sub-synth-c' }
            $analysis = Invoke-TestWorkloads -Cells $cells -Mode 'Subscription' -Names $names
            (Get-Workload $analysis $script:SyntheticSubscriptions.A).WorkloadName | Should -Be 'Pay-As-You-Go [11111111]'
            (Get-Workload $analysis $script:SyntheticSubscriptions.B).WorkloadName | Should -Be 'pay-as-you-go [22222222]'
            (Get-Workload $analysis $script:SyntheticSubscriptions.C).WorkloadName | Should -Be 'sub-synth-c'
        }

        It 'Applies a mapping file with stable IDs, merges, and display names' {
            $path = Join-Path $TestDrive 'mapping.csv'
            @(
                'MatchType,MatchValue,WorkloadId,WorkloadName'
                'Tag,app-alpha,WL-001,Synthetic Alpha'
                'Tag,App-Alpha-Legacy,WL-001,Synthetic Alpha'
                "ResourceGroup,$($script:SyntheticSubscriptions.B)/rg-shared,WL-002,Shared platform"
            ) | Set-Content -LiteralPath $path
            $mapping = InModuleScope FinOpsForecast -Parameters @{ Path = $path } { Import-ForecastWorkloadMapping -Path $Path }
            $mapping.Issues.Count | Should -Be 0
            $cells = @(New-RateCells -Rates ([decimal[]]@(1..12 | ForEach-Object { 500 })) -Tag 'app-alpha')
            $cells += @(New-RateCells -Rates ([decimal[]]@(1..12 | ForEach-Object { 200 })) -Tag 'app-alpha-legacy')
            $cells += @(New-RateCells -Rates ([decimal[]]@(1..12 | ForEach-Object { 50 })) -Subscription 'B' -ResourceGroup 'RG-Shared')
            $analysis = Invoke-TestWorkloads -Cells $cells -Rules $mapping.Rules
            $analysis.Workloads.Count | Should -Be 2
            (Round8 (Get-Workload $analysis 'WL-001').LastRunRate) | Should -Be 700
            (Get-Workload $analysis 'WL-002').WorkloadName | Should -Be 'Shared platform'
        }

        It 'Rejects mapping files with <Case>' -ForEach @(
            @{ Case = 'duplicate matches'; Lines = @('MatchType,MatchValue,WorkloadId,WorkloadName', 'Tag,a,W1,One', 'Tag,A,W2,Two'); Code = 'MAP-DUPLICATE' }
            @{ Case = 'conflicting names'; Lines = @('MatchType,MatchValue,WorkloadId,WorkloadName', 'Tag,a,W1,One', 'Tag,b,W1,Uno'); Code = 'MAP-NAME' }
            @{ Case = 'missing columns'; Lines = @('MatchType,WorkloadId', 'Tag,W1'); Code = 'MAP-COLUMNS' }
        ) {
            $path = Join-Path $TestDrive "mapping-$([guid]::NewGuid().ToString('N')).csv"
            $Lines | Set-Content -LiteralPath $path
            $mapping = InModuleScope FinOpsForecast -Parameters @{ Path = $path } { Import-ForecastWorkloadMapping -Path $Path }
            @($mapping.Issues | Where-Object Code -EQ $Code).Count | Should -Be 1
        }
    }

    Context 'Metrics' {
        BeforeAll {
            # Alpha: biggest change. Beta: highest spend. Gamma: highest growth. Delta: new.
            $script:Cells = @(
                New-RateCells -Tag 'alpha' -Rates ([decimal[]](1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1600, 1600, 1700, 1800))
                New-RateCells -Tag 'beta' -Rates ([decimal[]](5000, 5000, 5000, 5000, 5000, 5000, 5000, 5000, 5000, 5000, 5000, 5100))
                New-RateCells -Tag 'gamma' -Rates ([decimal[]](100, 100, 100, 100, 100, 100, 100, 100, 100, 150, 250, 400))
                New-RateCells -Tag 'delta' -Rates ([decimal[]](0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 50, 60))
            )
            $script:Analysis = Invoke-TestWorkloads -Cells $script:Cells
        }

        It 'Defines change, growth, and contribution share from 30-day run rates' {
            $alpha = Get-Workload $script:Analysis 'tag:alpha'
            (Round8 $alpha.Change) | Should -Be 800
            (Round8 $alpha.Growth) | Should -Be 0.8
            (Round8 $script:Analysis.NetChange) | Should -Be (800 + 100 + 300 + 60)
            (Round8 $alpha.ContributionShare) | Should -Be (Round8 (800d / 1260d))
            $sum = 0d; foreach ($w in $script:Analysis.Workloads) { $sum += $w.ContributionShare }
            (Round8 $sum) | Should -Be 1
        }

        It 'Reports the month and amount of the largest month-over-month increase' {
            $alpha = Get-Workload $script:Analysis 'tag:alpha'
            $alpha.LargestIncreaseMonth | Should -Be '2026-07'
            (Round8 $alpha.LargestIncreaseAmount) | Should -Be 600
        }

        It 'Keeps the largest change distinct from the highest spend and highest growth' {
            $byChange = InModuleScope FinOpsForecast -Parameters @{ A = $script:Analysis } { Get-ForecastWorkloadView -Analysis $A -View Change }
            $bySpend = InModuleScope FinOpsForecast -Parameters @{ A = $script:Analysis } { Get-ForecastWorkloadView -Analysis $A -View Spend }
            $byGrowth = InModuleScope FinOpsForecast -Parameters @{ A = $script:Analysis } { Get-ForecastWorkloadView -Analysis $A -View Growth }
            $byChange[0].WorkloadId | Should -Be 'tag:alpha'
            $bySpend[0].WorkloadId | Should -Be 'tag:beta'
            $byGrowth[0].WorkloadId | Should -Be 'tag:gamma'
            $byGrowth[-1].WorkloadId | Should -Be 'tag:delta'
        }

        It 'Treats a workload that starts at zero as new with undefined growth' {
            $delta = Get-Workload $script:Analysis 'tag:delta'
            $delta.Flags | Should -Match 'New'
            $delta.Growth | Should -BeNullOrEmpty
            (Round8 $delta.FirstRunRate) | Should -Be 0
        }

        It 'Flags retired and moved workloads' {
            $cells = @(
                New-RateCells -Tag 'retiring' -Rates ([decimal[]](100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 0, 0))
                New-RateCells -Tag 'mover' -Subscription 'A' -Rates ([decimal[]](100, 100, 100, 100, 100, 100, 0, 0, 0, 0, 0, 0))
                New-RateCells -Tag 'mover' -Subscription 'B' -Rates ([decimal[]](0, 0, 0, 0, 0, 0, 100, 100, 100, 100, 100, 100))
            )
            $analysis = Invoke-TestWorkloads -Cells $cells
            (Get-Workload $analysis 'tag:retiring').Flags | Should -Match 'Retired'
            (Get-Workload $analysis 'tag:mover').Flags | Should -Match 'Moved'
        }

        It 'Flags a subscription that moved billing scope as moved' {
            $cells = @(
                @(0..5 | ForEach-Object { New-TestCell -Month $script:Months[$_] -Cost 100 -Agreement 'EA' })
                @(6..11 | ForEach-Object { New-TestCell -Month $script:Months[$_] -Cost 100 -Agreement 'MCA' -Scope '/providers/microsoft.billing/billingaccounts/x:y_2019-05-31/billingprofiles/bp-synth-01' })
            )
            $analysis = Invoke-TestWorkloads -Cells $cells -Mode 'Subscription'
            $analysis.Workloads[0].Flags | Should -Match 'Moved'
            $analysis.Workloads[0].Notes | Should -Match 'billing scope'
        }

        It 'Explains reservation coverage changes without allocating purchases' {
            $cells = @(
                New-TestCell -Month $script:Months[0] -Tag 'vm-app' -Cost 1000 -Rows 10 -Covered 0
                New-TestCell -Month $script:Months[11] -Tag 'vm-app' -Cost 200 -Rows 10 -Covered 8
                New-TestCell -Month $script:Months[11] -Tag 'vm-app' -Cost 900 -Stream 'Purchase'
            )
            $analysis = Invoke-TestWorkloads -Cells $cells
            $workload = Get-Workload $analysis 'tag:vm-app'
            $workload.Notes | Should -Match 'coverage moved from 0% to 80%'
            (Round8 $workload.LatestMonthSpend) | Should -Be 200
            $workload.PurchasesLast | Should -Be 900 -Because 'a purchase shows where it''s billed, apart from usage'
            $analysis.Purchases.Count | Should -Be 1
        }
    }

    Context 'Purchases and month-to-date pace' {
        It 'Shows purchases beside the subscription that pays for them, with a net change' {
            $cells = @(New-RateCells -Rates ([decimal[]]@(1..12 | ForEach-Object { 1000 })) -Tag '')
            $cells += New-TestCell -Month $script:Months[0] -ResourceGroup '' -Cost 300 -Stream 'Purchase'
            $cells += New-TestCell -Month $script:Months[11] -ResourceGroup '' -Cost 100 -Stream 'Purchase'
            $cells += New-TestCell -Month $script:Months[11] -Subscription 'B' -ResourceGroup '' -Cost 50 -Stream 'Purchase'
            $analysis = Invoke-TestWorkloads -Cells $cells
            $payer = Get-Workload $analysis "unmapped:$($script:SyntheticSubscriptions.A)"
            $payer.Change | Should -Be 0
            $payer.PurchasesFirst | Should -Be 300
            $payer.PurchasesLast | Should -Be 100
            $payer.NetChange | Should -Be -200
            $payer.Notes | Should -Match 'this subscription pays for'
            $buyer = Get-Workload $analysis "unmapped:$($script:SyntheticSubscriptions.B)"
            $buyer.Flags | Should -Match 'Purchases only'
            $buyer.NetChange | Should -Be 50
            $analysis.NetChange | Should -Be 0 -Because 'purchases never change the run-rate net change or shares'
            $analysis.Purchases.Count | Should -Be 3
        }

        It 'Paces the month in progress from its days with data, and lists a workload new this month' {
            $cells = @(New-RateCells -Rates ([decimal[]]@(1..12 | ForEach-Object { 1000 })) -Tag 'app-alpha')
            $cells += New-TestCell -Month '2026-11' -Tag 'app-alpha' -Cost 400
            $cells += New-TestCell -Month '2026-11' -Tag 'app-new' -Cost 100
            $settings = New-TestSettings
            $analysis = InModuleScope FinOpsForecast -Parameters @{ Cells = $cells; Settings = $settings; Months = $script:Months } {
                Get-ForecastWorkloadAnalysis -Cells $Cells -Months $Months -Settings $Settings -Rules @() -SubscriptionNames @{} -PaceMonth '2026-11' -PaceDays 10
            }
            $analysis.PaceMonth | Should -Be '2026-11'
            (Get-Workload $analysis 'tag:app-alpha').MonthToDatePace | Should -Be 1200
            (Get-Workload $analysis 'tag:app-alpha').Change | Should -Be 0 -Because 'the month in progress never feeds the change'
            $new = Get-Workload $analysis 'tag:app-new'
            $new.Flags | Should -Match 'New this month'
            $new.MonthToDatePace | Should -Be 300
            $plain = Invoke-TestWorkloads -Cells $cells
            (Get-Workload $plain 'tag:app-alpha').MonthToDatePace | Should -BeNullOrEmpty
            Get-Workload $plain 'tag:app-new' | Should -BeNullOrEmpty
        }

        It 'Finds the month in progress after the window and how many of its days have data' {
            $pace = InModuleScope FinOpsForecast {
                $dataset = [pscustomobject]@{ Months = @(
                        [pscustomobject]@{ Month = '2026-10'; Status = 'Complete'; Headline = 10d; DataThrough = [datetime]'2026-10-31' }
                        [pscustomobject]@{ Month = '2026-11'; Status = 'Provisional'; Headline = 5d; DataThrough = [datetime]'2026-11-11' }
                    )
                }
                $window = [pscustomobject]@{ Last = '2026-10' }
                $found = Get-ForecastMonthToDate -Dataset $dataset -Window $window
                # Runs with different cutoffs make the month Incomplete; its earliest cutoff would overstate the pace.
                $dataset.Months[1].Status = 'Incomplete'
                [pscustomobject]@{ Found = $found; Mismatched = Get-ForecastMonthToDate -Dataset $dataset -Window $window }
            }
            $pace.Found.Month | Should -Be '2026-11'
            $pace.Found.Days | Should -Be 11
            $pace.Mismatched | Should -BeNullOrEmpty
        }
    }

    Context 'Ordering and scale' {
        It 'Breaks ties by workload ID in every view' {
            $cells = @(
                New-RateCells -Tag 'zeta' -Rates ([decimal[]](100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 200))
                New-RateCells -Tag 'eta' -Rates ([decimal[]](100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 200))
            )
            $analysis = Invoke-TestWorkloads -Cells $cells
            foreach ($view in 'Change', 'Spend', 'Growth', 'LargestIncrease') {
                $ordered = InModuleScope FinOpsForecast -Parameters @{ A = $analysis; V = $view } { Get-ForecastWorkloadView -Analysis $A -View $V }
                ($ordered.WorkloadId -join ',') | Should -Be 'tag:eta,tag:zeta'
            }
        }

        It 'Uses the earliest month when two increases tie' {
            $cells = @(New-RateCells -Tag 'steps' -Rates ([decimal[]](100, 100, 200, 200, 200, 300, 300, 300, 300, 300, 300, 300)))
            $analysis = Invoke-TestWorkloads -Cells $cells
            (Get-Workload $analysis 'tag:steps').LargestIncreaseMonth | Should -Be $script:Months[2]
        }

        It 'Returns every workload in an expanded dataset with no ranking limit' {
            $months = Get-TestMonthKeys -Last '2026-10' -Count 24
            $cells = [Collections.Generic.List[object]]::new()
            for ($w = 0; $w -lt 600; $w++) {
                foreach ($month in $months) { $cells.Add((New-TestCell -Month $month -Tag ('wl-{0:D4}' -f $w) -Cost (100 + $w))) }
            }
            $analysis = Invoke-TestWorkloads -Cells $cells.ToArray() -Months $months
            $analysis.Workloads.Count | Should -Be 600
            $view = InModuleScope FinOpsForecast -Parameters @{ A = $analysis } { Get-ForecastWorkloadView -Analysis $A -View Spend }
            $view.Count | Should -Be 600
            $view[0].WorkloadId | Should -Be 'tag:wl-0599'
        }
    }
}
