# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers create synthetic fixtures in TestDrive only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helpers are named for the collections they build.')]
param()
BeforeAll {
    . (Join-Path $PSScriptRoot 'Forecast.TestHelpers.ps1')
    $script:AsOf = [datetime]::SpecifyKind([datetime]'2026-11-07T12:00:00', [DateTimeKind]::Utc)
    $script:Answers = [Collections.Generic.Queue[string]]::new()
    $script:Console = [Collections.Generic.List[object]]::new()

    function Set-TestAnswers { param([string[]]$Values) $script:Answers.Clear(); foreach ($value in $Values) { $script:Answers.Enqueue($value) } }
    function Get-RedLines { @($script:Console | Where-Object { $_.Text -match '^\s*Error:|couldn''t be evaluated' } | ForEach-Object Text) }
    function Get-Workspace { param([string]$Name) InModuleScope FinOpsForecast -Parameters @{ Base = (Join-Path $TestDrive 'ws'); Name = $Name } { Get-ForecastWorkspaceRoot -WorkspaceName $Name -WorkspacePath $Base } }
}

Describe 'Forecast console' {
    BeforeEach {
        $script:Console.Clear()
        Mock Read-FinOpsAnswer -ModuleName FinOpsForecast { if ($script:Answers.Count) { $script:Answers.Dequeue() } else { '' } }
        Mock Write-FinOpsConsole -ModuleName FinOpsForecast { $script:Console.Add([pscustomobject]@{ Text = [string]$Object; Color = [string]$ForegroundColor }) }
        Mock Clear-Host -ModuleName FinOpsForecast { }
    }

    It 'Walks every Setup & Review section for an exports workspace' {
        $exports = Join-Path $TestDrive 'console-exports'
        foreach ($month in (Get-TestMonthKeys -Last '2026-10' -Count 13)) {
            $total = 100d * [decimal][DateTime]::DaysInMonth([int]$month.Substring(0, 4), [int]$month.Substring(5, 2))
            $null = New-SyntheticExportRun -Root $exports -Kind 'MCA' -Month $month -Scope $script:ProfileScope -Parts @(, @(New-SyntheticMonthRows -Month $month -Total $total -Workload 'app-alpha'))
        }
        $root = Get-Workspace -Name 'console-exports'
        InModuleScope FinOpsForecast -Parameters @{ Root = $root; Settings = (New-TestSettings -Root $exports) } { Save-ForecastStoredSettings -Root $Root -Settings $Settings }
        Set-TestAnswers @(
            'R', ''
            '7', 'N'
            '6', 'N', 'B'
            '3', '7', '0', '12', '3', '35', 'Auto', ''
            '4', 'S', 'A', 'PURCHASE', 'ONETIME', 'ADDITIVE', 'ri-new', 'Synthetic RI', '2027-01', '', '1200', '', '', 'B', 'B'
            'W', 'V', '2', '1', '', 'F', 'alpha', 'B'
            '5', ''
            'F', ''
            'P', ''
            'Q'
        )
        InModuleScope FinOpsForecast -Parameters @{ Root = $root; AsOf = $script:AsOf; Out = (Join-Path $TestDrive 'console-reports') } { Show-ForecastSetupReview -Root $Root -AsOf $AsOf -OutputPath $Out }
        Get-RedLines | Should -BeNullOrEmpty
        $script:Answers.Count | Should -Be 0
        $settings = InModuleScope FinOpsForecast -Parameters @{ Root = $root } { Get-ForecastStoredSettings -Root $Root }
        $settings.period.fiscalYearStartMonth | Should -Be 7
        @($settings.scheduledItems).id | Should -Contain 'ri-new'
        $vintages = InModuleScope FinOpsForecast -Parameters @{ Root = $root } { Get-ForecastVintages -Root $Root }
        @($vintages).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath (Join-Path $TestDrive 'console-reports') -Directory).Count | Should -Be 2
        ($script:Console.Text -join "`n") | Should -Match 'Refresh succeeded'
        ($script:Console.Text -join "`n") | Should -Match 'Forecast saved'
    }

    It 'Reviews a change the forecast didn''t flag from 5 Exceptions' {
        # Run rates 3,000, 1,500, and 1,530. Two changes can't be flagged, but the drop is new commitments covering usage.
        $exports = Join-Path $TestDrive 'console-by-hand'
        foreach ($entry in @(@('2026-08', 3100), @('2026-09', 1500), @('2026-10', 1581))) {
            $null = New-SyntheticExportRun -Root $exports -Kind 'MCA' -Month $entry[0] -Scope $script:ProfileScope -Parts @(, @(New-SyntheticMonthRows -Month $entry[0] -Total $entry[1]))
        }
        $root = Get-Workspace -Name 'console-by-hand'
        $settings = New-TestSettings -Root $exports -StartMonth 8
        $settings.period.lookbackMonths = 3
        $settings.method.minimumRetained = 1
        InModuleScope FinOpsForecast -Parameters @{ Root = $root; Settings = $settings } { Save-ForecastStoredSettings -Root $Root -Settings $Settings }
        Set-TestAnswers @('R', '', '5', 'C', '1', '3', 'Reservations bought in September', 'B', 'Q')
        InModuleScope FinOpsForecast -Parameters @{ Root = $root; AsOf = $script:AsOf } { Show-ForecastSetupReview -Root $Root -AsOf $AsOf }
        Get-RedLines | Should -BeNullOrEmpty
        $script:Answers.Count | Should -Be 0
        ($script:Console.Text -join "`n") | Should -Match 'Nothing needs a decision'
        $session = InModuleScope FinOpsForecast -Parameters @{ Root = $root; AsOf = $script:AsOf } { Invoke-ForecastEvaluation -Root $Root -AsOf $AsOf }
        $drop = $session.Model.Comparisons.Items[0]
        $drop.Review.Decision | Should -Be 'StepChange'
        $drop.Review.Note | Should -Be 'Reservations bought in September'
        $drop.Retained | Should -BeFalse
        $session.Model.Growth.Central | Should -Be 0.02
    }

    It 'Keeps a filtered Exceptions list to its own category' {
        $session = [pscustomobject]@{ Readiness = [pscustomobject]@{ Reviews = @() }; Model = [pscustomobject]@{ Comparisons = [pscustomobject]@{ Items = @([pscustomobject]@{ Status = 'Defined' }) } } }
        Set-TestAnswers @('')
        InModuleScope FinOpsForecast -Parameters @{ Session = $session } { Show-ForecastExceptions -Root 'unused' -Session $Session -Category 'ManualMonth' }
        ($script:Console.Text -join "`n") | Should -Match 'Nothing to review'
        $script:Answers.Count | Should -Be 0
    }

    It 'Adds and edits a Cost Details source' {
        $root = Get-Workspace -Name 'console-costdetails'
        InModuleScope FinOpsForecast -Parameters @{ Root = $root; Settings = (New-TestSettings) } { Save-ForecastStoredSettings -Root $Root -Settings $Settings }
        Set-TestAnswers @(
            'C', $script:ProfileScope, '1', '2026-07', '', 'MCA', 'Live MCA', ''
            'E', '1', 'Renamed', '7', 'NONE', '2026-10', 'EA', ''
            'B'
        )
        InModuleScope FinOpsForecast -Parameters @{ Root = $root } { Edit-ForecastSources -Root $Root }
        Get-RedLines | Should -BeNullOrEmpty
        $script:Answers.Count | Should -Be 0
        $source = @((InModuleScope FinOpsForecast -Parameters @{ Root = $root } { Get-ForecastStoredSettings -Root $Root }).sources)[0]
        $source.kind | Should -Be 'CostDetails'
        $source.scope | Should -Be $script:ProfileScope
        $source.label | Should -Be 'Renamed'
        $source.chunkDays | Should -Be 7
        $source.fromMonth | Should -Be ''
        $source.toMonth | Should -Be '2026-10'
        $source.agreement | Should -Be 'EA'
        ($script:Console.Text -join "`n") | Should -Match '7-day reports, earliest to 2026-10 \| billingProfiles/BP-SYNTH-01'
    }

    It 'Starts a new Cost Details source at what the forecast period needs by default' {
        $root = Get-Workspace -Name 'console-costdetails-auto'
        InModuleScope FinOpsForecast -Parameters @{ Root = $root; Settings = (New-TestSettings) } { Save-ForecastStoredSettings -Root $Root -Settings $Settings }
        Set-TestAnswers @('C', $script:ProfileScope, '', '', '', '', '', '', 'B')
        InModuleScope FinOpsForecast -Parameters @{ Root = $root } { Edit-ForecastSources -Root $Root }
        Get-RedLines | Should -BeNullOrEmpty
        $script:Answers.Count | Should -Be 0
        $source = @((InModuleScope FinOpsForecast -Parameters @{ Root = $root } { Get-ForecastStoredSettings -Root $Root }).sources)[0]
        $source.fromMonth | Should -Be 'Auto'
        $source.toMonth | Should -Be ''
        ($script:Console.Text -join "`n") | Should -Match '7-day reports, auto to current'
    }

    It 'Enters, approves, and forecasts manual inputs' {
        $root = Get-Workspace -Name 'console-manual'
        $settings = New-TestSettings -Mode 'Manual'
        $settings.scope.subscriptionIds = @()
        InModuleScope FinOpsForecast -Parameters @{ Root = $root; Settings = $settings } { Save-ForecastStoredSettings -Root $Root -Settings $Settings }
        $answers = [Collections.Generic.List[string]]::new()
        $answers.AddRange([string[]]@('I', 'C', 'USD', 'S', 'Synthetic manual scope'))
        foreach ($month in (Get-TestMonthKeys -Last '2026-10')) {
            $value = [string](100 * [DateTime]::DaysInMonth([int]$month.Substring(0, 4), [int]$month.Substring(5, 2)))
            $answers.AddRange([string[]]@('E', $month, $value, "Synthetic invoice $month"))
        }
        $answers.AddRange([string[]]@('E', '2026-11', '', ''))
        $answers.AddRange([string[]]@('O', 'refund-1', '2026-10', '-50', 'Refund', 'Synthetic refund', 'credit memo 1'))
        $answers.Add('A')
        for ($i = 0; $i -lt 12; $i++) { $answers.AddRange([string[]]@('1', '1', '')) }
        $answers.AddRange([string[]]@('B', 'B', 'F', '', 'Q'))
        Set-TestAnswers $answers.ToArray()
        InModuleScope FinOpsForecast -Parameters @{ Root = $root; AsOf = $script:AsOf; Out = (Join-Path $TestDrive 'manual-reports') } { Show-ForecastSetupReview -Root $Root -AsOf $AsOf -OutputPath $Out }
        Get-RedLines | Should -BeNullOrEmpty
        $inputs = InModuleScope FinOpsForecast -Parameters @{ Root = $root } { Get-ForecastStoredInputs -Root $Root }
        @($inputs.months | Where-Object status -EQ 'Entered').Count | Should -Be 12
        @($inputs.months | Where-Object month -EQ '2026-11')[0].status | Should -Be 'Missing'
        $inputs.otherCharges[0].amount | Should -Be '-50'
        @(InModuleScope FinOpsForecast -Parameters @{ Root = $root } { Get-ForecastVintages -Root $Root }).Count | Should -Be 1
    }
}
