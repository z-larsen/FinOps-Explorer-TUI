# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers create synthetic fixtures in TestDrive only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helpers are named for the collections they build.')]
param()
BeforeAll {
    . (Join-Path $PSScriptRoot 'Forecast.TestHelpers.ps1')
    $script:AsOf = [datetime]::SpecifyKind([datetime]'2026-11-07T12:00:00', [DateTimeKind]::Utc)

    function New-TestRoot { $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($path); return $path }

    function Invoke-TestHistory {
        param([Parameter(Mandatory)]$Settings, $Reviews = @{})
        InModuleScope FinOpsForecast -Parameters @{ Settings = $Settings; Reviews = $Reviews; AsOf = $script:AsOf } {
            $ingestProfile = Get-ForecastIngestProfile -Settings $Settings
            $results = @(foreach ($source in $Settings.sources) {
                    $blobs = Get-ForecastSourceBlobs -Source $source
                    foreach ($run in (Find-ForecastExportRuns -Source $source -Blobs $blobs)) { Invoke-ForecastRunIngest -Source $source -Run $run -IngestProfile $ingestProfile }
                })
            $selection = Select-ForecastRuns -Results $results -Settings $Settings -Reviews $Reviews
            $dataset = Merge-ForecastExportHistory -Results $results -Selection $selection -Settings $Settings -Reviews $Reviews
            [pscustomobject]@{ Results = $results; Selection = $selection; Dataset = $dataset }
        }
    }

    function Get-TestMonth { param($History, [string]$Month) @($History.Dataset.Months | Where-Object Month -EQ $Month)[0] }

    function New-Review {
        param($Item, [string]$Decision)
        @{ $Item.Key = [pscustomobject]@{ decision = $Decision; fingerprint = $Item.Fingerprint; note = 'synthetic review'; value = $null } }
    }
}

Describe 'Export history' {
    Context 'Schemas and precision' {
        It 'Reads <Kind> cost details with exact decimals and signed charges' -ForEach @(
            @{ Kind = 'EA'; Gzip = $false }
            @{ Kind = 'MCA'; Gzip = $true }
            @{ Kind = 'FOCUS'; Gzip = $false }
        ) {
            $root = New-TestRoot
            $rows = @(
                New-SyntheticRow -Date '10/01/2026' -Cost '0.12345678' -Workload 'app-alpha'
                New-SyntheticRow -Date '10/02/2026' -Cost '1000.00000001' -Workload 'app-alpha'
                New-SyntheticRow -Date '10/03/2026' -Cost '-25.5' -ChargeType 'Refund' -CommitmentId 'ri-synth-1'
            )
            $null = New-SyntheticExportRun -Root $root -Kind $Kind -Month '2026-10' -Parts @(, $rows) -Gzip:$Gzip
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            $history.Results[0].Status | Should -Be 'Complete'
            $history.Results[0].Schema | Should -Be $Kind
            $october = Get-TestMonth $history '2026-10'
            $october.RunRate | Should -Be ([decimal]'1000.12345679')
            $october.Purchase | Should -Be ([decimal]'-25.5')
            $october.Headline | Should -Be ([decimal]'974.62345679')
            $history.Dataset.Currency | Should -Be 'USD'
            @($history.Dataset.Reconciliation | Where-Object { $_.Difference -ne 0 }).Count | Should -Be 0
        }

        It 'Parses amounts the same way under a comma-decimal culture' {
            $root = New-TestRoot
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-10' -Parts @(, @(New-SyntheticRow -Date '10/01/2026' -Cost '1234.56'))
            $original = [Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::GetCultureInfo('de-DE')
                $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            }
            finally { [Threading.Thread]::CurrentThread.CurrentCulture = $original }
            (Get-TestMonth $history '2026-10').RunRate | Should -Be ([decimal]'1234.56')
        }

        It 'Keeps identical legitimate charge rows instead of deduplicating them' {
            $root = New-TestRoot
            $row = New-SyntheticRow -Date '10/05/2026' -Cost '10.25' -Workload 'app-alpha'
            $null = New-SyntheticExportRun -Root $root -Kind 'MCA' -Month '2026-10' -Parts @(, @($row, $row, $row))
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            (Get-TestMonth $history '2026-10').RunRate | Should -Be ([decimal]'30.75')
            ($history.Dataset.Cells | Measure-Object -Property Rows -Sum).Sum | Should -Be 3
        }

        It 'Rejects an amortized dataset' {
            $root = New-TestRoot
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-10' -Dataset 'AmortizedCost' -Parts @(, @(New-SyntheticRow -Date '10/01/2026' -Cost '5'))
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            $history.Results[0].Status | Should -Be 'Unsupported'
            $history.Dataset.Months.Count | Should -Be 0
        }
    }

    Context 'Run selection' {
        It 'Produces identical results with the compiled and PowerShell reducers for <Kind>' -ForEach @(@{ Kind = 'EA' }, @{ Kind = 'MCA' }, @{ Kind = 'FOCUS' }) {
            $requestedReducer = [string]$env:FINOPS_FORECAST_REDUCER
            $root = New-TestRoot
            $rows = @(
                New-SyntheticRow -Date '10/01/2026' -Cost '10.12345678' -Workload 'app-alpha'
                New-SyntheticRow -Date '10/01/2026' -Cost '10.12345678' -Workload 'app-alpha'
                New-SyntheticRow -Date '10/02/2026' -Cost '0' -Workload 'a\"quoted' -PricingModel 'Reservation' -UnitPrice '1.5' -Quantity '24' -CommitmentId 'ri-1'
                New-SyntheticRow -Date '10/03/2026' -Cost '120' -ChargeType 'Purchase' -CommitmentId 'RI-1' -Frequency 'Recurring'
                New-SyntheticRow -Date '10/04/2026' -Cost '-7.5' -ChargeType 'Refund' -CommitmentId 'ri-1'
                New-SyntheticRow -Date '10/04/2026' -Cost '3' -ChargeType 'Refund' -CommitmentId 'ri-2'
                New-SyntheticRow -Date '10/05/2026' -Cost '44' -PublisherType 'Marketplace' -PublisherName 'Synthetic Vendor'
                New-SyntheticRow -Date '10/06/2026' -Cost '9' -Subscription '' -ChargeType 'Purchase' -CommitmentId 'sp-1'
                New-SyntheticRow -Date '10/07/2026' -Cost '2.25' -Subscription 'B' -ResourceGroup 'RG-Upper' -Workload 'app-beta'
                New-SyntheticRow -Date '10/08/2026' -Cost '1' -Workload 'b\q\u0041'
                New-SyntheticRow -Date '10/08/2026' -Cost '1' -Workload '\/Date(1700000000000)\/'
                New-SyntheticRow -Date '10/08/2026' -Cost '1' -Workload '\u0032024-01-05T00:00:00Z'
            )
            $null = New-SyntheticExportRun -Root $root -Kind $Kind -Month '2026-10' -Parts @(, $rows) -Gzip
            $settings = New-TestSettings -Root $root
            $results = foreach ($reducer in 'Compiled', 'PowerShell') {
                InModuleScope FinOpsForecast -Parameters @{ Settings = $settings; Reducer = $reducer } {
                    $script:ForecastAggregatorReady = $null
                    $previousReducer = $env:FINOPS_FORECAST_REDUCER
                    $env:FINOPS_FORECAST_REDUCER = if ($Reducer -eq 'PowerShell') { 'PowerShell' } else { $null }
                    try {
                        $source = $Settings.sources[0]
                        $run = @(Find-ForecastExportRuns -Source $source -Blobs (Get-ForecastSourceBlobs -Source $source))[0]
                        $ingested = Invoke-ForecastRunIngest -Source $source -Run $run -IngestProfile (Get-ForecastIngestProfile -Settings $Settings)
                        [pscustomobject]@{
                            Compiled = [bool]$script:ForecastAggregatorReady
                            Cells = (@($ingested.Cells | Sort-Object { "$($_.Month)|$($_.SubscriptionId)|$($_.Tag)|$($_.ChargeType)|$($_.CommitmentId)|$($_.PublisherClass)|$($_.ResourceGroup)" }) | ConvertTo-Json -Depth 5 -Compress)
                            Stats = ($ingested.MonthStats | ConvertTo-Json -Depth 5 -Compress)
                            Names = (($ingested.SubscriptionNames.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';')
                            Parts = ($ingested.Parts | ConvertTo-Json -Compress)
                            Status = $ingested.Status
                        }
                    }
                    finally { $env:FINOPS_FORECAST_REDUCER = $previousReducer; $script:ForecastAggregatorReady = $null }
                }
            }
            $results[0].Compiled | Should -BeTrue
            [string]$env:FINOPS_FORECAST_REDUCER | Should -BeExactly $requestedReducer
            $results[1].Compiled | Should -BeFalse
            $results[0].Status | Should -Be 'Complete'
            $results[1].Cells | Should -BeExactly $results[0].Cells
            $results[1].Stats | Should -BeExactly $results[0].Stats
            $results[1].Names | Should -BeExactly $results[0].Names
            $results[1].Parts | Should -BeExactly $results[0].Parts
        }

        It 'Unescapes tag values the same way as the compiled reducer' {
            $cases = InModuleScope FinOpsForecast {
                foreach ($text in 'a\"b', 'b\q\u0041', '\/Date(1700000000000)\/', '\u0032024-01-05T00:00:00Z', 'tab\there', 'end\', 'bad\u00zz') {
                    ConvertFrom-ForecastJsonEscape -Value $text
                }
            }
            ($cases -join '|') | Should -BeExactly (@('a"b', 'b\qA', '/Date(1700000000000)/', '2024-01-05T00:00:00Z', "tab`there", 'end\', 'bad\u00zz') -join '|')
        }
        It 'Selects one run per month so month-to-date runs and corrections never stack' {
            $root = New-TestRoot
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-09' -Submitted ([datetime]'2026-09-10') -Parts @(, @(New-SyntheticRow -Date '09/01/2026' -Cost '100'))
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-09' -Submitted ([datetime]'2026-09-20') -Parts @(, @(New-SyntheticRow -Date '09/01/2026' -Cost '200'))
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-09' -Submitted ([datetime]'2026-10-04') -Parts @(, @(New-SyntheticRow -Date '09/01/2026' -Cost '300'))
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-09' -Submitted ([datetime]'2026-10-06') -Parts @(, @(New-SyntheticRow -Date '09/01/2026' -Cost '310'))
            $first = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            $september = Get-TestMonth $first '2026-09'
            $september.RunRate | Should -Be 310
            $september.Status | Should -Be 'Complete'
            @($first.Selection.Selection).Count | Should -Be 1
            $first.Selection.Selection[0].Superseded.Count | Should -Be 3

            $second = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            (Get-TestMonth $second '2026-09').RunRate | Should -Be 310
            $second.Selection.Selection[0].RunId | Should -Be $first.Selection.Selection[0].RunId
        }

        It 'Labels a month provisional until a run is submitted after the grace period' {
            $root = New-TestRoot
            $null = New-SyntheticExportRun -Root $root -Kind 'MCA' -Month '2026-10' -Submitted ([datetime]'2026-11-02') -Parts @(, @(New-SyntheticRow -Date '10/01/2026' -Cost '50'))
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            (Get-TestMonth $history '2026-10').Status | Should -Be 'Provisional'
        }

        It 'Reads a multi-month run into each month it covers' {
            $root = New-TestRoot
            $rows = @(New-SyntheticRow -Date '07/03/2026' -Cost '70'; New-SyntheticRow -Date '08/03/2026' -Cost '80'; New-SyntheticRow -Date '09/03/2026' -Cost '90')
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-07' -EndMonth '2026-09' -Parts @(, $rows)
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            (@($history.Dataset.Months | ForEach-Object { "$($_.Month)=$($_.RunRate)" }) -join ',') | Should -Be '2026-07=70,2026-08=80,2026-09=90'
        }

        It 'Keeps a whole-month run when a later run covers only the tail of the month' {
            $root = New-TestRoot
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-01' -Parts @(, @(New-SyntheticRow -Date '01/10/2026' -Cost '1000'))
            $tail = @(New-SyntheticRow -Date '01/26/2026' -Cost '100'; New-SyntheticRow -Date '02/02/2026' -Cost '50')
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-01' -RangeStart ([datetime]'2026-01-25') -RangeEnd ([datetime]'2026-02-05') -Submitted ([datetime]'2026-02-08') -Parts @(, $tail)
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            $january = Get-TestMonth $history '2026-01'
            $january.RunRate | Should -Be 1000
            $january.Status | Should -Be 'Complete'
            @($history.Dataset.Issues | Where-Object { $_.Code -eq 'RUN-PARTIAL' -and $_.Subject -eq '2026-01' }).Count | Should -Be 1
            $february = Get-TestMonth $history '2026-02'
            $february.RunRate | Should -Be 50
            $february.Status | Should -Be 'Provisional'
        }

        It 'Keeps a month provisional when only a month-to-date run covers it' {
            $root = New-TestRoot
            $null = New-SyntheticExportRun -Root $root -Kind 'MCA' -Month '2026-10' -RangeEnd ([datetime]'2026-10-20') -Submitted ([datetime]'2026-11-04') -Parts @(, @(New-SyntheticRow -Date '10/05/2026' -Cost '80'))
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            $history.Selection.Selection[0].Coverage | Should -Be 'MonthToDate'
            (Get-TestMonth $history '2026-10').Status | Should -Be 'Provisional'
        }
    }

    Context 'Partitions and completeness' {
        It 'Ingests every declared partition' {
            $root = New-TestRoot
            $parts = @(
                , @(New-SyntheticRow -Date '10/01/2026' -Cost '1')
                , @(New-SyntheticRow -Date '10/02/2026' -Cost '2')
                , @(New-SyntheticRow -Date '10/03/2026' -Cost '3')
            )
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-10' -Parts $parts -Gzip
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            $history.Results[0].Parts.Count | Should -Be 3
            (Get-TestMonth $history '2026-10').RunRate | Should -Be 6
        }

        It 'Marks a run <Case> as incomplete and doesn''t use it' -ForEach @(
            @{ Case = 'with a missing partition'; Arguments = @{ DeclareExtraPartitions = 1 }; Code = 'RUN-PARTITION' }
            @{ Case = 'with a row-count mismatch'; Arguments = @{ RowCountOffset = 1 }; Code = 'RUN-ROWS' }
            @{ Case = 'with a byte-count mismatch'; Arguments = @{ ByteCountOffset = 7 }; Code = 'RUN-BYTES' }
        ) {
            $root = New-TestRoot
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-10' -Parts @(, @(New-SyntheticRow -Date '10/01/2026' -Cost '1')) @Arguments
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            $history.Results[0].Status | Should -Be 'Incomplete'
            @($history.Results[0].Issues | Where-Object Code -EQ $Code).Count | Should -BeGreaterThan 0
            @($history.Dataset.Issues | Where-Object Code -EQ 'RUN-NOELIGIBLE').Count | Should -Be 1
            $history.Dataset.Months.Count | Should -Be 0
        }

        It 'Keeps the earlier complete run when the newest run is incomplete' {
            $root = New-TestRoot
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-09' -Submitted ([datetime]'2026-10-05') -Parts @(, @(New-SyntheticRow -Date '09/01/2026' -Cost '400'))
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-09' -Submitted ([datetime]'2026-10-07') -Parts @(, @(New-SyntheticRow -Date '09/01/2026' -Cost '999')) -DeclareExtraPartitions 1
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            (Get-TestMonth $history '2026-09').RunRate | Should -Be 400
            @($history.Dataset.Issues | Where-Object Code -EQ 'RUN-NEWERINCOMPLETE').Count | Should -Be 1
        }

        It 'Requires an approved review before using a legacy file without a manifest' {
            $root = New-TestRoot
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-09' -Parts @(, @(New-SyntheticRow -Date '09/01/2026' -Cost '12')) -NoManifest
            $folder = Get-ChildItem -Path $root -Recurse -Filter 'part_0_0001.csv' | Select-Object -First 1
            Rename-Item -LiteralPath $folder.FullName -NewName 'synth-actual_legacy.csv'
            $runFolder = $folder.Directory
            Move-Item -LiteralPath (Join-Path $runFolder.FullName 'synth-actual_legacy.csv') -Destination $runFolder.Parent.FullName
            $settings = New-TestSettings -Root $root
            $pending = Invoke-TestHistory -Settings $settings
            $pending.Results[0].Status | Should -Be 'Unverified'
            $review = @($pending.Dataset.Reviews | Where-Object Category -EQ 'Run')[0]
            $review.Decision | Should -Be 'Pending'
            $pending.Dataset.Months.Count | Should -Be 0
            $approved = Invoke-TestHistory -Settings $settings -Reviews (New-Review $review 'Approved')
            (Get-TestMonth $approved '2026-09').RunRate | Should -Be 12
        }

        It 'Treats a loose file whose rows end on <LastDate> as <Status>' -ForEach @(
            @{ LastDate = '06/19/2026'; Status = 'Provisional'; Coverage = 'MonthToDate' }
            @{ LastDate = '06/30/2026'; Status = 'Complete'; Coverage = 'Unknown' }
        ) {
            $root = New-TestRoot
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'loose')
            $csv = ConvertTo-SyntheticCsv -Kind 'EA' -Rows @(New-SyntheticRow -Date '06/01/2026' -Cost '40'; New-SyntheticRow -Date $LastDate -Cost '2')
            [IO.File]::WriteAllText((Join-Path $root 'loose\ea-actual.csv'), $csv)
            $settings = New-TestSettings -Root $root
            $review = @((Invoke-TestHistory -Settings $settings).Dataset.Reviews | Where-Object Category -EQ 'Run')[0]
            $review.Detail | Should -Match 'actual-cost export \(not amortized\)'
            $history = Invoke-TestHistory -Settings $settings -Reviews (New-Review $review 'Approved')
            $history.Selection.Selection[0].Coverage | Should -Be $Coverage
            $june = Get-TestMonth $history '2026-06'
            $june.Status | Should -Be $Status
            $june.Headline | Should -Be 42
        }

        It 'Warns when a final month''s data ends before the month does' {
            $root = New-TestRoot
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-09' -Parts @(, @(New-SyntheticRow -Date '09/01/2026' -Cost '5'; New-SyntheticRow -Date '09/19/2026' -Cost '5'))
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            $september = Get-TestMonth $history '2026-09'
            $september.Status | Should -Be 'Complete'
            $september.Note | Should -Match 'Last charge is dated 11 day\(s\) before month end'
            @($history.Dataset.Issues | Where-Object { $_.Code -eq 'RUN-EARLYEND' -and $_.Severity -eq 'Warn' -and $_.Subject -eq '2026-09' }).Count | Should -Be 1
        }

        It 'Rejects amortized cost in an actual-cost <Kind> file (<Case>)' -ForEach @(
            @{ Kind = 'EA'; Case = 'covered usage with a cost'; Row = @{ Date = '10/02/2026'; Cost = '7'; PricingModel = 'Reservation'; CommitmentId = 'ri-1' } }
            @{ Kind = 'MCA'; Case = 'an unused reservation charge'; Row = @{ Date = '10/02/2026'; Cost = '3'; ChargeType = 'UnusedReservation'; PricingModel = 'Reservation'; CommitmentId = 'ri-1' } }
        ) {
            $root = New-TestRoot
            $null = New-SyntheticExportRun -Root $root -Kind $Kind -Month '2026-10' -Parts @(, @(New-SyntheticRow -Date '10/01/2026' -Cost '100'; New-SyntheticRow @Row))
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            $history.Results[0].Status | Should -Be 'Invalid'
            @($history.Results[0].Issues | Where-Object Code -EQ 'RUN-AMORTIZED').Count | Should -Be 1
            @($history.Dataset.Issues | Where-Object Code -EQ 'RUN-NOELIGIBLE')[0].Message | Should -Match 'looks like amortized cost'
            $history.Dataset.Months.Count | Should -Be 0
        }

        It 'Uses the actual-cost file when an amortized copy sits beside it' {
            $root = New-TestRoot
            $folder = Join-Path $root 'loose'
            $null = New-Item -ItemType Directory -Path $folder
            $actual = @(
                New-SyntheticRow -Date '06/01/2026' -Cost '100'
                New-SyntheticRow -Date '06/30/2026' -Cost '0' -PricingModel 'Reservation' -CommitmentId 'ri-1'
                New-SyntheticRow -Date '06/10/2026' -Cost '30' -ChargeType 'Purchase' -CommitmentId 'ri-1'
            )
            $amortized = @(
                New-SyntheticRow -Date '06/01/2026' -Cost '100'
                New-SyntheticRow -Date '06/30/2026' -Cost '1' -PricingModel 'Reservation' -CommitmentId 'ri-1'
            )
            [IO.File]::WriteAllText((Join-Path $folder 'ea-actual.csv'), (ConvertTo-SyntheticCsv -Kind 'EA' -Rows $actual))
            [IO.File]::WriteAllText((Join-Path $folder 'ea-amortized.csv'), (ConvertTo-SyntheticCsv -Kind 'EA' -Rows $amortized))
            (Get-Item (Join-Path $folder 'ea-amortized.csv')).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(1)
            $settings = New-TestSettings -Root $root
            $reviews = @{}
            foreach ($item in @((Invoke-TestHistory -Settings $settings).Dataset.Reviews | Where-Object Category -EQ 'Run')) { $reviews += New-Review $item 'Approved' }
            $reviews.Count | Should -Be 1
            $history = Invoke-TestHistory -Settings $settings -Reviews $reviews
            $history.Selection.Selection[0].RunId | Should -Be 'legacy:loose/ea-actual.csv'
            (Get-TestMonth $history '2026-06').Headline | Should -Be 130
            @($history.Dataset.Issues | Where-Object Code -EQ 'RUN-LEGACYMULTI').Count | Should -Be 1
            @($history.Dataset.Issues | Where-Object Code -EQ 'RUN-NEWERINCOMPLETE')[0].Message | Should -Match 'looks like amortized cost'
        }

        It 'Treats only differences of at least a millionth as unreconciled' {
            InModuleScope FinOpsForecast {
                Test-ForecastMaterialDifference ([decimal]'0.000000000000000000000076') | Should -BeFalse
                Test-ForecastMaterialDifference ([decimal]'0.000000999') | Should -BeFalse
                Test-ForecastMaterialDifference ([decimal]'0.000001') | Should -BeTrue
                Test-ForecastMaterialDifference ([decimal]'-0.5') | Should -BeTrue
                Test-ForecastMaterialDifference $null | Should -BeFalse
            }
        }
    }

    Context 'Manifest identities and date coverage' {
        It 'Rejects a duplicate partition listed by <Reference>' -ForEach @(
            @{ Reference = 'the same path'; Alias = $false }
            @{ Reference = 'a different alias resolving to the same file'; Alias = $true }
        ) {
            $root = New-TestRoot
            $folder = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-10' -Parts @(, @(New-SyntheticRow -Date '10/31/2026' -Cost '100'))
            $path = Join-Path $folder 'manifest.json'
            $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $duplicate = $manifest.blobs[0] | Select-Object *
            if ($Alias) { $duplicate.blobName = 'part_0_0001.csv' }
            $manifest.blobs = @($manifest.blobs[0], $duplicate)
            $manifest.blobCount = 2
            $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            $history.Results[0].Status | Should -Be 'Incomplete'
            @($history.Results[0].Issues | Where-Object Code -EQ 'RUN-DUPLICATEPARTITION').Count | Should -Be 1
            $history.Dataset.Months.Count | Should -Be 0
        }

        It 'Rejects a manifest with <Case> end date' -ForEach @(
            @{ Case = 'a missing'; End = $null }
            @{ Case = 'a reversed'; End = '2026-09-30T00:00:00' }
        ) {
            $root = New-TestRoot
            $folder = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-10' -Parts @(, @(New-SyntheticRow -Date '10/31/2026' -Cost '100'))
            $path = Join-Path $folder 'manifest.json'
            $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $manifest.runInfo.endDate = $End
            $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            $history.Results[0].Status | Should -Be 'Incomplete'
            @($history.Results[0].Issues | Where-Object Code -EQ 'RUN-MANIFEST').Count | Should -Be 1
        }

        It 'Excludes later dates in the same month and reconciles every input row' {
            $root = New-TestRoot
            $rows = @(New-SyntheticRow -Date '10/05/2026' -Cost '100'; New-SyntheticRow -Date '10/20/2026' -Cost '900')
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-10' -RangeEnd ([datetime]'2026-10-10') -Parts @(, $rows)
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            (Get-TestMonth $history '2026-10').Headline | Should -Be 100
            $history.Results[0].OutsideRows | Should -Be 1
            $row = $history.Dataset.Reconciliation[0]
            $row.Rows | Should -Be 2
            $row.RawTotal | Should -Be 1000
            $row.ExcludedOutsideRange | Should -Be 900
            $row.IncludedHeadline + $row.ExcludedOutsideRange | Should -Be $row.RawTotal
            $row.Difference | Should -Be 0
        }

        It 'Includes both range endpoints but excludes earlier and later dates' {
            $root = New-TestRoot
            $rows = @(
                New-SyntheticRow -Date '10/04/2026' -Cost '3'
                New-SyntheticRow -Date '10/05/2026' -Cost '10'
                New-SyntheticRow -Date '10/10/2026' -Cost '20'
                New-SyntheticRow -Date '10/11/2026' -Cost '-40' -ChargeType 'Refund'
            )
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-10' -RangeStart ([datetime]'2026-10-05') -RangeEnd ([datetime]'2026-10-10') -Parts @(, $rows)
            $result = (Invoke-TestHistory -Settings (New-TestSettings -Root $root)).Results[0]
            $result.MonthStats[0].Total | Should -Be 30
            $result.OutsideRows | Should -Be 2
            $result.OutsideTotal | Should -Be -37
        }

        It 'Treats midnight on the next month''s first day as an exclusive end' {
            $root = New-TestRoot
            $rows = @(New-SyntheticRow -Date '10/31/2026' -Cost '10'; New-SyntheticRow -Date '11/01/2026' -Cost '20')
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-10' -RangeEnd ([datetime]'2026-11-01') -Parts @(, $rows)
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            $history.Results[0].Months -join ',' | Should -Be '2026-10'
            $history.Selection.Selection[0].Coverage | Should -Be 'Full'
            (Get-TestMonth $history '2026-10').Headline | Should -Be 10
            $history.Results[0].OutsideTotal | Should -Be 20
        }

        It 'Keeps manifest coverage through the 20th when <Case>' -ForEach @(
            @{ Case = 'only the first day has a charge'; Empty = $false; Expected = 100 }
            @{ Case = 'a verified partition has no charges'; Empty = $true; Expected = 0 }
        ) {
            $root = New-TestRoot
            $rows = @(if (-not $Empty) { New-SyntheticRow -Date '11/01/2026' -Cost '100' })
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-11' -RangeEnd ([datetime]'2026-11-20') -Submitted ([datetime]'2026-11-21') -Parts @(, $rows)
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            $month = Get-TestMonth $history '2026-11'
            $month.Status | Should -Be 'Provisional'
            $month.DataThrough | Should -Be ([datetime]'2026-11-20')
            $month.Headline | Should -Be $Expected
        }

        It 'Does not claim future coverage from a full-month range submitted mid-month' {
            $root = New-TestRoot
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-11' -Submitted ([datetime]'2026-11-10') -Parts @(, @(New-SyntheticRow -Date '11/01/2026' -Cost '100'))
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            (Get-TestMonth $history '2026-11').DataThrough | Should -Be ([datetime]'2026-11-09')
        }

        It 'Blocks an aggregate partial month when selected scopes end on different days' {
            $root = New-TestRoot
            foreach ($entry in @(@{ Sub = 'A'; End = '2026-11-10' }, @{ Sub = 'B'; End = '2026-11-20' })) {
                $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-11' -ExportName $entry.Sub -Scope "/subscriptions/$($script:SyntheticSubscriptions[$entry.Sub])" -RangeEnd ([datetime]$entry.End) -Submitted ([datetime]'2026-11-21') -Parts @(, @(New-SyntheticRow -Date '11/01/2026' -Subscription $entry.Sub -Cost '100'))
            }
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root -Subscriptions @('A', 'B'))
            (Get-TestMonth $history '2026-11').DataThrough | Should -Be ([datetime]'2026-11-10')
            (Get-TestMonth $history '2026-11').Status | Should -Be 'Incomplete'
            @($history.Dataset.Issues | Where-Object { $_.Code -eq 'RUN-COVERAGE' -and $_.Severity -eq 'Fail' }).Count | Should -Be 1
        }
    }

    Context 'Filters, scope, and reconciliation' {
        It 'Excludes Marketplace by default, reports it, and includes it when asked' {
            $root = New-TestRoot
            $rows = @(
                New-SyntheticRow -Date '10/01/2026' -Cost '100'
                New-SyntheticRow -Date '10/01/2026' -Cost '40' -PublisherType 'Marketplace' -PublisherName 'Synthetic Vendor'
            )
            $null = New-SyntheticExportRun -Root $root -Kind 'MCA' -Month '2026-10' -Parts @(, $rows)
            $excluded = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            (Get-TestMonth $excluded '2026-10').Headline | Should -Be 100
            (Get-TestMonth $excluded '2026-10').ExcludedMarketplace | Should -Be 40
            $settings = New-TestSettings -Root $root
            $settings.filters.includeMarketplace = $true
            (Get-TestMonth (Invoke-TestHistory -Settings $settings) '2026-10').Headline | Should -Be 140
        }

        It 'Asks for a decision on EA rows from a non-Microsoft publisher' {
            $root = New-TestRoot
            $rows = @(
                New-SyntheticRow -Date '10/01/2026' -Cost '100'
                New-SyntheticRow -Date '10/01/2026' -Cost '15' -PublisherName 'Synthetic Vendor'
            )
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-10' -Parts @(, $rows)
            $settings = New-TestSettings -Root $root
            $first = Invoke-TestHistory -Settings $settings
            $review = @($first.Dataset.Reviews | Where-Object Category -EQ 'Publisher')[0]
            $review.Decision | Should -Be 'Pending'
            (Get-TestMonth $first '2026-10').Headline | Should -Be 100
            $reviewed = Invoke-TestHistory -Settings $settings -Reviews (New-Review $review 'TreatAsMicrosoft')
            (Get-TestMonth $reviewed '2026-10').Headline | Should -Be 115
        }

        It 'Keeps a publisher decision when more rows arrive from the same publisher, and reopens it for a new one' {
            $root = New-TestRoot
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-10' -Submitted ([datetime]'2026-11-02') -Parts @(, @(
                    New-SyntheticRow -Date '10/01/2026' -Cost '100'
                    New-SyntheticRow -Date '10/01/2026' -Cost '15' -PublisherName 'Synthetic Vendor'))
            $settings = New-TestSettings -Root $root
            $review = @((Invoke-TestHistory -Settings $settings).Dataset.Reviews | Where-Object Category -EQ 'Publisher')[0]
            $review.Detail | Should -Match 'Synthetic Vendor'
            $reviews = New-Review $review 'TreatAsMicrosoft'

            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-10' -Submitted ([datetime]'2026-11-03') -Parts @(, @(
                    New-SyntheticRow -Date '10/01/2026' -Cost '100'
                    New-SyntheticRow -Date '10/01/2026' -Cost '15' -PublisherName 'Synthetic Vendor'
                    New-SyntheticRow -Date '10/09/2026' -Cost '20' -PublisherName 'synthetic vendor '))
            $more = Invoke-TestHistory -Settings $settings -Reviews $reviews
            @($more.Dataset.Reviews | Where-Object Category -EQ 'Publisher')[0].Decision | Should -Be 'TreatAsMicrosoft'
            (Get-TestMonth $more '2026-10').Headline | Should -Be 135

            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-10' -Submitted ([datetime]'2026-11-04') -Parts @(, @(
                    New-SyntheticRow -Date '10/01/2026' -Cost '100'
                    New-SyntheticRow -Date '10/01/2026' -Cost '15' -PublisherName 'Synthetic Vendor'
                    New-SyntheticRow -Date '10/12/2026' -Cost '5' -PublisherName 'Another Synthetic Vendor'))
            $changed = Invoke-TestHistory -Settings $settings -Reviews $reviews
            $reopened = @($changed.Dataset.Reviews | Where-Object Category -EQ 'Publisher')[0]
            $reopened.Decision | Should -Be 'Pending'
            $reopened.Stale | Should -BeTrue
            (Get-TestMonth $changed '2026-10').Headline | Should -Be 100
        }

        It 'Leaves the pre-credit headline unchanged when credits are present' {
            $root = New-TestRoot
            $base = @(New-SyntheticRow -Date '10/01/2026' -Cost '500')
            $null = New-SyntheticExportRun -Root $root -Kind 'FOCUS' -Month '2026-10' -Parts @(, ($base + (New-SyntheticRow -Date '10/02/2026' -Cost '-200' -ChargeType 'Credit')))
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            $october = Get-TestMonth $history '2026-10'
            $october.Headline | Should -Be 500
            $october.Credit | Should -Be -200
            @($history.Dataset.Reconciliation | Where-Object { $_.Difference -ne 0 }).Count | Should -Be 0
        }

        It 'Keeps refunds signed and flags positive refunds for review' {
            $root = New-TestRoot
            $rows = @(
                New-SyntheticRow -Date '10/01/2026' -Cost '300'
                New-SyntheticRow -Date '10/02/2026' -Cost '-20' -ChargeType 'Refund' -CommitmentId 'ri-a'
                New-SyntheticRow -Date '10/03/2026' -Cost '5' -ChargeType 'Refund' -CommitmentId 'ri-b'
            )
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-10' -Parts @(, $rows)
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root)
            (Get-TestMonth $history '2026-10').Purchase | Should -Be -15
            $refund = @($history.Dataset.Reviews | Where-Object Category -EQ 'Refund')[0]
            $refund.Required | Should -BeFalse
            $refund.Detail | Should -Match '1 refund row'
            $refund.Key | Should -BeLike "*:2026-10:$($history.Selection.Selection[0].RunKey)"
        }

        It 'Reports rows outside the run''s declared dates instead of dropping them silently' {
            $root = New-TestRoot
            $rows = @(New-SyntheticRow -Date '10/01/2026' -Cost '100'; New-SyntheticRow -Date '11/02/2026' -Cost '25.125')
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month '2026-10' -Parts @(, $rows)
            $settings = New-TestSettings -Root $root
            $history = Invoke-TestHistory -Settings $settings
            $history.Results[0].Status | Should -Be 'Complete'
            $history.Results[0].OutsideRows | Should -Be 1
            $history.Results[0].OutsideTotal | Should -Be 25.125
            (Get-TestMonth $history '2026-10').Headline | Should -Be 100
            @($history.Dataset.Issues | Where-Object { $_.Code -eq 'RUN-OUTSIDE' -and $_.Subject -eq '2026-10' }).Count | Should -Be 1
            @($history.Dataset.Reconciliation)[0].ExcludedOutsideRange | Should -Be 25.125
            $checked = InModuleScope FinOpsForecast -Parameters @{ Result = $history.Results[0]; Dataset = $history.Dataset; Settings = $settings; AsOf = $script:AsOf } {
                $cached = ConvertFrom-ForecastCacheRecord -Record ((ConvertTo-ForecastCacheRecord -Result $Result) | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
                $model = Invoke-ForecastModel -Dataset $Dataset -Settings $Settings -Reviews @{} -AsOf $AsOf
                [pscustomobject]@{
                    Cached = $cached.OutsideTotal
                    Source = @((Test-ForecastReadiness -Dataset $Dataset -Model $model -Settings $Settings -AsOf $AsOf).Checks | Where-Object Id -EQ 'SOURCE')[0]
                }
            }
            $checked.Cached | Should -BeOfType [decimal]
            $checked.Cached | Should -Be 25.125
            $checked.Source.Status | Should -Be 'Warn'
            $checked.Source.Detail | Should -Match 'outside the run'
        }

        It 'Limits subscription scope and reports out-of-scope and unattributed amounts' {
            $root = New-TestRoot
            $rows = @(
                New-SyntheticRow -Date '10/01/2026' -Cost '100' -Subscription 'A'
                New-SyntheticRow -Date '10/01/2026' -Cost '60' -Subscription 'B'
                New-SyntheticRow -Date '10/01/2026' -Cost '9' -Subscription '' -ChargeType 'Purchase' -CommitmentId 'sp-1'
            )
            $null = New-SyntheticExportRun -Root $root -Kind 'MCA' -Month '2026-10' -Scope $script:ProfileScope -Parts @(, $rows)
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $root -Subscriptions @('A'))
            $october = Get-TestMonth $history '2026-10'
            $october.Headline | Should -Be 100
            $october.ExcludedScope | Should -Be 60
            $october.ExcludedUnattributed | Should -Be 9
        }

        It 'Includes rows without a subscription for a billing profile scope' {
            $root = New-TestRoot
            $rows = @(
                New-SyntheticRow -Date '10/01/2026' -Cost '100' -Subscription 'A'
                New-SyntheticRow -Date '10/01/2026' -Cost '9' -Subscription '' -ChargeType 'Purchase' -CommitmentId 'sp-1'
                New-SyntheticRow -Date '10/01/2026' -Cost '70' -Subscription 'C' -BillingProfile 'BP-OTHER'
            )
            $null = New-SyntheticExportRun -Root $root -Kind 'MCA' -Month '2026-10' -Scope $script:ProfileScope -Parts @(, $rows)
            $settings = New-TestSettings -Root $root
            $settings.scope.kind = 'BillingProfile'; $settings.scope.billingProfileId = 'BP-SYNTH-01'
            $october = Get-TestMonth (Invoke-TestHistory -Settings $settings) '2026-10'
            $october.Headline | Should -Be 109
            $october.ExcludedScope | Should -Be 70
        }

        It 'Counts charges without a subscription once when two billing scopes carry them' {
            $root = New-TestRoot
            $rows = @(
                New-SyntheticRow -Date '10/01/2026' -Cost '1000' -Subscription 'A'
                New-SyntheticRow -Date '10/01/2026' -Cost '300' -Subscription '' -ChargeType 'Purchase' -CommitmentId 'sp-1'
            )
            $accountScope = ($script:ProfileScope -split '/billingProfiles/')[0]
            $null = New-SyntheticExportRun -Root $root -Kind 'MCA' -ExportName 'billing-account' -Scope $accountScope -Month '2026-10' -Parts @(, $rows)
            $null = New-SyntheticExportRun -Root $root -Kind 'MCA' -ExportName 'billing-profile' -Scope $script:ProfileScope -Month '2026-10' -Parts @(, $rows)
            $settings = New-TestSettings -Root $root
            $settings.scope.kind = 'BillingProfile'; $settings.scope.billingProfileId = 'BP-SYNTH-01'
            $history = Invoke-TestHistory -Settings $settings
            $october = Get-TestMonth $history '2026-10'
            $october.Headline | Should -Be 1300
            $october.ExcludedOverlap | Should -Be 1300
            @($history.Dataset.Reviews | Where-Object Category -EQ 'Overlap').Count | Should -Be 1
            @($history.Dataset.Reconciliation | Where-Object { $_.Difference -ne 0 }).Count | Should -Be 0
        }
    }

    Context 'Migration boundary and overlapping scopes' {
        BeforeAll {
            $script:BoundaryRoot = New-TestRoot
            $eaRows = @(New-SyntheticRow -Date '06/10/2026' -Cost '100'; New-SyntheticRow -Date '06/20/2026' -Cost '40')
            $mcaRows = @(New-SyntheticRow -Date '06/10/2026' -Cost '7'; New-SyntheticRow -Date '06/20/2026' -Cost '60')
            $null = New-SyntheticExportRun -Root $script:BoundaryRoot -Kind 'EA' -ExportName 'ea-actual' -Month '2026-06' -Parts @(, $eaRows)
            $null = New-SyntheticExportRun -Root $script:BoundaryRoot -Kind 'MCA' -ExportName 'mca-actual' -Scope $script:ProfileScope -Month '2026-06' -Parts @(, $mcaRows)
        }

        It 'Requires a boundary when EA and MCA data are both present' {
            $history = Invoke-TestHistory -Settings (New-TestSettings -Root $script:BoundaryRoot)
            @($history.Dataset.Issues | Where-Object Code -EQ 'BND-MISSING').Count | Should -Be 1
        }

        It 'Joins EA before the boundary and MCA on or after it, without overlap' {
            $settings = New-TestSettings -Root $script:BoundaryRoot
            $settings.migration.boundaryDate = '2026-06-15'
            $history = Invoke-TestHistory -Settings $settings
            $june = Get-TestMonth $history '2026-06'
            $june.Headline | Should -Be 160
            $june.ExcludedBoundary | Should -Be 47
            $june.Status | Should -Be 'Complete'
            @($history.Dataset.Issues | Where-Object Code -EQ 'BND-MISSING').Count | Should -Be 0
            @($history.Dataset.Reviews | Where-Object Category -EQ 'Boundary').Count | Should -Be 1
            @($history.Dataset.Reconciliation | Where-Object { $_.Difference -ne 0 }).Count | Should -Be 0
        }

        It 'Asks which scope to keep when two exports carry the same subscription and month' {
            $root = New-TestRoot
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -ExportName 'enrollment' -Month '2026-10' -Parts @(, @(New-SyntheticRow -Date '10/01/2026' -Cost '100'))
            $null = New-SyntheticExportRun -Root $root -Kind 'EA' -ExportName 'subscription' -Scope "/subscriptions/$($script:SyntheticSubscriptions.A)" -Month '2026-10' -Parts @(, @(New-SyntheticRow -Date '10/01/2026' -Cost '100'))
            $settings = New-TestSettings -Root $root
            $first = Invoke-TestHistory -Settings $settings
            $review = @($first.Dataset.Reviews | Where-Object Category -EQ 'Overlap')[0]
            $review.Decision | Should -Be 'Pending'
            (Get-TestMonth $first '2026-10').Headline | Should -Be 100
            $keep = @($review.Options | Where-Object { $_ -like '/subscriptions/*' })[0]
            $resolved = Invoke-TestHistory -Settings $settings -Reviews (New-Review $review $keep)
            (Get-TestMonth $resolved '2026-10').Headline | Should -Be 100
            (Get-TestMonth $resolved '2026-10').ExcludedOverlap | Should -Be 100
        }
    }

    Context 'Recurring purchases' {
        It 'Flags a recurring purchase that no scheduled item covers' {
            $root = New-TestRoot
            foreach ($month in '2026-08', '2026-09', '2026-10') {
                $date = "$($month.Substring(5, 2))/01/$($month.Substring(0, 4))"
                $rows = @(New-SyntheticRow -Date $date -Cost '100'; New-SyntheticRow -Date $date -Cost '30' -ChargeType 'Purchase' -CommitmentId 'ri-synth-monthly' -Frequency 'Recurring')
                $null = New-SyntheticExportRun -Root $root -Kind 'EA' -Month $month -Parts @(, $rows)
            }
            $settings = New-TestSettings -Root $root
            $history = Invoke-TestHistory -Settings $settings
            @($history.Dataset.Reviews | Where-Object Category -EQ 'RecurringPurchase').Count | Should -Be 1
            $settings.scheduledItems = @([pscustomobject]@{ id = 'ri-monthly'; type = 'Renewal'; description = 'Synthetic RI'; startMonth = '2026-11'; endMonth = ''; recurrence = 'Monthly'; amount = '30'; baselineTreatment = 'Additive'; replacedAmount = ''; commitmentId = 'ri-synth-monthly' })
            @((Invoke-TestHistory -Settings $settings).Dataset.Reviews | Where-Object Category -EQ 'RecurringPurchase').Count | Should -Be 0
        }
    }
}
