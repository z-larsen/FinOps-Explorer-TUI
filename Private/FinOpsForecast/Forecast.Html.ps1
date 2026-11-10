# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers that build objects or write only the private local forecast workspace; nothing in Azure changes.')]
param()

###########################################################################
# FORECAST.HTML.PS1
# SELF-CONTAINED HTML REPORT
###########################################################################
# Every value is HTML-encoded. Tables load every row and page them in the
# browser, with a filter box, so large workload lists aren't truncated. The
# page loads nothing from the network.
###########################################################################

function ConvertTo-ForecastHtmlText {
    param([AllowNull()]$Value)
    return [Net.WebUtility]::HtmlEncode([string]$Value)
}

function Format-ForecastHtmlCell {
    param([AllowNull()]$Value, [string]$Format)
    switch ($Format) {
        'amount' { if ($null -eq $Value -or ($Value -is [string] -and $Value.Length -eq 0)) { return '' } return Format-ForecastAmount ([decimal]$Value) }
        'percent' { return Format-ForecastPercent $Value }
        'date' { if ($Value -is [datetime]) { return ([datetime]$Value).ToString('yyyy-MM-dd', $script:ForecastInvariant) } return [string]$Value }
        default {
            if ($Value -is [array]) { return (@($Value) | ForEach-Object { [string]$_ }) -join '; ' }
            if ($Value -is [decimal]) { return Format-ForecastAmount $Value }
            return [string]$Value
        }
    }
}

function ConvertTo-ForecastHtmlTable {
    param(
        [Parameter(Mandatory)][string]$Id,
        [AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][object[]]$Columns,
        [int]$PageSize = 25
    )
    $sb = [Text.StringBuilder]::new()
    $count = @($Rows).Count
    [void]$sb.Append("<div class=""grid""><div class=""controls""><input type=""search"" placeholder=""Filter $count rows"" data-filter=""$Id""><span class=""pager"" data-pager=""$Id""></span></div>")
    [void]$sb.Append("<table id=""$Id"" data-page-size=""$PageSize""><thead><tr>")
    foreach ($column in $Columns) { [void]$sb.Append("<th>$(ConvertTo-ForecastHtmlText $column.Label)</th>") }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($row in @($Rows)) {
        $class = ''
        if ($row.PSObject.Properties.Name -contains 'Status' -and $row.Status -in 'Fail', 'NotReady', 'Missing', 'Incomplete') { $class = ' class="fail"' }
        elseif ($row.PSObject.Properties.Name -contains 'Status' -and $row.Status -in 'Warn', 'Provisional') { $class = ' class="warn"' }
        [void]$sb.Append("<tr$class>")
        foreach ($column in $Columns) {
            $text = Format-ForecastHtmlCell -Value $row.($column.Name) -Format $column.Format
            $align = if ($column.Format -in 'amount', 'percent') { ' class="num"' } else { '' }
            [void]$sb.Append("<td$align>$(ConvertTo-ForecastHtmlText $text)</td>")
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table></div>')
    return $sb.ToString()
}

function New-ForecastColumn {
    param([string]$Name, [string]$Label, [string]$Format = 'text')
    [pscustomobject]@{ Name = $Name; Label = $(if ($Label) { $Label } else { $Name }); Format = $Format }
}

function ConvertTo-ForecastHtml {
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)]$Dataset,
        [Parameter(Mandatory)]$Readiness,
        $Workloads,
        $Backtest,
        [string[]]$Disclosure,
        [string]$ScopeLabel
    )
    $currency = $Dataset.Currency
    $projection = $Model.Projection
    $status = $Readiness.Status
    $labels = if ($Readiness.Labels.Count) { " &middot; " + (ConvertTo-ForecastHtmlText ($Readiness.Labels -join ', ')) } else { '' }
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append(@"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FinOps Explorer forecast - $(ConvertTo-ForecastHtmlText $projection.FiscalYear.Label)</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b1b1b;background:#fafafa}
h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:28px 0 8px;border-bottom:1px solid #ddd;padding-bottom:4px}
.meta{color:#555;font-size:13px}.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-weight:600;font-size:12px}
.Ready{background:#dff6dd;color:#107c10}.NotReady{background:#fde7e9;color:#a4262c}
.cards{display:flex;flex-wrap:wrap;gap:12px;margin:16px 0}.card{background:#fff;border:1px solid #ddd;border-radius:6px;padding:12px 16px;min-width:200px}
.card .v{font-size:20px;font-weight:600}.card .l{font-size:12px;color:#555}
table{border-collapse:collapse;width:100%;background:#fff;font-size:12.5px}th,td{border:1px solid #e1e1e1;padding:4px 6px;text-align:left;vertical-align:top}
th{background:#f3f3f3;position:sticky;top:0}td.num{text-align:right;white-space:nowrap}tr.fail td{background:#fdf3f4}tr.warn td{background:#fff8e6}
.grid{margin-bottom:8px}.controls{display:flex;gap:12px;align-items:center;margin:6px 0}.controls input{padding:4px;width:240px}
.pager button{margin:0 2px}pre{background:#fff;border:1px solid #ddd;padding:12px;white-space:pre-wrap;font-size:12.5px}
</style></head><body>
<h1>Pre-credit forecast: $(ConvertTo-ForecastHtmlText $projection.FiscalYear.Label)</h1>
<p class="meta">Scope: $(ConvertTo-ForecastHtmlText $ScopeLabel) &middot; Currency: $(ConvertTo-ForecastHtmlText $currency) &middot; As of $(ConvertTo-ForecastHtmlText (([datetime]$Model.AsOf).ToString('yyyy-MM-dd', $script:ForecastInvariant))) &middot; <span class="badge $status">$(ConvertTo-ForecastHtmlText $status)</span>$labels</p>
<div class="cards">
<div class="card"><div class="l">Central estimate</div><div class="v">$(ConvertTo-ForecastHtmlText (Format-ForecastAmount $projection.TotalCentral $currency))</div></div>
<div class="card"><div class="l">Sensitivity range (not a confidence interval)</div><div class="v">$(ConvertTo-ForecastHtmlText (Format-ForecastAmount $projection.TotalLow)) to $(ConvertTo-ForecastHtmlText (Format-ForecastAmount $projection.TotalHigh))</div></div>
<div class="card"><div class="l">Actuals to date</div><div class="v">$(ConvertTo-ForecastHtmlText (Format-ForecastAmount $projection.ActualToDate $currency))</div></div>
<div class="card"><div class="l">Scheduled items</div><div class="v">$(ConvertTo-ForecastHtmlText (Format-ForecastAmount $projection.Scheduled $currency))</div></div>
<div class="card"><div class="l">Growth a month (low / central / high)</div><div class="v">$(ConvertTo-ForecastHtmlText "$(Format-ForecastPercent $Model.Growth.Low 2) / $(Format-ForecastPercent $Model.Growth.Central 2) / $(Format-ForecastPercent $Model.Growth.High 2)")</div></div>
</div>
"@)
    [void]$sb.Append('<h2>Fiscal year by month</h2>')
    [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'monthly' -Rows $projection.Rows -PageSize 24 -Columns @(
                (New-ForecastColumn Month), (New-ForecastColumn Kind), (New-ForecastColumn Actual -Format amount), (New-ForecastColumn Scheduled -Format amount),
                (New-ForecastColumn TotalLow 'Low' amount), (New-ForecastColumn TotalCentral 'Central' amount), (New-ForecastColumn TotalHigh 'High' amount), (New-ForecastColumn Note))))
    [void]$sb.Append('<h2>Checks</h2>')
    [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'checks' -Rows $Readiness.Checks -PageSize 50 -Columns @((New-ForecastColumn Name 'Check'), (New-ForecastColumn Status), (New-ForecastColumn Detail))))
    [void]$sb.Append('<h2>Exceptions and reviews</h2>')
    [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'reviews' -Rows $Readiness.Reviews -Columns @((New-ForecastColumn Category), (New-ForecastColumn Title), (New-ForecastColumn Required), (New-ForecastColumn Decision), (New-ForecastColumn Note), (New-ForecastColumn Detail))))
    [void]$sb.Append('<h2>Adjacent-month comparisons</h2>')
    $comparisonRows = foreach ($item in @($Model.Comparisons.Items)) { $item | Select-Object *, @{ Name = 'Decision'; Expression = { if ($_.Review) { $_.Review.Decision } else { '' } } } }
    [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'comparisons' -Rows @($comparisonRows) -PageSize 40 -Columns @((New-ForecastColumn FromMonth 'From'), (New-ForecastColumn ToMonth 'To'), (New-ForecastColumn FromRunRate 'From run rate' amount), (New-ForecastColumn ToRunRate 'To run rate' amount), (New-ForecastColumn Change 'Change' percent), (New-ForecastColumn Flagged), (New-ForecastColumn Decision), (New-ForecastColumn Retained), (New-ForecastColumn Reason))))
    [void]$sb.Append('<h2>Monthly history</h2>')
    [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'history' -Rows $Model.Window.Rows -PageSize 40 -Columns @((New-ForecastColumn Month), (New-ForecastColumn Status), (New-ForecastColumn RunRate 'Run-rate charges' amount), (New-ForecastColumn Purchase 'Purchases' amount), (New-ForecastColumn Adjustment 'Adjustments' amount), (New-ForecastColumn Other -Format amount), (New-ForecastColumn Headline 'Pre-credit total' amount), (New-ForecastColumn Credit 'Credits (not counted)' amount), (New-ForecastColumn ExcludedMarketplace 'Excluded Marketplace' amount), (New-ForecastColumn Note))))
    if ($Workloads) {
        [void]$sb.Append("<h2>Workloads ($(@($Workloads.Workloads).Count), mode $(ConvertTo-ForecastHtmlText $Workloads.Mode))</h2><p class=""meta"">Change in 30-day run rate from $(ConvertTo-ForecastHtmlText $Workloads.Months[0]) to $(ConvertTo-ForecastHtmlText $Workloads.Months[-1]). Contribution share = workload change / net change ($(ConvertTo-ForecastHtmlText (Format-ForecastAmount $Workloads.NetChange $currency))). The largest increase is the biggest month-over-month rise, which differs from the highest spend and the highest percentage growth.</p>")
        [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'workloads' -Rows $Workloads.Workloads -Columns @((New-ForecastColumn WorkloadName 'Workload'), (New-ForecastColumn WorkloadId 'ID'), (New-ForecastColumn Flags), (New-ForecastColumn FirstRunRate 'First' amount), (New-ForecastColumn LastRunRate 'Last' amount), (New-ForecastColumn Change -Format amount), (New-ForecastColumn Growth 'Growth' percent), (New-ForecastColumn ContributionShare 'Share' percent), (New-ForecastColumn LargestIncreaseMonth 'Largest increase month'), (New-ForecastColumn LargestIncreaseAmount 'Largest increase' amount), (New-ForecastColumn LookbackSpend 'Lookback spend' amount), (New-ForecastColumn Notes))))
    }
    if ($Backtest) {
        [void]$sb.Append("<h2>Backtest</h2><p class=""meta"">$(ConvertTo-ForecastHtmlText $Backtest.Note)</p>")
        if ($Backtest.Status -eq 'Completed') {
            [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'backtest' -Rows $Backtest.Results -Columns @((New-ForecastColumn Cutoff), (New-ForecastColumn Month), (New-ForecastColumn Horizon), (New-ForecastColumn Actual -Format amount), (New-ForecastColumn ForecastCentral 'Central' amount), (New-ForecastColumn ErrorRatio 'Error' percent), (New-ForecastColumn InRange 'In range'))))
        }
    }
    [void]$sb.Append('<h2>Reconciliation</h2>')
    [void]$sb.Append((ConvertTo-ForecastHtmlTable -Id 'reconciliation' -Rows $Dataset.Reconciliation -Columns @((New-ForecastColumn Month), (New-ForecastColumn Source), (New-ForecastColumn Rows), (New-ForecastColumn RawTotal 'Raw total' amount), (New-ForecastColumn IncludedHeadline 'Included' amount), (New-ForecastColumn ExcludedMarketplace 'Marketplace' amount), (New-ForecastColumn ExcludedScope 'Out of scope' amount), (New-ForecastColumn ExcludedBoundary 'Boundary' amount), (New-ForecastColumn ExcludedOutsideRange 'Outside run dates' amount), (New-ForecastColumn Credits -Format amount), (New-ForecastColumn Difference -Format amount))))
    [void]$sb.Append("<h2>Method and disclosure</h2><pre>$(ConvertTo-ForecastHtmlText ($Disclosure -join "`n"))</pre>")
    [void]$sb.Append(@'
<script>
(function () {
  document.querySelectorAll('table[data-page-size]').forEach(function (table) {
    var size = parseInt(table.getAttribute('data-page-size'), 10) || 25;
    var rows = Array.prototype.slice.call(table.tBodies[0].rows);
    var filter = document.querySelector('input[data-filter="' + table.id + '"]');
    var pager = document.querySelector('[data-pager="' + table.id + '"]');
    var page = 0;
    var label = document.createElement('span');
    label.setAttribute('aria-live', 'polite');
    pager.appendChild(label);
    var buttons = [['Previous', -1], ['Next', 1]].map(function (pair) {
      var button = document.createElement('button');
      button.type = 'button';
      button.textContent = pair[0];
      button.addEventListener('click', function () { page += pair[1]; render(); });
      pager.appendChild(button);
      return button;
    });
    function matches() {
      var text = filter ? filter.value.toLowerCase() : '';
      return rows.filter(function (row) { return !text || row.textContent.toLowerCase().indexOf(text) >= 0; });
    }
    function render() {
      var visible = matches();
      var pages = Math.max(1, Math.ceil(visible.length / size));
      if (page >= pages) { page = pages - 1; }
      rows.forEach(function (row) { row.style.display = 'none'; });
      visible.slice(page * size, page * size + size).forEach(function (row) { row.style.display = ''; });
      label.textContent = visible.length + ' rows, page ' + (page + 1) + ' of ' + pages + ' ';
      var focused = document.activeElement;
      buttons[0].disabled = page === 0;
      buttons[1].disabled = page >= pages - 1;
      if (focused === buttons[0] && buttons[0].disabled && !buttons[1].disabled) { buttons[1].focus(); }
      else if (focused === buttons[1] && buttons[1].disabled && !buttons[0].disabled) { buttons[0].focus(); }
    }
    if (filter) { filter.addEventListener('input', function () { page = 0; render(); }); }
    render();
  });
})();
</script>
</body></html>
'@)
    return $sb.ToString()
}
