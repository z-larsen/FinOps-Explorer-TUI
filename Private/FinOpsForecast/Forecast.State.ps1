# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers that build objects or write only the private local forecast workspace; nothing in Azure changes.')]
param()

###########################################################################
# FORECAST.STATE.PS1
# PRIVATE LOCAL WORKSPACE
###########################################################################
# Layout under LocalApplicationData/FinOpsToolkit/Explorer/Forecast/<name>:
#   settings.json       sources, scope, period, assumptions, scheduled items
#   inputs.json         manual monthly inputs (manual mode only)
#   reviews.json        review decisions keyed by exception, with fingerprints
#   refresh-log.json    the last 50 refresh attempts
#   cache/current/      the last successful refresh (one file per run)
#   vintages/           immutable saved forecasts
# The workspace uses FinOps Explorer's private-directory checks: local disk,
# no links, no Git repositories, owner-only access. Every write goes through
# Write-ForecastStateFile, which writes a temporary file and then replaces
# the target, so a crash never leaves a half-written file. A refresh builds a
# staging cache and swaps it in only when it succeeds, so a failed refresh
# keeps the previous data.
###########################################################################

$script:ForecastStateNamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$'
$script:ForecastPrivateDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function Get-ForecastDefaultWorkspaceBase {
    return (Join-Path (Split-Path -Path (Get-FinOpsReportRoot) -Parent) 'Forecast')
}

function Get-ForecastWorkspaceRoot {
    param([string]$WorkspaceName = 'default', [string]$WorkspacePath)
    if ($WorkspaceName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw 'The workspace name must be 1-64 letters, digits, dots, dashes, or underscores.' }
    $base = if ([string]::IsNullOrWhiteSpace($WorkspacePath)) { Get-ForecastDefaultWorkspaceBase } else { $WorkspacePath }
    $root = Assert-FinOpsReportPath -Path (Join-Path $base $WorkspaceName)
    $root = New-FinOpsPrivateDirectory -Path $root
    [void]$script:ForecastPrivateDirectories.Add($root)
    return $root
}

function Resolve-ForecastStatePath {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath)
    $segments = @($RelativePath -split '/')
    foreach ($segment in $segments) { if ($segment -notmatch $script:ForecastStateNamePattern) { throw "Invalid workspace path '$(ConvertTo-ForecastSafeText $RelativePath 120)'." } }
    $full = [IO.Path]::GetFullPath((Join-Path $Root ($segments -join [IO.Path]::DirectorySeparatorChar)))
    $prefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::Ordinal)) { throw 'Workspace paths must stay inside the workspace.' }
    return $full
}

function Initialize-ForecastStateDirectory {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath)
    $path = Resolve-ForecastStatePath -Root $Root -RelativePath $RelativePath
    if (-not $script:ForecastPrivateDirectories.Contains($path)) {
        $path = New-FinOpsPrivateDirectory -Path $path
        [void]$script:ForecastPrivateDirectories.Add($path)
    }
    return $path
}

function Write-ForecastStateFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [switch]$CreateNew
    )
    $target = Resolve-ForecastStatePath -Root $Root -RelativePath $RelativePath
    $parentRelative = if ($RelativePath.Contains('/')) { $RelativePath.Substring(0, $RelativePath.LastIndexOf('/')) } else { $null }
    if ($parentRelative) { $null = Initialize-ForecastStateDirectory -Root $Root -RelativePath $parentRelative }
    if ($CreateNew -and [IO.File]::Exists($target)) { throw "The workspace file $RelativePath already exists and is never overwritten." }
    $temporary = "$target.tmp-$([guid]::NewGuid().ToString('N'))"
    $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        if (-not $IsWindows) {
            $unixModeType = 'System.IO.UnixFileMode' -as [type]
            if ($unixModeType) { [IO.File]::SetUnixFileMode($temporary, [Enum]::ToObject($unixModeType, 384)) }
        }
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        try { $writer.Write($Content) } finally { $writer.Dispose() }
    }
    finally { $stream.Dispose() }
    try {
        if ($CreateNew) { [IO.File]::Move($temporary, $target, $false) } else { [IO.File]::Move($temporary, $target, $true) }
    }
    catch {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        throw
    }
    return $target
}

function Read-ForecastStateFile {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath)
    $path = Resolve-ForecastStatePath -Root $Root -RelativePath $RelativePath
    if (-not [IO.File]::Exists($path)) { return $null }
    return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
}

function Read-ForecastStateJson {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath)
    $text = Read-ForecastStateFile -Root $Root -RelativePath $RelativePath
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { return ($text | ConvertFrom-Json -Depth 40 -ErrorAction Stop) }
    catch { throw "The workspace file $RelativePath is damaged: $($_.Exception.Message)" }
}

function Write-ForecastStateJson {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath, [Parameter(Mandatory)][AllowNull()]$Value, [switch]$CreateNew)
    $json = ConvertTo-Json -InputObject $Value -Depth 40
    return Write-ForecastStateFile -Root $Root -RelativePath $RelativePath -Content $json -CreateNew:$CreateNew
}

# -- Settings, inputs, and reviews ----------------------------------------
function Get-ForecastStoredSettings {
    param([Parameter(Mandatory)][string]$Root)
    return ConvertTo-ForecastSettings -Loaded (Read-ForecastStateJson -Root $Root -RelativePath 'settings.json')
}

function Save-ForecastStoredSettings {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Settings)
    $null = Write-ForecastStateJson -Root $Root -RelativePath 'settings.json' -Value $Settings
}

function Get-ForecastStoredInputs {
    param([Parameter(Mandatory)][string]$Root)
    return ConvertTo-ForecastInputs -Loaded (Read-ForecastStateJson -Root $Root -RelativePath 'inputs.json')
}

function Save-ForecastStoredInputs {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Inputs)
    $null = Write-ForecastStateJson -Root $Root -RelativePath 'inputs.json' -Value $Inputs
}

function Get-ForecastStoredReviews {
    param([Parameter(Mandatory)][string]$Root)
    $reviews = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $loaded = Read-ForecastStateJson -Root $Root -RelativePath 'reviews.json'
    if ($loaded) { foreach ($property in $loaded.PSObject.Properties) { $reviews[$property.Name] = $property.Value } }
    return , $reviews
}

function Set-ForecastReviewDecision {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][string]$Decision,
        [string]$Note,
        [string]$Value
    )
    if ($Decision -notin @($Item.Options)) { throw "'$Decision' isn't an option for this review. Options: $(@($Item.Options) -join ', ')." }
    if ($Decision -eq 'Manual' -and ($null -eq (Read-ForecastDecimal -Value $Value) -or [string]::IsNullOrWhiteSpace($Note))) { throw 'A manual baseline needs a non-negative value and a reason.' }
    $reviews = Get-ForecastStoredReviews -Root $Root
    $reviews[[string]$Item.Key] = [pscustomobject]@{
        decision = $Decision; fingerprint = [string]$Item.Fingerprint; note = ConvertTo-ForecastSafeText -Text $Note -MaxLength 500
        value = if ($Value) { Format-ForecastDecimal (Read-ForecastDecimal -Value $Value) } else { $null }
        title = ConvertTo-ForecastSafeText -Text $Item.Title -MaxLength 200; decidedUtc = [datetime]::UtcNow.ToString('o', $script:ForecastInvariant)
        decidedBy = ConvertTo-ForecastSafeText -Text ([Environment]::UserName) -MaxLength 100
    }
    $ordered = [ordered]@{}
    foreach ($key in (@($reviews.Keys) | Sort-Object -CaseSensitive)) { $ordered[$key] = $reviews[$key] }
    $null = Write-ForecastStateJson -Root $Root -RelativePath 'reviews.json' -Value ([pscustomobject]$ordered)
}

function Move-ForecastStateDirectory {
    # Antivirus and search indexing can briefly lock files that were just
    # written, so a directory rename can fail with access denied. Retry for a
    # few seconds before giving up.
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    for ($attempt = 1; ; $attempt++) {
        try { [IO.Directory]::Move($Source, $Destination); return }
        catch {
            $reason = $_.Exception.GetBaseException()
            if ($attempt -ge 6 -or -not ($reason -is [IO.IOException] -or $reason -is [UnauthorizedAccessException])) { throw }
            Start-Sleep -Milliseconds (250 * $attempt)
        }
    }
}

# -- Refresh cache ---------------------------------------------------------
function Get-ForecastCache {
    # Returns the last successful refresh, restoring it if a previous swap
    # was interrupted between its two renames.
    param([Parameter(Mandatory)][string]$Root)
    $cacheDirectory = Resolve-ForecastStatePath -Root $Root -RelativePath 'cache'
    $current = Join-Path $cacheDirectory 'current'
    if (-not [IO.Directory]::Exists($current) -and [IO.Directory]::Exists($cacheDirectory)) {
        $previous = @([IO.Directory]::GetDirectories($cacheDirectory, 'previous-*') | Sort-Object -Descending)[0]
        if ($previous) { Move-ForecastStateDirectory -Source $previous -Destination $current }
    }
    $meta = Read-ForecastStateJson -Root $Root -RelativePath 'cache/current/cache.json'
    if (-not $meta) { return $null }
    $results = [Collections.Generic.List[object]]::new()
    foreach ($runKey in @($meta.runKeys)) {
        $record = Read-ForecastStateJson -Root $Root -RelativePath "cache/current/runs/$runKey.json"
        if (-not $record) { throw "The cached run $runKey is missing. Refresh the data." }
        $results.Add((ConvertFrom-ForecastCacheRecord -Record $record))
    }
    [pscustomobject]@{ Meta = $meta; Results = $results.ToArray() }
}

function Get-ForecastCachedRunText {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RunKey)
    return Read-ForecastStateFile -Root $Root -RelativePath "cache/current/runs/$RunKey.json"
}

function Publish-ForecastCache {
    # Writes a complete staging cache, then swaps it in with two renames.
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RunTexts,
        [Parameter(Mandatory)]$Meta
    )
    $staging = "staging-$([guid]::NewGuid().ToString('N'))"
    try {
        foreach ($run in $RunTexts) { $null = Write-ForecastStateFile -Root $Root -RelativePath "cache/$staging/runs/$($run.RunKey).json" -Content $run.Text }
        $null = Write-ForecastStateJson -Root $Root -RelativePath "cache/$staging/cache.json" -Value $Meta
        $cacheDirectory = Resolve-ForecastStatePath -Root $Root -RelativePath 'cache'
        $current = Join-Path $cacheDirectory 'current'
        $previous = $null
        if ([IO.Directory]::Exists($current)) {
            $previous = Join-Path $cacheDirectory "previous-$([datetime]::UtcNow.ToString('yyyyMMddTHHmmssfff', $script:ForecastInvariant))"
            Move-ForecastStateDirectory -Source $current -Destination $previous
        }
        Move-ForecastStateDirectory -Source (Join-Path $cacheDirectory $staging) -Destination $current
        [void]$script:ForecastPrivateDirectories.Remove((Join-Path $cacheDirectory $staging))
        if ($previous) { Remove-Item -LiteralPath $previous -Recurse -Force -ErrorAction SilentlyContinue }
    }
    catch {
        $stagingPath = Resolve-ForecastStatePath -Root $Root -RelativePath "cache/$staging"
        if ([IO.Directory]::Exists($stagingPath)) { Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Add-ForecastRefreshLog {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Entry)
    $log = @(Read-ForecastStateJson -Root $Root -RelativePath 'refresh-log.json')
    $log = @(@($log | Where-Object { $_ }) + $Entry | Select-Object -Last 50)
    $null = Write-ForecastStateJson -Root $Root -RelativePath 'refresh-log.json' -Value $log
}

function Get-ForecastRefreshState {
    param([Parameter(Mandatory)][string]$Root)
    $log = @(Read-ForecastStateJson -Root $Root -RelativePath 'refresh-log.json' | Where-Object { $_ })
    if ($log.Count -eq 0) { return $null }
    $last = $log[-1]
    $success = @($log | Where-Object Result -EQ 'Succeeded')[-1]
    [pscustomobject]@{
        LastAttemptUtc = $last.AttemptUtc; LastAttemptResult = $last.Result; LastError = $last.Error
        LastSuccessUtc = if ($success) { $success.AttemptUtc } else { $null }
        LastSuccess = $success; Log = $log
    }
}

# -- Vintages --------------------------------------------------------------
function Save-ForecastVintage {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Vintage)
    $name = "{0}-{1}.json" -f ([datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ', $script:ForecastInvariant)), $Vintage.id
    $null = Write-ForecastStateJson -Root $Root -RelativePath "vintages/$name" -Value $Vintage -CreateNew
    return $name
}

function Get-ForecastVintages {
    param([Parameter(Mandatory)][string]$Root)
    $directory = Resolve-ForecastStatePath -Root $Root -RelativePath 'vintages'
    if (-not [IO.Directory]::Exists($directory)) { return @() }
    $vintages = foreach ($file in ([IO.Directory]::GetFiles($directory, '*.json') | Sort-Object)) {
        $name = [IO.Path]::GetFileName($file)
        $vintage = Read-ForecastStateJson -Root $Root -RelativePath "vintages/$name"
        [pscustomobject]@{
            File = $name; Id = $vintage.id; CreatedUtc = $vintage.createdUtc; FiscalYear = $vintage.fiscalYear.label
            Currency = $vintage.currency; TotalLow = $vintage.fiscalYear.totalLow; TotalCentral = $vintage.fiscalYear.totalCentral; TotalHigh = $vintage.fiscalYear.totalHigh
            Ready = $vintage.ready; Vintage = $vintage
        }
    }
    return $vintages
}
