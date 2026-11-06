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
    It 'Never calls Invoke-Expression or a mutating Azure command' {
        $violations = foreach ($file in $script:ForecastFiles) {
            $commands = (Get-TestAst $file.FullName).FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)
            foreach ($command in $commands) {
                $name = $command.GetCommandName()
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
            foreach ($match in [regex]::Matches([IO.File]::ReadAllText($file.FullName), '-Method\s+[''"]?(PUT|PATCH|DELETE|POST)\b', 'IgnoreCase')) { "$($file.Name): $($match.Value)" }
        }
        @($violations) | Should -BeNullOrEmpty
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
