# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers that build objects or write only the private local forecast workspace; nothing in Azure changes.')]
param()

###########################################################################
# FORECAST.INPUTS.PS1
# MANUAL MONTHLY INPUTS (FALLBACK WHEN EXPORTS AREN'T AVAILABLE)
###########################################################################
# Each month records pre-credit Azure usage, a status, and source evidence:
# - Missing      no value yet; a blank is never treated as zero
# - VerifiedZero the month was checked and had no usage
# - Entered      a value was entered from the cited evidence
# Other billed charges are signed (refunds are negative) and typed so
# Marketplace, tax, and credits follow the same rules as exports. Each month
# needs an Approved review; changing any of its values clears the approval.
# Manual inputs never mix with imported actuals in the same workspace.
###########################################################################

$script:ForecastOtherChargeTypes = @('Purchase', 'Refund', 'Adjustment', 'Marketplace', 'Tax', 'Credit', 'Other')

function New-ForecastInputs {
    [pscustomobject]@{ schemaVersion = 1; currency = ''; scopeLabel = ''; months = @(); otherCharges = @() }
}

function ConvertTo-ForecastInputs {
    param([AllowNull()]$Loaded)
    $inputs = New-ForecastInputs
    if ($null -eq $Loaded) { return $inputs }
    $inputs.currency = ([string]$Loaded.currency).Trim().ToUpperInvariant()
    $inputs.scopeLabel = [string]$Loaded.scopeLabel
    $inputs.months = @($Loaded.months | Where-Object { $null -ne $_ })
    $inputs.otherCharges = @($Loaded.otherCharges | Where-Object { $null -ne $_ })
    return $inputs
}

function Set-ForecastInputMonth {
    # Value: a decimal string, 'zero' for a verified zero, or '' for missing.
    param([Parameter(Mandatory)]$Inputs, [Parameter(Mandatory)][string]$Month, [AllowEmptyString()][string]$Value, [AllowEmptyString()][string]$Evidence)
    Assert-ForecastMonthKey -MonthKey $Month
    $text = ([string]$Value).Trim()
    $record = [pscustomobject]@{ month = $Month; usage = $null; status = 'Missing'; evidence = ConvertTo-ForecastSafeText -Text $Evidence -MaxLength 300 }
    if ($text -match '^(?i)(zero|verified ?zero)$') { $record.status = 'VerifiedZero'; $record.usage = '0' }
    elseif ($text.Length -gt 0) {
        $amount = Read-ForecastDecimal -Value $text
        if ($null -eq $amount) { throw "'$text' isn't a number. Use digits with a period for decimals, 'zero' for a verified zero, or leave it blank." }
        if ($amount -lt 0) { throw 'Azure usage can''t be negative. Enter refunds as other billed charges.' }
        if ($amount -eq 0) { throw "To record zero usage, type 'zero' so it's clear the month was checked." }
        $record.status = 'Entered'; $record.usage = Format-ForecastDecimal $amount
    }
    $Inputs.months = @(@($Inputs.months | Where-Object { [string]$_.month -ne $Month }) + $record | Sort-Object { [string]$_.month })
    return $record
}

function Add-ForecastOtherCharge {
    param(
        [Parameter(Mandatory)]$Inputs, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Month,
        [Parameter(Mandatory)][string]$Amount, [Parameter(Mandatory)][string]$Type, [string]$Description, [string]$Evidence
    )
    Assert-ForecastMonthKey -MonthKey $Month
    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw 'The charge ID must be letters, digits, dots, dashes, or underscores.' }
    if (@($Inputs.otherCharges | Where-Object { [string]$_.id -ieq $Id }).Count) { throw "A charge with ID '$Id' already exists." }
    if ($Type -notin $script:ForecastOtherChargeTypes) { throw "Type must be one of: $($script:ForecastOtherChargeTypes -join ', ')." }
    $value = Read-ForecastDecimal -Value $Amount
    if ($null -eq $value) { throw "'$Amount' isn't a number." }
    $charge = [pscustomobject]@{
        id = $Id; month = $Month; amount = Format-ForecastDecimal $value; type = $Type
        description = ConvertTo-ForecastSafeText -Text $Description -MaxLength 200; evidence = ConvertTo-ForecastSafeText -Text $Evidence -MaxLength 300
    }
    $Inputs.otherCharges = @(@($Inputs.otherCharges) + $charge)
    return $charge
}

function Remove-ForecastOtherCharge {
    param([Parameter(Mandatory)]$Inputs, [Parameter(Mandatory)][string]$Id)
    $before = @($Inputs.otherCharges).Count
    $Inputs.otherCharges = @($Inputs.otherCharges | Where-Object { [string]$_.id -ine $Id })
    return ($before -ne @($Inputs.otherCharges).Count)
}

function Test-ForecastInputs {
    param([Parameter(Mandatory)]$Inputs)
    $issues = [Collections.Generic.List[object]]::new()
    if ([string]$Inputs.currency -notmatch '^[A-Z]{3}$') { $issues.Add((New-ForecastIssue -Code 'INP-CURRENCY' -Message 'Enter the billing currency as a three-letter code, such as USD.')) }
    $months = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in @($Inputs.months)) {
        $month = [string]$record.month
        if (-not (Test-ForecastMonthKey -MonthKey $month)) { $issues.Add((New-ForecastIssue -Code 'INP-MONTH' -Message "Input month '$(ConvertTo-ForecastSafeText $month 20)' isn't yyyy-MM.")); continue }
        if (-not $months.Add($month)) { $issues.Add((New-ForecastIssue -Code 'INP-DUPLICATE' -Message "Month $month is entered more than once." -Subject $month)) }
        switch ([string]$record.status) {
            'Entered' {
                $usage = Read-ForecastDecimal -Value $record.usage
                if ($null -eq $usage -or $usage -le 0) { $issues.Add((New-ForecastIssue -Code 'INP-USAGE' -Message "Month $month has an invalid usage amount." -Subject $month)) }
                if ([string]::IsNullOrWhiteSpace([string]$record.evidence)) { $issues.Add((New-ForecastIssue -Code 'INP-EVIDENCE' -Message "Month $month needs source evidence, such as an invoice or report reference." -Subject $month)) }
            }
            'VerifiedZero' { if ([string]::IsNullOrWhiteSpace([string]$record.evidence)) { $issues.Add((New-ForecastIssue -Code 'INP-EVIDENCE' -Message "Verified zero for $month needs source evidence." -Subject $month)) } }
            'Missing' { }
            default { $issues.Add((New-ForecastIssue -Code 'INP-STATUS' -Message "Month $month has an unknown status." -Subject $month)) }
        }
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($charge in @($Inputs.otherCharges)) {
        $label = ConvertTo-ForecastSafeText ([string]$charge.id) 64
        if (-not $ids.Add([string]$charge.id)) { $issues.Add((New-ForecastIssue -Code 'INP-CHARGEID' -Message "Charge ID '$label' is used more than once." -Subject $label)) }
        if (-not (Test-ForecastMonthKey -MonthKey ([string]$charge.month))) { $issues.Add((New-ForecastIssue -Code 'INP-CHARGE' -Message "Charge '$label' has an invalid month." -Subject $label)) }
        if ($null -eq (Read-ForecastDecimal -Value $charge.amount)) { $issues.Add((New-ForecastIssue -Code 'INP-CHARGE' -Message "Charge '$label' has an invalid amount." -Subject $label)) }
        if ([string]$charge.type -notin $script:ForecastOtherChargeTypes) { $issues.Add((New-ForecastIssue -Code 'INP-CHARGE' -Message "Charge '$label' has an unknown type." -Subject $label)) }
    }
    return $issues.ToArray()
}

function ConvertTo-ForecastDatasetFromInputs {
    param([Parameter(Mandatory)]$Inputs, [Parameter(Mandatory)]$Settings, [Collections.IDictionary]$Reviews)
    $includeMarketplace = [bool]$Settings.filters.includeMarketplace
    $includeTax = [bool]$Settings.filters.includeTax
    $scopeKey = Get-ForecastScopeKey -Settings $Settings
    $chargesByMonth = @{}
    foreach ($charge in @($Inputs.otherCharges)) {
        $month = [string]$charge.month
        if (-not $chargesByMonth.ContainsKey($month)) { $chargesByMonth[$month] = [Collections.Generic.List[object]]::new() }
        $chargesByMonth[$month].Add($charge)
    }
    $allMonths = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in @($Inputs.months)) { if (Test-ForecastMonthKey ([string]$record.month)) { [void]$allMonths.Add([string]$record.month) } }
    foreach ($month in $chargesByMonth.Keys) { if (Test-ForecastMonthKey $month) { [void]$allMonths.Add($month) } }

    $rows = [Collections.Generic.List[object]]::new()
    $reviewItems = [Collections.Generic.List[object]]::new()
    $reconciliation = [Collections.Generic.List[object]]::new()
    foreach ($month in $allMonths) {
        $record = @($Inputs.months | Where-Object { [string]$_.month -eq $month })[0]
        $status = if ($record) { [string]$record.status } else { 'Missing' }
        $usage = switch ($status) { 'Entered' { Read-ForecastDecimal -Value $record.usage } 'VerifiedZero' { 0d } default { $null } }
        $purchase = 0d; $adjustment = 0d; $other = 0d; $credit = 0d; $marketplace = 0d; $tax = 0d
        foreach ($charge in @($chargesByMonth[$month])) {
            if ($null -eq $charge) { continue }
            $amount = Read-ForecastDecimal -Value $charge.amount
            if ($null -eq $amount) { continue }
            switch ([string]$charge.type) {
                { $_ -in 'Purchase', 'Refund' } { $purchase += $amount }
                'Adjustment' { $adjustment += $amount }
                'Marketplace' { if ($includeMarketplace) { $other += $amount } else { $marketplace += $amount } }
                'Tax' { if ($includeTax) { $other += $amount } else { $tax += $amount } }
                'Credit' { $credit += $amount }
                default { $other += $amount }
            }
        }
        $headline = if ($null -ne $usage) { $usage + $purchase + $adjustment + $other } else { $null }
        $monthStatus = switch ($status) { 'Entered' { 'Complete' } 'VerifiedZero' { 'VerifiedZero' } default { 'Missing' } }
        $evidence = if ($record) { [string]$record.evidence } else { '' }
        $rows.Add([pscustomobject]@{
                Month = $month; Status = $monthStatus; Days = Get-ForecastDaysInMonth -MonthKey $month
                RunRate = $usage; Purchase = $purchase; Adjustment = $adjustment; Other = $other; Headline = $headline; Credit = $credit
                ExcludedMarketplace = $marketplace; ExcludedTax = $tax; ExcludedUnattributed = 0d; ExcludedBoundary = 0d; ExcludedScope = 0d
                DataThrough = if ($null -ne $usage) { (Get-ForecastMonthEnd -MonthKey $month).AddDays(-1) } else { $null }
                Provenance = @("Manual entry. Evidence: $evidence"); Approved = $false; Note = ''
            })
        if ($monthStatus -ne 'Missing') {
            $chargeText = (@($chargesByMonth[$month] | Where-Object { $_ } | Sort-Object { [string]$_.id } | ForEach-Object { "$($_.id)=$($_.type)=$($_.amount)" }) -join ';')
            $fingerprint = Get-ForecastHash -Text "$($Inputs.currency)|$month|$status|$(Format-ForecastDecimal $usage)|$evidence|$chargeText"
            $review = New-ForecastReviewItem -Key "manual:${scopeKey}:$month" -Fingerprint $fingerprint -Category 'ManualMonth' -Reviews $Reviews -Subject $month `
                -Title "Approve manual inputs for $month" -Detail "Usage $(Format-ForecastAmount $usage $Inputs.currency) ($status). Evidence: $(ConvertTo-ForecastSafeText $evidence 200)" `
                -Options @('Approved') -Suggested 'Approved'
            $rows[-1].Approved = ($review.Decision -eq 'Approved')
            $reviewItems.Add($review)
        }
        $reconciliation.Add([pscustomobject]@{
                Month = $month; Source = 'Manual'; Rows = $null; RawTotal = $null
                IncludedHeadline = $headline; ExcludedMarketplace = $marketplace; ExcludedTax = $tax; Credits = $credit
                ExcludedUnattributed = 0d; ExcludedBoundary = 0d; ExcludedScope = 0d; Difference = $null; Note = "Status: $status"
            })
    }
    [pscustomobject]@{
        Mode = 'Manual'; Currency = [string]$Inputs.currency; Months = $rows.ToArray(); Cells = @()
        Reviews = $reviewItems.ToArray(); Issues = @(Test-ForecastInputs -Inputs $Inputs)
        Reconciliation = $reconciliation.ToArray(); Runs = @(); SubscriptionNames = @{}; RecurringPurchases = @()
        Population = $null; DataThrough = $null
    }
}
