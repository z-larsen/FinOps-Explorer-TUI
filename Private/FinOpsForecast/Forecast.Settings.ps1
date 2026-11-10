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

$script:ForecastSettingsVersion = 1

function New-ForecastDefaultSettings {
    [pscustomobject]@{
        schemaVersion  = $script:ForecastSettingsVersion
        dataMode       = 'Exports'
        scope          = [pscustomobject]@{ kind = 'Subscriptions'; subscriptionIds = @(); billingProfileId = ''; label = '' }
        period         = [pscustomobject]@{ fiscalYearStartMonth = 1; fiscalYearOffset = 0; lookbackMonths = 12; graceDays = 3; staleAfterDays = 35; windowEnd = 'Auto' }
        filters        = [pscustomobject]@{ includeMarketplace = $false; includeTax = $false }
        method         = [pscustomobject]@{ central = 'Median'; lowPercentile = 25; highPercentile = 75; anomalyK = '3'; anomalyMinimumDeviation = '0.05'; minimumRetained = 8; backtestHorizon = 6 }
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
    if ($Loaded.dataMode -in 'Exports', 'Manual') { $settings.dataMode = [string]$Loaded.dataMode }
    $settings.sources = @($Loaded.sources | Where-Object { $null -ne $_ })
    $settings.scheduledItems = @($Loaded.scheduledItems | Where-Object { $null -ne $_ })
    $settings.scope.subscriptionIds = @($settings.scope.subscriptionIds | Where-Object { $_ })
    return $settings
}

function Get-ForecastMethodNumber {
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Name)
    $value = Read-ForecastDecimal -Value $Settings.method.$Name
    if ($null -eq $value) { throw "Method setting '$Name' isn't a number." }
    return $value
}

function Test-ForecastSettings {
    param([Parameter(Mandatory)]$Settings)
    $issues = [Collections.Generic.List[object]]::new()
    $period = $Settings.period
    if ([int]$period.fiscalYearStartMonth -lt 1 -or [int]$period.fiscalYearStartMonth -gt 12) { $issues.Add((New-ForecastIssue -Code 'SET-FY' -Message 'Fiscal year start month must be 1 to 12.')) }
    if ([int]$period.fiscalYearOffset -notin 0, 1) { $issues.Add((New-ForecastIssue -Code 'SET-FYOFFSET' -Message 'Fiscal year must be the current (0) or next (1) fiscal year.')) }
    if ([int]$period.lookbackMonths -lt 12 -or [int]$period.lookbackMonths -gt 36) { $issues.Add((New-ForecastIssue -Code 'SET-LOOKBACK' -Message 'The lookback must be 12 to 36 complete months.')) }
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
        default { $issues.Add((New-ForecastIssue -Code 'SET-SOURCE' -Message "Source '$label' must be AzureStorage or LocalFolder.")) }
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
                [ordered]@{
                    id = [string]$_.id; kind = [string]$_.kind; path = [string]$_.path
                    storageResourceId = [string]$_.storageResourceId; container = [string]$_.container
                    prefix = [string]$_.prefix; agreement = [string]$_.agreement
                }
            })
    }
    return [pscustomobject]@{ Values = $values; Hash = Get-ForecastHash -Text (($values | ConvertTo-Json -Depth 5 -Compress)) -Length 16 }
}
