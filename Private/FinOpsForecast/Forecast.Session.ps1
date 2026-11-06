# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers that build objects or write only the private local forecast workspace; nothing in Azure changes.')]
param()

###########################################################################
# FORECAST.SESSION.PS1
# REFRESH, EVALUATION, VINTAGES, AND THE ENTRY POINT
###########################################################################

function Update-ForecastExportCache {
    # Reads every source, reusing cached runs whose manifest, partitions, and
    # ingest profile are unchanged. The new cache replaces the old one only
    # when every source was read; otherwise the previous cache stays in use.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Settings)
    $started = [datetime]::UtcNow
    $ingestProfile = Get-ForecastIngestProfile -Settings $Settings
    $existing = $null
    try { $existing = Get-ForecastCache -Root $Root } catch { Write-Warning "The cached data couldn't be read and will be rebuilt: $($_.Exception.Message)" }
    $cachedByKey = @{}
    if ($existing) { foreach ($result in $existing.Results) { $cachedByKey[[string]$result.RunKey] = $result } }
    $runTexts = [Collections.Generic.List[object]]::new()
    $read = 0; $reused = 0
    try {
        $sourceIndex = 0
        foreach ($source in @($Settings.sources)) {
            $sourceIndex++
            Write-Progress -Id 81 -Activity 'Refreshing export history' -Status "Source $sourceIndex of $(@($Settings.sources).Count): $(ConvertTo-ForecastSafeText $source.label 80)"
            $blobs = Get-ForecastSourceBlobs -Source $source
            $runs = Find-ForecastExportRuns -Source $source -Blobs $blobs
            $runIndex = 0
            foreach ($run in $runs) {
                $runIndex++
                Write-Progress -Id 82 -ParentId 81 -Activity 'Reading export runs' -Status "Run $runIndex of $($runs.Count)" -PercentComplete ([int](100 * $runIndex / [math]::Max(1, $runs.Count)))
                $cached = $cachedByKey[[string]$run.RunKey]
                $text = $null
                if ($cached -and $cached.Signature -eq (Get-ForecastRunSignature -Run $run) -and $cached.ProfileHash -eq $ingestProfile.Hash -and $cached.Status -in 'Complete', 'Unverified', 'Unsupported') {
                    $text = Get-ForecastCachedRunText -Root $Root -RunKey $run.RunKey
                    if ($text) { $reused++ }
                }
                if (-not $text) {
                    $result = Invoke-ForecastRunIngest -Source $source -Run $run -IngestProfile $ingestProfile
                    $text = ConvertTo-ForecastCacheRecord -Result $result | ConvertTo-Json -Depth 20 -Compress
                    $read++
                }
                $runTexts.Add([pscustomobject]@{ RunKey = [string]$run.RunKey; Text = $text })
            }
        }
        Write-Progress -Id 82 -Activity 'Reading export runs' -Completed
        Write-Progress -Id 81 -Activity 'Refreshing export history' -Completed
        $meta = [pscustomobject]@{ refreshedUtc = $started.ToString('o', $script:ForecastInvariant); profileHash = $ingestProfile.Hash; runKeys = @($runTexts.RunKey); sourceIds = @($Settings.sources.id) }
        Publish-ForecastCache -Root $Root -RunTexts $runTexts.ToArray() -Meta $meta
        $entry = [pscustomobject]@{ AttemptUtc = $started.ToString('o', $script:ForecastInvariant); Result = 'Succeeded'; Error = $null; RunsRead = $read; RunsReused = $reused; DurationSeconds = [int]([datetime]::UtcNow - $started).TotalSeconds }
        Add-ForecastRefreshLog -Root $Root -Entry $entry
        return [pscustomobject]@{ Succeeded = $true; Error = $null; RunsRead = $read; RunsReused = $reused }
    }
    catch {
        Write-Progress -Id 82 -Activity 'Reading export runs' -Completed
        Write-Progress -Id 81 -Activity 'Refreshing export history' -Completed
        $message = ConvertTo-ForecastSafeText -Text $_.Exception.Message -MaxLength 400
        Add-ForecastRefreshLog -Root $Root -Entry ([pscustomobject]@{ AttemptUtc = $started.ToString('o', $script:ForecastInvariant); Result = 'Failed'; Error = $message; RunsRead = $read; RunsReused = $reused; DurationSeconds = [int]([datetime]::UtcNow - $started).TotalSeconds })
        return [pscustomobject]@{ Succeeded = $false; Error = $message; RunsRead = $read; RunsReused = $reused }
    }
}

function New-ForecastEmptyDataset {
    param([string]$Mode, [string]$Message)
    [pscustomobject]@{
        Mode = $Mode; Currency = ''; Months = @(); Cells = @(); Reviews = @()
        Issues = @(New-ForecastIssue -Code 'DATA-NONE' -Message $Message); Reconciliation = @(); Runs = @()
        SubscriptionNames = @{}; RecurringPurchases = @(); Population = $null; ScopeSubscriptions = @(); DataThrough = $null
    }
}

function Get-ForecastDataset {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Settings, [Collections.IDictionary]$Reviews)
    if ($Settings.dataMode -eq 'Manual') {
        return ConvertTo-ForecastDatasetFromInputs -Inputs (Get-ForecastStoredInputs -Root $Root) -Settings $Settings -Reviews $Reviews
    }
    $cache = Get-ForecastCache -Root $Root
    if (-not $cache) { return New-ForecastEmptyDataset -Mode 'Exports' -Message 'No export data has been read yet. Configure a source and refresh.' }
    $ingestProfile = Get-ForecastIngestProfile -Settings $Settings
    $sourceIds = @($Settings.sources.id)
    $results = @($cache.Results | Where-Object { $_.SourceId -in $sourceIds })
    $dataset = $null
    $selection = Select-ForecastRuns -Results $results -Settings $Settings -Reviews $Reviews
    $dataset = Merge-ForecastExportHistory -Results $results -Selection $selection -Settings $Settings -Reviews $Reviews
    if ($cache.Meta.profileHash -ne $ingestProfile.Hash) {
        $dataset.Issues = @($dataset.Issues) + (New-ForecastIssue -Code 'DATA-PROFILE' -Message 'The workload tag key or migration boundary changed since the last refresh. Refresh to re-read the exports.')
    }
    return $dataset
}

function Invoke-ForecastEvaluation {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][datetime]$AsOf)
    $settings = Get-ForecastStoredSettings -Root $Root
    $reviews = Get-ForecastStoredReviews -Root $Root
    $dataset = Get-ForecastDataset -Root $Root -Settings $settings -Reviews $reviews
    $model = Invoke-ForecastModel -Dataset $dataset -Settings $settings -Reviews $reviews -AsOf $AsOf
    $mapping = Import-ForecastWorkloadMapping -Path ([string]$settings.workloads.mappingPath)
    $workloads = $null
    if ($dataset.Mode -eq 'Exports' -and @($dataset.Cells).Count) {
        $workloads = Get-ForecastWorkloadAnalysis -Cells $dataset.Cells -Months ([string[]]@($model.Window.Rows.Month)) -Settings $settings -Rules $mapping.Rules -SubscriptionNames $dataset.SubscriptionNames
    }
    $backtest = Invoke-ForecastBacktest -Dataset $dataset -Settings $settings -LastMonth $model.Window.Last
    $refreshState = Get-ForecastRefreshState -Root $Root
    $readiness = Test-ForecastReadiness -Dataset $dataset -Model $model -Settings $settings -RefreshState $refreshState -MappingIssues @($mapping.Issues) -AsOf $AsOf
    [pscustomobject]@{
        Root = $Root; AsOf = $AsOf; Settings = $settings; Reviews = $reviews; Dataset = $dataset; Model = $model
        Mapping = $mapping; Workloads = $workloads; Backtest = $backtest; RefreshState = $refreshState; Readiness = $readiness
        ScopeLabel = Get-ForecastScopeLabel -Settings $settings -Root $Root
    }
}

function Get-ForecastScopeLabel {
    param([Parameter(Mandatory)]$Settings, [string]$Root)
    if ($Settings.scope.label) { return [string]$Settings.scope.label }
    if ($Settings.dataMode -eq 'Manual' -and $Root) {
        $inputs = Get-ForecastStoredInputs -Root $Root
        if ($inputs.scopeLabel) { return [string]$inputs.scopeLabel }
        return 'Manual inputs'
    }
    if ($Settings.scope.kind -eq 'BillingProfile') { return "Billing profile $($Settings.scope.billingProfileId)" }
    $count = @($Settings.scope.subscriptionIds).Count
    return "$count selected subscription$(if ($count -ne 1) { 's' })"
}

function ConvertTo-ForecastSerializable {
    # Walks an object graph and turns decimals into invariant strings and
    # dates into ISO 8601, so a vintage survives JSON exactly.
    param([AllowNull()]$Value, [int]$Depth = 0)
    if ($Depth -gt 12 -or $null -eq $Value) { return $Value }
    if ($Value -is [decimal]) { return Format-ForecastDecimal $Value }
    if ($Value -is [datetime]) { return $Value.ToString('o', $script:ForecastInvariant) }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) { $copy[[string]$key] = ConvertTo-ForecastSerializable -Value $Value[$key] -Depth ($Depth + 1) }
        return [pscustomobject]$copy
    }
    if ($Value -is [Collections.IEnumerable]) { return , @(foreach ($item in $Value) { ConvertTo-ForecastSerializable -Value $item -Depth ($Depth + 1) }) }
    $copy = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) { $copy[$property.Name] = ConvertTo-ForecastSerializable -Value $property.Value -Depth ($Depth + 1) }
    return [pscustomobject]$copy
}

function New-ForecastVintage {
    param([Parameter(Mandatory)]$Session)
    $model = $Session.Model
    $projection = $model.Projection
    $body = [ordered]@{
        schemaVersion = 1
        createdUtc = [datetime]::UtcNow
        asOf = $model.AsOf
        ready = $Session.Readiness.Ready
        labels = $Session.Readiness.Labels
        scope = $Session.ScopeLabel
        currency = $Session.Dataset.Currency
        dataMode = $Session.Dataset.Mode
        settings = $Session.Settings
        fiscalYear = [ordered]@{ label = $projection.FiscalYear.Label; firstMonth = $projection.FiscalYear.FirstMonth; lastMonth = $projection.FiscalYear.LastMonth; totalLow = $projection.TotalLow; totalCentral = $projection.TotalCentral; totalHigh = $projection.TotalHigh; actualToDate = $projection.ActualToDate; scheduled = $projection.Scheduled }
        window = [ordered]@{ first = $model.Window.First; last = $model.Window.Last; months = @($model.Window.Rows | ForEach-Object { [ordered]@{ month = $_.Month; status = $_.Status; runRate = $_.RunRate; headline = $_.Headline } }) }
        growth = [ordered]@{ low = $model.Growth.Low; central = $model.Growth.Central; high = $model.Growth.High; retained = $model.Growth.Retained }
        baseline = [ordered]@{ value = $model.Baseline.Value; method = $model.Baseline.Method; month = $model.Baseline.Month }
        comparisons = @($model.Comparisons.Items | ForEach-Object { [ordered]@{ from = $_.FromMonth; to = $_.ToMonth; change = $_.Change; status = $_.Status; flagged = $_.Flagged; retained = $_.Retained; decision = if ($_.Review) { $_.Review.Decision } else { $null } } })
        monthly = @($projection.Rows)
        scheduleEffects = @($model.ScheduleEffects)
        provenance = @($Session.Dataset.Runs | ForEach-Object { [ordered]@{ month = $_.Month; group = $_.Label; runId = $_.RunId; submitted = $_.Submitted; final = $_.Final } })
        reviews = @($Session.Readiness.Reviews | ForEach-Object { [ordered]@{ key = $_.Key; category = $_.Category; decision = $_.Decision; note = $_.Note } })
        checks = @($Session.Readiness.Checks)
    }
    $serializable = ConvertTo-ForecastSerializable -Value $body
    $id = Get-ForecastHash -Text ($serializable | ConvertTo-Json -Depth 30 -Compress) -Length 12
    $serializable | Add-Member -NotePropertyName id -NotePropertyValue $id
    return $serializable
}

function Publish-ForecastOutputs {
    # Writes the reports. A vintage is saved only when the forecast is Ready.
    param([Parameter(Mandatory)]$Session, [string]$OutputPath, [switch]$SaveVintage)
    $vintageName = $null
    if ($SaveVintage) {
        if (-not $Session.Readiness.Ready) { throw 'The forecast isn''t Ready, so it can''t be saved as a vintage. Resolve the failing checks first.' }
        $vintageName = Save-ForecastVintage -Root $Session.Root -Vintage (New-ForecastVintage -Session $Session)
    }
    $directory = Export-ForecastReport -Model $Session.Model -Dataset $Session.Dataset -Settings $Session.Settings -Readiness $Session.Readiness `
        -Workloads $Session.Workloads -Backtest $Session.Backtest -OutputPath $OutputPath -ScopeLabel $Session.ScopeLabel -VintageName $vintageName
    [pscustomobject]@{ ReportDirectory = $directory; Vintage = $vintageName }
}

function Invoke-FinOpsForecast {
    # .SYNOPSIS
    # Runs the pre-credit forecast and workload-growth workflow.
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Accessible', Justification = 'Read by the shared console helpers through dynamic scope.')]
    param(
        [string]$WorkspaceName = 'default',
        [string]$WorkspacePath,
        [string]$OutputPath,
        [string]$ConfigPath,
        [datetime]$AsOf = [datetime]::UtcNow,
        [switch]$SkipRefresh,
        [switch]$NonInteractive,
        [switch]$Accessible
    )
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'The forecast requires PowerShell 7 or later.' }
    $script:FinOpsRichConsole = $null
    $root = Get-ForecastWorkspaceRoot -WorkspaceName $WorkspaceName -WorkspacePath $WorkspacePath
    if ($ConfigPath) {
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "The config file wasn't found: $ConfigPath" }
        $loaded = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -Depth 20 -ErrorAction Stop
        Save-ForecastStoredSettings -Root $root -Settings (ConvertTo-ForecastSettings -Loaded $loaded)
    }
    if (-not $NonInteractive) {
        Show-ForecastSetupReview -Root $root -AsOf $AsOf -OutputPath $OutputPath
        return
    }
    $settings = Get-ForecastStoredSettings -Root $root
    $refresh = $null
    if ($settings.dataMode -eq 'Exports' -and -not $SkipRefresh) {
        $refresh = Update-ForecastExportCache -Root $root -Settings $settings
        if (-not $refresh.Succeeded) { Write-Warning "Refresh failed; using the previous data. $($refresh.Error)" }
    }
    $session = Invoke-ForecastEvaluation -Root $root -AsOf $AsOf
    $published = Publish-ForecastOutputs -Session $session -OutputPath $OutputPath -SaveVintage:($session.Readiness.Ready)
    if (-not $session.Readiness.Ready) {
        $failing = @($session.Readiness.Checks | Where-Object Status -EQ 'Fail' | ForEach-Object { "$($_.Name): $($_.Detail)" })
        Write-Error -Message "The forecast isn't Ready. $($failing -join ' | ') Reports were written to $($published.ReportDirectory) and labeled NotReady; no vintage was saved." -ErrorId 'FinOpsForecastNotReady' -Category InvalidData
    }
    [pscustomobject]@{
        Ready = $session.Readiness.Ready; Status = $session.Readiness.Status; Labels = $session.Readiness.Labels
        FiscalYear = $session.Model.Projection.FiscalYear.Label; Currency = $session.Dataset.Currency
        TotalLow = $session.Model.Projection.TotalLow; TotalCentral = $session.Model.Projection.TotalCentral; TotalHigh = $session.Model.Projection.TotalHigh
        ReportDirectory = $published.ReportDirectory; Vintage = $published.Vintage; Workspace = $root
        Refresh = $refresh
    }
}
