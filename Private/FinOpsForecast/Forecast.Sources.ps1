# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
param()

###########################################################################
# FORECAST.SOURCES.PS1
# EXPORT LOCATIONS AND RUN DISCOVERY
###########################################################################
# Two read-only locations are supported:
# - AzureStorage: the storage account and container an export delivers to.
#   Listing and downloads reuse FinOps Explorer's storage helpers with an
#   Entra ID token (Storage Blob Data Reader on the account).
# - LocalFolder:  a local copy of that container with the same folder layout,
#   for example one made with AzCopy or Storage Explorer.
#
# Each export run writes manifest.json beside its partitions. The manifest
# lists runInfo (runId, submittedTime, startDate, endDate), exportConfig
# (resourceId, type, dataVersion) and every blob with byteCount and
# dataRowCount. Runs without a manifest are legacy runs: one file per run,
# readable only after a reviewer approves them.
# https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-improved-exports
###########################################################################

function Get-ForecastStorageAccountName {
    param([Parameter(Mandatory)][string]$ResourceId)
    if ($ResourceId -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Storage/storageAccounts/([a-z0-9]{3,24})$') {
        throw 'The source has an invalid storage account resource ID.'
    }
    return $Matches[1]
}

function Get-ForecastLocalRoot {
    param([Parameter(Mandatory)]$Source)
    $path = [string]$Source.path
    if ($path -match '^[\\/]{2}' -or $path -match '[\x00-\x1f]') { throw 'Local export folders must be on a local drive.' }
    $full = [IO.Path]::GetFullPath($path)
    if (-not [IO.Directory]::Exists($full)) { throw "The local export folder doesn't exist: $(ConvertTo-ForecastSafeText $full 200)" }
    return $full
}

function Test-ForecastBlobName {
    param([AllowNull()][string]$Name)
    return -not ([string]::IsNullOrWhiteSpace($Name) -or $Name -match '(?:^|/)\.{1,2}(?:/|$)|[\\\p{Cc}\p{Cf}]')
}

function Get-ForecastSourceBlobs {
    # Returns every blob under the source prefix as Name (container-relative,
    # '/' separated), LastModified (UTC), and Length when the location knows it.
    param([Parameter(Mandatory)]$Source)
    $prefix = ([string]$Source.prefix).Trim('/')
    $blobs = [Collections.Generic.List[object]]::new()
    switch ([string]$Source.kind) {
        'LocalFolder' {
            $root = Get-ForecastLocalRoot -Source $Source
            $start = if ($prefix) { Join-Path $root $prefix } else { $root }
            if (-not [IO.Directory]::Exists($start)) { throw "The export folder prefix doesn't exist under the local source." }
            foreach ($file in [IO.Directory]::EnumerateFiles($start, '*', [IO.SearchOption]::AllDirectories)) {
                $info = [IO.FileInfo]::new($file)
                if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Local export folders can''t contain links.' }
                $name = [IO.Path]::GetRelativePath($root, $file).Replace('\', '/')
                $blobs.Add([pscustomobject]@{ Name = $name; LastModified = $info.LastWriteTimeUtc; Length = $info.Length })
            }
        }
        'AzureStorage' {
            $account = Get-ForecastStorageAccountName -ResourceId ([string]$Source.storageResourceId)
            $environment = 'AzureCloud'
            try { $environment = [string](Get-AzContext -ErrorAction Stop).Environment.Name } catch { Write-Verbose 'Using the public cloud blob endpoint.' }
            $blobBase = "https://$account.$(Get-ExportBlobSuffix -Environment $environment)"
            $listPrefix = if ($prefix) { "$prefix/" } else { '' }
            $listed = Get-StorageBlobList -BlobBase $blobBase -Container ([string]$Source.container) -Prefix $listPrefix
            if (-not $listed.Listed) { throw 'The export container couldn''t be listed.' }
            foreach ($blob in $listed.Blobs) {
                $modified = if ($blob.LastModified) { ConvertFrom-ForecastDate -Value $blob.LastModified } else { $null }
                $blobs.Add([pscustomobject]@{ Name = [string]$blob.Name; LastModified = $modified; Length = $null })
            }
        }
        default { throw "Unknown source kind '$($Source.kind)'." }
    }
    foreach ($blob in $blobs) {
        if (-not (Test-ForecastBlobName -Name $blob.Name)) { throw 'The export listing contains an unsafe blob path; nothing was read.' }
    }
    return , $blobs.ToArray()
}

function Read-ForecastSourceBlob {
    # Returns the blob's raw bytes. Throws when the blob can't be read.
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-ForecastBlobName -Name $Name)) { throw 'Refusing to read an unsafe blob path.' }
    switch ([string]$Source.kind) {
        'LocalFolder' {
            $root = Get-ForecastLocalRoot -Source $Source
            $path = [IO.Path]::GetFullPath((Join-Path $root $Name))
            if (-not $path.StartsWith($root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to read outside the local export folder.' }
            return , [IO.File]::ReadAllBytes($path)
        }
        'AzureStorage' {
            $account = Get-ForecastStorageAccountName -ResourceId ([string]$Source.storageResourceId)
            $environment = 'AzureCloud'
            try { $environment = [string](Get-AzContext -ErrorAction Stop).Environment.Name } catch { Write-Verbose 'Using the public cloud blob endpoint.' }
            $encoded = (($Name -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
            $uri = "https://$account.$(Get-ExportBlobSuffix -Environment $environment)/$([string]$Source.container)/$encoded"
            $bytes = Get-StorageBlobBytes -Uri $uri
            if ($null -eq $bytes) { throw "Blob '$(ConvertTo-ForecastSafeText $Name 200)' couldn't be read." }
            return , $bytes
        }
        default { throw "Unknown source kind '$($Source.kind)'." }
    }
}

function Get-ForecastManifestScope {
    param([AllowNull()][string]$ResourceId)
    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return $null }
    $end = $ResourceId.IndexOf('/providers/Microsoft.CostManagement/exports/', [StringComparison]::OrdinalIgnoreCase)
    $scope = if ($end -gt 0) { $ResourceId.Substring(0, $end) } else { $ResourceId }
    $scope = $scope.Trim().TrimEnd('/').ToLowerInvariant()
    if ($scope -match '[\p{Cc}\p{Cf}]') { return $null }
    return $scope
}

function Get-ForecastRunLastDate {
    param([AllowNull()]$Start, [AllowNull()]$End)
    if ($null -eq $End) { return $null }
    $last = [datetime]$End
    # Keep the existing exclusive-end convention for midnight on a month's first day.
    if ($null -ne $Start -and $last -gt $Start -and $last.Day -eq 1 -and $last.TimeOfDay -eq [TimeSpan]::Zero) { $last = $last.AddDays(-1) }
    return $last.Date
}

function Get-ForecastRunMonths {
    param([AllowNull()]$Start, [AllowNull()]$End)
    if ($null -eq $Start) { return , [string[]]@() }
    $last = if ($null -ne $End -and $End -ge $Start) { $End } else { $Start }
    $last = Get-ForecastRunLastDate -Start $Start -End $last
    return , [string[]](Get-ForecastMonthSpan -First (ConvertTo-ForecastMonthKey -Date $Start) -Last (ConvertTo-ForecastMonthKey -Date $last))
}

function Find-ForecastExportRuns {
    # Builds one run record per manifest, plus one legacy run per CSV file that
    # no manifest claims. Parquet runs are reported as unsupported.
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Blobs)
    $runs = [Collections.Generic.List[object]]::new()
    $byName = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($blob in $Blobs) { $byName[$blob.Name] = $blob }
    $claimed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    foreach ($manifestBlob in @($Blobs | Where-Object { $_.Name -match '(?:^|/)manifest\.json$' })) {
        $folder = if ($manifestBlob.Name.Contains('/')) { $manifestBlob.Name.Substring(0, $manifestBlob.Name.LastIndexOf('/') + 1) } else { '' }
        $issues = [Collections.Generic.List[object]]::new()
        $manifest = $null
        try { $manifest = [Text.Encoding]::UTF8.GetString((Read-ForecastSourceBlob -Source $Source -Name $manifestBlob.Name)) | ConvertFrom-Json -Depth 20 -ErrorAction Stop }
        catch { $issues.Add((New-ForecastIssue -Code 'RUN-MANIFEST' -Message "Manifest $(ConvertTo-ForecastSafeText $manifestBlob.Name 200) couldn't be read: $(ConvertTo-ForecastSafeText $_.Exception.Message 200)")) }
        $runId = if ($manifest) { [string]$manifest.runInfo.runId } else { '' }
        if ([string]::IsNullOrWhiteSpace($runId)) { $runId = 'folder:' + (Get-ForecastHash -Text "$($Source.id)|$folder") }
        $start = if ($manifest) { ConvertFrom-ForecastDate -Value $manifest.runInfo.startDate } else { $null }
        $end = if ($manifest) { ConvertFrom-ForecastDate -Value $manifest.runInfo.endDate } else { $null }
        $submitted = if ($manifest) { ConvertFrom-ForecastDate -Value $manifest.runInfo.submittedTime } else { $null }
        if ($manifest -and -not $submitted) { $issues.Add((New-ForecastIssue -Code 'RUN-MANIFEST' -Message 'The manifest has no readable submittedTime.')) }
        if ($manifest -and -not $start) { $issues.Add((New-ForecastIssue -Code 'RUN-MANIFEST' -Message 'The manifest has no readable startDate.')) }
        if ($manifest -and -not $end) { $issues.Add((New-ForecastIssue -Code 'RUN-MANIFEST' -Message 'The manifest has no readable endDate.')) }
        elseif ($start -and $end -lt $start) { $issues.Add((New-ForecastIssue -Code 'RUN-MANIFEST' -Message 'The manifest endDate precedes its startDate.')) }
        $format = if ($manifest) { [string]$manifest.deliveryConfig.fileFormat } else { '' }
        $parts = [Collections.Generic.List[object]]::new()
        $partitionNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($declared in @($manifest.blobs)) {
            if ($null -eq $declared) { continue }
            $declaredName = ([string]$declared.blobName).TrimStart('/')
            $leaf = if ($declaredName.Contains('/')) { $declaredName.Substring($declaredName.LastIndexOf('/') + 1) } else { $declaredName }
            # Manifests name blobs from the container root; a local copy may
            # start lower, so fall back to the file name inside this run folder.
            $resolved = if ($byName.ContainsKey($declaredName)) { $declaredName } elseif ($leaf -and $byName.ContainsKey($folder + $leaf)) { $folder + $leaf } else { $null }
            $identity = if ($resolved) { $resolved } else { $declaredName }
            if (-not $partitionNames.Add($identity)) {
                $issues.Add((New-ForecastIssue -Code 'RUN-DUPLICATEPARTITION' -Message "The manifest lists partition $(ConvertTo-ForecastSafeText $identity 200) more than once. The run isn't used."))
                continue
            }
            $byteCount = $null; $rowCount = $null
            $parsedLong = 0L
            if ($null -ne $declared.byteCount -and [long]::TryParse([string]$declared.byteCount, [ref]$parsedLong)) { $byteCount = $parsedLong }
            if ($null -ne $declared.dataRowCount -and [long]::TryParse([string]$declared.dataRowCount, [ref]$parsedLong)) { $rowCount = $parsedLong }
            if ($resolved) { [void]$claimed.Add($resolved) }
            $parts.Add([pscustomobject]@{
                    Declared = $declaredName; Name = $resolved; ByteCount = $byteCount; RowCount = $rowCount
                    Length = if ($resolved) { $byName[$resolved].Length } else { $null }
                    LastModified = if ($resolved) { $byName[$resolved].LastModified } else { $null }
                })
        }
        if ($manifest -and $parts.Count -eq 0 -and $manifest.PSObject.Properties.Name -contains 'blobs') {
            $issues.Add((New-ForecastIssue -Code 'RUN-EMPTY' -Severity 'Info' -Message 'The manifest lists no partitions; the run has no data rows.'))
        }
        $unsupported = $format -match '(?i)parquet' -or @($parts | Where-Object { $_.Declared -match '\.parquet$' }).Count -gt 0
        $runs.Add([pscustomobject]@{
                RunKey        = Get-ForecastHash -Text "$($Source.id)|$runId|$folder"
                RunId         = $runId
                SourceId      = [string]$Source.id
                Folder        = $folder
                ManifestName  = $manifestBlob.Name
                ManifestModified = $manifestBlob.LastModified
                HasManifest   = $null -ne $manifest
                ExportName    = if ($manifest) { ConvertTo-ForecastSafeText ([string]$manifest.exportConfig.exportName) 120 } else { '' }
                OriginalScope = if ($manifest) { Get-ForecastManifestScope -ResourceId ([string]$manifest.exportConfig.resourceId) } else { $null }
                Dataset       = if ($manifest) { [string]$manifest.exportConfig.type } else { '' }
                DataVersion   = if ($manifest) { [string]$manifest.exportConfig.dataVersion } else { '' }
                Format        = $format
                Start         = $start
                End           = $end
                Submitted     = $submitted
                Months        = Get-ForecastRunMonths -Start $start -End $end
                Parts         = $parts.ToArray()
                Unsupported   = $unsupported
                Issues        = $issues.ToArray()
            })
    }

    foreach ($blob in @($Blobs | Where-Object { $_.Name -match '\.(csv|csv\.gz|parquet)$' -and -not $claimed.Contains($_.Name) })) {
        $folder = if ($blob.Name.Contains('/')) { $blob.Name.Substring(0, $blob.Name.LastIndexOf('/') + 1) } else { '' }
        # A run folder named with a GUID or containing part files always has a manifest.
        if ($folder -match '/[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}/$' -or $blob.Name -match '/part_\d+(?:_\d+)?\.csv(?:\.gz)?$') {
            $issues = @(New-ForecastIssue -Code 'RUN-NOMANIFEST' -Message "Partition $(ConvertTo-ForecastSafeText $blob.Name 200) has no manifest, so the run may still be writing or be incomplete.")
        }
        else { $issues = @() }
        $start = $null; $end = $null
        if ($blob.Name -match '/(\d{8})-(\d{8})/') {
            $start = ConvertFrom-ForecastDate -Value $Matches[1]
            $end = ConvertFrom-ForecastDate -Value $Matches[2]
        }
        $runs.Add([pscustomobject]@{
                RunKey = Get-ForecastHash -Text "$($Source.id)|legacy|$($blob.Name)"; RunId = "legacy:$($blob.Name)"; SourceId = [string]$Source.id
                Folder = $folder; ManifestName = $null; HasManifest = $false; ExportName = ''; OriginalScope = $null; Dataset = ''; DataVersion = ''
                Format = if ($blob.Name -match '\.parquet$') { 'Parquet' } else { 'Csv' }
                Start = $start; End = $end; Submitted = $blob.LastModified; Months = Get-ForecastRunMonths -Start $start -End $end
                Parts = @([pscustomobject]@{ Declared = $blob.Name; Name = $blob.Name; ByteCount = $null; RowCount = $null; Length = $blob.Length; LastModified = $blob.LastModified })
                Unsupported = $blob.Name -match '\.parquet$'; Issues = $issues
            })
    }
    return , $runs.ToArray()
}

function Get-ForecastRunSignature {
    # Changes when the run's manifest, partitions, or delivery time change, so
    # a cached ingest is reused only for the identical run.
    param([Parameter(Mandatory)]$Run)
    $parts = @($Run.Parts | ForEach-Object {
            $modified = if ($_.LastModified) { (ConvertFrom-ForecastDate $_.LastModified).ToString('o', $script:ForecastInvariant) } else { '' }
            "$($_.Declared)=$($_.Name)=$($_.ByteCount)=$($_.RowCount)=$($_.Length)=$modified"
        }) -join ';'
    $dates = @(foreach ($name in 'Submitted', 'Start', 'End', 'ManifestModified') {
            if ($Run.$name) { (ConvertFrom-ForecastDate $Run.$name).ToString('o', $script:ForecastInvariant) } else { '' }
        }) -join '|'
    return Get-ForecastHash -Text "$($Run.RunId)|$($Run.Folder)|$($Run.Dataset)|$($Run.OriginalScope)|$($Run.DataVersion)|$($Run.HasManifest)|$dates|$parts"
}
