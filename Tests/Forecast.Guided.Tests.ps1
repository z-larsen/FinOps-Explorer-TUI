# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers create synthetic fixtures in TestDrive only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helpers are named for the collections they build.')]
param()
###########################################################################
# FORECAST.GUIDED.TESTS.PS1
# GUIDED SETUP, TENANT WORKSPACES, AND PRELIMINARY FORECASTS
###########################################################################
# Sign-in, the console, and refreshes are mocked; every subscription,
# tenant, and billing account here is synthetic.
###########################################################################
BeforeAll {
    . (Join-Path $PSScriptRoot 'Forecast.TestHelpers.ps1')
    $script:AsOf = [datetime]::SpecifyKind([datetime]'2026-11-10T15:00:00', [DateTimeKind]::Utc)
    $script:TenantId = '00000000-1111-2222-3333-444444444444'
    $script:Answers = [Collections.Generic.Queue[string]]::new()
    $script:Console = [Collections.Generic.List[string]]::new()

    function Set-TestAnswers { param([string[]]$Values) $script:Answers.Clear(); foreach ($value in $Values) { $script:Answers.Enqueue($value) } }

    function New-TestSubscriptions {
        param([int]$Count)
        $letters = 'A', 'B', 'C', 'D', 'E', 'F'
        @(for ($i = 0; $i -lt $Count; $i++) {
                $id = if ($script:SyntheticSubscriptions.ContainsKey($letters[$i])) { $script:SyntheticSubscriptions[$letters[$i]] } else { '{0}{0}{0}{0}{0}{0}{0}{0}-{0}{0}{0}{0}-{0}{0}{0}{0}-{0}{0}{0}{0}-{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}' -f ($i + 1) }
                [pscustomobject]@{ Id = $id; Name = "sub-synth-$($letters[$i].ToLowerInvariant())"; TenantId = $script:TenantId; State = 'Enabled' }
            })
    }

    function New-TestWorkspace {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        InModuleScope FinOpsForecast -Parameters @{ Base = $base } { Get-ForecastWorkspaceRoot -WorkspaceName 'synthetic' -WorkspacePath $Base }
    }

    function Get-TestSettings { param([string]$Root) InModuleScope FinOpsForecast -Parameters @{ Root = $Root } { Get-ForecastStoredSettings -Root $Root } }

    function New-RateSeries {
        param([decimal[]]$Rates, [string[]]$Months)
        $values = [ordered]@{}
        for ($i = 0; $i -lt $Months.Count; $i++) {
            $days = [DateTime]::DaysInMonth([int]$Months[$i].Substring(0, 4), [int]$Months[$i].Substring(5, 2))
            $values[$Months[$i]] = $Rates[$i] * [decimal]$days / 30d
        }
        return $values
    }

    function Get-TestReadiness {
        # A July fiscal year starts inside these windows (they end 2026-10), unless the lookback is 3 months.
        param([int]$Lookback, [int]$Months, [int]$StartMonth = 7)
        $settings = New-TestSettings -Mode 'Manual' -StartMonth $StartMonth
        $settings.period.lookbackMonths = $Lookback
        $settings.method.minimumRetained = InModuleScope FinOpsForecast -Parameters @{ N = $Lookback } { Get-ForecastDefaultMinimumRetained -LookbackMonths $N }
        $rates = [decimal[]]@(for ($i = 0; $i -lt $Months; $i++) { 1000 + (20 * $i) })
        $dataset = New-TestDataset -Values (New-RateSeries -Rates $rates -Months (Get-TestMonthKeys -Last '2026-10' -Count $Months))
        InModuleScope FinOpsForecast -Parameters @{ Dataset = $dataset; Settings = $settings; AsOf = $script:AsOf } {
            $model = Invoke-ForecastModel -Dataset $Dataset -Settings $Settings -Reviews @{} -AsOf $AsOf
            [pscustomobject]@{ Settings = $Settings; Dataset = $Dataset; Model = $model; Readiness = Test-ForecastReadiness -Dataset $Dataset -Model $model -Settings $Settings -AsOf $AsOf }
        }
    }
}

Describe 'Preliminary forecasts' {
    It 'Accepts 3 to 36 months of history and scales the retained-comparison default' {
        InModuleScope FinOpsForecast {
            $settings = New-ForecastDefaultSettings
            $settings.dataMode = 'Manual'
            foreach ($months in 3, 6, 12, 36) {
                $settings.period.lookbackMonths = $months
                $settings.method.minimumRetained = Get-ForecastDefaultMinimumRetained -LookbackMonths $months
                @(Test-ForecastSettings -Settings $Settings | Where-Object Code -In 'SET-LOOKBACK', 'SET-RETAINED') | Should -BeNullOrEmpty -Because "$months months is allowed"
            }
            $settings.period.lookbackMonths = 2
            @(Test-ForecastSettings -Settings $settings | Where-Object Code -EQ 'SET-LOOKBACK').Count | Should -Be 1
            @(3, 6, 12, 24 | ForEach-Object { Get-ForecastDefaultMinimumRetained -LookbackMonths $_ }) | Should -Be @(1, 3, 8, 16)
        }
    }

    It 'Labels a short history Preliminary instead of Ready, without a failing check' {
        $result = Get-TestReadiness -Lookback 6 -Months 6
        $result.Readiness.Ready | Should -BeFalse
        $result.Readiness.Status | Should -Be 'Preliminary'
        $result.Readiness.Labels | Should -Contain 'Preliminary (6 months of history)'
        @($result.Readiness.Checks | Where-Object Status -EQ 'Fail') | Should -BeNullOrEmpty
        ($result.Readiness.Checks | Where-Object Id -EQ 'HISTORY').Status | Should -Be 'Warn'
        $result.Model.Comparisons.Expected | Should -Be 5
        $null -ne $result.Model.Projection.TotalCentral | Should -BeTrue
    }

    It 'Keeps a 12-month history Ready' {
        $result = Get-TestReadiness -Lookback 12 -Months 12
        ($result.Readiness.Checks | Where-Object Id -EQ 'HISTORY').Status | Should -Be 'Pass'
        $result.Readiness.Status | Should -Be 'Ready'
        $result.Readiness.Ready | Should -BeTrue
    }

    It 'Shows Preliminary once in the summary and HTML, and explains it in the disclosure' {
        $result = Get-TestReadiness -Lookback 6 -Months 6
        InModuleScope FinOpsForecast -Parameters @{ Result = $result } {
            $summary = Get-ForecastSummaryLines -Model $Result.Model -Dataset $Result.Dataset -Readiness $Result.Readiness -ScopeLabel 'Synthetic'
            $summary | Should -Contain 'Status: Preliminary'
            (Get-ForecastDisclosure -Model $Result.Model -Dataset $Result.Dataset -Settings $Result.Settings -Readiness $Result.Readiness) -join "`n" | Should -Match 'PRELIMINARY: only 6 months of history \(5 month-to-month changes\)'
            (Get-ForecastDisclosure -Model $Result.Model -Dataset $Result.Dataset -Settings $Result.Settings -Readiness $Result.Readiness) -join "`n" | Should -Match 'Sensitivity range: lowest to highest retained change'
            $html = ConvertTo-ForecastHtml -Model $Result.Model -Dataset $Result.Dataset -Readiness $Result.Readiness -ScopeLabel 'Synthetic'
            ([regex]::Matches($html, '<div class="value">Preliminary</div>')).Count | Should -Be 1
            $html | Should -Not -Match 'Preliminary \(6 months of history\)'
        }
    }

    It 'Refuses to save a Preliminary forecast as a vintage' {
        $result = Get-TestReadiness -Lookback 6 -Months 6
        $session = [pscustomobject]@{ Root = (New-TestWorkspace); Readiness = $result.Readiness; Settings = $result.Settings; Model = $result.Model; Dataset = $result.Dataset }
        Mock Write-FinOpsConsole -ModuleName FinOpsForecast { $script:Console.Add([string]$Object) }
        Mock Read-FinOpsAnswer -ModuleName FinOpsForecast { '' }
        Mock Publish-ForecastOutputs -ModuleName FinOpsForecast { throw 'Publish should not run.' }
        $script:Console.Clear()
        InModuleScope FinOpsForecast -Parameters @{ Session = $session } { Invoke-ForecastConsolePublish -Session $Session -SaveVintage }
        Should -Invoke Publish-ForecastOutputs -ModuleName FinOpsForecast -Times 0 -Exactly
        ($script:Console -join "`n") | Should -Match 'A Preliminary forecast isn''t saved'
    }

    It 'Refuses a Preliminary vintage in the publisher too' {
        $result = Get-TestReadiness -Lookback 6 -Months 6
        $session = [pscustomobject]@{ Root = (New-TestWorkspace); Readiness = $result.Readiness; Settings = $result.Settings; Model = $result.Model; Dataset = $result.Dataset }
        { InModuleScope FinOpsForecast -Parameters @{ Session = $session } { Publish-ForecastOutputs -Session $Session -SaveVintage } } | Should -Throw -ExpectedMessage '*can''t be saved as a vintage*'
    }

    It 'Fails when fiscal-year months before a short lookback have no data' {
        # A July fiscal year with a 3-month lookback (2026-08 to 2026-10) also needs 2026-07.
        $result = Get-TestReadiness -Lookback 3 -Months 3
        $actuals = $result.Readiness.Checks | Where-Object Id -EQ 'ACTUALS'
        $actuals.Status | Should -Be 'Fail'
        $actuals.Detail | Should -Match '2026-07'
        $result.Readiness.Status | Should -Be 'NotReady'
        $result.Model.Projection.MissingActualMonths | Should -Be @('2026-07')

        $covered = Get-TestReadiness -Lookback 3 -Months 4
        ($covered.Readiness.Checks | Where-Object Id -EQ 'ACTUALS').Status | Should -Be 'Pass'
        $covered.Readiness.Status | Should -Be 'Preliminary'

        # A January fiscal year with a 6-month lookback used to count January to April as zero.
        $january = Get-TestReadiness -Lookback 6 -Months 6 -StartMonth 1
        ($january.Readiness.Checks | Where-Object Id -EQ 'ACTUALS').Detail | Should -Match '2026-01, 2026-02, 2026-03, 2026-04'
        $january.Readiness.Status | Should -Be 'NotReady'
    }
}

Describe 'Tenant workspaces' {
    It 'Names <Text> as <Expected>' -ForEach @(
        @{ Text = 'Contoso Synthetic'; Expected = 'contoso-synthetic' }
        @{ Text = 'contoso.onmicrosoft.com'; Expected = 'contoso' }
        @{ Text = '--Fabrikam, Inc.--'; Expected = 'fabrikam-inc' }
        @{ Text = ''; Expected = $null }
        @{ Text = '????'; Expected = $null }
    ) {
        InModuleScope FinOpsForecast -Parameters @{ Text = $Text; Expected = $Expected } { ConvertTo-ForecastWorkspaceName -Text $Text | Should -Be $Expected }
    }

    It 'Uses the tenant''s domain, never its ID, and falls back to the name or <Fallback>' -ForEach @(
        @{ Fallback = 'another domain'; Tenant = @{ Name = 'Contoso Synthetic'; DefaultDomain = ''; Domains = @('contoso-synth.example') }; Expected = 'contoso-synth-example' }
        @{ Fallback = 'a hash'; Tenant = @{ Name = 'Contoso Synthetic'; DefaultDomain = '' }; Expected = 'contoso-synthetic-{hash}' }
        @{ Fallback = 'tenant and a hash'; Tenant = $null; Expected = 'tenant-{hash}' }
    ) {
        # Mock bodies resolve variables where they're called, so the fixture isn't named like the function's $tenant.
        InModuleScope FinOpsForecast -Parameters @{ TenantId = $script:TenantId; TestTenant = $Tenant; Expected = $Expected } {
            Mock Get-AzTenant { [pscustomobject]@{ Name = 'Contoso Synthetic'; DefaultDomain = 'contososynth.onmicrosoft.com' } }
            Get-ForecastTenantWorkspaceName -TenantId $TenantId | Should -Be 'contososynth'
            if ($TestTenant) { Mock Get-AzTenant { [pscustomobject]$TestTenant } } else { Mock Get-AzTenant { throw 'not available' } }
            $name = Get-ForecastTenantWorkspaceName -TenantId $TenantId
            $name | Should -Be $Expected.Replace('{hash}', (Get-ForecastHash -Text $TenantId -Length 8))
            $name | Should -Not -Match '00000000'
        }
    }
}

Describe 'Billing scopes for live reads' {
    BeforeAll {
        $script:BillingAccounts = @(
            [pscustomobject]@{ id = '/providers/Microsoft.Billing/billingAccounts/1234567'; name = '1234567'; properties = [pscustomobject]@{ displayName = 'Synthetic enrollment'; agreementType = 'EnterpriseAgreement' } }
            [pscustomobject]@{ id = '/providers/Microsoft.Billing/billingAccounts/aaaa:bbbb_2019-05-31'; name = 'aaaa:bbbb_2019-05-31'; properties = [pscustomobject]@{ displayName = 'Synthetic MCA'; agreementType = 'MicrosoftCustomerAgreement' } }
            [pscustomobject]@{ id = '/providers/Microsoft.Billing/billingAccounts/9999'; name = '9999'; properties = [pscustomobject]@{ displayName = 'Pay-as-you-go'; agreementType = 'MicrosoftOnlineServicesProgram' } }
        )
    }

    It 'Returns the one EA or MCA account that owns every subscription, as a Cost Details scope' {
        # Mock bodies resolve variables dynamically, so test names mustn't match the function's locals ($accounts, $owners).
        InModuleScope FinOpsForecast -Parameters @{ Subscriptions = (New-TestSubscriptions -Count 4); TestAccounts = $script:BillingAccounts } {
            Mock Invoke-AzRestMethodWithRetry { [pscustomobject]@{ StatusCode = 200; Content = (@{ value = $TestAccounts } | ConvertTo-Json -Depth 6); Headers = @{} } }
            Mock Get-FinOpsBillingScope { [pscustomobject]@{ Accounts = @($BillingAccounts | Where-Object name -EQ 'aaaa:bbbb_2019-05-31'); Resolved = $true; CoverageIncomplete = $false; Reason = $null } }
            $scopes = Get-ForecastCostDetailsBillingScopes -Subscriptions $Subscriptions
            @($scopes).Count | Should -Be 1
            $scopes[0].Scope | Should -Be '/providers/Microsoft.Billing/billingAccounts/aaaa:bbbb_2019-05-31'
            $scopes[0].Agreement | Should -Be 'MCA'
            $scopes[0].Name | Should -Be 'Synthetic MCA'
            Should -Invoke Invoke-AzRestMethodWithRetry -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' -and $Path -eq '/providers/Microsoft.Billing/billingAccounts?api-version=2024-04-01' }
            Should -Invoke Get-FinOpsBillingScope -Times 1 -Exactly -ParameterFilter { @($Subscriptions).Count -eq 4 }
        }
    }

    It 'Returns nothing when <Case>' -ForEach @(
        @{ Case = 'the subscriptions belong to more than one account'; Owners = @('1234567', 'aaaa:bbbb_2019-05-31'); Incomplete = $false }
        @{ Case = 'a subscription''s owner couldn''t be confirmed'; Owners = @('aaaa:bbbb_2019-05-31'); Incomplete = $true }
        @{ Case = 'the only owner isn''t EA or MCA'; Owners = @('9999'); Incomplete = $false }
        @{ Case = 'no account owns them'; Owners = @(); Incomplete = $false }
    ) {
        InModuleScope FinOpsForecast -Parameters @{ Subscriptions = (New-TestSubscriptions -Count 4); TestAccounts = $script:BillingAccounts; TestOwners = $Owners; TestIncomplete = $Incomplete } {
            Mock Invoke-AzRestMethodWithRetry { [pscustomobject]@{ StatusCode = 200; Content = (@{ value = $TestAccounts } | ConvertTo-Json -Depth 6); Headers = @{} } }
            Mock Get-FinOpsBillingScope { [pscustomobject]@{ Accounts = @($BillingAccounts | Where-Object { $_.name -in $TestOwners }); Resolved = (@($TestOwners).Count -gt 0); CoverageIncomplete = $TestIncomplete; Reason = 'Synthetic reason' } }
            $scopes = Get-ForecastCostDetailsBillingScopes -Subscriptions $Subscriptions
            @($scopes).Count | Should -Be 0
            Should -Invoke Get-FinOpsBillingScope -Times 1 -Exactly
        }
    }

    It 'Returns nothing when billing accounts can''t be read' -ForEach @(
        @{ Case = 'forbidden'; Status = 403 }
        @{ Case = 'throws'; Status = 0 }
    ) {
        InModuleScope FinOpsForecast -Parameters @{ Subscriptions = (New-TestSubscriptions -Count 4); Status = $Status } {
            if ($Status) { Mock Invoke-AzRestMethodWithRetry { [pscustomobject]@{ StatusCode = $Status; Content = '{}'; Headers = @{} } } }
            else { Mock Invoke-AzRestMethodWithRetry { throw 'transport failure' } }
            $scopes = Get-ForecastCostDetailsBillingScopes -Subscriptions $Subscriptions
            @($scopes).Count | Should -Be 0
        }
    }
}

Describe 'Guided setup' {
    BeforeEach {
        $script:Console.Clear()
        $script:TestSubscriptions = @(New-TestSubscriptions -Count 2)
        Mock Read-FinOpsAnswer -ModuleName FinOpsForecast { if ($script:Answers.Count) { $script:Answers.Dequeue() } else { '' } }
        Mock Write-FinOpsConsole -ModuleName FinOpsForecast { $script:Console.Add([string]$Object) }
        Mock Clear-Host -ModuleName FinOpsForecast { }
        Mock Select-Subscription -ModuleName FinOpsForecast { $script:TestSubscriptions }
        Mock Invoke-ForecastConsoleRefresh -ModuleName FinOpsForecast { }
        Mock Get-ForecastCostDetailsBillingScopes -ModuleName FinOpsForecast { throw 'Billing lookup should not run for a few subscriptions.' }
        $script:Root = New-TestWorkspace
    }

    It 'Reads a few subscriptions live, one monthly report each, and refreshes' {
        Set-TestAnswers @('6', '7', '1', 'Y')
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; AsOf = $script:AsOf } { Start-ForecastGuidedSetup -Root $Root -AsOf $AsOf | Should -BeTrue }
        $settings = Get-TestSettings -Root $script:Root
        $settings.dataMode | Should -Be 'Exports'
        @($settings.sources).Count | Should -Be 2
        @($settings.sources.kind | Sort-Object -Unique) | Should -Be 'CostDetails'
        @($settings.sources.scope) | Should -Be @("/subscriptions/$($script:SyntheticSubscriptions.A)", "/subscriptions/$($script:SyntheticSubscriptions.B)")
        @($settings.sources.chunkDays | Sort-Object -Unique) | Should -Be 31
        @($settings.sources.fromMonth | Sort-Object -Unique) | Should -Be 'Auto'
        @($settings.sources.id | ForEach-Object { $_ -match '^live-[0-9a-f]{12}$' } | Sort-Object -Unique) | Should -Be $true
        @($settings.scope.subscriptionIds) | Should -Be @($script:SyntheticSubscriptions.A, $script:SyntheticSubscriptions.B)
        $settings.scope.label | Should -Be 'sub-synth-a and 1 more subscription'
        $settings.period.lookbackMonths | Should -Be 6
        $settings.method.minimumRetained | Should -Be 3
        $settings.period.fiscalYearStartMonth | Should -Be 7
        # 2026-05 through November, for each subscription.
        ($script:Console -join "`n") | Should -Match 'asks Cost Management for 14 reports, about 14 minutes'
        ($script:Console -join "`n") | Should -Match 'the forecast will be Preliminary'
        ($script:Console -join "`n") | Should -Not -Match 'The fiscal year started in'
        # The readout comes before the source question, without the billing account for two subscriptions.
        $text = $script:Console -join "`n"
        $text.IndexOf('How the forecast is built') | Should -BeLessThan $text.IndexOf('Where should the cost history come from?')
        $text | Should -Match 'Fastest\s+Cost Management exports'
        $text | Should -Match 'Slowest\s+Live, each subscription'
        $text | Should -Not -Match 'Live, at the billing account'
        $text | Should -Match 'More than 3 months\? Use exports'
        Should -Invoke Invoke-ForecastConsoleRefresh -ModuleName FinOpsForecast -Times 1 -Exactly
        $script:Answers.Count | Should -Be 0
    }

    It 'Reaches back to the fiscal year''s start when it''s before a short lookback' {
        Set-TestAnswers @('6', '1', '1', 'N')
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; AsOf = $script:AsOf } { Start-ForecastGuidedSetup -Root $Root -AsOf $AsOf | Should -BeTrue }
        $settings = Get-TestSettings -Root $script:Root
        $settings.period.fiscalYearStartMonth | Should -Be 1
        @($settings.sources.fromMonth | Sort-Object -Unique) | Should -Be 'Auto'
        ($script:Console -join "`n") | Should -Match 'The fiscal year started in 2026-01, before the 6-month lookback'
        # 2026-01 through November, for each subscription.
        ($script:Console -join "`n") | Should -Match 'asks Cost Management for 22 reports'
        $script:Answers.Count | Should -Be 0
    }

    It 'Offers the owning billing account for many subscriptions' {
        $script:TestSubscriptions = @(New-TestSubscriptions -Count 5)
        Mock Get-ForecastCostDetailsBillingScopes -ModuleName FinOpsForecast { @([pscustomobject]@{ Scope = '/providers/Microsoft.Billing/billingAccounts/aaaa:bbbb_2019-05-31'; Name = 'Synthetic MCA'; Agreement = 'MCA' }) }
        Set-TestAnswers @('12', '7', '1', '1', 'N')
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; AsOf = $script:AsOf } { Start-ForecastGuidedSetup -Root $Root -AsOf $AsOf | Should -BeTrue }
        $settings = Get-TestSettings -Root $script:Root
        @($settings.sources).Count | Should -Be 1
        $settings.sources[0].scope | Should -Be '/providers/Microsoft.Billing/billingAccounts/aaaa:bbbb_2019-05-31'
        $settings.sources[0].agreement | Should -Be 'MCA'
        $settings.sources[0].chunkDays | Should -Be 7
        $settings.sources[0].fromMonth | Should -Be 'Auto'
        $settings.period.lookbackMonths | Should -Be 12
        $settings.period.fiscalYearStartMonth | Should -Be 7
        $settings.method.minimumRetained | Should -Be 8
        @($settings.scope.subscriptionIds).Count | Should -Be 5
        # 2025-11 through November 2026 in weekly reports.
        ($script:Console -join "`n") | Should -Match 'asks Cost Management for 61 reports, about 2 hours'
        ($script:Console -join "`n") | Should -Match 'Live, at the billing account\n: available: Synthetic MCA \(MCA\)'
        # Checked once, before the estimates, and reused for the live read.
        Should -Invoke Get-ForecastCostDetailsBillingScopes -ModuleName FinOpsForecast -Times 1 -Exactly
        Should -Invoke Invoke-ForecastConsoleRefresh -ModuleName FinOpsForecast -Times 0 -Exactly
        $script:Answers.Count | Should -Be 0
    }

    It 'Defaults to whichever live read the estimates say is faster for <Count> subscriptions' -ForEach @(
        @{ Count = 5; Expected = 5 }
        @{ Count = 10; Expected = 1 }
    ) {
        $subscriptions = @(for ($i = 1; $i -le $Count; $i++) { [pscustomobject]@{ Id = ('{0:d8}-0000-4000-8000-000000000000' -f $i); Name = "sub-synth-$i"; TenantId = $script:TenantId; State = 'Enabled' } })
        Set-TestAnswers @('')
        $check = [pscustomobject]@{ Accounts = @([pscustomobject]@{ Scope = '/providers/Microsoft.Billing/billingAccounts/aaaa:bbbb_2019-05-31'; Name = 'Synthetic MCA'; Agreement = 'MCA' }) }
        # Five subscriptions need 65 monthly reports against 61 weekly ones; ten need 130.
        $created = InModuleScope FinOpsForecast -Parameters @{ TestSubscriptions = $subscriptions; Check = $check; AsOf = $script:AsOf } {
            Get-ForecastGuidedLiveSources -Subscriptions $TestSubscriptions -EarliestMonth '2025-11' -AsOf $AsOf -BillingCheck $Check
        }
        @($created).Count | Should -Be $Expected
    }

    It 'Uses 12 months when more are asked for and the history is read live' {
        Set-TestAnswers @('24', '7', '1', 'N')
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; AsOf = $script:AsOf } { Start-ForecastGuidedSetup -Root $Root -AsOf $AsOf | Should -BeTrue }
        $settings = Get-TestSettings -Root $script:Root
        $settings.period.lookbackMonths | Should -Be 12
        $settings.method.minimumRetained | Should -Be 8
        ($script:Console -join "`n") | Should -Match 'Live reads reach back 12 months\.'
        ($script:Console -join "`n") | Should -Match 'live reads use 12 months of history'
        $script:Answers.Count | Should -Be 0
    }

    It 'Falls back to each subscription when no billing account can be read' {
        $script:TestSubscriptions = @(New-TestSubscriptions -Count 5)
        Mock Get-ForecastCostDetailsBillingScopes -ModuleName FinOpsForecast { , [object[]]@() }
        Set-TestAnswers @('12', '1', '1', 'N')
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; AsOf = $script:AsOf } { $null = Start-ForecastGuidedSetup -Root $Root -AsOf $AsOf }
        @((Get-TestSettings -Root $script:Root).sources).Count | Should -Be 5
        ($script:Console -join "`n") | Should -Match 'each subscription is read separately'
        ($script:Console -join "`n") | Should -Match 'Live, at the billing account\n: not available with this sign-in'
    }

    It 'Sets up a local export folder' {
        $folder = Join-Path $TestDrive 'synthetic-exports'
        [void][IO.Directory]::CreateDirectory($folder)
        Set-TestAnswers @('12', '1', '2', '3', $folder, '', 'AUTO', 'Synthetic copy', 'N')
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; AsOf = $script:AsOf } { Start-ForecastGuidedSetup -Root $Root -AsOf $AsOf | Should -BeTrue }
        $source = @((Get-TestSettings -Root $script:Root).sources)[0]
        $source.kind | Should -Be 'LocalFolder'
        $source.path | Should -Be $folder
        $source.label | Should -Be 'Synthetic copy'
        $script:Answers.Count | Should -Be 0
    }

    It 'Switches to manual inputs without a source' {
        Set-TestAnswers @('6', '4', '3')
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; AsOf = $script:AsOf } { Start-ForecastGuidedSetup -Root $Root -AsOf $AsOf | Should -BeTrue }
        $settings = Get-TestSettings -Root $script:Root
        $settings.dataMode | Should -Be 'Manual'
        @($settings.sources).Count | Should -Be 0
        $settings.period.lookbackMonths | Should -Be 6
        $settings.period.fiscalYearStartMonth | Should -Be 4
        # An April fiscal year starts a month before the 6-month window.
        ($script:Console -join "`n") | Should -Match 'Press I on the review page to enter the monthly totals from 2026-04 on'
    }

    It 'Changes nothing when no source choice is made' {
        Set-TestAnswers @('12', '7', 'x', 'x', 'x')
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; AsOf = $script:AsOf } { Start-ForecastGuidedSetup -Root $Root -AsOf $AsOf | Should -BeFalse }
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root } { Test-ForecastWorkspaceConfigured -Root $Root | Should -BeFalse }
    }

    It 'Rescales a default retained threshold when the lookback changes, and clamps a custom one' {
        Set-TestAnswers @('1', '0', '6', '3', '35', 'Auto', '')
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root } { Edit-ForecastPeriod -Root $Root }
        (Get-TestSettings -Root $script:Root).method.minimumRetained | Should -Be 3
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root } {
            $settings = Get-ForecastStoredSettings -Root $Root
            $settings.period.lookbackMonths = 12; $settings.method.minimumRetained = 5
            Save-ForecastStoredSettings -Root $Root -Settings $settings
        }
        Set-TestAnswers @('1', '0', '4', '3', '35', 'Auto', '')
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root } { Edit-ForecastPeriod -Root $Root }
        (Get-TestSettings -Root $script:Root).method.minimumRetained | Should -Be 3
    }
}

Describe 'Read time estimates' {
    It 'Ranks exports first, then live reads fastest first, with reports and rough times' {
        # 124 subscriptions and a 4-month July lookback read 2026-07 through November.
        $estimate = InModuleScope FinOpsForecast -Parameters @{ AsOf = $script:AsOf } {
            Get-ForecastReadEstimate -SubscriptionCount 124 -LookbackMonths 4 -EarliestMonth '2026-07' -AsOf $AsOf -BillingCheck ([pscustomobject]@{ Accounts = @() })
        }
        @($estimate.Options.Key) | Should -Be @('Exports', 'Billing', 'Subscriptions')
        $billing = $estimate.Options[1]
        $billing.Reports | Should -Be 22
        $billing.FirstRead | Should -Be '22 reports, about 45 minutes'
        $billing.Available | Should -BeFalse
        $billing.Status | Should -Be 'not available with this sign-in'
        $each = $estimate.Options[2]
        $each.Reports | Should -Be 620
        $each.FirstRead | Should -Be '620 reports, about 10 hours'
        $each.Later | Should -Be '124 to 248, about 2 to 4 hours'
        $estimate.Recommendation | Should -Be 'More than 3 months? Use exports if they already cover these months. With a billing reader role, one set of reports would cover every subscription.'
    }

    It 'Recommends <Expected> when the billing account is <Case>' -ForEach @(
        @{ Case = 'readable'; Lookback = 4; Check = [pscustomobject]@{ Accounts = @([pscustomobject]@{ Name = 'Synthetic MCA'; Agreement = 'MCA' }) }; Expected = '; if not, read at the billing account.' }
        @{ Case = 'not checked'; Lookback = 4; Check = $null; Expected = '; if not, read at the billing account with a billing reader role.' }
        @{ Case = 'readable, at the minimum lookback'; Lookback = 3; Check = [pscustomobject]@{ Accounts = @([pscustomobject]@{ Name = 'Synthetic MCA'; Agreement = 'MCA' }) }; Expected = '' }
    ) {
        $estimate = InModuleScope FinOpsForecast -Parameters @{ AsOf = $script:AsOf; Lookback = $Lookback; Check = $Check } {
            Get-ForecastReadEstimate -SubscriptionCount 124 -LookbackMonths $Lookback -EarliestMonth '2026-07' -AsOf $AsOf -BillingCheck $Check
        }
        if ($Expected) { $estimate.Recommendation | Should -Be "More than 3 months? Use exports if they already cover these months$Expected" }
        else { $estimate.Recommendation | Should -BeNullOrEmpty }
    }

    It 'Leaves the billing account out for a few subscriptions, and ranks each subscription first when that''s faster' {
        $few = InModuleScope FinOpsForecast -Parameters @{ AsOf = $script:AsOf } { Get-ForecastReadEstimate -SubscriptionCount 2 -LookbackMonths 12 -EarliestMonth '2025-11' -AsOf $AsOf -BillingCheck $null }
        @($few.Options.Key) | Should -Be @('Exports', 'Subscriptions')
        # Five subscriptions: 65 monthly reports take less time than 61 weekly ones.
        $five = InModuleScope FinOpsForecast -Parameters @{ AsOf = $script:AsOf } { Get-ForecastReadEstimate -SubscriptionCount 5 -LookbackMonths 12 -EarliestMonth '2025-11' -AsOf $AsOf -BillingCheck $null }
        @($five.Options.Key) | Should -Be @('Exports', 'Subscriptions', 'Billing')
        $five.Recommendation | Should -Be 'More than 3 months? Use exports if they already cover these months.'
    }

    It 'Rounds <Seconds> seconds to <Expected>' -ForEach @(
        @{ Seconds = 20; UpTo = -1; Expected = 'under a minute' }
        @{ Seconds = 3500; UpTo = -1; Expected = 'about 1 hour' }
        @{ Seconds = 57600; UpTo = -1; Expected = 'about 16 hours' }
        @{ Seconds = 4340; UpTo = 8680; Expected = 'about 1 to 2.5 hours' }
        @{ Seconds = 1800; UpTo = 5400; Expected = 'about 30 minutes to 1.5 hours' }
    ) {
        InModuleScope FinOpsForecast -Parameters @{ Seconds = $Seconds; UpTo = $UpTo } { Format-ForecastDuration -Seconds $Seconds -UpToSeconds $UpTo } | Should -Be $Expected
    }
}

Describe 'How it works on the review page' {
    BeforeEach {
        $script:Console.Clear()
        Mock Read-FinOpsAnswer -ModuleName FinOpsForecast { if ($script:Answers.Count) { $script:Answers.Dequeue() } else { '' } }
        Mock Write-FinOpsConsole -ModuleName FinOpsForecast { $script:Console.Add([string]$Object) }
        Mock Clear-Host -ModuleName FinOpsForecast { }
        Mock Get-ForecastCostDetailsBillingScopes -ModuleName FinOpsForecast { throw 'H should not ask Azure.' }
        $script:Root = New-TestWorkspace
        $script:Ids = @(New-TestSubscriptions -Count 5 | ForEach-Object Id)
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; Ids = $script:Ids } {
            $settings = New-ForecastDefaultSettings
            $settings.dataMode = 'Exports'
            $settings.scope.subscriptionIds = $Ids
            $settings.scope.label = 'sub-synth-a and 4 more subscriptions'
            $settings.sources = @($Ids | ForEach-Object { [pscustomobject]@{ id = "live-$($_.Substring(0, 8))"; kind = 'CostDetails'; label = 'synthetic (live)'; scope = "/subscriptions/$_"; chunkDays = 31; fromMonth = 'Auto'; toMonth = ''; storageResourceId = ''; container = ''; prefix = ''; path = ''; agreement = 'Auto' } })
            Save-ForecastStoredSettings -Root $Root -Settings $settings
            $script:ForecastBillingCheck = $null
        }
    }

    It 'Marks the read in use, and shows the last billing check without asking Azure' {
        InModuleScope FinOpsForecast -Parameters @{ Ids = $script:Ids } { $script:ForecastBillingCheck = [pscustomobject]@{ Key = Get-ForecastBillingCheckKey -SubscriptionIds $Ids; Accounts = @() } }
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; AsOf = $script:AsOf } { Show-ForecastHowItWorks -Root $Root -AsOf $AsOf }
        $text = $script:Console -join "`n"
        $text | Should -Match 'Live, each subscription\n \(in use\)'
        $text | Should -Match 'Live, at the billing account\n: not available with this sign-in'
        $text | Should -Match 'G, then 3'
    }

    It 'Says the billing account isn''t checked yet when guided setup hasn''t checked these subscriptions' {
        InModuleScope FinOpsForecast { $script:ForecastBillingCheck = [pscustomobject]@{ Key = Get-ForecastBillingCheckKey -SubscriptionIds @('00000000-0000-4000-8000-000000000000'); Accounts = @() } }
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; AsOf = $script:AsOf } { Show-ForecastHowItWorks -Root $Root -AsOf $AsOf }
        ($script:Console -join "`n") | Should -Match 'Live, at the billing account\n: not checked yet'
    }

    It 'Estimates the read in use from the workspace''s own sources' {
        # One-day reports for five subscriptions, from 2025-11 through November 9.
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root } {
            $settings = Get-ForecastStoredSettings -Root $Root
            foreach ($source in $settings.sources) { $source.chunkDays = 1 }
            Save-ForecastStoredSettings -Root $Root -Settings $settings
        }
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; AsOf = $script:AsOf } { Show-ForecastHowItWorks -Root $Root -AsOf $AsOf }
        ($script:Console -join "`n") | Should -Match 'First read 1870 reports, about 31 hours; each later refresh 150 to 300, about 2\.5 to 5 hours\.'
    }

    It 'Shows a billing account the workspace reads as in use, even for a few subscriptions' {
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root } {
            $settings = Get-ForecastStoredSettings -Root $Root
            $settings.scope.subscriptionIds = @($settings.scope.subscriptionIds | Select-Object -First 2)
            $settings.sources = @([pscustomobject]@{ id = 'live-billing'; kind = 'CostDetails'; label = 'Synthetic MCA (live)'; scope = '/providers/Microsoft.Billing/billingAccounts/aaaa:bbbb_2019-05-31'; chunkDays = 7; fromMonth = 'Auto'; toMonth = ''; storageResourceId = ''; container = ''; prefix = ''; path = ''; agreement = 'MCA' })
            Save-ForecastStoredSettings -Root $Root -Settings $settings
        }
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; AsOf = $script:AsOf } { Show-ForecastHowItWorks -Root $Root -AsOf $AsOf }
        ($script:Console -join "`n") | Should -Match 'Live, at the billing account\n: available: Synthetic MCA \(MCA\)\n \(in use\)'
    }

    It 'Opens from the review page with H' {
        Mock Invoke-ForecastEvaluation -ModuleName FinOpsForecast { throw 'Synthetic evaluation failure.' }
        Mock Show-ForecastHowItWorks -ModuleName FinOpsForecast { }
        Set-TestAnswers @('H', 'Q')
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Root; AsOf = $script:AsOf } { Show-ForecastSetupReview -Root $Root -AsOf $AsOf }
        Should -Invoke Show-ForecastHowItWorks -ModuleName FinOpsForecast -Times 1 -Exactly
    }
}

Describe 'Forecast entry' {
    BeforeEach {
        $script:Console.Clear()
        $script:TestSubscriptions = @(New-TestSubscriptions -Count 2)
        $script:Base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Opened = [Collections.Generic.List[string]]::new()
        Mock Read-FinOpsAnswer -ModuleName FinOpsForecast { if ($script:Answers.Count) { $script:Answers.Dequeue() } else { '' } }
        Mock Write-FinOpsConsole -ModuleName FinOpsForecast { $script:Console.Add([string]$Object) }
        Mock Clear-Host -ModuleName FinOpsForecast { }
        Mock Select-Subscription -ModuleName FinOpsForecast { $script:TestSubscriptions }
        Mock Get-AzContext -ModuleName FinOpsForecast { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $script:TenantId } } }
        Mock Get-AzTenant -ModuleName FinOpsForecast { [pscustomobject]@{ Name = 'Contoso Synthetic'; DefaultDomain = 'contososynth.onmicrosoft.com' } }
        Mock Start-ForecastGuidedSetup -ModuleName FinOpsForecast { $true }
        Mock Show-ForecastSetupReview -ModuleName FinOpsForecast { $script:Opened.Add($Root) }
    }

    It 'Signs in first and opens the tenant''s workspace when no workspace is named' {
        Set-TestAnswers @('')
        Invoke-FinOpsForecast -WorkspacePath $script:Base -AsOf $script:AsOf
        $script:Opened.Count | Should -Be 1
        Split-Path $script:Opened[0] -Leaf | Should -Be 'contososynth'
        Should -Invoke Start-ForecastGuidedSetup -ModuleName FinOpsForecast -Times 1 -Exactly -ParameterFilter { $Root -eq $script:Opened[0] -and @($Subscriptions).Count -eq 2 }

        # Once set up, the same tenant's workspace opens without asking again.
        InModuleScope FinOpsForecast -Parameters @{ Root = $script:Opened[0] } {
            $settings = New-ForecastDefaultSettings
            $settings.dataMode = 'Manual'
            Save-ForecastStoredSettings -Root $Root -Settings $settings
        }
        Set-TestAnswers @('', '')
        Invoke-FinOpsForecast -WorkspacePath $script:Base -AsOf $script:AsOf
        $script:Opened.Count | Should -Be 2
        $script:Opened[1] | Should -Be $script:Opened[0]
        Should -Invoke Start-ForecastGuidedSetup -ModuleName FinOpsForecast -Times 1 -Exactly
        ($script:Console -join "`n") | Should -Match 'already set up with manual inputs'
    }

    It 'Uses a named workspace as given and starts guided setup when it''s empty' {
        Mock Open-ForecastTenantWorkspace -ModuleName FinOpsForecast { throw 'A named workspace should not sign in first.' }
        Invoke-FinOpsForecast -WorkspaceName 'named-synthetic' -WorkspacePath $script:Base -AsOf $script:AsOf
        Split-Path $script:Opened[0] -Leaf | Should -Be 'named-synthetic'
        Should -Invoke Start-ForecastGuidedSetup -ModuleName FinOpsForecast -Times 1 -Exactly
    }

    It 'Opens nothing when no subscription is selected' {
        $script:TestSubscriptions = @()
        Invoke-FinOpsForecast -WorkspacePath $script:Base -AsOf $script:AsOf
        $script:Opened.Count | Should -Be 0
        Should -Invoke Start-ForecastGuidedSetup -ModuleName FinOpsForecast -Times 0 -Exactly
    }
}
