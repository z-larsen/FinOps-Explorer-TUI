# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers create synthetic fixtures in TestDrive only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helpers are named for the collections they build.')]
param()
BeforeAll {
    . (Join-Path $PSScriptRoot 'Forecast.TestHelpers.ps1')
    $script:ForecastFiles = @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'Private/FinOpsForecast') -Filter '*.ps*1') + (Get-Item (Join-Path $script:RepoRoot 'Public/Start-FinOpsForecast.ps1'))
    $script:ExplorerScript = Join-Path $script:RepoRoot 'Private/FinOpsMultitool/Invoke-FinOpsMultitool.ps1'

    function Get-TestAst { param([string]$Path) [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null) }
}

Describe 'Forecast safety' {
    BeforeAll {
        # The one documented exception: the Cost Details source generates
        # read-only reports through Explorer's REST helper.
        $script:CostDetailsFile = 'Forecast.CostDetails.ps1'
    }

    It 'Never calls Invoke-Expression or a mutating Azure command' {
        $violations = foreach ($file in $script:ForecastFiles) {
            $commands = (Get-TestAst $file.FullName).FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)
            foreach ($command in $commands) {
                $name = $command.GetCommandName()
                if ($name -eq 'Invoke-AzRestMethodWithRetry' -and $file.Name -eq $script:CostDetailsFile) { continue }
                if ($name -in 'Invoke-Expression', 'iex', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Connect-AzAccount', 'Set-AzContext' -or
                    $name -match '^(New|Set|Remove|Update|Start|Stop|Restart|Register|Unregister|Grant|Revoke|Add|Move|Rename|Clear|Reset|Enable|Disable|Import|Export|Publish|Invoke)-Az') {
                    "$($file.Name): $name"
                }
            }
        }
        @($violations) | Should -BeNullOrEmpty
    }

    It 'Never sends a write method to an Azure API' {
        $violations = foreach ($file in $script:ForecastFiles) {
            foreach ($match in [regex]::Matches([IO.File]::ReadAllText($file.FullName), '-Method\s+[''"]?(PUT|PATCH|DELETE|POST)\b', 'IgnoreCase')) {
                if ($file.Name -eq $script:CostDetailsFile -and $match.Groups[1].Value -ceq 'POST') { continue }
                "$($file.Name): $($match.Value)"
            }
        }
        @($violations) | Should -BeNullOrEmpty
    }

    It 'Posts only to generateCostDetailsReport and reads only its status link' {
        $path = (Join-Path $script:RepoRoot "Private/FinOpsForecast/$script:CostDetailsFile")
        $calls = @((Get-TestAst $path).FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-AzRestMethodWithRetry' }, $true))
        $calls.Count | Should -Be 2
        $described = foreach ($call in $calls) {
            $elements = $call.CommandElements
            $values = @{}
            for ($i = 1; $i -lt $elements.Count - 1; $i++) {
                if ($elements[$i] -is [Management.Automation.Language.CommandParameterAst]) { $values[$elements[$i].ParameterName] = $elements[$i + 1].Extent.Text }
            }
            "$($values['Method'])=$($values['Path'])"
        }
        @($described | Sort-Object) | Should -Be @('GET=$pollPath', 'POST=$requestPath')
        $text = [IO.File]::ReadAllText($path)
        [regex]::Matches($text, '-Method\s+[''"]?POST\b', 'IgnoreCase').Count | Should -Be 1
        $assignments = [regex]::Matches($text, '\$requestPath\s*=\s*(.+)')
        $assignments.Count | Should -Be 1
        $assignments[0].Groups[1].Value | Should -Match ([regex]::Escape('/providers/Microsoft.CostManagement/generateCostDetailsReport?api-version='))
        $pollAssignments = [regex]::Matches($text, '\$pollPath\s*=\s*(.+)')
        $pollAssignments.Count | Should -Be 1
        $pollAssignments[0].Groups[1].Value | Should -Match '^ConvertTo-ForecastCostDetailsPollPath '
    }

    It 'Downloads Cost Details files without an Azure credential' {
        foreach ($file in $script:ForecastFiles) {
            $text = [IO.File]::ReadAllText($file.FullName)
            if ($file.Name -ne $script:CostDetailsFile) {
                $text | Should -Not -Match 'Net\.Http' -Because "$($file.Name) shouldn't open its own HTTP connections"
                $text | Should -Not -Match '(?i)blobLink' -Because "$($file.Name) shouldn't handle report links"
                continue
            }
            $text | Should -Not -Match '(?i)Authorization|Get-PlainAccessToken|Get-AzAccessToken|Get-StorageBlobBytes'
            $text | Should -Match 'AllowAutoRedirect = \$false'
            $text | Should -Not -Match '\.(Post|Put|Patch|Delete|Get)Async\('
        }
    }

    It 'Builds exactly one HTTP request, and only as a GET' {
        $httpTypes = '(?i)^(System\.)?(Net\.Http\.)?(HttpClient|HttpClientHandler|SocketsHttpHandler|HttpRequestMessage|HttpMethod)$|(?i)^(System\.)?(Net\.)?(WebClient|WebRequest|HttpWebRequest)$'
        $methodType = '(?i)^(System\.)?(Net\.Http\.)?HttpMethod$'
        $requestType = '(?i)^(System\.)?(Net\.Http\.)?HttpRequestMessage$'
        $requests = [Collections.Generic.List[object]]::new()
        $methodTypes = [Collections.Generic.List[object]]::new()
        $violations = foreach ($file in $script:ForecastFiles) {
            $ast = Get-TestAst $file.FullName
            $text = [IO.File]::ReadAllText($file.FullName)
            if ($text -match '(?i)New-Object[^\r\n]*(Http|WebClient|WebRequest)') { "$($file.Name): New-Object for an HTTP type" }
            foreach ($type in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.TypeExpressionAst] -or $node -is [Management.Automation.Language.TypeConstraintAst] }, $true)) {
                if ($type.TypeName.FullName -match $httpTypes -and $file.Name -ne $script:CostDetailsFile) { "$($file.Name): $($type.TypeName.FullName)" }
                if ($type.TypeName.FullName -match $methodType) { $methodTypes.Add($type) }
            }
            # A request built as GET could otherwise be switched to another method afterwards.
            foreach ($assignment in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.MemberExpressionAst] -and $node.Left.Member.Extent.Text -eq 'Method' }, $true)) {
                "$($file.Name): $($assignment.Extent.Text)"
            }
            foreach ($member in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.MemberExpressionAst] -and $node.Static -and $node.Expression -is [Management.Automation.Language.TypeExpressionAst] }, $true)) {
                $typeName = $member.Expression.TypeName.FullName
                $memberName = [string]$member.Member.Extent.Text
                if ($typeName -match $methodType -and $memberName -ne 'Get') { "$($file.Name): [$typeName]::$memberName" }
                if ($typeName -match $requestType) {
                    if ($member -isnot [Management.Automation.Language.InvokeMemberExpressionAst] -or $memberName -ne 'new') { "$($file.Name): [$typeName]::$memberName" }
                    else { $requests.Add($member) }
                }
            }
        }
        @($violations) | Should -BeNullOrEmpty
        $requests.Count | Should -Be 1
        $method = $requests[0].Arguments[0]
        $method | Should -BeOfType ([Management.Automation.Language.MemberExpressionAst])
        $method.Expression.TypeName.FullName | Should -Match $methodType
        $method.Member.Extent.Text | Should -BeExactly 'Get'
        # HttpMethod appears once in all forecast code: as that argument. No casts or -as conversions.
        $methodTypes.Count | Should -Be 1
        [object]::ReferenceEquals($methodTypes[0], $method.Expression) | Should -BeTrue
    }

    It 'Generates reports only from a partition read, at a scope validated inside the request' {
        $callers = foreach ($file in $script:ForecastFiles) {
            $ast = Get-TestAst $file.FullName
            foreach ($call in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-ForecastCostDetailsReport' }, $true)) {
                $parent = $call.Parent
                while ($parent -and $parent -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $parent = $parent.Parent }
                "$($file.Name):$($parent.Name)"
            }
        }
        @($callers) | Should -Be @("$($script:CostDetailsFile):Read-ForecastCostDetailsPartition")
        $definition = (Get-TestAst (Join-Path $script:RepoRoot "Private/FinOpsForecast/$script:CostDetailsFile")).FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ForecastCostDetailsReport' }, $true)
        @($definition).Count | Should -Be 1
        $definition[0].Body.Extent.Text | Should -Match ([regex]::Escape('$Scope = Get-ForecastCostDetailsScope -Scope $ScopeId'))
    }

    It 'Writes files only through the workspace store' {
        $writeCommands = 'Set-Content', 'Add-Content', 'Out-File', 'Export-Csv', 'New-Item', 'Remove-Item', 'Move-Item', 'Copy-Item', 'Rename-Item', 'Clear-Content', 'Tee-Object'
        $writeMembers = 'WriteAllText', 'WriteAllBytes', 'WriteAllLines', 'AppendAllText', 'AppendAllLines', 'Move', 'Delete', 'Copy', 'Create', 'CreateText', 'CreateDirectory', 'Replace', 'SetUnixFileMode'
        $violations = foreach ($file in $script:ForecastFiles) {
            if ($file.Name -eq 'Forecast.State.ps1') { continue }
            $ast = Get-TestAst $file.FullName
            foreach ($command in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
                if ($command.GetCommandName() -in $writeCommands) { "$($file.Name): $($command.GetCommandName())" }
            }
            foreach ($member in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Static }, $true)) {
                $type = $member.Expression.TypeName.FullName
                if ($type -match '^(System\.)?IO\.(File|Directory|FileStream)$' -and $member.Member.Value -in $writeMembers) { "$($file.Name): [$type]::$($member.Member.Value)" }
                if ($type -match '^(System\.)?IO\.FileStream$') { "$($file.Name): [$type]::new" }
            }
        }
        @($violations) | Should -BeNullOrEmpty
    }

    It 'Finds every shared FinOps Explorer helper exactly once' {
        $definitions = (Get-TestAst $script:ExplorerScript).FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $shared = InModuleScope FinOpsForecast { $script:ForecastSharedHelpers }
        foreach ($name in $shared) { @($definitions | Where-Object Name -EQ $name).Count | Should -Be 1 -Because "$name is loaded from Explorer's launcher" }
    }
}

Describe 'FinOps Explorer integration' {
    It 'Offers the forecast only in interactive runs without preset scans or sources' {
        $text = [IO.File]::ReadAllText($script:ExplorerScript)
        ([regex]::Matches($text, [regex]::Escape("Select-FinOpsExplorerMode -Accessible:`$Accessible"))).Count | Should -Be 1
        $text | Should -Match ([regex]::Escape('if (-not $NonInteractive -and -not $Scans -and -not $DataSource -and (Test-Path -LiteralPath $forecastModule))'))
    }

    It 'Returns <Expected> when the answer is "<Answer>"' -ForEach @(
        @{ Answer = ''; Expected = 'Scans' }
        @{ Answer = '1'; Expected = 'Scans' }
        @{ Answer = '2'; Expected = 'Forecast' }
    ) {
        Mock Read-FinOpsAnswer -ModuleName FinOpsForecast { $Answer }
        Mock Write-FinOpsConsole -ModuleName FinOpsForecast { }
        Select-FinOpsExplorerMode | Should -Be $Expected
    }

    It 'Passes every public parameter through to the forecast' {
        . (Join-Path $script:RepoRoot 'Public/Start-FinOpsForecast.ps1')
        $public = (Get-Command Start-FinOpsForecast).Parameters.Keys | Where-Object { $_ -notin [Management.Automation.PSCmdlet]::CommonParameters }
        $private = (Get-Command Invoke-FinOpsForecast).Parameters.Keys
        foreach ($name in $public) { $private | Should -Contain $name }
    }

    It 'Stays in parity with the FinOps Toolkit runtime' {
        $toolkit = if ($env:FINOPS_TOOLKIT_ROOT) { $env:FINOPS_TOOLKIT_ROOT } else { Join-Path (Split-Path (Split-Path $script:RepoRoot -Parent) -Parent) 'FinOps Toolkit' }
        if (-not (Test-Path -LiteralPath (Join-Path $toolkit 'src/powershell/Private/FinOpsMultitool'))) {
            Set-ItResult -Skipped -Because 'no FinOps Toolkit checkout was found; set FINOPS_TOOLKIT_ROOT to run the parity check'
            return
        }
        $result = & (Join-Path $script:RepoRoot 'scripts/Test-ToolkitParity.ps1') -ToolkitRoot $toolkit
        $result.Result | Should -Be 'Passed'
        $result.ForecastHook | Should -Be 'Present'
    }
}
