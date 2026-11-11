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
    # when every source was read; otherwise the previous cache stays in use,
    # plus any Cost Details months this attempt read completely.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Settings, [datetime]$Now = [datetime]::UtcNow)
    $started = [datetime]::UtcNow
    $ingestProfile = Get-ForecastIngestProfile -Settings $Settings
    $existing = $null
    try { $existing = Get-ForecastCache -Root $Root } catch { Write-Warning "The cached data couldn't be read and will be rebuilt: $($_.Exception.Message)" }
    $cachedByKey = @{}
    if ($existing) { foreach ($result in $existing.Results) { $cachedByKey[[string]$result.RunKey] = $result } }
    $runTexts = [Collections.Generic.List[object]]::new()
    $checkpoint = [Collections.Generic.List[object]]::new()
    $read = 0; $reused = 0; $incomplete = 0
    $notes = [Collections.Generic.List[string]]::new()
    # Cost Details sources with a fromMonth of Auto read from here.
    $earliestMonth = ''
    try { $earliestMonth = Get-ForecastFirstNeededMonth -Settings $Settings -AsOf $Now }
    catch { Write-Verbose "The forecast period's first month isn't available: $($_.Exception.Message)" }
    try {
        $sourceIndex = 0
        foreach ($source in @($Settings.sources)) {
            $sourceIndex++
            Write-Progress -Id 81 -Activity 'Refreshing export history' -Status "Source $sourceIndex of $(@($Settings.sources).Count): $(ConvertTo-ForecastSafeText $source.label 80)"
            $costDetails = [string]$source.kind -eq 'CostDetails'
            # Cost Details records carry their own source's profile hash; see Get-ForecastIngestProfile.
            $sourceProfile = $ingestProfile
            if ($costDetails) {
                $runs = Get-ForecastCostDetailsRuns -Source $source -Now $Now -EarliestMonth $earliestMonth
                $sourceProfile = [pscustomobject]@{ Values = $ingestProfile.Values; Hash = [string]$ingestProfile.SourceHashes[[string]$source.id] }
            }
            else {
                $blobs = Get-ForecastSourceBlobs -Source $source
                $runs = Find-ForecastExportRuns -Source $source -Blobs $blobs
            }
            $runIndex = 0
            foreach ($run in $runs) {
                $runIndex++
                Write-Progress -Id 82 -ParentId 81 -Activity 'Reading export runs' -Status "Run $runIndex of $($runs.Count)" -PercentComplete ([int](100 * $runIndex / [math]::Max(1, $runs.Count)))
                $cached = $cachedByKey[[string]$run.RunKey]
                $text = $null
                if ($costDetails) { $canReuse = Test-ForecastCostDetailsReuse -Cached $cached -Run $run -ProfileHash $sourceProfile.Hash -GraceDays ([int]$Settings.period.graceDays) -Now $Now }
                else {
                    $hasPartitionVersions = @($run.Parts | Where-Object { -not $_.LastModified }).Count -eq 0
                    $runHasErrors = @($run.Issues | Where-Object Severity -EQ 'Fail').Count -gt 0
                    $canReuse = $cached -and -not $runHasErrors -and $hasPartitionVersions -and $cached.Signature -eq (Get-ForecastRunSignature -Run $run) -and $cached.ProfileHash -eq $ingestProfile.Hash -and $cached.Status -in 'Complete', 'Unverified', 'Unsupported'
                }
                if ($canReuse) {
                    $text = Get-ForecastCachedRunText -Root $Root -RunKey $run.RunKey
                    if ($text) { $reused++ }
                }
                if (-not $text) {
                    $result = Invoke-ForecastRunIngest -Source $source -Run $run -IngestProfile $sourceProfile
                    if ($cached -and $cached.Status -in 'Complete', 'Unverified' -and $result.Status -notin 'Complete', 'Unverified') {
                        $reason = @($result.Issues | Where-Object Severity -EQ 'Fail' | ForEach-Object Message) -join ' '
                        throw "Previously usable run $(ConvertTo-ForecastSafeText $run.RunId 80) is now $($result.Status). The previous cache was retained. $reason"
                    }
                    $text = ConvertTo-ForecastCacheRecord -Result $result | ConvertTo-Json -Depth 20 -Compress
                    $read++
                    if ($result.Status -in 'Incomplete', 'Invalid') { $incomplete++ }
                    if ($costDetails -and $result.Status -eq 'Complete') { $checkpoint.Add([pscustomobject]@{ RunKey = [string]$run.RunKey; Text = $text }) }
                }
                $runTexts.Add([pscustomobject]@{ RunKey = [string]$run.RunKey; Text = $text })
            }
            if ($costDetails) {
                $retention = Get-ForecastCostDetailsRetainedKeys -Source $source -Runs @($runs) -Cached @($cachedByKey.Values) -ProfileHash $sourceProfile.Hash -GraceDays ([int]$Settings.period.graceDays)
                foreach ($runKey in $retention.Keys) {
                    $text = Get-ForecastCachedRunText -Root $Root -RunKey $runKey
                    if (-not $text) { continue }
                    $runTexts.Add([pscustomobject]@{ RunKey = $runKey; Text = $text })
                    $reused++
                }
                if (@($retention.Dropped).Count) {
                    $note = "$(ConvertTo-ForecastSafeText $source.label 80): $(@($retention.Dropped) -join ', ') can't be read again from Cost Details and were read before the tag key, migration boundary, or this source's settings changed, so they're no longer used."
                    $notes.Add($note)
                    Write-Warning $note
                }
            }
        }
        Write-Progress -Id 82 -Activity 'Reading export runs' -Completed
        Write-Progress -Id 81 -Activity 'Refreshing export history' -Completed
        $meta = [pscustomobject]@{ refreshedUtc = $started.ToString('o', $script:ForecastInvariant); profileHash = $ingestProfile.Hash; runKeys = @($runTexts.RunKey); sourceIds = @($Settings.sources.id) }
        Publish-ForecastCache -Root $Root -RunTexts $runTexts.ToArray() -Meta $meta
        $entry = [pscustomobject]@{ AttemptUtc = $started.ToString('o', $script:ForecastInvariant); Result = 'Succeeded'; Error = $null; RunsRead = $read; RunsReused = $reused; DurationSeconds = [int]([datetime]::UtcNow - $started).TotalSeconds }
        Add-ForecastRefreshLog -Root $Root -Entry $entry
        return [pscustomobject]@{ Succeeded = $true; Error = $null; RunsRead = $read; RunsReused = $reused; RunsIncomplete = $incomplete; Notes = $notes.ToArray() }
    }
    catch {
        Write-Progress -Id 82 -Activity 'Reading export runs' -Completed
        Write-Progress -Id 81 -Activity 'Refreshing export history' -Completed
        $message = ConvertTo-ForecastSafeText -Text $_.Exception.Message -MaxLength 400
        $kept = Save-ForecastRefreshCheckpoint -Root $Root -Existing $existing -RunTexts $checkpoint.ToArray() -IngestProfile $ingestProfile -Settings $Settings -Started $started
        if ($kept) { $message += " $kept Cost Details month(s) read completely in this attempt were kept; refresh again to continue." }
        Add-ForecastRefreshLog -Root $Root -Entry ([pscustomobject]@{ AttemptUtc = $started.ToString('o', $script:ForecastInvariant); Result = 'Failed'; Error = $message; RunsRead = $read; RunsReused = $reused; DurationSeconds = [int]([datetime]::UtcNow - $started).TotalSeconds })
        return [pscustomobject]@{ Succeeded = $false; Error = $message; RunsRead = $read; RunsReused = $reused; RunsIncomplete = $incomplete; Notes = $notes.ToArray() }
    }
}

function Save-ForecastRefreshCheckpoint {
    # A first Cost Details pull can take an hour, so months a failed refresh
    # read completely are kept and the next refresh resumes. Each kept month
    # replaces only its own record; the rest of the previous cache, including
    # its profile hash, is unchanged, so a pending settings change still asks
    # for a refresh.
    param(
        [Parameter(Mandatory)][string]$Root,
        [AllowNull()]$Existing,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RunTexts,
        [Parameter(Mandatory)]$IngestProfile,
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)][datetime]$Started
    )
    if ($RunTexts.Count -eq 0) { return 0 }
    try {
        $texts = [ordered]@{}
        if ($Existing) {
            foreach ($runKey in @($Existing.Meta.runKeys)) {
                $text = Get-ForecastCachedRunText -Root $Root -RunKey $runKey
                if (-not $text) { return 0 }
                $texts[[string]$runKey] = $text
            }
        }
        foreach ($run in $RunTexts) { $texts[[string]$run.RunKey] = $run.Text }
        $meta = [pscustomobject]@{
            refreshedUtc = if ($Existing) { [string]$Existing.Meta.refreshedUtc } else { $Started.ToString('o', $script:ForecastInvariant) }
            profileHash = if ($Existing) { [string]$Existing.Meta.profileHash } else { $IngestProfile.Hash }; runKeys = @($texts.Keys)
            sourceIds = if ($Existing) { @($Existing.Meta.sourceIds) } else { @($Settings.sources.id) }
        }
        Publish-ForecastCache -Root $Root -RunTexts @(foreach ($key in $texts.Keys) { [pscustomobject]@{ RunKey = [string]$key; Text = $texts[$key] } }) -Meta $meta
        return $RunTexts.Count
    }
    catch {
        Write-Warning "The months read before the failure couldn't be kept: $(ConvertTo-ForecastSafeText $_.Exception.Message 200)"
        return 0
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
        $dataset.Issues = @($dataset.Issues) + (New-ForecastIssue -Code 'DATA-PROFILE' -Message 'The export sources, workload tag key, migration boundary, or ingestion rules changed since the last refresh. Refresh to re-read the exports.')
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
    # Interactive runs without a named workspace or config sign in first and
    # use the signed-in tenant's workspace, so customers never share one.
    if (-not $NonInteractive -and -not $PSBoundParameters.ContainsKey('WorkspaceName') -and -not $ConfigPath) {
        $tenantRoot = Open-ForecastTenantWorkspace -WorkspacePath $WorkspacePath -AsOf $AsOf
        if ($tenantRoot) { Show-ForecastSetupReview -Root $tenantRoot -AsOf $AsOf -OutputPath $OutputPath }
        return
    }
    $root = Get-ForecastWorkspaceRoot -WorkspaceName $WorkspaceName -WorkspacePath $WorkspacePath
    if ($ConfigPath) {
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "The config file wasn't found: $ConfigPath" }
        $loaded = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -Depth 20 -ErrorAction Stop
        Save-ForecastStoredSettings -Root $root -Settings (ConvertTo-ForecastSettings -Loaded $loaded)
    }
    if (-not $NonInteractive) {
        if (-not (Test-ForecastWorkspaceConfigured -Root $root)) { $null = Start-ForecastGuidedSetup -Root $root -AsOf $AsOf }
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
        $message = if ($session.Readiness.Status -eq 'Preliminary') {
            "The forecast is Preliminary: $($session.Settings.period.lookbackMonths) months of history, and a Ready forecast needs $($script:ForecastReadyMonths). Reports were written to $($published.ReportDirectory) and labeled Preliminary; no vintage was saved."
        }
        else {
            $failing = @($session.Readiness.Checks | Where-Object Status -EQ 'Fail' | ForEach-Object { "$($_.Name): $($_.Detail)" })
            "The forecast isn't Ready. $($failing -join ' | ') Reports were written to $($published.ReportDirectory) and labeled NotReady; no vintage was saved."
        }
        Write-Error -Message $message -ErrorId 'FinOpsForecastNotReady' -Category InvalidData
    }
    [pscustomobject]@{
        Ready = $session.Readiness.Ready; Status = $session.Readiness.Status; Labels = $session.Readiness.Labels
        FiscalYear = $session.Model.Projection.FiscalYear.Label; Currency = $session.Dataset.Currency
        TotalLow = $session.Model.Projection.TotalLow; TotalCentral = $session.Model.Projection.TotalCentral; TotalHigh = $session.Model.Projection.TotalHigh
        ReportDirectory = $published.ReportDirectory; Vintage = $published.Vintage; Workspace = $root
        Refresh = $refresh
    }
}
