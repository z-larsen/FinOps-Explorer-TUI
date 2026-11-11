# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers create synthetic fixtures in TestDrive only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helpers are named for the collections they build.')]
param()
###########################################################################
# FORECAST.COSTDETAILS.TESTS.PS1
# LIVE COST DETAILS SOURCE, AGAINST A SYNTHETIC COST MANAGEMENT API
###########################################################################
# Explorer's REST helper and the report download are mocked, so nothing
# reaches Azure. The fake API follows the documented contract: a POST
# returns 202 with Location and Retry-After, the status link returns 202
# once and then the manifest, and each report file is a SAS-style link.
# Every link carries SECRETSIG so tests can prove links never persist.
###########################################################################
BeforeAll {
    . (Join-Path $PSScriptRoot 'Forecast.TestHelpers.ps1')
    $script:Now = [datetime]::SpecifyKind([datetime]'2026-11-10T15:00:00', [DateTimeKind]::Utc)
    $script:SubScope = "/subscriptions/$($script:SyntheticSubscriptions.A)"

    function New-TestWorkspace {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        InModuleScope FinOpsForecast -Parameters @{ Base = $base } { Get-ForecastWorkspaceRoot -WorkspaceName 'synthetic' -WorkspacePath $Base }
    }

    function New-CostDetailsSource {
        param([string]$Id = 'src-cd', [string]$Scope = $script:SubScope, $ChunkDays = 7, [string]$From = '', [string]$To = '', [string]$Agreement = 'Auto')
        [pscustomobject]@{ id = $Id; kind = 'CostDetails'; label = "Synthetic $Id"; scope = $Scope; chunkDays = $ChunkDays; fromMonth = $From; toMonth = $To; storageResourceId = ''; container = ''; prefix = ''; path = ''; agreement = $Agreement }
    }

    function New-CostDetailsSettings {
        param([object[]]$Sources, [string]$Boundary = '')
        $settings = New-TestSettings -Subscriptions @('A')
        $settings.sources = @($Sources)
        $settings.migration.boundaryDate = $Boundary
        return $settings
    }

    function Reset-CostDetailsApi {
        $script:Api = @{
            Next = 0; Operations = @{}; Files = @{}; Posts = [Collections.Generic.List[object]]::new(); Gets = [Collections.Generic.List[string]]::new()
            Waits = [Collections.Generic.List[int]]::new(); DailyCost = '10'; DailyCostByMonth = @{}; Kinds = @{}; PostStatus = @{}; GetStatus = @{}
            NoData = [Collections.Generic.HashSet[string]]::new(); Extra = @{}; Location = $null; Manifest = $null
        }
        InModuleScope FinOpsForecast { $script:ForecastCostDetailsThrottledUntil = $null }
    }

    function Get-CostDetailsCsvBytes {
        param([string]$Kind, [datetime]$Start, [datetime]$End, [string]$Key)
        $month = $Start.ToString('yyyy-MM')
        $daily = if ($script:Api.DailyCostByMonth.ContainsKey($month)) { $script:Api.DailyCostByMonth[$month] } else { $script:Api.DailyCost }
        $rows = [Collections.Generic.List[object]]::new()
        for ($day = $Start; $day -le $End; $day = $day.AddDays(1)) { $rows.Add((New-SyntheticRow -Date $day.ToString('MM/dd/yyyy') -Cost $daily -Workload 'app-alpha')) }
        if ($script:Api.Extra.ContainsKey($Key)) { foreach ($row in @($script:Api.Extra[$Key])) { $rows.Add($row) } }
        return , [Text.Encoding]::UTF8.GetBytes((ConvertTo-SyntheticCsv -Kind $Kind -Rows $rows.ToArray()))
    }

    function Invoke-FakeCostDetailsApi {
        param([string]$Path, [string]$Method, [string]$Payload)
        if ($Method -eq 'POST') {
            $script:Api.Posts.Add([pscustomobject]@{ Path = $Path; Payload = $Payload })
            $body = $Payload | ConvertFrom-Json
            $start = [datetime]::SpecifyKind([datetime]$body.timePeriod.start, [DateTimeKind]::Utc)
            $end = [datetime]::SpecifyKind([datetime]$body.timePeriod.end, [DateTimeKind]::Utc)
            $key = $start.ToString('yyyyMMdd')
            if ($script:Api.PostStatus.ContainsKey($key)) {
                return [pscustomobject]@{ StatusCode = $script:Api.PostStatus[$key]; Content = '{"error":{"code":"SyntheticError","message":"Synthetic request failure"}}'; Headers = @{ 'Retry-After' = @('600') } }
            }
            $scope = $Path.Substring(0, $Path.IndexOf('/providers/Microsoft.CostManagement/'))
            $id = '{0:D8}-0000-0000-0000-000000000000' -f $script:Api.Next++
            $script:Api.Operations[$id] = @{ Scope = $scope; Start = $start; End = $end; Key = $key; Polled = 0 }
            $location = if ($script:Api.Location) { $script:Api.Location } else { "https://management.azure.com$scope/providers/Microsoft.CostManagement/costDetailsOperationResults/$id`?api-version=2025-03-01" }
            return [pscustomobject]@{ StatusCode = 202; Content = ''; Headers = @{ Location = @($location); 'Retry-After' = @('7') } }
        }
        $script:Api.Gets.Add($Path)
        $id = ($Path -split '\?')[0] -replace '^.*/', ''
        $op = $script:Api.Operations[$id]
        if ($script:Api.GetStatus.ContainsKey($op.Key)) {
            return [pscustomobject]@{ StatusCode = $script:Api.GetStatus[$op.Key]; Content = '{"error":{"code":"SyntheticError","message":"Synthetic status failure"}}'; Headers = @{} }
        }
        $op.Polled++
        if ($op.Polled -eq 1) { return [pscustomobject]@{ StatusCode = 202; Content = ''; Headers = @{ 'Retry-After' = @('9') } } }
        if ($script:Api.NoData.Contains($op.Key)) { return [pscustomobject]@{ StatusCode = 200; Content = '{"status":"NoDataFound"}'; Headers = @{} } }
        $kind = if ($script:Api.Kinds.ContainsKey($op.Scope.ToLowerInvariant())) { $script:Api.Kinds[$op.Scope.ToLowerInvariant()] } else { 'MCA' }
        $bytes = Get-CostDetailsCsvBytes -Kind $kind -Start $op.Start -End $op.End -Key $op.Key
        $link = "https://ccmreportstoragewestus.blob.core.windows.net/armreports/$id/part0.csv?sv=2020-05-31&sr=b&sig=SECRETSIG$id"
        $script:Api.Files[$link] = $bytes
        $manifest = [ordered]@{
            manifestVersion = '2025-03-01'; dataFormat = 'Csv'; blobCount = 1; byteCount = $bytes.Length; compressData = $false
            requestContext = [ordered]@{ requestScope = $op.Scope.TrimStart('/'); requestBody = [ordered]@{ metric = 'ActualCost'; timePeriod = [ordered]@{ start = $op.Start.ToString('yyyy-MM-dd'); end = $op.End.ToString('yyyy-MM-dd') } } }
            blobs = @([ordered]@{ blobLink = $link; byteCount = $bytes.Length })
        }
        if ($script:Api.Manifest) { & $script:Api.Manifest $manifest }
        $content = [ordered]@{ id = "$($op.Scope)/providers/Microsoft.CostManagement/costDetailsOperationResults/$id"; name = $id; status = 'Completed'; manifest = $manifest; validTill = [datetime]::UtcNow.AddHours(1).ToString('o') } | ConvertTo-Json -Depth 10
        return [pscustomobject]@{ StatusCode = 200; Content = $content; Headers = @{} }
    }

    function Register-CostDetailsMocks {
        Mock Get-FinOpsArmEndpoint -ModuleName FinOpsForecast { 'https://management.azure.com' }
        Mock Get-AzContext -ModuleName FinOpsForecast { $null }
        Mock Wait-ForecastCostDetails -ModuleName FinOpsForecast { $script:Api.Waits.Add($Seconds) }
        Mock Invoke-AzRestMethodWithRetry -ModuleName FinOpsForecast { Invoke-FakeCostDetailsApi -Path $Path -Method $Method -Payload $Payload }
        Mock Get-ForecastCostDetailsFileBytes -ModuleName FinOpsForecast { , $script:Api.Files[$Uri] }
    }

    function Get-WorkspaceText {
        param([string]$Root)
        (Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
    }
}

Describe 'Cost Details planning' {
    It 'Requests whole reachable months, then the current month through yesterday' {
        $source = New-CostDetailsSource
        InModuleScope FinOpsForecast -Parameters @{ Source = $source; Now = $script:Now } {
            $runs = Get-ForecastCostDetailsRuns -Source $Source -Now $Now
            @($runs.Months) | Should -Be @('2025-11', '2025-12', '2026-01', '2026-02', '2026-03', '2026-04', '2026-05', '2026-06', '2026-07', '2026-08', '2026-09', '2026-10', '2026-11')
            $runs[-1].End.ToString('yyyy-MM-dd') | Should -Be '2026-11-09'
            @($runs | Where-Object { $_.Months -eq '2026-07' })[0].Parts.Name | Should -Be @(
                'costdetails/2026-07/20260701-20260707.csv', 'costdetails/2026-07/20260708-20260714.csv', 'costdetails/2026-07/20260715-20260721.csv',
                'costdetails/2026-07/20260722-20260728.csv', 'costdetails/2026-07/20260729-20260731.csv')
            @($runs | ForEach-Object { $_.Dataset } | Sort-Object -Unique) | Should -Be 'ActualCost'
            @($runs | Where-Object { -not $_.HasManifest }).Count | Should -Be 0
        }
    }

    It 'Narrows to fromMonth and toMonth, honors chunkDays, and skips a month with no finished day' {
        InModuleScope FinOpsForecast -Parameters @{ Source = (New-CostDetailsSource -From '2026-07' -To '2026-09' -ChunkDays 1) } {
            $runs = Get-ForecastCostDetailsRuns -Source $Source -Now ([datetime]'2026-11-10')
            @($runs.Months) | Should -Be @('2026-07', '2026-08', '2026-09')
            @($runs[2].Parts).Count | Should -Be 30
            $firstDay = Get-ForecastCostDetailsRuns -Source (New-Object psobject -Property @{ id = 'x'; scope = $Source.scope; chunkDays = 31 }) -Now ([datetime]'2026-11-01')
            $firstDay[-1].Months | Should -Be '2026-10'
            @($firstDay[-1].Parts).Count | Should -Be 1
        }
    }

    It 'Keeps month keys stable so a new read replaces the cached month' {
        $source = New-CostDetailsSource
        InModuleScope FinOpsForecast -Parameters @{ Source = $source; Now = $script:Now } {
            $first = Get-ForecastCostDetailsRuns -Source $Source -Now $Now
            $later = Get-ForecastCostDetailsRuns -Source $Source -Now $Now.AddHours(6)
            $first[0].RunKey | Should -Be $later[0].RunKey
            $first[0].RunId | Should -Not -Be $later[0].RunId
        }
    }
}

Describe 'Cost Details settings' {
    It 'Accepts <Scope>' -ForEach @(
        @{ Scope = '/subscriptions/11111111-1111-1111-1111-111111111111' }
        @{ Scope = '/providers/Microsoft.Billing/billingAccounts/1234567' }
        @{ Scope = '/providers/Microsoft.Billing/billingAccounts/1234567/departments/42' }
        @{ Scope = '/providers/Microsoft.Billing/billingAccounts/1234567/enrollmentAccounts/77' }
        @{ Scope = 'providers/Microsoft.Billing/billingAccounts/aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-0000-0000-0000-000000000000_2019-05-31/billingProfiles/BP-SYNTH-01/' }
        @{ Scope = '/providers/Microsoft.Billing/billingAccounts/aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-0000-0000-0000-000000000000_2019-05-31/billingProfiles/BP-SYNTH-01/invoiceSections/IS-SYNTH-01' }
    ) {
        InModuleScope FinOpsForecast -Parameters @{ Source = (New-CostDetailsSource -Scope $Scope) } { @(Test-ForecastSourceDefinition -Source $Source) | Should -BeNullOrEmpty }
    }

    It 'Rejects <Case>' -ForEach @(
        @{ Case = 'a management group'; Source = @{ Scope = '/providers/Microsoft.Management/managementGroups/mg-synth' } }
        @{ Case = 'a resource group'; Source = @{ Scope = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-synth' } }
        @{ Case = 'path traversal'; Source = @{ Scope = '/providers/Microsoft.Billing/billingAccounts/../subscriptions' } }
        @{ Case = 'a query string'; Source = @{ Scope = '/subscriptions/11111111-1111-1111-1111-111111111111?api-version=1' } }
        @{ Case = 'an empty scope'; Source = @{ Scope = '' } }
        @{ Case = 'zero days per report'; Source = @{ ChunkDays = 0 } }
        @{ Case = 'too many days per report'; Source = @{ ChunkDays = 32 } }
        @{ Case = 'non-numeric days'; Source = @{ ChunkDays = 'week' } }
        @{ Case = 'an invalid month'; Source = @{ From = '2026-13' } }
        @{ Case = 'months out of order'; Source = @{ From = '2026-09'; To = '2026-07' } }
        @{ Case = 'the FOCUS schema'; Source = @{ Agreement = 'FOCUS' } }
    ) {
        $parameters = $Source
        InModuleScope FinOpsForecast -Parameters @{ Source = (New-CostDetailsSource @parameters) } { @(Test-ForecastSourceDefinition -Source $Source).Count | Should -BeGreaterThan 0 }
    }

    It 'Adds the scope to the ingest profile only for Cost Details sources' {
        $settings = New-CostDetailsSettings -Sources @((New-CostDetailsSource), [pscustomobject]@{ id = 'src-local'; kind = 'LocalFolder'; label = 'x'; path = 'C:\x'; prefix = ''; storageResourceId = ''; container = ''; agreement = 'Auto' })
        InModuleScope FinOpsForecast -Parameters @{ Settings = $settings } {
            $profileSources = (Get-ForecastIngestProfile -Settings $Settings).Values.sources
            ($profileSources | Where-Object { $_.id -eq 'src-cd' }).scope | Should -Be $Settings.sources[0].scope.ToLowerInvariant()
            ($profileSources | Where-Object { $_.id -eq 'src-local' }).Contains('scope') | Should -BeFalse
        }
    }
}

Describe 'Cost Details requests' {
    BeforeEach {
        Reset-CostDetailsApi
        Register-CostDetailsMocks
    }

    It 'Posts one ActualCost request per chunk and follows only its status link' {
        $source = New-CostDetailsSource
        $bytes = InModuleScope FinOpsForecast -Parameters @{ Source = $source } { , (Read-ForecastCostDetailsPartition -Source $Source -Name 'costdetails/2026-07/20260708-20260714.csv') }
        $script:Api.Posts.Count | Should -Be 1
        $script:Api.Posts[0].Path | Should -BeExactly "$script:SubScope/providers/Microsoft.CostManagement/generateCostDetailsReport?api-version=2025-03-01"
        $script:Api.Posts[0].Payload | Should -BeExactly '{"metric":"ActualCost","timePeriod":{"start":"2026-07-08","end":"2026-07-14"}}'
        @($script:Api.Gets | Sort-Object -Unique) | Should -Be @("$script:SubScope/providers/Microsoft.CostManagement/costDetailsOperationResults/00000000-0000-0000-0000-000000000000?api-version=2025-03-01")
        @($script:Api.Waits) | Should -Be @(7, 9)
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        ([regex]::Matches($text, '07/(0[89]|1[0-4])/2026')).Count | Should -Be 7
    }

    It 'Doesn''t follow a status link that <Case>' -ForEach @(
        @{ Case = 'points at another host'; Location = 'https://management.example.com/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.CostManagement/costDetailsOperationResults/abc?api-version=2025-03-01'; Expected = '*outside*' }
        @{ Case = 'uses HTTP'; Location = 'http://management.azure.com/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.CostManagement/costDetailsOperationResults/abc?api-version=2025-03-01'; Expected = '*outside*' }
        @{ Case = 'is for another scope'; Location = 'https://management.azure.com/subscriptions/22222222-2222-2222-2222-222222222222/providers/Microsoft.CostManagement/costDetailsOperationResults/abc?api-version=2025-03-01'; Expected = '*different operation or scope*' }
        @{ Case = 'is another operation'; Location = 'https://management.azure.com/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Authorization/roleAssignments/abc?api-version=2022-04-01'; Expected = '*different operation or scope*' }
        @{ Case = 'is missing'; Location = ' '; Expected = '*usable status link*' }
    ) {
        $script:Api.Location = $Location
        { InModuleScope FinOpsForecast -Parameters @{ Source = (New-CostDetailsSource) } { Read-ForecastCostDetailsPartition -Source $Source -Name 'costdetails/2026-07/20260701-20260707.csv' } } | Should -Throw $Expected
        $script:Api.Gets.Count | Should -Be 0
    }

    It 'Rejects a report whose <Case>' -ForEach @(
        @{ Case = 'scope differs'; Change = { param($m) $m.requestContext.requestScope = 'subscriptions/22222222-2222-2222-2222-222222222222' }; Expected = '*different scope*' }
        @{ Case = 'dates differ'; Change = { param($m) $m.requestContext.requestBody.timePeriod.end = '2026-07-31' }; Expected = '*different dates*' }
        @{ Case = 'metric is amortized'; Change = { param($m) $m.requestContext.requestBody.metric = 'AmortizedCost' }; Expected = '*not ActualCost*' }
        @{ Case = 'data is compressed'; Change = { param($m) $m.compressData = $true }; Expected = '*compressed*' }
        @{ Case = 'file count differs'; Change = { param($m) $m.blobCount = 2 }; Expected = '*declares 2*' }
        @{ Case = 'byte total differs'; Change = { param($m) $m.byteCount = 1 }; Expected = '*manifest declares 1*' }
        @{ Case = 'request context is missing'; Change = { param($m) $m.Remove('requestContext') }; Expected = '*didn''t say which*' }
        @{ Case = 'metric is missing'; Change = { param($m) $m.requestContext.requestBody.Remove('metric') }; Expected = '*unstated metric*' }
        @{ Case = 'dates are missing'; Change = { param($m) $m.requestContext.requestBody.Remove('timePeriod') }; Expected = '*different dates, or didn''t say which*' }
    ) {
        $script:Api.Manifest = $Change
        { InModuleScope FinOpsForecast -Parameters @{ Source = (New-CostDetailsSource) } { Read-ForecastCostDetailsPartition -Source $Source -Name 'costdetails/2026-07/20260701-20260707.csv' } } | Should -Throw $Expected
    }

    It 'Reads NoDataFound as an empty partition' {
        [void]$script:Api.NoData.Add('20260701')
        $bytes = InModuleScope FinOpsForecast -Parameters @{ Source = (New-CostDetailsSource) } { , (Read-ForecastCostDetailsPartition -Source $Source -Name 'costdetails/2026-07/20260701-20260707.csv') }
        $bytes.Length | Should -Be 0
    }

    It 'Explains an access failure without echoing links' {
        $script:Api.PostStatus['20260701'] = 403
        $failure = { InModuleScope FinOpsForecast -Parameters @{ Source = (New-CostDetailsSource) } { Read-ForecastCostDetailsPartition -Source $Source -Name 'costdetails/2026-07/20260701-20260707.csv' } } | Should -Throw -PassThru
        $failure.Exception.Message | Should -BeLike '*HTTP 403*Cost Management read access*'
    }

    It 'Stops requesting while Cost Management is throttling' {
        $script:Api.PostStatus['20260701'] = 429
        { InModuleScope FinOpsForecast -Parameters @{ Source = (New-CostDetailsSource) } { Read-ForecastCostDetailsPartition -Source $Source -Name 'costdetails/2026-07/20260701-20260707.csv' } } | Should -Throw '*HTTP 429*'
        { InModuleScope FinOpsForecast -Parameters @{ Source = (New-CostDetailsSource) } { Read-ForecastCostDetailsPartition -Source $Source -Name 'costdetails/2026-07/20260708-20260714.csv' } } | Should -Throw '*throttling Cost Details requests until*'
        $script:Api.Posts.Count | Should -Be 1
    }

    It 'Refuses a partition name that isn''t one chunk of one month' -ForEach @(
        @{ Name = 'costdetails/2026-07/20260725-20260803.csv' }
        @{ Name = 'costdetails/2026-07/20260707-20260701.csv' }
        @{ Name = 'exports/x/part_0_0001.csv' }
    ) {
        { InModuleScope FinOpsForecast -Parameters @{ Source = (New-CostDetailsSource); Name = $Name } { Read-ForecastCostDetailsPartition -Source $Source -Name $Name } } | Should -Throw
        $script:Api.Posts.Count | Should -Be 0
    }
}

Describe 'Cost Details downloads' {
    It 'Downloads exactly the declared bytes without credentials or redirects' {
        # A loopback listener stands in for blob storage; only the link check is bypassed.
        $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
        $listener = [Net.HttpListener]::new()
        $listener.Prefixes.Add("http://localhost:$port/")
        $listener.Start()
        $seen = [hashtable]::Synchronized(@{ Paths = [Collections.ArrayList]::Synchronized([Collections.ArrayList]::new()); Authorization = 0 })
        $server = [powershell]::Create().AddScript({
                param($Listener, $Seen)
                while ($Listener.IsListening) {
                    try { $context = $Listener.GetContext() } catch { break }
                    [void]$Seen.Paths.Add($context.Request.Url.AbsolutePath)
                    if ($context.Request.Headers['Authorization']) { $Seen.Authorization++ }
                    $response = $context.Response
                    $body = [Text.Encoding]::ASCII.GetBytes("a,b`n1,2`n")
                    switch ($context.Request.Url.AbsolutePath) {
                        '/ok' { $response.ContentLength64 = $body.Length; $response.OutputStream.Write($body, 0, $body.Length) }
                        '/chunked' { $response.SendChunked = $true; $response.OutputStream.Write($body, 0, $body.Length) }
                        '/redirect' { $response.StatusCode = 302; $response.RedirectLocation = '/followed' }
                        '/stall' {
                            $response.ContentLength64 = $body.Length
                            try { $response.OutputStream.Write($body, 0, 3); $response.OutputStream.Flush(); Start-Sleep -Seconds 3; $response.OutputStream.Write($body, 3, $body.Length - 3) } catch { $null = $_ }
                        }
                        default { $response.StatusCode = 403 }
                    }
                    try { $response.Close() } catch { $null = $_ }
                }
            }).AddArgument($listener).AddArgument($seen)
        $handle = $server.BeginInvoke()
        try {
            InModuleScope FinOpsForecast -Parameters @{ Base = "http://localhost:$port" } {
                Mock Test-ForecastCostDetailsFileUri { [uri]$Uri }
                $bytes = Get-ForecastCostDetailsFileBytes -Uri "$Base/ok?sig=x" -ExpectedBytes 8
                [Text.Encoding]::ASCII.GetString($bytes) | Should -BeExactly "a,b`n1,2`n"
                { Get-ForecastCostDetailsFileBytes -Uri "$Base/ok?sig=x" -ExpectedBytes 9 } | Should -Throw '*8 bytes; the report declares 9*'
                { Get-ForecastCostDetailsFileBytes -Uri "$Base/chunked?sig=x" -ExpectedBytes 5 } | Should -Throw '*size doesn''t match*'
                { Get-ForecastCostDetailsFileBytes -Uri "$Base/redirect?sig=x" -ExpectedBytes 8 } | Should -Throw '*HTTP 302*'
                $denied = { Get-ForecastCostDetailsFileBytes -Uri "$Base/denied?sig=SECRETSIG" -ExpectedBytes 8 } | Should -Throw '*HTTP 403*' -PassThru
                $denied.Exception.Message | Should -Not -Match 'SECRETSIG'
                $idle = $script:ForecastCostDetailsIdleSeconds
                $script:ForecastCostDetailsIdleSeconds = 1
                try { { Get-ForecastCostDetailsFileBytes -Uri "$Base/stall?sig=x" -ExpectedBytes 8 } | Should -Throw '*network error*' }
                finally { $script:ForecastCostDetailsIdleSeconds = $idle }
            }
            $seen.Paths | Should -Not -Contain '/followed'
            $seen.Authorization | Should -Be 0
        }
        finally {
            $listener.Stop()
            $listener.Close()
            [void]$handle.AsyncWaitHandle.WaitOne(5000)
            $server.Dispose()
        }
    }

    It 'Accepts an HTTPS blob link with a SAS signature' {
        InModuleScope FinOpsForecast {
            Mock Get-AzContext { $null }
            (Test-ForecastCostDetailsFileUri -Uri 'https://ccmreportstorageeastus.blob.core.windows.net/armreports/1/a.csv?sv=2020-05-31&sr=b&sig=abc').Host | Should -Be 'ccmreportstorageeastus.blob.core.windows.net'
        }
    }

    It 'Rejects a report link that <Case>, without echoing it' -ForEach @(
        @{ Case = 'uses HTTP'; Uri = 'http://ccmreportstorageeastus.blob.core.windows.net/a.csv?sig=SECRETSIG' }
        @{ Case = 'is on another host'; Uri = 'https://attacker.example.com/a.csv?sig=SECRETSIG' }
        @{ Case = 'only looks like blob storage'; Uri = 'https://ccm.blob.core.windows.net.example.com/a.csv?sig=SECRETSIG' }
        @{ Case = 'carries credentials'; Uri = 'https://user:pass@ccmreportstorageeastus.blob.core.windows.net/a.csv?sig=SECRETSIG' }
        @{ Case = 'uses another port'; Uri = 'https://ccmreportstorageeastus.blob.core.windows.net:8443/a.csv?sig=SECRETSIG' }
        @{ Case = 'has no SAS signature'; Uri = 'https://ccmreportstorageeastus.blob.core.windows.net/a.csv?sv=2020-05-31&SECRETSIG' }
        @{ Case = 'isn''t a URL'; Uri = 'not a url SECRETSIG' }
    ) {
        $failure = { InModuleScope FinOpsForecast -Parameters @{ Uri = $Uri } { Mock Get-AzContext { $null }; Test-ForecastCostDetailsFileUri -Uri $Uri } } | Should -Throw -PassThru
        $failure.Exception.Message | Should -Not -Match 'SECRETSIG'
    }

    It 'Joins a multi-file report, keeping one header' {
        InModuleScope FinOpsForecast {
            $first = [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("a,b`r`n1,2"))
            $second = [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("a,b`r`n3,4`r`n"))
            [Text.Encoding]::UTF8.GetString((Join-ForecastCostDetailsFiles -Files @($first, $second))) | Should -BeExactly "a,b`r`n1,2`r`n3,4`r`n"
            { Join-ForecastCostDetailsFiles -Files @([Text.Encoding]::UTF8.GetBytes("a,b`n1,2`n"), [Text.Encoding]::UTF8.GetBytes("a,c`n3,4`n")) } | Should -Throw '*different columns*'
        }
    }
}

Describe 'Cost Details refresh' {
    BeforeEach {
        Reset-CostDetailsApi
        Register-CostDetailsMocks
        $script:Root = New-TestWorkspace
    }

    It 'Reads every month once, reuses closed months, and re-reads the open month after four hours' {
        $settings = New-CostDetailsSettings -Sources @(New-CostDetailsSource)
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $settings; Now = $script:Now } {
            $first = Update-ForecastExportCache -Root $Root -Settings $Settings -Now $Now
            $first.Succeeded | Should -BeTrue
            $first.RunsRead | Should -Be 13
            $first.RunsIncomplete | Should -Be 0
            $dataset = Get-ForecastDataset -Root $Root -Settings $Settings -Reviews @{}
            @($dataset.Months | Where-Object Month -EQ '2026-07')[0].RunRate | Should -Be 310
            @($dataset.Months | Where-Object Month -EQ '2026-02')[0].RunRate | Should -Be 280
            @($dataset.Runs | Where-Object { $_.Month -eq '2026-10' })[0].Final | Should -BeTrue
            @($dataset.Reconciliation | Where-Object { Test-ForecastMaterialDifference $_.Difference }).Count | Should -Be 0

            $again = Update-ForecastExportCache -Root $Root -Settings $Settings -Now $Now.AddHours(1)
            $again.RunsRead | Should -Be 0
            $again.RunsReused | Should -Be 13

            $later = Update-ForecastExportCache -Root $Root -Settings $Settings -Now $Now.AddHours(5)
            $later.RunsRead | Should -Be 1
            $later.RunsReused | Should -Be 12
        }
        # 59 weekly chunks for the 12 closed months and 2 for November, then November's 2 again.
        $script:Api.Posts.Count | Should -Be (61 + 2)
    }

    It 'Keeps a final month the API can no longer reach while the forecast window still needs it' {
        $settings = New-CostDetailsSettings -Sources @(New-CostDetailsSource)
        $october = [datetime]::SpecifyKind([datetime]'2026-10-31T12:00:00', [DateTimeKind]::Utc)
        $november = [datetime]::SpecifyKind([datetime]'2026-11-02T12:00:00', [DateTimeKind]::Utc)
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $settings; October = $october; November = $november } {
            $first = Update-ForecastExportCache -Root $Root -Settings $Settings -Now $October
            $first.Error | Should -BeNullOrEmpty
            # On November 2, 2025-10 is past the API's reach but October 2026 isn't final yet, so the window still starts at 2025-10.
            $refresh = Update-ForecastExportCache -Root $Root -Settings $Settings -Now $November
            $refresh.Error | Should -BeNullOrEmpty
            $dataset = Get-ForecastDataset -Root $Root -Settings $Settings -Reviews @{}
            @($dataset.Months | Where-Object Month -EQ '2025-10')[0].RunRate | Should -Be 310
            $model = Invoke-ForecastModel -Dataset $dataset -Settings $Settings -Reviews @{} -AsOf $November
            $readiness = Test-ForecastReadiness -Dataset $dataset -Model $model -Settings $Settings -RefreshState (Get-ForecastRefreshState -Root $Root) -AsOf $November
            ($readiness.Checks | Where-Object Id -EQ 'MONTHS').Status | Should -Be 'Pass'

            # Adding an unrelated source changes the workspace profile but keeps the month.
            $Settings.sources = @($Settings.sources) + [pscustomobject]@{ id = 'src-old'; kind = 'CostDetails'; label = 'Old scope'; scope = '/subscriptions/22222222-2222-2222-2222-222222222222'; chunkDays = 7; fromMonth = ''; toMonth = '2024-12'; storageResourceId = ''; container = ''; prefix = ''; path = ''; agreement = 'Auto' }
            $added = Update-ForecastExportCache -Root $Root -Settings $Settings -Now $November
            $added.Error | Should -BeNullOrEmpty
            $added.RunsRead | Should -Be 0
            @($added.Notes) | Should -BeNullOrEmpty
            @((Get-ForecastCache -Root $Root).Results | Where-Object { $_.Months -contains '2025-10' }).Count | Should -Be 1

            # Narrowing the source's first month leaves the month out without a warning.
            $narrowed = $Settings.sources[0].PSObject.Copy()
            $narrowed.fromMonth = '2025-11'
            $cache = Get-ForecastCache -Root $Root
            $ingest = Get-ForecastIngestProfile -Settings $Settings
            $plannedRuns = Get-ForecastCostDetailsRuns -Source $narrowed -Now $November
            $retention = Get-ForecastCostDetailsRetainedKeys -Source $narrowed -Runs $plannedRuns -Cached @($cache.Results) -ProfileHash $ingest.SourceHashes['src-cd']
            @($retention.Keys) | Should -BeNullOrEmpty
            @($retention.Dropped) | Should -BeNullOrEmpty

            # A new tag key changes the month's content, so it's dropped, with a warning.
            $Settings.workloads.tagKey = 'costcenter'
            $retagged = Update-ForecastExportCache -Root $Root -Settings $Settings -Now $November -WarningAction SilentlyContinue
            $retagged.Error | Should -BeNullOrEmpty
            $retagged.Succeeded | Should -BeTrue
            @($retagged.Notes) -join ' ' | Should -BeLike '*2025-10*no longer used*'
            @((Get-ForecastCache -Root $Root).Results | Where-Object { $_.Months -contains '2025-10' }).Count | Should -Be 0
        }
    }

    It 'Never writes report links to the workspace or messages' {
        $settings = New-CostDetailsSettings -Sources @(New-CostDetailsSource -From '2026-09')
        $script:Api.GetStatus['20260915'] = 500
        $result = InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $settings; Now = $script:Now } {
            $refresh = Update-ForecastExportCache -Root $Root -Settings $Settings -Now $Now
            $dataset = Get-ForecastDataset -Root $Root -Settings $Settings -Reviews @{}
            [pscustomobject]@{ Refresh = $refresh; Messages = (@($dataset.Issues.Message) -join "`n") }
        }
        $result.Refresh.RunsIncomplete | Should -Be 1
        $result.Messages | Should -Match 'HTTP 500'
        $script:Api.Files.Count | Should -BeGreaterThan 0
        $everything = (Get-WorkspaceText -Root $script:Root) + "`n" + $result.Messages + "`n" + ($result.Refresh | ConvertTo-Json -Depth 5)
        $everything | Should -Not -Match 'SECRETSIG'
        $everything | Should -Not -Match 'sig='
        $everything | Should -Not -Match 'ccmreportstorage'
    }

    It 'Keeps months read before a failure and resumes from them' {
        $settings = New-CostDetailsSettings -Sources @(New-CostDetailsSource -From '2026-08')
        $start = [datetime]::SpecifyKind([datetime]'2026-10-02T08:00:00', [DateTimeKind]::Utc)
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $settings; Now = $start } {
            (Update-ForecastExportCache -Root $Root -Settings $Settings -Now $Now).RunsRead | Should -Be 3
        }
        # Six hours later September (inside its grace period) and October are
        # read again. September succeeds with corrected amounts; October fails.
        $script:Api.DailyCostByMonth['2026-09'] = '11'
        $script:Api.GetStatus['20261001'] = 500
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $settings; Now = $start.AddHours(6) } {
            $failed = Update-ForecastExportCache -Root $Root -Settings $Settings -Now $Now
            $failed.Succeeded | Should -BeFalse
            $failed.Error | Should -BeLike '*1 Cost Details month(s) read completely in this attempt were kept*'
            $dataset = Get-ForecastDataset -Root $Root -Settings $Settings -Reviews @{}
            @($dataset.Months | Where-Object Month -EQ '2026-09')[0].RunRate | Should -Be 330
            @($dataset.Months | Where-Object Month -EQ '2026-08')[0].RunRate | Should -Be 310
            (Get-ForecastRefreshState -Root $Root).LastAttemptResult | Should -Be 'Failed'
        }
    }

    It 'Reports charges dated outside the requested month instead of counting them' {
        $script:Api.Extra['20260701'] = @(New-SyntheticRow -Date '06/30/2026' -Cost '25' -Workload 'app-alpha')
        $settings = New-CostDetailsSettings -Sources @(New-CostDetailsSource -From '2026-06' -To '2026-07')
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $settings; Now = $script:Now } {
            $null = Update-ForecastExportCache -Root $Root -Settings $Settings -Now $Now
            $dataset = Get-ForecastDataset -Root $Root -Settings $Settings -Reviews @{}
            @($dataset.Months | Where-Object Month -EQ '2026-06')[0].RunRate | Should -Be 300
            @($dataset.Months | Where-Object Month -EQ '2026-07')[0].RunRate | Should -Be 310
            $july = @($dataset.Reconciliation | Where-Object Month -EQ '2026-07')[0]
            $july.ExcludedOutsideRange | Should -Be 25
            $july.Difference | Should -Be 0
            @((Get-ForecastCache -Root $Root).Results | ForEach-Object { $_.Issues } | Where-Object Code -EQ 'RUN-OUTSIDE').Count | Should -Be 1
        }
    }

    It 'Joins EA months from the enrollment with MCA months from the billing profile at the boundary' {
        $script:Api.Kinds[$script:EnrollmentScope.ToLowerInvariant()] = 'EA'
        $script:Api.Kinds[$script:ProfileScope.ToLowerInvariant()] = 'MCA'
        $settings = New-CostDetailsSettings -Boundary '2026-07-01' -Sources @(
            (New-CostDetailsSource -Id 'src-ea' -Scope $script:EnrollmentScope -To '2026-07')
            (New-CostDetailsSource -Id 'src-mca' -Scope $script:ProfileScope -From '2026-06')
        )
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Settings = $settings; Now = $script:Now } {
            $refresh = Update-ForecastExportCache -Root $Root -Settings $Settings -Now $Now
            $refresh.Succeeded | Should -BeTrue
            $dataset = Get-ForecastDataset -Root $Root -Settings $Settings -Reviews @{}
            # Overlapping June and July are each counted once, from the side of the boundary they belong to.
            @($dataset.Months | Where-Object Month -EQ '2026-06')[0].RunRate | Should -Be 300
            @($dataset.Months | Where-Object Month -EQ '2026-07')[0].RunRate | Should -Be 310
            @($dataset.Months | Where-Object { $_.Status -eq 'Complete' }).Count | Should -Be 12
            $model = Invoke-ForecastModel -Dataset $dataset -Settings $Settings -Reviews @{} -AsOf $Now
            $readiness = Test-ForecastReadiness -Dataset $dataset -Model $model -Settings $Settings -RefreshState (Get-ForecastRefreshState -Root $Root) -AsOf $Now
            foreach ($id in 'SOURCE', 'MONTHS', 'BOUNDARY', 'RECONCILE', 'CURRENCY') { ($readiness.Checks | Where-Object Id -EQ $id).Status | Should -Be 'Pass' -Because $id }
        }
    }
}
