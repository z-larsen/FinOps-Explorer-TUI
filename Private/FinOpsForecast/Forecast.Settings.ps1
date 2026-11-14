# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers that build objects or write only the private local forecast workspace; nothing in Azure changes.')]
param()

###########################################################################
# FORECAST.SETTINGS.PS1
# WORKSPACE SETTINGS: DEFAULTS, NORMALIZATION, AND VALIDATION
###########################################################################
# Purpose: One settings object drives source configuration, scope, period,
#          assumptions, and workload mapping. Settings round-trip through
#          JSON, so amounts and rates are stored as invariant strings.
###########################################################################

$script:ForecastSettingsVersion = 3
# A forecast can be Ready only with at least this many complete months.
# Shorter lookbacks (down to 3) produce a Preliminary forecast.
$script:ForecastReadyMonths = 12
$script:ForecastMinimumLookbackMonths = 3
# Azure closes a billing period up to 72 hours after it ends, and usage
# charges can still change until the fifth day after it ends. A daily cost
# export rewrites the prior month on each of the first five days of a month
# to match the invoice, so its last copy arrives on day 5. A month counts as
# final from 00:00 UTC on that day: four days after the month ends.
# https://learn.microsoft.com/azure/cost-management-billing/costs/understand-cost-mgt-data
# https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-improved-exports
$script:ForecastDefaultGraceDays = 4

function New-ForecastDefaultSettings {
    [pscustomobject]@{
        schemaVersion  = $script:ForecastSettingsVersion
        dataMode       = 'Exports'
        # excluded: subscriptions taken out of the scope, each with the reason recorded when it was removed.
        scope          = [pscustomobject]@{ kind = 'Subscriptions'; subscriptionIds = @(); billingProfileId = ''; label = ''; excluded = @() }
        period         = [pscustomobject]@{ fiscalYearStartMonth = 1; fiscalYearOffset = 0; lookbackMonths = 12; graceDays = $script:ForecastDefaultGraceDays; staleAfterDays = 35; windowEnd = 'Auto' }
        # showMarketplace lists Marketplace charges in their own report section whether or not includeMarketplace counts them.
        filters        = [pscustomobject]@{ includeMarketplace = $false; includeTax = $false; showMarketplace = $true }
        # reviewAgreementChange asks for a decision on each change between months on different agreements (EA and MCA).
        method         = [pscustomobject]@{ central = 'Median'; lowPercentile = 25; highPercentile = 75; anomalyK = '3'; anomalyMinimumDeviation = '0.05'; minimumRetained = 8; backtestHorizon = 6; reviewAgreementChange = $true }
        workloads      = [pscustomobject]@{ mode = 'Tag'; tagKey = 'workload'; mappingPath = '' }
        sources        = @()
        migration      = [pscustomobject]@{ boundaryDate = '' }
        scheduledItems = @()
    }
}

function Copy-ForecastObject {
    # Deep copy through JSON keeps settings free of shared references.
    param([Parameter(Mandatory)]$InputObject)
    return ($InputObject | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20)
}

function ConvertTo-ForecastSettings {
    # Merges a loaded settings object over the defaults so older files gain
    # new settings without losing the user's values.
    param([AllowNull()]$Loaded)
    $settings = New-ForecastDefaultSettings
    if ($null -eq $Loaded) { return $settings }
    if ($Loaded.schemaVersion -and [int]$Loaded.schemaVersion -gt $script:ForecastSettingsVersion) {
        throw "These settings were saved by a newer version of the forecast (schema $($Loaded.schemaVersion)). Update FinOps Explorer before opening this workspace."
    }
    foreach ($section in 'scope', 'period', 'filters', 'method', 'workloads', 'migration') {
        if ($null -eq $Loaded.$section) { continue }
        foreach ($property in $Loaded.$section.PSObject.Properties) {
            if ($settings.$section.PSObject.Properties.Name -contains $property.Name) { $settings.$section.($property.Name) = $property.Value }
        }
    }
    # The default grace was three days before schema 2 and five days in
    # schema 2, so a stored value equal to its schema's default is that
    # default rather than a choice. Once saved again, any value is kept.
    $loadedVersion = if ($Loaded.schemaVersion) { [int]$Loaded.schemaVersion } else { 1 }
    $earlierDefault = if ($loadedVersion -lt 2) { '3' } elseif ($loadedVersion -eq 2) { '5' } else { $null }
    if ($earlierDefault -and [string]$settings.period.graceDays -eq $earlierDefault) { $settings.period.graceDays = $script:ForecastDefaultGraceDays }
    if ($Loaded.dataMode -in 'Exports', 'Manual') { $settings.dataMode = [string]$Loaded.dataMode }
    $settings.sources = @($Loaded.sources | Where-Object { $null -ne $_ })
    $settings.scheduledItems = @($Loaded.scheduledItems | Where-Object { $null -ne $_ })
    $settings.scope.subscriptionIds = @($settings.scope.subscriptionIds | Where-Object { $_ })
    $settings.scope.excluded = @($settings.scope.excluded | Where-Object { $null -ne $_ })
    $settings.filters.showMarketplace = ConvertTo-ForecastSettingSwitch -Value $settings.filters.showMarketplace -Default $true
    $settings.method.reviewAgreementChange = ConvertTo-ForecastSettingSwitch -Value $settings.method.reviewAgreementChange -Default $true
    return $settings
}

function ConvertTo-ForecastSettingSwitch {
    # A hand-edited "false" must stay false; [bool]'false' would be true.
    param([AllowNull()]$Value, [bool]$Default)
    if ($Value -is [bool]) { return $Value }
    switch -Regex ([string]$Value) {
        '^(?i)(true|yes|1)$' { return $true }
        '^(?i)(false|no|0)$' { return $false }
    }
    return $Default
}

function Update-ForecastScopeExclusions {
    # A subscription chosen for the scope again is no longer left out of it.
    param([Parameter(Mandatory)]$Settings)
    $inScope = @($Settings.scope.subscriptionIds | ForEach-Object { ConvertTo-ForecastSubscriptionId -Value ([string]$_) } | Where-Object { $_ })
    $Settings.scope.excluded = @($Settings.scope.excluded | Where-Object { $_ -and (ConvertTo-ForecastSubscriptionId -Value ([string]$_.subscriptionId)) -notin $inScope })
}

function Get-ForecastMethodNumber {
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Name)
    $value = Read-ForecastDecimal -Value $Settings.method.$Name
    if ($null -eq $value) { throw "Method setting '$Name' isn't a number." }
    return $value
}

function Get-ForecastDefaultMinimumRetained {
    # The default keeps the 8-of-11 share of a 12-month lookback for any
    # lookback length, so a shorter history isn't held to all-or-nothing.
    param([Parameter(Mandatory)][int]$LookbackMonths)
    return [int][math]::Max(1, [math]::Floor(($LookbackMonths - 1) * 8 / 11))
}

function Test-ForecastSettings {
    param([Parameter(Mandatory)]$Settings)
    $issues = [Collections.Generic.List[object]]::new()
    $period = $Settings.period
    if ([int]$period.fiscalYearStartMonth -lt 1 -or [int]$period.fiscalYearStartMonth -gt 12) { $issues.Add((New-ForecastIssue -Code 'SET-FY' -Message 'Fiscal year start month must be 1 to 12.')) }
    if ([int]$period.fiscalYearOffset -notin 0, 1) { $issues.Add((New-ForecastIssue -Code 'SET-FYOFFSET' -Message 'Fiscal year must be the current (0) or next (1) fiscal year.')) }
    if ([int]$period.lookbackMonths -lt $script:ForecastMinimumLookbackMonths -or [int]$period.lookbackMonths -gt 36) { $issues.Add((New-ForecastIssue -Code 'SET-LOOKBACK' -Message "The lookback must be $($script:ForecastMinimumLookbackMonths) to 36 complete months. Under $($script:ForecastReadyMonths), the forecast is Preliminary.")) }
    if ([int]$period.graceDays -lt 0 -or [int]$period.graceDays -gt 10) { $issues.Add((New-ForecastIssue -Code 'SET-GRACE' -Message 'The finalization grace period must be 0 to 10 days.')) }
    if ([int]$period.staleAfterDays -lt 1) { $issues.Add((New-ForecastIssue -Code 'SET-STALE' -Message 'Stale-data age must be at least 1 day.')) }
    if ([string]$period.windowEnd -ne 'Auto' -and -not (Test-ForecastMonthKey -MonthKey ([string]$period.windowEnd))) { $issues.Add((New-ForecastIssue -Code 'SET-WINDOWEND' -Message "The window end must be Auto or a month (yyyy-MM).")) }

    $method = $Settings.method
    $low = Read-ForecastDecimal -Value $method.lowPercentile
    $high = Read-ForecastDecimal -Value $method.highPercentile
    if ($null -eq $low -or $null -eq $high -or $low -lt 0 -or $high -gt 100 -or $low -ge 50 -or $high -le 50) { $issues.Add((New-ForecastIssue -Code 'SET-BAND' -Message 'The sensitivity percentiles must bracket the median: 0 <= low < 50 < high <= 100.')) }
    $k = Read-ForecastDecimal -Value $method.anomalyK
    if ($null -eq $k -or $k -le 0) { $issues.Add((New-ForecastIssue -Code 'SET-ANOMALYK' -Message 'The anomaly multiplier must be greater than zero.')) }
    $minimumDeviation = Read-ForecastDecimal -Value $method.anomalyMinimumDeviation
    if ($null -eq $minimumDeviation -or $minimumDeviation -lt 0) { $issues.Add((New-ForecastIssue -Code 'SET-ANOMALYMIN' -Message 'The minimum anomaly deviation can''t be negative.')) }
    $comparisons = [int]$period.lookbackMonths - 1
    if ([int]$method.minimumRetained -lt 1 -or [int]$method.minimumRetained -gt $comparisons) { $issues.Add((New-ForecastIssue -Code 'SET-RETAINED' -Message "Minimum retained comparisons must be 1 to $comparisons.")) }
    if ($method.central -ne 'Median') { $issues.Add((New-ForecastIssue -Code 'SET-CENTRAL' -Message 'Only the median central estimate is supported.')) }

    if ($Settings.workloads.mode -notin 'Tag', 'ResourceGroup', 'Subscription') { $issues.Add((New-ForecastIssue -Code 'SET-WLMODE' -Message 'Workload mode must be Tag, ResourceGroup, or Subscription.')) }
    if ($Settings.workloads.mode -eq 'Tag' -and [string]::IsNullOrWhiteSpace([string]$Settings.workloads.tagKey)) { $issues.Add((New-ForecastIssue -Code 'SET-TAGKEY' -Message 'Tag workload mode needs a tag key.')) }
    if ([string]$Settings.workloads.tagKey -match '[\p{Cc}"]') { $issues.Add((New-ForecastIssue -Code 'SET-TAGKEY' -Message 'The tag key contains characters that can''t appear in a tag name.')) }

    if ($Settings.scope.kind -notin 'Subscriptions', 'BillingProfile') { $issues.Add((New-ForecastIssue -Code 'SET-SCOPE' -Message 'Scope must be Subscriptions or BillingProfile.')) }
    elseif ($Settings.scope.kind -eq 'Subscriptions') {
        if (@($Settings.scope.subscriptionIds).Count -eq 0) { $issues.Add((New-ForecastIssue -Code 'SET-SCOPE' -Message 'Select at least one subscription.')) }
        foreach ($id in @($Settings.scope.subscriptionIds)) {
            if (-not (ConvertTo-ForecastSubscriptionId -Value $id)) { $issues.Add((New-ForecastIssue -Code 'SET-SCOPE' -Message "'$(ConvertTo-ForecastSafeText $id 60)' isn't a subscription ID.")) }
        }
    }
    elseif ([string]::IsNullOrWhiteSpace([string]$Settings.scope.billingProfileId)) { $issues.Add((New-ForecastIssue -Code 'SET-SCOPE' -Message 'Enter the billing profile ID.')) }
    $inScope = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($Settings.scope.subscriptionIds)) { $normalized = ConvertTo-ForecastSubscriptionId -Value $id; if ($normalized) { [void]$inScope.Add($normalized) } }
    foreach ($exclusion in @($Settings.scope.excluded)) {
        $excludedId = ConvertTo-ForecastSubscriptionId -Value ([string]$exclusion.subscriptionId)
        if (-not $excludedId) { $issues.Add((New-ForecastIssue -Code 'SET-EXCLUDED' -Message "A subscription left out of the scope has no valid subscription ID.")); continue }
        if ([string]::IsNullOrWhiteSpace([string]$exclusion.reason)) { $issues.Add((New-ForecastIssue -Code 'SET-EXCLUDED' -Message "Subscription $excludedId was left out of the scope without a reason.")) }
        if ($inScope.Contains($excludedId)) { $issues.Add((New-ForecastIssue -Code 'SET-EXCLUDED' -Message "Subscription $excludedId is in the scope and also listed as left out of it.")) }
    }

    if ($Settings.migration.boundaryDate -and -not (ConvertFrom-ForecastDate -Value $Settings.migration.boundaryDate)) { $issues.Add((New-ForecastIssue -Code 'SET-BOUNDARY' -Message 'The migration boundary must be a date (yyyy-MM-dd).')) }

    if ($Settings.dataMode -eq 'Exports') {
        if (@($Settings.sources).Count -eq 0) { $issues.Add((New-ForecastIssue -Code 'SET-SOURCE' -Message 'Add at least one export source.')) }
        $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($source in @($Settings.sources)) {
            if (-not $ids.Add([string]$source.id)) { $issues.Add((New-ForecastIssue -Code 'SET-SOURCE' -Message "Source ID '$($source.id)' is used more than once.")) }
            foreach ($issue in @(Test-ForecastSourceDefinition -Source $source)) { $issues.Add($issue) }
        }
    }
    return $issues.ToArray()
}

function Test-ForecastSourceDefinition {
    param([Parameter(Mandatory)]$Source)
    $issues = [Collections.Generic.List[object]]::new()
    $label = ConvertTo-ForecastSafeText -Text ([string]$Source.label) -MaxLength 60
    if ([string]$Source.id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { $issues.Add((New-ForecastIssue -Code 'SET-SOURCE' -Message "Source '$label' needs an ID of letters, digits, dots, dashes, or underscores.")) }
    if ($Source.agreement -and $Source.agreement -notin 'Auto', 'EA', 'MCA', 'FOCUS') { $issues.Add((New-ForecastIssue -Code 'SET-SOURCE' -Message "Source '$label' has an unknown schema setting.")) }
    switch ([string]$Source.kind) {
        'LocalFolder' {
            if ([string]::IsNullOrWhiteSpace([string]$Source.path)) { $issues.Add((New-ForecastIssue -Code 'SET-SOURCE' -Message "Local source '$label' needs a folder path.")) }
        }
        'AzureStorage' {
            if ([string]$Source.storageResourceId -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Storage/storageAccounts/[a-z0-9]{3,24}$') {
                $issues.Add((New-ForecastIssue -Code 'SET-SOURCE' -Message "Storage source '$label' needs a storage account resource ID."))
            }
            $container = [string]$Source.container
            if ($container -cnotmatch '^[a-z0-9](?:[a-z0-9-]{1,61})[a-z0-9]\z' -or $container.Contains('--')) { $issues.Add((New-ForecastIssue -Code 'SET-SOURCE' -Message "Storage source '$label' needs a valid container name.")) }
            if ([string]$Source.prefix -match '(?:^|/)\.{1,2}(?:/|$)|[\\\p{Cc}\p{Cf}]') { $issues.Add((New-ForecastIssue -Code 'SET-SOURCE' -Message "Storage source '$label' has an unsafe folder prefix.")) }
        }
        'CostDetails' {
            try { $null = Get-ForecastCostDetailsScope -Scope ([string]$Source.scope) }
            catch { $issues.Add((New-ForecastIssue -Code 'SET-SOURCE' -Message "Cost Details source '$label': $($_.Exception.Message)")) }
            $days = 0
            if ($null -ne $Source.chunkDays -and [string]$Source.chunkDays -ne '' -and (-not [int]::TryParse([string]$Source.chunkDays, [ref]$days) -or $days -lt 1 -or $days -gt 31)) {
                $issues.Add((New-ForecastIssue -Code 'SET-SOURCE' -Message "Cost Details source '$label' needs 1 to 31 days per report."))
            }
            foreach ($name in 'fromMonth', 'toMonth') {
                # A fromMonth of Auto follows the forecast period; see Get-ForecastCostDetailsMonths.
                if ($name -eq 'fromMonth' -and [string]$Source.$name -eq 'Auto') { continue }
                if ([string]$Source.$name -and -not (Test-ForecastMonthKey -MonthKey ([string]$Source.$name))) { $issues.Add((New-ForecastIssue -Code 'SET-SOURCE' -Message "Cost Details source '$label' has an invalid $name; use yyyy-MM$(if ($name -eq 'fromMonth') { ' or Auto' }).")) }
            }
            if ((Test-ForecastMonthKey -MonthKey ([string]$Source.fromMonth)) -and (Test-ForecastMonthKey -MonthKey ([string]$Source.toMonth)) -and [string]::CompareOrdinal([string]$Source.fromMonth, [string]$Source.toMonth) -gt 0) {
                $issues.Add((New-ForecastIssue -Code 'SET-SOURCE' -Message "Cost Details source '$label' has a first month after its last month."))
            }
            if ($Source.agreement -eq 'FOCUS') { $issues.Add((New-ForecastIssue -Code 'SET-SOURCE' -Message "Cost Details source '$label' returns EA or MCA columns; set its schema to Auto, EA, or MCA.")) }
        }
        default { $issues.Add((New-ForecastIssue -Code 'SET-SOURCE' -Message "Source '$label' must be AzureStorage, LocalFolder, or CostDetails.")) }
    }
    return $issues.ToArray()
}

function Get-ForecastScopeKey {
    # Identifies the analysis scope in review keys, so decisions made for one
    # scope never apply to another.
    param([Parameter(Mandatory)]$Settings)
    if ($Settings.scope.kind -eq 'BillingProfile') { return 'bp:' + ([string]$Settings.scope.billingProfileId).Trim().ToLowerInvariant() }
    $ids = @($Settings.scope.subscriptionIds | ForEach-Object { ConvertTo-ForecastSubscriptionId -Value $_ } | Where-Object { $_ } | Sort-Object -Unique)
    return 'subs:' + (Get-ForecastHash -Text ($ids -join ',') -Length 12)
}

function Get-ForecastIngestProfile {
    # Settings that change what a run's cached cells contain. A change here
    # makes the next refresh re-read every run.
    param([Parameter(Mandatory)]$Settings)
    # The tag value is captured in every mode, so switching workload modes
    # doesn't force a re-read. Source identity and interpretation do.
    $values = [ordered]@{
        version      = 6
        tagKey       = ([string]$Settings.workloads.tagKey).Trim()
        boundaryDate = [string]$Settings.migration.boundaryDate
        sources      = @($Settings.sources | Sort-Object id | ForEach-Object {
                $entry = [ordered]@{
                    id = [string]$_.id; kind = [string]$_.kind; path = [string]$_.path
                    storageResourceId = [string]$_.storageResourceId; container = [string]$_.container
                    prefix = [string]$_.prefix; agreement = [string]$_.agreement
                }
                # Only Cost Details sources carry a scope, so existing export workspaces keep their hash.
                if ([string]$_.kind -eq 'CostDetails') { $entry.scope = ([string]$_.scope).Trim().TrimEnd('/').ToLowerInvariant() }
                $entry
            })
    }
    # Cost Details months beyond the API's reach can't be read again, so their
    # records are tied only to what changes their content: their own source,
    # the tag key, and the boundary. Adding or editing another source keeps them.
    $sourceHashes = @{}
    foreach ($entry in $values.sources) {
        $scoped = [ordered]@{ version = $values.version; tagKey = $values.tagKey; boundaryDate = $values.boundaryDate; source = $entry }
        $sourceHashes[[string]$entry.id] = Get-ForecastHash -Text ($scoped | ConvertTo-Json -Depth 5 -Compress) -Length 16
    }
    return [pscustomobject]@{ Values = $values; Hash = Get-ForecastHash -Text (($values | ConvertTo-Json -Depth 5 -Compress)) -Length 16; SourceHashes = $sourceHashes }
}
