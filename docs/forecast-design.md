# Pre-credit forecast: design and integration plan

This is the as-built plan for the forecast added to the standalone FinOps Explorer. For day-to-day use, read [forecast.md](forecast.md).

## Goal and boundaries

The forecast does three things:

- Explains historical Azure growth.
- Forecasts a configurable fiscal year from pre-credit cost: actuals to date, plus a central estimate and a sensitivity range for the rest of the year.
- Breaks growth down by workload.

It reads Cost Management exports, or manual monthly inputs when exports aren't available.

It never writes to Azure. Writes go to the user's private workspace and report folders only. Automated tests enforce both rules.

## Where it lives

The feature sits beside Explorer's runtime, not inside it, so syncs from the FinOps Toolkit stay mechanical.

| Path | Purpose |
|---|---|
| `Private/FinOpsForecast/` | The forecast module: 18 PowerShell scripts, a module loader, and one C# reducer |
| `Public/Start-FinOpsForecast.ps1` | Public entry point |
| `Private/FinOpsMultitool/Invoke-FinOpsMultitool.ps1` | One 9-line hook after the banner that offers the forecast. Skipped for `-NonInteractive`, `-Scans`, and `-DataSource` |
| `scripts/Test-ToolkitParity.ps1` | Treats that hook as an allowed standalone overlay, next to the four version overlays |
| `Tests/` | Pester 6 suite, synthetic data only |
| `samples/forecast/` | Synthetic config and workload-mapping examples |

### What it reuses from Explorer

- `FinOpsMultitool.psm1` helpers:
  - Storage listing and blob reads (`Get-StorageBlobList`, `Get-StorageBlobBytes`, `Get-ExportBlobSuffix`).
  - Export discovery (`Find-CostExport`, `Find-CostExportFromStorage`).
  - Private-directory creation (`New-FinOpsPrivateDirectory`).
- Explorer's console and report helpers. These are nested inside `Invoke-FinOpsMultitool`, so the module loads them from that script's syntax tree:
  - Sign-in and subscription picking (`Select-Subscription`).
  - Report folders and files (`New-FinOpsReportDirectory`, `Write-FinOpsReportFile`, `Assert-FinOpsReportPath`).
  - The CSV formula-injection guard (`ConvertTo-FinOpsExportCell`).
  - Console output and prompts (`Write-FinOpsConsole`, `Read-FinOpsAnswer`).

  If any helper is missing or defined twice after a sync, the module refuses to load instead of running a stale copy.

## Data flow

1. **Discover runs.** List every blob under each source. Each `manifest.json` describes one run: `runId`, `submittedTime`, `startDate`, `endDate`, `exportConfig.resourceId` and `type`, and every partition with `byteCount` and `dataRowCount`. CSV files that no manifest claims become legacy runs, which need a reviewer's approval.
2. **Read runs.** Download every declared partition and check its byte count. Stream it through `TextFieldParser`, then check its row count. Any missing partition, size or row mismatch, or unreadable row makes the run unusable instead of quietly short.
3. **Reduce, then classify.** The C# reducer sums rows that share the same raw values into tuples. A PowerShell reducer with identical output covers hosts that block `Add-Type`. PowerShell then applies the rules once per tuple: schema, charge stream, publisher class, pricing model, agreement, migration-boundary side, and workload tag.
4. **Cache.** Results are cached per run. A refresh re-reads only runs whose manifest, partitions, or ingest profile (tag key, boundary date) changed. A new cache replaces the old one only after every source was read.
5. **Select.** For each (original scope, dataset, month), prefer a run that covers the whole month, then a legacy run, then one still in progress; among those, the latest complete, approved run wins. A run that starts after the first of the month can't stand in for it and raises a warning. A month counts as final once a whole-month run was submitted at least the grace period after month end. A corrected rerun replaces the month instead of adding to it.
6. **Assemble.** Apply overlap, boundary, scope, and filter rules, then reconcile every run-month to its raw total. Overlap is decided per subscription, or per billing profile for charges without a subscription. Rows dated outside a run's own dates are reported, not counted.
7. **Model, gate, report.** Run the forecast and the readiness checks, then write reports. Save a vintage only when the forecast is Ready.

### Charge streams

| Stream | Charge types | Treatment |
|---|---|---|
| Run rate | Usage, UnusedReservation, UnusedSavingsPlan | Drives growth |
| Purchase | Purchase, Refund | Kept in actuals; future amounts come only from scheduled items |
| Adjustment | RoundingAdjustment, Adjustment | Kept in actuals; not grown |
| Credit | Credit | Never in the pre-credit headline |
| Tax | Tax | Excluded unless the setting includes it |
| Other | Anything unrecognized | Kept in actuals and needs a review |

## Method

- **Run rate:** month cost × 30 / days in month.
- **Comparisons:** N complete months give N − 1 adjacent changes, ordered by month key, never by row order. A zero or negative previous month makes the change undefined, and it needs an acknowledgement.
- **Anomalies:** a change is flagged when |change − median| > max(K × 1.4826 × MAD, minimum deviation). The defaults are K = 3 and 5 points. A flag needs a review: Retain, Exclude, or Step change. Step change is suggested when the new level held the following month.
- **Growth:** the median of retained changes. The sensitivity range is the 25th to 75th percentile (PERCENTILE.INC). At least 8 of 11 must be retained.
- **Baseline:** the latest month's run rate. If that month is anomalous, a separate review picks the latest month, the median of the last three months, or a manual value with a reason.
- **Projection:** baseline × (1 + g)^h × days / 30 for each path, where h is months after the window.
- **Current month:** actuals so far plus the forecast for the remaining days. A scheduled item whose commitment ID matches a purchase already posted that month isn't added again.
- **Scheduled items:** added to every path. Additive adds the amount, AlreadyInBaseline adds nothing, and ReplacesBaselineAmount adds the amount minus what it replaces.
- **Fiscal-year totals:** sum one consistent path per scenario, never independent percentiles.
- **Backtest:** every cutoff with a full window and a later month, using automatic exclusions. It reports mean absolute error, bias, and how often actuals fell in range. These are observed results, not a calibration.

Money is `[decimal]` throughout and stored as invariant strings in JSON. Display rounding is banker's rounding to cents.

## Readiness gate

Ready requires no **Fail** in any of these checks:

- Settings.
- Source data and partitions.
- Complete months (12 or more by default).
- All comparisons computed.
- Enough retained comparisons.
- A single currency.
- Unique keys: runs, scheduled items, mappings, inputs.
- An EA-to-MCA boundary, when both agreements are present.
- Reconciliation.
- A baseline.
- No pending required reviews.

Freshness and partial population raise **Warn** and labels instead. Failed checks block saving a vintage. Reports can still be written, labeled NotReady.

## Verified Azure facts

Checked on Microsoft Learn, November 2026.

| Fact | Source |
|---|---|
| Each export run writes `manifest.json` with run info and every blob's `byteCount` and `dataRowCount` | [Improved exports](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-improved-exports) |
| Partitioning is always on. Without overwrite, a month folder keeps every run ID; daily month-to-date runs are cumulative | same |
| Portal backfill reaches 13 months; Exports Execute REST reaches 7 years for cost datasets | same |
| Cost is "before credits or taxes"; credits are applied at invoice time | [EA schema](https://learn.microsoft.com/azure/cost-management-billing/dataset-schema/cost-usage-details-ea), [MCA schema](https://learn.microsoft.com/azure/cost-management-billing/dataset-schema/cost-usage-details-mca) |
| Taxes and credits aren't in any Cost Management cost dataset | [FOCUS conformance](https://learn.microsoft.com/cloud-computing/finops/focus/conformance-full-report) |
| `PublisherType` is documented as `Azure` for every EA row | EA schema |
| Actual cost shows reservation purchases as Purchase charges and covered usage at zero | [Amortized costs](https://learn.microsoft.com/azure/cost-management-billing/reservations/view-amortized-costs) |
| FOCUS `BilledCost` is the invoicing basis; `x_PublisherCategory` separates vendors from the cloud provider | [FOCUS schema](https://learn.microsoft.com/azure/cost-management-billing/dataset-schema/cost-usage-details-focus) |
| EA cost history stays in the EA scope after moving to MCA | [Onboard MCA](https://learn.microsoft.com/azure/cost-management-billing/manage/onboard-microsoft-customer-agreement) |
| A billing period closes up to 72 hours after it ends; export files aren't rounded | [Understand Cost Management data](https://learn.microsoft.com/azure/cost-management-billing/costs/understand-cost-mgt-data) |

## Unknowns and how they're handled

| Unknown | Handling |
|---|---|
| How EA Marketplace rows look in real exports. Learn says `PublisherType` is always `Azure`; the FinOps hub ingestion checks for `Marketplace` | Rows from a non-Microsoft publisher are Unclassified until a reviewer decides |
| Whether refund rows are negative | Signs are kept as exported; positive refunds are flagged |
| Row layout in the transition month | A confirmed boundary date; EA rows on or after it and MCA rows before it are excluded and reported |
| Manifest differences across export API versions, and legacy exports | Legacy files need an explicit approval |
| Linux and macOS behavior | The code avoids Windows-only APIs, but only Windows has been run |

Validating these against sanitized real exports is the main open task.

## Acceptance tests

| Requirement | Tests |
|---|---|
| Migration boundaries | `Forecast.Exports.Tests.ps1`: requires a boundary; joins EA before and MCA after without overlap |
| Overlapping runs | Exports: one run per month, no stacking, corrections replace, idempotent; a tail-of-month run never replaces a whole month; month-to-date runs stay provisional; overlapping export scopes, including charges without a subscription |
| Missing partitions or months | Exports: missing partition, row and byte mismatches, newest-incomplete fallback; Engine: missing months |
| Zeros and refunds | Engine: undefined change after a zero month; Inputs: missing vs verified zero; Exports: signed refunds, positive refunds flagged |
| Sorting | Engine: date-key ordering with shuffled input |
| Duplicate keys and schedules | Engine: duplicate IDs and near-duplicate schedules; Inputs: duplicate months and charge IDs; Workloads: mapping duplicates; Exports: identical rows kept |
| Failed refresh keeps old data | `Forecast.State.Tests.ps1` |
| First-row calculations | Engine: 11 comparisons start after the first month; Workloads: new workload with undefined growth |
| Ties | Workloads: ID tie-breaks in every view; earliest month for equal increases |
| Expanded datasets | Workloads: 600 workloads × 24 months, no truncation |
| Baseline anomalies | Engine: separate baseline review and all three decisions |
| Credits leave the headline unchanged | Exports (FOCUS credit rows) and Inputs (credit charges) |
| End to end, safety, console | `Forecast.EndToEnd.Tests.ps1`, `Forecast.Safety.Tests.ps1`, `Forecast.Console.Tests.ps1` |
| Compiled and PowerShell reducers agree | Exports: exact parity for EA, MCA, and FOCUS, including escaped and date-like tag values |
| Review decisions stay stable | Exports: a publisher decision survives new rows from the same publisher and reopens for a new one |
| Nothing dropped silently | Exports: rows outside a run's dates are reported, reconciled, and warn on Source; the cache keeps their total exactly |
| Scheduled items in the current month | Engine: a purchase already posted isn't added again; an unlinked purchase item gets a note |

## Performance

These figures were measured on Windows with PowerShell 7.6 and synthetic gzip CSV exports:

| Rows in one partition | Compiled reducer | PowerShell reducer |
|---|---|---|
| 200,000 | 9.6 s (includes the one-time compile) | 68 s |
| 1,000,000 | 19 s | not measured |

The PowerShell reducer only runs when the host blocks `Add-Type`, for example in Constrained Language Mode.

A first refresh of 13 months at a million rows a month takes a few minutes. Later refreshes only read new or corrected runs. Partitions are held in memory compressed, so gzip exports keep memory low.

## Follow-ups

- Validate the unknowns above with sanitized EA and MCA exports.
- Run the suite on Linux and macOS.
- Optional sources: a FinOps hub (Kusto `Costs()` with `BilledCost`) and Parquet exports.
- If the Toolkit wants this feature, move it upstream as its own PR after #2155 merges.
