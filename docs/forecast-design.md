# Pre-credit forecast: design and integration plan

This is the as-built plan for the forecast added to the standalone FinOps Explorer. For day-to-day use, read [forecast.md](forecast.md).

## Goal and boundaries

The forecast does three things:

- Explains historical Azure growth.
- Forecasts a configurable fiscal year from pre-credit cost: actuals to date, plus a central estimate and a sensitivity range for the rest of the year.
- Breaks growth down by workload.

It reads Cost Management exports, live Cost Details reports, or manual monthly inputs when neither is available.

It never writes to Azure. Writes go to the user's private workspace and report folders only. Automated tests enforce both rules. The one request that isn't a plain read is the Cost Details source's POST to `generateCostDetailsReport`, which creates a temporary report rather than an Azure resource. The safety tests allow exactly that call, in one file, and nothing else.

## Where it lives

The feature sits beside Explorer's runtime, not inside it, so syncs from the FinOps Toolkit stay mechanical.

| Path | Purpose |
|---|---|
| `Private/FinOpsForecast/` | The forecast module: 20 PowerShell scripts, a module loader, and one C# reducer |
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
  - Resource Manager calls with retry and throttle handling (`Invoke-AzRestMethodWithRetry`, `Get-ServerRetryDelay`, `Get-FinOpsArmEndpoint`), used only by the Cost Details source.
- Explorer's console and report helpers. These are nested inside `Invoke-FinOpsMultitool`, so the module loads them from that script's syntax tree:
  - Sign-in and subscription picking (`Select-Subscription`).
  - Report folders and files (`New-FinOpsReportDirectory`, `Write-FinOpsReportFile`, `Assert-FinOpsReportPath`).
  - The CSV formula-injection guard (`ConvertTo-FinOpsExportCell`).
  - Console output and prompts (`Write-FinOpsConsole`, `Read-FinOpsAnswer`).

  If any helper is missing or defined twice after a sync, the module refuses to load instead of running a stale copy.

## Data flow

1. **Discover runs.** List every blob under each source. Each `manifest.json` describes one run: `runId`, `submittedTime`, `startDate`, `endDate`, `exportConfig.resourceId` and `type`, and every partition with `byteCount` and `dataRowCount`. CSV files that no manifest claims become legacy runs, which need a reviewer's approval. A Cost Details source has nothing to list; see [Cost Details source](#cost-details-source).
2. **Read runs.** Reject duplicate partition references, including aliases resolving to the same file. Download every distinct declared partition and check its byte count. Stream it through `TextFieldParser`, then check its row count. Any missing partition, size or row mismatch, unreadable row, or invalid manifest date range makes the run unusable instead of quietly short. So does amortized content: EA and MCA amortized files have the same columns as actual cost, so a run is rejected when reservation- or savings-plan-covered usage has a cost, or when it has unused-benefit charges. Actual cost has neither.
3. **Reduce, then classify.** The C# reducer sums rows that share the same raw values into tuples. A PowerShell reducer with identical output covers hosts that block `Add-Type`. PowerShell then applies the rules once per tuple: schema, charge stream, publisher class, pricing model, agreement, migration-boundary side, and workload tag.
4. **Cache.** Results are cached per run. The signature includes manifest dates and modification time, plus each partition's modification time, size, and declared counts. Same-size corrections are re-read when their modification time changes; missing partition timestamps disable reuse. The ingest profile includes source locations and schema overrides, the tag key, the boundary date, and the ingestion version. Changing it requires a refresh. If a previously usable cached run becomes unreadable or invalid, refresh fails and keeps the previous cache. A newly discovered incomplete run can still be recorded while an older complete run remains selected. The swap into place retries for a few seconds if Windows antivirus or indexing briefly holds a file that was just written.
5. **Select.** For each (original scope, dataset, month), prefer a run that covers the whole month, then a legacy run, then one still in progress; among those, the latest complete, approved run wins. A run that starts after the first of the month can't stand in for it and raises a warning. A legacy file only counts as covering the whole month if its rows reach the month's last day; otherwise it's treated as still in progress. A month counts as final once a whole-month run was submitted at least the grace period after month end: 4 days by default, so from 00:00 UTC on day 5, when a daily export writes its last copy of the prior month. A corrected rerun replaces the month instead of adding to it. Several legacy files for one month raise a warning, because they're more likely different datasets than reruns.
6. **Assemble.** Apply overlap, boundary, scope, and filter rules, then reconcile every run-month to its raw total. Overlap is decided per subscription, or per billing profile for charges without a subscription. Check each row's date, not just its month, against the run range. Outside-range charges and row counts appear once, on that run's first selected reconciliation row, in both the raw total and the excluded amount. An end at midnight on the next month's first day is exclusive; other end dates are inclusive. A final month whose last charge precedes month end raises a warning.
7. **Model, gate, report.** Run the forecast and the readiness checks, then write reports. Save a vintage only when the forecast is Ready. A rejected future window remains a blocking settings failure even when a fallback window is used for preview.

Legacy run identity includes the source ID, so identical relative filenames in
different sources aren't discarded as duplicates. Only manifest-backed runs can
share a run identity across sources. Folder dates never substitute for observed
month-end coverage in a legacy file.

### Cost Details source

A `CostDetails` source (`Forecast.CostDetails.ps1`) produces the same run records as an export, so steps 2 to 7 don't change:

- **Months.** Every whole month inside the API's 13-month reach (with a day's margin), then the current month through yesterday, narrowed by optional `fromMonth` and `toMonth`. On the first of a month, the current month is skipped. A `fromMonth` of `Auto` starts at `Get-ForecastFirstNeededMonth`: the lookback window's first month, or the fiscal year's first month when that's earlier. Refresh computes it from the current settings, so raising the lookback or moving the fiscal year reads the earlier months next time. Guided setup creates `Auto` sources, and so does the console's **C** by default.
- **Runs and partitions.** One run per month, with a stable key per source, scope, and month so a new read replaces the cached one. Each run has one partition per chunk of `chunkDays` days (default 7, 1 to 31). The run is `ActualCost` with `HasManifest` set, its scope is the source scope, and `Submitted` is the refresh time, so finality and coverage follow the usual rules.
- **Lazy generation.** Nothing is requested until ingestion reads a partition. Then one POST to `{scope}/providers/Microsoft.CostManagement/generateCostDetailsReport` asks for `ActualCost` for that chunk's dates; the scope is re-validated inside the function that sends it, and the safety tests allow only the partition read to call that function. The returned `Location` is followed only if it's on the signed-in cloud's Resource Manager host, for the same scope, and is a `costDetailsOperationResults` or `costDetailsOperationStatus` path. Polling honors `Retry-After` (5 to 300 seconds) for up to 30 minutes.
- **Manifest checks.** `NoDataFound` reads as an empty partition. `Completed` must echo the requested scope, dates, and `ActualCost`; a missing echo fails the chunk. It must also be uncompressed CSV, with file counts and byte totals that match. Each file is downloaded without credentials or redirects, from an HTTPS blob endpoint of the signed-in cloud, and must be exactly its declared size. A connection that sends nothing for five minutes fails the chunk. Files in one report are joined with the header kept once. Cost Details manifests have no row counts, so verification rests on byte counts and a clean parse.
- **Links.** Download links are SAS URLs. They live only in local variables inside the partition read and never reach messages, the cache, or reports. A test fails if any workspace file or message contains them.
- **Reuse.** A cached Complete month read at least the grace period after month end is reused without a request. Other months are reused if read under four hours ago for the same days, since Cost Management refreshes these reports about every four hours. Whole months this source read earlier but no longer requests, such as months the API can no longer reach, are carried forward within a fixed `fromMonth` and the `toMonth`. A whole month read before its grace period ended is carried forward too, since it may be the only copy, but it stays provisional; while the forecast needs such a month, the refresh says so, and the month's note explains it. That happens when the grace period changes, as it did from 3 to 4 days. `Auto` sets no lower bound, so lowering the lookback and raising it again doesn't lose months that can't be read again. Until last month passes its grace period, the forecast window starts one month beyond the API's reach, so dropping them would open a gap. Because those months can't be read again, Cost Details records carry a per-source profile hash (ingest version, tag key, boundary, and that source's settings) instead of the workspace-wide one, so adding or editing another source keeps them. When a tag key, boundary, or source change does invalidate them, the refresh warns and names the months it dropped.
- **Failures.** A chunk failure makes its month Incomplete, like a missing partition. A 429 after Explorer's retries pauses further Cost Details requests until the service's retry time. If a refresh fails outright, any month this attempt read completely replaces its own record in the previous cache, so a long first pull resumes instead of restarting. The previous cache's workspace profile hash is kept, so a pending settings change still asks for a refresh.
- **Charge dates.** Learn ties the data to when the billing system received a cost. A charge dated before the requested month is excluded and reported as outside the run's range, never moved into the earlier month.

### Charge streams

| Stream | Charge types | Treatment |
|---|---|---|
| Run rate | Usage | Drives growth. UnusedReservation and UnusedSavingsPlan exist only in amortized cost, so a file that has them is rejected |
| Purchase | Purchase, Refund | Kept in actuals; future amounts come only from scheduled items |
| Adjustment | RoundingAdjustment, Adjustment | Kept in actuals; not grown |
| Credit | Credit | Never in the pre-credit headline |
| Tax | Tax | Excluded unless the setting includes it |
| Other | Anything unrecognized | Kept in actuals and needs a review |

## Method

- **Run rate:** month cost × 30 / days in month.
- **Comparisons:** N complete months give N − 1 adjacent changes, ordered by month key, never by row order. A zero or negative previous month makes the change undefined, and it needs an acknowledgement.
- **Anomalies:** a change is flagged when |change − median| > max(K × 1.4826 × MAD, minimum deviation). The defaults are K = 3 and 5 points. A flag needs a review: Retain, Exclude, or Step change. Retain counts the change in growth; Exclude and Step change leave it out. Step change means a one-time move to a new level, such as new reservations or savings plans covering usage, which the baseline already reflects, so counting the jump as growth would compound a one-off move. Step change is suggested when the new level held the following month, unless the change reverses a flagged change just before it and brings the run rate back near its trend; that's a one-off spike or dip, so Exclude is suggested. Any change that isn't flagged can be reviewed by hand with the same three choices, from **C** in 5 Exceptions, under the same review key. Two changes are never flagged at the default K: each sits exactly half their difference from the median, inside K × 1.4826 × that half. So with a 3-month lookback, a review by hand is the only way to set aside a known move such as new commitments. A hand review stays until the change's data changes; then it's required again.
- **Growth:** the median of retained changes; with an even count, the average of the middle two. The sensitivity range is the 25th to 75th percentile (PERCENTILE.INC, linear interpolation between ranks). While the lookback is under 12 months, it's the lowest to the highest retained change instead, because quartiles of two to ten changes are mostly interpolation and understate the spread. Custom percentiles must satisfy `0 <= low < 50 < high <= 100`, including settings loaded from JSON. At least 8 of 11 must be retained.
- **Baseline:** the latest month's run rate. If that month is anomalous (its change was flagged, undefined, or excluded or marked a step change by hand), a separate review picks the latest month, the median of the last three months, or a manual value with a reason. The median is suggested, except after a step change into the latest month, which makes it the new level, so the latest month is suggested. The step change is part of the review's fingerprint, so marking or unmarking it asks again even if the baseline was answered first, as the Exceptions list orders it.
- **Projection:** baseline × (1 + g)^h × days / 30 for each path, where h is months after the window.
- **Current month:** actuals so far plus the forecast for the remaining days. Verified manifest coverage includes days with no charges, including an empty partition; it isn't shortened to the last charge date. A configured range extending beyond submission is capped at the prior day, or a later day already carrying actual charges. Legacy files still use observed row dates. Different coverage cutoffs across selected partial-month runs block Ready until refreshed to a common cutoff. A scheduled item whose commitment ID matches a posted Purchase charge isn't added again; a Refund alone does not satisfy it.
- **Scheduled items:** added to every path. Additive adds the amount, AlreadyInBaseline adds nothing, and ReplacesBaselineAmount adds the amount minus what it replaces.
- **Fiscal-year totals:** sum one consistent path per scenario, never independent percentiles.
- **Backtest:** every cutoff with a full window and a later month, using automatic exclusions. It reports mean absolute error, bias, and how often actuals fell in range. These are observed results, not a calibration.

Money is `[decimal]` throughout and stored as invariant strings in JSON. Display rounding is banker's rounding to cents. Reconciliation treats differences under 0.000001 as rounding: `[decimal]` keeps 28 to 29 significant digits, so very long amounts summed in a different order can differ in the last digit.

Manual approval fingerprints include currency as well as amounts and evidence.
SHA-256 identifiers use `SHA256.Create().ComputeHash()` and `BitConverter`, avoiding
the .NET 5-only hashing helpers while retaining the same digest strings.

## Readiness gate

Ready requires a lookback of at least 12 months and no **Fail** in any of these checks:

- Settings.
- Source data and partitions.
- Complete months: every month in the lookback.
- Fiscal-year actuals: every month of the fiscal year before the lookback window has final data. Otherwise the projection would count it as zero.
- All comparisons computed.
- Enough retained comparisons.
- A single currency.
- Unique keys: runs, scheduled items, mappings, inputs.
- An EA-to-MCA boundary, when both agreements are present.
- Reconciliation.
- A baseline.
- No pending required reviews.

Freshness and partial population raise **Warn** and labels instead. Failed checks block saving a vintage. Reports can still be written, labeled NotReady.

A lookback of 3 to 11 months is a deliberate choice, so it doesn't fail a check. The History length check warns instead, and the status is **Preliminary** when nothing fails, or NotReady when something does. Every output carries the label, the disclosure explains how few changes the growth rests on, and a Preliminary forecast is never saved as a vintage. The default minimum of retained comparisons scales with the lookback as floor((N − 1) × 8 / 11), at least 1, so 12 months still needs 8 of 11. Changing the lookback in the console rescales a default threshold and only clamps a customized one.

## Guided setup

`Forecast.Guided.ps1` builds a workspace's settings from a few questions. Without a workspace name or `-ConfigPath`, an interactive run first calls Explorer's `Select-Subscription` for the tenant and subscriptions. Explorer lists tenants by name only, adds the domain when names repeat, and lets you type to narrow the list. It lists only the chosen tenant's subscriptions. While it signs in, it turns off Az's own subscription list for that PowerShell session, because that list spans every tenant, and hides Az's warnings about other tenants.

Az keeps a sign-in between sessions, but a tenant can require you to sign in again, for example for MFA. Listing tenants then gives only the IDs Az saved, without names, and listing subscriptions returns nothing, with a warning that names the tenant. Explorer treats both as an expired sign-in. It asks you to sign in to that tenant again, offers a fresh sign-in if that fails, and reads once more. Unattended runs stop with the `Connect-AzAccount` command that renews the sign-in. Sign-in errors show tenant names instead of IDs.

The forecast loads these helpers from Explorer's launcher, and a safety test fails if a helper calls an Explorer function the forecast doesn't load. It then opens a workspace named after the tenant's default domain, which belongs to that tenant alone, so the tenant ID isn't shown. Without a domain, the name is the tenant's display name plus the first 8 characters of a SHA-256 hash of its ID. That keeps one customer's vintages and reviews out of another's comparisons.

An empty workspace goes to setup. One that's already set up asks whether to open it or set it up again. A named workspace that's empty also starts setup, signing in there.

Setup asks for the history length (3 to 36) and the fiscal year's first month, then for the source: live Cost Details, exports, or manual. It asks about the period before it builds any source, so the first month needed covers any fiscal-year months before a short window. Choosing live with more than 12 months uses 12, since Cost Details reaches 13 months back.

Between the period questions and the source choice, a screen sums up the method and ranks the ways to read by estimated time: exports first, then the live reads, fastest first. Each shows its first-read and later-refresh report counts and rough times. The estimates assume about 35 seconds per subscription report, measured on a live tenant, and about 60 seconds per weekly billing-account report, which isn't measured yet. Above the minimum lookback, the screen recommends exports, then the fastest live read this sign-in can use. After you choose a source, setup replaces the sources, scope, lookback, window end, and retained-comparison default, keeps everything else, and offers a refresh.

**H** on the review page shows the same screen for the workspace without calling Azure. It marks the read in use and shows the last billing check from guided setup for the same subscriptions. A live read in use is estimated from the workspace's own Cost Details sources: their months, first and last months, and days per report. A billing-scope source is listed even for three or fewer subscriptions.

Live sources read the chosen subscriptions directly when there are up to three, one 31-day report per month each. Above that, `Get-ForecastCostDetailsBillingScopes` lists billing accounts with one read-only GET, and Explorer's `Get-FinOpsBillingScope` confirms each selected subscription's owner. That check runs once, before the time estimates, and the live source reuses it.

Setup offers an account only when every owner is confirmed and it's the single EA or MCA account that owns them all, so a billing-account read never misses a selected subscription. The offer defaults to whichever read the estimates say is faster. Without an offer, or if you decline it, setup reads each subscription directly, one 31-day report per month. The billing-account read uses weekly reports, and the forecast's subscription scope filters its rows back to the selected subscriptions.

Source IDs come from the scope, so running setup again reuses months already read. Live sources use `fromMonth` `Auto`. Setup warns when the first month needed is beyond Cost Management's reach, and estimates the first refresh's report requests and time from that month.

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
| Unused reservation and savings plan charges appear only in amortized cost; actual cost has a zero effective price for savings-plan-covered usage, and amortized cost has no purchase rows | [Amortized costs](https://learn.microsoft.com/azure/cost-management-billing/reservations/view-amortized-costs), [Savings plan cost and usage](https://learn.microsoft.com/azure/cost-management-billing/savings-plan/utilization-cost-reports) |
| FOCUS `BilledCost` is the invoicing basis; `x_PublisherCategory` separates vendors from the cloud provider | [FOCUS schema](https://learn.microsoft.com/azure/cost-management-billing/dataset-schema/cost-usage-details-focus) |
| EA cost history stays in the EA scope after moving to MCA | [Onboard MCA](https://learn.microsoft.com/azure/cost-management-billing/manage/onboard-microsoft-customer-agreement) |
| A billing period closes up to 72 hours after it ends, but usage charges can change until the fifth day after it ends, and charges are final when the invoice is issued; export files aren't rounded | [Understand Cost Management data](https://learn.microsoft.com/azure/cost-management-billing/costs/understand-cost-mgt-data) |
| A daily cost export runs twice a day for the first five days of a month; the second run rewrites the whole prior month to match the invoice, so its last copy arrives on day 5. A month is final from 00:00 UTC that day by default (grace 4 days) | [Create and manage exports](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-improved-exports#cost-export-runs-twice-a-day-for-the-first-five-days-of-the-month) |
| In actual cost, an up-front reservation shows once, in its purchase month; a monthly-paid one recurs on the purchase anniversary with Frequency `Recurring`; usage a reservation covers costs zero | [View amortized benefit costs](https://learn.microsoft.com/azure/cost-management-billing/reservations/view-amortized-costs), [Buy a reservation](https://learn.microsoft.com/azure/cost-management-billing/reservations/prepare-buy-reservation#buy-reservations-with-monthly-payments) |
| Cost Details covers EA and MCA only, needs read-only permissions at the scope, doesn't support management groups, returns one month or less per report, and reaches 13 months back | [Get small cost datasets on demand](https://learn.microsoft.com/azure/cost-management-billing/automate/get-small-usage-datasets-on-demand), [Create Operation](https://learn.microsoft.com/rest/api/cost-management/generate-cost-details-report/create-operation) |
| Cost Details is asynchronous: 202 with `Location` and `Retry-After`; results are `Completed`, `NoDataFound`, or `Failed`; a completed manifest lists blob links with byte counts and a `validTill` time | [Get Operation Results](https://learn.microsoft.com/rest/api/cost-management/generate-cost-details-report/get-operation-results) |
| Cost Details data corresponds to when the billing system received the cost and may span invoices; reports refresh about every four hours; above roughly 2 GB or 2 million rows a month, chunk by day or week or use Exports | [Get small cost datasets on demand](https://learn.microsoft.com/azure/cost-management-billing/automate/get-small-usage-datasets-on-demand) |

## Unknowns and how they're handled

| Unknown | Handling |
|---|---|
| How EA Marketplace rows look in real exports. Learn says `PublisherType` is always `Azure`; the FinOps hub ingestion checks for `Marketplace` | Rows from a non-Microsoft publisher are Unclassified until a reviewer decides |
| Whether refund rows are negative | Signs are kept as exported; positive refunds are flagged |
| Row layout in the transition month | A confirmed boundary date; EA rows on or after it and MCA rows before it are excluded and reported |
| Manifest differences across export API versions, and legacy exports | Legacy files need an explicit approval |
| Linux and macOS behavior | The code avoids Windows-only APIs, but only Windows has been run |
| Cost Details on a live tenant: column casing, how often charges land outside their month, link lifetime, and rate limits at volume | Subscription-scope reads have run on one live tenant, at about 35 seconds a report; billing scopes and the rest are untested against real data. Schema detection and the source's schema setting cover casing; outside-month charges are reported, not counted; expired links fail the month for the next refresh to retry; throttling pauses requests |

Validating these against sanitized real exports is the main open task.

## Acceptance tests

| Requirement | Tests |
|---|---|
| Migration boundaries | `Forecast.Exports.Tests.ps1`: requires a boundary; joins EA before and MCA after without overlap |
| Overlapping runs | Exports: one run per month, no stacking, corrections replace, idempotent; a tail-of-month run never replaces a whole month; month-to-date runs stay provisional; overlapping export scopes, including charges without a subscription |
| Missing partitions or months | Exports: missing partition, row and byte mismatches, duplicate partition aliases, invalid manifest dates, newest-incomplete fallback; Engine: missing months |
| Zeros and refunds | Engine: undefined change after a zero month; Inputs: missing vs verified zero; Exports: signed refunds, positive refunds flagged |
| Sorting | Engine: date-key ordering with shuffled input |
| Duplicate keys and schedules | Engine: duplicate IDs and near-duplicate schedules; Inputs: duplicate months and charge IDs; Workloads: mapping duplicates; Exports: identical rows kept |
| Failed refresh keeps old data | State: unavailable source, a missing or invalid formerly readable partition; a new incomplete run doesn't displace an older good run |
| Corrections invalidate the cache | State: same-size in-place charge correction, changed manifest dates, changed source interpretation, missing modification timestamps |
| First-row calculations | Engine: 11 comparisons start after the first month; Workloads: new workload with undefined growth |
| Ties | Workloads: ID tie-breaks in every view; earliest month for equal increases |
| Expanded datasets | Workloads: 600 workloads × 24 months, no truncation |
| Baseline anomalies | Engine: separate baseline review and all three decisions |
| Credits leave the headline unchanged | Exports (FOCUS credit rows) and Inputs (credit charges) |
| End to end, safety, console | `Forecast.EndToEnd.Tests.ps1`, `Forecast.Safety.Tests.ps1`, `Forecast.Console.Tests.ps1` |
| Compiled and PowerShell reducers agree | Exports: exact parity for EA, MCA, and FOCUS, including escaped and date-like tag values |
| Review decisions stay stable | Exports: a publisher decision survives new rows from the same publisher and reopens for a new one |
| Nothing dropped silently | Exports: same-month dates outside either endpoint and exclusive month boundaries; raw totals include every excluded row once |
| Scheduled items in the current month | Engine: a purchase already posted isn't added again; refunds don't suppress scheduled purchases; an unlinked purchase item gets a note |
| Partial-month coverage | Exports: sparse and zero-charge partitions retain declared coverage, future days aren't claimed, and mismatched scope cutoffs block Ready |
| Month coverage from the data | Exports: a loose file whose rows stop mid-month stays provisional; a final month whose data ends early warns |
| Amortized data rejected | Exports: EA covered usage with a cost and an MCA unused-reservation row are rejected with the reason shown; an actual-cost file wins over an amortized copy beside it |
| Rounding isn't a reconciliation failure | Exports: differences under 0.000001 pass, larger ones fail |
| One-off spikes | Engine: the drop back after a spike is suggested as Exclude; a drop that settles at a new level is still a step change; a step change is left out of growth like an exclusion, while Retain keeps it |
| Reviews by hand | Engine: with two changes nothing is flagged, but a change reviewed by hand as a step change leaves growth; excluding the latest change by hand asks for the baseline; after a step change into the latest month the baseline review suggests it and reopens an answer given first. Console: **C** in 5 Exceptions lists every change and records a hand review with its reason |
| Range and month close | Engine: the lowest to highest retained change under 12 months, and interpolated P25 to P75 from 12. Review: a month is final from 00:00 UTC on the fifth day after it ends; a stored grace equal to its schema's default (3 before schema 2, 5 in schema 2) reads as 4, and any other value is kept. Synthetic exports are submitted on day 5, as a daily export's last copy is, so every export test depends on it. Cost Details: a whole month read before it was final is kept as provisional, with a note, once the API can't return it; its copy is intact, and a later tag change drops it with a warning |
| Display names | Workloads: subscriptions with the same name get a short ID |
| Guided setup and Preliminary forecasts | `Forecast.Guided.Tests.ps1`: 3 to 36 month lookbacks and the scaled retained default; a 6-month history is Preliminary with no failing check, labeled once in the summary and HTML, explained in the disclosure, and never saved as a vintage by the console or the publisher; 12 months stays Ready; fiscal-year months before a short lookback fail the actuals check until they have data, instead of counting as zero; tenant workspaces named by domain, never the tenant ID, with name and hash fallbacks; a billing account offered only when one EA or MCA account owns every subscription and each owner is confirmed; live setup per subscription, at an owning billing account, and the per-subscription fallback, all with an `Auto` first month; a fiscal year starting before a short lookback widens the live read; time estimates shown before the source question, ranked exports first and then the faster live read, with report counts, rough times, and rounding; the billing account checked once before the estimates and reused, shown as available or not, and left out for three or fewer subscriptions; a recommendation only above the minimum lookback; the faster live read offered as the default; live reads capped at 12 months; **H** on the review page marking the read in use and showing the last billing check without calling Azure, estimating the read in use from the workspace's own sources, and listing a billing-scope source for a few subscriptions; exports from a local folder; manual inputs; cancelling changes nothing; the period editor rescales or clamps; unnamed interactive runs sign in and open the tenant workspace, set-up workspaces open without asking again, and named workspaces skip sign-in |
| Choosing a tenant | `Explorer.SignIn.Tests.ps1`, against Explorer's launcher with stubbed Az commands: tenants listed by name, sorted, with no tenant ID on screen; repeated names told apart by domain, unnamed tenants shown by domain, and identical lines numbered; control characters removed; typing narrows the list, Esc clears it then stays, and the list scrolls a page at a time; a number or part of a name picks a tenant; only the chosen tenant's subscriptions are listed; a cancelled sign-in returns to the list, and one that ends in another tenant stops; unattended runs never prompt or switch; Az's subscription list is off only while signing in and restored afterward, even when sign-in fails, and Az's own warnings are hidden; an expired sign-in is renewed in its tenant before tenants, subscriptions, or an explicit subscription are read, with a fresh sign-in offered if that fails; a tenant with no enabled subscriptions is explained; unattended runs stop with the command that renews the sign-in; sign-in errors keep their first sentence and name tenants instead of IDs |
| Cost Details source | `Forecast.CostDetails.Tests.ps1`, against a synthetic API: month planning and chunking; an `Auto` first month following the lookback window, the fiscal year's start, and a pinned window end; scope and settings validation; one POST per chunk with the exact path and body; status links on another host, scope, or operation refused; mismatched or missing manifest echoes rejected; NoDataFound; access and throttle failures; credential-free, redirect-free, size-checked downloads over loopback, including a stalled connection; closed months reused and the open month re-read after four hours; a longer lookback or earlier fiscal year reading only the new months, and a shorter one keeping them; final months beyond the API's reach kept while the window needs them; links never persisted; months kept after a failed refresh; outside-month charges reported; EA enrollment and MCA billing profile joined at the boundary. Safety: only that file may POST, only to `generateCostDetailsReport`, only from a partition read, with GET-only downloads |

## Checked against the FinOps toolkit sample

The forecast was also run against the Microsoft sample cost data in the FinOps toolkit repository (`src/open-data/dataset-examples`, a demo EA billing account). The sample covers June 1 to 19, 2024 only, so it can't produce a Ready forecast by itself.

- **EA actual cost** (135,253 rows, 55 columns): $35,445.86, which is $35,425.22 of usage plus a $20.64 reservation purchase. That matches an independent count of the file, with nothing unreconciled.
- **FOCUS 1.0** (96 columns, read through `BilledCost`): the same totals to the cent.
- **EA amortized cost** placed beside the actual-cost file: rejected as amortized.
- **A 12-month replay** of the June rows with a scripted growth pattern (2.6 million rows): the growth, anomaly flags, workload metrics, and fiscal-year totals came out as constructed.

This run found the issues covered by the last five rows of the table above.

## Performance

These figures were measured on Windows with PowerShell 7.6, one refresh at a time, using the compiled reducer. The synthetic rows time reading only; the sample rows time the whole `Start-FinOpsForecast -NonInteractive` run (read, evaluate, write reports).

| Data | Size | Time |
|---|---|---|
| Synthetic, narrow rows, 1 partition | 200,000 rows | 9.6 s (includes the one-time compile) |
| Synthetic, narrow rows, 1 partition | 1,000,000 rows | 19 s |
| FinOps toolkit EA sample, 55 columns | 135,253 rows, 135 MB | 23 s |
| FinOps toolkit FOCUS 1.0 sample, 96 columns | 135,253 rows, 195 MB | 27 s |
| 13 monthly gzip runs of the EA sample rows | 2.6 million rows, about 2.7 GB uncompressed | 250 s |

Real cost rows are wide, so throughput depends on bytes more than rows: about 10 MB of uncompressed CSV a second, or roughly 10,000 real rows a second. A first refresh of 13 months at a million rows a month therefore takes about 20 to 25 minutes. Later refreshes only read new or corrected runs. Partitions are held in memory compressed, so gzip exports keep memory low.

The PowerShell reducer only runs when the host blocks `Add-Type`, for example in Constrained Language Mode. It took 68 s for 200,000 narrow synthetic rows, about seven times slower than the compiled reducer.

## Follow-ups

- Validate the unknowns above with sanitized EA and MCA exports.
- Run a Cost Details source against a live EA and MCA tenant, starting with a narrow month range, and record generation time, link lifetime, and throttling.
- Run the suite on Linux and macOS.
- Faster CSV parsing for wide rows; `TextFieldParser` is the main cost of a first refresh.
- Optional sources: a FinOps hub (Kusto `Costs()` with `BilledCost`) and Parquet exports.
- If the Toolkit wants this feature, move it upstream as its own PR after #2155 merges.
