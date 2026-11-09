# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
param()

###########################################################################
# FORECAST.SCHEMA.PS1
# EA, MCA, AND FOCUS COST DETAIL SCHEMAS
###########################################################################
# Purpose: Detect which cost-details schema a file uses, map its columns
#          explicitly, and classify each row's charge type, publisher, and
#          pricing model.
#
# Sources (Microsoft Learn):
# - EA:    https://learn.microsoft.com/azure/cost-management-billing/dataset-schema/cost-usage-details-ea
# - MCA:   https://learn.microsoft.com/azure/cost-management-billing/dataset-schema/cost-usage-details-mca
# - FOCUS: https://learn.microsoft.com/azure/cost-management-billing/dataset-schema/cost-usage-details-focus
#
# Pre-credit cost is CostInBillingCurrency (EA), costInBillingCurrency (MCA),
# or BilledCost (FOCUS): "cost of the charge in the billing currency before
# credits or taxes". Amortized datasets are rejected because they spread
# purchases instead of showing what was billed.
###########################################################################

$script:ForecastColumnCandidates = @{
    Classic = [ordered]@{
        Date             = @('Date')
        SubscriptionId   = @('SubscriptionId')
        SubscriptionName = @('SubscriptionName')
        ResourceGroup    = @('ResourceGroup', 'ResourceGroupName')
        Tags             = @('Tags')
        Cost             = @('CostInBillingCurrency')
        Currency         = @('BillingCurrencyCode', 'BillingCurrency')
        ChargeType       = @('ChargeType')
        PublisherType    = @('PublisherType')
        PublisherName    = @('PublisherName')
        PricingModel     = @('PricingModel')
        UnitPrice        = @('UnitPrice')
        Quantity         = @('Quantity')
        BillingProfileId = @('BillingProfileId')
        BillingAccountId = @('BillingAccountId')
        CommitmentId     = @('ReservationId', 'BenefitId', 'ProductOrderId')
        Frequency        = @('Frequency')
    }
    FOCUS   = [ordered]@{
        Date             = @('ChargePeriodStart')
        SubscriptionId   = @('SubAccountId')
        SubscriptionName = @('SubAccountName')
        ResourceGroup    = @('x_ResourceGroupName')
        Tags             = @('Tags')
        Cost             = @('BilledCost')
        Currency         = @('BillingCurrency')
        ChargeType       = @('ChargeCategory')
        ChargeClass      = @('ChargeClass')
        PublisherType    = @('x_PublisherCategory')
        PublisherName    = @('PublisherName')
        PricingModel     = @('CommitmentDiscountType')
        PricingCategory  = @('PricingCategory')
        ContractedCost   = @('ContractedCost')
        BillingProfileId = @('x_BillingProfileId')
        BillingAccountId = @('BillingAccountId')
        Agreement        = @('x_BillingAccountAgreement')
        CommitmentId     = @('CommitmentDiscountId')
        Frequency        = @('ChargeFrequency')
    }
}
$script:ForecastRequiredColumns = @('Date', 'SubscriptionId', 'Cost', 'Currency', 'ChargeType')
$script:ForecastSupportedDatasets = @('ActualCost', 'FocusCost', 'Usage')

function Get-ForecastSchemaKind {
    # Returns EA, MCA, FOCUS, or $null with a reason.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Header,
        [string]$ManifestType,
        [ValidateSet('Auto', 'EA', 'MCA', 'FOCUS')][string]$Override = 'Auto'
    )
    if ($ManifestType -and $ManifestType -notin $script:ForecastSupportedDatasets) {
        $reason = if ($ManifestType -match 'Amortized') { 'Amortized datasets spread purchases over time. Export ActualCost or FocusCost for billed, pre-credit cost.' } else { "Dataset '$ManifestType' isn't a cost-details dataset this forecast supports." }
        return [pscustomobject]@{ Kind = $null; Reason = $reason }
    }
    if ($Override -ne 'Auto') { return [pscustomobject]@{ Kind = $Override; Reason = 'Set on the source.' } }
    $insensitive = [Collections.Generic.HashSet[string]]::new([string[]]$Header, [StringComparer]::OrdinalIgnoreCase)
    if ($ManifestType -eq 'FocusCost' -or ($insensitive.Contains('BilledCost') -and $insensitive.Contains('ChargeCategory'))) {
        return [pscustomobject]@{ Kind = 'FOCUS'; Reason = 'FOCUS columns (BilledCost, ChargeCategory).' }
    }
    $sensitive = [Collections.Generic.HashSet[string]]::new([string[]]$Header, [StringComparer]::Ordinal)
    if ($sensitive.Contains('costInBillingCurrency')) { return [pscustomobject]@{ Kind = 'MCA'; Reason = 'MCA column casing (costInBillingCurrency).' } }
    if ($sensitive.Contains('CostInBillingCurrency')) { return [pscustomobject]@{ Kind = 'EA'; Reason = 'EA column casing (CostInBillingCurrency).' } }
    return [pscustomobject]@{ Kind = $null; Reason = 'No CostInBillingCurrency, costInBillingCurrency, or BilledCost column was found.' }
}

function Resolve-ForecastColumnIndex {
    # Maps canonical columns to zero-based header positions. Header matching
    # is case-insensitive; the schema kind was already decided from casing.
    param([Parameter(Mandatory)][string[]]$Header, [Parameter(Mandatory)][ValidateSet('EA', 'MCA', 'FOCUS')][string]$Kind)
    $candidates = if ($Kind -eq 'FOCUS') { $script:ForecastColumnCandidates.FOCUS } else { $script:ForecastColumnCandidates.Classic }
    $positions = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
    for ($i = 0; $i -lt $Header.Count; $i++) {
        $name = ([string]$Header[$i]).Trim().TrimStart([char]0xFEFF)
        if ($name -and -not $positions.ContainsKey($name)) { $positions[$name] = $i }
    }
    $map = @{}
    $commitmentColumns = [Collections.Generic.List[int]]::new()
    foreach ($canonical in $candidates.Keys) {
        foreach ($candidate in $candidates[$canonical]) {
            if ($positions.ContainsKey($candidate)) {
                if ($canonical -eq 'CommitmentId') { $commitmentColumns.Add($positions[$candidate]); continue }
                $map[$canonical] = $positions[$candidate]
                break
            }
        }
    }
    $missing = @($script:ForecastRequiredColumns | Where-Object { -not $map.ContainsKey($_) })
    [pscustomobject]@{
        Map               = $map
        CommitmentColumns = $commitmentColumns.ToArray()
        Missing           = $missing
    }
}

function ConvertTo-ForecastChargeType {
    # Canonical charge types: Usage, UnusedReservation, UnusedSavingsPlan,
    # Purchase, Refund, RoundingAdjustment, Adjustment, Credit, Tax, or the
    # original value when it isn't recognized.
    param([string]$Kind, [AllowNull()][string]$Value, [AllowNull()][string]$ChargeClass)
    $text = ([string]$Value).Trim()
    if ($Kind -eq 'FOCUS') {
        switch -Regex ($text) {
            '^(?i)usage$' { return 'Usage' }
            '^(?i)purchase$' { if ($ChargeClass -match '^(?i)correction$') { return 'Refund' } return 'Purchase' }
            '^(?i)adjustment$' { return 'Adjustment' }
            '^(?i)credit$' { return 'Credit' }
            '^(?i)tax$' { return 'Tax' }
        }
    }
    else {
        switch -Regex ($text) {
            '^(?i)usage$' { return 'Usage' }
            '^(?i)unusedreservation$' { return 'UnusedReservation' }
            '^(?i)unusedsavingsplan$' { return 'UnusedSavingsPlan' }
            '^(?i)purchase$' { return 'Purchase' }
            '^(?i)refund$' { return 'Refund' }
            '^(?i)roundingadjustment$' { return 'RoundingAdjustment' }
            '^(?i)adjustment$' { return 'Adjustment' }
            '^(?i)credit$' { return 'Credit' }
            '^(?i)tax$' { return 'Tax' }
        }
    }
    if ($text.Length -eq 0) { return '(blank)' }
    return (ConvertTo-ForecastSafeText -Text $text -MaxLength 60)
}

function Get-ForecastChargeStream {
    # RunRate charges drive growth. Purchases and refunds are forecast only
    # through scheduled items. Adjustments stay in actuals but aren't grown.
    # Credits and tax never enter the pre-credit headline.
    param([Parameter(Mandatory)][string]$ChargeType)
    switch ($ChargeType) {
        { $_ -in 'Usage', 'UnusedReservation', 'UnusedSavingsPlan' } { return 'RunRate' }
        { $_ -in 'Purchase', 'Refund' } { return 'Purchase' }
        { $_ -in 'RoundingAdjustment', 'Adjustment' } { return 'Adjustment' }
        'Credit' { return 'Credit' }
        'Tax' { return 'Tax' }
        default { return 'Other' }
    }
}

function Get-ForecastPublisherClass {
    # EA cost details document PublisherType as Azure for every row, while the
    # FinOps hub ingestion relies on PublisherType = Marketplace. Rows that
    # only a third-party publisher name identifies stay Unclassified so a
    # reviewer decides instead of the tool guessing.
    param([string]$Kind, [AllowNull()][string]$PublisherType, [AllowNull()][string]$PublisherName)
    $type = ([string]$PublisherType).Trim()
    $name = ([string]$PublisherName).Trim()
    $microsoftName = $name.Length -eq 0 -or $name -match '^(?i)microsoft( corporation)?$'
    if ($Kind -eq 'FOCUS') {
        if ($type -match '^(?i)vendor$') { return 'Marketplace' }
        if ($type -match '^(?i)cloud provider$') { return 'Microsoft' }
        if ($microsoftName) { return 'Microsoft' }
        return 'Unclassified'
    }
    if ($type -match '^(?i)marketplace$') { return 'Marketplace' }
    if ($microsoftName) { return 'Microsoft' }
    return 'Unclassified'
}

function ConvertTo-ForecastPricingModel {
    param([string]$Kind, [AllowNull()][string]$Value, [AllowNull()][string]$PricingCategory)
    $text = ([string]$Value).Trim()
    if ($text -match '^(?i)reservation$') { return 'Reservation' }
    if ($text -match '^(?i)savings ?plan$') { return 'SavingsPlan' }
    if ($text -match '^(?i)spot$') { return 'Spot' }
    if ($Kind -eq 'FOCUS') {
        if (([string]$PricingCategory) -match '^(?i)dynamic$') { return 'Spot' }
        return 'OnDemand'
    }
    if ($text -match '^(?i)on ?demand$' -or $text.Length -eq 0) { return 'OnDemand' }
    return 'Other'
}

function Get-ForecastRowAgreement {
    # EA and MCA schemas carry their agreement. FOCUS is shared, so use the
    # agreement column when present, then the billing account ID shape (EA
    # enrollments are numeric; MCA IDs contain a colon and a date suffix),
    # then the source setting.
    param([string]$Kind, [AllowNull()][string]$AgreementValue, [AllowNull()][string]$BillingAccountId, [string]$SourceAgreement = 'Auto')
    if ($Kind -in 'EA', 'MCA') { return $Kind }
    $value = ([string]$AgreementValue).Trim()
    if ($value -match '^(?i)(ea|enterprise ?agreement)$') { return 'EA' }
    if ($value -match '^(?i)(mca|microsoft ?customer ?agreement)$') { return 'MCA' }
    $account = ([string]$BillingAccountId).Trim()
    if ($account -match '^/providers/Microsoft\.Billing/billingAccounts/(.+)$') { $account = $Matches[1] }
    if ($account -match '^\d+$') { return 'EA' }
    if ($account -match ':' -and $account -match '_\d{4}-\d{2}-\d{2}$') { return 'MCA' }
    if ($SourceAgreement -in 'EA', 'MCA') { return $SourceAgreement }
    return 'Unknown'
}

function Get-ForecastTagPattern {
    # Tag names are case-insensitive in Azure. Matches both the JSON object
    # form and the brace-less "key": "value" list some EA exports use.
    param([Parameter(Mandatory)][string]$TagKey)
    return [regex]::new('"' + [regex]::Escape($TagKey) + '"\s*:\s*"((?:[^"\\]|\\.)*)"', [Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant')
}

function ConvertFrom-ForecastJsonEscape {
    # Mirrors UnescapeJson in Forecast.Aggregator.cs so both reducers read
    # the same tag value. Unknown escapes are kept as written.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $builder = [Text.StringBuilder]::new($Value.Length)
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $c = $Value[$i]
        if ($c -ne [char]'\' -or $i + 1 -ge $Value.Length) { [void]$builder.Append($c); continue }
        $i++
        $next = $Value[$i]
        switch -CaseSensitive ([string]$next) {
            '"' { [void]$builder.Append([char]'"') }
            '\' { [void]$builder.Append([char]'\') }
            '/' { [void]$builder.Append([char]'/') }
            'b' { [void]$builder.Append([char]8) }
            'f' { [void]$builder.Append([char]12) }
            'n' { [void]$builder.Append([char]10) }
            'r' { [void]$builder.Append([char]13) }
            't' { [void]$builder.Append([char]9) }
            'u' {
                $code = 0
                if ($i + 4 -lt $Value.Length -and [int]::TryParse($Value.Substring($i + 1, 4), [Globalization.NumberStyles]::HexNumber, [cultureinfo]::InvariantCulture, [ref]$code)) {
                    [void]$builder.Append([char]$code)
                    $i += 4
                }
                else { [void]$builder.Append('\u') }
            }
            default { [void]$builder.Append([char]'\').Append($next) }
        }
    }
    return $builder.ToString()
}

function Get-ForecastTagValue {
    param([AllowNull()][string]$Tags, [Parameter(Mandatory)][regex]$Pattern)
    if ([string]::IsNullOrWhiteSpace($Tags)) { return $null }
    $match = $Pattern.Match($Tags)
    if (-not $match.Success) { return $null }
    $value = $match.Groups[1].Value
    if ($value.Contains('\')) { $value = ConvertFrom-ForecastJsonEscape -Value $value }
    $value = $value.Trim()
    if ($value.Length -eq 0) { return $null }
    return $value
}
