# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console; Write-FinOpsConsole is the user interface.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
param()

###########################################################################
# FORECAST.CONSOLE.PS1
# SETUP & REVIEW PAGE AND REVIEW SCREENS
###########################################################################
# Every screen uses numbered prompts, so it works the same in rich consoles,
# remoting sessions, and -Accessible mode (no screen clearing). Three empty
# answers in a row leave a screen, so a host that can't prompt never loops.
###########################################################################

$script:ForecastNoteOptional = @('Acknowledged', 'Approved', 'Scheduled', 'ConfirmedDistinct', 'LatestMonth', 'MedianLast3', 'TreatAsMarketplace')

function Clear-ForecastScreen {
    if (-not $Accessible) { try { Clear-Host } catch { Write-Verbose 'Clear-Host is unavailable in this host.' } }
}

function Write-ForecastHeading {
    param([Parameter(Mandatory)][string]$Title)
    Write-FinOpsConsole ''
    Write-FinOpsConsole "  $Title" -ForegroundColor Cyan
    Write-FinOpsConsole ('  ' + ([string][char]0x2500 * [math]::Min(74, [math]::Max(10, (Get-MenuWidth 78) - 4)))) -ForegroundColor DarkGray
}

function Read-ForecastText {
    param([Parameter(Mandatory)][string]$Prompt, [string]$Default)
    $suffix = if ($PSBoundParameters.ContainsKey('Default') -and $null -ne $Default -and $Default -ne '') { " [$Default]" } else { '' }
    $answer = Read-FinOpsAnswer "  $Prompt$suffix`: "
    if ($answer -eq '' -and $suffix) { return $Default }
    return $answer
}

function Read-ForecastChoice {
    # Returns the matching choice in upper case, or '' after three invalid or empty answers.
    param([Parameter(Mandatory)][string]$Prompt, [Parameter(Mandatory)][string[]]$Valid, [string]$Default)
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $answer = (Read-ForecastText -Prompt $Prompt -Default $Default).Trim().ToUpperInvariant()
        if ($answer -in $Valid) { return $answer }
        if ($answer) { Write-FinOpsConsole "  '$answer' isn't an option." -ForegroundColor Yellow }
    }
    return ''
}

function Read-ForecastYesNo {
    param([Parameter(Mandatory)][string]$Prompt, [bool]$Default = $false)
    $choice = Read-ForecastChoice -Prompt "$Prompt (Y/N)" -Valid @('Y', 'N', 'YES', 'NO') -Default $(if ($Default) { 'Y' } else { 'N' })
    return $choice -in 'Y', 'YES'
}

function Wait-ForecastKey {
    $null = Read-FinOpsAnswer '  Press Enter to continue: '
}

function Get-ForecastWorstStatus {
    param([AllowEmptyCollection()][string[]]$Statuses)
    if ($Statuses -contains 'Fail') { return 'Fail' }
    if ($Statuses -contains 'Warn') { return 'Warn' }
    return 'Pass'
}

function Get-ForecastStatusColor {
    param([string]$Status)
    switch ($Status) { 'Fail' { 'Red' } 'Warn' { 'Yellow' } 'Pass' { 'Green' } default { 'Gray' } }
}

function Write-ForecastSectionLine {
    param([string]$Key, [string]$Label, [string]$Summary, [string]$Status)
    $width = Get-MenuWidth 110
    $badge = switch ($Status) { 'Fail' { 'NEEDS ACTION' } 'Warn' { 'CHECK' } 'Pass' { 'OK' } default { '' } }
    $text = ('  {0,-2} {1,-15} {2}' -f $Key, $Label, (ConvertTo-ForecastSafeText $Summary 200))
    $room = [math]::Max(20, $width - 15)
    if ($text.Length -gt $room) { $text = $text.Substring(0, $room - 3) + '...' }
    Write-FinOpsConsole $text.PadRight($room) -NoNewline
    Write-FinOpsConsole " $badge" -ForegroundColor (Get-ForecastStatusColor $Status)
}

function Get-ForecastCheckStatus {
    param([Parameter(Mandatory)]$Readiness, [Parameter(Mandatory)][string[]]$Ids)
    return Get-ForecastWorstStatus -Statuses @($Readiness.Checks | Where-Object { $_.Id -in $Ids } | ForEach-Object Status)
}

function Show-ForecastSetupReview {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][datetime]$AsOf, [string]$OutputPath)
    $emptyAnswers = 0
    while ($true) {
        $session = $null
        try { $session = Invoke-ForecastEvaluation -Root $Root -AsOf $AsOf }
        catch {
            Write-FinOpsConsole "  The workspace couldn't be evaluated: $(ConvertTo-ForecastSafeText $_.Exception.Message 300)" -ForegroundColor Red
            Write-FinOpsConsole '  Open a section to fix the settings, or press Q to leave.' -ForegroundColor DarkGray
        }
        Clear-ForecastScreen
        Write-ForecastHeading -Title "Forecast setup and review  (workspace: $([IO.Path]::GetFileName($Root)))"
        if ($session) {
            $readiness = $session.Readiness
            $failing = @($readiness.Checks | Where-Object Status -EQ 'Fail').Count
            $statusText = if ($readiness.Ready) { 'READY' }
            elseif ($readiness.Status -eq 'Preliminary') { "PRELIMINARY ($($session.Settings.period.lookbackMonths) months of history; $($script:ForecastReadyMonths) are needed for Ready)" }
            else { "NOT READY ($failing check$(if ($failing -ne 1) { 's' }) failing)" }
            $statusColor = if ($readiness.Ready) { 'Green' } elseif ($readiness.Status -eq 'Preliminary') { 'Yellow' } else { 'Red' }
            $statusLabels = Get-ForecastDisplayLabels -Readiness $readiness
            Write-FinOpsConsole "  Status: $statusText$(if ($statusLabels.Count) { "  [$($statusLabels -join ', ')]" })" -ForegroundColor $statusColor
            Write-FinOpsConsole ''
            $settings = $session.Settings
            $dataset = $session.Dataset
            $model = $session.Model
            $sourceSummary = if ($settings.dataMode -eq 'Manual') { "Manual inputs: $(@($dataset.Months | Where-Object Status -NE 'Missing').Count) month(s) entered" }
            else { "$(Get-ForecastSourceCountText -Sources @($settings.sources)); $(@($dataset.Runs).Count) run-month(s) selected; $(@($dataset.Runs | Where-Object { -not $_.Final }).Count) not final" }
            Write-ForecastSectionLine '1' 'Source' $sourceSummary (Get-ForecastCheckStatus $readiness @('SOURCE', 'CURRENCY', 'BOUNDARY'))
            Write-ForecastSectionLine '2' 'Scope' $session.ScopeLabel (Get-ForecastCheckStatus $readiness @('SETTINGS', 'POPULATION'))
            Write-ForecastSectionLine '3' 'Period' "$($model.FiscalYear.Label) ($($model.FiscalYear.FirstMonth) to $($model.FiscalYear.LastMonth)); lookback $($model.Window.First) to $($model.Window.Last)" (Get-ForecastCheckStatus $readiness @('MONTHS', 'HISTORY', 'ACTUALS', 'COMPARISONS', 'RETAINED'))
            Write-ForecastSectionLine '4' 'Assumptions' "Median growth, $(Get-ForecastRangeLabel -Settings $settings) range; $(@($settings.scheduledItems).Count) scheduled item(s); workloads by $($settings.workloads.mode)$(if ($settings.workloads.mode -eq 'Tag') { " '$($settings.workloads.tagKey)'" })" (Get-ForecastCheckStatus $readiness @('KEYS', 'BASELINE'))
            $pendingRequired = @($readiness.Reviews | Where-Object { $_.Required -and $_.Decision -eq 'Pending' }).Count
            $pendingOptional = @($readiness.Reviews | Where-Object { -not $_.Required -and $_.Decision -eq 'Pending' }).Count
            Write-ForecastSectionLine '5' 'Exceptions' "$pendingRequired required and $pendingOptional optional review(s) pending of $(@($readiness.Reviews).Count)" (Get-ForecastCheckStatus $readiness @('EXCEPTIONS'))
            $reconcileFails = @($readiness.Checks | Where-Object { $_.Id -eq 'RECONCILE' -and $_.Status -eq 'Fail' }).Count
            Write-ForecastSectionLine '6' 'Reconciliation' $(if ($reconcileFails) { 'Some months don''t reconcile' } else { "$(@($dataset.Reconciliation).Count) run-month(s) reconcile to raw totals" }) (Get-ForecastCheckStatus $readiness @('RECONCILE'))
            $refreshSummary = if ($settings.dataMode -eq 'Manual') { 'Not used for manual inputs' } elseif ($session.RefreshState) { "Last attempt $($session.RefreshState.LastAttemptUtc) ($($session.RefreshState.LastAttemptResult))" } else { 'Never refreshed' }
            Write-ForecastSectionLine '7' 'Refresh' $refreshSummary (Get-ForecastCheckStatus $readiness @('FRESHNESS'))
            Write-FinOpsConsole ''
            $projection = $model.Projection
            if ($null -ne $model.Growth.Central -and $null -ne $model.Baseline.Value) {
                Write-FinOpsConsole "  $($projection.FiscalYear.Label) pre-credit: central $(Format-ForecastAmount $projection.TotalCentral $dataset.Currency); range $(Format-ForecastAmount $projection.TotalLow) to $(Format-ForecastAmount $projection.TotalHigh)$(if ($readiness.Status -eq 'Preliminary') { ' (preliminary)' } elseif (-not $readiness.Ready) { ' (preview; not Ready)' })" -ForegroundColor White
            }
        }
        Write-FinOpsConsole ''
        $inputsAction = if ($session -and $session.Settings.dataMode -eq 'Manual') { '  I Inputs' } else { '' }
        Write-FinOpsConsole "  1-7 Open a section$inputsAction   W Workloads   R Refresh   F Forecast and save   P Preview report   G Guided setup   H How it works   Q Quit" -ForegroundColor DarkGray
        $choice = Read-ForecastChoice -Prompt 'Choose' -Valid @('1', '2', '3', '4', '5', '6', '7', 'I', 'W', 'R', 'F', 'P', 'G', 'H', 'Q')
        if ($choice -eq '') { $emptyAnswers++; if ($emptyAnswers -ge 2) { return }; continue }
        $emptyAnswers = 0
        try {
            switch ($choice) {
                '1' { Edit-ForecastSources -Root $Root }
                '2' { Edit-ForecastScope -Root $Root }
                '3' { Edit-ForecastPeriod -Root $Root }
                '4' { Edit-ForecastAssumptions -Root $Root }
                '5' { if ($session) { Show-ForecastExceptions -Root $Root -Session $session } }
                '6' { if ($session) { Show-ForecastReconciliation -Session $session } }
                '7' { Show-ForecastRefresh -Root $Root }
                'I' { Edit-ForecastInputs -Root $Root -Session $session }
                'W' { if ($session) { Show-ForecastWorkloads -Session $session } }
                'R' { Invoke-ForecastConsoleRefresh -Root $Root }
                'F' { if ($session) { Invoke-ForecastConsolePublish -Session $session -OutputPath $OutputPath -SaveVintage } }
                'P' { if ($session) { Invoke-ForecastConsolePublish -Session $session -OutputPath $OutputPath } }
                'G' { $null = Start-ForecastGuidedSetup -Root $Root -AsOf $AsOf }
                'H' { Show-ForecastHowItWorks -Root $Root -AsOf $AsOf }
                'Q' { return }
            }
        }
        catch {
            Write-FinOpsConsole "  Error: $(ConvertTo-ForecastSafeText $_.Exception.Message 400)" -ForegroundColor Red
            Wait-ForecastKey
        }
    }
}

function Select-ForecastComparisonReview {
    # Lists every month-to-month change, so one the forecast didn't flag can
    # be reviewed by hand. Returns its review, or $null to cancel.
    param([Parameter(Mandatory)]$Session)
    $changes = @($Session.Model.Comparisons.Items | Where-Object Status -EQ 'Defined')
    Write-ForecastHeading -Title 'Month-to-month changes'
    Write-FinOpsConsole ('  {0,3}  {1,-18} {2,9}  {3,-9}  {4}' -f '#', 'Months', 'Change', 'In growth', 'Decision') -ForegroundColor White
    for ($i = 0; $i -lt $changes.Count; $i++) {
        $change = $changes[$i]
        $decision = if ($change.Review) { [string]$change.Review.Decision } else { '' }
        Write-FinOpsConsole ('  {0,3}  {1,-18} {2,9}  {3,-9}  {4}' -f ($i + 1), "$($change.FromMonth) to $($change.ToMonth)", (Format-ForecastPercent $change.Change), $(if ($change.Retained) { 'yes' } else { 'no' }), $decision) -ForegroundColor $(if ($change.Flagged) { 'Yellow' } else { 'Gray' })
    }
    $answer = Read-ForecastText -Prompt 'Number of the change to review (blank to cancel)'
    $number = 0
    if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $changes.Count) { return $null }
    $change = $changes[$number - 1]
    if ($change.Review) { return $change.Review }
    return New-ForecastComparisonReview -Comparison $change -ScopeKey $Session.Model.ScopeKey -Median $Session.Model.Comparisons.Median -Threshold $Session.Model.Comparisons.Threshold
}

function Show-ForecastExceptions {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Session, [string]$Category)
    while ($true) {
        $reviews = @($Session.Readiness.Reviews | Where-Object { -not $Category -or $_.Category -eq $Category })
        $ordered = Invoke-ForecastSort -Items $reviews -Comparison {
            param($a, $b)
            $left = if ($a.Decision -eq 'Pending') { if ($a.Required) { 0 } else { 1 } } else { 2 }
            $right = if ($b.Decision -eq 'Pending') { if ($b.Required) { 0 } else { 1 } } else { 2 }
            $c = $left.CompareTo($right)
            if ($c) { $c } else { [string]::CompareOrdinal([string]$a.Key, [string]$b.Key) }
        }
        # A list filtered to one category, such as approving manual months, stays on it.
        $changes = if ($Category) { 0 } else { @($Session.Model.Comparisons.Items | Where-Object Status -EQ 'Defined').Count }
        Clear-ForecastScreen
        Write-ForecastHeading -Title "Exceptions ($($ordered.Count))"
        if ($ordered.Count -eq 0 -and $changes -eq 0) { Write-FinOpsConsole '  Nothing to review.' -ForegroundColor Green; Wait-ForecastKey; return }
        if ($ordered.Count -eq 0) { Write-FinOpsConsole '  Nothing needs a decision.' -ForegroundColor Green }
        for ($i = 0; $i -lt $ordered.Count; $i++) {
            $item = $ordered[$i]
            $flag = if ($item.Decision -eq 'Pending') { if ($item.Required) { 'REQUIRED' } else { 'optional' } } else { $item.Decision }
            $color = if ($item.Decision -eq 'Pending') { if ($item.Required) { 'Red' } else { 'Yellow' } } else { 'Green' }
            Write-FinOpsConsole ('  {0,3}  {1,-17} {2,-12} {3}' -f ($i + 1), $item.Category, $flag, (ConvertTo-ForecastSafeText $item.Title 80)) -ForegroundColor $color
        }
        Write-FinOpsConsole ''
        $answer = Read-ForecastText -Prompt $(if ($changes) { 'Number to review, C to review any month-to-month change, or B to go back' } else { 'Number to review, or B to go back' })
        if ($answer -eq '' -or $answer -match '^(?i)b$') { return }
        if ($changes -and $answer -match '^(?i)c$') {
            $item = Select-ForecastComparisonReview -Session $Session
            if (-not $item) { continue }
        }
        else {
            $number = 0
            if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $ordered.Count) { continue }
            $item = $ordered[$number - 1]
        }
        Write-ForecastHeading -Title (ConvertTo-ForecastSafeText $item.Title 120)
        Write-FinOpsConsole "  $(ConvertTo-ForecastSafeText $item.Detail 1200)" -ForegroundColor Gray
        if ($item.Stale) { Write-FinOpsConsole '  The data, or a decision it depends on, changed since the last decision, so it needs a new review.' -ForegroundColor Yellow }
        Write-FinOpsConsole "  Current decision: $($item.Decision)$(if ($item.Note) { " - $($item.Note)" })" -ForegroundColor DarkGray
        for ($o = 0; $o -lt @($item.Options).Count; $o++) {
            $suggested = if ($item.Options[$o] -eq $item.Suggested) { '  (suggested)' } else { '' }
            Write-FinOpsConsole ('    {0}  {1}{2}' -f ($o + 1), $item.Options[$o], $suggested)
        }
        $proposal = if ($item.PSObject.Properties.Name -contains 'Proposal') { $item.Proposal } else { $null }
        if ($proposal) { Write-FinOpsConsole "    A  Add the proposed scheduled item: $(Format-ForecastAmount (Read-ForecastDecimal $proposal.amount)) a month from $($proposal.startMonth)" -ForegroundColor Cyan }
        $pick = Read-ForecastText -Prompt $(if ($proposal) { 'Option number, A to add the proposed item, or blank to cancel' } else { 'Option number (blank to cancel)' })
        if ($proposal -and $pick -match '^(?i)a$') {
            $null = Add-ForecastProposedItem -Root $Root -Proposal $proposal
            Wait-ForecastKey
            $Session = Invoke-ForecastEvaluation -Root $Root -AsOf $Session.AsOf
            continue
        }
        $optionNumber = 0
        if (-not [int]::TryParse($pick, [ref]$optionNumber) -or $optionNumber -lt 1 -or $optionNumber -gt @($item.Options).Count) { continue }
        $decision = $item.Options[$optionNumber - 1]
        $value = $null
        if ($decision -eq 'Manual') { $value = Read-ForecastText -Prompt 'Baseline run rate for a 30-day month' }
        $note = Read-ForecastText -Prompt $(if ($decision -in $script:ForecastNoteOptional) { 'Note (optional)' } else { 'Reason (required): what did you check?' })
        if ($decision -notin $script:ForecastNoteOptional -and [string]::IsNullOrWhiteSpace($note)) { Write-FinOpsConsole '  A reason is required for this decision. Nothing was saved.' -ForegroundColor Yellow; Wait-ForecastKey; continue }
        Set-ForecastReviewDecision -Root $Root -Item $item -Decision $decision -Note $note -Value $value
        $Session = Invoke-ForecastEvaluation -Root $Root -AsOf $Session.AsOf
    }
}

function Show-ForecastReconciliation {
    param([Parameter(Mandatory)]$Session)
    $rows = @($Session.Dataset.Reconciliation)
    $page = 0; $size = 15
    while ($true) {
        Clear-ForecastScreen
        Write-ForecastHeading -Title "Reconciliation ($($rows.Count) run-months, $($Session.Dataset.Currency))"
        Write-FinOpsConsole ('  {0,-8} {1,16} {2,16} {3,14} {4,14} {5,12}  {6}' -f 'Month', 'Raw total', 'Included', 'Excluded', 'Credits', 'Difference', 'Source') -ForegroundColor White
        foreach ($row in @($rows | Select-Object -Skip ($page * $size) -First $size)) {
            $excluded = 0d
            foreach ($name in 'ExcludedTax', 'ExcludedMarketplace', 'ExcludedUnattributed', 'ExcludedBoundary', 'ExcludedScope', 'ExcludedOverlap', 'ExcludedOutsideRange') { if ($null -ne $row.$name) { $excluded += [decimal]$row.$name } }
            $color = if (Test-ForecastMaterialDifference $row.Difference) { 'Red' } else { 'Gray' }
            Write-FinOpsConsole ('  {0,-8} {1,16} {2,16} {3,14} {4,14} {5,12}  {6}' -f $row.Month, (Format-ForecastAmount $row.RawTotal), (Format-ForecastAmount $row.IncludedHeadline), (Format-ForecastAmount $excluded), (Format-ForecastAmount $row.Credits), (Format-ForecastAmount $row.Difference), (ConvertTo-ForecastSafeText $row.Source 40)) -ForegroundColor $color
        }
        $pages = [math]::Max(1, [math]::Ceiling($rows.Count / $size))
        Write-FinOpsConsole "  Page $($page + 1) of $pages.  N Next  P Previous  B Back" -ForegroundColor DarkGray
        $choice = Read-ForecastChoice -Prompt 'Choose' -Valid @('N', 'P', 'B') -Default 'B'
        switch ($choice) { 'N' { if ($page + 1 -lt $pages) { $page++ } } 'P' { if ($page -gt 0) { $page-- } } default { return } }
    }
}

function Invoke-ForecastConsoleRefresh {
    param([Parameter(Mandatory)][string]$Root)
    $settings = Get-ForecastStoredSettings -Root $Root
    if ($settings.dataMode -ne 'Exports') { Write-FinOpsConsole '  Manual inputs don''t need a refresh.' -ForegroundColor DarkGray; Wait-ForecastKey; return }
    if (@($settings.sources | Where-Object kind -In 'AzureStorage', 'CostDetails').Count -and -not (Get-AzContext -ErrorAction SilentlyContinue)) {
        Write-FinOpsConsole '  Signing in to read Azure sources...' -ForegroundColor Yellow
        $null = Select-Subscription
    }
    Write-FinOpsConsole '  Refreshing export history...' -ForegroundColor Cyan
    $result = Update-ForecastExportCache -Root $Root -Settings $settings
    if ($result.Succeeded) {
        Write-FinOpsConsole "  Refresh succeeded: $($result.RunsRead) run(s) read, $($result.RunsReused) reused from the cache." -ForegroundColor Green
        if ($result.RunsIncomplete) { Write-FinOpsConsole "  $($result.RunsIncomplete) run(s) couldn't be read completely and aren't used. Data checks list the reasons; refresh again to retry them." -ForegroundColor Yellow }
    }
    else { Write-FinOpsConsole "  Refresh failed; the previous data is still in use. $($result.Error)" -ForegroundColor Red }
    Wait-ForecastKey
}

function Show-ForecastRefresh {
    param([Parameter(Mandatory)][string]$Root)
    Clear-ForecastScreen
    Write-ForecastHeading -Title 'Refresh status'
    $state = Get-ForecastRefreshState -Root $Root
    if (-not $state) { Write-FinOpsConsole '  No refresh has run in this workspace.' -ForegroundColor DarkGray }
    else {
        Write-FinOpsConsole "  Last successful refresh: $(if ($state.LastSuccessUtc) { $state.LastSuccessUtc } else { 'none' })"
        foreach ($entry in @($state.Log | Select-Object -Last 10)) {
            $color = if ($entry.Result -eq 'Succeeded') { 'Green' } else { 'Red' }
            Write-FinOpsConsole "  $($entry.AttemptUtc)  $($entry.Result)  read $($entry.RunsRead), reused $($entry.RunsReused), $($entry.DurationSeconds)s  $(ConvertTo-ForecastSafeText $entry.Error 160)" -ForegroundColor $color
        }
    }
    if (Read-ForecastYesNo -Prompt 'Refresh now?') { Invoke-ForecastConsoleRefresh -Root $Root }
}

function Show-ForecastWorkloads {
    param([Parameter(Mandatory)]$Session)
    if (-not $Session.Workloads) { Write-FinOpsConsole '  Workload analysis needs export data; manual inputs don''t carry workload detail.' -ForegroundColor Yellow; Wait-ForecastKey; return }
    $view = 'Change'; $filter = ''; $page = 0; $size = 15
    $currency = $Session.Dataset.Currency
    while ($true) {
        $items = Get-ForecastWorkloadView -Analysis $Session.Workloads -View $view -Filter $filter
        $pages = [math]::Max(1, [math]::Ceiling($items.Count / $size))
        if ($page -ge $pages) { $page = $pages - 1 }
        Clear-ForecastScreen
        Write-ForecastHeading -Title "Workloads by $view ($($items.Count) shown of $(@($Session.Workloads.Workloads).Count); net change $(Format-ForecastAmount $Session.Workloads.NetChange $currency))"
        Write-FinOpsConsole ('  {0,4} {1,-34} {2,14} {3,9} {4,8} {5,-8} {6,12}  {7}' -f '#', 'Workload', 'Change', 'Growth', 'Share', 'Largest', 'increase', 'Flags') -ForegroundColor White
        for ($i = $page * $size; $i -lt [math]::Min($items.Count, ($page + 1) * $size); $i++) {
            $w = $items[$i]
            Write-FinOpsConsole ('  {0,4} {1,-34} {2,14} {3,9} {4,8} {5,-8} {6,12}  {7}' -f ($i + 1), (ConvertTo-ForecastSafeText $w.WorkloadName 34), (Format-ForecastAmount $w.Change), (Format-ForecastPercent $w.Growth), (Format-ForecastPercent $w.ContributionShare), ([string]$w.LargestIncreaseMonth), (Format-ForecastAmount $w.LargestIncreaseAmount), $w.Flags)
        }
        Write-FinOpsConsole "  Page $($page + 1) of $pages.  N/P page  V view  F filter  number for detail  B back" -ForegroundColor DarkGray
        $answer = Read-ForecastText -Prompt 'Choose'
        if ($answer -eq '' -or $answer -match '^(?i)b$') { return }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $items.Count) {
            $w = $items[$number - 1]
            Write-ForecastHeading -Title (ConvertTo-ForecastSafeText $w.WorkloadName 100)
            Write-FinOpsConsole "  ID: $($w.WorkloadId)  Source: $($w.Source)  Flags: $($w.Flags)"
            Write-FinOpsConsole "  Run rate $($w.FirstMonth): $(Format-ForecastAmount $w.FirstRunRate $currency); $($w.LastMonth): $(Format-ForecastAmount $w.LastRunRate $currency)"
            if ([decimal]$w.PurchasesFirst -ne 0 -or [decimal]$w.PurchasesLast -ne 0) { Write-FinOpsConsole "  Purchases this subscription pays for, $($w.FirstMonth): $(Format-ForecastAmount $w.PurchasesFirst $currency); $($w.LastMonth): $(Format-ForecastAmount $w.PurchasesLast $currency); net change with purchases $(Format-ForecastAmount $w.NetChange $currency)" }
            if ($null -ne $w.MonthToDatePace) { Write-FinOpsConsole "  $($Session.Workloads.PaceMonth) so far: $(Format-ForecastAmount $w.MonthToDate $currency) in $($Session.Workloads.PaceDays) day(s), a pace of $(Format-ForecastAmount $w.MonthToDatePace $currency) for 30 days" }
            Write-FinOpsConsole "  Lookback spend $(Format-ForecastAmount $w.LookbackSpend $currency); latest month $(Format-ForecastAmount $w.LatestMonthSpend $currency)"
            if ($w.Notes) { Write-FinOpsConsole "  $(ConvertTo-ForecastSafeText $w.Notes 600)" -ForegroundColor Yellow }
            for ($m = 0; $m -lt $Session.Workloads.Months.Count; $m++) { Write-FinOpsConsole ('    {0}  {1,16}' -f $Session.Workloads.Months[$m], (Format-ForecastAmount $w.MonthlyRunRate[$m])) -ForegroundColor DarkGray }
            Wait-ForecastKey
            continue
        }
        switch -Regex ($answer) {
            '^(?i)n$' { if ($page + 1 -lt $pages) { $page++ } }
            '^(?i)p$' { if ($page -gt 0) { $page-- } }
            '^(?i)v$' {
                $pick = Read-ForecastChoice -Prompt 'View: 1 Change  2 Lookback spend  3 Growth %  4 Largest increase' -Valid @('1', '2', '3', '4') -Default '1'
                $view = switch ($pick) { '2' { 'Spend' } '3' { 'Growth' } '4' { 'LargestIncrease' } default { 'Change' } }
                $page = 0
            }
            '^(?i)f$' { $filter = Read-ForecastText -Prompt 'Filter text (blank for all)'; $page = 0 }
        }
    }
}

function Invoke-ForecastConsolePublish {
    param([Parameter(Mandatory)]$Session, [string]$OutputPath, [switch]$SaveVintage)
    if ($SaveVintage -and -not $Session.Readiness.Ready) {
        if ($Session.Readiness.Status -eq 'Preliminary') {
            Write-ForecastHeading -Title 'A Preliminary forecast isn''t saved'
            Write-FinOpsConsole "  It uses $($Session.Settings.period.lookbackMonths) months of history; a vintage needs $($script:ForecastReadyMonths). Use P to write a preview report labeled Preliminary." -ForegroundColor Yellow
            Wait-ForecastKey
            return
        }
        Write-ForecastHeading -Title 'The forecast isn''t Ready'
        foreach ($check in @($Session.Readiness.Checks | Where-Object Status -EQ 'Fail')) { Write-FinOpsConsole "  [FAIL] $($check.Name): $(ConvertTo-ForecastSafeText $check.Detail 300)" -ForegroundColor Red }
        Write-FinOpsConsole '  Use P to write a preview report labeled NotReady.' -ForegroundColor DarkGray
        Wait-ForecastKey
        return
    }
    $previous = @(Get-ForecastVintages -Root $Session.Root)[-1]
    $published = Publish-ForecastOutputs -Session $Session -OutputPath $OutputPath -SaveVintage:$SaveVintage
    Write-ForecastHeading -Title $(if ($SaveVintage) { 'Forecast saved' } else { 'Preview report written' })
    foreach ($line in (Get-ForecastSummaryLines -Model $Session.Model -Dataset $Session.Dataset -Readiness $Session.Readiness -Workloads $Session.Workloads -ScopeLabel $Session.ScopeLabel | Select-Object -First 10)) { Write-FinOpsConsole "  $line" }
    if ($SaveVintage -and $previous) {
        $change = $Session.Model.Projection.TotalCentral - (Read-ForecastDecimal $previous.TotalCentral)
        Write-FinOpsConsole "  Change from vintage $($previous.File): $(Format-ForecastAmount $change $Session.Dataset.Currency)" -ForegroundColor Cyan
    }
    Write-FinOpsConsole "  Reports: $($published.ReportDirectory)" -ForegroundColor Green
    if ($published.Vintage) { Write-FinOpsConsole "  Vintage: $($published.Vintage)" -ForegroundColor Green }
    Wait-ForecastKey
}

function Select-FinOpsExplorerMode {
    # Called from FinOps Explorer's launcher. Returns Scans or Forecast.
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Accessible', Justification = 'Read by the shared console helpers through dynamic scope.')]
    param([switch]$Accessible)
    Write-FinOpsConsole ''
    Write-FinOpsConsole '  What would you like to do?' -ForegroundColor White
    Write-FinOpsConsole '    1  Run FinOps Explorer scans'
    Write-FinOpsConsole '    2  Pre-credit forecast and workload growth'
    $choice = Read-ForecastChoice -Prompt 'Choose' -Valid @('1', '2') -Default '1'
    if ($choice -eq '2') { return 'Forecast' }
    return 'Scans'
}
