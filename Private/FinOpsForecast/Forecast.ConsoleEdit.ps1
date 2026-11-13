# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console; Write-FinOpsConsole is the user interface.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers that build objects or write only the private local forecast workspace; nothing in Azure changes.')]
param()

###########################################################################
# FORECAST.CONSOLEEDIT.PS1
# SETTINGS AND INPUT EDITORS
###########################################################################
# Each editor saves after every change and shows the validation messages
# that apply, so problems surface where they're fixed.
###########################################################################

function Save-ForecastSettingsWithFeedback {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Settings)
    Save-ForecastStoredSettings -Root $Root -Settings $Settings
    $issues = @(Test-ForecastSettings -Settings $Settings | Where-Object { -not ($Settings.dataMode -eq 'Manual' -and $_.Code -in 'SET-SOURCE', 'SET-SCOPE') })
    if ($issues.Count) { foreach ($issue in $issues) { Write-FinOpsConsole "  ! $($issue.Message)" -ForegroundColor Yellow } }
    else { Write-FinOpsConsole '  Saved.' -ForegroundColor Green }
}

function New-ForecastSourceId {
    param([string]$Seed)
    $base = 'src-' + (Get-ForecastHash -Text "$Seed|$([guid]::NewGuid())" -Length 8)
    return $base
}

function Test-ForecastSourceShown {
    # Shows why a source isn't valid. Returns $true when it is.
    param([Parameter(Mandatory)]$Source)
    $problems = @(Test-ForecastSourceDefinition -Source $Source)
    foreach ($problem in $problems) { Write-FinOpsConsole "  ! $($problem.Message)" -ForegroundColor Yellow }
    return $problems.Count -eq 0
}

function Read-ForecastStorageSource {
    # Prompts for an export's storage location. Returns $null when it isn't valid.
    $resourceId = Read-ForecastText -Prompt 'Storage account resource ID (/subscriptions/.../storageAccounts/<name>)'
    $container = Read-ForecastText -Prompt 'Container'
    $prefix = Read-ForecastText -Prompt 'Folder path to the export (root folder/export name)' -Default ''
    $agreement = Read-ForecastChoice -Prompt 'Schema: Auto, EA, MCA, or FOCUS' -Valid @('AUTO', 'EA', 'MCA', 'FOCUS') -Default 'AUTO'
    $source = [pscustomobject]@{ id = New-ForecastSourceId -Seed $resourceId; kind = 'AzureStorage'; label = Read-ForecastText -Prompt 'Label' -Default $prefix; storageResourceId = ([string]$resourceId).Trim(); container = ([string]$container).Trim(); prefix = ([string]$prefix).Trim('/'); path = ''; agreement = $(if ($agreement -eq 'AUTO' -or -not $agreement) { 'Auto' } else { $agreement }) }
    if (-not (Test-ForecastSourceShown -Source $source)) { return $null }
    return $source
}

function Read-ForecastLocalSource {
    # Prompts for a local copy of an export container. Returns $null when it isn't valid.
    $path = Read-ForecastText -Prompt 'Local folder that holds a copy of the export container'
    $prefix = Read-ForecastText -Prompt 'Folder path inside it to the export (blank for all)' -Default ''
    $agreement = Read-ForecastChoice -Prompt 'Schema: Auto, EA, MCA, or FOCUS' -Valid @('AUTO', 'EA', 'MCA', 'FOCUS') -Default 'AUTO'
    $source = [pscustomobject]@{ id = New-ForecastSourceId -Seed $path; kind = 'LocalFolder'; label = Read-ForecastText -Prompt 'Label' -Default ([IO.Path]::GetFileName(([string]$path).TrimEnd('\', '/'))); storageResourceId = ''; container = ''; prefix = ([string]$prefix).Trim('/'); path = ([string]$path).Trim(); agreement = $(if ($agreement -eq 'AUTO' -or -not $agreement) { 'Auto' } else { $agreement }) }
    if (-not (Test-ForecastSourceShown -Source $source)) { return $null }
    return $source
}

function Remove-ForecastUnreadableSources {
    # Lists the live sources Cost Details turned down for their offer type
    # and, once confirmed, removes them and their subscriptions from the scope.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Settings)
    Write-FinOpsConsole '  Checking the last refresh...' -ForegroundColor DarkGray
    $cache = $null
    try { $cache = Get-ForecastCache -Root $Root }
    catch { Write-FinOpsConsole "  ! The last refresh couldn't be read: $(ConvertTo-ForecastSafeText $_.Exception.Message 200)" -ForegroundColor Yellow; return }
    $unreadable = @(Get-ForecastUnreadableSources -Settings $Settings -Results @(if ($cache) { $cache.Results }))
    if (-not $unreadable.Count) { Write-FinOpsConsole '  The last refresh didn''t turn down any live source for its offer type.' -ForegroundColor DarkGray; return }
    Write-FinOpsConsole "  Cost Details reads only EA and MCA subscriptions, so the last refresh couldn't read these $($unreadable.Count):"
    foreach ($item in $unreadable) { Write-FinOpsConsole "    $($item.Name)  (offer type $($item.Offer))" }
    if (-not (Read-ForecastYesNo -Prompt 'Remove their live sources and take them out of the scope?')) { return }
    $sourceIds = @($unreadable | ForEach-Object { [string]$_.Source.id })
    $subscriptionIds = @($unreadable | ForEach-Object SubscriptionId | Where-Object { $_ })
    $before = @($Settings.scope.subscriptionIds).Count
    $Settings.sources = @($Settings.sources | Where-Object { [string]$_.id -notin $sourceIds })
    $Settings.scope.subscriptionIds = @($Settings.scope.subscriptionIds | Where-Object { (ConvertTo-ForecastSubscriptionId -Value ([string]$_)) -notin $subscriptionIds })
    $remaining = @($Settings.scope.subscriptionIds)
    # A label from guided setup ("<name> and N more subscriptions") would still count the removed ones.
    if ($remaining.Count -and $remaining.Count -lt $before -and [string]$Settings.scope.label -match "^.+ and $($before - 1) more subscriptions?$") {
        $named = @($remaining | ForEach-Object { [pscustomobject]@{ Name = Get-ForecastLiveSourceName -SubscriptionId (ConvertTo-ForecastSubscriptionId -Value ([string]$_)) -Settings $Settings } })
        if ($named[0].Name) { $Settings.scope.label = Get-ForecastGuidedScopeLabel -Subscriptions $named }
    }
    Save-ForecastSettingsWithFeedback -Root $Root -Settings $Settings
    Write-FinOpsConsole "  Removed $($sourceIds.Count) live source(s)$(if ($remaining.Count -lt $before) { " and $($before - $remaining.Count) subscription(s) from the scope" }). Refresh to bring the workspace up to date; months already read are kept." -ForegroundColor Cyan
}

function Edit-ForecastSources {
    param([Parameter(Mandatory)][string]$Root)
    while ($true) {
        $settings = Get-ForecastStoredSettings -Root $Root
        Clear-ForecastScreen
        Write-ForecastHeading -Title "Source configuration (mode: $($settings.dataMode))"
        $sources = @($settings.sources)
        for ($i = 0; $i -lt $sources.Count; $i++) {
            $s = $sources[$i]
            $location = switch ([string]$s.kind) {
                'LocalFolder' { $s.path }
                'CostDetails' {
                    $range = if ($s.fromMonth -or $s.toMonth) { ", $(if ($s.fromMonth -eq 'Auto') { 'auto' } elseif ($s.fromMonth) { $s.fromMonth } else { 'earliest' }) to $(if ($s.toMonth) { $s.toMonth } else { 'current' })" } else { '' }
                    "$(Get-ForecastCostDetailsChunkDays -Source $s)-day reports$range | $((([string]$s.scope).Trim('/') -split '/' | Select-Object -Last 2) -join '/')"
                }
                default { "$(([string]$s.storageResourceId) -replace '^.*/storageAccounts/', '')/$($s.container)/$($s.prefix)" }
            }
            Write-FinOpsConsole ('  {0,2}  {1,-12} {2,-6} {3}  ({4})' -f ($i + 1), $s.kind, $s.agreement, (ConvertTo-ForecastSafeText $location 70), (ConvertTo-ForecastSafeText $s.label 40))
        }
        if ($sources.Count -eq 0) { Write-FinOpsConsole '  No export sources yet.' -ForegroundColor DarkGray }
        Write-FinOpsConsole "  Migration boundary: $(if ($settings.migration.boundaryDate) { "$($settings.migration.boundaryDate) (EA before, MCA on or after)" } else { 'not set' })"
        Write-FinOpsConsole ''
        Write-FinOpsConsole '  D Discover exports in Azure   A Add storage location   L Add local folder   C Add Cost Details (live)' -ForegroundColor DarkGray
        Write-FinOpsConsole '  E Edit   X Remove   M Switch between exports and manual inputs   T Set migration boundary   B Back' -ForegroundColor DarkGray
        $live = @($sources | Where-Object { [string]$_.kind -eq 'CostDetails' }).Count -gt 0
        if ($live) { Write-FinOpsConsole '  U Remove live sources Cost Details can''t read, such as Visual Studio subscriptions' -ForegroundColor DarkGray }
        $choice = Read-ForecastChoice -Prompt 'Choose' -Valid (@('D', 'A', 'L', 'C', 'E', 'X', 'M', 'T', 'B') + @(if ($live) { 'U' })) -Default 'B'
        switch ($choice) {
            'D' { Add-ForecastDiscoveredSources -Root $Root }
            'U' { Remove-ForecastUnreadableSources -Root $Root -Settings $settings; Wait-ForecastKey }
            'A' {
                $source = Read-ForecastStorageSource
                if (-not $source) { Wait-ForecastKey; continue }
                $settings.sources = @($sources + $source)
                Save-ForecastSettingsWithFeedback -Root $Root -Settings $settings; Wait-ForecastKey
            }
            'L' {
                $source = Read-ForecastLocalSource
                if (-not $source) { Wait-ForecastKey; continue }
                $settings.sources = @($sources + $source)
                Save-ForecastSettingsWithFeedback -Root $Root -Settings $settings; Wait-ForecastKey
            }
            'C' {
                Write-FinOpsConsole '  Cost Details asks Cost Management for ActualCost reports at a subscription or billing scope.' -ForegroundColor DarkGray
                Write-FinOpsConsole '  It reaches 13 months back, needs Cost Management read access there, and changes nothing in Azure.' -ForegroundColor DarkGray
                $scope = Read-ForecastText -Prompt 'Scope (/subscriptions/<id> or /providers/Microsoft.Billing/billingAccounts/<id>[/billingProfiles/<id>])'
                $days = Read-ForecastText -Prompt 'Days per report, 1 to 31 (use 1 for very large scopes)' -Default '7'
                $from = Read-ForecastText -Prompt 'First month: AUTO (what the forecast period needs), yyyy-MM, or NONE (as far back as allowed)' -Default 'AUTO'
                $to = Read-ForecastText -Prompt 'Last month, yyyy-MM (blank for the current month)' -Default ''
                $agreement = Read-ForecastChoice -Prompt 'Schema: Auto, EA, or MCA' -Valid @('AUTO', 'EA', 'MCA') -Default 'AUTO'
                $parsedDays = 0
                $source = [pscustomobject]@{
                    id = New-ForecastSourceId -Seed $scope; kind = 'CostDetails'; label = Read-ForecastText -Prompt 'Label' -Default 'Cost Details'
                    scope = ([string]$scope).Trim(); chunkDays = $(if ([int]::TryParse($days, [ref]$parsedDays)) { $parsedDays } else { $days })
                    fromMonth = $(switch -Regex (([string]$from).Trim()) { '^(?i)auto$' { 'Auto' } '^(?i)none$' { '' } default { $_ } }); toMonth = ([string]$to).Trim()
                    storageResourceId = ''; container = ''; prefix = ''; path = ''; agreement = $(if ($agreement -eq 'AUTO' -or -not $agreement) { 'Auto' } else { $agreement })
                }
                $problems = @(Test-ForecastSourceDefinition -Source $source)
                if ($problems.Count) { foreach ($p in $problems) { Write-FinOpsConsole "  ! $($p.Message)" -ForegroundColor Yellow }; Wait-ForecastKey; continue }
                $settings.sources = @($sources + $source)
                Save-ForecastSettingsWithFeedback -Root $Root -Settings $settings; Wait-ForecastKey
            }
            'E' {
                $number = 0
                if (-not [int]::TryParse((Read-ForecastText -Prompt 'Source number'), [ref]$number) -or $number -lt 1 -or $number -gt $sources.Count) { continue }
                $s = $sources[$number - 1]
                $s.label = Read-ForecastText -Prompt 'Label' -Default $s.label
                if ([string]$s.kind -eq 'CostDetails') {
                    $days = Read-ForecastText -Prompt 'Days per report, 1 to 31' -Default ([string](Get-ForecastCostDetailsChunkDays -Source $s))
                    $parsedDays = 0
                    $values = [ordered]@{
                        chunkDays = $(if ([int]::TryParse($days, [ref]$parsedDays)) { $parsedDays } else { $days })
                        fromMonth = ([string](Read-ForecastText -Prompt 'First month: yyyy-MM, AUTO (what the forecast period needs), or NONE' -Default ([string]$s.fromMonth))).Trim()
                        toMonth = ([string](Read-ForecastText -Prompt 'Last month, yyyy-MM, or NONE' -Default ([string]$s.toMonth))).Trim()
                    }
                    foreach ($name in @($values.Keys)) {
                        $value = if ($values[$name] -match '^(?i)none$') { '' } elseif ($name -eq 'fromMonth' -and $values[$name] -eq 'Auto') { 'Auto' } else { $values[$name] }
                        if ($s.PSObject.Properties[$name]) { $s.$name = $value } else { $s | Add-Member -NotePropertyName $name -NotePropertyValue $value }
                    }
                    $agreement = Read-ForecastChoice -Prompt 'Schema: Auto, EA, or MCA' -Valid @('AUTO', 'EA', 'MCA') -Default ([string]$s.agreement).ToUpperInvariant()
                }
                else {
                    $s.prefix = (Read-ForecastText -Prompt 'Folder path' -Default $s.prefix).Trim('/')
                    $agreement = Read-ForecastChoice -Prompt 'Schema: Auto, EA, MCA, or FOCUS' -Valid @('AUTO', 'EA', 'MCA', 'FOCUS') -Default ([string]$s.agreement).ToUpperInvariant()
                }
                $s.agreement = if ($agreement -eq 'AUTO' -or -not $agreement) { 'Auto' } else { $agreement }
                Save-ForecastSettingsWithFeedback -Root $Root -Settings $settings; Wait-ForecastKey
            }
            'X' {
                $number = 0
                if (-not [int]::TryParse((Read-ForecastText -Prompt 'Source number to remove'), [ref]$number) -or $number -lt 1 -or $number -gt $sources.Count) { continue }
                if (Read-ForecastYesNo -Prompt "Remove '$(ConvertTo-ForecastSafeText $sources[$number - 1].label 60)'?") {
                    $settings.sources = @($sources | Select-Object -Index @(0..($sources.Count - 1) | Where-Object { $_ -ne $number - 1 }))
                    Save-ForecastSettingsWithFeedback -Root $Root -Settings $settings; Wait-ForecastKey
                }
            }
            'M' {
                $settings.dataMode = if ($settings.dataMode -eq 'Exports') { 'Manual' } else { 'Exports' }
                Write-FinOpsConsole "  Data mode is now $($settings.dataMode). Manual inputs and imported actuals are never combined." -ForegroundColor Cyan
                Save-ForecastSettingsWithFeedback -Root $Root -Settings $settings; Wait-ForecastKey
            }
            'T' {
                $date = Read-ForecastText -Prompt 'EA to MCA transition date (yyyy-MM-dd), or NONE to clear' -Default $settings.migration.boundaryDate
                if ($date -match '^(?i)none$') { $settings.migration.boundaryDate = '' }
                elseif (ConvertFrom-ForecastDate -Value $date) { $settings.migration.boundaryDate = (ConvertFrom-ForecastDate -Value $date).ToString('yyyy-MM-dd') }
                else { Write-FinOpsConsole '  That isn''t a date.' -ForegroundColor Yellow; Wait-ForecastKey; continue }
                Write-FinOpsConsole '  Changing the boundary re-reads the exports on the next refresh.' -ForegroundColor DarkGray
                Save-ForecastSettingsWithFeedback -Root $Root -Settings $settings; Wait-ForecastKey
            }
            default { return }
        }
    }
}

function Select-ForecastDiscoveredSources {
    # Finds actual-cost and FOCUS exports for the subscriptions, the
    # management groups, and billing accounts above them, and returns the
    # ones the user picks as sources. Read-only.
    param([Parameter(Mandatory)][object[]]$Subscriptions)
    Write-FinOpsConsole '  Discovery reads export definitions and storage listings. It doesn''t create or change anything.' -ForegroundColor DarkGray
    $tenantId = (Get-AzContext).Tenant.Id
    $found = [Collections.Generic.List[object]]::new()
    foreach ($export in @(Find-CostExport -Subscriptions $Subscriptions -IncludeManagementGroups -IncludeBillingAccounts -TenantId $tenantId -SkipRunHistory)) { $found.Add($export) }
    $known = @{}
    foreach ($export in $found) { $known[("$($export.StorageResourceId)|$($export.Container)|$($export.RootFolder)|$($export.Name)").ToLowerInvariant()] = $true }
    foreach ($export in @(Find-CostExportFromStorage -Subscriptions $Subscriptions -KnownKeys $known)) { $found.Add($export) }
    $usable = @($found | Where-Object { $_.StorageResourceId -and $_.Container -and $_.Type -notmatch 'Amortized' })
    if ($usable.Count -eq 0) { Write-FinOpsConsole '  No actual-cost or FOCUS exports were found.' -ForegroundColor Yellow; return , [object[]]@() }
    for ($i = 0; $i -lt $usable.Count; $i++) {
        $e = $usable[$i]
        Write-FinOpsConsole ('  {0,3}  {1,-28} {2,-12} {3}' -f ($i + 1), (ConvertTo-ForecastSafeText $e.Name 28), $e.Type, (ConvertTo-ForecastSafeText $e.ScopeLabel 60))
    }
    $answer = Read-ForecastText -Prompt 'Numbers to add, separated by commas (blank to cancel)'
    $sources = [Collections.Generic.List[object]]::new()
    foreach ($token in (([string]$answer) -split ',')) {
        $number = 0
        if (-not [int]::TryParse($token.Trim(), [ref]$number) -or $number -lt 1 -or $number -gt $usable.Count) { continue }
        $e = $usable[$number - 1]
        $prefix = (@(([string]$e.RootFolder).Trim('/'), [string]$e.Name) | Where-Object { $_ }) -join '/'
        $source = [pscustomobject]@{ id = New-ForecastSourceId -Seed $prefix; kind = 'AzureStorage'; label = "$($e.Name) ($($e.ScopeLabel))"; storageResourceId = [string]$e.StorageResourceId; container = [string]$e.Container; prefix = $prefix; path = ''; agreement = 'Auto' }
        if (@(Test-ForecastSourceDefinition -Source $source).Count) { Write-FinOpsConsole "  Skipped $($e.Name): its storage location isn't valid." -ForegroundColor Yellow; continue }
        $sources.Add($source)
    }
    return , $sources.ToArray()
}

function Add-ForecastDiscoveredSources {
    param([Parameter(Mandatory)][string]$Root)
    $subscriptions = @(Select-Subscription | Where-Object { $_ })
    if ($subscriptions.Count -eq 0) { return }
    # Assign first: @(...) around a call that returns , $array would nest it.
    $chosen = Select-ForecastDiscoveredSources -Subscriptions $subscriptions
    $chosen = @($chosen)
    if ($chosen.Count) {
        $settings = Get-ForecastStoredSettings -Root $Root
        $settings.sources = @(@($settings.sources) + $chosen)
        Save-ForecastSettingsWithFeedback -Root $Root -Settings $settings
    }
    Wait-ForecastKey
}

function Edit-ForecastScope {
    param([Parameter(Mandatory)][string]$Root)
    $settings = Get-ForecastStoredSettings -Root $Root
    Clear-ForecastScreen
    Write-ForecastHeading -Title 'Scope'
    Write-FinOpsConsole "  Current: $($settings.scope.kind) $(if ($settings.scope.kind -eq 'BillingProfile') { $settings.scope.billingProfileId } else { "($(@($settings.scope.subscriptionIds).Count) subscriptions)" })"
    Write-FinOpsConsole '  S Select subscriptions in Azure   E Enter subscription IDs   P Billing profile   L Label   B Back' -ForegroundColor DarkGray
    switch (Read-ForecastChoice -Prompt 'Choose' -Valid @('S', 'E', 'P', 'L', 'B') -Default 'B') {
        'S' {
            $subscriptions = @(Select-Subscription)
            if ($subscriptions.Count) { $settings.scope.kind = 'Subscriptions'; $settings.scope.subscriptionIds = @($subscriptions | ForEach-Object { [string]$_.Id }) }
        }
        'E' {
            $ids = @((Read-ForecastText -Prompt 'Subscription IDs, separated by commas') -split '[,\s]+' | Where-Object { $_ })
            $settings.scope.kind = 'Subscriptions'; $settings.scope.subscriptionIds = $ids
        }
        'P' {
            $settings.scope.kind = 'BillingProfile'
            $settings.scope.billingProfileId = Read-ForecastText -Prompt 'MCA billing profile ID' -Default $settings.scope.billingProfileId
            Write-FinOpsConsole '  EA history before the migration is included for the same subscriptions.' -ForegroundColor DarkGray
        }
        'L' { $settings.scope.label = ConvertTo-ForecastSafeText (Read-ForecastText -Prompt 'Label shown on reports' -Default $settings.scope.label) 120 }
        default { return }
    }
    Save-ForecastSettingsWithFeedback -Root $Root -Settings $settings
    Wait-ForecastKey
}

function Read-ForecastInteger {
    param([string]$Prompt, $Default, [int]$Minimum, [int]$Maximum)
    $answer = Read-ForecastText -Prompt "$Prompt ($Minimum-$Maximum)" -Default ([string]$Default)
    $value = 0
    if ([int]::TryParse($answer, [ref]$value) -and $value -ge $Minimum -and $value -le $Maximum) { return $value }
    Write-FinOpsConsole "  Kept $Default." -ForegroundColor Yellow
    return $Default
}

function Edit-ForecastPeriod {
    param([Parameter(Mandatory)][string]$Root)
    $settings = Get-ForecastStoredSettings -Root $Root
    Clear-ForecastScreen
    Write-ForecastHeading -Title 'Period'
    $period = $settings.period
    $period.fiscalYearStartMonth = Read-ForecastInteger -Prompt 'Fiscal year start month' -Default $period.fiscalYearStartMonth -Minimum 1 -Maximum 12
    $period.fiscalYearOffset = Read-ForecastInteger -Prompt 'Fiscal year: 0 current, 1 next' -Default $period.fiscalYearOffset -Minimum 0 -Maximum 1
    $previousLookback = [int]$period.lookbackMonths
    $period.lookbackMonths = Read-ForecastInteger -Prompt "Lookback in complete months (under $($script:ForecastReadyMonths) is Preliminary)" -Default $period.lookbackMonths -Minimum $script:ForecastMinimumLookbackMonths -Maximum 36
    $period.graceDays = Read-ForecastInteger -Prompt 'Days after month end before a month counts as final (4 = from the 5th)' -Default $period.graceDays -Minimum 0 -Maximum 10
    $period.staleAfterDays = Read-ForecastInteger -Prompt 'Days before data is labeled stale' -Default $period.staleAfterDays -Minimum 1 -Maximum 365
    $end = Read-ForecastText -Prompt 'Window end: Auto, or a month (yyyy-MM) to pin it' -Default $period.windowEnd
    $period.windowEnd = if ($end -match '^(?i)auto$') { 'Auto' } else { $end }
    # A default threshold follows the lookback; a customized one is only clamped.
    if ([int]$settings.method.minimumRetained -eq (Get-ForecastDefaultMinimumRetained -LookbackMonths $previousLookback)) { $settings.method.minimumRetained = Get-ForecastDefaultMinimumRetained -LookbackMonths ([int]$period.lookbackMonths) }
    elseif ([int]$settings.method.minimumRetained -gt [int]$period.lookbackMonths - 1) { $settings.method.minimumRetained = [int]$period.lookbackMonths - 1 }
    Save-ForecastSettingsWithFeedback -Root $Root -Settings $settings
    Wait-ForecastKey
}

function Edit-ForecastAssumptions {
    param([Parameter(Mandatory)][string]$Root)
    while ($true) {
        $settings = Get-ForecastStoredSettings -Root $Root
        Clear-ForecastScreen
        Write-ForecastHeading -Title 'Assumptions'
        $m = $settings.method
        $range = if (Test-ForecastShortHistory -Settings $settings) { "lowest to highest while the lookback is under $($script:ForecastReadyMonths) months (P$($m.lowPercentile) to P$($m.highPercentile) after)" } else { "P$($m.lowPercentile) to P$($m.highPercentile)" }
        Write-FinOpsConsole "  Method: median growth; sensitivity $range; flag at $($m.anomalyK) x scaled MAD (minimum $(Format-ForecastPercent (Read-ForecastDecimal $m.anomalyMinimumDeviation))); at least $($m.minimumRetained) retained; backtest horizon $($m.backtestHorizon)"
        Write-FinOpsConsole "  Filters: Marketplace $(if ($settings.filters.includeMarketplace) { 'included' } else { 'excluded' }); tax $(if ($settings.filters.includeTax) { 'included' } else { 'excluded' }); credits never counted"
        Write-FinOpsConsole "  Workloads: $($settings.workloads.mode)$(if ($settings.workloads.tagKey) { "; tag key '$($settings.workloads.tagKey)'" })$(if ($settings.workloads.mappingPath) { "; mapping $($settings.workloads.mappingPath)" })"
        Write-FinOpsConsole "  Scheduled items: $(@($settings.scheduledItems).Count)"
        Write-FinOpsConsole '  M Method   F Filters   W Workloads   S Scheduled items   B Back' -ForegroundColor DarkGray
        switch (Read-ForecastChoice -Prompt 'Choose' -Valid @('M', 'F', 'W', 'S', 'B') -Default 'B') {
            'M' {
                $m.lowPercentile = Read-ForecastInteger -Prompt 'Low percentile' -Default $m.lowPercentile -Minimum 0 -Maximum 49
                $m.highPercentile = Read-ForecastInteger -Prompt 'High percentile' -Default $m.highPercentile -Minimum 51 -Maximum 100
                $k = Read-ForecastText -Prompt 'Anomaly multiplier (K)' -Default $m.anomalyK
                if (Read-ForecastDecimal $k) { $m.anomalyK = Format-ForecastDecimal (Read-ForecastDecimal $k) }
                $minimum = Read-ForecastText -Prompt 'Minimum flag deviation as a fraction (0.05 = 5 points)' -Default $m.anomalyMinimumDeviation
                if ($null -ne (Read-ForecastDecimal $minimum)) { $m.anomalyMinimumDeviation = Format-ForecastDecimal (Read-ForecastDecimal $minimum) }
                $m.minimumRetained = Read-ForecastInteger -Prompt 'Minimum retained comparisons' -Default $m.minimumRetained -Minimum 1 -Maximum ([int]$settings.period.lookbackMonths - 1)
                $m.backtestHorizon = Read-ForecastInteger -Prompt 'Backtest horizon in months' -Default $m.backtestHorizon -Minimum 1 -Maximum 12
                Save-ForecastSettingsWithFeedback -Root $Root -Settings $settings; Wait-ForecastKey
            }
            'F' {
                $settings.filters.includeMarketplace = Read-ForecastYesNo -Prompt 'Include Marketplace charges?' -Default ([bool]$settings.filters.includeMarketplace)
                $settings.filters.includeTax = Read-ForecastYesNo -Prompt 'Include tax lines (manual inputs only; exports carry no tax)?' -Default ([bool]$settings.filters.includeTax)
                Save-ForecastSettingsWithFeedback -Root $Root -Settings $settings; Wait-ForecastKey
            }
            'W' {
                $mode = Read-ForecastChoice -Prompt 'Workload mode: TAG, RESOURCEGROUP, or SUBSCRIPTION' -Valid @('TAG', 'RESOURCEGROUP', 'SUBSCRIPTION') -Default ([string]$settings.workloads.mode).ToUpperInvariant()
                $settings.workloads.mode = switch ($mode) { 'RESOURCEGROUP' { 'ResourceGroup' } 'SUBSCRIPTION' { 'Subscription' } default { 'Tag' } }
                $settings.workloads.tagKey = (Read-ForecastText -Prompt 'Tag key (read during refresh; changing it re-reads exports)' -Default $settings.workloads.tagKey).Trim()
                $mapping = Read-ForecastText -Prompt 'Mapping CSV path (MatchType, MatchValue, WorkloadId, WorkloadName), or NONE' -Default $settings.workloads.mappingPath
                $settings.workloads.mappingPath = if ($mapping -match '^(?i)none$') { '' } else { $mapping }
                Save-ForecastSettingsWithFeedback -Root $Root -Settings $settings
                foreach ($issue in @((Import-ForecastWorkloadMapping -Path $settings.workloads.mappingPath).Issues)) { Write-FinOpsConsole "  ! $($issue.Message)" -ForegroundColor Yellow }
                Wait-ForecastKey
            }
            'S' { Edit-ForecastScheduledItems -Root $Root }
            default { return }
        }
    }
}

function Edit-ForecastScheduledItems {
    param([Parameter(Mandatory)][string]$Root)
    while ($true) {
        $settings = Get-ForecastStoredSettings -Root $Root
        Clear-ForecastScreen
        Write-ForecastHeading -Title 'Scheduled purchases, renewals, and business changes'
        $items = @($settings.scheduledItems)
        for ($i = 0; $i -lt $items.Count; $i++) {
            $item = $items[$i]
            Write-FinOpsConsole ('  {0,2}  {1,-18} {2,-14} {3,-9} {4,-8} {5,14}  {6}' -f ($i + 1), (ConvertTo-ForecastSafeText $item.id 18), $item.type, $item.recurrence, $item.startMonth, (Format-ForecastAmount (Read-ForecastDecimal $item.amount)), $item.baselineTreatment)
        }
        if ($items.Count -eq 0) { Write-FinOpsConsole '  None.' -ForegroundColor DarkGray }
        Write-FinOpsConsole '  Treatment: Additive adds the amount; AlreadyInBaseline adds nothing (the run rate already includes it); ReplacesBaselineAmount adds amount minus the replaced amount.' -ForegroundColor DarkGray
        Write-FinOpsConsole '  A Add   E Edit   X Remove   B Back' -ForegroundColor DarkGray
        $choice = Read-ForecastChoice -Prompt 'Choose' -Valid @('A', 'E', 'X', 'B') -Default 'B'
        if ($choice -in '', 'B') { return }
        $index = -1
        if ($choice -in 'E', 'X') {
            $number = 0
            if (-not [int]::TryParse((Read-ForecastText -Prompt 'Item number'), [ref]$number) -or $number -lt 1 -or $number -gt $items.Count) { continue }
            $index = $number - 1
        }
        if ($choice -eq 'X') {
            $settings.scheduledItems = @($items | Select-Object -Index @(0..($items.Count - 1) | Where-Object { $_ -ne $index }))
            Save-ForecastSettingsWithFeedback -Root $Root -Settings $settings; Wait-ForecastKey; continue
        }
        $current = if ($index -ge 0) { $items[$index] } else { [pscustomobject]@{ id = ''; type = 'Purchase'; description = ''; startMonth = ''; endMonth = ''; recurrence = 'OneTime'; amount = ''; baselineTreatment = 'Additive'; replacedAmount = ''; commitmentId = '' } }
        $type = Read-ForecastChoice -Prompt 'Type: PURCHASE, RENEWAL, or BUSINESSCHANGE' -Valid @('PURCHASE', 'RENEWAL', 'BUSINESSCHANGE') -Default ([string]$current.type).ToUpperInvariant()
        $recurrence = Read-ForecastChoice -Prompt 'Recurrence: ONETIME, MONTHLY, or ANNUAL' -Valid @('ONETIME', 'MONTHLY', 'ANNUAL') -Default ([string]$current.recurrence).ToUpperInvariant()
        $treatment = Read-ForecastChoice -Prompt 'Treatment: ADDITIVE, ALREADYINBASELINE, or REPLACESBASELINEAMOUNT' -Valid @('ADDITIVE', 'ALREADYINBASELINE', 'REPLACESBASELINEAMOUNT') -Default ([string]$current.baselineTreatment).ToUpperInvariant()
        $new = [pscustomobject]@{
            id = Read-ForecastText -Prompt 'Unique ID' -Default $current.id
            type = switch ($type) { 'RENEWAL' { 'Renewal' } 'BUSINESSCHANGE' { 'BusinessChange' } default { 'Purchase' } }
            description = ConvertTo-ForecastSafeText (Read-ForecastText -Prompt 'Description' -Default $current.description) 200
            startMonth = Read-ForecastText -Prompt 'Start month (yyyy-MM)' -Default $current.startMonth
            endMonth = Read-ForecastText -Prompt 'End month (yyyy-MM, blank for open-ended)' -Default $current.endMonth
            recurrence = switch ($recurrence) { 'MONTHLY' { 'Monthly' } 'ANNUAL' { 'Annual' } default { 'OneTime' } }
            amount = Read-ForecastText -Prompt 'Amount per occurrence (negative for a reduction)' -Default $current.amount
            baselineTreatment = switch ($treatment) { 'ALREADYINBASELINE' { 'AlreadyInBaseline' } 'REPLACESBASELINEAMOUNT' { 'ReplacesBaselineAmount' } default { 'Additive' } }
            replacedAmount = ''
            commitmentId = (Read-ForecastText -Prompt 'Commitment ID it covers (optional)' -Default $current.commitmentId).Trim().ToLowerInvariant()
        }
        if ($new.baselineTreatment -eq 'ReplacesBaselineAmount') { $new.replacedAmount = Read-ForecastText -Prompt 'Amount of the baseline it replaces, per occurrence' -Default $current.replacedAmount }
        $others = if ($index -ge 0) { @($items | Select-Object -Index @(0..($items.Count - 1) | Where-Object { $_ -ne $index })) } else { $items }
        $check = Test-ForecastScheduledItems -Items @($others + $new)
        $problems = @($check.Issues | Where-Object { $_.Subject -eq $new.id -or $_.Code -eq 'SCH-DUPLICATE' })
        if ($problems.Count) { foreach ($p in $problems) { Write-FinOpsConsole "  ! $($p.Message)" -ForegroundColor Yellow }; Wait-ForecastKey; continue }
        $settings.scheduledItems = if ($index -ge 0) { @(for ($position = 0; $position -lt $items.Count; $position++) { if ($position -eq $index) { $new } else { $items[$position] } }) } else { @($items + $new) }
        Save-ForecastSettingsWithFeedback -Root $Root -Settings $settings; Wait-ForecastKey
    }
}

function Edit-ForecastInputs {
    param([Parameter(Mandatory)][string]$Root, $Session)
    $settings = Get-ForecastStoredSettings -Root $Root
    if ($settings.dataMode -ne 'Manual') { Write-FinOpsConsole '  Switch the source to manual inputs (section 1, M) to enter values by hand.' -ForegroundColor Yellow; Wait-ForecastKey; return }
    while ($true) {
        $inputs = Get-ForecastStoredInputs -Root $Root
        $session = Invoke-ForecastEvaluation -Root $Root -AsOf $(if ($Session) { $Session.AsOf } else { [datetime]::UtcNow })
        $windowMonths = @($session.Model.Window.Rows.Month)
        # Fiscal-year months before the window count as actuals too, so they're listed for entry.
        $fiscalMonths = @($session.Model.FiscalYear.Months | Where-Object { $_ -and [string]::CompareOrdinal([string]$_, [string]$session.Model.Window.Last) -le 0 })
        $months = @(@($windowMonths) + $fiscalMonths + @($inputs.months.month) | Where-Object { $_ } | Sort-Object -Unique)
        Clear-ForecastScreen
        Write-ForecastHeading -Title "Inputs (currency $(if ($inputs.currency) { $inputs.currency } else { 'not set' }); scope '$(ConvertTo-ForecastSafeText $inputs.scopeLabel 60)')"
        Write-FinOpsConsole ('  {0,-8} {1,-13} {2,16} {3,14} {4,16} {5,-9}  {6}' -f 'Month', 'Status', 'Azure usage', 'Other charges', 'Total', 'Review', 'Evidence') -ForegroundColor White
        foreach ($month in $months) {
            $row = @($session.Dataset.Months | Where-Object Month -EQ $month)[0]
            $record = @($inputs.months | Where-Object month -EQ $month)[0]
            $status = if ($record) { $record.status } else { 'Missing' }
            $review = @($session.Dataset.Reviews | Where-Object Subject -EQ $month)[0]
            $other = if ($row) { [decimal]$row.Purchase + [decimal]$row.Adjustment + [decimal]$row.Other } else { 0d }
            $color = switch ($status) { 'Missing' { 'Red' } 'VerifiedZero' { 'Cyan' } default { 'Gray' } }
            $inWindow = if ($month -in $windowMonths) { '' } elseif ($month -in $fiscalMonths) { ' (fiscal year, before the window)' } else { ' (outside window)' }
            Write-FinOpsConsole ('  {0,-8} {1,-13} {2,16} {3,14} {4,16} {5,-9}  {6}{7}' -f $month, $status, $(if ($row -and $null -ne $row.RunRate) { Format-ForecastAmount $row.RunRate } else { '-' }), (Format-ForecastAmount $other), $(if ($row -and $null -ne $row.Headline) { Format-ForecastAmount $row.Headline } else { '-' }), $(if ($review) { $review.Decision } else { '-' }), (ConvertTo-ForecastSafeText $record.evidence 40), $inWindow) -ForegroundColor $color
        }
        Write-FinOpsConsole "  Other billed charges: $(@($inputs.otherCharges).Count). Missing months are never treated as zero; type 'zero' for a verified zero." -ForegroundColor DarkGray
        Write-FinOpsConsole '  E Enter a month   O Add other charge   X Remove other charge   L List other charges   C Currency   S Scope label   A Approve months   B Back' -ForegroundColor DarkGray
        switch (Read-ForecastChoice -Prompt 'Choose' -Valid @('E', 'O', 'X', 'L', 'C', 'S', 'A', 'B') -Default 'B') {
            'E' {
                $month = Read-ForecastText -Prompt 'Month (yyyy-MM)'
                if (-not (Test-ForecastMonthKey $month)) { Write-FinOpsConsole '  Use yyyy-MM.' -ForegroundColor Yellow; Wait-ForecastKey; continue }
                $existing = @($inputs.months | Where-Object month -EQ $month)[0]
                $default = if ($existing -and $existing.status -eq 'VerifiedZero') { 'zero' } elseif ($existing) { [string]$existing.usage } else { '' }
                $value = Read-ForecastText -Prompt 'Pre-credit Azure usage (number, zero, or blank for missing)' -Default $default
                $evidence = Read-ForecastText -Prompt 'Source evidence (invoice, report, or file reference)' -Default $(if ($existing) { $existing.evidence } else { '' })
                try { $null = Set-ForecastInputMonth -Inputs $inputs -Month $month -Value $value -Evidence $evidence; Save-ForecastStoredInputs -Root $Root -Inputs $inputs }
                catch { Write-FinOpsConsole "  $($_.Exception.Message)" -ForegroundColor Yellow; Wait-ForecastKey }
            }
            'O' {
                try {
                    $null = Add-ForecastOtherCharge -Inputs $inputs -Id (Read-ForecastText -Prompt 'Charge ID') -Month (Read-ForecastText -Prompt 'Month (yyyy-MM)') `
                        -Amount (Read-ForecastText -Prompt 'Signed amount (refunds negative)') -Type (Read-ForecastText -Prompt "Type ($($script:ForecastOtherChargeTypes -join ', '))") `
                        -Description (Read-ForecastText -Prompt 'Description' -Default '') -Evidence (Read-ForecastText -Prompt 'Evidence' -Default '')
                    Save-ForecastStoredInputs -Root $Root -Inputs $inputs
                }
                catch { Write-FinOpsConsole "  $($_.Exception.Message)" -ForegroundColor Yellow; Wait-ForecastKey }
            }
            'X' { if (Remove-ForecastOtherCharge -Inputs $inputs -Id (Read-ForecastText -Prompt 'Charge ID to remove')) { Save-ForecastStoredInputs -Root $Root -Inputs $inputs } }
            'L' {
                foreach ($charge in @($inputs.otherCharges | Sort-Object month, id)) { Write-FinOpsConsole ('  {0,-14} {1,-8} {2,-12} {3,14}  {4}' -f (ConvertTo-ForecastSafeText $charge.id 14), $charge.month, $charge.type, (Format-ForecastAmount (Read-ForecastDecimal $charge.amount)), (ConvertTo-ForecastSafeText $charge.description 50)) }
                Wait-ForecastKey
            }
            'C' {
                $currency = (Read-ForecastText -Prompt 'Billing currency (three letters)' -Default $inputs.currency).Trim().ToUpperInvariant()
                if ($currency -match '^[A-Z]{3}$') { $inputs.currency = $currency; Save-ForecastStoredInputs -Root $Root -Inputs $inputs } else { Write-FinOpsConsole '  Use a three-letter code.' -ForegroundColor Yellow; Wait-ForecastKey }
            }
            'S' { $inputs.scopeLabel = ConvertTo-ForecastSafeText (Read-ForecastText -Prompt 'Scope label' -Default $inputs.scopeLabel) 120; Save-ForecastStoredInputs -Root $Root -Inputs $inputs }
            'A' { Show-ForecastExceptions -Root $Root -Session $session -Category 'ManualMonth' }
            default { return }
        }
    }
}
