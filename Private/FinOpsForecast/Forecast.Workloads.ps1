# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers that build objects or write only the private local forecast workspace; nothing in Azure changes.')]
param()

###########################################################################
# FORECAST.WORKLOADS.PS1
# WORKLOAD GROWTH ANALYSIS
###########################################################################
# A workload is identified by a tag value, a resource group, or a
# subscription (the workload mode), optionally overridden by a mapping CSV
# with stable IDs and display names. The same mapping applies to every month
# in the lookback, so the population stays consistent.
#
# Definitions (run-rate charges only, 30-day normalized):
# - Change               = R(last month) - R(first month)
# - Growth               = Change / R(first month); undefined when R(first) <= 0
# - Contribution share   = Change / net change across all workloads;
#                          undefined when the net change is under 0.01
# - Largest increase     = the largest positive R(m) - R(m-1), earliest month on ties
# Ties in every ranking fall back to the workload ID in ordinal order.
###########################################################################

$script:ForecastMappingColumns = @('MatchType', 'MatchValue', 'WorkloadId', 'WorkloadName')

function ConvertTo-ForecastResourceGroupKey {
    param([AllowNull()][string]$SubscriptionId, [AllowNull()][string]$ResourceGroup)
    $sub = ConvertTo-ForecastSubscriptionId -Value $SubscriptionId
    if (-not $sub -or [string]::IsNullOrWhiteSpace($ResourceGroup)) { return $null }
    return "/subscriptions/$sub/resourcegroups/$($ResourceGroup.Trim().ToLowerInvariant())"
}

function Import-ForecastWorkloadMapping {
    # Reads and validates a mapping CSV. Rules are matched case-insensitively.
    param([AllowNull()][string]$Path)
    $result = [pscustomobject]@{ Rules = @(); Issues = @(); Version = ''; Path = $Path }
    if ([string]::IsNullOrWhiteSpace($Path)) { return $result }
    $issues = [Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $result.Issues = @(New-ForecastIssue -Code 'MAP-FILE' -Message "The workload mapping file wasn't found: $(ConvertTo-ForecastSafeText $Path 200)")
        return $result
    }
    $text = [IO.File]::ReadAllText($Path)
    $result.Version = Get-ForecastHash -Text $text
    $rows = @($text | ConvertFrom-Csv)
    if ($rows.Count -eq 0) { $result.Issues = @(New-ForecastIssue -Code 'MAP-EMPTY' -Severity 'Warn' -Message 'The workload mapping file has no rules.'); return $result }
    $header = @($rows[0].PSObject.Properties.Name)
    $missing = @($script:ForecastMappingColumns | Where-Object { $_ -notin $header })
    if ($missing.Count) { $result.Issues = @(New-ForecastIssue -Code 'MAP-COLUMNS' -Message "The workload mapping file is missing column(s): $($missing -join ', ').") ; return $result }

    $rules = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $names = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $line = 1
    foreach ($row in $rows) {
        $line++
        $type = ([string]$row.MatchType).Trim()
        $value = ([string]$row.MatchValue).Trim()
        $id = ([string]$row.WorkloadId).Trim()
        $name = ConvertTo-ForecastSafeText -Text ([string]$row.WorkloadName) -MaxLength 120
        if ($type -notin 'Tag', 'ResourceGroup', 'Subscription') { $issues.Add((New-ForecastIssue -Code 'MAP-TYPE' -Message "Mapping line ${line}: MatchType must be Tag, ResourceGroup, or Subscription.")); continue }
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$') { $issues.Add((New-ForecastIssue -Code 'MAP-ID' -Message "Mapping line ${line}: WorkloadId must be 1-128 letters, digits, or . _ : / -.")); continue }
        if ($value.Length -eq 0) { $issues.Add((New-ForecastIssue -Code 'MAP-VALUE' -Message "Mapping line ${line}: MatchValue is empty.")); continue }
        if ($type -eq 'Subscription') {
            $value = ConvertTo-ForecastSubscriptionId -Value $value
            if (-not $value) { $issues.Add((New-ForecastIssue -Code 'MAP-VALUE' -Message "Mapping line ${line}: MatchValue isn't a subscription ID.")); continue }
        }
        elseif ($type -eq 'ResourceGroup') {
            $parsed = if ($value -match '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/?$') { ConvertTo-ForecastResourceGroupKey -SubscriptionId $Matches[1] -ResourceGroup $Matches[2] }
            elseif ($value -match '^([0-9a-fA-F-]{36})/([^/]+)$') { ConvertTo-ForecastResourceGroupKey -SubscriptionId $Matches[1] -ResourceGroup $Matches[2] }
            else { $null }
            if (-not $parsed) { $issues.Add((New-ForecastIssue -Code 'MAP-VALUE' -Message "Mapping line ${line}: use /subscriptions/<id>/resourceGroups/<name> or <subscription-id>/<name>.")); continue }
            $value = $parsed
        }
        if (-not $seen.Add("$type|$value")) { $issues.Add((New-ForecastIssue -Code 'MAP-DUPLICATE' -Message "Mapping line ${line}: $type '$(ConvertTo-ForecastSafeText $value 120)' is mapped more than once.")); continue }
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $id }
        if ($names.ContainsKey($id) -and $names[$id] -cne $name) { $issues.Add((New-ForecastIssue -Code 'MAP-NAME' -Message "Mapping line ${line}: WorkloadId '$id' already has the name '$($names[$id])'.")); continue }
        $names[$id] = $name
        $rules.Add([pscustomobject]@{ MatchType = $type; MatchValue = $value; WorkloadId = $id; WorkloadName = $name })
    }
    $result.Rules = $rules.ToArray()
    $result.Issues = $issues.ToArray()
    return $result
}

function New-ForecastWorkloadResolver {
    param([Parameter(Mandatory)]$Settings, [AllowEmptyCollection()][object[]]$Rules, [Collections.IDictionary]$SubscriptionNames)
    $byType = @{
        Tag           = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        ResourceGroup = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        Subscription  = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    }
    foreach ($rule in @($Rules)) { $byType[$rule.MatchType][$rule.MatchValue] = $rule }
    [pscustomobject]@{ Mode = [string]$Settings.workloads.mode; Rules = $byType; Names = $SubscriptionNames; Memo = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal) }
}

function Resolve-ForecastWorkload {
    # Precedence: tag rule, resource-group rule, subscription rule, then the
    # workload mode's default identity, then Unmapped for that subscription.
    param([Parameter(Mandatory)]$Resolver, [Parameter(Mandatory)]$Cell)
    $sub = [string]$Cell.SubscriptionId
    $rgKey = ConvertTo-ForecastResourceGroupKey -SubscriptionId $sub -ResourceGroup ([string]$Cell.ResourceGroup)
    $tag = [string]$Cell.Tag
    $memoKey = "$sub|$rgKey|$tag"
    if ($Resolver.Memo.ContainsKey($memoKey)) { return $Resolver.Memo[$memoKey] }
    $subName = if ($Resolver.Names -and $Resolver.Names.ContainsKey($sub)) { [string]$Resolver.Names[$sub] } else { $sub }
    $resolved = $null
    if ($tag -and $Resolver.Rules.Tag.ContainsKey($tag)) { $rule = $Resolver.Rules.Tag[$tag]; $resolved = [pscustomobject]@{ Id = $rule.WorkloadId; Name = $rule.WorkloadName; Mapped = $true; Source = 'Mapping (tag)' } }
    elseif ($rgKey -and $Resolver.Rules.ResourceGroup.ContainsKey($rgKey)) { $rule = $Resolver.Rules.ResourceGroup[$rgKey]; $resolved = [pscustomobject]@{ Id = $rule.WorkloadId; Name = $rule.WorkloadName; Mapped = $true; Source = 'Mapping (resource group)' } }
    elseif ($sub -and $Resolver.Rules.Subscription.ContainsKey($sub)) { $rule = $Resolver.Rules.Subscription[$sub]; $resolved = [pscustomobject]@{ Id = $rule.WorkloadId; Name = $rule.WorkloadName; Mapped = $true; Source = 'Mapping (subscription)' } }
    else {
        switch ($Resolver.Mode) {
            'Tag' { if ($tag) { $resolved = [pscustomobject]@{ Id = "tag:$tag"; Name = $tag; Mapped = $true; Source = 'Tag' } } }
            'ResourceGroup' { if ($rgKey) { $resolved = [pscustomobject]@{ Id = $rgKey; Name = "$(([string]$Cell.ResourceGroup).Trim()) ($subName)"; Mapped = $true; Source = 'Resource group' } } }
            'Subscription' { if ($sub) { $resolved = [pscustomobject]@{ Id = $sub; Name = $subName; Mapped = $true; Source = 'Subscription' } } }
        }
    }
    if (-not $resolved) {
        $id = if ($sub) { "unmapped:$sub" } else { 'unmapped:none' }
        $resolved = [pscustomobject]@{ Id = $id; Name = "Unmapped ($subName)"; Mapped = $false; Source = 'Unmapped' }
    }
    $Resolver.Memo[$memoKey] = $resolved
    return $resolved
}

function Get-ForecastWorkloadAnalysis {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Cells,
        [Parameter(Mandatory)][string[]]$Months,
        [Parameter(Mandatory)]$Settings,
        [AllowEmptyCollection()][object[]]$Rules,
        [Collections.IDictionary]$SubscriptionNames
    )
    $monthIndex = @{}
    for ($i = 0; $i -lt $Months.Count; $i++) { $monthIndex[$Months[$i]] = $i }
    $resolver = New-ForecastWorkloadResolver -Settings $Settings -Rules $Rules -SubscriptionNames $SubscriptionNames
    $workloads = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $purchases = [Collections.Generic.List[object]]::new()

    foreach ($cell in $Cells) {
        if (-not $monthIndex.ContainsKey([string]$cell.Month)) { continue }
        $index = $monthIndex[[string]$cell.Month]
        if ($cell.Stream -eq 'Purchase') {
            $purchases.Add([pscustomobject]@{ Month = $cell.Month; SubscriptionId = $cell.SubscriptionId; ChargeType = $cell.ChargeType; CommitmentId = $cell.CommitmentId; Cost = [decimal]$cell.Cost })
            continue
        }
        if ($cell.Stream -ne 'RunRate') { continue }
        $identity = Resolve-ForecastWorkload -Resolver $resolver -Cell $cell
        if (-not $workloads.ContainsKey($identity.Id)) {
            # Build the per-month sets explicitly; emitting an empty set from a
            # pipeline would unroll it into nothing.
            $subscriptionSets = [Collections.Generic.List[object]]::new()
            $scopeSets = [Collections.Generic.List[object]]::new()
            foreach ($m in $Months) {
                $subscriptionSets.Add([Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase))
                $scopeSets.Add([Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase))
            }
            $workloads[$identity.Id] = [pscustomobject]@{
                Id = $identity.Id; Name = $identity.Name; Mapped = $identity.Mapped; Source = $identity.Source
                Cost = [decimal[]]::new($Months.Count); Rows = [long[]]::new($Months.Count); Covered = [long[]]::new($Months.Count)
                OnDemandEquivalent = [decimal[]]::new($Months.Count)
                Subscriptions = $subscriptionSets; Scopes = $scopeSets
            }
        }
        $workload = $workloads[$identity.Id]
        $workload.Cost[$index] += [decimal]$cell.Cost
        $workload.Rows[$index] += [long]$cell.Rows
        $workload.Covered[$index] += [long]$cell.CoveredRows
        if ($null -ne $cell.OnDemandEquivalent) { $workload.OnDemandEquivalent[$index] += [decimal]$cell.OnDemandEquivalent }
        if ([decimal]$cell.Cost -ne 0 -or [long]$cell.Rows -gt 0) {
            if ($cell.SubscriptionId) { [void]$workload.Subscriptions[$index].Add([string]$cell.SubscriptionId) }
            [void]$workload.Scopes[$index].Add("$($cell.Agreement)|$($cell.OriginalScope)")
        }
    }

    $last = $Months.Count - 1
    $results = [Collections.Generic.List[object]]::new()
    foreach ($workload in $workloads.Values) {
        $rates = [decimal[]]::new($Months.Count)
        for ($i = 0; $i -le $last; $i++) { $rates[$i] = ($workload.Cost[$i] * 30d) / [decimal](Get-ForecastDaysInMonth -MonthKey $Months[$i]) }
        $first = $rates[0]; $final = $rates[$last]
        $change = $final - $first
        $growth = if ($first -gt 0) { $change / $first } else { $null }
        $largestMonth = $null; $largestAmount = $null
        for ($i = 1; $i -le $last; $i++) {
            $increase = $rates[$i] - $rates[$i - 1]
            if ($increase -gt 0 -and ($null -eq $largestAmount -or $increase -gt $largestAmount)) { $largestAmount = $increase; $largestMonth = $Months[$i] }
        }
        $spend = 0d
        foreach ($value in $workload.Cost) { $spend += $value }
        $flags = [Collections.Generic.List[string]]::new()
        $hasFirst = $workload.Rows[0] -gt 0 -or $workload.Cost[0] -ne 0
        $hasLast = $workload.Rows[$last] -gt 0 -or $workload.Cost[$last] -ne 0
        if (-not $hasFirst -and $hasLast) { $flags.Add('New') }
        if ($hasFirst -and -not $hasLast) { $flags.Add('Retired') }
        $notes = [Collections.Generic.List[string]]::new()
        if ($hasFirst -and $hasLast) {
            if (-not $workload.Subscriptions[0].SetEquals($workload.Subscriptions[$last])) {
                $flags.Add('Moved')
                $notes.Add('The subscriptions carrying this workload changed between the first and last month.')
            }
            elseif (-not $workload.Scopes[0].SetEquals($workload.Scopes[$last])) {
                $flags.Add('Moved')
                $notes.Add('The billing scope changed (for example, an EA to MCA transition).')
            }
        }
        if (-not $workload.Mapped) { $flags.Add('Unmapped') }
        $coveredFirst = if ($workload.Rows[0] -gt 0) { [decimal]$workload.Covered[0] / [decimal]$workload.Rows[0] } else { $null }
        $coveredLast = if ($workload.Rows[$last] -gt 0) { [decimal]$workload.Covered[$last] / [decimal]$workload.Rows[$last] } else { $null }
        if ($null -ne $coveredFirst -and $null -ne $coveredLast -and [math]::Abs($coveredLast - $coveredFirst) -ge 0.2d) {
            $notes.Add("Reservation or savings plan coverage moved from $(Format-ForecastPercent $coveredFirst 0) to $(Format-ForecastPercent $coveredLast 0) of usage rows. Covered usage shows zero actual cost, so part of this change may reflect coverage rather than demand. Purchases are listed separately and never allocated here.")
        }
        elseif ($null -ne $coveredLast -and $coveredLast -gt 0) {
            $notes.Add("$(Format-ForecastPercent $coveredLast 0) of usage rows in the last month were covered by a reservation or savings plan and show zero actual cost.")
        }
        $results.Add([pscustomobject]@{
                WorkloadId = $workload.Id; WorkloadName = $workload.Name; Source = $workload.Source; Mapped = $workload.Mapped
                Flags = ($flags -join ', '); FirstMonth = $Months[0]; LastMonth = $Months[$last]
                FirstRunRate = $first; LastRunRate = $final; Change = $change; Growth = $growth; ContributionShare = $null
                LargestIncreaseMonth = $largestMonth; LargestIncreaseAmount = $largestAmount
                LookbackSpend = $spend; LatestMonthSpend = $workload.Cost[$last]
                CoveredShareFirst = $coveredFirst; CoveredShareLast = $coveredLast
                OnDemandEquivalentLast = $workload.OnDemandEquivalent[$last]
                SubscriptionsLast = (@($workload.Subscriptions[$last] | Sort-Object -CaseSensitive) -join ';')
                Notes = ($notes -join ' '); MonthlyRunRate = $rates
            })
    }
    # Different workloads can share a display name, such as two subscriptions
    # both named Pay-As-You-Go. A short ID keeps them apart on screen; the
    # stable WorkloadId is unchanged.
    foreach ($group in @($results | Group-Object { ([string]$_.WorkloadName).ToLowerInvariant() } | Where-Object Count -GT 1)) {
        foreach ($result in $group.Group) {
            $guid = [regex]::Match([string]$result.WorkloadId, '[0-9a-fA-F]{8}(?=-[0-9a-fA-F]{4}-)')
            $short = if ($guid.Success) { $guid.Value.ToLowerInvariant() } else { Get-ForecastHash -Text ([string]$result.WorkloadId) -Length 8 }
            $result.WorkloadName = "$($result.WorkloadName) [$short]"
        }
    }
    $netChange = 0d
    foreach ($result in $results) { $netChange += [decimal]$result.Change }
    foreach ($result in $results) { $result.ContributionShare = if ([math]::Abs($netChange) -ge 0.01d) { [decimal]$result.Change / $netChange } else { $null } }

    $byId = { param($a, $b) [string]::CompareOrdinal([string]$a.WorkloadId, [string]$b.WorkloadId) }
    $byChange = Invoke-ForecastSort -Items $results.ToArray() -Comparison { param($a, $b) $c = Compare-ForecastDecimalDescending $a.Change $b.Change; if ($c) { $c } else { & $byId $a $b } }
    [pscustomobject]@{
        Mode = [string]$Settings.workloads.mode; TagKey = [string]$Settings.workloads.tagKey
        Months = $Months; NetChange = $netChange; Workloads = $byChange
        UnmappedCount = @($results | Where-Object { -not $_.Mapped }).Count
        Purchases = $purchases.ToArray()
    }
}

function Get-ForecastWorkloadView {
    # Returns the workloads ordered for one view. Ties resolve by workload ID.
    param([Parameter(Mandatory)]$Analysis, [ValidateSet('Change', 'Spend', 'Growth', 'LargestIncrease')][string]$View = 'Change', [string]$Filter)
    $items = @($Analysis.Workloads)
    if ($Filter) { $items = @($items | Where-Object { $_.WorkloadName -like "*$Filter*" -or $_.WorkloadId -like "*$Filter*" -or $_.Flags -like "*$Filter*" }) }
    $byId = { param($a, $b) [string]::CompareOrdinal([string]$a.WorkloadId, [string]$b.WorkloadId) }
    $comparison = switch ($View) {
        'Change' { { param($a, $b) $c = Compare-ForecastDecimalDescending $a.Change $b.Change; if ($c) { $c } else { & $byId $a $b } } }
        'Spend' { { param($a, $b) $c = Compare-ForecastDecimalDescending $a.LookbackSpend $b.LookbackSpend; if ($c) { $c } else { & $byId $a $b } } }
        'Growth' { { param($a, $b) $c = Compare-ForecastDecimalDescending $a.Growth $b.Growth; if ($c) { $c } else { & $byId $a $b } } }
        'LargestIncrease' {
            { param($a, $b)
                $c = Compare-ForecastDecimalDescending $a.LargestIncreaseAmount $b.LargestIncreaseAmount
                if (-not $c -and $a.LargestIncreaseMonth -and $b.LargestIncreaseMonth) { $c = [string]::CompareOrdinal([string]$a.LargestIncreaseMonth, [string]$b.LargestIncreaseMonth) }
                if ($c) { $c } else { & $byId $a $b } }
        }
    }
    return , (Invoke-ForecastSort -Items $items -Comparison $comparison)
}
