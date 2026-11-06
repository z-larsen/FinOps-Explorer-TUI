# Pre-credit forecast and workload growth

FinOps Explorer can forecast a fiscal year of Azure spend from your own Cost Management exports. You get actuals to date plus the rest of the year, a central estimate, and a low-to-high sensitivity range. It also shows which workloads drove the growth.

All amounts are **pre-credit**: what Cost Management reports before Azure credits and Azure Prepayment are applied. That's `CostInBillingCurrency` (EA), `costInBillingCurrency` (MCA), or `BilledCost` (FOCUS). Negotiated discounts are included and list prices aren't used. Marketplace and tax are excluded by default.

The forecast only reads Azure data. It never creates exports, changes permissions, or provisions anything.

For the design, method details, and test coverage, see [forecast-design.md](forecast-design.md).

## What you need

- PowerShell 7 and the same Az modules FinOps Explorer uses.
- Cost Management exports of **actual cost** or **FOCUS** data in CSV format (gzip is fine). Amortized exports are rejected because they spread purchases instead of showing what was billed; that includes an amortized file with no manifest, which is recognized from its content. Parquet isn't read.
- At least **12 complete months** of history. The portal can backfill up to 13 months one month at a time; the [Exports Execute REST API](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-improved-exports) goes back further. Set those up yourself; the forecast won't create them.
- **Storage Blob Data Reader** on the storage account the exports deliver to. A local copy of the export container (same folder layout, for example from AzCopy) works too, with no Azure access at all.

No exports? Switch the workspace to **manual inputs** and type in monthly totals from invoices instead.

## Start it

From PowerShell 7, in the folder where you extracted FinOps Explorer:

```powershell
Import-Module .\FinOpsToolkit.psm1
Start-FinOpsForecast -WorkspaceName contoso-fy27
```

You can also run `Start-FinOpsExplorer` and pick **2 Pre-credit forecast and workload growth** at the first prompt. Explorer runs started with `-NonInteractive`, `-Scans`, or `-DataSource` skip that prompt and behave as before.

Use one workspace per customer or scope. A workspace keeps settings, review decisions, cached export history, and saved forecasts under `FinOpsToolkit\Explorer\Forecast\<name>` in your local application data, readable only by you.

## The Setup & Review page

Everything happens on one page. Each line shows a status: **OK**, **CHECK** (a warning you should read), or **NEEDS ACTION** (blocks Ready).

| Section | What you set or check |
|---|---|
| 1 Source | Export locations (discover in Azure, enter a storage path, or a local folder), the EA-to-MCA migration date, or a switch to manual inputs |
| 2 Scope | Selected subscriptions, or an MCA billing profile (its EA history before the migration is included for the same subscriptions) |
| 3 Period | Fiscal-year start month, current or next fiscal year, lookback length, finalization grace days, stale-data age |
| 4 Assumptions | Growth method settings, Marketplace and tax filters, workload mode and mapping, scheduled purchases, renewals, and business changes |
| 5 Exceptions | Everything that needs a human decision |
| 6 Reconciliation | Each month's raw export total against what was included and excluded |
| 7 Refresh | Refresh history; refresh now |

Other keys: **R** refresh, **W** workloads, **F** forecast and save, **P** preview report, **I** manual inputs, **Q** quit.

A typical first run:

1. **1 Source**: press **D** to discover exports, or **A**/**L** to add a location. If the history spans an EA-to-MCA move, press **T** and enter the transition date.
2. **2 Scope**: pick subscriptions or enter the billing profile ID.
3. **3 Period**: set the fiscal-year start month.
4. **R** to read the exports. Later refreshes only read runs that are new or changed.
5. **5 Exceptions**: work through anything marked REQUIRED.
6. **F** to save the forecast. It's only saved when the status is **READY**.

## Review decisions

The forecast doesn't guess when the data is ambiguous. It asks, records your answer with a reason, and asks again if the underlying data changes later.

| Exception | Your choice |
|---|---|
| Anomalous month-to-month change | Retain, Exclude from growth, or Step change (a new level that held). Check what happened first; actual charges always stay in actuals. A drop back to the trend right after a spike is suggested as Exclude, not Step change. |
| Undefined change (previous month was zero or negative) | Acknowledge; it's left out of growth estimation. |
| Anomalous latest month | Baseline from the latest month, the median of the last three, or a manual value with a reason. |
| Unclassified publisher | Treat rows from non-Microsoft publishers as Marketplace or Microsoft. EA exports label every row `Azure`, so this comes up for EA. The decision covers the publisher names it lists; new rows from those publishers keep it, and a new publisher reopens it. |
| Overlapping export scopes | Pick which export to keep when two carry the same subscription and month. Charges without a subscription, such as a shared savings plan purchase, follow the same choice by billing profile. |
| Recurring purchase not scheduled | Add a scheduled item, or confirm it won't recur. |
| Legacy export file without a manifest | Approve only if you've confirmed it's the complete actual-cost export for the month. It counts as a whole month only if its rows reach the month's last day. |
| Positive refund rows, unknown charge types, boundary exclusions | Acknowledge after checking. |

## Scheduled items

Purchases and refunds aren't grown with the run rate, so future commitments come only from scheduled items. Each has a unique ID, a start month, and a recurrence (one-time, monthly, or annual). It also has a treatment:

- **Additive**: adds the amount.
- **AlreadyInBaseline**: adds nothing, because the run rate already includes it.
- **ReplacesBaselineAmount**: adds the amount minus the part of the baseline it replaces.

If an item covers an existing reservation or savings plan, give its commitment ID (the order ID or the full resource ID). Then, when that purchase has already posted in the current month, the item isn't added on top of the month-to-date actuals; the monthly CSV shows it under `ScheduledAlreadyPosted`. A Purchase or Renewal item without a commitment ID gets a note in any current month where purchases have already posted, so you can check it isn't counted twice.

## Workloads

Workloads are grouped by a tag (the default, key `workload`), a resource group, or a subscription. A mapping CSV can give stable IDs and names and merge renamed tags. See [the sample](../samples/forecast/workload-mapping.sample.csv).

For each workload you see:

- The change in 30-day run rate across the lookback, and the percentage growth.
- Its share of the net change.
- The month and amount of its largest month-over-month increase.
- Flags for New, Retired, Moved, and Unmapped.

When two workloads have the same display name, such as two subscriptions both called Pay-As-You-Go, a short ID is added in brackets so you can tell them apart.

You can rank by change, spend, growth, or largest increase. Every workload is listed; nothing is cut off at a top-N.

## Outputs

**F** and **P** write a new private folder under `FinOpsToolkit\Explorer\Reports` with:

- `forecast-report.html`: the whole forecast with filterable tables and the method disclosure.
- `forecast-summary.txt`: headline numbers, checks, and the method.
- CSVs for the fiscal-year months, history, comparisons, checks, reviews, reconciliation, provenance (which export run fed each month), workloads, purchases, and the backtest.

**F** also saves a **vintage**, a frozen copy of the forecast and the decisions behind it, so later forecasts can be compared with earlier ones. Vintages are never overwritten.

## Run without prompts

Record review decisions interactively first, then:

```powershell
Start-FinOpsForecast -WorkspaceName contoso-fy27 -NonInteractive
```

It refreshes, writes reports, and saves a vintage if the forecast is Ready. If it isn't, the reports are labeled **NotReady**, no vintage is saved, and a non-terminating error lists the failing checks. `-ConfigPath` loads settings from JSON first; see [the sample config](../samples/forecast/forecast-config.sample.json).

## Reading the numbers

- **Central estimate** uses the median month-over-month change in run rate.
- **Sensitivity range** uses the 25th to 75th percentile of historical changes. It shows how much the history varied. It is **not** a confidence interval.
- **Fiscal-year totals** add completed months, this month's actuals so far plus the rest of the month, the remaining forecast months, and scheduled items. Low and high each follow one growth path for the whole year.
- **Partial population** means a subscription in scope is missing data in some months. **Stale data** means the last refresh failed or the newest data is old. Both appear on every output.

## Limits to know

- Learn doesn't say whether refund rows are negative; signs are kept as exported and positive refunds are flagged.
- `RoundingAdjustment` rows only appear at billing scope after an invoice, so subscription-scoped months can differ slightly from invoices.
- Cost data can change for up to 72 hours after a month ends. A month counts as final only when a whole-month run was submitted after the grace period (3 days by default).
- A run that starts after the first of a month never replaces that month's whole-month run; it shows as CHECK on the Source line. A month covered only by a run still in progress stays provisional.
- Rows dated outside a run's own start and end dates aren't counted. They show as CHECK on the Source line and as `ExcludedOutsideRange` in the reconciliation CSV.
- A final month whose data ends before the month does shows as CHECK on the Source line, in case the export didn't cover the whole month.
- Reconciliation ignores differences under 0.000001, which come from decimal rounding of very long amounts.
- A first refresh reads about 10 MB of uncompressed CSV a second, roughly 10,000 real cost rows. Thirteen months at a million rows a month takes about 20 to 25 minutes the first time; later refreshes only read new runs.
- Windows is the verified platform. The code is cross-platform, but Linux and macOS haven't been tested.

## Tests

```powershell
.\scripts\Invoke-ForecastTests.ps1
```

The suite uses synthetic data only and needs no Azure access. Add `-ToolkitRoot <path>` to include the Toolkit parity check, or `-Reducer PowerShell` to run it on the PowerShell fallback.
