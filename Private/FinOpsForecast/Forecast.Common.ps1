# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers that build objects or write only the private local forecast workspace; nothing in Azure changes.')]
param()

###########################################################################
# FORECAST.COMMON.PS1
# SHARED NUMBERS, CALENDAR, STATISTICS, AND ORDERING HELPERS
###########################################################################
# Purpose: Exact decimal arithmetic, UTC month keys, fiscal-year windows,
#          robust statistics, and culture-independent ordering for the
#          pre-credit forecast. Nothing here touches Azure or the disk.
#
# Conventions:
# - Money is [decimal] end to end. Amounts are stored as invariant strings
#   because ConvertFrom-Json turns JSON numbers into [double].
# - A month key is 'yyyy-MM'. Ordering always uses month keys, never the
#   physical order of rows.
# - String ordering is ordinal so results don't depend on the host culture.
###########################################################################

$script:ForecastInvariant = [Globalization.CultureInfo]::InvariantCulture
$script:ForecastNumberStyle = [Globalization.NumberStyles]::Float
$script:ForecastDateFormats = [string[]]@(
    'MM/dd/yyyy', 'M/d/yyyy', 'MM/dd/yyyy HH:mm:ss', 'M/d/yyyy H:mm:ss', 'M/d/yyyy h:mm:ss tt',
    'yyyy-MM-dd', 'yyyyMMdd', 'yyyy-MM-ddTHH:mm:ss', 'yyyy-MM-ddTHH:mm:ssZ', 'yyyy-MM-ddTHH:mm:ss.fffffffZ',
    'yyyy-MM-ddTHH:mm:ss.fffZ', 'yyyy-MM-ddTHH:mm:sszzz', 'yyyy-MM-ddTHH:mm:ss.fffffffzzz'
)

function New-ForecastIssue {
    param(
        [Parameter(Mandatory)][string]$Code,
        [ValidateSet('Fail', 'Warn', 'Info')][string]$Severity = 'Fail',
        [Parameter(Mandatory)][string]$Message,
        [string]$Subject
    )
    [pscustomobject]@{ Code = $Code; Severity = $Severity; Message = $Message; Subject = $Subject }
}

# Reconciliation differences below a millionth of a currency unit are decimal
# rounding: [decimal] keeps 28-29 significant digits, so sums of long amounts
# in a different order can differ in the last digit.
$script:ForecastReconcileTolerance = [decimal]0.000001

function Test-ForecastMaterialDifference {
    param([AllowNull()]$Value)
    return $null -ne $Value -and [math]::Abs([decimal]$Value) -ge $script:ForecastReconcileTolerance
}

# -- Decimal parsing and formatting ---------------------------------------
# Returns $null for blank or invalid text so callers decide whether a blank
# means "missing" (manual inputs) or "invalid row" (exports).
function Read-ForecastDecimal {
    param([AllowNull()][AllowEmptyString()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [decimal]) { return $Value }
    if ($Value -is [int] -or $Value -is [long]) { return [decimal]$Value }
    $text = ([string]$Value).Trim()
    if ($text.Length -eq 0) { return $null }
    $parsed = [decimal]0
    if ([decimal]::TryParse($text, $script:ForecastNumberStyle, $script:ForecastInvariant, [ref]$parsed)) { return $parsed }
    return $null
}

function Format-ForecastDecimal {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    return ([decimal]$Value).ToString($script:ForecastInvariant)
}

function Get-ForecastRounded {
    param([Parameter(Mandatory)][decimal]$Value, [int]$Digits = 2)
    return [decimal]::Round($Value, $Digits, [MidpointRounding]::ToEven)
}

function Format-ForecastAmount {
    param([AllowNull()]$Value, [string]$Currency)
    if ($null -eq $Value) { return 'n/a' }
    $text = (Get-ForecastRounded -Value ([decimal]$Value)).ToString('N2', $script:ForecastInvariant)
    if ($Currency) { return "$text $Currency" }
    return $text
}

function Format-ForecastPercent {
    param([AllowNull()]$Value, [int]$Digits = 1)
    if ($null -eq $Value) { return 'Undefined' }
    return ((Get-ForecastRounded -Value ([decimal]$Value * 100d) -Digits $Digits).ToString("N$Digits", $script:ForecastInvariant) + '%')
}

# -- Calendar --------------------------------------------------------------
function Test-ForecastMonthKey {
    param([AllowNull()][string]$MonthKey)
    if ([string]::IsNullOrWhiteSpace($MonthKey) -or $MonthKey -notmatch '^(\d{4})-(0[1-9]|1[0-2])$') { return $false }
    return ([int]$Matches[1] -ge 1900 -and [int]$Matches[1] -le 9999)
}

function Assert-ForecastMonthKey {
    param([AllowNull()][string]$MonthKey)
    if (-not (Test-ForecastMonthKey -MonthKey $MonthKey)) { throw "Invalid month '$MonthKey'. Use yyyy-MM, for example 2026-07." }
}

function ConvertTo-ForecastMonthKey {
    param([Parameter(Mandatory)][datetime]$Date)
    return $Date.ToString('yyyy-MM', $script:ForecastInvariant)
}

function Get-ForecastMonthStart {
    param([Parameter(Mandatory)][string]$MonthKey)
    Assert-ForecastMonthKey -MonthKey $MonthKey
    return [datetime]::SpecifyKind([datetime]::ParseExact("$MonthKey-01", 'yyyy-MM-dd', $script:ForecastInvariant), [DateTimeKind]::Utc)
}

function Get-ForecastDaysInMonth {
    param([Parameter(Mandatory)][string]$MonthKey)
    $start = Get-ForecastMonthStart -MonthKey $MonthKey
    return [DateTime]::DaysInMonth($start.Year, $start.Month)
}

function Add-ForecastMonth {
    param([Parameter(Mandatory)][string]$MonthKey, [Parameter(Mandatory)][int]$Count)
    return ConvertTo-ForecastMonthKey -Date ((Get-ForecastMonthStart -MonthKey $MonthKey).AddMonths($Count))
}

function Get-ForecastMonthSpan {
    # Inclusive list of month keys from First to Last.
    param([Parameter(Mandatory)][string]$First, [Parameter(Mandatory)][string]$Last)
    Assert-ForecastMonthKey -MonthKey $First
    Assert-ForecastMonthKey -MonthKey $Last
    $months = [Collections.Generic.List[string]]::new()
    $current = $First
    while ([string]::CompareOrdinal($current, $Last) -le 0) {
        $months.Add($current)
        $current = Add-ForecastMonth -MonthKey $current -Count 1
    }
    return , $months.ToArray()
}

function Get-ForecastMonthDifference {
    # Number of months from First to Second (Second minus First).
    param([Parameter(Mandatory)][string]$First, [Parameter(Mandatory)][string]$Second)
    $a = Get-ForecastMonthStart -MonthKey $First
    $b = Get-ForecastMonthStart -MonthKey $Second
    return (($b.Year - $a.Year) * 12) + ($b.Month - $a.Month)
}

function ConvertFrom-ForecastDate {
    # Parses an export or manifest date as UTC. Returns $null when unreadable.
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Local) { return $Value.ToUniversalTime() }
        return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc)
    }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    $text = ([string]$Value).Trim()
    if ($text.Length -eq 0) { return $null }
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParseExact($text, $script:ForecastDateFormats, $script:ForecastInvariant, $styles, [ref]$parsed)) { return $parsed.UtcDateTime }
    # ISO 8601 variants with other fraction lengths.
    if ($text -match '^\d{4}-\d{2}-\d{2}T' -and [datetimeoffset]::TryParse($text, $script:ForecastInvariant, $styles, [ref]$parsed)) { return $parsed.UtcDateTime }
    return $null
}

function Get-ForecastMonthEnd {
    # First instant after the month, in UTC.
    param([Parameter(Mandatory)][string]$MonthKey)
    return (Get-ForecastMonthStart -MonthKey $MonthKey).AddMonths(1)
}

function Get-ForecastLastEligibleMonth {
    # The latest month that has closed and passed the finalization grace
    # period as of AsOf. Usage can change until the fifth day after a month
    # ends, so the default grace is five days (ForecastDefaultGraceDays).
    param([Parameter(Mandatory)][datetime]$AsOf, [int]$GraceDays = $script:ForecastDefaultGraceDays)
    $asOfUtc = ConvertFrom-ForecastDate -Value $AsOf
    $candidate = ConvertTo-ForecastMonthKey -Date $asOfUtc
    for ($i = 0; $i -lt 3; $i++) {
        $candidate = Add-ForecastMonth -MonthKey $candidate -Count -1
        if ((Get-ForecastMonthEnd -MonthKey $candidate).AddDays($GraceDays) -le $asOfUtc) { return $candidate }
    }
    return $candidate
}

function Get-ForecastFiscalYear {
    # Fiscal years are labeled by the calendar year they end in (July 2026
    # through June 2027 is FY2027).
    param(
        [Parameter(Mandatory)][datetime]$AsOf,
        [ValidateRange(1, 12)][int]$StartMonth = 7,
        [ValidateRange(0, 1)][int]$Offset = 0
    )
    $asOfUtc = ConvertFrom-ForecastDate -Value $AsOf
    $startYear = if ($asOfUtc.Month -ge $StartMonth) { $asOfUtc.Year } else { $asOfUtc.Year - 1 }
    $startYear += $Offset
    $first = '{0:D4}-{1:D2}' -f $startYear, $StartMonth
    $last = Add-ForecastMonth -MonthKey $first -Count 11
    [pscustomobject]@{
        Label      = "FY$($last.Substring(0, 4))"
        FirstMonth = $first
        LastMonth  = $last
        Months     = Get-ForecastMonthSpan -First $first -Last $last
        StartMonth = $StartMonth
        Offset     = $Offset
    }
}

# -- Statistics -----------------------------------------------------------
function Get-ForecastSortedDecimals {
    param([AllowEmptyCollection()][decimal[]]$Values)
    $list = [Collections.Generic.List[decimal]]::new()
    foreach ($value in $Values) { $list.Add($value) }
    $list.Sort()
    return , $list.ToArray()
}

function Get-ForecastPercentile {
    # Linear interpolation between closest ranks (the PERCENTILE.INC method).
    param([Parameter(Mandatory)][AllowEmptyCollection()][decimal[]]$Values, [Parameter(Mandatory)][decimal]$Percentile)
    if ($Values.Count -eq 0) { return $null }
    if ($Percentile -lt 0 -or $Percentile -gt 100) { throw 'Percentile must be between 0 and 100.' }
    $sorted = Get-ForecastSortedDecimals -Values $Values
    if ($sorted.Count -eq 1) { return $sorted[0] }
    $rank = ($Percentile / 100d) * [decimal]($sorted.Count - 1)
    $lower = [int][decimal]::Floor($rank)
    $upper = [int][decimal]::Ceiling($rank)
    if ($lower -eq $upper) { return $sorted[$lower] }
    $weight = $rank - [decimal]$lower
    return $sorted[$lower] + (($sorted[$upper] - $sorted[$lower]) * $weight)
}

function Get-ForecastMedian {
    param([Parameter(Mandatory)][AllowEmptyCollection()][decimal[]]$Values)
    return Get-ForecastPercentile -Values $Values -Percentile 50
}

function Get-ForecastScaledMad {
    # Median absolute deviation scaled to be comparable with a standard
    # deviation for normally distributed data (factor 1.4826).
    param([Parameter(Mandatory)][AllowEmptyCollection()][decimal[]]$Values)
    if ($Values.Count -eq 0) { return $null }
    $median = Get-ForecastMedian -Values $Values
    $deviations = [decimal[]]@(foreach ($value in $Values) { [math]::Abs($value - $median) })
    return (Get-ForecastMedian -Values $deviations) * 1.4826d
}

function Get-ForecastCompound {
    # (1 + Rate) ^ Periods with exact decimal multiplication.
    param([Parameter(Mandatory)][decimal]$Rate, [Parameter(Mandatory)][int]$Periods)
    if ($Periods -lt 0) { throw 'Compounding periods cannot be negative.' }
    $factor = 1d
    $step = 1d + $Rate
    for ($i = 0; $i -lt $Periods; $i++) { $factor = $factor * $step }
    return $factor
}

# -- Ordering and identity -------------------------------------------------
function Invoke-ForecastSort {
    # Stable, culture-independent sort. Comparison receives (a, b) and returns
    # a negative, zero, or positive integer.
    param([AllowNull()][AllowEmptyCollection()][object[]]$Items, [Parameter(Mandatory)][scriptblock]$Comparison)
    $indexed = [Collections.Generic.List[object]]::new()
    $position = 0
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $indexed.Add([pscustomobject]@{ Item = $item; Position = $position })
        $position++
    }
    $compare = $Comparison
    $indexed.Sort([Comparison[object]] {
            param($left, $right)
            $result = [int](& $compare $left.Item $right.Item)
            if ($result -ne 0) { return $result }
            return $left.Position.CompareTo($right.Position)
        })
    return , ([object[]]@($indexed | ForEach-Object { $_.Item }))
}

function Compare-ForecastDecimalDescending {
    # Larger values first; undefined values after every defined value.
    param([AllowNull()]$Left, [AllowNull()]$Right)
    if ($null -eq $Left -and $null -eq $Right) { return 0 }
    if ($null -eq $Left) { return 1 }
    if ($null -eq $Right) { return -1 }
    return ([decimal]$Right).CompareTo([decimal]$Left)
}

function Get-ForecastHash {
    param([AllowEmptyString()][string]$Text, [int]$Length = 16)
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $hash = $algorithm.ComputeHash($bytes) }
    finally { $algorithm.Dispose() }
    return ([BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()).Substring(0, $Length)
}

function ConvertTo-ForecastSubscriptionId {
    # Returns the lowercase GUID for a bare ID or an ARM path, else $null.
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $text = $Value.Trim()
    if ($text -match '^/subscriptions/([0-9a-fA-F-]{36})(?:/|$)') { $text = $Matches[1] }
    $parsed = [guid]::Empty
    if ([guid]::TryParse($text, [ref]$parsed)) { return $parsed.ToString() }
    return $null
}

function ConvertTo-ForecastSafeText {
    # Removes control and format characters before text reaches a console or report.
    param([AllowNull()][string]$Text, [int]$MaxLength = 500)
    if ($null -eq $Text) { return '' }
    $clean = [regex]::Replace($Text, '[\p{Cc}\p{Cf}]', ' ').Trim()
    if ($clean.Length -gt $MaxLength) { $clean = $clean.Substring(0, $MaxLength) + '...' }
    return $clean
}
