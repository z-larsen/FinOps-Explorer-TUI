# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stubs accept the parameters Explorer passes to the Az commands they replace.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stubs record calls only.')]
param()
###########################################################################
# EXPLORER.SIGNIN.TESTS.PS1
# CHOOSING A TENANT BY NAME, SHARED BY EXPLORER'S SCANS AND THE FORECAST
###########################################################################
# The tenant helpers and Select-Subscription are loaded from Explorer's
# launcher. Az commands, the console, and prompts are replaced by stubs that
# record what they're asked; every tenant and subscription is synthetic.
###########################################################################
Describe 'Choosing a tenant by name' {
    BeforeAll {
        $launcher = Join-Path $PSScriptRoot '../Private/FinOpsMultitool/Invoke-FinOpsMultitool.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$null, [ref]$null)
        foreach ($definition in $ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -in @('Get-FinOpsTenantChoice', 'Step-FinOpsTenantPicker', 'Select-FinOpsTenant', 'Connect-FinOpsAzAccount', 'Select-Subscription',
                        'Get-FinOpsContextTenantName', 'Get-FinOpsSignInFailure', 'Test-FinOpsSignInExpired', 'Request-FinOpsTenantSignIn')
                }, $true)) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }

        $script:Ids = @{
            Contoso   = 'c0000000-0000-4000-8000-000000000001'
            Fabrikam  = 'f0000000-0000-4000-8000-000000000002'
            Northwind = 'a0000000-0000-4000-8000-000000000003'
        }
        $script:GuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $script:Output = [Collections.Generic.List[string]]::new()
        $script:Answers = [Collections.Generic.Queue[string]]::new()
        $script:Calls = [Collections.Generic.List[string]]::new()

        function Write-FinOpsConsole {
            param([Parameter(Position = 0)][AllowNull()][object]$Object, [ConsoleColor]$ForegroundColor, [ConsoleColor]$BackgroundColor, [switch]$NoNewline)
            $script:Output.Add([string]$Object)
        }
        function Read-FinOpsAnswer {
            param([string]$Prompt)
            $script:Output.Add($Prompt)
            if ($script:Answers.Count) { return $script:Answers.Dequeue() }
            throw "Unexpected prompt: $Prompt"
        }
        function Test-FinOpsRichConsole { $false }
        function Get-MenuWidth { param([int]$Cap) $Cap }
        function Move-FinOpsCursorLine { param([int]$LinesUp) }
        function Get-AzContext {
            [CmdletBinding()] param()
            if ($script:ContextTenant) {
                [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'finops.synthetic@example.test' }; Tenant = [pscustomobject]@{ Id = $script:ContextTenant } }
            }
        }
        # Expired holds tenants whose saved sign-in Az can't use without the
        # user. Like Az, listing tenants then returns only the saved tenant ID,
        # and listing subscriptions returns nothing; both warn with the ID.
        function Get-AzTenant {
            [CmdletBinding()] param()
            $saved = if ($script:SavedTenant) { $script:SavedTenant } else { $script:ContextTenant }
            if ($script:Expired.Contains($saved)) {
                Write-Warning "Unable to acquire token for tenant '$saved' with error 'User interaction is required.'"
                return [pscustomobject]@{ TenantId = $saved }
            }
            $script:Tenants
        }
        function Get-AzSubscription {
            [CmdletBinding()] param([string]$TenantId, [string]$SubscriptionId)
            $script:Calls.Add("Get-AzSubscription $TenantId")
            if ($script:Expired.Contains($TenantId)) {
                Write-Warning "Unable to acquire token for tenant '$TenantId' with error 'User interaction is required.'"
                return
            }
            @($script:Subscriptions | Where-Object { $_.TenantId -eq $TenantId -and (-not $SubscriptionId -or $_.Id -eq $SubscriptionId) })
        }
        function Connect-AzAccount {
            [CmdletBinding()] param([string]$TenantId)
            $script:Calls.Add("Connect-AzAccount $TenantId".TrimEnd())
            $script:SignInWarningAction = [string]$PSBoundParameters['WarningAction']
            if ($script:FailedSignIns -gt 0) {
                $script:FailedSignIns--
                throw $(if ($TenantId) { "Authentication failed against tenant $TenantId. Synthetic sign-in was cancelled." } else { 'Synthetic sign-in was cancelled.' })
            }
            $script:SavedTenant = $null
            if (-not $TenantId) { $script:ContextTenant = $script:HomeTenant; return }
            if ($script:SignInLandsElsewhere) { return }
            $script:ContextTenant = $TenantId
            [void]$script:Expired.Remove($TenantId)
        }
        function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$TenantId, [string]$Scope) $script:Calls.Add("Set-AzContext $SubscriptionId") }
        function Get-AzConfig { [CmdletBinding()] param([switch]$LoginExperienceV2) $script:Calls.Add('Get-AzConfig'); $script:LoginSetting }
        function Update-AzConfig { [CmdletBinding()] param([string]$LoginExperienceV2, [string]$Scope) $script:Calls.Add("Update-AzConfig $LoginExperienceV2 $Scope") }
        function Clear-AzConfig {
            [CmdletBinding(SupportsShouldProcess)] param([switch]$LoginExperienceV2, [string]$Scope)
            if ($PSCmdlet.ShouldProcess("LoginExperienceV2 at $Scope scope")) { $script:Calls.Add("Clear-AzConfig $Scope") }
        }

        function New-Tenant { param([string]$Id, [string]$Name, [string]$Domain) [pscustomobject]@{ TenantId = $Id; Name = $Name; DefaultDomain = $Domain } }
        function New-Key { param([int]$Code, [char]$Character = [char]0) [pscustomobject]@{ VirtualKeyCode = $Code; Character = $Character } }
        function New-PickerState { param([object[]]$Choices) @{ Choices = $Choices; Visible = $Choices; Filter = ''; Cursor = 0; Offset = 0 } }
        function Send-PickerText {
            param([hashtable]$State, [string]$Text)
            foreach ($character in $Text.ToCharArray()) { $null = Step-FinOpsTenantPicker -State $State -Key (New-Key ([int][char]::ToUpperInvariant($character)) $character) }
        }
    }

    BeforeEach {
        $script:Output.Clear()
        $script:Answers.Clear()
        $script:Calls.Clear()
        $script:ContextTenant = $script:Ids.Contoso
        $script:Tenants = @(
            New-Tenant $script:Ids.Northwind 'Northwind Traders' 'northwind.onmicrosoft.com'
            New-Tenant $script:Ids.Contoso 'Contoso' 'contoso.onmicrosoft.com'
            New-Tenant $script:Ids.Fabrikam 'Fabrikam' 'fabrikam.onmicrosoft.com'
        )
        $script:Subscriptions = @(
            [pscustomobject]@{ Id = '11111111-1111-4111-8111-111111111111'; Name = 'contoso-prod'; TenantId = $script:Ids.Contoso; State = 'Enabled' }
            [pscustomobject]@{ Id = '11111111-1111-4111-8111-111111111112'; Name = 'contoso-dev'; TenantId = $script:Ids.Contoso; State = 'Enabled' }
            [pscustomobject]@{ Id = '22222222-2222-4222-8222-222222222221'; Name = 'fabrikam-prod'; TenantId = $script:Ids.Fabrikam; State = 'Enabled' }
            [pscustomobject]@{ Id = '22222222-2222-4222-8222-222222222222'; Name = 'fabrikam-dev'; TenantId = $script:Ids.Fabrikam; State = 'Enabled' }
            [pscustomobject]@{ Id = '33333333-3333-4333-8333-333333333331'; Name = 'northwind-prod'; TenantId = $script:Ids.Northwind; State = 'Enabled' }
        )
        $script:LoginSetting = [pscustomobject]@{ Value = 'On'; Scope = 'Default' }
        $script:FailedSignIns = 0
        $script:SignInLandsElsewhere = $false
        $script:Expired = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $script:SavedTenant = $null
        $script:HomeTenant = $script:Ids.Contoso
        $script:SignInWarningAction = $null
        Set-Variable -Name NonInteractive -Value $false
    }

    Context 'Tenant names' {
        It 'Lists tenants by name, sorted, with the current tenant marked' {
            $tenants = @($script:Tenants) + [pscustomobject]@{ Id = $script:Ids.Contoso; Name = 'Contoso listed twice' }
            $choices = @(Get-FinOpsTenantChoice -Tenants $tenants -CurrentTenantId $script:Ids.Contoso.ToUpperInvariant())
            $choices.Label | Should -Be @('Contoso', 'Fabrikam', 'Northwind Traders')
            @($choices | Where-Object Current).Label | Should -Be 'Contoso'
            $choices.TenantId | Should -Be @($script:Ids.Contoso, $script:Ids.Fabrikam, $script:Ids.Northwind)
        }

        It 'Tells tenants apart by domain, never by ID' {
            $tenants = @(
                New-Tenant 'd1000000-0000-4000-8000-000000000001' 'Default Directory' 'fabrikamlab.onmicrosoft.com'
                New-Tenant 'd2000000-0000-4000-8000-000000000002' 'default directory' 'contosolab.onmicrosoft.com'
                New-Tenant 'e1000000-0000-4000-8000-000000000003' 'e1000000-0000-4000-8000-000000000003' 'nameless.onmicrosoft.com'
                [pscustomobject]@{ Id = 'e2000000-0000-4000-8000-000000000004'; Name = ''; Domains = @('', 'other.onmicrosoft.com') }
                New-Tenant '7b000000-0000-4000-8000-000000000006' 'Twin' ''
                New-Tenant '7a000000-0000-4000-8000-000000000005' 'Twin' ''
                New-Tenant 'f9000000-0000-4000-8000-000000000007' '' ''
            )
            $labels = @(Get-FinOpsTenantChoice -Tenants $tenants).Label
            $labels | Should -Be @(
                'default directory (contosolab.onmicrosoft.com)', 'Default Directory (fabrikamlab.onmicrosoft.com)',
                'nameless.onmicrosoft.com', 'other.onmicrosoft.com', 'Twin (1)', 'Twin (2)', 'Unnamed tenant')
            ($labels -join "`n") | Should -Not -Match $script:GuidPattern
        }

        It 'Removes control characters from names' {
            $choices = @(Get-FinOpsTenantChoice -Tenants @(New-Tenant $script:Ids.Contoso "Contoso`e[2J Ltd" 'contoso.onmicrosoft.com'))
            $choices[0].Label | Should -Be 'Contoso[2J Ltd'
        }
    }

    Context 'Picker keys' {
        It 'Narrows the list as you type, and Esc clears the text before staying' {
            $choices = @(Get-FinOpsTenantChoice -Tenants $script:Tenants -CurrentTenantId $script:Ids.Fabrikam)
            $state = New-PickerState $choices
            $state.Cursor = 1

            Send-PickerText $state 'nor'
            @($state.Visible).Label | Should -Be 'Northwind Traders'
            Step-FinOpsTenantPicker -State $state -Key (New-Key 13) | Should -Be 'Select'
            @($state.Visible)[$state.Cursor].Label | Should -Be 'Northwind Traders'

            foreach ($press in 1..3) { $null = Step-FinOpsTenantPicker -State $state -Key (New-Key 8) }
            $state.Filter | Should -Be ''
            @($state.Visible).Count | Should -Be 3
            $state.Cursor | Should -Be 1 -Because 'clearing the text returns to the current tenant'

            Send-PickerText $state 'zz'
            @($state.Visible).Count | Should -Be 0
            Step-FinOpsTenantPicker -State $state -Key (New-Key 13) | Should -BeNullOrEmpty
            Step-FinOpsTenantPicker -State $state -Key (New-Key 27) | Should -BeNullOrEmpty
            $state.Filter | Should -Be ''
            $state.Cursor | Should -Be 1
            Step-FinOpsTenantPicker -State $state -Key (New-Key 27) | Should -Be 'Stay'
        }

        It 'Moves within the list and scrolls a page at a time' {
            $tenants = foreach ($number in 1..20) { New-Tenant ('{0:x8}-0000-4000-8000-000000000000' -f $number) ('Tenant {0:D2}' -f $number) '' }
            $state = New-PickerState @(Get-FinOpsTenantChoice -Tenants $tenants)
            $positions = foreach ($code in 38, 40, 40, 40, 34, 35, 33, 36) {
                $null = Step-FinOpsTenantPicker -State $state -Key (New-Key $code) -PageSize 5
                '{0}/{1}' -f $state.Cursor, $state.Offset
            }
            $positions | Should -Be @('0/0', '1/0', '2/0', '3/0', '8/4', '19/15', '14/14', '0/0')
        }

        It 'Redraws the arrow-key list in place and returns the highlighted tenant' {
            function Test-FinOpsRichConsole { $true }
            function Move-FinOpsCursorLine { param([int]$LinesUp) $script:Output.Add("<move $LinesUp>") }
            $keys = [Collections.Generic.Queue[object]]::new()
            foreach ($key in @((New-Key 40), (New-Key 78 'n'), (New-Key 8), (New-Key 40), (New-Key 13))) { $keys.Enqueue($key) }
            $choices = @(Get-FinOpsTenantChoice -Tenants $script:Tenants -CurrentTenantId $script:Ids.Contoso)

            $selected = Select-FinOpsTenant -Choices $choices -ReadKey { $keys.Dequeue() }

            $selected.Label | Should -Be 'Fabrikam'
            $moves = 0
            for ($i = 0; $i -lt $script:Output.Count; $i++) {
                $move = [regex]::Match($script:Output[$i], '^<move ([1-9]\d*)>$')
                if (-not $move.Success) { continue }
                $moves++
                ($i - $script:Output.LastIndexOf('<move 0>', $i) - 1) | Should -Be ([int]$move.Groups[1].Value) -Because 'the list moves up exactly as many lines as it drew, even when typing hides some tenants'
            }
            $moves | Should -Be 4
            @($script:Output | ForEach-Object { $_.TrimEnd() }) | Should -Contain '  Filter: n  (2 of 3)'
            ($script:Output -join "`n") | Should -Not -Match $script:GuidPattern
        }
    }

    Context 'Selecting a tenant' {
        It 'Shows names only, signs in to the chosen tenant, and lists only its subscriptions' {
            $script:Answers.Enqueue('2')
            $script:Answers.Enqueue('A')

            $result = @(Select-Subscription)

            $result.Name | Should -Be @('fabrikam-prod', 'fabrikam-dev')
            $script:Calls | Should -Be @('Get-AzConfig', 'Update-AzConfig Off Process', "Connect-AzAccount $($script:Ids.Fabrikam)", 'Clear-AzConfig Process', "Get-AzSubscription $($script:Ids.Fabrikam)")
            $script:Output | Should -Contain '    [1] Contoso (current)'
            $script:Output | Should -Contain '    [2] Fabrikam'
            $script:Output | Should -Contain '  Connected to: Fabrikam'
            $shown = $script:Output -join "`n"
            $shown | Should -Not -Match $script:GuidPattern
            foreach ($id in $script:Ids.Values) { $shown | Should -Not -Match $id.Substring(0, 8) }
        }

        It 'Picks a tenant from part of its name' {
            $script:Answers.Enqueue('north')

            $result = @(Select-Subscription)

            $result.Name | Should -Be 'northwind-prod'
            $script:Calls | Should -Contain "Connect-AzAccount $($script:Ids.Northwind)"
            $script:Output | Should -Contain '  Connected to: Northwind Traders'
        }

        It 'Stays in the current tenant when Enter is pressed' {
            $script:Answers.Enqueue('')
            $script:Answers.Enqueue('A')

            $result = @(Select-Subscription)

            $result.Name | Should -Be @('contoso-prod', 'contoso-dev')
            $script:Calls | Should -Be @("Get-AzSubscription $($script:Ids.Contoso)")
            $script:Output | Should -Contain '  Staying in Contoso.'
        }

        It 'Returns to the list when a sign-in is cancelled' {
            $script:FailedSignIns = 1
            foreach ($answer in '2', '', 'A') { $script:Answers.Enqueue($answer) }

            $result = @(Select-Subscription)

            $result.Name | Should -Be @('contoso-prod', 'contoso-dev')
            $script:Output | Should -Contain "  Sign-in to Fabrikam didn't finish: Authentication failed against Fabrikam."
            ($script:Output -join "`n") | Should -Not -Match $script:GuidPattern
            @($script:Output | Where-Object { $_ -eq '  3 tenants available:' }).Count | Should -Be 2
            @($script:Calls | Where-Object { $_ -like 'Connect-AzAccount*' }).Count | Should -Be 1
            $script:Calls | Should -Contain 'Clear-AzConfig Process'
            $script:Calls[-1] | Should -Be "Get-AzSubscription $($script:Ids.Contoso)"
        }

        It 'Stops when the sign-in ends in another tenant' {
            $script:SignInLandsElsewhere = $true
            $script:Answers.Enqueue('2')

            Select-Subscription | Should -BeNullOrEmpty

            $script:Output | Should -Contain "  The sign-in didn't end in Fabrikam, so no subscriptions were listed."
            @($script:Calls | Where-Object { $_ -like 'Get-AzSubscription*' }) | Should -BeNullOrEmpty
        }

        It 'Stays in the signed-in tenant without prompting in unattended runs' {
            Set-Variable -Name NonInteractive -Value $true

            $result = @(Select-Subscription)

            $result.Name | Should -Be @('contoso-prod', 'contoso-dev')
            $script:Output | Should -Contain '  Tenant: Contoso'
            $script:Output | Should -Contain '  3 tenants available. Sign in to the intended tenant before targeting another one.'
            @($script:Calls | Where-Object { $_ -like 'Connect-AzAccount*' }) | Should -BeNullOrEmpty
        }

        It 'Signs in first when there''s no Azure context, without Az''s subscription list' {
            $script:ContextTenant = $null
            $script:Answers.Enqueue('')
            $script:Answers.Enqueue('A')

            $result = @(Select-Subscription)

            $result.Name | Should -Be @('contoso-prod', 'contoso-dev')
            $script:Calls[0..3] | Should -Be @('Get-AzConfig', 'Update-AzConfig Off Process', 'Connect-AzAccount', 'Clear-AzConfig Process')
        }

        It 'Stops quietly when the first sign-in is cancelled' {
            $script:ContextTenant = $null
            $script:FailedSignIns = 1

            Select-Subscription | Should -BeNullOrEmpty

            $script:Output | Should -Contain "  Sign-in didn't finish: Synthetic sign-in was cancelled."
        }
    }

    Context 'Sign-in settings' {
        It 'Turns off Az''s subscription list only while signing in when it''s <Setting>' -ForEach @(
            @{ Setting = 'on by default'; Value = 'On'; Scope = 'Default'; Expected = @('Get-AzConfig', 'Update-AzConfig Off Process', 'Connect-AzAccount', 'Clear-AzConfig Process') }
            @{ Setting = 'on for this session'; Value = 'On'; Scope = 'Process'; Expected = @('Get-AzConfig', 'Update-AzConfig Off Process', 'Connect-AzAccount', 'Update-AzConfig On Process') }
            @{ Setting = 'already off'; Value = 'Off'; Scope = 'CurrentUser'; Expected = @('Get-AzConfig', 'Connect-AzAccount') }
        ) {
            $script:LoginSetting = [pscustomobject]@{ Value = $Value; Scope = $Scope }

            Connect-FinOpsAzAccount

            $script:Calls | Should -Be $Expected
            $script:SignInWarningAction | Should -Be 'SilentlyContinue' -Because 'Az''s warnings about other tenants and its own subscription choice don''t apply'
        }

        It 'Restores the setting when the sign-in fails' {
            $script:FailedSignIns = 1

            { Connect-FinOpsAzAccount -TenantId $script:Ids.Fabrikam } | Should -Throw '*cancelled*'

            $script:Calls | Should -Be @('Get-AzConfig', 'Update-AzConfig Off Process', "Connect-AzAccount $($script:Ids.Fabrikam)", 'Clear-AzConfig Process')
        }

        It 'Names tenants in sign-in errors and keeps only the first sentence' {
            $message = "Authentication failed against tenant $($script:Ids.Fabrikam). User interaction is required. Rerun 'Connect-AzAccount' with '-TenantId $($script:Ids.Fabrikam)'."
            $record = [Management.Automation.ErrorRecord]::new([Exception]::new($message), 'SyntheticSignIn', 'AuthenticationError', $null)

            Get-FinOpsSignInFailure -ErrorRecord $record -Choices @([pscustomobject]@{ TenantId = $script:Ids.Fabrikam; Label = 'Fabrikam $0 Ltd' }) | Should -Be 'Authentication failed against Fabrikam $0 Ltd.'
            Get-FinOpsSignInFailure -ErrorRecord $record -Choices @([pscustomobject]@{ TenantId = $script:Ids.Fabrikam.ToUpperInvariant(); Label = '' }) | Should -Be 'Authentication failed against that tenant.'
            Get-FinOpsSignInFailure -ErrorRecord ([Management.Automation.ErrorRecord]::new([Exception]::new(''), 'Empty', 'NotSpecified', $null)) | Should -Be 'Azure gave no reason.'
        }
    }

    Context 'Expired sign-ins' {
        It 'Signs in to the last tenant again when its saved sign-in can''t list tenants' {
            [void]$script:Expired.Add($script:Ids.Contoso)
            $script:Answers.Enqueue('')
            $script:Answers.Enqueue('A')

            $result = @(Select-Subscription)

            $result.Name | Should -Be @('contoso-prod', 'contoso-dev')
            $script:Calls | Should -Be @('Get-AzConfig', 'Update-AzConfig Off Process', "Connect-AzAccount $($script:Ids.Contoso)", 'Clear-AzConfig Process', "Get-AzSubscription $($script:Ids.Contoso)")
            $script:Output | Should -Contain '  Your Azure sign-in has expired or needs MFA again. Sign in when prompted.'
            $script:Output | Should -Contain '    [1] Contoso (current)'
            $script:Output | Should -Not -Contain '  Tenant: Unnamed tenant'
            ($script:Output -join "`n") | Should -Not -Match $script:GuidPattern
        }

        It 'Offers a fresh sign-in when the last tenant''s sign-in can''t be renewed, and you answer <Answer>' -ForEach @(
            @{ Answer = 'Y'; Expected = @('northwind-prod') }
            @{ Answer = 'N'; Expected = @() }
        ) {
            [void]$script:Expired.Add($script:Ids.Contoso)
            $script:FailedSignIns = 1
            $script:HomeTenant = $script:Ids.Northwind
            $script:Answers.Enqueue($Answer)
            $script:Answers.Enqueue('')

            $result = @(Select-Subscription | Where-Object { $_ })

            ($result.Name -join ',') | Should -Be ($Expected -join ',')
            $script:Output | Should -Contain "  Sign-in didn't finish: Authentication failed against that tenant."
            ($script:Output -join "`n") | Should -Not -Match $script:GuidPattern
            if ($Answer -eq 'Y') {
                $script:Calls | Should -Contain 'Connect-AzAccount'
                $script:Output | Should -Contain '    [3] Northwind Traders (current)'
            }
            else {
                @($script:Calls | Where-Object { $_ -like 'Connect-AzAccount*' }).Count | Should -Be 1
                @($script:Calls | Where-Object { $_ -like 'Get-AzSubscription*' }) | Should -BeNullOrEmpty
            }
        }

        It 'Signs in to the chosen tenant again when its subscriptions can''t be read' {
            [void]$script:Expired.Add($script:Ids.Contoso)
            $script:SavedTenant = $script:Ids.Northwind
            $script:Answers.Enqueue('')
            $script:Answers.Enqueue('A')

            $result = @(Select-Subscription)

            $result.Name | Should -Be @('contoso-prod', 'contoso-dev')
            $script:Calls | Should -Be @("Get-AzSubscription $($script:Ids.Contoso)", 'Get-AzConfig', 'Update-AzConfig Off Process', "Connect-AzAccount $($script:Ids.Contoso)", 'Clear-AzConfig Process', "Get-AzSubscription $($script:Ids.Contoso)")
            $script:Output | Should -Contain '  Your Azure sign-in to Contoso has expired or needs MFA again. Sign in when prompted.'
            $script:Output | Should -Not -Contain '  No enabled subscriptions were found in Contoso. Your account needs Reader access to at least one subscription there.'
        }

        It 'Explains when a tenant has no enabled subscriptions' {
            $script:Subscriptions = @($script:Subscriptions | Where-Object TenantId -NE $script:Ids.Contoso)
            $script:Answers.Enqueue('')

            Select-Subscription | Should -BeNullOrEmpty

            $script:Output | Should -Contain '  No enabled subscriptions were found in Contoso. Your account needs Reader access to at least one subscription there.'
            @($script:Calls | Where-Object { $_ -like 'Connect-AzAccount*' }) | Should -BeNullOrEmpty
        }

        It 'Stops unattended runs with the command that renews the sign-in' {
            Set-Variable -Name NonInteractive -Value $true
            [void]$script:Expired.Add($script:Ids.Contoso)
            $script:SavedTenant = $script:Ids.Northwind

            { Select-Subscription } | Should -Throw "*Run Connect-AzAccount -TenantId $($script:Ids.Contoso)*"

            @($script:Calls | Where-Object { $_ -like 'Connect-AzAccount*' }) | Should -BeNullOrEmpty
        }

        It 'Renews the sign-in for an explicit subscription in <Mode> runs without widening the scope' -ForEach @(
            @{ Mode = 'interactive'; Unattended = $false }
            @{ Mode = 'unattended'; Unattended = $true }
        ) {
            Set-Variable -Name NonInteractive -Value $Unattended
            [void]$script:Expired.Add($script:Ids.Contoso)

            if ($Unattended) {
                { Select-Subscription -PreselectedId '11111111-1111-4111-8111-111111111111' } | Should -Throw '*Run Connect-AzAccount -TenantId*'
                @($script:Calls | Where-Object { $_ -like 'Connect-AzAccount*' -or $_ -like 'Set-AzContext*' }) | Should -BeNullOrEmpty
                return
            }
            $result = @(Select-Subscription -PreselectedId '11111111-1111-4111-8111-111111111111')

            $result.Name | Should -Be 'contoso-prod'
            $script:Calls | Should -Be @("Get-AzSubscription $($script:Ids.Contoso)", 'Get-AzConfig', 'Update-AzConfig Off Process', "Connect-AzAccount $($script:Ids.Contoso)", 'Clear-AzConfig Process', "Get-AzSubscription $($script:Ids.Contoso)", 'Set-AzContext 11111111-1111-4111-8111-111111111111')
        }
    }
}
