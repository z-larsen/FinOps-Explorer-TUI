# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers write synthetic fixtures in TestDrive only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helpers build collections.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'Forecast.TestHelpers.ps1')
    $script:AsOf = [datetime]'2026-11-06T12:00:00Z'

    function New-ReviewDataset {
        $values = [ordered]@{}
        foreach ($month in (Get-TestMonthKeys -Last '2026-10')) {
            $date = [datetime]::ParseExact("$month-01", 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
            $values[$month] = [decimal]$date.AddMonths(1).AddDays(-1).Day * 100d
        }
        New-TestDataset -Values $values
    }

    function Read-ReviewHistory {
        param($Settings, $Reviews = @{})
        InModuleScope FinOpsForecast -Parameters @{ Settings = $Settings; Reviews = $Reviews } {
            $profileValue = Get-ForecastIngestProfile -Settings $Settings
            $results = @(foreach ($source in $Settings.sources) {
                    foreach ($run in (Find-ForecastExportRuns -Source $source -Blobs (Get-ForecastSourceBlobs -Source $source))) {
                        Invoke-ForecastRunIngest -Source $source -Run $run -IngestProfile $profileValue
                    }
                })
            $selection = Select-ForecastRuns -Results $results -Settings $Settings -Reviews $Reviews
            $dataset = Merge-ForecastExportHistory -Results $results -Selection $selection -Settings $Settings -Reviews $Reviews
            [pscustomobject]@{ Results = $results; Selection = $selection; Dataset = $dataset }
        }
    }

    function Approve-ReviewItems {
        param($Items)
        $reviews = @{}
        foreach ($item in $Items) {
            $reviews[$item.Key] = [pscustomobject]@{ decision = 'Approved'; fingerprint = $item.Fingerprint; note = 'Synthetic review'; value = $null }
        }
        return $reviews
    }
}

Describe 'Copilot review regressions' {
    It 'Invalidates every manual approval when the billing currency changes' {
        InModuleScope FinOpsForecast -Parameters @{ AsOf = $script:AsOf } {
            $settings = New-ForecastDefaultSettings
            $settings.dataMode = 'Manual'
            $inputs = New-ForecastInputs
            $inputs.currency = 'USD'
            foreach ($month in (Get-ForecastMonthSpan -First '2025-11' -Last '2026-10')) {
                $null = Set-ForecastInputMonth -Inputs $inputs -Month $month -Value ([string](100 * (Get-ForecastDaysInMonth $month))) -Evidence 'Synthetic evidence'
            }
            $pending = ConvertTo-ForecastDatasetFromInputs -Inputs $inputs -Settings $settings -Reviews @{}
            $reviews = @{}
            foreach ($item in $pending.Reviews) { $reviews[$item.Key] = [pscustomobject]@{ decision = 'Approved'; fingerprint = $item.Fingerprint; note = 'USD only'; value = $null } }
            $approved = ConvertTo-ForecastDatasetFromInputs -Inputs $inputs -Settings $settings -Reviews $reviews
            @($approved.Reviews | Where-Object Decision -EQ 'Approved').Count | Should -Be 12
            $inputs.currency = 'EUR'
            $changed = ConvertTo-ForecastDatasetFromInputs -Inputs $inputs -Settings $settings -Reviews $reviews
            @($changed.Reviews | Where-Object { $_.Decision -eq 'Pending' -and $_.Stale }).Count | Should -Be 12
            $changed.Months[0].Headline | Should -Be $approved.Months[0].Headline
            $model = Invoke-ForecastModel -Dataset $changed -Settings $settings -Reviews $reviews -AsOf $AsOf
            (Test-ForecastReadiness -Dataset $changed -Model $model -Settings $settings -AsOf $AsOf).Ready | Should -BeFalse
        }
    }

    It 'Keeps legacy history provisional despite whole-month folder dates' {
        $root = Join-Path $TestDrive 'dated-legacy'
        foreach ($month in (Get-TestMonthKeys -Last '2026-10')) {
            $first = [datetime]::ParseExact("$month-01", 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
            $last = $first.AddMonths(1).AddDays(-1)
            $folder = Join-Path $root "exports\$($first.ToString('yyyyMMdd'))-$($last.ToString('yyyyMMdd'))"
            [void][IO.Directory]::CreateDirectory($folder)
            $rows = @(New-SyntheticRow -Date $first.AddDays(14).ToString('MM/dd/yyyy') -Cost ([string]($last.Day * 100)))
            [IO.File]::WriteAllText((Join-Path $folder 'actual.csv'), (ConvertTo-SyntheticCsv -Kind EA -Rows $rows))
        }
        $settings = New-TestSettings -Root $root
        $pending = Read-ReviewHistory -Settings $settings
        $history = Read-ReviewHistory -Settings $settings -Reviews (Approve-ReviewItems $pending.Dataset.Reviews)
        @($history.Dataset.Months | Where-Object Status -EQ 'Provisional').Count | Should -Be 12
        @($history.Selection.Selection | Where-Object Final).Count | Should -Be 0
        InModuleScope FinOpsForecast -Parameters @{ Dataset = $history.Dataset; Settings = $settings; AsOf = $script:AsOf } {
            $model = Invoke-ForecastModel -Dataset $Dataset -Settings $Settings -Reviews @{} -AsOf $AsOf
            (Test-ForecastReadiness -Dataset $Dataset -Model $model -Settings $Settings -AsOf $AsOf).Ready | Should -BeFalse
        }
    }

    It 'Does not infer legacy completeness without an observed last day' {
        InModuleScope FinOpsForecast {
            $result = [pscustomobject]@{ HasManifest = $false; Start = [datetime]'2026-10-01'; End = [datetime]'2026-10-31'; MonthStats = @() }
            Get-ForecastRunCoverage -Result $result -Month '2026-10' | Should -Be 'MonthToDate'
            $result.MonthStats = @([pscustomobject]@{ Month = '2026-10'; Through = [datetime]'2026-10-31' })
            Get-ForecastRunCoverage -Result $result -Month '2026-10' | Should -Be 'Unknown'
            $result.Start = [datetime]'2026-10-15'
            Get-ForecastRunCoverage -Result $result -Month '2026-10' | Should -Be 'Partial'
        }
    }

    It 'Keeps independent legacy files with the same relative name' {
        $settings = New-TestSettings -Subscriptions @('A', 'B')
        $settings.sources = @(foreach ($entry in @(@{ Id = 'a'; Sub = 'A'; Amount = '100' }, @{ Id = 'b'; Sub = 'B'; Amount = '200' })) {
                $root = Join-Path $TestDrive $entry.Id
                [void][IO.Directory]::CreateDirectory($root)
                $rows = @(New-SyntheticRow -Date '10/31/2026' -Subscription $entry.Sub -Cost $entry.Amount)
                [IO.File]::WriteAllText((Join-Path $root 'actual.csv'), (ConvertTo-SyntheticCsv -Kind EA -Rows $rows))
                [pscustomobject]@{ id = $entry.Id; kind = 'LocalFolder'; label = 'Synthetic'; path = $root; prefix = ''; agreement = 'Auto' }
            })
        $pending = Read-ReviewHistory -Settings $settings
        @($pending.Dataset.Reviews | Where-Object Category -EQ 'Run').Count | Should -Be 2
        $history = Read-ReviewHistory -Settings $settings -Reviews (Approve-ReviewItems $pending.Dataset.Reviews)
        $history.Selection.Selection.Count | Should -Be 2
        $history.Dataset.Months[0].Headline | Should -Be 300
        $history.Dataset.Reconciliation.Count | Should -Be 2
        @($history.Dataset.Reconciliation | Where-Object Difference -NE 0).Count | Should -Be 0
    }

    It 'Still counts a manifest-backed run reached through two sources once' {
        $root = Join-Path $TestDrive 'manifest-original'
        $copy = Join-Path $TestDrive 'manifest-copy'
        $null = New-SyntheticExportRun -Root $root -Kind EA -Month '2026-10' -Parts @(, @(New-SyntheticRow -Date '10/31/2026' -Cost '100'))
        Copy-Item -LiteralPath $root -Destination $copy -Recurse
        $settings = New-TestSettings -Root $root
        $source = $settings.sources[0] | Select-Object *
        $source.id = 'replica'; $source.path = $copy
        $settings.sources += $source
        $history = Read-ReviewHistory -Settings $settings
        $history.Results.Count | Should -Be 2
        $history.Selection.Selection.Count | Should -Be 1
        $history.Dataset.Months[0].Headline | Should -Be 100
    }

    It 'Rejects sensitivity percentiles <Low>/<High> outside the median bracket' -ForEach @(
        @{ Low = 75; High = 90 }, @{ Low = 10; High = 25 }, @{ Low = 50; High = 90 }, @{ Low = 10; High = 50 }
        @{ Low = -1; High = 75 }, @{ Low = 25; High = 101 }
    ) {
        $settings = New-TestSettings -Mode 'Manual'
        $settings.method.lowPercentile = $Low
        $settings.method.highPercentile = $High
        InModuleScope FinOpsForecast -Parameters @{ Settings = $settings; Dataset = (New-ReviewDataset); AsOf = $script:AsOf } {
            @(Test-ForecastSettings -Settings $Settings | Where-Object Code -EQ 'SET-BAND').Count | Should -Be 1
            if ($Settings.method.lowPercentile -lt 0 -or $Settings.method.highPercentile -gt 100) {
                { Invoke-ForecastModel -Dataset $Dataset -Settings $Settings -Reviews @{} -AsOf $AsOf } | Should -Throw '*between 0 and 100*'
                return
            }
            $model = Invoke-ForecastModel -Dataset $Dataset -Settings $Settings -Reviews @{} -AsOf $AsOf
            (Test-ForecastReadiness -Dataset $Dataset -Model $model -Settings $Settings -AsOf $AsOf).Ready | Should -BeFalse
        }
    }

    It 'Accepts sensitivity percentiles <Low>/<High> bracketing the median' -ForEach @(
        @{ Low = 0; High = 100 }, @{ Low = 25; High = 75 }, @{ Low = 49; High = 51 }
    ) {
        $settings = New-TestSettings -Mode 'Manual'
        $settings.method.lowPercentile = $Low; $settings.method.highPercentile = $High
        InModuleScope FinOpsForecast -Parameters @{ Settings = $settings } {
            @(Test-ForecastSettings -Settings $Settings | Where-Object Code -EQ 'SET-BAND').Count | Should -Be 0
        }
    }

    It 'Treats a month as final five days after it ends' {
        # Usage can change until the fifth day after a month ends, so November closes at the start of December 6.
        InModuleScope FinOpsForecast {
            $settings = New-ForecastDefaultSettings
            Get-ForecastFirstNeededMonth -Settings $settings -AsOf ([datetime]::SpecifyKind([datetime]'2026-12-05T23:59:00', 'Utc')) | Should -Be '2025-11'
            Get-ForecastFirstNeededMonth -Settings $settings -AsOf ([datetime]::SpecifyKind([datetime]'2026-12-06T00:00:00', 'Utc')) | Should -Be '2025-12'
        }
    }

    It 'Moves the old three-day default to five days, but keeps <Grace> for <Case>' -ForEach @(
        @{ Case = 'schema 1 at the old default'; Version = 1; Grace = 3; Expected = 5 }
        @{ Case = 'settings without a schema version'; Version = $null; Grace = 3; Expected = 5 }
        @{ Case = 'schema 1 with another value'; Version = 1; Grace = 4; Expected = 4 }
        @{ Case = 'schema 2, where 3 was chosen'; Version = 2; Grace = 3; Expected = 3 }
    ) {
        InModuleScope FinOpsForecast -Parameters @{ Version = $Version; Grace = $Grace; Expected = $Expected } {
            $loaded = [pscustomobject]@{ period = [pscustomobject]@{ graceDays = $Grace } }
            if ($null -ne $Version) { $loaded | Add-Member -NotePropertyName schemaVersion -NotePropertyValue $Version }
            (ConvertTo-ForecastSettings -Loaded $loaded).period.graceDays | Should -Be $Expected
        }
    }

    It 'Blocks saving when a future pinned window is replaced for preview' {
        $settings = New-TestSettings -Mode 'Manual'
        $settings.period.windowEnd = '2027-01'
        InModuleScope FinOpsForecast -Parameters @{ Settings = $settings; Dataset = (New-ReviewDataset); AsOf = $script:AsOf; Root = (Join-Path $TestDrive 'blocked-vintage') } {
            $model = Invoke-ForecastModel -Dataset $Dataset -Settings $Settings -Reviews @{} -AsOf $AsOf
            $model.Window.Last | Should -Be '2026-10'
            $ready = Test-ForecastReadiness -Dataset $Dataset -Model $model -Settings $Settings -AsOf $AsOf
            $ready.Ready | Should -BeFalse
            ($ready.Checks | Where-Object Id -EQ 'SETTINGS').Detail | Should -Match '2027-01'
            $session = [pscustomobject]@{ Root = $Root; Readiness = $ready }
            { Publish-ForecastOutputs -Session $session -SaveVintage } | Should -Throw '*isn''t Ready*'
            Test-Path -LiteralPath $Root | Should -BeFalse
        }
    }

    It 'Preserves SHA-256 identifiers using runtime-compatible hashing' {
        InModuleScope FinOpsForecast {
            Get-ForecastHash -Text 'abc' -Length 64 | Should -Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
            Get-ForecastHash -Text 'abc' | Should -Be 'ba7816bf8f01cfea'
            Get-ForecastHash -Text '' -Length 64 | Should -Be 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
        }
    }

    It 'Renders <Kind> amounts without confusing zero with missing' -ForEach @(
        @{ Kind = 'decimal zero'; Value = [decimal]0; Expected = '0.00' }
        @{ Kind = 'integer zero'; Value = 0; Expected = '0.00' }
        @{ Kind = 'string zero'; Value = '0'; Expected = '0.00' }
        @{ Kind = 'a refund'; Value = [decimal]-5; Expected = '-5.00' }
        @{ Kind = 'null'; Value = $null; Expected = '' }
        @{ Kind = 'empty string'; Value = ''; Expected = '' }
    ) {
        InModuleScope FinOpsForecast -Parameters @{ Value = $Value; Expected = $Expected } {
            Format-ForecastHtmlCell -Value $Value -Format amount | Should -BeExactly $Expected
        }
    }

    It 'Documents loading the forecast entrypoint before its first direct invocation' {
        $readme = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'README.md'))
        $section = [regex]::Match($readme, '(?s)## Forecast pre-credit cost and workload growth(.*?)## Reports and privacy').Groups[1].Value
        $example = [regex]::Match($section, '(?s)```powershell\s+(.*?)```').Groups[1].Value
        $example | Should -Match '(?s)\. \.\\Public\\Start-FinOpsForecast\.ps1\s+Start-FinOpsForecast'
        . (Join-Path $script:RepoRoot 'Public\Start-FinOpsForecast.ps1')
        (Get-Command Start-FinOpsForecast).CommandType | Should -Be 'Function'
    }
}
