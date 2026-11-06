# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers create synthetic fixtures in TestDrive only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helpers are named for the collections they build.')]
param()
BeforeAll {
    . (Join-Path $PSScriptRoot 'Forecast.TestHelpers.ps1')
    $script:AsOf = [datetime]::SpecifyKind([datetime]'2026-11-05T12:00:00', [DateTimeKind]::Utc)

    function New-TestInputs {
        param([hashtable]$Usage = @{}, [object[]]$Charges = @())
        InModuleScope FinOpsForecast -Parameters @{ Usage = $Usage; Charges = $Charges } {
            $inputs = New-ForecastInputs
            $inputs.currency = 'USD'
            foreach ($month in ($Usage.Keys | Sort-Object)) { $null = Set-ForecastInputMonth -Inputs $inputs -Month $month -Value $Usage[$month] -Evidence "Synthetic invoice $month" }
            foreach ($charge in $Charges) { $null = Add-ForecastOtherCharge -Inputs $inputs @charge }
            $inputs
        }
    }

    function ConvertTo-TestDataset {
        param($Inputs, $Settings = (New-TestSettings -Mode 'Manual'), $Reviews = @{})
        InModuleScope FinOpsForecast -Parameters @{ Inputs = $Inputs; Settings = $Settings; Reviews = $Reviews } { ConvertTo-ForecastDatasetFromInputs -Inputs $Inputs -Settings $Settings -Reviews $Reviews }
    }
}

Describe 'Manual inputs' {
    It 'Keeps a missing month distinct from a verified zero' {
        $inputs = New-TestInputs -Usage @{ '2026-09' = ''; '2026-10' = 'zero' }
        $dataset = ConvertTo-TestDataset -Inputs $inputs
        $september = @($dataset.Months | Where-Object Month -EQ '2026-09')[0]
        $october = @($dataset.Months | Where-Object Month -EQ '2026-10')[0]
        $september.Status | Should -Be 'Missing'
        $september.RunRate | Should -BeNullOrEmpty
        $october.Status | Should -Be 'VerifiedZero'
        $october.RunRate | Should -Be 0
    }

    It 'Refuses a bare 0 so a zero is always confirmed' {
        { New-TestInputs -Usage @{ '2026-10' = '0' } } | Should -Throw '*zero*'
    }

    It 'Refuses negative usage and asks for a refund charge instead' {
        { New-TestInputs -Usage @{ '2026-10' = '-5' } } | Should -Throw '*refunds*'
    }

    It 'Applies signed charges and leaves the pre-credit headline unchanged by credits' {
        $charges = @(
            @{ Id = 'refund-1'; Month = '2026-10'; Amount = '-40'; Type = 'Refund' }
            @{ Id = 'credit-1'; Month = '2026-10'; Amount = '-500'; Type = 'Credit' }
            @{ Id = 'mkt-1'; Month = '2026-10'; Amount = '75'; Type = 'Marketplace' }
            @{ Id = 'tax-1'; Month = '2026-10'; Amount = '19'; Type = 'Tax' }
        )
        $inputs = New-TestInputs -Usage @{ '2026-10' = '1000' } -Charges $charges
        $october = @((ConvertTo-TestDataset -Inputs $inputs).Months | Where-Object Month -EQ '2026-10')[0]
        $october.Headline | Should -Be 960
        $october.Credit | Should -Be -500
        $october.ExcludedMarketplace | Should -Be 75
        $october.ExcludedTax | Should -Be 19

        $settings = New-TestSettings -Mode 'Manual'
        $settings.filters.includeTax = $true
        (@((ConvertTo-TestDataset -Inputs $inputs -Settings $settings).Months | Where-Object Month -EQ '2026-10')[0]).Headline | Should -Be 979
    }

    It 'Reports duplicate months and duplicate charge IDs' {
        $inputs = New-TestInputs -Usage @{ '2026-10' = '10' }
        $inputs.months = @($inputs.months) + $inputs.months[0]
        $inputs.otherCharges = @(
            [pscustomobject]@{ id = 'c1'; month = '2026-10'; amount = '1'; type = 'Other' }
            [pscustomobject]@{ id = 'C1'; month = '2026-10'; amount = '2'; type = 'Other' }
        )
        $issues = InModuleScope FinOpsForecast -Parameters @{ Inputs = $inputs } { Test-ForecastInputs -Inputs $Inputs }
        @($issues | Where-Object Code -EQ 'INP-DUPLICATE').Count | Should -Be 1
        @($issues | Where-Object Code -EQ 'INP-CHARGEID').Count | Should -Be 1
    }

    It 'Requires an approval per month and clears it when a value changes' {
        $inputs = New-TestInputs -Usage @{ '2026-10' = '1000' }
        $first = ConvertTo-TestDataset -Inputs $inputs
        $review = @($first.Reviews | Where-Object Subject -EQ '2026-10')[0]
        $review.Decision | Should -Be 'Pending'
        $reviews = @{ $review.Key = [pscustomobject]@{ decision = 'Approved'; fingerprint = $review.Fingerprint; note = ''; value = $null } }
        (@((ConvertTo-TestDataset -Inputs $inputs -Reviews $reviews).Reviews)[0]).Decision | Should -Be 'Approved'
        $changed = New-TestInputs -Usage @{ '2026-10' = '1001' }
        $after = @((ConvertTo-TestDataset -Inputs $changed -Reviews $reviews).Reviews)[0]
        $after.Decision | Should -Be 'Pending'
        $after.Stale | Should -BeTrue
    }

    It 'Produces a Ready forecast from twelve approved months' {
        $usage = @{}
        foreach ($month in (Get-TestMonthKeys -Last '2026-10')) { $usage[$month] = [string](1000 + [int]$month.Substring(5, 2)) }
        $inputs = New-TestInputs -Usage $usage
        $settings = New-TestSettings -Mode 'Manual'
        $settings.scope.subscriptionIds = @()
        $pending = ConvertTo-TestDataset -Inputs $inputs -Settings $settings
        $reviews = @{}
        foreach ($item in $pending.Reviews) { $reviews[$item.Key] = [pscustomobject]@{ decision = 'Approved'; fingerprint = $item.Fingerprint; note = ''; value = $null } }
        $readiness = InModuleScope FinOpsForecast -Parameters @{ Inputs = $inputs; Settings = $settings; Reviews = $reviews; AsOf = $script:AsOf } {
            $dataset = ConvertTo-ForecastDatasetFromInputs -Inputs $Inputs -Settings $Settings -Reviews $Reviews
            $model = Invoke-ForecastModel -Dataset $dataset -Settings $Settings -Reviews $Reviews -AsOf $AsOf
            $pendingModel = @($model.Reviews | Where-Object Decision -EQ 'Pending')
            foreach ($item in $pendingModel) { $Reviews[$item.Key] = [pscustomobject]@{ decision = $item.Suggested; fingerprint = $item.Fingerprint; note = 'synthetic'; value = $null } }
            $model = Invoke-ForecastModel -Dataset $dataset -Settings $Settings -Reviews $Reviews -AsOf $AsOf
            Test-ForecastReadiness -Dataset $dataset -Model $model -Settings $Settings -AsOf $AsOf
        }
        ($readiness.Checks | Where-Object Status -EQ 'Fail' | ForEach-Object { "$($_.Id): $($_.Detail)" }) -join ' | ' | Should -BeNullOrEmpty
        $readiness.Ready | Should -BeTrue
    }
}
