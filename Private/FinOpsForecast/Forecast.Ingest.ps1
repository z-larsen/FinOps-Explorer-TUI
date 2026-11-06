# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers that build objects or write only the private local forecast workspace; nothing in Azure changes.')]
param()

###########################################################################
# FORECAST.INGEST.PS1
# READ ONE EXPORT RUN INTO LEDGER CELLS
###########################################################################
# Every partition the manifest declares is downloaded, checked against its
# declared byteCount, streamed through a CSV parser, and checked against its
# declared dataRowCount.
#
# Two stages keep large partitions fast without duplicating the rules:
# 1. Reduce: rows that share the same raw values are summed into one tuple.
#    A compiled C# reducer (Forecast.Aggregator.cs) does this when the host
#    allows Add-Type; otherwise an equivalent PowerShell loop does. Both use
#    the same TextFieldParser and invariant-culture decimal parsing.
# 2. Classify: PowerShell applies the forecast rules once per distinct tuple
#    and adds it to a ledger cell at the grain:
#      month | agreement | subscription | resource group | workload tag |
#      charge type | stream | publisher class | pricing model |
#      commitment ID (purchases) | frequency (purchases) | billing profile |
#      currency | migration-boundary side
# Rows are summed, never deduplicated, so identical legitimate charges both
# count. Amounts keep their sign. A row that can't be read invalidates the
# run instead of being skipped silently.
###########################################################################

$script:ForecastMaxRowsPerPart = 200000000
$script:ForecastAggregatorReady = $null
$script:ForecastTupleSeparator = [string][char]0x1F

function Initialize-ForecastAggregator {
    # Compiles the C# reducer once per session. Returns $false, and the
    # PowerShell reducer is used, when compilation isn't allowed.
    if ($null -ne $script:ForecastAggregatorReady) { return $script:ForecastAggregatorReady }
    $script:ForecastAggregatorReady = $false
    if ($env:FINOPS_FORECAST_REDUCER -eq 'PowerShell') { return $false }
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { return $false }
    try {
        [void][Reflection.Assembly]::Load('Microsoft.VisualBasic.Core')
        if (-not ('FinOpsForecast.V1.CsvAggregator' -as [type])) {
            $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Forecast.Aggregator.cs'))
            $references = @([Microsoft.VisualBasic.FileIO.TextFieldParser].Assembly.Location, 'System.Collections', 'System.Text.RegularExpressions', 'System.Runtime')
            Add-Type -TypeDefinition $source -ReferencedAssemblies $references -ErrorAction Stop
        }
        $script:ForecastAggregatorReady = $true
    }
    catch { Write-Verbose "The compiled reducer isn't available; using PowerShell. $($_.Exception.Message)" }
    return $script:ForecastAggregatorReady
}

function Open-ForecastCsvParser {
    param([Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)][string]$Name)
    [void][Reflection.Assembly]::Load('Microsoft.VisualBasic.Core')
    $stream = [IO.MemoryStream]::new($Bytes, $false)
    if ($Name -match '\.gz$') { $stream = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Decompress) }
    $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true)
    $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new($reader)
    $parser.SetDelimiters(',')
    $parser.HasFieldsEnclosedInQuotes = $true
    $parser.TrimWhiteSpace = $false
    return $parser
}

function New-ForecastReducerOptions {
    # Column positions and settings for either reducer.
    param([Parameter(Mandatory)]$Schema, [Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][int]$Width, [string]$TagKey)
    $map = $Schema.Map
    $position = { param($name) if ($map.ContainsKey($name)) { [int]$map[$name] } else { -1 } }
    [pscustomobject]@{
        Width = $Width; Date = & $position 'Date'; Subscription = & $position 'SubscriptionId'; Name = & $position 'SubscriptionName'
        ResourceGroup = & $position 'ResourceGroup'; Tags = & $position 'Tags'; Cost = & $position 'Cost'; Currency = & $position 'Currency'
        Charge = & $position 'ChargeType'; ChargeClass = & $position 'ChargeClass'; PublisherType = & $position 'PublisherType'; PublisherName = & $position 'PublisherName'
        Pricing = & $position 'PricingModel'; PricingCategory = & $position 'PricingCategory'; UnitPrice = & $position 'UnitPrice'; Quantity = & $position 'Quantity'
        Contracted = & $position 'ContractedCost'; Profile = & $position 'BillingProfileId'; Account = & $position 'BillingAccountId'; Agreement = & $position 'Agreement'
        Frequency = & $position 'Frequency'; CommitmentColumns = [int[]]@($Schema.CommitmentColumns); TagKey = $TagKey
        # Raw charge values whose rows are purchases or refunds, so their commitment ID and frequency are kept.
        PurchaseCharges = if ($Kind -eq 'FOCUS') { [string[]]@('Purchase') } else { [string[]]@('Purchase', 'Refund') }
        MaxRows = [long]$script:ForecastMaxRowsPerPart
    }
}

function Invoke-ForecastReducePowerShell {
    # PowerShell reducer with the same output shape as the C# reducer.
    param([Parameter(Mandatory)]$Parser, [Parameter(Mandatory)]$Options)
    $styles = $script:ForecastNumberStyle; $culture = $script:ForecastInvariant
    $tuples = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $names = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $purchase = [Collections.Generic.HashSet[string]]::new([string[]]$Options.PurchaseCharges, [StringComparer]::OrdinalIgnoreCase)
    $tagPattern = if ($Options.TagKey) { Get-ForecastTagPattern -TagKey $Options.TagKey } else { $null }
    $tagMemo = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $separator = $script:ForecastTupleSeparator
    $o = $Options
    $rows = 0L; $shape = 0L; $costErrors = 0L
    while (-not $Parser.EndOfData) {
        $f = $Parser.ReadFields()
        if ($null -eq $f -or ($f.Count -eq 1 -and $f[0].Length -eq 0)) { continue }
        $rows++
        if ($rows -gt $o.MaxRows) { throw 'The partition exceeds the supported row count.' }
        if ($f.Count -ne $o.Width) { $shape++; continue }
        $cost = [decimal]0
        if (-not [decimal]::TryParse($f[$o.Cost], $styles, $culture, [ref]$cost)) { $costErrors++; continue }
        $charge = if ($o.Charge -ge 0) { $f[$o.Charge] } else { '' }
        $isPurchase = $purchase.Contains($charge.Trim())
        $tag = ''
        if ($tagPattern -and $o.Tags -ge 0) {
            $rawTags = $f[$o.Tags]
            if (-not $tagMemo.TryGetValue($rawTags, [ref]$tag)) { $tag = [string](Get-ForecastTagValue -Tags $rawTags -Pattern $tagPattern); $tagMemo[$rawTags] = $tag }
        }
        $commitment = ''; $frequency = ''
        if ($isPurchase) {
            foreach ($column in $o.CommitmentColumns) { $candidate = $f[$column].Trim(); if ($candidate) { $commitment = $candidate.ToLowerInvariant(); break } }
            if ($o.Frequency -ge 0) { $frequency = $f[$o.Frequency].Trim() }
        }
        $values = [string[]]@(
            $(if ($o.Date -ge 0) { $f[$o.Date] } else { '' }), $(if ($o.Subscription -ge 0) { $f[$o.Subscription] } else { '' }),
            $(if ($o.ResourceGroup -ge 0) { $f[$o.ResourceGroup].Trim().ToLowerInvariant() } else { '' }), $tag, $charge,
            $(if ($o.ChargeClass -ge 0) { $f[$o.ChargeClass] } else { '' }), $(if ($o.PublisherType -ge 0) { $f[$o.PublisherType] } else { '' }),
            $(if ($o.PublisherName -ge 0) { $f[$o.PublisherName] } else { '' }), $(if ($o.Pricing -ge 0) { $f[$o.Pricing] } else { '' }),
            $(if ($o.PricingCategory -ge 0) { $f[$o.PricingCategory] } else { '' }), $(if ($o.Agreement -ge 0) { $f[$o.Agreement] } else { '' }),
            $(if ($o.Account -ge 0) { $f[$o.Account] } else { '' }), $(if ($o.Profile -ge 0) { $f[$o.Profile].Trim().ToLowerInvariant() } else { '' }),
            $commitment, $frequency, $(if ($o.Currency -ge 0) { $f[$o.Currency] } else { '' })
        )
        $key = [string]::Join($separator, $values)
        $tuple = $null
        if (-not $tuples.TryGetValue($key, [ref]$tuple)) {
            $tuple = [pscustomobject]@{ Values = $values; Cost = [decimal]0; Rows = 0L; PositiveCost = [decimal]0; PositiveRows = 0L; OnDemand = [decimal]0 }
            $tuples[$key] = $tuple
        }
        $tuple.Cost += $cost
        $tuple.Rows++
        if ($cost -gt 0) { $tuple.PositiveCost += $cost; $tuple.PositiveRows++ }
        $onDemand = [decimal]0
        if ($o.Contracted -ge 0) { if ([decimal]::TryParse($f[$o.Contracted], $styles, $culture, [ref]$onDemand)) { $tuple.OnDemand += $onDemand } }
        elseif ($o.UnitPrice -ge 0 -and $o.Quantity -ge 0) {
            $unit = [decimal]0; $quantity = [decimal]0
            if ([decimal]::TryParse($f[$o.UnitPrice], $styles, $culture, [ref]$unit) -and [decimal]::TryParse($f[$o.Quantity], $styles, $culture, [ref]$quantity)) { $tuple.OnDemand += $unit * $quantity }
        }
        if ($o.Name -ge 0 -and $o.Subscription -ge 0) {
            $subscriptionName = $f[$o.Name].Trim()
            if ($f[$o.Subscription].Trim() -and $subscriptionName) { $names[$f[$o.Subscription] + $separator + $f[$o.Date]] = $subscriptionName }
        }
    }
    [pscustomobject]@{ Rows = $rows; ShapeErrors = $shape; CostErrors = $costErrors; Tuples = $tuples; SubscriptionNames = $names }
}

function Invoke-ForecastReduce {
    param([Parameter(Mandatory)]$Parser, [Parameter(Mandatory)]$Options)
    if (Initialize-ForecastAggregator) {
        $native = [FinOpsForecast.V1.AggregatorOptions]::new()
        foreach ($property in $Options.PSObject.Properties) { $native.($property.Name) = $property.Value }
        return [FinOpsForecast.V1.CsvAggregator]::Aggregate($Parser, $native)
    }
    return Invoke-ForecastReducePowerShell -Parser $Parser -Options $Options
}

function Invoke-ForecastRunIngest {
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)]$IngestProfile
    )
    $issues = [Collections.Generic.List[object]]::new()
    foreach ($issue in @($Run.Issues)) { $issues.Add($issue) }
    $incomplete = @($Run.Issues | Where-Object Severity -EQ 'Fail').Count -gt 0
    $partResults = [Collections.Generic.List[object]]::new()
    $cells = [Collections.Generic.Dictionary[string, hashtable]]::new([StringComparer]::Ordinal)
    $monthStats = [Collections.Generic.Dictionary[string, hashtable]]::new([StringComparer]::Ordinal)
    $names = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $schema = $null; $headerKey = $null; $kind = $null
    $invalid = @{ Shape = 0L; Date = 0L; Cost = 0L; Currency = 0L; Subscription = 0L }
    $outsideRows = 0L; $outsideTotal = 0d

    $result = [pscustomobject]@{
        RunKey = $Run.RunKey; RunId = $Run.RunId; SourceId = $Run.SourceId; Signature = Get-ForecastRunSignature -Run $Run
        ProfileHash = $IngestProfile.Hash; Status = 'Complete'; Schema = $null; Dataset = $Run.Dataset; DataVersion = $Run.DataVersion
        OriginalScope = $Run.OriginalScope; ExportName = $Run.ExportName; Folder = $Run.Folder; HasManifest = $Run.HasManifest
        Submitted = $Run.Submitted; Start = $Run.Start; End = $Run.End; Months = @($Run.Months)
        Parts = @(); MonthStats = @(); Cells = @(); SubscriptionNames = @{}; Issues = @(); IngestedUtc = [datetime]::UtcNow
        OutsideRows = 0L; OutsideTotal = [decimal]0
    }

    if ($Run.Dataset -and $Run.Dataset -notin $script:ForecastSupportedDatasets) {
        $issues.Add((New-ForecastIssue -Code 'RUN-DATASET' -Message (Get-ForecastSchemaKind -Header @() -ManifestType $Run.Dataset).Reason))
        $result.Status = 'Unsupported'; $result.Issues = $issues.ToArray(); return $result
    }
    if ($Run.Unsupported) {
        $issues.Add((New-ForecastIssue -Code 'RUN-PARQUET' -Message 'Parquet exports aren''t read by the forecast. Create the export as CSV (gzip is fine).'))
        $result.Status = 'Unsupported'; $result.Issues = $issues.ToArray(); return $result
    }

    $override = if ($Source.agreement -in 'EA', 'MCA', 'FOCUS') { [string]$Source.agreement } else { 'Auto' }
    $sourceAgreement = if ($Source.agreement -in 'EA', 'MCA') { [string]$Source.agreement } else { 'Auto' }
    $boundary = if ($IngestProfile.Values.boundaryDate) { ConvertFrom-ForecastDate -Value $IngestProfile.Values.boundaryDate } else { $null }
    $declaredMonths = [Collections.Generic.HashSet[string]]::new([string[]]@($Run.Months), [StringComparer]::Ordinal)
    $dateMemo = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $subMemo = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $chargeMemo = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $publisherMemo = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $pricingMemo = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $agreementMemo = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $culture = $script:ForecastInvariant

    foreach ($part in @($Run.Parts)) {
        $partResult = [ordered]@{ Name = $part.Declared; Found = [bool]$part.Name; DeclaredBytes = $part.ByteCount; ActualBytes = $null; DeclaredRows = $part.RowCount; ParsedRows = 0L; Status = 'Verified' }
        if (-not $part.Name) {
            $partResult.Status = 'Missing'; $incomplete = $true
            $issues.Add((New-ForecastIssue -Code 'RUN-PARTITION' -Message "Partition $(ConvertTo-ForecastSafeText $part.Declared 200) is declared in the manifest but wasn't found."))
            $partResults.Add([pscustomobject]$partResult); continue
        }
        try { $bytes = Read-ForecastSourceBlob -Source $Source -Name $part.Name }
        catch {
            $partResult.Status = 'Unreadable'; $incomplete = $true
            $issues.Add((New-ForecastIssue -Code 'RUN-PARTITION' -Message "Partition $(ConvertTo-ForecastSafeText $part.Name 200) couldn't be read: $(ConvertTo-ForecastSafeText $_.Exception.Message 200)"))
            $partResults.Add([pscustomobject]$partResult); continue
        }
        $partResult.ActualBytes = [long]$bytes.Length
        if ($null -ne $part.ByteCount -and [long]$part.ByteCount -ne [long]$bytes.Length) {
            $partResult.Status = 'SizeMismatch'; $incomplete = $true
            $issues.Add((New-ForecastIssue -Code 'RUN-BYTES' -Message "Partition $(ConvertTo-ForecastSafeText $part.Name 200) has $($bytes.Length) bytes; the manifest declares $($part.ByteCount)."))
        }
        $parser = $null
        try {
            $parser = Open-ForecastCsvParser -Bytes $bytes -Name $part.Name
            $header = $parser.ReadFields()
            if ($null -eq $header) {
                if ($null -ne $part.RowCount -and $part.RowCount -ne 0) { $partResult.Status = 'RowMismatch'; $incomplete = $true }
                $partResults.Add([pscustomobject]$partResult); continue
            }
            $header = [string[]]@($header | ForEach-Object { ([string]$_).Trim().TrimStart([char]0xFEFF) })
            $thisHeaderKey = ($header | ForEach-Object { $_.ToLowerInvariant() }) -join ','
            if ($null -eq $schema) {
                $detected = Get-ForecastSchemaKind -Header $header -ManifestType $Run.Dataset -Override $override
                if (-not $detected.Kind) { throw "Unsupported schema: $($detected.Reason)" }
                $kind = $detected.Kind
                $schema = Resolve-ForecastColumnIndex -Header $header -Kind $kind
                if ($schema.Missing.Count) { throw "The $kind file is missing required column(s): $($schema.Missing -join ', ')." }
                $headerKey = $thisHeaderKey
            }
            elseif ($thisHeaderKey -cne $headerKey) { throw 'Partitions in this run have different columns.' }

            $options = New-ForecastReducerOptions -Schema $schema -Kind $kind -Width $header.Count -TagKey ([string]$IngestProfile.Values.tagKey)
            $reduced = Invoke-ForecastReduce -Parser $parser -Options $options
            $invalid.Shape += $reduced.ShapeErrors
            $invalid.Cost += $reduced.CostErrors
            $partResult.ParsedRows = [long]$reduced.Rows

            foreach ($tuple in $reduced.Tuples.Values) {
                $v = $tuple.Values
                $rows = [long]$tuple.Rows
                $cost = [decimal]$tuple.Cost
                $dateInfo = $null
                if (-not $dateMemo.TryGetValue($v[0], [ref]$dateInfo)) {
                    $parsedDate = ConvertFrom-ForecastDate -Value $v[0]
                    $dateInfo = if ($parsedDate) { [pscustomobject]@{ Date = $parsedDate.Date; Month = $parsedDate.ToString('yyyy-MM', $culture) } } else { $null }
                    $dateMemo[$v[0]] = $dateInfo
                }
                if ($null -eq $dateInfo) { $invalid.Date += $rows; continue }
                $currency = $v[15].Trim().ToUpperInvariant()
                if ($currency -notmatch '^[A-Z]{3}$') { $invalid.Currency += $rows; continue }
                $sub = $null
                if (-not $subMemo.TryGetValue($v[1], [ref]$sub)) {
                    $sub = if ([string]::IsNullOrWhiteSpace($v[1])) { '' } else { $normalized = ConvertTo-ForecastSubscriptionId -Value $v[1]; if ($normalized) { $normalized } else { '!' } }
                    $subMemo[$v[1]] = $sub
                }
                if ($sub -eq '!') { $invalid.Subscription += $rows; continue }
                $month = $dateInfo.Month
                if ($declaredMonths.Count -gt 0 -and -not $declaredMonths.Contains($month)) { $outsideRows += $rows; $outsideTotal += $cost; continue }

                $stats = $null
                if (-not $monthStats.TryGetValue($month, [ref]$stats)) {
                    $stats = @{ Rows = 0L; Total = 0d; Through = [datetime]::MinValue; PositiveRefundRows = 0L; PositiveRefundTotal = 0d; Currencies = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }
                    $monthStats[$month] = $stats
                }
                $stats.Rows += $rows
                $stats.Total += $cost
                if ($dateInfo.Date -gt $stats.Through) { $stats.Through = $dateInfo.Date }
                [void]$stats.Currencies.Add($currency)

                $chargeKey = $v[4] + '|' + $v[5]
                $charge = $null
                if (-not $chargeMemo.TryGetValue($chargeKey, [ref]$charge)) {
                    $chargeType = ConvertTo-ForecastChargeType -Kind $kind -Value $v[4] -ChargeClass $v[5]
                    $charge = [pscustomobject]@{ Type = $chargeType; Stream = Get-ForecastChargeStream -ChargeType $chargeType }
                    $chargeMemo[$chargeKey] = $charge
                }
                if ($charge.Type -eq 'Refund' -and $tuple.PositiveRows -gt 0) { $stats.PositiveRefundRows += [long]$tuple.PositiveRows; $stats.PositiveRefundTotal += [decimal]$tuple.PositiveCost }
                $publisherKey = $v[6] + '|' + $v[7]
                $publisher = $null
                if (-not $publisherMemo.TryGetValue($publisherKey, [ref]$publisher)) {
                    $publisher = Get-ForecastPublisherClass -Kind $kind -PublisherType $v[6] -PublisherName $v[7]
                    $publisherMemo[$publisherKey] = $publisher
                }
                $pricingKey = $v[8] + '|' + $v[9]
                $pricing = $null
                if (-not $pricingMemo.TryGetValue($pricingKey, [ref]$pricing)) {
                    $pricing = ConvertTo-ForecastPricingModel -Kind $kind -Value $v[8] -PricingCategory $v[9]
                    $pricingMemo[$pricingKey] = $pricing
                }
                $agreement = $kind
                if ($kind -eq 'FOCUS') {
                    $agreementKey = $v[10] + '|' + $v[11]
                    if (-not $agreementMemo.TryGetValue($agreementKey, [ref]$agreement)) {
                        $agreement = Get-ForecastRowAgreement -Kind $kind -AgreementValue $v[10] -BillingAccountId $v[11] -SourceAgreement $sourceAgreement
                        $agreementMemo[$agreementKey] = $agreement
                    }
                }
                $side = 'In'
                if ($boundary) {
                    if ($agreement -eq 'EA' -and $dateInfo.Date -ge $boundary) { $side = 'Outside' }
                    elseif ($agreement -eq 'MCA' -and $dateInfo.Date -lt $boundary) { $side = 'Outside' }
                }
                $isPurchase = $charge.Stream -eq 'Purchase'
                $commitment = if ($isPurchase) { $v[13] } else { '' }
                $frequency = if ($isPurchase) { $v[14] } else { '' }
                $covered = $charge.Stream -eq 'RunRate' -and $charge.Type -eq 'Usage' -and ($pricing -eq 'Reservation' -or $pricing -eq 'SavingsPlan')
                # The publisher name is kept only where a reviewer has to classify it.
                $publisherName = if ($publisher -eq 'Unclassified') { $v[7].Trim() } else { '' }
                $key = "$month|$agreement|$sub|$($v[2])|$($v[3])|$($charge.Type)|$($charge.Stream)|$publisher|$publisherName|$pricing|$commitment|$frequency|$($v[12])|$currency|$side"
                $cell = $null
                if (-not $cells.TryGetValue($key, [ref]$cell)) {
                    $cell = @{
                        Month = $month; Agreement = $agreement; SubscriptionId = $sub; ResourceGroup = $v[2]; Tag = $v[3]
                        ChargeType = $charge.Type; Stream = $charge.Stream; PublisherClass = $publisher; PublisherName = $publisherName; PricingModel = $pricing
                        CommitmentId = $commitment; Frequency = $frequency; BillingProfileId = $v[12]; Currency = $currency; Boundary = $side
                        Cost = [decimal]0; Rows = 0L; CoveredRows = 0L; OnDemandEquivalent = [decimal]0
                    }
                    $cells[$key] = $cell
                }
                $cell.Cost += $cost
                $cell.Rows += $rows
                if ($covered) { $cell.CoveredRows += $rows; $cell.OnDemandEquivalent += [decimal]$tuple.OnDemand }
            }
            foreach ($entry in $reduced.SubscriptionNames.GetEnumerator()) {
                $pair = $entry.Key.Split($script:ForecastTupleSeparator)
                $sub = ConvertTo-ForecastSubscriptionId -Value $pair[0]
                $date = ConvertFrom-ForecastDate -Value $pair[1]
                if (-not $sub -or -not $date) { continue }
                $known = $null
                if (-not $names.TryGetValue($sub, [ref]$known) -or $date -gt $known.Date -or ($date -eq $known.Date -and [string]::CompareOrdinal($entry.Value, $known.Name) -gt 0)) {
                    $names[$sub] = [pscustomobject]@{ Name = $entry.Value; Date = $date }
                }
            }
            if ($null -ne $part.RowCount -and [long]$part.RowCount -ne [long]$reduced.Rows) {
                $partResult.Status = 'RowMismatch'; $incomplete = $true
                $issues.Add((New-ForecastIssue -Code 'RUN-ROWS' -Message "Partition $(ConvertTo-ForecastSafeText $part.Name 200) has $($reduced.Rows) data rows; the manifest declares $($part.RowCount)."))
            }
        }
        catch {
            $partResult.Status = 'Invalid'; $incomplete = $true
            $issues.Add((New-ForecastIssue -Code 'RUN-PARSE' -Message "Partition $(ConvertTo-ForecastSafeText $part.Name 200) couldn't be parsed: $(ConvertTo-ForecastSafeText $_.Exception.Message 300)"))
        }
        finally { if ($parser) { $parser.Dispose() } }
        $partResults.Add([pscustomobject]$partResult)
    }

    $invalidTotal = $invalid.Shape + $invalid.Date + $invalid.Cost + $invalid.Currency + $invalid.Subscription
    if ($invalidTotal -gt 0) {
        $issues.Add((New-ForecastIssue -Code 'RUN-INVALIDROWS' -Message "$invalidTotal row(s) couldn't be read (columns: $($invalid.Shape), dates: $($invalid.Date), amounts: $($invalid.Cost), currencies: $($invalid.Currency), subscription IDs: $($invalid.Subscription)). The run isn't used until the export is fixed."))
    }
    if ($outsideRows -gt 0) {
        $issues.Add((New-ForecastIssue -Code 'RUN-OUTSIDE' -Severity 'Warn' -Message "$outsideRows row(s) totaling $(Format-ForecastAmount $outsideTotal) fall outside the run's declared dates and weren't counted."))
    }
    $result.Schema = $kind
    $result.OutsideRows = $outsideRows
    $result.OutsideTotal = $outsideTotal
    $result.Parts = $partResults.ToArray()
    $result.Status = if ($incomplete) { 'Incomplete' } elseif ($invalidTotal -gt 0) { 'Invalid' } elseif (-not $Run.HasManifest) { 'Unverified' } else { 'Complete' }
    $result.MonthStats = @(foreach ($entry in $monthStats.GetEnumerator()) {
            [pscustomobject]@{
                Month = $entry.Key; Rows = $entry.Value.Rows; Total = $entry.Value.Total
                Through = if ($entry.Value.Through -gt [datetime]::MinValue) { $entry.Value.Through } else { $null }
                PositiveRefundRows = $entry.Value.PositiveRefundRows; PositiveRefundTotal = $entry.Value.PositiveRefundTotal
                Currencies = @($entry.Value.Currencies | Sort-Object -CaseSensitive)
            }
        })
    $result.Cells = @(foreach ($cell in $cells.Values) { [pscustomobject]$cell })
    $nameTable = @{}
    foreach ($entry in $names.GetEnumerator()) { $nameTable[$entry.Key] = $entry.Value.Name }
    $result.SubscriptionNames = $nameTable
    # Legacy runs carry their months only in the data.
    if (@($result.Months).Count -eq 0) { $result.Months = @($result.MonthStats | ForEach-Object Month | Sort-Object) }
    $result.Issues = $issues.ToArray()
    return $result
}

# -- Cache records ----------------------------------------------------------
# Amounts are stored as strings so they survive JSON without becoming doubles.
function ConvertTo-ForecastCacheRecord {
    param([Parameter(Mandatory)]$Result)
    $record = $Result | Select-Object * -ExcludeProperty Cells, MonthStats
    $record | Add-Member -NotePropertyName Cells -NotePropertyValue @(foreach ($cell in @($Result.Cells)) {
            $copy = $cell | Select-Object *
            $copy.Cost = Format-ForecastDecimal $cell.Cost
            $copy.OnDemandEquivalent = Format-ForecastDecimal $cell.OnDemandEquivalent
            $copy
        })
    $record | Add-Member -NotePropertyName MonthStats -NotePropertyValue @(foreach ($stat in @($Result.MonthStats)) {
            $copy = $stat | Select-Object *
            $copy.Total = Format-ForecastDecimal $stat.Total
            $copy.PositiveRefundTotal = Format-ForecastDecimal $stat.PositiveRefundTotal
            if ($stat.Through) { $copy.Through = ([datetime]$stat.Through).ToString('yyyy-MM-dd', $script:ForecastInvariant) }
            $copy
        })
    $record.OutsideTotal = Format-ForecastDecimal ([decimal]$Result.OutsideTotal)
    foreach ($name in 'Submitted', 'Start', 'End', 'IngestedUtc') {
        if ($record.$name) { $record.$name = ([datetime]$record.$name).ToString('o', $script:ForecastInvariant) }
    }
    return $record
}

function ConvertFrom-ForecastCacheRecord {
    param([Parameter(Mandatory)]$Record)
    foreach ($cell in @($Record.Cells)) {
        $cell.Cost = Read-ForecastDecimal -Value $cell.Cost
        $cell.OnDemandEquivalent = Read-ForecastDecimal -Value $cell.OnDemandEquivalent
        $cell.Rows = [long]$cell.Rows
        $cell.CoveredRows = [long]$cell.CoveredRows
        foreach ($text in 'SubscriptionId', 'ResourceGroup', 'Tag', 'CommitmentId', 'Frequency', 'BillingProfileId', 'PublisherName') {
            if ($cell.PSObject.Properties.Name -notcontains $text) { $cell | Add-Member -NotePropertyName $text -NotePropertyValue '' }
            elseif ($null -eq $cell.$text) { $cell.$text = '' }
        }
    }
    foreach ($stat in @($Record.MonthStats)) {
        $stat.Total = Read-ForecastDecimal -Value $stat.Total
        $stat.PositiveRefundTotal = Read-ForecastDecimal -Value $stat.PositiveRefundTotal
        $stat.Rows = [long]$stat.Rows
        $stat.PositiveRefundRows = [long]$stat.PositiveRefundRows
        $stat.Through = ConvertFrom-ForecastDate -Value $stat.Through
    }
    foreach ($name in 'Submitted', 'Start', 'End', 'IngestedUtc') { $Record.$name = ConvertFrom-ForecastDate -Value $Record.$name }
    $outside = Read-ForecastDecimal -Value $Record.OutsideTotal
    if ($Record.PSObject.Properties.Name -contains 'OutsideTotal') { $Record.OutsideTotal = if ($null -ne $outside) { $outside } else { [decimal]0 } }
    else { $Record | Add-Member -NotePropertyName OutsideTotal -NotePropertyValue ([decimal]0) }
    if ($Record.PSObject.Properties.Name -contains 'OutsideRows') { $Record.OutsideRows = [long]$Record.OutsideRows }
    else { $Record | Add-Member -NotePropertyName OutsideRows -NotePropertyValue 0L }
    $names = @{}
    if ($Record.SubscriptionNames) { foreach ($property in $Record.SubscriptionNames.PSObject.Properties) { $names[$property.Name] = [string]$property.Value } }
    $Record.SubscriptionNames = $names
    $Record.Months = @($Record.Months)
    return $Record
}
