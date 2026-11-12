# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers create synthetic fixtures in TestDrive only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helpers are named for the collections they build.')]
param()
###########################################################################
# FORECAST.TESTHELPERS.PS1
# SYNTHETIC FIXTURES FOR THE FORECAST TESTS
###########################################################################
# Every fixture is synthetic: generated GUIDs, placeholder names such as
# sub-synth-a and BP-SYNTH-01, and round amounts. Nothing here comes from a
# real tenant. Export runs are written to disk in the same layout Cost
# Management uses (manifest.json beside part_*.csv files), so tests exercise
# the real discovery and ingestion code.
###########################################################################

$script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
Import-Module (Join-Path $script:RepoRoot 'Private/FinOpsForecast/FinOpsForecast.psm1') -Force

$script:SyntheticSubscriptions = @{
    A = '11111111-1111-1111-1111-111111111111'
    B = '22222222-2222-2222-2222-222222222222'
    C = '33333333-3333-3333-3333-333333333333'
}
$script:EnrollmentScope = '/providers/Microsoft.Billing/billingAccounts/1234567'
$script:ProfileScope = '/providers/Microsoft.Billing/billingAccounts/aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-0000-0000-0000-000000000000_2019-05-31/billingProfiles/BP-SYNTH-01'

$script:SyntheticHeaders = @{
    EA    = @('Date', 'BillingAccountId', 'BillingProfileId', 'SubscriptionId', 'SubscriptionName', 'ResourceGroup', 'Tags', 'CostInBillingCurrency', 'BillingCurrencyCode', 'ChargeType', 'PublisherType', 'PublisherName', 'PricingModel', 'UnitPrice', 'Quantity', 'ReservationId', 'Frequency')
    MCA   = @('date', 'billingAccountId', 'billingProfileId', 'SubscriptionId', 'subscriptionName', 'resourceGroupName', 'tags', 'costInBillingCurrency', 'billingCurrency', 'chargeType', 'publisherType', 'publisherName', 'pricingModel', 'unitPrice', 'quantity', 'reservationId', 'frequency')
    FOCUS = @('ChargePeriodStart', 'BillingAccountId', 'x_BillingProfileId', 'SubAccountId', 'SubAccountName', 'x_ResourceGroupName', 'Tags', 'BilledCost', 'BillingCurrency', 'ChargeCategory', 'ChargeClass', 'x_PublisherCategory', 'PublisherName', 'CommitmentDiscountType', 'PricingCategory', 'ContractedCost', 'CommitmentDiscountId', 'ChargeFrequency')
}

function New-SyntheticRow {
    # Canonical synthetic row; ConvertTo-SyntheticCsv renders it per schema.
    param(
        [Parameter(Mandatory)][string]$Date,
        [string]$Subscription = 'A',
        [Parameter(Mandatory)][string]$Cost,
        [string]$ChargeType = 'Usage',
        [string]$Workload,
        [string]$ResourceGroup = 'rg-synth',
        [string]$Currency = 'USD',
        [string]$PublisherType = '',
        [string]$PublisherName = 'Microsoft',
        [string]$PricingModel = 'OnDemand',
        [string]$UnitPrice = '',
        [string]$Quantity = '',
        [string]$CommitmentId = '',
        [string]$Frequency = 'UsageBased',
        [string]$BillingProfile = 'BP-SYNTH-01',
        [string]$BillingAccount = '1234567'
    )
    $subscriptionId = if ($Subscription -and $script:SyntheticSubscriptions.ContainsKey($Subscription)) { $script:SyntheticSubscriptions[$Subscription] } else { $Subscription }
    [pscustomobject]@{
        Date = $Date; SubscriptionId = $subscriptionId; SubscriptionName = if ($Subscription) { "sub-synth-$($Subscription.ToLowerInvariant())" } else { '' }
        ResourceGroup = $ResourceGroup; Tags = if ($Workload) { "{`"workload`": `"$Workload`", `"env`": `"test`"}" } else { '' }
        Cost = $Cost; Currency = $Currency; ChargeType = $ChargeType; PublisherType = $PublisherType; PublisherName = $PublisherName
        PricingModel = $PricingModel; UnitPrice = $UnitPrice; Quantity = $Quantity; CommitmentId = $CommitmentId; Frequency = $Frequency
        BillingProfile = $BillingProfile; BillingAccount = $BillingAccount
    }
}

function ConvertTo-SyntheticCsv {
    param([Parameter(Mandatory)][ValidateSet('EA', 'MCA', 'FOCUS')][string]$Kind, [AllowEmptyCollection()][object[]]$Rows)
    $quote = { param($value) '"' + ([string]$value).Replace('"', '""') + '"' }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add(($script:SyntheticHeaders[$Kind] | ForEach-Object { & $quote $_ }) -join ',')
    foreach ($row in @($Rows)) {
        $values = switch ($Kind) {
            'FOCUS' {
                $category = switch ($row.ChargeType) { 'Refund' { 'Purchase' } 'UnusedReservation' { 'Usage' } 'RoundingAdjustment' { 'Adjustment' } default { $row.ChargeType } }
                $class = if ($row.ChargeType -eq 'Refund') { 'Correction' } else { '' }
                $publisher = switch ($row.PublisherType) { 'Marketplace' { 'Vendor' } '' { 'Cloud Provider' } default { 'Cloud Provider' } }
                $commitmentType = switch ($row.PricingModel) { 'Reservation' { 'Reservation' } 'SavingsPlan' { 'Savings Plan' } default { '' } }
                $contracted = if ($row.UnitPrice -and $row.Quantity) { [string]([decimal]$row.UnitPrice * [decimal]$row.Quantity) } else { '' }
                $iso = ([datetime]::ParseExact($row.Date, 'MM/dd/yyyy', [cultureinfo]::InvariantCulture)).ToString('yyyy-MM-ddT00:00:00Z')
                @($iso, $row.BillingAccount, $row.BillingProfile, $row.SubscriptionId, $row.SubscriptionName, $row.ResourceGroup, $row.Tags, $row.Cost, $row.Currency, $category, $class, $publisher, $row.PublisherName, $commitmentType, 'Standard', $contracted, $row.CommitmentId, $row.Frequency)
            }
            default {
                $publisherType = if ($row.PublisherType) { $row.PublisherType } elseif ($Kind -eq 'EA') { 'Azure' } else { 'Microsoft' }
                @($row.Date, $row.BillingAccount, $row.BillingProfile, $row.SubscriptionId, $row.SubscriptionName, $row.ResourceGroup, $row.Tags, $row.Cost, $row.Currency, $row.ChargeType, $publisherType, $row.PublisherName, $row.PricingModel, $row.UnitPrice, $row.Quantity, $row.CommitmentId, $row.Frequency)
            }
        }
        $lines.Add(($values | ForEach-Object { & $quote $_ }) -join ',')
    }
    return ($lines -join "`r`n") + "`r`n"
}

function New-SyntheticExportRun {
    # Writes one export run: part files plus manifest.json. Returns the run folder.
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidateSet('EA', 'MCA', 'FOCUS')][string]$Kind,
        [Parameter(Mandatory)][string]$Month,
        [Parameter(Mandatory)][object[]]$Parts,
        [string]$ExportName = 'synth-actual',
        [string]$Scope = $script:EnrollmentScope,
        [string]$Dataset,
        [string]$RunId = ([guid]::NewGuid().ToString()),
        [datetime]$Submitted,
        [string]$EndMonth,
        [datetime]$RangeStart,
        [datetime]$RangeEnd,
        [switch]$Gzip,
        [int]$DeclareExtraPartitions = 0,
        [int]$RowCountOffset = 0,
        [int]$ByteCountOffset = 0,
        [switch]$NoManifest
    )
    if (-not $Dataset) { $Dataset = if ($Kind -eq 'FOCUS') { 'FocusCost' } else { 'ActualCost' } }
    $start = [datetime]::ParseExact("$Month-01", 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
    $last = if ($EndMonth) { [datetime]::ParseExact("$EndMonth-01", 'yyyy-MM-dd', [cultureinfo]::InvariantCulture).AddMonths(1).AddDays(-1) } else { $start.AddMonths(1).AddDays(-1) }
    # Explicit ranges model runs that start mid-month or stop early.
    if ($PSBoundParameters.ContainsKey('RangeStart')) { $start = $RangeStart.Date }
    if ($PSBoundParameters.ContainsKey('RangeEnd')) { $last = $RangeEnd.Date }
    if (-not $PSBoundParameters.ContainsKey('Submitted')) { $Submitted = $last.AddDays(7) }
    $range = '{0}-{1}' -f $start.ToString('yyyyMMdd'), $last.ToString('yyyyMMdd')
    $relativeFolder = "exports/$ExportName/$range/$RunId"
    $folder = Join-Path $Root ($relativeFolder -replace '/', [IO.Path]::DirectorySeparatorChar)
    [void][IO.Directory]::CreateDirectory($folder)
    $blobs = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Parts.Count; $i++) {
        $rows = @($Parts[$i])
        $csv = ConvertTo-SyntheticCsv -Kind $Kind -Rows $rows
        $bytes = [Text.Encoding]::UTF8.GetBytes($csv)
        $name = "part_0_$('{0:D4}' -f ($i + 1)).csv"
        if ($Gzip) {
            $buffer = [IO.MemoryStream]::new()
            $compressor = [IO.Compression.GZipStream]::new($buffer, [IO.Compression.CompressionLevel]::Optimal, $true)
            $compressor.Write($bytes, 0, $bytes.Length); $compressor.Dispose()
            $bytes = $buffer.ToArray(); $buffer.Dispose()
            $name += '.gz'
        }
        [IO.File]::WriteAllBytes((Join-Path $folder $name), $bytes)
        $blobs.Add([ordered]@{ blobName = "$relativeFolder/$name"; byteCount = $bytes.Length + $ByteCountOffset; dataRowCount = $rows.Count + $RowCountOffset })
    }
    for ($extra = 0; $extra -lt $DeclareExtraPartitions; $extra++) {
        $blobs.Add([ordered]@{ blobName = "$relativeFolder/part_9_$('{0:D4}' -f ($extra + 1)).csv"; byteCount = 100; dataRowCount = 1 })
    }
    if (-not $NoManifest) {
        $manifest = [ordered]@{
            manifestVersion = '2024-04-01'; byteCount = 0; blobCount = $blobs.Count; dataRowCount = 0
            exportConfig = [ordered]@{ exportName = $ExportName; resourceId = "$Scope/providers/Microsoft.CostManagement/exports/$ExportName"; dataVersion = '2023-12-01-preview'; apiVersion = '2023-07-01-preview'; type = $Dataset; timeFrame = 'Custom'; granularity = 'Daily' }
            deliveryConfig = [ordered]@{ partitionData = $true; dataOverwriteBehavior = 'CreateNewReport'; fileFormat = 'Csv'; compressionMode = $(if ($Gzip) { 'Gzip' } else { 'None' }); containerUri = '/subscriptions/x/resourceGroups/y/providers/Microsoft.Storage/storageAccounts/synthstore'; rootFolderPath = 'exports' }
            runInfo = [ordered]@{ executionType = 'Scheduled'; submittedTime = $Submitted.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'); runId = $RunId; startDate = $start.ToString('yyyy-MM-ddT00:00:00'); endDate = $last.ToString('yyyy-MM-ddT00:00:00') }
            blobs = $blobs.ToArray()
        }
        [IO.File]::WriteAllText((Join-Path $folder 'manifest.json'), ($manifest | ConvertTo-Json -Depth 10))
    }
    return $folder
}

function New-SyntheticMonthRows {
    # Daily usage rows for one month that add up to Total (spread evenly, remainder on day 1).
    param([Parameter(Mandatory)][string]$Month, [Parameter(Mandatory)][decimal]$Total, [string]$Subscription = 'A', [string]$Workload = 'app-alpha', [int]$Days = 3, [string]$ChargeType = 'Usage')
    $start = [datetime]::ParseExact("$Month-01", 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
    $share = [decimal]::Round($Total / $Days, 2)
    for ($d = 0; $d -lt $Days; $d++) {
        $amount = if ($d -eq 0) { $Total - ($share * ($Days - 1)) } else { $share }
        New-SyntheticRow -Date $start.AddDays($d * 9).ToString('MM/dd/yyyy') -Subscription $Subscription -Cost ([string]$amount) -Workload $Workload -ChargeType $ChargeType
    }
}

function New-TestSettings {
    param(
        [string]$Root,
        [string[]]$Subscriptions = @('A'),
        [string]$Kind = 'Auto',
        [int]$StartMonth = 1,
        [string]$Mode = 'Exports'
    )
    $settings = InModuleScope FinOpsForecast { New-ForecastDefaultSettings }
    $settings.dataMode = $Mode
    $settings.scope.subscriptionIds = @($Subscriptions | ForEach-Object { $script:SyntheticSubscriptions[$_] })
    $settings.scope.label = 'Synthetic scope'
    $settings.period.fiscalYearStartMonth = $StartMonth
    if ($Root) { $settings.sources = @([pscustomobject]@{ id = 'src-local'; kind = 'LocalFolder'; label = 'Synthetic exports'; path = $Root; prefix = ''; storageResourceId = ''; container = ''; agreement = $Kind }) }
    return $settings
}

function New-TestDataset {
    # Monthly run-rate dataset for engine tests. Values: ordered month -> amount.
    param([Parameter(Mandatory)][Collections.IDictionary]$Values, [string]$Currency = 'USD', [string]$Status = 'Complete')
    $months = foreach ($month in $Values.Keys) {
        $amount = $Values[$month]
        $days = [DateTime]::DaysInMonth([int]$month.Substring(0, 4), [int]$month.Substring(5, 2))
        [pscustomobject]@{
            Month = $month; Status = if ($null -eq $amount) { 'Missing' } else { $Status }; Days = $days
            RunRate = if ($null -eq $amount) { $null } else { [decimal]$amount }; Purchase = 0d; Adjustment = 0d; Other = 0d
            Headline = if ($null -eq $amount) { $null } else { [decimal]$amount }; Credit = 0d
            ExcludedMarketplace = 0d; ExcludedTax = 0d; ExcludedUnattributed = 0d; ExcludedBoundary = 0d; ExcludedScope = 0d
            DataThrough = if ($null -eq $amount) { $null } else { [datetime]::ParseExact("$month-$days", 'yyyy-MM-dd', [cultureinfo]::InvariantCulture) }
            Provenance = @('synthetic'); Approved = $true; Note = ''
        }
    }
    [pscustomobject]@{
        Mode = 'Exports'; Currency = $Currency; Months = @($months); Cells = @(); Reviews = @(); Issues = @(); Reconciliation = @(); Runs = @()
        SubscriptionNames = @{}; RecurringPurchases = @(); Population = $null; ScopeSubscriptions = @(); DataThrough = $null
    }
}

function Get-TestMonthKeys {
    # Months ending at Last, oldest first.
    param([Parameter(Mandatory)][string]$Last, [int]$Count = 12)
    $end = [datetime]::ParseExact("$Last-01", 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
    return , @(for ($i = $Count - 1; $i -ge 0; $i--) { $end.AddMonths(-$i).ToString('yyyy-MM') })
}
