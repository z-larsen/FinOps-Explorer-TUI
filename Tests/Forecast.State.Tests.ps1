# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers create synthetic fixtures in TestDrive only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helpers are named for the collections they build.')]
param()
BeforeAll {
    . (Join-Path $PSScriptRoot 'Forecast.TestHelpers.ps1')
    $script:AsOf = [datetime]::SpecifyKind([datetime]'2026-11-05T12:00:00', [DateTimeKind]::Utc)

    function New-TestWorkspace {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        InModuleScope FinOpsForecast -Parameters @{ Base = $base } { Get-ForecastWorkspaceRoot -WorkspaceName 'synthetic' -WorkspacePath $Base }
    }
}

Describe 'Workspace state' {
    It 'Creates a private workspace and rejects unsafe names and paths' {
        $root = New-TestWorkspace
        Test-Path -LiteralPath $root -PathType Container | Should -BeTrue
        { InModuleScope FinOpsForecast { Get-ForecastWorkspaceRoot -WorkspaceName '../escape' -WorkspacePath $TestDrive } } | Should -Throw
        $repo = Join-Path $TestDrive 'repo'
        [void][IO.Directory]::CreateDirectory((Join-Path $repo '.git'))
        { InModuleScope FinOpsForecast -Parameters @{ Base = $repo } { Get-ForecastWorkspaceRoot -WorkspaceName 'inside' -WorkspacePath $Base } } | Should -Throw '*Git*'
    }

    It 'Keeps every write inside the workspace' {
        $root = New-TestWorkspace
        foreach ($path in '../outside.json', 'cache/../../x.json', 'a\b.json', '.hidden') {
            { InModuleScope FinOpsForecast -Parameters @{ Root = $root; Path = $path } { Write-ForecastStateFile -Root $Root -RelativePath $Path -Content '{}' } } | Should -Throw
        }
    }

    It 'Never overwrites a vintage' {
        $root = New-TestWorkspace
        InModuleScope FinOpsForecast -Parameters @{ Root = $root } {
            $null = Write-ForecastStateJson -Root $Root -RelativePath 'vintages/v1.json' -Value @{ id = 'one' } -CreateNew
            { Write-ForecastStateJson -Root $Root -RelativePath 'vintages/v1.json' -Value @{ id = 'two' } -CreateNew } | Should -Throw '*never overwritten*'
            (Read-ForecastStateJson -Root $Root -RelativePath 'vintages/v1.json').id | Should -Be 'one'
        }
    }

    It 'Stores decisions only for valid options and requires a reason for a manual baseline' {
        $root = New-TestWorkspace
        $item = [pscustomobject]@{ Key = 'baseline:x:2026-10'; Fingerprint = 'abc'; Options = @('LatestMonth', 'MedianLast3', 'Manual'); Title = 'Baseline' }
        InModuleScope FinOpsForecast -Parameters @{ Root = $root; Item = $item } {
            { Set-ForecastReviewDecision -Root $Root -Item $Item -Decision 'Retain' } | Should -Throw '*option*'
            { Set-ForecastReviewDecision -Root $Root -Item $Item -Decision 'Manual' -Value '100' } | Should -Throw '*reason*'
            Set-ForecastReviewDecision -Root $Root -Item $Item -Decision 'Manual' -Value '100.25' -Note 'Synthetic: excludes a one-time migration spike'
            $stored = (Get-ForecastStoredReviews -Root $Root)[$Item.Key]
            $stored.decision | Should -Be 'Manual'
            $stored.value | Should -Be '100.25'
        }
    }

    Context 'Refresh' {
        BeforeEach {
            $script:Exports = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            foreach ($month in '2026-08', '2026-09') {
                $null = New-SyntheticExportRun -Root $script:Exports -Kind 'EA' -Month $month -Parts @(, @(New-SyntheticMonthRows -Month $month -Total 300))
            }
            $script:Root = New-TestWorkspace
            $script:Settings = New-TestSettings -Root $script:Exports
            InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $script:Settings } { Save-ForecastStoredSettings -Root $Root -Settings $Settings }
        }

        It 'Reuses unchanged runs and reads only new or corrected runs' {
            InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $script:Settings; Exports = $script:Exports } {
                $first = Update-ForecastExportCache -Root $Root -Settings $Settings
                $first.Succeeded | Should -BeTrue
                $first.RunsRead | Should -Be 2
                $second = Update-ForecastExportCache -Root $Root -Settings $Settings
                $second.RunsRead | Should -Be 0
                $second.RunsReused | Should -Be 2
            }
            $null = New-SyntheticExportRun -Root $script:Exports -Kind 'EA' -Month '2026-09' -Submitted ([datetime]'2026-10-09') -Parts @(, @(New-SyntheticMonthRows -Month '2026-09' -Total 333))
            InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $script:Settings; AsOf = $script:AsOf } {
                $third = Update-ForecastExportCache -Root $Root -Settings $Settings
                $third.RunsRead | Should -Be 1
                $third.RunsReused | Should -Be 2
                $dataset = Get-ForecastDataset -Root $Root -Settings $Settings -Reviews @{}
                @($dataset.Months | Where-Object Month -EQ '2026-09')[0].RunRate | Should -Be 333
            }
        }

        It 'Keeps the previous data when a refresh fails' {
            InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $script:Settings } { $null = Update-ForecastExportCache -Root $Root -Settings $Settings }
            Rename-Item -LiteralPath $script:Exports -NewName 'moved-away'
            InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $script:Settings; AsOf = $script:AsOf } {
                $failed = Update-ForecastExportCache -Root $Root -Settings $Settings
                $failed.Succeeded | Should -BeFalse
                $state = Get-ForecastRefreshState -Root $Root
                $state.LastAttemptResult | Should -Be 'Failed'
                $state.LastSuccessUtc | Should -Not -BeNullOrEmpty
                $dataset = Get-ForecastDataset -Root $Root -Settings $Settings -Reviews @{}
                @($dataset.Months | Where-Object Month -EQ '2026-09')[0].RunRate | Should -Be 300
                $model = Invoke-ForecastModel -Dataset $dataset -Settings $Settings -Reviews @{} -AsOf $AsOf
                $readiness = Test-ForecastReadiness -Dataset $dataset -Model $model -Settings $Settings -RefreshState $state -AsOf $AsOf
                ($readiness.Checks | Where-Object Id -EQ 'FRESHNESS').Status | Should -Be 'Warn'
                $readiness.Labels | Should -Contain 'Stale data'
            }
        }

        It 'Keeps the previous cache when an existing partition becomes <Failure>' -ForEach @(
            @{ Failure = 'missing' }
            @{ Failure = 'invalid' }
        ) {
            InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $script:Settings } {
                (Update-ForecastExportCache -Root $Root -Settings $Settings).Succeeded | Should -BeTrue
            }
            $partition = Get-ChildItem -LiteralPath $script:Exports -Recurse -Filter 'part_0_0001.csv' | Where-Object FullName -Match '20260901-20260930' | Select-Object -First 1
            if ($Failure -eq 'missing') { Remove-Item -LiteralPath $partition.FullName }
            else {
                $text = [IO.File]::ReadAllText($partition.FullName)
                $text | Should -Match '"100"'
                [IO.File]::WriteAllText($partition.FullName, $text.Replace('"100"', '"bad"'))
                (Get-Item -LiteralPath $partition.FullName).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(1)
            }
            InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $script:Settings } {
                $refresh = Update-ForecastExportCache -Root $Root -Settings $Settings
                $refresh.Succeeded | Should -BeFalse
                $refresh.Error | Should -Match 'previous cache was retained'
                (Get-ForecastRefreshState -Root $Root).LastAttemptResult | Should -Be 'Failed'
                @((Get-ForecastCache -Root $Root).Results | Where-Object Status -NE 'Complete').Count | Should -Be 0
                $dataset = Get-ForecastDataset -Root $Root -Settings $Settings -Reviews @{}
                ($dataset.Months | Where-Object Month -EQ '2026-09').Headline | Should -Be 300
            }
        }

        It 'Detects an in-place correction with unchanged byte and row counts' {
            InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $script:Settings } {
                (Update-ForecastExportCache -Root $Root -Settings $Settings).Succeeded | Should -BeTrue
            }
            $partition = Get-ChildItem -LiteralPath $script:Exports -Recurse -Filter 'part_0_0001.csv' | Where-Object FullName -Match '20260901-20260930' | Select-Object -First 1
            $length = $partition.Length
            $text = [IO.File]::ReadAllText($partition.FullName)
            [IO.File]::WriteAllText($partition.FullName, $text.Replace('"100"', '"150"'))
            (Get-Item -LiteralPath $partition.FullName).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(1)
            (Get-Item -LiteralPath $partition.FullName).Length | Should -Be $length
            InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $script:Settings } {
                $refresh = Update-ForecastExportCache -Root $Root -Settings $Settings
                $refresh.Succeeded | Should -BeTrue
                $refresh.RunsRead | Should -Be 1
                $refresh.RunsReused | Should -Be 1
                $dataset = Get-ForecastDataset -Root $Root -Settings $Settings -Reviews @{}
                ($dataset.Months | Where-Object Month -EQ '2026-09').Headline | Should -Be 450
                (Update-ForecastExportCache -Root $Root -Settings $Settings).RunsReused | Should -Be 2
            }
        }

        It 'Re-ingests a corrected manifest date range even when its partitions are unchanged' {
            InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $script:Settings } {
                $null = Update-ForecastExportCache -Root $Root -Settings $Settings
            }
            $path = (Get-ChildItem -LiteralPath $script:Exports -Recurse -Filter 'manifest.json' | Where-Object FullName -Match '20260901-20260930' | Select-Object -First 1).FullName
            $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $manifest.runInfo.endDate = '2026-09-15T00:00:00'
            $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
            InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $script:Settings } {
                (Update-ForecastExportCache -Root $Root -Settings $Settings).RunsRead | Should -Be 1
                $dataset = Get-ForecastDataset -Root $Root -Settings $Settings -Reviews @{}
                $month = $dataset.Months | Where-Object Month -EQ '2026-09'
                $month.Headline | Should -Be 200
                $month.Status | Should -Be 'Provisional'
                $month.DataThrough | Should -Be ([datetime]'2026-09-15')
            }
        }

        It 'Keeps an older good run available when a newly discovered run is incomplete' {
            InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $script:Settings } {
                $null = Update-ForecastExportCache -Root $Root -Settings $Settings
            }
            $null = New-SyntheticExportRun -Root $script:Exports -Kind 'EA' -Month '2026-09' -Submitted ([datetime]'2026-10-10') -DeclareExtraPartitions 1 -Parts @(, @(New-SyntheticMonthRows -Month '2026-09' -Total 600))
            InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $script:Settings } {
                (Update-ForecastExportCache -Root $Root -Settings $Settings).Succeeded | Should -BeTrue
                $dataset = Get-ForecastDataset -Root $Root -Settings $Settings -Reviews @{}
                ($dataset.Months | Where-Object Month -EQ '2026-09').Headline | Should -Be 300
                @($dataset.Issues | Where-Object Code -EQ 'RUN-NEWERINCOMPLETE').Count | Should -Be 1
            }
        }

        It 'Does not reuse a run when the listing lacks partition modification times' {
            InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $script:Settings } {
                $blobs = Get-ForecastSourceBlobs -Source $Settings.sources[0]
                foreach ($blob in $blobs) { $blob.LastModified = $null }
                Mock Get-ForecastSourceBlobs { return , $blobs }
                (Update-ForecastExportCache -Root $Root -Settings $Settings).RunsRead | Should -Be 2
                $second = Update-ForecastExportCache -Root $Root -Settings $Settings
                $second.RunsReused | Should -Be 0
                $second.RunsRead | Should -Be 2
            }
        }

        It 'Requires a refresh when the source interpretation changes under the same ID' {
            InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $script:Settings } {
                $null = Update-ForecastExportCache -Root $Root -Settings $Settings
                $Settings.sources[0].agreement = 'EA'
                $dataset = Get-ForecastDataset -Root $Root -Settings $Settings -Reviews @{}
                @($dataset.Issues | Where-Object Code -EQ 'DATA-PROFILE').Count | Should -Be 1
                (Update-ForecastExportCache -Root $Root -Settings $Settings).RunsRead | Should -Be 2
            }
        }

        It 'Asks for a refresh when the workload tag key changes, then re-reads every run' {
            InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $script:Settings; AsOf = $script:AsOf } {
                $null = Update-ForecastExportCache -Root $Root -Settings $Settings
                $Settings.workloads.tagKey = 'application'
                $dataset = Get-ForecastDataset -Root $Root -Settings $Settings -Reviews @{}
                @($dataset.Issues | Where-Object Code -EQ 'DATA-PROFILE').Count | Should -Be 1
                (Update-ForecastExportCache -Root $Root -Settings $Settings).RunsRead | Should -Be 2
            }
        }
    }
}
