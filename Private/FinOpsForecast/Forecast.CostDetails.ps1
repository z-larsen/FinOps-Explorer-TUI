# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
param()

###########################################################################
# FORECAST.COSTDETAILS.PS1
# COST DETAILS REPORTS AS A LIVE, READ-ONLY SOURCE
###########################################################################
# A CostDetails source asks Cost Management for ActualCost detail reports
# instead of reading export files. Each month becomes one run, and each run
# has one partition per date chunk (a week by default). A chunk's report is
# generated only when ingestion reads that partition, so the existing
# ingestion, selection, reconciliation, and readiness rules apply unchanged.
#
# Read-only boundaries. This is the only forecast file that calls Azure
# Resource Manager directly, and the safety tests hold it to:
# - one POST, to {scope}/providers/Microsoft.CostManagement/
#   generateCostDetailsReport, which creates a temporary report, not an
#   Azure resource;
# - GETs only to the status link that request returns, after checking it's
#   on the signed-in cloud's Resource Manager host and for the same scope,
#   and to the billing account list, which guided setup uses to find the
#   one EA or MCA account that owns every selected subscription;
# - report downloads without any Azure credential. Cost Management returns
#   short-lived SAS links. They stay in local variables, are never written
#   to messages, the cache, or reports, and only HTTPS blob endpoints of the
#   signed-in cloud are contacted, without following redirects.
#
# Service limits (Microsoft Learn, November 2026): one month or less per
# report, data up to 13 months back, no management group or resource group
# scopes, and day or week chunks for large datasets. Rows correspond to
# when the billing system received a cost, so a report can include charges
# dated outside the requested days. Ingestion reports those separately
# instead of counting them.
# https://learn.microsoft.com/azure/cost-management-billing/automate/get-small-usage-datasets-on-demand
# https://learn.microsoft.com/rest/api/cost-management/generate-cost-details-report
###########################################################################

$script:ForecastCostDetailsApiVersion = '2025-03-01'
$script:ForecastCostDetailsReachMonths = 13
$script:ForecastCostDetailsRecentHours = 4
$script:ForecastCostDetailsMaxWaitSeconds = 1800
$script:ForecastCostDetailsIdleSeconds = 300
$script:ForecastCostDetailsMaxBytes = 2147483591L
$script:ForecastCostDetailsThrottledUntil = $null
$script:ForecastCostDetailsIdPattern = '[A-Za-z0-9][A-Za-z0-9:_.\-]{0,127}'

function Get-ForecastCostDetailsScope {
    # Returns the scope path and its comparison key. Throws for scopes the
    # Cost Details API doesn't support.
    param([AllowNull()][string]$Scope)
    $text = ([string]$Scope).Trim().TrimEnd('/')
    if ($text -and -not $text.StartsWith('/')) { $text = '/' + $text }
    $id = $script:ForecastCostDetailsIdPattern
    $patterns = @(
        '^/subscriptions/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z'
        "^/providers/Microsoft\.Billing/billingAccounts/$id(?:/billingProfiles/$id(?:/invoiceSections/$id)?|/departments/$id|/enrollmentAccounts/$id|/customers/$id)?\z"
    )
    foreach ($pattern in $patterns) {
        if ([regex]::IsMatch($text, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            return [pscustomobject]@{ Path = $text; Key = $text.ToLowerInvariant() }
        }
    }
    throw 'Cost Details needs a subscription or billing scope, such as /subscriptions/<id> or /providers/Microsoft.Billing/billingAccounts/<id>/billingProfiles/<id>. Management groups and resource groups aren''t supported.'
}

function Get-ForecastCostDetailsChunkDays {
    param([Parameter(Mandatory)]$Source)
    $days = 0
    if ([int]::TryParse([string]$Source.chunkDays, [ref]$days) -and $days -ge 1 -and $days -le 31) { return $days }
    return 7
}

function Get-ForecastCostDetailsMonths {
    # Whole months the API can still return (a day inside its 13-month
    # limit), then the current month through yesterday, narrowed by the
    # source's optional fromMonth and toMonth. A fromMonth of Auto starts at
    # EarliestMonth, the first month the forecast period needs, so changing
    # the lookback or fiscal year changes what the next refresh reads.
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)][datetime]$Now, [string]$EarliestMonth)
    $today = (ConvertFrom-ForecastDate -Value $Now).Date
    $reach = $today.AddMonths(-$script:ForecastCostDetailsReachMonths).AddDays(1)
    $first = ConvertTo-ForecastMonthKey -Date $reach
    if ($reach.Day -ne 1) { $first = Add-ForecastMonth -MonthKey $first -Count 1 }
    $yesterday = $today.AddDays(-1)
    $last = ConvertTo-ForecastMonthKey -Date $yesterday
    $from = [string]$Source.fromMonth
    if ($from -eq 'Auto') { $from = $EarliestMonth }
    $to = [string]$Source.toMonth
    if ((Test-ForecastMonthKey -MonthKey $from) -and [string]::CompareOrdinal($from, $first) -gt 0) { $first = $from }
    if ((Test-ForecastMonthKey -MonthKey $to) -and [string]::CompareOrdinal($to, $last) -lt 0) { $last = $to }
    if ([string]::CompareOrdinal($first, $last) -gt 0) { return , [object[]]@() }
    $plans = foreach ($month in (Get-ForecastMonthSpan -First $first -Last $last)) {
        $end = (Get-ForecastMonthEnd -MonthKey $month).AddDays(-1)
        if ($end -gt $yesterday) { $end = $yesterday }
        [pscustomobject]@{ Month = $month; Start = Get-ForecastMonthStart -MonthKey $month; End = $end }
    }
    return , @($plans)
}

function Get-ForecastCostDetailsChunks {
    param([Parameter(Mandatory)][datetime]$Start, [Parameter(Mandatory)][datetime]$End, [Parameter(Mandatory)][int]$Days)
    $chunks = [Collections.Generic.List[object]]::new()
    $cursor = $Start.Date
    while ($cursor -le $End.Date) {
        $chunkEnd = $cursor.AddDays($Days - 1)
        if ($chunkEnd -gt $End.Date) { $chunkEnd = $End.Date }
        $chunks.Add([pscustomobject]@{ Start = $cursor; End = $chunkEnd })
        $cursor = $chunkEnd.AddDays(1)
    }
    return , $chunks.ToArray()
}

function Get-ForecastCostDetailsRuns {
    # One run per month, one partition per chunk. Nothing is requested here;
    # each chunk's report is generated when ingestion reads its partition.
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)][datetime]$Now, [string]$EarliestMonth)
    $scope = Get-ForecastCostDetailsScope -Scope ([string]$Source.scope)
    $days = Get-ForecastCostDetailsChunkDays -Source $Source
    $submitted = ConvertFrom-ForecastDate -Value $Now
    $culture = $script:ForecastInvariant
    $stamp = $submitted.ToString('yyyyMMddTHHmmssZ', $culture)
    $runs = foreach ($plan in (Get-ForecastCostDetailsMonths -Source $Source -Now $Now -EarliestMonth $EarliestMonth)) {
        $parts = foreach ($chunk in (Get-ForecastCostDetailsChunks -Start $plan.Start -End $plan.End -Days $days)) {
            $name = 'costdetails/{0}/{1}-{2}.csv' -f $plan.Month, $chunk.Start.ToString('yyyyMMdd', $culture), $chunk.End.ToString('yyyyMMdd', $culture)
            [pscustomobject]@{ Declared = $name; Name = $name; ByteCount = $null; RowCount = $null; Length = $null; LastModified = $null }
        }
        [pscustomobject]@{
            RunKey = Get-ForecastHash -Text "$($Source.id)|costdetails|$($scope.Key)|$($plan.Month)"
            RunId = "costdetails:$($Source.id):$($plan.Month):$stamp"
            SourceId = [string]$Source.id; Folder = "costdetails/$($plan.Month)/"; ManifestName = $null; ManifestModified = $null
            # Each report's manifest is verified when its partition is read.
            HasManifest = $true; ExportName = 'Cost Details'; OriginalScope = $scope.Key; Dataset = 'ActualCost'
            DataVersion = $script:ForecastCostDetailsApiVersion; Format = 'Csv'
            Start = $plan.Start; End = $plan.End; Submitted = $submitted; Months = @($plan.Month)
            Parts = @($parts); Unsupported = $false; Issues = @()
        }
    }
    return , @($runs)
}

function Test-ForecastCostDetailsFinal {
    # A Complete whole-month read submitted at least the grace period after
    # the month closed. Matches the Final rule in Select-ForecastRuns.
    param([AllowNull()]$Cached, [Parameter(Mandatory)][string]$Month, [Parameter(Mandatory)][string]$ProfileHash, [int]$GraceDays = $script:ForecastDefaultGraceDays)
    if (-not $Cached -or [string]$Cached.Status -ne 'Complete' -or [string]$Cached.ProfileHash -ne $ProfileHash) { return $false }
    $submitted = ConvertFrom-ForecastDate -Value $Cached.Submitted
    $cachedStart = ConvertFrom-ForecastDate -Value $Cached.Start
    $cachedEnd = ConvertFrom-ForecastDate -Value $Cached.End
    if (-not $submitted -or -not $cachedStart -or -not $cachedEnd) { return $false }
    $monthEnd = Get-ForecastMonthEnd -MonthKey $Month
    return $cachedStart.Date -eq (Get-ForecastMonthStart -MonthKey $Month) -and $cachedEnd.Date -ge $monthEnd.AddDays(-1).Date -and $submitted -ge $monthEnd.AddDays($GraceDays)
}

function Test-ForecastCostDetailsReuse {
    # A month read at least the grace period after it closed doesn't change.
    # Cost Management refreshes these reports about every four hours, so a
    # recent read of the same days is still current.
    param(
        [AllowNull()]$Cached,
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][string]$ProfileHash,
        [int]$GraceDays = $script:ForecastDefaultGraceDays,
        [Parameter(Mandatory)][datetime]$Now
    )
    if (Test-ForecastCostDetailsFinal -Cached $Cached -Month ([string]@($Run.Months)[0]) -ProfileHash $ProfileHash -GraceDays $GraceDays) { return $true }
    if (-not $Cached -or [string]$Cached.Status -ne 'Complete' -or [string]$Cached.ProfileHash -ne $ProfileHash) { return $false }
    $submitted = ConvertFrom-ForecastDate -Value $Cached.Submitted
    $cachedStart = ConvertFrom-ForecastDate -Value $Cached.Start
    $cachedEnd = ConvertFrom-ForecastDate -Value $Cached.End
    if (-not $submitted -or -not $cachedStart -or -not $cachedEnd -or $cachedStart.Date -ne ([datetime]$Run.Start).Date) { return $false }
    $current = ConvertFrom-ForecastDate -Value $Now
    return $cachedEnd.Date -eq ([datetime]$Run.End).Date -and $submitted -le $current -and ($current - $submitted).TotalHours -lt $script:ForecastCostDetailsRecentHours
}

function Get-ForecastCostDetailsRetainedKeys {
    # Final months this source read earlier that the API can no longer reach.
    # Until last month passes its grace period, the forecast window still
    # starts one month beyond that reach, so these months stay in the cache.
    # Months outside the source's fromMonth and toMonth aren't kept; with a
    # fromMonth of Auto, earlier final months are, so lowering the lookback
    # and raising it again doesn't lose months the API can't return. Dropped
    # counts final months that were read under a different tag key, boundary,
    # or source setting; they can't be read again.
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Runs,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Cached,
        [Parameter(Mandatory)][string]$ProfileHash,
        [int]$GraceDays = $script:ForecastDefaultGraceDays
    )
    $scope = Get-ForecastCostDetailsScope -Scope ([string]$Source.scope)
    $planned = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($run in $Runs) { [void]$planned.Add([string]$run.RunKey) }
    $from = [string]$Source.fromMonth
    $to = [string]$Source.toMonth
    $keys = [Collections.Generic.List[string]]::new()
    $dropped = [Collections.Generic.List[string]]::new()
    foreach ($record in $Cached) {
        if (-not $record -or $planned.Contains([string]$record.RunKey)) { continue }
        if ([string]$record.SourceId -ne [string]$Source.id -or [string]$record.OriginalScope -ne $scope.Key -or [string]$record.RunId -notlike 'costdetails:*') { continue }
        $months = @($record.Months)
        if ($months.Count -ne 1 -or -not (Test-ForecastMonthKey -MonthKey ([string]$months[0]))) { continue }
        $month = [string]$months[0]
        if ([string]$record.RunKey -ne (Get-ForecastHash -Text "$($Source.id)|costdetails|$($scope.Key)|$month")) { continue }
        if ((Test-ForecastMonthKey -MonthKey $from) -and [string]::CompareOrdinal($month, $from) -lt 0) { continue }
        if ((Test-ForecastMonthKey -MonthKey $to) -and [string]::CompareOrdinal($month, $to) -gt 0) { continue }
        if (Test-ForecastCostDetailsFinal -Cached $record -Month $month -ProfileHash $ProfileHash -GraceDays $GraceDays) { $keys.Add([string]$record.RunKey) }
        elseif (Test-ForecastCostDetailsFinal -Cached $record -Month $month -ProfileHash ([string]$record.ProfileHash) -GraceDays $GraceDays) { $dropped.Add($month) }
    }
    return [pscustomobject]@{ Keys = $keys.ToArray(); Dropped = @($dropped | Sort-Object) }
}

# -- Requests ----------------------------------------------------------------
function Wait-ForecastCostDetails {
    param([Parameter(Mandatory)][int]$Seconds)
    Start-Sleep -Seconds $Seconds
}

function Get-ForecastCostDetailsHeader {
    param($Headers, [Parameter(Mandatory)][string]$Name)
    if (-not $Headers) { return $null }
    foreach ($key in @($Headers.Keys)) {
        if ([string]$key -eq $Name) { return [string]@($Headers[$key])[0] }
    }
    return $null
}

function Get-ForecastCostDetailsRetryAfter {
    param($Headers)
    $seconds = 10
    $parsed = 0
    if ([int]::TryParse([string](Get-ForecastCostDetailsHeader -Headers $Headers -Name 'Retry-After'), [ref]$parsed)) { $seconds = $parsed }
    return [math]::Min(300, [math]::Max(5, $seconds))
}

function Assert-ForecastCostDetailsAvailable {
    $until = $script:ForecastCostDetailsThrottledUntil
    if ($until -and [datetime]::UtcNow -lt $until) {
        throw "Cost Management is throttling Cost Details requests until $($until.ToString('HH:mm', $script:ForecastInvariant)) UTC. Refresh again after that; months already read are kept."
    }
}

function Register-ForecastCostDetailsThrottle {
    # Requests still throttled after Explorer's retries would only draw more
    # 429s, so later chunks in this session wait for the window to end.
    param([Parameter(Mandatory)]$Response)
    if ([int]$Response.StatusCode -ne 429) { return }
    $delay = Get-ServerRetryDelay -Headers $Response.Headers -IsThrottled $true
    if ($delay -lt 0) { $delay = 300 }
    $script:ForecastCostDetailsThrottledUntil = [datetime]::UtcNow.AddSeconds($delay)
}

function Get-ForecastCostDetailsFailure {
    # Uses only the status code and the service's error code and message.
    param([Parameter(Mandatory)]$Response, [Parameter(Mandatory)][string]$Activity)
    $status = [int]$Response.StatusCode
    $code = ''; $message = ''
    try {
        $body = [string]$Response.Content | ConvertFrom-Json -Depth 10 -ErrorAction Stop
        $code = [string]$body.error.code
        $message = [string]$body.error.message
    }
    catch { Write-Verbose 'The error response had no JSON body.' }
    $hint = switch ($status) {
        { $_ -in 401, 403 } { ' The signed-in account needs Cost Management read access at this scope, such as Cost Management Reader or an EA or MCA billing reader role. On EA, the enrollment''s view-charges setting must be on.' }
        400 { ' Check the scope, and that the dates are within the last 13 months.' }
        404 { ' Check the scope ID.' }
        429 { ' Cost Management is throttling these requests. Refresh again later; months already read are kept.' }
        default { '' }
    }
    $detail = if ($code -or $message) { ": $(ConvertTo-ForecastSafeText "$code $message" 300)" } else { '' }
    return "$Activity failed (HTTP $status)$detail.$hint"
}

function ConvertTo-ForecastCostDetailsPollPath {
    # Follows only a status link on the signed-in cloud's Resource Manager
    # host for the same scope, and returns its path and query.
    param([AllowNull()][string]$Location, [Parameter(Mandatory)]$Scope)
    $arm = [uri](Get-FinOpsArmEndpoint)
    $uri = $null
    if ([string]::IsNullOrWhiteSpace($Location) -or $Location -match '[\x00-\x20\\]' -or -not [uri]::TryCreate($Location, [UriKind]::Absolute, [ref]$uri)) {
        throw 'Cost Management didn''t return a usable status link.'
    }
    if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Fragment -or -not $uri.IsDefaultPort -or -not [string]::Equals($uri.Host, $arm.Host, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Cost Management returned a status link outside the signed-in cloud''s Resource Manager endpoint; it wasn''t followed.'
    }
    $path = [uri]::UnescapeDataString($uri.AbsolutePath)
    $match = [regex]::Match($path, '^(?<scope>/.+?)/providers/Microsoft\.CostManagement/costDetailsOperation(?:Results|Status)/[A-Za-z0-9-]{1,100}\z', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success -or -not [string]::Equals($match.Groups['scope'].Value.TrimEnd('/'), $Scope.Path, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Cost Management returned a status link for a different operation or scope; it wasn''t followed.'
    }
    if ($uri.Query -notmatch '^\?(?:[A-Za-z0-9._~%=-]+&)*api-version=[A-Za-z0-9.-]+(?:&[A-Za-z0-9._~%=-]+)*\z') {
        throw 'Cost Management returned a status link with an unexpected query; it wasn''t followed.'
    }
    return $uri.PathAndQuery
}

function ConvertFrom-ForecastCostDetailsResult {
    # Checks a finished report against the request: the same scope, dates,
    # and metric, uncompressed CSV, and file sizes that add up.
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)]$Scope,
        [Parameter(Mandatory)][datetime]$Start,
        [Parameter(Mandatory)][datetime]$End,
        [Parameter(Mandatory)][string]$Activity
    )
    try { $body = [string]$Response.Content | ConvertFrom-Json -Depth 20 -ErrorAction Stop }
    catch { throw "$Activity returned a response that isn't valid JSON." }
    $state = [string]$body.status
    if ($state -match '^(?i)(InProgress|Running|Queued|NotStarted)$') { return [pscustomobject]@{ Status = 'Pending'; Files = @(); ValidTill = $null } }
    if ($state -match '^(?i)NoDataFound$') { return [pscustomobject]@{ Status = 'NoDataFound'; Files = @(); ValidTill = $null } }
    if ($state -match '^(?i)Failed$') { throw "$Activity failed in Cost Management: $(ConvertTo-ForecastSafeText "$($body.error.code) $($body.error.message)" 300)" }
    if ($state -notmatch '^(?i)Completed$') { throw "$Activity returned an unexpected status '$(ConvertTo-ForecastSafeText $state 40)'." }

    $manifest = $body.manifest
    if (-not $manifest) { throw "$Activity completed without a manifest." }
    if ([string]$manifest.dataFormat -and [string]$manifest.dataFormat -ne 'Csv') { throw "$Activity isn't CSV ($(ConvertTo-ForecastSafeText ([string]$manifest.dataFormat) 20))." }
    if ($manifest.compressData -eq $true) { throw "$Activity is compressed, which the forecast doesn't read from Cost Details." }
    $context = $manifest.requestContext
    $requestScope = ([string]$context.requestScope).Trim().TrimEnd('/')
    if ($requestScope -and -not $requestScope.StartsWith('/')) { $requestScope = '/' + $requestScope }
    if (-not $requestScope -or -not [string]::Equals($requestScope, $Scope.Path, [StringComparison]::OrdinalIgnoreCase)) { throw "$Activity came back for a different scope, or didn't say which." }
    $metric = [string]$context.requestBody.metric
    if ($metric -ne 'ActualCost') { throw "$Activity came back as $(if ($metric) { ConvertTo-ForecastSafeText $metric 30 } else { 'an unstated metric' }), not ActualCost." }
    $period = $context.requestBody.timePeriod
    $periodStart = if ($period) { ConvertFrom-ForecastDate -Value $period.start } else { $null }
    $periodEnd = if ($period) { ConvertFrom-ForecastDate -Value $period.end } else { $null }
    if (-not $periodStart -or -not $periodEnd -or $periodStart.Date -ne $Start.Date -or $periodEnd.Date -ne $End.Date) { throw "$Activity came back for different dates, or didn't say which." }
    $files = [Collections.Generic.List[object]]::new()
    $total = 0L
    foreach ($blob in @($manifest.blobs)) {
        if ($null -eq $blob) { continue }
        $size = 0L
        if ([string]::IsNullOrWhiteSpace([string]$blob.blobLink) -or -not [long]::TryParse([string]$blob.byteCount, [ref]$size) -or $size -lt 0) {
            throw "$Activity lists a report file without a link or size."
        }
        $total += $size
        $files.Add([pscustomobject]@{ Link = [string]$blob.blobLink; ByteCount = $size })
    }
    $declared = 0L
    if ($null -ne $manifest.blobCount -and [long]::TryParse([string]$manifest.blobCount, [ref]$declared) -and $declared -ne $files.Count) {
        throw "$Activity lists $($files.Count) file(s) but declares $declared."
    }
    if ($null -ne $manifest.byteCount -and [long]::TryParse([string]$manifest.byteCount, [ref]$declared) -and $declared -ne $total) {
        throw "$Activity files add up to $total bytes but the manifest declares $declared."
    }
    if ($files.Count -eq 0) { return [pscustomobject]@{ Status = 'NoDataFound'; Files = @(); ValidTill = $null } }
    return [pscustomobject]@{ Status = 'Completed'; Files = $files.ToArray(); ValidTill = ConvertFrom-ForecastDate -Value $body.validTill }
}

function Invoke-ForecastCostDetailsReport {
    # Generates one ActualCost report and waits for it, following the
    # service's Retry-After guidance. The scope is validated here, so the
    # only POST this module sends always targets generateCostDetailsReport
    # at a supported scope.
    param([Parameter(Mandatory)][string]$ScopeId, [Parameter(Mandatory)][datetime]$Start, [Parameter(Mandatory)][datetime]$End)
    $Scope = Get-ForecastCostDetailsScope -Scope $ScopeId
    $culture = $script:ForecastInvariant
    $first = $Start.ToString('yyyy-MM-dd', $culture)
    $last = $End.ToString('yyyy-MM-dd', $culture)
    $activity = "The Cost Details report for $first to $last"
    Assert-ForecastCostDetailsAvailable
    $requestPath = "$($Scope.Path)/providers/Microsoft.CostManagement/generateCostDetailsReport?api-version=$($script:ForecastCostDetailsApiVersion)"
    $payload = [ordered]@{ metric = 'ActualCost'; timePeriod = [ordered]@{ start = $first; end = $last } } | ConvertTo-Json -Compress
    $response = Invoke-AzRestMethodWithRetry -Path $requestPath -Method POST -Payload $payload -MaxRetries 4 -TimeoutSeconds 120 -MaxRetryWaitSeconds 900
    Register-ForecastCostDetailsThrottle -Response $response
    $status = [int]$response.StatusCode
    $result = $null
    if ($status -eq 200) { $result = ConvertFrom-ForecastCostDetailsResult -Response $response -Scope $Scope -Start $Start -End $End -Activity $activity }
    elseif ($status -ne 202) { throw (Get-ForecastCostDetailsFailure -Response $response -Activity $activity) }
    if ($result -and $result.Status -ne 'Pending') { return $result }

    $pollPath = ConvertTo-ForecastCostDetailsPollPath -Location (Get-ForecastCostDetailsHeader -Headers $response.Headers -Name 'Location') -Scope $Scope
    $deadline = [datetime]::UtcNow.AddSeconds($script:ForecastCostDetailsMaxWaitSeconds)
    $wait = Get-ForecastCostDetailsRetryAfter -Headers $response.Headers
    try {
        while ($true) {
            if ([datetime]::UtcNow.AddSeconds($wait) -gt $deadline) { throw "$activity wasn't ready after $([int]($script:ForecastCostDetailsMaxWaitSeconds / 60)) minutes. Try fewer days per report (chunkDays)." }
            Write-Progress -Id 83 -ParentId 82 -Activity 'Waiting for Cost Management' -Status "Generating the report for $first to $last"
            Wait-ForecastCostDetails -Seconds $wait
            $poll = Invoke-AzRestMethodWithRetry -Path $pollPath -Method GET -MaxRetries 4 -TimeoutSeconds 120 -MaxRetryWaitSeconds 900
            Register-ForecastCostDetailsThrottle -Response $poll
            $pollStatus = [int]$poll.StatusCode
            if ($pollStatus -eq 202) { $wait = Get-ForecastCostDetailsRetryAfter -Headers $poll.Headers; continue }
            if ($pollStatus -ne 200) { throw (Get-ForecastCostDetailsFailure -Response $poll -Activity $activity) }
            $result = ConvertFrom-ForecastCostDetailsResult -Response $poll -Scope $Scope -Start $Start -End $End -Activity $activity
            if ($result.Status -eq 'Pending') { $wait = Get-ForecastCostDetailsRetryAfter -Headers $poll.Headers; continue }
            return $result
        }
    }
    finally { Write-Progress -Id 83 -Activity 'Waiting for Cost Management' -Completed }
}

# -- Downloads ---------------------------------------------------------------
function Test-ForecastCostDetailsFileUri {
    # Report links must be HTTPS blob endpoints of the signed-in cloud that
    # carry a SAS signature. Messages never include the link.
    param([AllowNull()][string]$Uri)
    $parsed = $null
    if ([string]::IsNullOrWhiteSpace($Uri) -or $Uri -match '[\x00-\x20\\]' -or -not [uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed)) {
        throw 'Cost Management returned a report link that isn''t a valid URL; it wasn''t used.'
    }
    $environment = 'AzureCloud'
    try { $environment = [string](Get-AzContext -ErrorAction Stop).Environment.Name } catch { Write-Verbose 'Using the public cloud blob endpoint.' }
    $hostPattern = '^[a-z0-9]{3,24}\.' + [regex]::Escape((Get-ExportBlobSuffix -Environment $environment)) + '\z'
    if ($parsed.Scheme -ne 'https' -or $parsed.UserInfo -or $parsed.Fragment -or -not $parsed.IsDefaultPort -or $parsed.Host -notmatch $hostPattern -or $parsed.Query -notmatch '(?:^\?|&)sig=') {
        throw 'Cost Management returned a report link outside the signed-in cloud''s blob storage; it wasn''t used.'
    }
    return $parsed
}

function Get-ForecastCostDetailsFileBytes {
    # Downloads one report file. The link is a SAS, so no Azure credential is
    # sent and redirects aren't followed. The size must match the manifest.
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][long]$ExpectedBytes)
    $target = Test-ForecastCostDetailsFileUri -Uri $Uri
    if ($ExpectedBytes -gt $script:ForecastCostDetailsMaxBytes) { throw 'A report file is larger than PowerShell can hold in memory. Use fewer days per report (chunkDays).' }
    $failure = 'unknown error'
    $idle = [TimeSpan]::FromSeconds($script:ForecastCostDetailsIdleSeconds)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.UseDefaultCredentials = $false
    $client = [Net.Http.HttpClient]::new($handler)
    # Large files can take a while, so each wait for headers or data has its own limit instead of one overall timeout.
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $request = $null; $response = $null; $stream = $null
    try {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $target)
        $cancel = [Threading.CancellationTokenSource]::new($idle)
        try { $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token).GetAwaiter().GetResult() }
        finally { $cancel.Dispose() }
        $length = $response.Content.Headers.ContentLength
        if (-not $response.IsSuccessStatusCode) { $failure = "HTTP $([int]$response.StatusCode)" }
        elseif ($null -ne $length -and [long]$length -ne $ExpectedBytes) { $failure = "$length bytes; the report declares $ExpectedBytes" }
        else {
            $buffer = [byte[]]::new([int]$ExpectedBytes)
            $stream = $response.Content.ReadAsStream()
            $offset = 0
            $extra = 0
            $overflow = [byte[]]::new(1)
            while ($true) {
                # One byte past the declared size proves the file isn't longer.
                # Plain assignments keep the array by reference; an if-expression would copy it.
                $into = $overflow; $at = 0; $want = 1
                if ($offset -lt $buffer.Length) { $into = $buffer; $at = $offset; $want = [math]::Min(4194304, $buffer.Length - $offset) }
                $cancel = [Threading.CancellationTokenSource]::new($idle)
                try { $count = $stream.ReadAsync($into, $at, $want, $cancel.Token).GetAwaiter().GetResult() }
                finally { $cancel.Dispose() }
                if ($count -le 0) { break }
                if ($offset -ge $buffer.Length) { $extra = $count; break }
                $offset += $count
            }
            if ($offset -eq $buffer.Length -and $extra -eq 0) { return , $buffer }
            $failure = "the size doesn't match the $ExpectedBytes bytes the report declares"
        }
    }
    catch { $failure = "network error: $($_.Exception.GetBaseException().GetType().Name)" }
    finally {
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        $client.Dispose()
    }
    throw "A report file couldn't be downloaded ($failure)."
}

function Join-ForecastCostDetailsFiles {
    # Combines one report's files into a single CSV. Every file starts with
    # the same header, which is kept once.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Files)
    $bodies = [Collections.Generic.List[object]]::new()
    $header = $null
    $total = 0L
    foreach ($file in $Files) {
        [byte[]]$bytes = $file
        $offset = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
        if ($offset -ge $bytes.Length) { continue }
        $newline = [Array]::IndexOf($bytes, [byte]10, $offset)
        $lineEnd = if ($newline -lt 0) { $bytes.Length } else { $newline }
        if ($lineEnd -gt $offset -and $bytes[$lineEnd - 1] -eq 13) { $lineEnd-- }
        $thisHeader = [Text.Encoding]::UTF8.GetString($bytes, $offset, $lineEnd - $offset)
        if ($null -eq $header) { $header = $thisHeader; $start = $offset }
        elseif ($thisHeader -cne $header) { throw 'The files in one Cost Details report have different columns.' }
        else { $start = if ($newline -lt 0) { $bytes.Length } else { $newline + 1 } }
        $bodies.Add([pscustomobject]@{ Bytes = $bytes; Start = $start })
        $total += $bytes.Length - $start + 2
    }
    if ($total -gt $script:ForecastCostDetailsMaxBytes) { throw 'This report is larger than PowerShell can hold in memory. Use fewer days per report (chunkDays).' }
    $output = [IO.MemoryStream]::new([int][math]::Max(0, $total))
    try {
        $lineBreak = [byte[]]@(13, 10)
        foreach ($body in $bodies) {
            $count = $body.Bytes.Length - $body.Start
            if ($count -le 0) { continue }
            if ($output.Length -gt 0 -and $output.GetBuffer()[$output.Length - 1] -ne 10) { $output.Write($lineBreak, 0, 2) }
            $output.Write($body.Bytes, $body.Start, $count)
        }
        return , $output.ToArray()
    }
    finally { $output.Dispose() }
}

function Read-ForecastCostDetailsPartition {
    # Generates the report for one partition's days and returns its CSV
    # bytes. An empty array means Cost Management found no cost data.
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)][string]$Name)
    $culture = $script:ForecastInvariant
    if ($Name -notmatch '^costdetails/(\d{4}-\d{2})/(\d{8})-(\d{8})\.csv\z') { throw 'This isn''t a Cost Details partition.' }
    $month = $Matches[1]
    $start = [datetime]::SpecifyKind([datetime]::ParseExact($Matches[2], 'yyyyMMdd', $culture), [DateTimeKind]::Utc)
    $end = [datetime]::SpecifyKind([datetime]::ParseExact($Matches[3], 'yyyyMMdd', $culture), [DateTimeKind]::Utc)
    if ($end -lt $start -or (ConvertTo-ForecastMonthKey -Date $start) -ne $month -or (ConvertTo-ForecastMonthKey -Date $end) -ne $month) { throw 'The Cost Details partition has invalid dates.' }
    $report = Invoke-ForecastCostDetailsReport -ScopeId ([string]$Source.scope) -Start $start -End $end
    if ($report.Status -eq 'NoDataFound') { return , [byte[]]::new(0) }
    $buffers = [Collections.Generic.List[byte[]]]::new()
    foreach ($file in $report.Files) {
        if ($report.ValidTill -and [datetime]::UtcNow -ge $report.ValidTill) { throw 'The report''s download links expired before every file was read. Refresh again.' }
        $buffers.Add((Get-ForecastCostDetailsFileBytes -Uri $file.Link -ExpectedBytes $file.ByteCount))
    }
    if ($buffers.Count -eq 1) { return , $buffers[0] }
    return , (Join-ForecastCostDetailsFiles -Files $buffers.ToArray())
}

# -- Billing scopes ----------------------------------------------------------
function Get-ForecastCostDetailsBillingScopes {
    # The EA or MCA billing account that owns every selected subscription, as
    # a Cost Details scope. One read-only list call here; Explorer's
    # Get-FinOpsBillingScope confirms each subscription's owner. Returns
    # nothing when billing data can't be read, any subscription's owner isn't
    # confirmed, or the subscriptions belong to more than one account, so a
    # billing-account read never misses a selected subscription.
    param([Parameter(Mandatory)][object[]]$Subscriptions)
    $billingPath = '/providers/Microsoft.Billing/billingAccounts?api-version=2024-04-01'
    $owners = $null
    try {
        $response = Invoke-AzRestMethodWithRetry -Path $billingPath -Method GET -MaxRetries 2 -TimeoutSeconds 60
        if ([int]$response.StatusCode -ne 200) { return , [object[]]@() }
        $listed = Get-FinOpsListResult -FirstResponse $response -Context 'billing accounts for the forecast'
        $accounts = @($listed.value | Where-Object { $_ -and [string]$_.name -match '^[A-Za-z0-9_.():-]+$' -and [string]$_.id -eq "/providers/Microsoft.Billing/billingAccounts/$($_.name)" })
        if ($accounts.Count -eq 0) { return , [object[]]@() }
        $owners = Get-FinOpsBillingScope -BillingAccounts $accounts -Subscriptions $Subscriptions
    }
    catch {
        Write-Verbose "Billing accounts couldn't be read: $($_.Exception.Message)"
        return , [object[]]@()
    }
    $owning = @($owners.Accounts | Where-Object { $_ })
    if (-not $owners.Resolved -or $owners.CoverageIncomplete -or $owning.Count -ne 1) {
        Write-Verbose "No single billing account confirmed for all $(@($Subscriptions).Count) subscriptions: $(@($owning).Count) owner(s); $([string]$owners.Reason)"
        return , [object[]]@()
    }
    $account = $owning[0]
    $agreement = switch -Regex ([string]$account.properties.agreementType) {
        '^(?i)EnterpriseAgreement$' { 'EA' }
        '^(?i)MicrosoftCustomerAgreement$' { 'MCA' }
        default { $null }
    }
    if (-not $agreement) { return , [object[]]@() }
    try { $scope = (Get-ForecastCostDetailsScope -Scope ([string]$account.id)).Path } catch { return , [object[]]@() }
    $name = ConvertTo-ForecastSafeText ([string]$account.properties.displayName) 80
    return , @([pscustomobject]@{ Scope = $scope; Name = $(if ($name) { $name } else { [string]$account.name }); Agreement = $agreement })
}
