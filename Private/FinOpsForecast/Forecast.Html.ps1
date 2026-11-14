# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers that build objects or write only the private local forecast workspace; nothing in Azure changes.')]
param()

###########################################################################
# FORECAST.HTML.PS1
# SELF-CONTAINED HTML REPORT
###########################################################################
# The report uses the scan report's layout and styles: a masthead, summary
# cards, and a tab for each section, opening on an overview written for
# executive and finance readers. Every value is HTML-encoded. Tables load
# every row and page them in the browser, with a filter, sorting, and an
# expanded view, so large workload lists aren't truncated. Charts are
# inline SVG drawn here. The page loads nothing from the network.
###########################################################################

$script:ForecastHtmlKinds = @{
    Actual = 'Actual'; ProvisionalActual = 'Actual, not final'; PartialActual = 'Month to date and forecast'
    Forecast = 'Forecast'; MissingActual = 'No final data'
}
# Text colors for status values, from the scan report's severity classes.
$script:ForecastHtmlTones = @{
    Fail = 'severity-red'; Incomplete = 'severity-red'; Missing = 'severity-red'; MissingActual = 'severity-red'
    Warn = 'severity-yellow'; Provisional = 'severity-yellow'; ProvisionalActual = 'severity-yellow'; Pending = 'severity-yellow'
    Pass = 'severity-green'
    # Source read status.
    'Rows' = 'severity-green'; 'No rows' = 'severity-yellow'; 'Partly read' = 'severity-yellow'; 'Not attempted' = 'severity-yellow'
    'Unsupported offer' = 'severity-red'; 'Access denied' = 'severity-red'; 'Failed' = 'severity-red'
}
# Column widths in rem by format. Text columns share what's left.
$script:ForecastHtmlWidths = @{ month = 7; amount = 8.5; percent = 6.5; bool = 5.5; status = 9.5; date = 7.5; number = 6 }

function ConvertTo-ForecastHtmlText {
    param([AllowNull()]$Value)
    return [Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-ForecastMonthName {
    # "July 2026", "Jul 2026" with -Short, or the month alone with -NoYear.
    param([AllowNull()][string]$MonthKey, [switch]$Short, [switch]$NoYear)
    if (-not (Test-ForecastMonthKey -MonthKey $MonthKey)) { return [string]$MonthKey }
    $format = if ($Short) { 'MMM' } else { 'MMMM' }
    if (-not $NoYear) { $format += ' yyyy' }
    return [datetime]::ParseExact("$MonthKey-01", 'yyyy-MM-dd', $script:ForecastInvariant).ToString($format, $script:ForecastInvariant)
}

function Format-ForecastMonthRange {
    # "July to October 2026" or "July 2026 to June 2027".
    param([AllowNull()][string]$First, [AllowNull()][string]$Last)
    if (-not (Test-ForecastMonthKey -MonthKey $First) -or -not (Test-ForecastMonthKey -MonthKey $Last)) { return "$First to $Last" }
    if ($First -eq $Last) { return Get-ForecastMonthName -MonthKey $First }
    if ($First.Substring(0, 4) -eq $Last.Substring(0, 4)) { return "$(Get-ForecastMonthName -MonthKey $First -NoYear) to $(Get-ForecastMonthName -MonthKey $Last)" }
    return "$(Get-ForecastMonthName -MonthKey $First) to $(Get-ForecastMonthName -MonthKey $Last)"
}

function Format-ForecastLongDate {
    param([AllowNull()]$Value)
    $date = ConvertFrom-ForecastDate -Value $Value
    if (-not $date) { return '' }
    return $date.ToString('MMMM d, yyyy', $script:ForecastInvariant)
}

function Get-ForecastCountText {
    # "1 check" or "3 checks".
    param([int]$Count, [string]$Singular, [string]$Plural)
    if ($Count -eq 1) { return "1 $Singular" }
    return "$Count $Plural"
}

function Get-ForecastShortText {
    # Shortens text at a word for the overview; the full text is on its tab.
    param([AllowNull()][string]$Text, [int]$MaxLength = 200)
    $clean = ConvertTo-ForecastSafeText $Text 100000
    if ($clean.Length -le $MaxLength) { return $clean }
    $cut = $clean.LastIndexOf(' ', $MaxLength)
    if ($cut -lt $MaxLength / 2) { $cut = $MaxLength }
    return $clean.Substring(0, $cut).TrimEnd(' ', ',', ';', ':') + '...'
}

function Format-ForecastHtmlCell {
    param([AllowNull()]$Value, [string]$Format)
    switch ($Format) {
        'amount' { if ($null -eq $Value -or ($Value -is [string] -and $Value.Length -eq 0)) { return '' } return Format-ForecastAmount ([decimal]$Value) }
        'percent' { return Format-ForecastPercent $Value }
        'date' { if ($Value -is [datetime]) { return ([datetime]$Value).ToString('yyyy-MM-dd', $script:ForecastInvariant) } return [string]$Value }
        'month' { return Get-ForecastMonthName -MonthKey ([string]$Value) -Short }
        'bool' { if ($Value -is [bool]) { if ($Value) { return 'Yes' } return 'No' } return [string]$Value }
        'number' { if ($null -eq $Value -or [string]$Value -eq '') { return '' } return ([decimal]$Value).ToString('N0', $script:ForecastInvariant) }
        default {
            if ($Value -is [array]) { return (@($Value) | ForEach-Object { [string]$_ }) -join '; ' }
            if ($Value -is [decimal]) { return Format-ForecastAmount $Value }
            return [string]$Value
        }
    }
}

function New-ForecastColumn {
    # Map turns stored values into display text; Tone colors status values.
    param([string]$Name, [string]$Label, [string]$Format = 'text', [hashtable]$Map, [switch]$Tone, [double]$Width = 0)
    [pscustomobject]@{ Name = $Name; Label = $(if ($Label) { $Label } else { $Name }); Format = $Format; Map = $Map; Tone = [bool]$Tone; Width = $Width }
}

function ConvertTo-ForecastHtmlTableCell {
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)]$Column)
    $value = $Row.($Column.Name)
    $key = [string]$value
    $text = if ($Column.Map -and $null -ne $value -and $Column.Map.ContainsKey($key)) { $Column.Map[$key] } else { Format-ForecastHtmlCell -Value $value -Format $Column.Format }
    $classes = @()
    if ($Column.Format -in 'amount', 'percent', 'number') { $classes += 'numeric-cell' }
    if ($Column.Tone -and $null -ne $value -and $script:ForecastHtmlTones.ContainsKey($key)) { $classes += $script:ForecastHtmlTones[$key] }
    $class = if ($classes.Count) { " class=""$($classes -join ' ')""" } else { '' }
    # Months show as "Jul 2026" but sort by their yyyy-MM key.
    $sort = if ($Column.Format -eq 'month' -and $key) { " data-sort=""$(ConvertTo-ForecastHtmlText $key)""" } else { '' }
    return "<td$class$sort>$(ConvertTo-ForecastHtmlText $text)</td>"
}

function ConvertTo-ForecastHtmlTable {
    # A table the page's script turns into the scan report's grid: a filter,
    # pages of rows, sortable and resizable columns, and an expanded view.
    # Footer values, keyed by column name, make a totals row.
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][object[]]$Columns,
        [int]$PageSize = 25,
        [Collections.IDictionary]$Footer,
        [string]$Empty = 'Nothing to show.'
    )
    if (-not @($Rows).Count) { return "<p class=""no-data"">$(ConvertTo-ForecastHtmlText $Empty)</p>" }
    $inv = $script:ForecastInvariant
    $sb = [Text.StringBuilder]::new()
    $colgroup = [Text.StringBuilder]::new()
    $minimum = 3.0
    foreach ($column in $Columns) {
        $width = if ($column.Width) { [double]$column.Width } else { [double]$script:ForecastHtmlWidths[[string]$column.Format] }
        if ($width) { [void]$colgroup.Append("<col style=""width:$($width.ToString($inv))rem"">"); $minimum += $width }
        else { [void]$colgroup.Append('<col>'); $minimum += 12 }
    }
    [void]$sb.Append("<div class=""table-scroll""><table class=""report-table"" id=""$(ConvertTo-ForecastHtmlText $Id)"" data-title=""$(ConvertTo-ForecastHtmlText $Title)"" data-page-size=""$PageSize"" style=""min-width:$($minimum.ToString($inv))rem"">")
    [void]$sb.Append("<colgroup>$($colgroup.ToString())</colgroup><thead><tr>")
    foreach ($column in $Columns) {
        $class = if ($column.Format -in 'amount', 'percent', 'number') { ' class="numeric-cell"' } else { '' }
        [void]$sb.Append("<th scope=""col""$class>$(ConvertTo-ForecastHtmlText $column.Label)</th>")
    }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($row in @($Rows)) {
        [void]$sb.Append('<tr>')
        foreach ($column in $Columns) { [void]$sb.Append((ConvertTo-ForecastHtmlTableCell -Row $row -Column $column)) }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody>')
    if ($Footer) {
        [void]$sb.Append('<tfoot><tr>')
        foreach ($column in $Columns) {
            $value = if ($Footer.Contains($column.Name)) { $Footer[$column.Name] } else { $null }
            $text = if ($value -is [string]) { $value } else { Format-ForecastHtmlCell -Value $value -Format $column.Format }
            $class = if ($column.Format -in 'amount', 'percent', 'number') { ' class="numeric-cell"' } else { '' }
            [void]$sb.Append("<td$class>$(ConvertTo-ForecastHtmlText $text)</td>")
        }
        [void]$sb.Append('</tr></tfoot>')
    }
    [void]$sb.Append('</table></div>')
    return $sb.ToString()
}

# -- Charts ----------------------------------------------------------------
function Get-ForecastChartStep {
    # The smallest round step, 1, 2, 2.5, or 5 times a power of ten, that
    # covers Min to Max in at most MaxTicks intervals.
    param([Parameter(Mandatory)][double]$Min, [Parameter(Mandatory)][double]$Max, [int]$MaxTicks = 6)
    $span = $Max - $Min
    if ($span -le 0) { return 1.0 }
    $power = [math]::Pow(10, [math]::Floor([math]::Log10($span / $MaxTicks)))
    foreach ($scale in 1, 10, 100) {
        foreach ($factor in 1, 2, 2.5, 5) {
            $step = $factor * $power * $scale
            if ([math]::Ceiling($Max / $step - 1e-9) - [math]::Floor($Min / $step + 1e-9) -le $MaxTicks) { return $step }
        }
    }
    return $span
}

function Format-ForecastCompactAmount {
    # 1.25M, 250K, or 980, for chart labels.
    param([double]$Value)
    $abs = [math]::Abs($Value)
    foreach ($unit in @(@(1e9, 'B'), @(1e6, 'M'), @(1e3, 'K'))) {
        if ($abs -ge $unit[0]) { return ($Value / $unit[0]).ToString('0.##', $script:ForecastInvariant) + $unit[1] }
    }
    return $Value.ToString('0.##', $script:ForecastInvariant)
}

function Format-ForecastAxisValue {
    param([double]$Value, [string]$Scale)
    if ([math]::Abs($Value) -lt 1e-9) { $Value = 0 }
    if ($Scale -eq 'Percent') { return ($Value * 100).ToString('0.##', $script:ForecastInvariant) + '%' }
    return Format-ForecastCompactAmount -Value $Value
}

function Format-ForecastSvgNumber {
    param([double]$Value)
    return ([math]::Round($Value, 1)).ToString($script:ForecastInvariant)
}

function ConvertTo-ForecastChart {
    # A column chart as inline SVG. Each column stacks its segments up from
    # zero, or down for negative values, with an optional line from Low to
    # High. Lines mark a value across the plot, bands shade a range, and
    # regions label runs of columns. Tips show as tooltips; the same values
    # are in the tab's table.
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Description,
        [AllowEmptyCollection()][object[]]$Columns,
        [ValidateSet('Amount', 'Percent')][string]$Scale = 'Amount',
        [string]$Unit,
        [AllowEmptyCollection()][object[]]$Lines = @(),
        [AllowEmptyCollection()][object[]]$Bands = @(),
        [AllowEmptyCollection()][object[]]$Regions = @()
    )
    $count = @($Columns).Count
    if (-not $count) { return '' }
    $width = 960; $height = 300; $left = 72; $right = 20; $bottom = 46
    $top = if (@($Regions).Count) { 38 } else { 20 }
    $plotWidth = $width - $left - $right
    $plotHeight = $height - $top - $bottom
    $values = [Collections.Generic.List[double]]::new()
    $values.Add(0)
    foreach ($column in $Columns) {
        $up = 0.0; $down = 0.0
        foreach ($segment in @($column.Segments)) { $v = [double]$segment.Value; if ($v -ge 0) { $up += $v } else { $down += $v } }
        $values.Add($up); $values.Add($down)
        if ($null -ne $column.Low) { $values.Add([double]$column.Low) }
        if ($null -ne $column.High) { $values.Add([double]$column.High) }
    }
    foreach ($line in @($Lines)) { $values.Add([double]$line.Value) }
    foreach ($band in @($Bands)) { $values.Add([double]$band.From); $values.Add([double]$band.To) }
    $min = [double]($values | Measure-Object -Minimum).Minimum
    $max = [double]($values | Measure-Object -Maximum).Maximum
    if ($max - $min -le 0) { $max = $min + $(if ($Scale -eq 'Percent') { 0.01 } else { 1.0 }) }
    $step = Get-ForecastChartStep -Min $min -Max $max
    $axisLow = [math]::Floor($min / $step + 1e-9) * $step
    $axisHigh = [math]::Ceiling($max / $step - 1e-9) * $step
    if ($axisHigh - $axisLow -le 0) { $axisHigh = $axisLow + $step }
    $toY = { param([double]$Value) $top + ($axisHigh - $Value) / ($axisHigh - $axisLow) * $plotHeight }
    $bandWidth = $plotWidth / $count
    $barWidth = [math]::Max(4.0, [math]::Min(58.0, $bandWidth * 0.62))
    $plotRight = $left + $plotWidth
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append("<svg id=""$Id"" class=""chart"" viewBox=""0 0 $width $height"" role=""img"" aria-labelledby=""$Id-title $Id-desc"">")
    [void]$sb.Append("<title id=""$Id-title"">$(ConvertTo-ForecastHtmlText $Title)</title><desc id=""$Id-desc"">$(ConvertTo-ForecastHtmlText $Description)</desc>")
    [void]$sb.Append("<defs><pattern id=""$Id-hatch"" width=""6"" height=""6"" patternUnits=""userSpaceOnUse"" patternTransform=""rotate(45)""><rect width=""6"" height=""6"" fill=""#FFFFFF""/><rect width=""3"" height=""6"" fill=""#0D0061""/></pattern></defs>")
    [void]$sb.Append('<g class="grid">')
    $ticks = [int][math]::Round(($axisHigh - $axisLow) / $step)
    for ($k = 0; $k -le $ticks; $k++) {
        $value = $axisLow + $k * $step
        $y = Format-ForecastSvgNumber (& $toY $value)
        [void]$sb.Append("<line x1=""$left"" x2=""$plotRight"" y1=""$y"" y2=""$y""/><text class=""ylabel"" x=""$($left - 8)"" y=""$y"" dy=""4"" text-anchor=""end"">$(ConvertTo-ForecastHtmlText (Format-ForecastAxisValue -Value $value -Scale $Scale))</text>")
    }
    if ($Unit) { [void]$sb.Append("<text class=""ylabel"" x=""$($left - 8)"" y=""$($top - $(if (@($Regions).Count) { 18 } else { 8 }))"" text-anchor=""end"">$(ConvertTo-ForecastHtmlText $Unit)</text>") }
    [void]$sb.Append('</g>')
    foreach ($band in @($Bands)) {
        $y1 = & $toY ([math]::Max([double]$band.From, [double]$band.To))
        $y2 = & $toY ([math]::Min([double]$band.From, [double]$band.To))
        [void]$sb.Append("<rect class=""band"" x=""$left"" y=""$(Format-ForecastSvgNumber $y1)"" width=""$plotWidth"" height=""$(Format-ForecastSvgNumber ([math]::Max(1, $y2 - $y1)))""/>")
        if ($band.Label) { [void]$sb.Append("<text class=""band-label"" x=""$($left + 6)"" y=""$(Format-ForecastSvgNumber ($y1 - 5))"">$(ConvertTo-ForecastHtmlText $band.Label)</text>") }
    }
    foreach ($region in @($Regions)) {
        $x1 = Format-ForecastSvgNumber ($left + $bandWidth * $region.First + 3)
        $x2 = Format-ForecastSvgNumber ($left + $bandWidth * ($region.Last + 1) - 3)
        [void]$sb.Append("<line class=""region-line"" x1=""$x1"" x2=""$x2"" y1=""$($top - 12)"" y2=""$($top - 12)""/><text class=""region-label"" x=""$x1"" y=""$($top - 18)"">$(ConvertTo-ForecastHtmlText $region.Label)</text>")
    }
    $zero = & $toY 0
    [void]$sb.Append('<g class="columns">')
    for ($i = 0; $i -lt $count; $i++) {
        $column = $Columns[$i]
        $center = $left + $bandWidth * ($i + 0.5)
        $x = Format-ForecastSvgNumber ($center - $barWidth / 2)
        [void]$sb.Append("<g class=""col""><title>$(ConvertTo-ForecastHtmlText $column.Tip)</title>")
        $up = 0.0; $down = 0.0
        foreach ($segment in @($column.Segments)) {
            $v = [double]$segment.Value
            if ($v -eq 0) { continue }
            if ($v -gt 0) { $y1 = & $toY ($up + $v); $y2 = & $toY $up; $up += $v }
            else { $y1 = & $toY $down; $y2 = & $toY ($down + $v); $down += $v }
            $fill = if ($segment.Class -eq 'provisional') { " fill=""url(#$Id-hatch)""" } else { '' }
            [void]$sb.Append("<rect class=""seg $($segment.Class)""$fill x=""$x"" y=""$(Format-ForecastSvgNumber $y1)"" width=""$(Format-ForecastSvgNumber $barWidth)"" height=""$(Format-ForecastSvgNumber ([math]::Max(0.5, $y2 - $y1)))""/>")
        }
        if ($column.Empty) {
            $label = if ($column.EmptyLabel) { $column.EmptyLabel } else { 'No data' }
            [void]$sb.Append("<text class=""empty-label"" x=""$(Format-ForecastSvgNumber $center)"" y=""$(Format-ForecastSvgNumber ($zero - 8))"" text-anchor=""middle"">$(ConvertTo-ForecastHtmlText $label)</text>")
        }
        if ($null -ne $column.Low -and $null -ne $column.High) {
            $yHigh = Format-ForecastSvgNumber (& $toY ([double]$column.High))
            $yLow = Format-ForecastSvgNumber (& $toY ([double]$column.Low))
            $cap = $barWidth * 0.22
            $cx = Format-ForecastSvgNumber $center
            [void]$sb.Append("<path class=""whisker"" d=""M$(Format-ForecastSvgNumber ($center - $cap)) $yHigh H$(Format-ForecastSvgNumber ($center + $cap)) M$cx $yHigh V$yLow M$(Format-ForecastSvgNumber ($center - $cap)) $yLow H$(Format-ForecastSvgNumber ($center + $cap))""/>")
        }
        [void]$sb.Append('</g>')
    }
    [void]$sb.Append('</g>')
    [void]$sb.Append("<line class=""zero"" x1=""$left"" x2=""$plotRight"" y1=""$(Format-ForecastSvgNumber $zero)"" y2=""$(Format-ForecastSvgNumber $zero)""/>")
    foreach ($line in @($Lines)) {
        $y = & $toY ([double]$line.Value)
        [void]$sb.Append("<line class=""ref"" x1=""$left"" x2=""$plotRight"" y1=""$(Format-ForecastSvgNumber $y)"" y2=""$(Format-ForecastSvgNumber $y)""/>")
        if ($line.Label) { [void]$sb.Append("<text class=""ref-label"" x=""$($plotRight - 4)"" y=""$(Format-ForecastSvgNumber ($y - 6))"" text-anchor=""end"">$(ConvertTo-ForecastHtmlText $line.Label)</text>") }
    }
    # Every label when they fit, otherwise every second or third.
    $every = [math]::Max(1, [int][math]::Ceiling(34 / $bandWidth))
    $lastSublabel = ''
    [void]$sb.Append('<g class="axis">')
    for ($i = 0; $i -lt $count; $i += $every) {
        $column = $Columns[$i]
        $cx = Format-ForecastSvgNumber ($left + $bandWidth * ($i + 0.5))
        [void]$sb.Append("<text class=""xlabel"" x=""$cx"" y=""$($top + $plotHeight + 18)"" text-anchor=""middle"">$(ConvertTo-ForecastHtmlText $column.Label)</text>")
        if ($column.Sublabel -and $column.Sublabel -ne $lastSublabel) {
            [void]$sb.Append("<text class=""xsublabel"" x=""$cx"" y=""$($top + $plotHeight + 34)"" text-anchor=""middle"">$(ConvertTo-ForecastHtmlText $column.Sublabel)</text>")
            $lastSublabel = $column.Sublabel
        }
    }
    [void]$sb.Append('</g></svg>')
    return $sb.ToString()
}

function ConvertTo-ForecastChartLegend {
    # Entries are Class and Label pairs; the key's color comes from Class.
    param([AllowEmptyCollection()][object[]]$Entries)
    if (-not @($Entries).Count) { return '' }
    $items = foreach ($entry in $Entries) { "<li><span class=""key key-$($entry.Class)"" aria-hidden=""true""></span>$(ConvertTo-ForecastHtmlText $entry.Label)</li>" }
    return "<ul class=""chart-legend"">$($items -join '')</ul>"
}

# -- Overview --------------------------------------------------------------
function Get-ForecastHtmlSourceText {
    # "124 live Cost Details sources", "2 Cost Management export sources", or both.
    param($Settings, $Dataset)
    if ($Dataset -and $Dataset.Mode -eq 'Manual') { return 'Manual inputs' }
    if (-not $Settings) { return '' }
    $sources = @($Settings.sources | Where-Object { $_ })
    $live = @($sources | Where-Object { [string]$_.kind -eq 'CostDetails' }).Count
    $parts = @()
    if ($sources.Count - $live) { $parts += Get-ForecastCountText -Count ($sources.Count - $live) -Singular 'Cost Management export source' -Plural 'Cost Management export sources' }
    if ($live) { $parts += Get-ForecastCountText -Count $live -Singular 'live Cost Details source' -Plural 'live Cost Details sources' }
    return $parts -join ' and '
}

function ConvertTo-ForecastKpiHtml {
    param([string]$Name, [string]$Value, [string]$Plain)
    return "<div class=""kpi""><div class=""kpi-name"">$(ConvertTo-ForecastHtmlText $Name)</div><div class=""kpi-value"">$(ConvertTo-ForecastHtmlText $Value)</div><div class=""kpi-plain"">$(ConvertTo-ForecastHtmlText $Plain)</div></div>"
}

function ConvertTo-ForecastStatusHtml {
    # What the status means, and what blocks or weakens the forecast, with
    # links to the tabs that explain each item.
    param([Parameter(Mandatory)]$Model, [Parameter(Mandatory)]$Readiness)
    $checks = @($Readiness.Checks)
    # Pending reviews are listed on their own, so their check isn't repeated.
    $failed = @($checks | Where-Object { $_.Status -eq 'Fail' -and $_.Id -ne 'EXCEPTIONS' })
    $warned = @($checks | Where-Object Status -EQ 'Warn')
    $pending = @($Readiness.Reviews | Where-Object { $_ -and $_.Required -and $_.Decision -eq 'Pending' })
    $labels = @($Readiness.Labels)
    $months = @($Model.Window.Rows).Count
    $history = "$months months of history give $([math]::Max(0, $months - 1)) changes between months"
    switch ([string]$Readiness.Status) {
        'Ready' { $tone = 'green'; $lead = '<strong>Ready.</strong> Every check passed, and every required review has a decision.' }
        'Preliminary' { $tone = 'yellow'; $lead = "<strong>Preliminary.</strong> $(ConvertTo-ForecastHtmlText "$history, so treat this as an early indication, not a number to commit to. A Ready forecast needs $($script:ForecastReadyMonths) months.")" }
        default {
            $tone = 'red'
            $parts = @()
            if ($failed.Count) { $parts += "$(Get-ForecastCountText -Count $failed.Count -Singular 'check' -Plural 'checks') failed" }
            if ($pending.Count) { $parts += "$(Get-ForecastCountText -Count $pending.Count -Singular 'required review is' -Plural 'required reviews are') pending" }
            if (-not $parts.Count) { $parts += 'A check failed' }
            $subject = if (($failed.Count + $pending.Count) -gt 1) { "they're" } else { "it's" }
            $text = "$($parts -join ', and '). Treat this number as a draft until $subject resolved."
            if (@($labels | Where-Object { $_ -like 'Preliminary*' }).Count) { $text += " It's also preliminary: $history, and a Ready forecast needs $($script:ForecastReadyMonths) months." }
            $lead = "<strong>Not ready.</strong> $(ConvertTo-ForecastHtmlText $text)"
        }
    }
    $notes = @()
    if ($labels -contains 'Partial population') { $notes += 'Some subscriptions in scope have no cost data in some months.' }
    if ($labels -contains 'Stale data') { $notes += 'Some of the data may be out of date.' }
    if ($notes.Count) { $lead += " $(ConvertTo-ForecastHtmlText ($notes -join ' '))" }
    $items = [Collections.Generic.List[string]]::new()
    foreach ($check in $failed) {
        $items.Add("<a class=""report-jump"" data-target=""tab-checks"" href=""#checks-heading"">$(ConvertTo-ForecastHtmlText $check.Name)</a>: $(ConvertTo-ForecastHtmlText (Get-ForecastShortText -Text $check.Detail))")
    }
    if ($pending.Count) {
        # Reviews with the same title, such as two recurring purchases, are told apart by subject.
        $titles = @($pending | Select-Object -First 4 | ForEach-Object {
                $title = [string]$_.Title
                if ($_.Subject -and $title -notlike "*$($_.Subject)*") { $title += " ($($_.Subject))" }
                ConvertTo-ForecastHtmlText $title
            }) -join '; '
        $more = if ($pending.Count -gt 4) { "; and $($pending.Count - 4) more" } else { '' }
        $items.Add("<a class=""report-jump"" data-target=""tab-reviews"" href=""#reviews-heading"">$(Get-ForecastCountText -Count $pending.Count -Singular 'required review' -Plural 'required reviews')</a> to decide in FinOps Explorer: $titles$more.")
    }
    if ($warned.Count) {
        $names = @($warned | ForEach-Object { ConvertTo-ForecastHtmlText $_.Name }) -join ', '
        $items.Add("<a class=""report-jump"" data-target=""tab-checks"" href=""#checks-heading"">$(Get-ForecastCountText -Count $warned.Count -Singular 'check has' -Plural 'checks have') a warning</a>: $names.")
    }
    $list = if ($items.Count) { "<p class=""callout-heading"">What needs attention</p><ul>$(($items | ForEach-Object { "<li>$_</li>" }) -join '')</ul>" } else { '' }
    return "<div class=""guidance $tone status-callout""><p>$lead</p>$list</div>"
}

function ConvertTo-ForecastCompositionHtml {
    # The central estimate as actuals, the rest of the year's forecast, and
    # scheduled items, which add up to it exactly.
    param([Parameter(Mandatory)]$Projection, [string]$Currency)
    $total = [decimal]$Projection.TotalCentral
    $parts = @(
        [pscustomobject]@{ Class = 'actual'; Label = 'Actuals to date'; Value = [decimal]$Projection.ActualToDate }
        [pscustomobject]@{ Class = 'forecast'; Label = 'Forecast for the rest of the year'; Value = [decimal]$Projection.RemainingRunRateCentral }
        [pscustomobject]@{ Class = 'scheduled'; Label = 'Scheduled items'; Value = [decimal]$Projection.Scheduled }
    )
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append('<table class="statement"><tbody>')
    foreach ($part in $parts) {
        $share = if ($total -gt 0) { Format-ForecastPercent ($part.Value / $total) } else { '' }
        [void]$sb.Append("<tr><th scope=""row""><span class=""key key-$($part.Class)"" aria-hidden=""true""></span>$(ConvertTo-ForecastHtmlText $part.Label)</th><td class=""numeric-cell"">$(ConvertTo-ForecastHtmlText (Format-ForecastAmount $part.Value))</td><td class=""numeric-cell"">$share</td></tr>")
    }
    $label = if ($Currency) { "Central estimate ($Currency)" } else { 'Central estimate' }
    [void]$sb.Append("</tbody><tfoot><tr><th scope=""row"">$(ConvertTo-ForecastHtmlText $label)</th><td class=""numeric-cell"">$(ConvertTo-ForecastHtmlText (Format-ForecastAmount $total))</td><td class=""numeric-cell"">$(if ($total -gt 0) { '100.0%' })</td></tr></tfoot></table>")
    if ($total -gt 0 -and @($parts | Where-Object { $_.Value -lt 0 }).Count -eq 0) {
        [void]$sb.Append('<div class="composition" aria-hidden="true">')
        foreach ($part in $parts) { if ($part.Value -gt 0) { [void]$sb.Append("<span class=""$($part.Class)"" style=""width:$(([math]::Round([double]($part.Value / $total) * 100, 2)).ToString($script:ForecastInvariant))%""></span>") } }
        [void]$sb.Append('</div>')
    }
    [void]$sb.Append("<p class=""story-note"">The low and high totals, $(ConvertTo-ForecastHtmlText (Format-ForecastAmount $Projection.TotalLow)) and $(ConvertTo-ForecastHtmlText (Format-ForecastAmount $Projection.TotalHigh)), keep the same actuals and scheduled items and apply the low or high growth rate to every forecast month.</p>")
    return $sb.ToString()
}

function Get-ForecastQuarterRows {
    # Fiscal quarters of three months each, summed from the projection.
    param([Parameter(Mandatory)]$Projection)
    $rows = @($Projection.Rows)
    $quarters = [Collections.Generic.List[object]]::new()
    for ($start = 0; $start -lt $rows.Count; $start += 3) {
        $members = @($rows[$start..([math]::Min($start + 2, $rows.Count - 1))])
        $sum = [ordered]@{ Actual = 0d; RunRateCentral = 0d; Scheduled = 0d; TotalLow = 0d; TotalCentral = 0d; TotalHigh = 0d }
        foreach ($row in $members) { foreach ($name in @($sum.Keys)) { $sum[$name] += [decimal]$row.$name } }
        $quarters.Add([pscustomobject]@{
                Quarter = "Q$($quarters.Count + 1)"; Months = Format-ForecastMonthRange -First $members[0].Month -Last $members[-1].Month
                Actual = $sum.Actual; Forecast = $sum.RunRateCentral; Scheduled = $sum.Scheduled
                TotalLow = $sum.TotalLow; TotalCentral = $sum.TotalCentral; TotalHigh = $sum.TotalHigh
            })
    }
    return , $quarters.ToArray()
}

function ConvertTo-ForecastQuarterHtml {
    param([Parameter(Mandatory)]$Projection)
    $fy = $Projection.FiscalYear
    $amounts = 'Actual', 'Forecast', 'Scheduled', 'TotalLow', 'TotalCentral', 'TotalHigh'
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append('<div class="table-scroll"><table class="statement quarters"><thead><tr><th scope="col">Quarter</th><th scope="col">Months</th><th scope="col" class="numeric-cell">Actual</th><th scope="col" class="numeric-cell">Forecast</th><th scope="col" class="numeric-cell">Scheduled</th><th scope="col" class="numeric-cell">Low</th><th scope="col" class="numeric-cell">Central</th><th scope="col" class="numeric-cell">High</th></tr></thead><tbody>')
    foreach ($quarter in (Get-ForecastQuarterRows -Projection $Projection)) {
        [void]$sb.Append("<tr><th scope=""row"">$($quarter.Quarter)</th><td>$(ConvertTo-ForecastHtmlText $quarter.Months)</td>")
        foreach ($name in $amounts) { [void]$sb.Append("<td class=""numeric-cell"">$(ConvertTo-ForecastHtmlText (Format-ForecastAmount $quarter.$name))</td>") }
        [void]$sb.Append('</tr>')
    }
    $totals = [pscustomobject]@{ Actual = $Projection.ActualToDate; Forecast = $Projection.RemainingRunRateCentral; Scheduled = $Projection.Scheduled; TotalCentral = $Projection.TotalCentral; TotalLow = $Projection.TotalLow; TotalHigh = $Projection.TotalHigh }
    [void]$sb.Append("</tbody><tfoot><tr><th scope=""row"">$(ConvertTo-ForecastHtmlText $fy.Label)</th><td>$(ConvertTo-ForecastHtmlText (Format-ForecastMonthRange -First $fy.FirstMonth -Last $fy.LastMonth))</td>")
    foreach ($name in $amounts) { [void]$sb.Append("<td class=""numeric-cell"">$(ConvertTo-ForecastHtmlText (Format-ForecastAmount $totals.$name))</td>") }
    [void]$sb.Append('</tr></tfoot></table></div>')
    return $sb.ToString()
}

function ConvertTo-ForecastDriversHtml {
    # The baseline, growth, history, and cost basis behind the forecast, in plain words.
    param([Parameter(Mandatory)]$Model, [Parameter(Mandatory)]$Dataset, $Settings)
    $currency = [string]$Dataset.Currency
    $baseline = $Model.Baseline
    $growth = $Model.Growth
    $window = $Model.Window
    $sb = [Text.StringBuilder]::new()
    $value = if ($null -ne $baseline.Value) { "$(Format-ForecastAmount $baseline.Value $currency) a 30-day month" } else { 'Not available' }
    $plain = switch ([string]$baseline.Method) {
        'LatestMonth' { "Usage cost in $(Get-ForecastMonthName -MonthKey $baseline.Month), the latest month of history, scaled to 30 days. Every forecast month grows from it." }
        'MedianLast3' { "The median 30-day run rate of the last three months of history, to $(Get-ForecastMonthName -MonthKey $baseline.Month). Every forecast month grows from it." }
        'Manual' { 'A 30-day run rate entered by hand after review. Every forecast month grows from it.' }
        default { [string]$baseline.Detail }
    }
    if ($baseline.Pending) { $plain += " It's waiting for review." }
    [void]$sb.Append((ConvertTo-ForecastKpiHtml -Name 'Baseline' -Value $value -Plain $plain))

    $value = if ($null -ne $growth.Central) { "$(Format-ForecastPercent $growth.Central 2) a month" } else { 'Not available' }
    $range = if ($growth.RangeMethod -eq 'LowestToHighest') { 'the lowest to the highest retained change' } else { "P$(Format-ForecastDecimal $growth.LowPercentile) to P$(Format-ForecastDecimal $growth.HighPercentile) of retained changes" }
    $plain = if ($null -ne $growth.Central) { "The median of $(Get-ForecastCountText -Count $growth.Retained -Singular 'retained change' -Plural 'retained changes') between months, compounded each month. The sensitivity range runs from $($range), $(Format-ForecastPercent $growth.Low 2) to $(Format-ForecastPercent $growth.High 2)." } else { 'No change between months was retained, so there is no growth rate yet.' }
    [void]$sb.Append((ConvertTo-ForecastKpiHtml -Name 'Monthly growth' -Value $value -Plain $plain))

    $items = @($Model.Comparisons.Items)
    $counts = [ordered]@{ retained = 0; pending = 0; leftOut = 0; missing = 0 }
    foreach ($item in $items) {
        if ($item.Status -eq 'MissingData') { $counts['missing'] += 1 }
        elseif ($item.Retained) { $counts['retained'] += 1 }
        elseif ($item.Review -and $item.Review.Decision -eq 'Pending') { $counts['pending'] += 1 }
        else { $counts['leftOut'] += 1 }
    }
    $parts = @()
    if ($counts['retained']) { $parts += "$($counts['retained']) retained" }
    if ($counts['pending']) { $parts += "$($counts['pending']) waiting for review" }
    if ($counts['leftOut']) { $parts += "$($counts['leftOut']) left out after review" }
    if ($counts['missing']) { $parts += "$($counts['missing']) missing data" }
    $months = @($window.Rows).Count
    $plain = "$(Get-ForecastCountText -Count $items.Count -Singular 'change' -Plural 'changes') between months$(if ($parts.Count) { ": $($parts -join ', ')" })."
    if ($months -lt $script:ForecastReadyMonths) { $plain += " A Ready forecast needs $($script:ForecastReadyMonths) months." }
    [void]$sb.Append((ConvertTo-ForecastKpiHtml -Name 'History' -Value "$(Get-ForecastCountText -Count $months -Singular 'month' -Plural 'months'): $(Format-ForecastMonthRange -First $window.First -Last $window.Last)" -Plain $plain))

    $basis = @('Azure credits are never counted.')
    if ($Settings) {
        $basis += "Marketplace charges are $(if ($Settings.filters.includeMarketplace) { 'included' } else { 'excluded' }); tax is $(if ($Settings.filters.includeTax) { 'included' } else { 'excluded' })."
        if ((ConvertTo-ForecastSettingSwitch -Value $Settings.filters.showMarketplace -Default $true) -and @($Dataset.Marketplace | Where-Object { $_ }).Count) { $basis += 'The Marketplace tab lists Marketplace charges by month.' }
    }
    $through = Format-ForecastLongDate $Dataset.DataThrough
    if ($through) { $basis += "Actual cost through $through." }
    $source = Get-ForecastHtmlSourceText -Settings $Settings -Dataset $Dataset
    if ($source) { $basis += "Read from $source." }
    [void]$sb.Append((ConvertTo-ForecastKpiHtml -Name 'Cost basis' -Value $(if ($currency) { "Pre-credit actual cost in $currency" } else { 'Pre-credit actual cost' }) -Plain ($basis -join ' ')))
    return $sb.ToString()
}

function Get-ForecastWorkloadGroupText {
    # "by the workload tag", "by resource group", or "by subscription".
    param($Workloads)
    switch ([string]$Workloads.Mode) {
        'Tag' { if ($Workloads.TagKey) { return "by the $($Workloads.TagKey) tag" } return 'by tag' }
        'ResourceGroup' { return 'by resource group' }
        'Subscription' { return 'by subscription' }
    }
    return ''
}

function ConvertTo-ForecastTopWorkloadsHtml {
    # The five largest increases in run rate, for the overview.
    param($Workloads)
    $top = @($Workloads.Workloads | Where-Object { $null -ne $_.Change -and [decimal]$_.Change -gt 0 } | Select-Object -First 5)
    if (-not $top.Count) { return '' }
    $by = Get-ForecastWorkloadGroupText -Workloads $Workloads
    $months = @($Workloads.Months)
    $span = if ($months.Count) { " from $(Format-ForecastMonthRange -First $months[0] -Last $months[-1])" } else { '' }
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append('<h2>Largest workload increases</h2>')
    $count = @($Workloads.Workloads).Count
    $more = if ($count -gt $top.Count) { "lists all $count" } else { 'has more detail' }
    [void]$sb.Append("<p class=""story-note"">Change in 30-day run rate$(ConvertTo-ForecastHtmlText $span), grouped $(ConvertTo-ForecastHtmlText $by). The <a class=""report-jump"" data-target=""tab-workloads"" href=""#workloads-heading"">Workloads</a> tab $more.</p>")
    [void]$sb.Append('<div class="table-scroll"><table class="statement"><thead><tr><th scope="col">Workload</th><th scope="col" class="numeric-cell">Change</th><th scope="col" class="numeric-cell">Growth</th><th scope="col" class="numeric-cell">Share of net change</th></tr></thead><tbody>')
    foreach ($workload in $top) {
        [void]$sb.Append("<tr><th scope=""row"">$(ConvertTo-ForecastHtmlText $workload.WorkloadName)</th><td class=""numeric-cell"">$(ConvertTo-ForecastHtmlText (Format-ForecastAmount $workload.Change))</td><td class=""numeric-cell"">$(ConvertTo-ForecastHtmlText (Format-ForecastPercent $workload.Growth))</td><td class=""numeric-cell"">$(ConvertTo-ForecastHtmlText (Format-ForecastPercent $workload.ContributionShare))</td></tr>")
    }
    [void]$sb.Append('</tbody></table></div>')
    return $sb.ToString()
}

function ConvertTo-ForecastFiscalYearChartHtml {
    # Actual months in navy, forecast months in blue with a line from the
    # low to the high total, and scheduled items stacked on top.
    param([Parameter(Mandatory)]$Projection, [string]$Currency)
    $rows = @($Projection.Rows)
    $suffix = if ($Currency) { " $Currency" } else { '' }
    $columns = foreach ($row in $rows) {
        $kind = [string]$row.Kind
        $segments = [Collections.Generic.List[object]]::new()
        switch ($kind) {
            'Actual' { $segments.Add([pscustomobject]@{ Value = $row.Actual; Class = 'actual' }) }
            'ProvisionalActual' { $segments.Add([pscustomobject]@{ Value = $row.Actual; Class = 'provisional' }) }
            'MissingActual' { }
            default {
                if ([decimal]$row.Actual -ne 0) { $segments.Add([pscustomobject]@{ Value = $row.Actual; Class = 'actual' }) }
                if ([decimal]$row.RunRateCentral -ne 0) { $segments.Add([pscustomobject]@{ Value = $row.RunRateCentral; Class = 'forecast' }) }
                if ([decimal]$row.Scheduled -ne 0) { $segments.Add([pscustomobject]@{ Value = $row.Scheduled; Class = 'scheduled' }) }
            }
        }
        $ranged = $kind -in 'PartialActual', 'Forecast' -and [decimal]$row.TotalHigh -ne [decimal]$row.TotalLow
        $tip = switch ($kind) {
            'MissingActual' { "$(Get-ForecastMonthName -MonthKey $row.Month): no final data" }
            'Actual' { "$(Get-ForecastMonthName -MonthKey $row.Month), actual: $(Format-ForecastAmount $row.Actual)$suffix" }
            'ProvisionalActual' { "$(Get-ForecastMonthName -MonthKey $row.Month), actual, not final: $(Format-ForecastAmount $row.Actual)$suffix" }
            default {
                $pieces = @()
                if ([decimal]$row.Actual -ne 0) { $pieces += "$(Format-ForecastAmount $row.Actual) actual" }
                $pieces += "$(Format-ForecastAmount $row.RunRateCentral) forecast"
                if ([decimal]$row.Scheduled -ne 0) { $pieces += "$(Format-ForecastAmount $row.Scheduled) scheduled" }
                $sum = if ($pieces.Count -gt 1) { "$($pieces -join ' + ') = " } else { '' }
                "$(Get-ForecastMonthName -MonthKey $row.Month), $($script:ForecastHtmlKinds[$kind].ToLowerInvariant()): $sum$(Format-ForecastAmount $row.TotalCentral)$suffix (low $(Format-ForecastAmount $row.TotalLow), high $(Format-ForecastAmount $row.TotalHigh))"
            }
        }
        [pscustomobject]@{
            Label = Get-ForecastMonthName -MonthKey $row.Month -Short -NoYear; Sublabel = ([string]$row.Month).Substring(0, 4); Segments = $segments.ToArray()
            Low = $(if ($ranged) { $row.TotalLow } else { $null }); High = $(if ($ranged) { $row.TotalHigh } else { $null })
            Empty = $kind -eq 'MissingActual'; EmptyLabel = 'No data'; Tip = $tip
        }
    }
    $columns = @($columns)
    $firstForecast = -1
    for ($i = 0; $i -lt $rows.Count; $i++) { if ($rows[$i].Kind -in 'PartialActual', 'Forecast') { $firstForecast = $i; break } }
    $regions = @()
    if ($firstForecast -gt 0) { $regions += [pscustomobject]@{ First = 0; Last = $firstForecast - 1; Label = 'Actual' } }
    if ($firstForecast -ge 0) { $regions += [pscustomobject]@{ First = $firstForecast; Last = $rows.Count - 1; Label = 'Forecast' } }
    $fy = $Projection.FiscalYear
    $description = "Columns show each month of $($fy.Label), $(Format-ForecastMonthRange -First $fy.FirstMonth -Last $fy.LastMonth)."
    if ($firstForecast -gt 0) { $description += " $(Format-ForecastMonthRange -First $rows[0].Month -Last $rows[$firstForecast - 1].Month) are actual cost." }
    if ($firstForecast -ge 0) { $description += " From $(Get-ForecastMonthName -MonthKey $rows[$firstForecast].Month), columns show the central forecast, with a line from the low to the high total." }
    $chart = ConvertTo-ForecastChart -Id 'chart-fiscal-year' -Title "$($fy.Label) by month" -Description $description -Columns $columns -Unit $Currency -Regions $regions
    $legend = @()
    if (@($rows | Where-Object { $_.Kind -eq 'Actual' -or ($_.Kind -eq 'PartialActual' -and [decimal]$_.Actual -ne 0) }).Count) { $legend += [pscustomobject]@{ Class = 'actual'; Label = 'Actual' } }
    if (@($rows | Where-Object Kind -EQ 'ProvisionalActual').Count) { $legend += [pscustomobject]@{ Class = 'provisional'; Label = 'Actual, not final' } }
    if ($firstForecast -ge 0) { $legend += [pscustomobject]@{ Class = 'forecast'; Label = 'Forecast (central)' } }
    if (@($rows | Where-Object { [decimal]$_.Scheduled -ne 0 }).Count) { $legend += [pscustomobject]@{ Class = 'scheduled'; Label = 'Scheduled items' } }
    if (@($columns | Where-Object { $null -ne $_.High }).Count) { $legend += [pscustomobject]@{ Class = 'range'; Label = 'Low to high total' } }
    return "<figure class=""chart-figure"">$chart$(ConvertTo-ForecastChartLegend -Entries $legend)</figure>"
}

function ConvertTo-ForecastOverviewHtml {
    param([Parameter(Mandatory)]$Model, [Parameter(Mandatory)]$Dataset, [Parameter(Mandatory)]$Readiness, $Workloads, $Settings, [string]$ScopeLabel)
    $currency = [string]$Dataset.Currency
    $projection = $Model.Projection
    $fy = $projection.FiscalYear
    $scope = if ($ScopeLabel) { $ScopeLabel } else { 'the selected scope' }
    $through = Format-ForecastLongDate $Dataset.DataThrough
    $intro = "$($fy.Label) runs from $(Format-ForecastMonthRange -First $fy.FirstMonth -Last $fy.LastMonth). This report forecasts its cost for $scope before Azure credits (pre-credit cost)$(if ($through) { ", from actual cost through $through" })."
    if ($currency) { $intro += " Amounts are in $currency." }
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append("<p class=""story-intro"">$(ConvertTo-ForecastHtmlText $intro)</p>")
    [void]$sb.Append((ConvertTo-ForecastStatusHtml -Model $Model -Readiness $Readiness))
    [void]$sb.Append("<h2>$(ConvertTo-ForecastHtmlText $fy.Label) by month</h2>")
    [void]$sb.Append("<p class=""story-note"">Point to a column to see its amounts. The <a class=""report-jump"" data-target=""tab-fiscal-year"" href=""#fiscal-year-heading"">Fiscal year by month</a> tab lists them.</p>")
    [void]$sb.Append((ConvertTo-ForecastFiscalYearChartHtml -Projection $projection -Currency $currency))
    [void]$sb.Append('<div class="overview-grid"><div>')
    [void]$sb.Append('<h2>How the central estimate adds up</h2>')
    [void]$sb.Append((ConvertTo-ForecastCompositionHtml -Projection $projection -Currency $currency))
    [void]$sb.Append('</div><div class="driver-list"><h2>What drives the forecast</h2>')
    [void]$sb.Append((ConvertTo-ForecastDriversHtml -Model $Model -Dataset $Dataset -Settings $Settings))
    [void]$sb.Append('</div></div>')
    [void]$sb.Append('<h2>By fiscal quarter</h2>')
    [void]$sb.Append((ConvertTo-ForecastQuarterHtml -Projection $projection))
    if ($Workloads) { [void]$sb.Append((ConvertTo-ForecastTopWorkloadsHtml -Workloads $Workloads)) }
    [void]$sb.Append('<p class="story-note">The sensitivity range shows how much growth between months varied in the history. It isn''t a confidence interval. Amounts are pre-credit cost: Azure credits are never subtracted.</p>')
    return $sb.ToString()
}

# -- Section tabs ----------------------------------------------------------
function ConvertTo-ForecastFiscalYearHtml {
    param([Parameter(Mandatory)]$Projection)
    $rows = foreach ($row in @($Projection.Rows)) {
        $row | Select-Object *, @{ Name = 'DaysText'; Expression = { if ($_.Kind -eq 'Forecast') { '' } else { "$($_.DaysWithData) of $($_.Days)" } } }
    }
    $footer = [ordered]@{ Month = 'Total'; Actual = $Projection.ActualToDate; RunRateCentral = $Projection.RemainingRunRateCentral; Scheduled = $Projection.Scheduled; TotalLow = $Projection.TotalLow; TotalCentral = $Projection.TotalCentral; TotalHigh = $Projection.TotalHigh }
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append('<h2 id="fiscal-year-heading" tabindex="-1">Fiscal year by month</h2>')
    [void]$sb.Append('<p class="story-note">Each month''s central total is its actual cost plus its forecast plus scheduled items, and the totals row adds them up. Low and high apply the low and high growth rates to every forecast month. A blank amount is missing; 0.00 is a measured zero.</p>')
    [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'table-fiscal-year' -Title 'Fiscal year by month' -Rows @($rows) -Footer $footer -Columns @(
                (New-ForecastColumn -Name Month -Format month), (New-ForecastColumn -Name Kind -Label 'Basis' -Format status -Map $script:ForecastHtmlKinds -Tone),
                (New-ForecastColumn -Name DaysText -Label 'Days with data' -Width 6), (New-ForecastColumn -Name Actual -Format amount),
                (New-ForecastColumn -Name RunRateCentral -Label 'Forecast (central)' -Format amount), (New-ForecastColumn -Name Scheduled -Format amount),
                (New-ForecastColumn -Name TotalLow -Label 'Low' -Format amount), (New-ForecastColumn -Name TotalCentral -Label 'Central' -Format amount),
                (New-ForecastColumn -Name TotalHigh -Label 'High' -Format amount), (New-ForecastColumn -Name Note))))
    return $sb.ToString()
}

function ConvertTo-ForecastHistoryHtml {
    param([Parameter(Mandatory)]$Model, [string]$Currency)
    $rows = @(foreach ($row in @($Model.Window.Rows)) {
            $row | Select-Object *, @{ Name = 'NormalizedRunRate'; Expression = { if (Test-ForecastMonthUsable $_) { Get-ForecastNormalizedRunRate $_ } else { $null } } }
        })
    $suffix = if ($Currency) { " $Currency" } else { '' }
    $columns = @(foreach ($row in $rows) {
            $usable = $null -ne $row.NormalizedRunRate
            [pscustomobject]@{
                Label = Get-ForecastMonthName -MonthKey $row.Month -Short -NoYear; Sublabel = ([string]$row.Month).Substring(0, 4)
                Segments = @(if ($usable) { [pscustomobject]@{ Value = $row.NormalizedRunRate; Class = 'runrate' } })
                Empty = -not $usable; EmptyLabel = 'No data'
                Tip = if ($usable) { "$(Get-ForecastMonthName -MonthKey $row.Month): 30-day run rate $(Format-ForecastAmount $row.NormalizedRunRate)$suffix ($($row.Status))" } else { "$(Get-ForecastMonthName -MonthKey $row.Month): $($row.Status), not used" }
            }
        })
    $baseline = $Model.Baseline.Value
    $lines = @(if ($null -ne $baseline) { [pscustomobject]@{ Value = $baseline; Label = "Baseline $(Format-ForecastCompactAmount ([double]$baseline))" } })
    $legend = @([pscustomobject]@{ Class = 'runrate'; Label = '30-day run rate' })
    if ($null -ne $baseline) { $legend += [pscustomobject]@{ Class = 'ref'; Label = "Baseline: $(Format-ForecastAmount $baseline $Currency)" } }
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append('<h2 id="history-heading" tabindex="-1">Monthly history</h2>')
    [void]$sb.Append('<p class="story-note">The 30-day run rate is a month''s usage cost scaled to 30 days, so months of different lengths compare fairly. Growth is measured on it. Purchases, adjustments, and other charges stay in the pre-credit total but aren''t grown.</p>')
    if ($rows.Count) {
        $chart = ConvertTo-ForecastChart -Id 'chart-history' -Title '30-day run rate by month' -Description "Columns show the 30-day run rate for each month from $(Format-ForecastMonthRange -First $Model.Window.First -Last $Model.Window.Last). The dashed line is the baseline the forecast grows from." -Columns $columns -Unit $Currency -Lines $lines
        [void]$sb.Append("<figure class=""chart-figure"">$chart$(ConvertTo-ForecastChartLegend -Entries $legend)</figure>")
    }
    [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'table-history' -Title 'Monthly history' -Rows $rows -Empty 'No months are in the lookback window.' -Columns @(
                (New-ForecastColumn -Name Month -Format month), (New-ForecastColumn -Name Status -Format status -Tone), (New-ForecastColumn -Name RunRate -Label 'Run-rate charges' -Format amount),
                (New-ForecastColumn -Name NormalizedRunRate -Label '30-day run rate' -Format amount), (New-ForecastColumn -Name Purchase -Label 'Purchases' -Format amount),
                (New-ForecastColumn -Name Adjustment -Label 'Adjustments' -Format amount), (New-ForecastColumn -Name Other -Format amount),
                (New-ForecastColumn -Name Headline -Label 'Pre-credit total' -Format amount), (New-ForecastColumn -Name Credit -Label 'Credits (not counted)' -Format amount),
                (New-ForecastColumn -Name ExcludedMarketplace -Label 'Excluded Marketplace' -Format amount), (New-ForecastColumn -Name DataThrough -Label 'Data through' -Format date),
                (New-ForecastColumn -Name Note))))
    return $sb.ToString()
}

function ConvertTo-ForecastComparisonsHtml {
    param([Parameter(Mandatory)]$Model)
    $comparisons = $Model.Comparisons
    $growth = $Model.Growth
    $rows = @(foreach ($item in @($comparisons.Items)) {
            $state = if ($item.Status -ne 'Defined') { 'none' } elseif ($item.Retained) { 'retained' } elseif ($item.Review -and $item.Review.Decision -eq 'Pending') { 'pending' } else { 'excluded' }
            $item | Select-Object *, @{ Name = 'Decision'; Expression = { if ($_.Review) { $_.Review.Decision } else { '' } } }, @{ Name = 'State'; Expression = { $state } }
        })
    $stateText = @{ retained = 'counts toward growth'; pending = 'waiting for review'; excluded = 'left out of growth'; none = 'not computed' }
    $columns = @(foreach ($row in $rows) {
            $defined = $row.State -ne 'none'
            [pscustomobject]@{
                Label = Get-ForecastMonthName -MonthKey $row.ToMonth -Short -NoYear; Sublabel = ([string]$row.ToMonth).Substring(0, 4)
                Segments = @(if ($defined) { [pscustomobject]@{ Value = $row.Change; Class = $row.State } })
                Empty = -not $defined; EmptyLabel = $(if ($row.Status -eq 'Undefined') { 'Undefined' } else { 'No data' })
                Tip = "$(Format-ForecastMonthRange -First $row.FromMonth -Last $row.ToMonth): $(if ($defined) { Format-ForecastPercent $row.Change } else { $row.Status }), $($stateText[$row.State])$(if ($row.Flagged) { ', flagged' })"
            }
        })
    $lines = @(if ($null -ne $growth.Central) { [pscustomobject]@{ Value = $growth.Central; Label = "Central growth $(Format-ForecastPercent $growth.Central 2)" } })
    $bands = @(if ($null -ne $growth.Low -and $null -ne $growth.High -and $growth.High -gt $growth.Low) { [pscustomobject]@{ From = $growth.Low; To = $growth.High; Label = 'Sensitivity range' } })
    $legend = @()
    foreach ($state in 'retained', 'excluded', 'pending') {
        if (@($rows | Where-Object State -EQ $state).Count) { $legend += [pscustomobject]@{ Class = $state; Label = $stateText[$state].Substring(0, 1).ToUpperInvariant() + $stateText[$state].Substring(1) } }
    }
    if ($lines.Count) { $legend += [pscustomobject]@{ Class = 'ref'; Label = 'Central growth' } }
    if ($bands.Count) { $legend += [pscustomobject]@{ Class = 'band'; Label = "Sensitivity range, $(Format-ForecastPercent $growth.Low 2) to $(Format-ForecastPercent $growth.High 2)" } }
    $summary = "$(Get-ForecastCountText -Count $rows.Count -Singular 'change' -Plural 'changes') between months: $(@($rows | Where-Object State -EQ 'retained').Count) retained."
    if ($null -ne $comparisons.Median -and $null -ne $comparisons.Threshold) { $summary += " The median change is $(Format-ForecastPercent $comparisons.Median), and a change more than $(Format-ForecastPercent $comparisons.Threshold) away from it is flagged for review." }
    if ($null -ne $growth.Central) { $summary += " Growth is the median of the retained changes, $(Format-ForecastPercent $growth.Central 2) a month." }
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append('<h2 id="comparisons-heading" tabindex="-1">Adjacent-month comparisons</h2>')
    [void]$sb.Append("<p class=""story-note"">$(ConvertTo-ForecastHtmlText $summary)</p>")
    if ($rows.Count) {
        $chart = ConvertTo-ForecastChart -Id 'chart-comparisons' -Title 'Change in 30-day run rate into each month' -Description "Columns show the change in 30-day run rate from the month before. Changes that count toward growth are blue, changes left out are gray, and changes waiting for review are amber. The dashed line is the central growth rate, and the shaded band is the sensitivity range." -Columns $columns -Scale Percent -Lines $lines -Bands $bands
        [void]$sb.Append("<figure class=""chart-figure"">$chart$(ConvertTo-ForecastChartLegend -Entries $legend)</figure>")
    }
    [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'table-comparisons' -Title 'Adjacent-month comparisons' -Rows $rows -Empty 'The lookback window has only one month, so there are no changes to compare.' -Columns @(
                (New-ForecastColumn -Name FromMonth -Label 'From' -Format month), (New-ForecastColumn -Name ToMonth -Label 'To' -Format month),
                (New-ForecastColumn -Name FromRunRate -Label 'From run rate' -Format amount), (New-ForecastColumn -Name ToRunRate -Label 'To run rate' -Format amount),
                (New-ForecastColumn -Name Change -Format percent), (New-ForecastColumn -Name Status -Format status), (New-ForecastColumn -Name Flagged -Format bool),
                (New-ForecastColumn -Name Decision -Format status -Tone), (New-ForecastColumn -Name Retained -Format bool), (New-ForecastColumn -Name Reason))))
    return $sb.ToString()
}

function ConvertTo-ForecastWorkloadsHtml {
    param([Parameter(Mandatory)]$Workloads, [string]$Currency)
    $months = @($Workloads.Months)
    $span = if ($months.Count) { "Change in 30-day run rate from $(Format-ForecastMonthRange -First $months[0] -Last $months[-1]). " } else { '' }
    $note = "$(Get-ForecastCountText -Count @($Workloads.Workloads).Count -Singular 'workload' -Plural 'workloads'), grouped $(Get-ForecastWorkloadGroupText -Workloads $Workloads). $($span)Share is a workload's change divided by the net change, $(Format-ForecastAmount $Workloads.NetChange $Currency). The largest increase is the biggest rise from one month to the next, which differs from the highest spend and the highest percentage growth."
    $hasPurchases = @($Workloads.Workloads | Where-Object { [decimal]$_.PurchasesFirst -ne 0 -or [decimal]$_.PurchasesLast -ne 0 }).Count -gt 0
    if ($hasPurchases -and $months.Count) { $note += " Purchases show on the subscription that pays for them, which may not be where a shared reservation or savings plan is used; net change adds the change in monthly purchases from $(Get-ForecastMonthName -MonthKey $months[0]) to $(Get-ForecastMonthName -MonthKey $months[-1])." }
    $paceLabel = $null
    if ($Workloads.PaceMonth -and $Workloads.PaceDays) {
        $paceLabel = "$(Get-ForecastMonthName -MonthKey $Workloads.PaceMonth -Short -NoYear) pace"
        $note += " $paceLabel is the cost from $(Get-ForecastMonthName -MonthKey $Workloads.PaceMonth -NoYear) 1 to $($Workloads.PaceDays), scaled to 30 days. It's for context and doesn't feed growth."
    }
    $columns = [Collections.Generic.List[object]]::new()
    foreach ($column in @(
            (New-ForecastColumn -Name WorkloadName -Label 'Workload'), (New-ForecastColumn -Name WorkloadId -Label 'ID' -Width 12), (New-ForecastColumn -Name Flags -Width 10),
            (New-ForecastColumn -Name FirstRunRate -Label 'First' -Format amount), (New-ForecastColumn -Name LastRunRate -Label 'Last' -Format amount),
            (New-ForecastColumn -Name Change -Format amount))) { $columns.Add($column) }
    if ($hasPurchases) {
        $columns.Add((New-ForecastColumn -Name PurchasesLast -Label 'Purchases, last month' -Format amount))
        $columns.Add((New-ForecastColumn -Name NetChange -Label 'Net change' -Format amount))
    }
    foreach ($column in @(
            (New-ForecastColumn -Name Growth -Format percent), (New-ForecastColumn -Name ContributionShare -Label 'Share' -Format percent),
            (New-ForecastColumn -Name LargestIncreaseMonth -Label 'Largest increase month' -Format month), (New-ForecastColumn -Name LargestIncreaseAmount -Label 'Largest increase' -Format amount))) { $columns.Add($column) }
    if ($paceLabel) { $columns.Add((New-ForecastColumn -Name MonthToDatePace -Label $paceLabel -Format amount)) }
    $columns.Add((New-ForecastColumn -Name LookbackSpend -Label 'Lookback spend' -Format amount))
    $columns.Add((New-ForecastColumn -Name Notes))
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append("<h2 id=""workloads-heading"" tabindex=""-1"">Workloads</h2>")
    [void]$sb.Append("<p class=""story-note"">$(ConvertTo-ForecastHtmlText $note)</p>")
    [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'table-workloads' -Title 'Workloads' -Rows $Workloads.Workloads -Empty 'No workloads had usage in the lookback window.' -Columns $columns.ToArray()))
    return $sb.ToString()
}

function ConvertTo-ForecastChecksHtml {
    param([Parameter(Mandatory)]$Readiness, [AllowEmptyCollection()][object[]]$ReadStatus = @())
    $checks = @($Readiness.Checks)
    $summary = "$(@($checks | Where-Object Status -EQ 'Pass').Count) passed, $(@($checks | Where-Object Status -EQ 'Warn').Count) with a warning, and $(@($checks | Where-Object Status -EQ 'Fail').Count) failed. A Ready forecast needs no failed check and $($script:ForecastReadyMonths) months of history."
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append('<h2 id="checks-heading" tabindex="-1">Checks</h2>')
    [void]$sb.Append("<p class=""story-note"">$(ConvertTo-ForecastHtmlText $summary)</p>")
    [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'table-checks' -Title 'Checks' -Rows $checks -Columns @((New-ForecastColumn -Name Name -Label 'Check' -Width 15), (New-ForecastColumn -Name Status -Format status -Tone -Width 7), (New-ForecastColumn -Name Detail))))
    [void]$sb.Append((ConvertTo-ForecastReadStatusHtml -Rows $ReadStatus))
    return $sb.ToString()
}

function ConvertTo-ForecastReadStatusHtml {
    # Every configured source and what its reads returned, problems first,
    # then the subscriptions left out of the scope with their reasons.
    param([AllowEmptyCollection()][object[]]$Rows = @())
    $rows = @($Rows | Where-Object { $_ })
    if (-not $rows.Count) { return '' }
    $order = @{ 'Unsupported offer' = 0; 'Access denied' = 1; 'Failed' = 2; 'Partly read' = 3; 'Not attempted' = 4; 'No rows' = 5; 'Left out' = 6; 'Rows' = 7 }
    $sorted = @($rows | Sort-Object @{ Expression = { if ($order.ContainsKey([string]$_.Status)) { $order[[string]$_.Status] } else { 9 } } }, @{ Expression = { [string]$_.Source } })
    $note = "$(Get-ForecastReadStatusSummary -Rows $rows) The first and last charge come from each source's latest complete month; charges that start late or end early are noted, since a quiet subscription can stop early but missing days can also mean missing data."
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append('<h2 id="read-status-heading" tabindex="-1">Sources read</h2>')
    [void]$sb.Append("<p class=""story-note"">$(ConvertTo-ForecastHtmlText $note)</p>")
    [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'table-read-status' -Title 'Sources read' -Rows $sorted -Columns @(
                (New-ForecastColumn -Name Source -Width 16), (New-ForecastColumn -Name Kind -Width 10), (New-ForecastColumn -Name Status -Format status -Tone),
                (New-ForecastColumn -Name MonthsRead -Label 'Months read' -Width 6.5), (New-ForecastColumn -Name Rows -Format number), (New-ForecastColumn -Name Included -Label 'Included' -Format amount),
                (New-ForecastColumn -Name FirstCharge -Label 'First charge' -Format date), (New-ForecastColumn -Name LastCharge -Label 'Last charge' -Format date), (New-ForecastColumn -Name Detail))))
    return $sb.ToString()
}

function ConvertTo-ForecastMarketplaceHtml {
    # Marketplace charges in scope, by month and by subscription. They're
    # counted only when the Marketplace filter includes them. Amounts in
    # different billing currencies are grouped and totaled apart.
    param([AllowEmptyCollection()][object[]]$Rows = @(), [Collections.IDictionary]$SubscriptionNames, [bool]$Counted, [string]$Currency)
    $rows = @($Rows | Where-Object { $_ })
    $currencies = @($rows | ForEach-Object { [string]$_.Currency } | Sort-Object -Unique)
    $mixed = $currencies.Count -gt 1
    $months = @($rows | ForEach-Object Month | Sort-Object -Unique)
    $monthly = foreach ($group in @($rows | Group-Object { "$($_.Month)|$($_.Currency)" } | Sort-Object Name)) {
        $usage = 0d; $purchases = 0d; $other = 0d
        foreach ($row in $group.Group) { switch ([string]$row.Stream) { 'RunRate' { $usage += [decimal]$row.Cost } 'Purchase' { $purchases += [decimal]$row.Cost } default { $other += [decimal]$row.Cost } } }
        [pscustomobject]@{ Month = [string]$group.Group[0].Month; Currency = [string]$group.Group[0].Currency; Usage = $usage; Purchases = $purchases; Other = $other; Total = $usage + $purchases + $other }
    }
    $bySubscription = foreach ($group in @($rows | Group-Object { "$($_.SubscriptionId)|$($_.Currency)" })) {
        $id = [string]$group.Group[0].SubscriptionId
        $sum = 0d; foreach ($row in $group.Group) { $sum += [decimal]$row.Cost }
        $latest = @($group.Group | ForEach-Object Month | Sort-Object)[-1]
        $latestSum = 0d; foreach ($row in @($group.Group | Where-Object Month -EQ $latest)) { $latestSum += [decimal]$row.Cost }
        $name = if ($id -and $SubscriptionNames -and $SubscriptionNames[$id]) { ConvertTo-ForecastSafeText ([string]$SubscriptionNames[$id]) 60 } elseif ($id) { $id } else { 'No subscription' }
        [pscustomobject]@{ Subscription = $name; SubscriptionId = $id; Currency = [string]$group.Group[0].Currency; Months = @($group.Group | ForEach-Object Month | Sort-Object -Unique).Count; Total = $sum; LatestMonth = $latest; LatestTotal = $latestSum }
    }
    $bySubscription = @($bySubscription | Sort-Object Currency, @{ Expression = { [decimal]$_.Total }; Descending = $true }, Subscription)
    $totals = foreach ($code in $currencies) { $sum = 0d; foreach ($row in @($rows | Where-Object { [string]$_.Currency -eq $code })) { $sum += [decimal]$row.Cost }; Format-ForecastAmount $sum $(if ($code) { $code } else { $Currency }) }
    $span = if ($months.Count) { " from $(Format-ForecastMonthRange -First $months[0] -Last $months[-1])" } else { '' }
    $amounts = if ($mixed) { "are in $($currencies.Count) billing currencies, totaled separately: $(@($totals) -join '; ')" } else { "total $(@($totals)[0])" }
    $note = "Marketplace charges in the scope $amounts$span. $(if ($Counted) { 'They''re counted in the forecast, because the Marketplace filter includes them.' } else { 'They''re not in the forecast; the Marketplace filter in 4 Assumptions leaves them out.' }) They're listed here for tracking commitments, such as an Azure consumption commitment; whether a Marketplace charge counts toward one depends on the offer."
    # A totals row would add currencies together, so it's left off when they're mixed.
    $footer = $null
    if (-not $mixed) {
        $footer = [ordered]@{ Month = 'Total' }
        foreach ($name in 'Usage', 'Purchases', 'Other', 'Total') { $sum = 0d; foreach ($row in @($monthly)) { $sum += [decimal]$row.$name }; $footer[$name] = $sum }
    }
    $currencyColumn = if ($mixed) { @(New-ForecastColumn -Name Currency -Width 6) } else { @() }
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append('<h2 id="marketplace-heading" tabindex="-1">Marketplace</h2>')
    [void]$sb.Append("<p class=""story-note"">$(ConvertTo-ForecastHtmlText $note)</p>")
    [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'table-marketplace-monthly' -Title 'Marketplace by month' -Rows @($monthly) -Footer $footer -Empty 'No Marketplace charges in the scope.' -Columns @(
                @(New-ForecastColumn -Name Month -Format month) + $currencyColumn + @((New-ForecastColumn -Name Usage -Format amount), (New-ForecastColumn -Name Purchases -Format amount),
                    (New-ForecastColumn -Name Other -Format amount), (New-ForecastColumn -Name Total -Format amount)))))
    [void]$sb.Append('<h2 id="marketplace-subscriptions-heading" tabindex="-1">Marketplace by subscription</h2>')
    [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'table-marketplace-subscriptions' -Title 'Marketplace by subscription' -Rows $bySubscription -Empty 'No Marketplace charges in the scope.' -Columns @(
                @((New-ForecastColumn -Name Subscription), (New-ForecastColumn -Name SubscriptionId -Label 'Subscription ID' -Width 18)) + $currencyColumn + @((New-ForecastColumn -Name Months -Label 'Months with charges' -Format number),
                    (New-ForecastColumn -Name Total -Format amount), (New-ForecastColumn -Name LatestMonth -Label 'Latest month' -Format month), (New-ForecastColumn -Name LatestTotal -Label 'Latest month total' -Format amount)))))
    return $sb.ToString()
}

function ConvertTo-ForecastReviewsHtml {
    param([Parameter(Mandatory)]$Readiness)
    $reviews = @($Readiness.Reviews | Where-Object { $_ })
    $pending = @($reviews | Where-Object { $_.Required -and $_.Decision -eq 'Pending' }).Count
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append('<h2 id="reviews-heading" tabindex="-1">Exceptions and reviews</h2>')
    if ($reviews.Count) { [void]$sb.Append("<p class=""story-note"">$(ConvertTo-ForecastHtmlText "$(Get-ForecastCountText -Count $pending -Singular 'required review is' -Plural 'required reviews are') pending, of $($reviews.Count). Decide them in FinOps Explorer under 5 Exceptions on the forecast's review page.")</p>") }
    [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'table-reviews' -Title 'Exceptions and reviews' -Rows $reviews -Empty 'Nothing needed a review.' -Columns @(
                (New-ForecastColumn -Name Category -Width 8), (New-ForecastColumn -Name Subject -Width 8), (New-ForecastColumn -Name Title), (New-ForecastColumn -Name Required -Format bool),
                (New-ForecastColumn -Name Decision -Format status -Tone), (New-ForecastColumn -Name Note), (New-ForecastColumn -Name Detail))))
    return $sb.ToString()
}

function ConvertTo-ForecastBacktestHtml {
    param([Parameter(Mandatory)]$Backtest)
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append('<h2 id="backtest-heading" tabindex="-1">Backtest</h2>')
    [void]$sb.Append("<p class=""story-note"">$(ConvertTo-ForecastHtmlText $Backtest.Note)</p>")
    if ($Backtest.Status -eq 'Completed') {
        [void]$sb.Append('<div class="driver-row">')
        [void]$sb.Append((ConvertTo-ForecastKpiHtml -Name 'Mean absolute error' -Value (Format-ForecastPercent $Backtest.MeanAbsoluteErrorRatio) -Plain 'How far forecasts made from earlier cutoffs were from the actual months, on average.'))
        [void]$sb.Append((ConvertTo-ForecastKpiHtml -Name 'Bias' -Value (Format-ForecastPercent $Backtest.MeanErrorRatio) -Plain 'The average signed error. Positive means the forecasts ran high.'))
        [void]$sb.Append((ConvertTo-ForecastKpiHtml -Name 'Inside the range' -Value (Format-ForecastPercent $Backtest.ObservedInRangeRatio 0) -Plain 'How often the actual month fell inside the sensitivity range. These are observed results, not a calibration.'))
        [void]$sb.Append('</div>')
        [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'table-backtest' -Title 'Backtest' -Rows $Backtest.Results -Columns @(
                    (New-ForecastColumn -Name Cutoff -Format month), (New-ForecastColumn -Name Month -Format month), (New-ForecastColumn -Name Horizon -Format number),
                    (New-ForecastColumn -Name Actual -Format amount), (New-ForecastColumn -Name ForecastLow -Label 'Low' -Format amount), (New-ForecastColumn -Name ForecastCentral -Label 'Central' -Format amount),
                    (New-ForecastColumn -Name ForecastHigh -Label 'High' -Format amount), (New-ForecastColumn -Name ErrorRatio -Label 'Error' -Format percent), (New-ForecastColumn -Name InRange -Label 'In range' -Format bool))))
    }
    return $sb.ToString()
}

function ConvertTo-ForecastReconciliationHtml {
    param([Parameter(Mandatory)]$Dataset)
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append('<h2 id="reconciliation-heading" tabindex="-1">Reconciliation</h2>')
    [void]$sb.Append('<p class="story-note">One row for each selected run and month. The raw total equals the included amount plus credits, every excluded amount, and the difference. Differences under 0.000001 are decimal rounding.</p>')
    [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'table-reconciliation' -Title 'Reconciliation' -Rows $Dataset.Reconciliation -Empty 'Manual inputs have no export runs to reconcile.' -Columns @(
                (New-ForecastColumn -Name Month -Format month), (New-ForecastColumn -Name Source -Width 12), (New-ForecastColumn -Name Final -Format bool), (New-ForecastColumn -Name Rows -Format number),
                (New-ForecastColumn -Name RawTotal -Label 'Raw total' -Format amount), (New-ForecastColumn -Name IncludedHeadline -Label 'Included' -Format amount),
                (New-ForecastColumn -Name Credits -Format amount), (New-ForecastColumn -Name ExcludedTax -Label 'Tax' -Format amount), (New-ForecastColumn -Name ExcludedMarketplace -Label 'Marketplace' -Format amount),
                (New-ForecastColumn -Name ExcludedUnattributed -Label 'No subscription' -Format amount), (New-ForecastColumn -Name ExcludedScope -Label 'Out of scope' -Format amount),
                (New-ForecastColumn -Name ExcludedBoundary -Label 'Boundary' -Format amount), (New-ForecastColumn -Name ExcludedOverlap -Label 'Overlap' -Format amount),
                (New-ForecastColumn -Name ExcludedOutsideRange -Label 'Outside run dates' -Format amount), (New-ForecastColumn -Name Difference -Format amount), (New-ForecastColumn -Name Note))))
    return $sb.ToString()
}

function ConvertTo-ForecastDisclosureHtml {
    # Turns the disclosure's text, with capitalized headings and "- " and
    # "  - " bullets, into headings and nested lists.
    param([AllowEmptyCollection()][string[]]$Lines)
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append('<h2 id="method-heading" tabindex="-1">Method and disclosure</h2>')
    if (-not @($Lines).Count) { [void]$sb.Append('<p class="no-data">The method disclosure wasn''t included.</p>'); return $sb.ToString() }
    [void]$sb.Append('<div class="disclosure">')
    $depth = 0
    foreach ($line in @($Lines)) {
        $text = [string]$line
        if ($text -cmatch '^[A-Z][A-Z0-9 ,()/-]*$') {
            while ($depth -gt 0) { [void]$sb.Append('</li></ul>'); $depth-- }
            [void]$sb.Append("<h3>$(ConvertTo-ForecastHtmlText ($text.Substring(0, 1) + $text.Substring(1).ToLowerInvariant()))</h3>")
        }
        elseif ($text -match '^(?<indent> *)- (?<body>.*)$') {
            $level = if ($Matches.indent.Length -ge 2) { 2 } else { 1 }
            $body = $Matches.body
            if ($depth -eq 0) { [void]$sb.Append('<ul><li>'); $depth = 1 }
            elseif ($level -gt $depth) { [void]$sb.Append('<ul><li>'); $depth = $level }
            elseif ($level -lt $depth) { [void]$sb.Append('</li></ul></li><li>'); $depth = $level }
            else { [void]$sb.Append('</li><li>') }
            if ($level -gt $depth) { [void]$sb.Append('<ul><li>'); $depth = $level }
            [void]$sb.Append((ConvertTo-ForecastHtmlText $body))
        }
        elseif ($text.Trim()) {
            while ($depth -gt 0) { [void]$sb.Append('</li></ul>'); $depth-- }
            [void]$sb.Append("<p>$(ConvertTo-ForecastHtmlText $text)</p>")
        }
        else { while ($depth -gt 0) { [void]$sb.Append('</li></ul>'); $depth-- } }
    }
    while ($depth -gt 0) { [void]$sb.Append('</li></ul>'); $depth-- }
    [void]$sb.Append('</div>')
    return $sb.ToString()
}

# -- Page ------------------------------------------------------------------
function Get-ForecastHtmlStyle {
    # The scan report's palette, masthead, cards, tabs, and grid, from
    # Invoke-FinOpsMultitool.ps1, then the forecast's charts and statements.
    return @'
:root {
  --energy-blue: #0000B3; --blue: #0078D4; --navy: #0D0061; --deep-blue: #000085;
  --indigo: #5D52EC; --turquoise: #00BBC3; --mint: #CFF3E8; --lavender: #AAC0FC;
  --light-gray: #D9D9D6; --surface: #F7F7F5; --ink: #1A1A1A; --muted: #5A5A5A;
  --danger: #C42B1C; --warning: #8A5300; --success: #0F7B0F;
}
* { box-sizing: border-box; }
body { font-family: 'Segoe Sans Display', 'Segoe UI Variable Display', 'Segoe UI', system-ui, -apple-system, sans-serif; background: #FFFFFF; color: var(--ink); margin: 0; padding: 0 0 48px 0; }
.masthead { background: var(--navy); color: #FFFFFF; padding: 28px 40px 24px 40px; }
.masthead .eyebrow { font-size: 11px; font-weight: 600; text-transform: uppercase; color: var(--lavender); margin-bottom: 6px; }
.masthead h1 { font-size: 30px; font-weight: 300; margin: 0 0 10px 0; color: #FFFFFF; }
.masthead .meta { color: #C5CBE8; font-size: 13px; margin: 0; }
.wrap { padding: 0 40px; }
h2 { color: var(--energy-blue); font-size: 19px; font-weight: 600; margin: 30px 0 4px 0; padding-bottom: 8px; border-bottom: 1px solid var(--light-gray); }
h3 { color: var(--navy); font-size: 12px; font-weight: 600; text-transform: uppercase; margin: 22px 0 4px 0; }
h2[id] { scroll-margin-top: 85px; }
h2[tabindex]:focus { outline: none; }
.summary-grid { display: flex; flex-wrap: wrap; gap: 12px; margin: 24px 0 4px 0; }
.summary-card { background: var(--surface); border: 1px solid var(--light-gray); border-top: 3px solid var(--blue); border-radius: 6px; padding: 12px 18px; min-width: 170px; }
.summary-card .label { color: var(--muted); font-size: 11px; font-weight: 600; text-transform: uppercase; }
.summary-card .value { font-size: 24px; font-weight: 600; color: var(--navy); margin-top: 2px; font-variant-numeric: tabular-nums; }
.summary-card .unit { font-size: 14px; color: var(--muted); }
.summary-card .sub { font-size: 12px; color: var(--muted); margin-top: 2px; max-width: 32ch; }
.summary-card.status.Ready { border-top-color: var(--success); }
.summary-card.status.Ready .value { color: var(--success); }
.summary-card.status.Preliminary { border-top-color: var(--warning); }
.summary-card.status.Preliminary .value { color: var(--warning); }
.summary-card.status.NotReady { border-top-color: var(--danger); }
.summary-card.status.NotReady .value { color: var(--danger); }
.tabs { display: flex; flex-wrap: wrap; gap: 2px; border-bottom: 2px solid var(--light-gray); margin: 22px 0 0 0; position: sticky; top: 0; background: #FFFFFF; z-index: 10; }
.tab { font: inherit; font-size: 11.5px; font-weight: 600; text-transform: uppercase; color: var(--muted); background: none; border: 0; border-bottom: 3px solid transparent; margin-bottom: -2px; padding: 11px 9px; cursor: pointer; }
.tab:hover { color: var(--energy-blue); background: var(--surface); }
.tab.active { color: var(--energy-blue); border-bottom-color: var(--energy-blue); }
.tab:focus-visible { outline: 2px solid var(--blue); outline-offset: -2px; }
.tabpane { display: none; }
.tabpane.active { display: block; }
.tabpane:focus-visible { outline: 2px solid var(--blue); outline-offset: 6px; }
table { border-collapse: collapse; width: 100%; margin: 12px 0 22px 0; font-size: 13px; }
th { background: var(--surface); color: var(--navy); text-align: left; padding: 9px 12px; border-bottom: 2px solid var(--light-gray); font-weight: 600; font-size: 11px; text-transform: uppercase; }
td { padding: 7px 12px; border-bottom: 1px solid #ECECEA; vertical-align: top; overflow-wrap: anywhere; }
tr:hover td { background: var(--surface); }
.severity-red { color: var(--danger); font-weight: 600; }
.severity-yellow { color: var(--warning); font-weight: 600; }
.severity-green { color: var(--success); font-weight: 600; }
.guidance { background: var(--surface); border-left: 4px solid var(--light-gray); padding: 11px 16px; margin: 8px 0 16px 0; border-radius: 0 4px 4px 0; font-size: 13px; }
.guidance.red { border-left-color: var(--danger); }
.guidance.yellow { border-left-color: var(--warning); }
.guidance.green { border-left-color: var(--success); }
.story-intro { font-size: 14px; color: var(--ink); max-width: 90ch; margin: 20px 0 12px 0; line-height: 1.5; }
.story-note { color: var(--muted); font-size: 13px; margin: 8px 0 12px; max-width: 100ch; line-height: 1.5; }
.table-scroll { width: 100%; max-width: 100%; overflow-x: auto; }
.report-table { table-layout: fixed; }
.report-table td { overflow-wrap: break-word; word-break: normal; }
.report-table th { overflow-wrap: normal; word-break: normal; }
.numeric-cell { text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; }
.report-table-controls { display: flex; align-items: end; flex-wrap: wrap; gap: 10px 16px; margin: 16px 0 0; font-size: 13px; }
.report-table-controls label { display: grid; gap: 5px; flex: 1 1 16rem; max-width: 28rem; font-weight: 600; }
.report-table-controls input { width: 100%; min-height: 36px; padding: 6px 9px; border: 1px solid #767676; border-radius: 4px; font: inherit; }
.report-table-controls output { min-width: 12rem; padding: 9px 0; font-variant-numeric: tabular-nums; }
.report-table-controls button { min-height: 36px; padding: 6px 12px; border: 1px solid #767676; border-radius: 4px; color: var(--energy-blue); background: #FFFFFF; font: inherit; cursor: pointer; }
.report-table-controls button:disabled { color: var(--muted); opacity: 0.5; cursor: default; }
.report-table tbody tr[hidden] { display: none; }
.report-grid { margin: 14px 0 24px; border: 1px solid #BDBDBD; border-radius: 6px; background: #FFFFFF; overflow: hidden; }
.report-grid .report-table-controls { margin: 0; padding: 10px 12px; border-bottom: 1px solid #D9D9D6; background: #F7F7F5; gap: 8px 12px; }
.report-grid .report-table-controls label { flex-basis: 13rem; max-width: 24rem; min-width: 0; }
.report-grid .report-table-controls output { min-width: 8rem; }
.report-grid .table-scroll { max-height: 36rem; overflow: auto; overscroll-behavior: contain; }
.report-grid table { margin: 0; }
.report-grid th { position: sticky; top: 0; z-index: 2; background: #F2F2F2; border-right: 1px solid #D9D9D6; text-transform: none; font-size: 12px; }
.report-grid td { border-right: 1px solid #ECECEA; line-height: 1.45; }
.report-grid tbody tr:nth-child(even) td { background: #FAFAFA; }
.report-grid tbody tr:hover td { background: #EEF6FC; }
.report-grid .row-number { width: 3rem; min-width: 3rem; text-align: right; color: var(--muted); font-variant-numeric: tabular-nums; background: #F2F2F2; }
.report-grid tfoot td { position: sticky; bottom: 0; z-index: 1; background: #F2F2F2; color: var(--navy); font-weight: 600; border-top: 2px solid var(--light-gray); }
.column-sort { font: inherit; font-weight: 600; color: inherit; background: transparent; border: 0; padding: 0 12px 0 0; width: 100%; text-align: inherit; cursor: pointer; overflow-wrap: anywhere; }
.column-sort span { margin-left: 5px; color: var(--blue); }
.column-resizer { position: absolute; right: 0; top: 0; bottom: 0; width: 8px; cursor: col-resize; touch-action: none; }
.column-resizer:hover, .column-resizer:focus-visible { background: #0078D440; outline: 2px solid var(--blue); outline-offset: -2px; }
.grid-dialog { width: calc(100vw - 32px); height: calc(100vh - 32px); max-width: none; max-height: none; padding: 0; border: 1px solid #767676; border-radius: 6px; background: #FFFFFF; color: var(--ink); }
.grid-dialog::backdrop { background: #00000066; }
.grid-dialog .report-grid { display: flex; flex-direction: column; width: 100%; height: 100%; margin: 0; border: 0; }
.grid-dialog .table-scroll { flex: 1; max-height: none; }
.report-jump { color: var(--blue); text-underline-offset: 3px; }
.kpi { border-left: 4px solid var(--blue); background: var(--surface); border-radius: 0 4px 4px 0; padding: 10px 16px; margin: 0 0 10px 0; max-width: 78ch; }
.kpi-name { font-size: 11px; font-weight: 600; text-transform: uppercase; color: var(--muted); }
.kpi-value { font-size: 17px; font-weight: 600; color: var(--navy); margin: 2px 0; font-variant-numeric: tabular-nums; }
.kpi-plain { font-size: 13px; color: var(--muted); line-height: 1.45; }
.no-data { color: var(--muted); font-style: italic; padding: 8px 0; }
.footer { color: var(--muted); font-size: 12px; margin-top: 40px; border-top: 1px solid var(--light-gray); padding-top: 14px; }
.footer a { color: var(--blue); text-decoration: none; }
.status-callout { margin: 4px 0 8px; }
.status-callout p { margin: 0 0 6px; max-width: 100ch; line-height: 1.5; }
.status-callout .callout-heading { font-weight: 600; margin: 10px 0 2px; }
.status-callout ul { margin: 0; padding-left: 20px; }
.status-callout li { margin: 4px 0; line-height: 1.45; max-width: 120ch; overflow-wrap: anywhere; }
.chart-figure { margin: 10px 0 6px; max-width: 980px; }
.chart { display: block; width: 100%; height: auto; }
.chart text { font-family: inherit; font-size: 12px; fill: var(--muted); }
.chart .xlabel { fill: var(--ink); }
.chart .grid line { stroke: #ECECEA; stroke-width: 1; }
.chart .zero { stroke: #8A8A8A; stroke-width: 1; }
.chart .seg.actual, .chart .seg.runrate { fill: var(--navy); }
.chart .seg.forecast, .chart .seg.retained { fill: var(--blue); }
.chart .seg.scheduled { fill: var(--indigo); }
.chart .seg.provisional { stroke: var(--navy); stroke-width: 1; }
.chart .seg.excluded { fill: #8A8A8A; }
.chart .seg.pending { fill: var(--warning); }
.chart .col:hover .seg { opacity: 0.8; }
.chart .whisker { stroke: var(--ink); stroke-width: 1.5; fill: none; }
.chart .ref { stroke: var(--energy-blue); stroke-width: 1.5; stroke-dasharray: 6 4; }
.chart .ref-label { fill: var(--energy-blue); font-weight: 600; }
.chart .band { fill: var(--lavender); fill-opacity: 0.35; }
.chart .band-label { fill: var(--navy); }
.chart .ref-label, .chart .band-label, .chart .empty-label { paint-order: stroke; stroke: #FFFFFF; stroke-width: 4px; stroke-linejoin: round; }
.chart .region-line { stroke: var(--light-gray); stroke-width: 2; }
.chart .region-label { fill: var(--navy); font-weight: 600; }
.chart-legend { list-style: none; display: flex; flex-wrap: wrap; gap: 6px 20px; padding: 0; margin: 4px 0 0; font-size: 12px; color: var(--muted); }
.chart-legend .key { display: inline-block; width: 12px; height: 12px; margin-right: 6px; vertical-align: -1px; border-radius: 2px; }
.key-actual, .key-runrate { background: var(--navy); }
.key-forecast, .key-retained { background: var(--blue); }
.key-scheduled { background: var(--indigo); }
.key-provisional { border: 1px solid var(--navy); background: repeating-linear-gradient(45deg, var(--navy) 0 2px, #FFFFFF 2px 4px); }
.key-excluded { background: #8A8A8A; }
.key-pending { background: var(--warning); }
.chart-legend .key-range { width: 2px; height: 14px; margin: 0 11px 0 5px; background: var(--ink); border-radius: 0; vertical-align: -2px; }
.chart-legend .key-ref { width: 18px; height: 0; border-top: 2px dashed var(--energy-blue); border-radius: 0; vertical-align: 3px; }
.key-band { background: var(--lavender); opacity: 0.7; }
.overview-grid { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 0 40px; align-items: start; }
.driver-list .kpi { max-width: none; }
.driver-row { display: grid; grid-template-columns: repeat(auto-fit, minmax(16rem, 1fr)); gap: 10px; margin: 12px 0; }
.driver-row .kpi { margin: 0; max-width: none; }
.statement { margin: 12px 0 10px; }
.statement th, .statement td { padding: 7px 12px; }
.statement tbody th { background: none; color: var(--ink); font-size: 13px; font-weight: 400; text-transform: none; border-bottom: 1px solid #ECECEA; }
.statement tfoot th, .statement tfoot td { background: none; color: var(--navy); font-size: 13px; font-weight: 600; text-transform: none; border-top: 2px solid var(--navy); border-bottom: 0; }
.statement .key { display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 8px; }
.quarters { min-width: 52rem; max-width: 76rem; }
.composition { display: flex; height: 14px; border-radius: 3px; overflow: hidden; background: var(--light-gray); margin: 4px 0 8px; }
.composition span { display: block; height: 100%; }
.composition .actual { background: var(--navy); }
.composition .forecast { background: var(--blue); }
.composition .scheduled { background: var(--indigo); }
.disclosure ul { margin: 6px 0 0; padding-left: 20px; max-width: 110ch; font-size: 13px; line-height: 1.55; }
.disclosure li { margin: 4px 0; }
.disclosure p { font-size: 13px; max-width: 110ch; }
@media (max-width: 900px) { .overview-grid { grid-template-columns: 1fr; } }
@media (max-width: 640px) {
  .wrap { padding: 0 16px; }
  .masthead { padding: 20px 16px; }
  .masthead h1 { font-size: 25px; }
  .summary-card { min-width: 0; flex: 1 1 125px; padding: 10px 12px; }
  .tabs { position: static; }
  .tab { padding: 10px; }
  th, td { padding: 7px 8px; }
}
@media print {
  .tabs { display: none; }
  .tabpane { display: block !important; }
  .masthead { background: #FFFFFF; color: var(--ink); padding: 0 0 12px 0; border-bottom: 2px solid var(--energy-blue); }
  .masthead h1, .masthead .meta, .masthead .eyebrow { color: var(--ink); }
  .wrap { padding: 0; }
  body { padding: 16px; }
  tr:hover td { background: none; }
  .table-scroll { overflow: visible; }
  .report-grid { overflow: visible; break-inside: auto; }
  .report-grid .report-table-controls, .column-resizer { display: none; }
  .report-grid .table-scroll { max-height: none; overflow: visible; }
  .report-grid th, .report-grid tfoot td { position: static; }
  .report-grid tr[data-grid-match="true"] { display: table-row !important; }
  .chart-figure, .overview-grid > div, .kpi { break-inside: avoid; }
  .chart, .chart-legend .key, .statement .key, .composition span, .summary-card { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
}
'@
}

function Get-ForecastHtmlScript {
    # The scan report's grid and tabs, from Invoke-FinOpsMultitool.ps1, with
    # totals rows, sort keys for months, and focus kept on a usable page button.
    return @'
(function () {
    Array.prototype.forEach.call(document.querySelectorAll('table.report-table'), function (table, tableIndex) {
        if (!table.tBodies.length || !table.tHead) { return; }
        if (!table.id) { table.id = 'report-grid-' + tableIndex; }
        var rows = Array.prototype.slice.call(table.tBodies[0].rows);
        var headers = Array.prototype.slice.call(table.tHead.rows[0].cells);
        var scroller = table.parentElement;
        var title = table.getAttribute('data-title') || 'Results';
        table.setAttribute('aria-label', title);
        var frame = document.createElement('div');
        frame.className = 'report-grid';
        scroller.parentNode.insertBefore(frame, scroller);
        var controls = document.createElement('div');
        controls.className = 'report-table-controls';
        var label = document.createElement('label');
        label.textContent = 'Filter ' + title;
        var search = document.createElement('input');
        search.type = 'search';
        search.setAttribute('aria-controls', table.id);
        label.appendChild(search);
        controls.appendChild(label);
        var output = document.createElement('output');
        output.setAttribute('aria-live', 'polite');
        controls.appendChild(output);
        var previous = document.createElement('button');
        var next = document.createElement('button');
        [[previous, 'Previous'], [next, 'Next']].forEach(function (pair) {
            pair[0].type = 'button';
            pair[0].textContent = pair[1];
            pair[0].setAttribute('aria-label', pair[1] + ' page of ' + title);
            controls.appendChild(pair[0]);
        });
        frame.appendChild(controls);
        frame.appendChild(scroller);
        scroller.tabIndex = 0;
        scroller.setAttribute('role', 'region');
        scroller.setAttribute('aria-label', title + ' table');
        var colgroup = table.querySelector('colgroup');
        if (!colgroup) {
            colgroup = document.createElement('colgroup');
            headers.forEach(function () { colgroup.appendChild(document.createElement('col')); });
            table.insertBefore(colgroup, table.firstChild);
        }
        var columns = Array.prototype.slice.call(colgroup.children);
        var numberColumn = document.createElement('col');
        numberColumn.style.width = '3rem';
        colgroup.insertBefore(numberColumn, colgroup.firstChild);
        var numberHeader = document.createElement('th');
        numberHeader.scope = 'col';
        numberHeader.className = 'row-number';
        numberHeader.textContent = '#';
        numberHeader.setAttribute('aria-label', 'Row number');
        table.tHead.rows[0].insertBefore(numberHeader, table.tHead.rows[0].firstChild);
        rows.forEach(function (row, index) {
            row.setAttribute('data-grid-search', row.textContent.toLowerCase());
            row.setAttribute('data-grid-order', String(index));
            var numberCell = document.createElement('td');
            numberCell.className = 'row-number';
            numberCell.textContent = String(index + 1);
            row.insertBefore(numberCell, row.firstChild);
        });
        if (table.tFoot) {
            Array.prototype.forEach.call(table.tFoot.rows, function (row) {
                var blank = document.createElement('td');
                blank.className = 'row-number';
                row.insertBefore(blank, row.firstChild);
            });
        }
        var pageIndex = 0;
        var pageSize = parseInt(table.getAttribute('data-page-size'), 10) || 25;
        var sortColumn = -1;
        var sortDirection = 1;
        var collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });
        function parseGridNumber(text) {
            var accounting = /^\(.*\)$/.test(text);
            var value = accounting ? text.slice(1, -1).trim() : text;
            var match = value.match(/^([-+])?\s*([A-Z]{3}|\$)?\s*([-+])?(\d[\d,]*(?:\.\d+)?(?:[eE][-+]?\d+)?)(%|\/yr)?$/);
            if (!match || (match[1] && match[3]) || (accounting && (match[1] || match[3]))) { return null; }
            var amount = Number(match[4].replace(/,/g, ''));
            if (!Number.isFinite(amount)) { return null; }
            if (accounting || match[1] === '-' || match[3] === '-') { amount = -amount; }
            return { value: amount, currency: match[2] || '', unit: match[5] || '' };
        }
        function sortText(row) {
            var cell = row.cells[sortColumn + 1];
            return (cell.getAttribute('data-sort') || cell.textContent).trim();
        }
        function compareCells(first, second) {
            var firstText = sortText(first);
            var secondText = sortText(second);
            var empty = /^(?:Undefined|n\/a)?$/i;
            if (empty.test(firstText) !== empty.test(secondText)) { return empty.test(firstText) ? 1 : -1; }
            var firstNumber = parseGridNumber(firstText);
            var secondNumber = parseGridNumber(secondText);
            var comparison = firstNumber && secondNumber && firstNumber.currency === secondNumber.currency && firstNumber.unit === secondNumber.unit
                ? firstNumber.value - secondNumber.value
                : collator.compare(firstText, secondText);
            return comparison ? comparison * sortDirection : Number(first.getAttribute('data-grid-order')) - Number(second.getAttribute('data-grid-order'));
        }
        function updateRows() {
            var focused = document.activeElement;
            var query = search.value.trim().toLowerCase();
            var matches = rows.filter(function (row) {
                var matched = !query || row.getAttribute('data-grid-search').indexOf(query) !== -1;
                row.setAttribute('data-grid-match', String(matched));
                return matched;
            });
            if (sortColumn >= 0) { matches.sort(compareCells); }
            var lastPage = Math.max(0, Math.ceil(matches.length / pageSize) - 1);
            pageIndex = Math.min(pageIndex, lastPage);
            rows.forEach(function (row) { row.hidden = true; });
            var startIndex = pageIndex * pageSize;
            matches.forEach(function (row) { table.tBodies[0].appendChild(row); });
            matches.slice(startIndex, startIndex + pageSize).forEach(function (row) { row.hidden = false; });
            output.textContent = matches.length ? (startIndex + 1) + '-' + Math.min(startIndex + pageSize, matches.length) + ' of ' + matches.length + (query ? ' matching rows' : ' rows') : 'No matching rows';
            previous.disabled = pageIndex === 0;
            next.disabled = pageIndex >= lastPage;
            // A page button that just became disabled hands focus to the other one.
            if (focused === previous && previous.disabled && !next.disabled) { next.focus(); }
            else if (focused === next && next.disabled && !previous.disabled) { previous.focus(); }
        }
        function resizeColumn(index, width) {
            var allColumns = Array.prototype.slice.call(colgroup.children);
            var allHeaders = Array.prototype.slice.call(table.tHead.rows[0].cells);
            allColumns.forEach(function (column, columnIndex) { column.style.width = allHeaders[columnIndex].getBoundingClientRect().width + 'px'; });
            columns[index].style.width = Math.max(80, Math.min(1200, width)) + 'px';
            table.style.minWidth = '0';
            table.style.width = allColumns.reduce(function (sum, column) { return sum + parseFloat(column.style.width); }, 0) + 'px';
            headers[index].querySelector('.column-resizer').setAttribute('aria-valuenow', String(Math.round(parseFloat(columns[index].style.width))));
        }
        headers.forEach(function (header, index) {
            var text = header.textContent;
            header.textContent = '';
            header.setAttribute('aria-sort', 'none');
            var sort = document.createElement('button');
            sort.type = 'button';
            sort.className = 'column-sort';
            sort.textContent = text;
            sort.title = 'Sort by ' + text;
            var direction = document.createElement('span');
            direction.setAttribute('aria-hidden', 'true');
            sort.appendChild(direction);
            sort.addEventListener('click', function () {
                sortDirection = sortColumn === index ? -sortDirection : 1;
                sortColumn = index;
                headers.forEach(function (item) { item.setAttribute('aria-sort', 'none'); item.querySelector('.column-sort span').textContent = ''; });
                header.setAttribute('aria-sort', sortDirection === 1 ? 'ascending' : 'descending');
                direction.textContent = sortDirection === 1 ? '\u2191' : '\u2193';
                pageIndex = 0;
                updateRows();
            });
            header.appendChild(sort);
            var resizer = document.createElement('span');
            resizer.className = 'column-resizer';
            resizer.tabIndex = 0;
            resizer.setAttribute('role', 'separator');
            resizer.setAttribute('aria-orientation', 'vertical');
            resizer.setAttribute('aria-label', 'Resize ' + text + ' column');
            resizer.setAttribute('aria-valuemin', '80');
            resizer.setAttribute('aria-valuemax', '1200');
            resizer.title = 'Resize ' + text + ' column';
            var drag = null;
            resizer.addEventListener('pointerdown', function (event) { event.preventDefault(); drag = { pointer: event.pointerId, start: event.clientX, width: header.getBoundingClientRect().width }; resizer.setPointerCapture(event.pointerId); });
            resizer.addEventListener('pointermove', function (event) { if (drag && drag.pointer === event.pointerId) { resizeColumn(index, drag.width + event.clientX - drag.start); } });
            resizer.addEventListener('pointerup', function () { drag = null; });
            resizer.addEventListener('pointercancel', function () { drag = null; });
            resizer.addEventListener('keydown', function (event) {
                if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') { return; }
                event.preventDefault();
                resizeColumn(index, header.getBoundingClientRect().width + (event.key === 'ArrowRight' ? 16 : -16));
            });
            header.appendChild(resizer);
        });
        var expand = document.createElement('button');
        expand.type = 'button';
        expand.className = 'grid-expand';
        expand.textContent = 'Expand';
        expand.setAttribute('aria-label', 'Expand ' + title + ' table');
        controls.appendChild(expand);
        var dialog = document.createElement('dialog');
        dialog.className = 'grid-dialog';
        dialog.setAttribute('aria-label', title + ' table');
        document.body.appendChild(dialog);
        var placeholder = null;
        function restoreGrid() {
            if (placeholder) { placeholder.parentNode.replaceChild(frame, placeholder); placeholder = null; }
            expand.textContent = 'Expand';
            expand.setAttribute('aria-label', 'Expand ' + title + ' table');
            expand.focus({ preventScroll: true });
        }
        function closeGrid() { if (dialog.open) { dialog.close(); } restoreGrid(); }
        expand.addEventListener('click', function () {
            if (dialog.open) { closeGrid(); return; }
            placeholder = document.createComment('Expanded table');
            frame.parentNode.replaceChild(placeholder, frame);
            dialog.appendChild(frame);
            expand.textContent = 'Close';
            expand.setAttribute('aria-label', 'Close expanded table');
            dialog.showModal();
        });
        dialog.addEventListener('close', function () { if (!dialog.open) { restoreGrid(); } });
        dialog.addEventListener('cancel', function (event) { event.preventDefault(); closeGrid(); });
        window.addEventListener('beforeprint', function () { if (dialog.open) { closeGrid(); } });
        search.addEventListener('input', function () { pageIndex = 0; updateRows(); });
        previous.addEventListener('click', function () { pageIndex--; updateRows(); });
        next.addEventListener('click', function () { pageIndex++; updateRows(); });
        updateRows();
    });
    var tabs = Array.prototype.slice.call(document.querySelectorAll('.tab'));
    var panes = Array.prototype.slice.call(document.querySelectorAll('.tabpane'));
    function activate(target) {
        tabs.forEach(function (tab) {
            var active = tab.getAttribute('data-target') === target;
            tab.classList.toggle('active', active);
            tab.setAttribute('aria-selected', String(active));
            tab.tabIndex = active ? 0 : -1;
        });
        panes.forEach(function (pane) { pane.classList.toggle('active', pane.id === target); });
    }
    tabs.forEach(function (tab) {
        tab.addEventListener('click', function () { activate(tab.getAttribute('data-target')); });
        tab.addEventListener('keydown', function (event) {
            var index = tabs.indexOf(tab);
            if (event.key === 'ArrowRight') { index = (index + 1) % tabs.length; }
            else if (event.key === 'ArrowLeft') { index = (index + tabs.length - 1) % tabs.length; }
            else if (event.key === 'Home') { index = 0; }
            else if (event.key === 'End') { index = tabs.length - 1; }
            else { return; }
            event.preventDefault();
            activate(tabs[index].getAttribute('data-target'));
            tabs[index].focus();
        });
    });
    Array.prototype.forEach.call(document.querySelectorAll('.report-jump'), function (link) {
        link.addEventListener('click', function (event) {
            var heading = document.getElementById(link.getAttribute('href').slice(1));
            if (!heading) { return; }
            event.preventDefault();
            activate(link.getAttribute('data-target'));
            heading.focus();
            heading.scrollIntoView({ block: 'start' });
        });
    });
    var start = window.location.hash ? document.getElementById(window.location.hash.slice(1)) : null;
    if (start && start.classList.contains('tabpane')) { activate(start.id); }
})();
'@
}

function ConvertTo-ForecastSummaryCardsHtml {
    param([Parameter(Mandatory)]$Model, [Parameter(Mandatory)]$Readiness, [string]$Currency)
    $projection = $Model.Projection
    $growth = $Model.Growth
    $unit = if ($Currency) { " <span class=""unit"">$(ConvertTo-ForecastHtmlText $Currency)</span>" } else { '' }
    $card = {
        param($Label, $Value, $Sub, $Class = '')
        $subHtml = if ($Sub) { '<div class="sub">' + (ConvertTo-ForecastHtmlText $Sub) + '</div>' } else { '' }
        "<div class=""summary-card$Class""><div class=""label"">$(ConvertTo-ForecastHtmlText $Label)</div><div class=""value"">$Value</div>$subHtml</div>"
    }
    $total = [decimal]$projection.TotalCentral
    $share = if ($total -gt 0) { "$(Format-ForecastPercent ([decimal]$projection.ActualToDate / $total)) of the central estimate" } else { '' }
    $range = if ($null -ne $growth.Low) { "Range $(Format-ForecastPercent $growth.Low 2) to $(Format-ForecastPercent $growth.High 2)" } else { '' }
    $status = [string]$Readiness.Status
    $statusText = if ($status -eq 'NotReady') { 'Not ready' } else { $status }
    $labels = Get-ForecastDisplayLabels -Readiness $Readiness
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append('<div class="summary-grid">')
    [void]$sb.Append((& $card "$($projection.FiscalYear.Label) central estimate" "$(ConvertTo-ForecastHtmlText (Format-ForecastAmount $projection.TotalCentral))$unit" ''))
    [void]$sb.Append((& $card 'Sensitivity range (not a confidence interval)' "$(ConvertTo-ForecastHtmlText (Format-ForecastAmount $projection.TotalLow)) to $(ConvertTo-ForecastHtmlText (Format-ForecastAmount $projection.TotalHigh))" ''))
    [void]$sb.Append((& $card 'Actuals to date' "$(ConvertTo-ForecastHtmlText (Format-ForecastAmount $projection.ActualToDate))$unit" $share))
    [void]$sb.Append((& $card 'Growth a month' (ConvertTo-ForecastHtmlText (Format-ForecastPercent $growth.Central 2)) $range))
    [void]$sb.Append((& $card 'Status' (ConvertTo-ForecastHtmlText $statusText) ($labels -join ', ') " status $(ConvertTo-ForecastHtmlText $status)"))
    [void]$sb.Append('</div>')
    return $sb.ToString()
}

function ConvertTo-ForecastHtml {
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)]$Dataset,
        [Parameter(Mandatory)]$Readiness,
        $Workloads,
        $Backtest,
        [string[]]$Disclosure,
        [string]$ScopeLabel,
        $Settings,
        [string]$VintageName,
        [datetime]$Generated = [datetime]::UtcNow
    )
    $inv = $script:ForecastInvariant
    $currency = [string]$Dataset.Currency
    $fy = $Model.Projection.FiscalYear
    $panes = [Collections.Generic.List[object]]::new()
    $panes.Add([pscustomobject]@{ Id = 'overview'; Label = 'Overview'; Html = (ConvertTo-ForecastOverviewHtml -Model $Model -Dataset $Dataset -Readiness $Readiness -Workloads $Workloads -Settings $Settings -ScopeLabel $ScopeLabel) })
    $panes.Add([pscustomobject]@{ Id = 'fiscal-year'; Label = 'Fiscal year by month'; Html = (ConvertTo-ForecastFiscalYearHtml -Projection $Model.Projection) })
    $panes.Add([pscustomobject]@{ Id = 'history'; Label = 'Monthly history'; Html = (ConvertTo-ForecastHistoryHtml -Model $Model -Currency $currency) })
    $panes.Add([pscustomobject]@{ Id = 'comparisons'; Label = 'Adjacent-month comparisons'; Html = (ConvertTo-ForecastComparisonsHtml -Model $Model) })
    if ($Workloads) { $panes.Add([pscustomobject]@{ Id = 'workloads'; Label = 'Workloads'; Html = (ConvertTo-ForecastWorkloadsHtml -Workloads $Workloads -Currency $currency) }) }
    $marketRows = @($Dataset.Marketplace | Where-Object { $_ })
    if ($marketRows.Count -and (-not $Settings -or (ConvertTo-ForecastSettingSwitch -Value $Settings.filters.showMarketplace -Default $true))) {
        $panes.Add([pscustomobject]@{ Id = 'marketplace'; Label = 'Marketplace'; Html = (ConvertTo-ForecastMarketplaceHtml -Rows $marketRows -SubscriptionNames $Dataset.SubscriptionNames -Counted ([bool]($Settings -and $Settings.filters.includeMarketplace)) -Currency $currency) })
    }
    $panes.Add([pscustomobject]@{ Id = 'checks'; Label = 'Checks'; Html = (ConvertTo-ForecastChecksHtml -Readiness $Readiness -ReadStatus @($Dataset.ReadStatus | Where-Object { $_ })) })
    $panes.Add([pscustomobject]@{ Id = 'reviews'; Label = 'Exceptions and reviews'; Html = (ConvertTo-ForecastReviewsHtml -Readiness $Readiness) })
    if ($Backtest) { $panes.Add([pscustomobject]@{ Id = 'backtest'; Label = 'Backtest'; Html = (ConvertTo-ForecastBacktestHtml -Backtest $Backtest) }) }
    $panes.Add([pscustomobject]@{ Id = 'reconciliation'; Label = 'Reconciliation'; Html = (ConvertTo-ForecastReconciliationHtml -Dataset $Dataset) })
    $panes.Add([pscustomobject]@{ Id = 'method'; Label = 'Method and disclosure'; Html = (ConvertTo-ForecastDisclosureHtml -Lines $Disclosure) })

    $meta = [Collections.Generic.List[string]]::new()
    if (Get-Command -Name Get-VersionNumber -ErrorAction SilentlyContinue) { $meta.Add("Version: $(ConvertTo-ForecastHtmlText "v$(Get-VersionNumber)")") }
    $meta.Add("Generated: $(ConvertTo-ForecastHtmlText ($Generated.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'", $inv)))")
    if ($ScopeLabel) { $meta.Add("Scope: $(ConvertTo-ForecastHtmlText $ScopeLabel)") }
    $source = Get-ForecastHtmlSourceText -Settings $Settings -Dataset $Dataset
    if ($source) { $meta.Add("Cost data: $(ConvertTo-ForecastHtmlText $source)") }
    $meta.Add("As of: $(ConvertTo-ForecastHtmlText (([datetime]$Model.AsOf).ToString('yyyy-MM-dd', $inv)))")
    if ($VintageName) { $meta.Add("Vintage: $(ConvertTo-ForecastHtmlText $VintageName)") }

    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append("<!DOCTYPE html>`n<html lang=""en""><head><meta charset=""utf-8"">`n")
    [void]$sb.Append('<meta http-equiv="Content-Security-Policy" content="default-src ''none''; style-src ''unsafe-inline''; script-src ''unsafe-inline''">' + "`n")
    [void]$sb.Append("<meta name=""viewport"" content=""width=device-width, initial-scale=1"">`n<title>FinOps Explorer forecast - $(ConvertTo-ForecastHtmlText $fy.Label)</title>`n")
    [void]$sb.Append("<style>`n$(Get-ForecastHtmlStyle)</style>`n<noscript><style>.tabpane { display: block; } .tabs { display: none; }</style></noscript>`n</head><body>`n")
    [void]$sb.Append("<div class=""masthead""><div class=""eyebrow"">FinOps Toolkit</div><h1>Pre-credit forecast: $(ConvertTo-ForecastHtmlText $fy.Label)</h1><p class=""meta"">$($meta -join ' &nbsp;|&nbsp; ')</p></div>`n")
    [void]$sb.Append('<div class="wrap">')
    [void]$sb.Append((ConvertTo-ForecastSummaryCardsHtml -Model $Model -Readiness $Readiness -Currency $currency))
    [void]$sb.Append('<nav class="tabs" role="tablist" aria-label="Report sections">')
    for ($i = 0; $i -lt $panes.Count; $i++) {
        $pane = $panes[$i]
        $selected = if ($i -eq 0) { 'true' } else { 'false' }
        $state = if ($i -eq 0) { ' active' } else { '' }
        $tabIndex = if ($i -eq 0) { '' } else { ' tabindex="-1"' }
        [void]$sb.Append("<button type=""button"" class=""tab$state"" role=""tab"" id=""tabbtn-$($pane.Id)"" aria-selected=""$selected""$tabIndex aria-controls=""tab-$($pane.Id)"" data-target=""tab-$($pane.Id)"">$(ConvertTo-ForecastHtmlText $pane.Label)</button>")
    }
    [void]$sb.Append("</nav>`n")
    for ($i = 0; $i -lt $panes.Count; $i++) {
        $pane = $panes[$i]
        $state = if ($i -eq 0) { ' active' } else { '' }
        [void]$sb.Append("<section id=""tab-$($pane.Id)"" class=""tabpane$state"" role=""tabpanel"" aria-labelledby=""tabbtn-$($pane.Id)"" tabindex=""0"">$($pane.Html)</section>`n")
    }
    [void]$sb.Append('<div class="footer">Generated by FinOps Explorer &mdash; part of the <a href="https://aka.ms/finops/toolkit">FinOps Toolkit</a></div>')
    [void]$sb.Append("</div>`n<script>`n$(Get-ForecastHtmlScript)</script>`n</body></html>`n")
    return $sb.ToString()
}
