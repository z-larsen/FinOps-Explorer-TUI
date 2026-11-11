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
                    $node.Name -in @('Get-FinOpsTenantChoice', 'Step-FinOpsTenantPicker', 'Select-FinOpsTenant', 'Connect-FinOpsAzAccount', 'Select-Subscription')
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
        function Get-AzTenant { [CmdletBinding()] param() $script:Tenants }
        function Get-AzSubscription {
            [CmdletBinding()] param([string]$TenantId)
            $script:Calls.Add("Get-AzSubscription $TenantId")
            @($script:Subscriptions | Where-Object TenantId -EQ $TenantId)
        }
        function Connect-AzAccount {
            [CmdletBinding()] param([string]$TenantId)
            $script:Calls.Add("Connect-AzAccount $TenantId".TrimEnd())
            if ($script:FailedSignIns -gt 0) { $script:FailedSignIns--; throw 'Synthetic sign-in was cancelled.' }
            if (-not $TenantId) { $script:ContextTenant = $script:Ids.Contoso }
            elseif (-not $script:SignInLandsElsewhere) { $script:ContextTenant = $TenantId }
        }
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
            $script:Output | Should -Contain "  Sign-in to Fabrikam didn't finish: Synthetic sign-in was cancelled."
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
        }

        It 'Restores the setting when the sign-in fails' {
            $script:FailedSignIns = 1

            { Connect-FinOpsAzAccount -TenantId $script:Ids.Fabrikam } | Should -Throw '*cancelled*'

            $script:Calls | Should -Be @('Get-AzConfig', 'Update-AzConfig Off Process', "Connect-AzAccount $($script:Ids.Fabrikam)", 'Clear-AzConfig Process')
        }
    }
}
