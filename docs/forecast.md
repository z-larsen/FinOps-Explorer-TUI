# Pre-credit forecast and workload growth

FinOps Explorer can forecast a fiscal year of Azure spend from your own Cost Management exports. You get actuals to date plus the rest of the year, a central estimate, and a low-to-high sensitivity range. It also shows which workloads drove the growth.

All amounts are **pre-credit**: what Cost Management reports before Azure credits and Azure Prepayment are applied. That's `CostInBillingCurrency` (EA), `costInBillingCurrency` (MCA), or `BilledCost` (FOCUS). Negotiated discounts are included and list prices aren't used. Marketplace and tax are excluded by default.

The forecast only reads Azure data. It never creates exports, changes permissions, or provisions anything. The one request it sends is with a Cost Details source, which asks Cost Management to generate a temporary report.

For the design, method details, and test coverage, see [forecast-design.md](forecast-design.md).

## What you need

- PowerShell 7 and the same Az modules FinOps Explorer uses.
- Cost Management exports of **actual cost** or **FOCUS** data in CSV format (gzip is fine). Amortized exports are rejected because they spread purchases instead of showing what was billed; that includes an amortized file with no manifest, which is recognized from its content. Parquet isn't read.
- At least **12 complete months** of history for a forecast that can be marked Ready. With 3 to 11 months you get a **Preliminary** forecast (see [Short history](#short-history-preliminary-forecasts)). The portal can backfill exports up to 13 months one month at a time; the [Exports Execute REST API](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-improved-exports) goes back further. Set those up yourself; the forecast won't create them.
- **Storage Blob Data Reader** on the storage account the exports deliver to. A local copy of the export container (same folder layout, for example from AzCopy) works too, with no Azure access at all.

No exports? If you have Cost Management read access at a subscription or billing scope, add a [Cost Details source](#read-cost-management-directly-cost-details) and the forecast requests the reports itself. Otherwise, switch the workspace to **manual inputs** and type in monthly totals from invoices.

## Start it

From PowerShell 7, in the folder where you extracted FinOps Explorer, run `Start-FinOpsExplorer` and pick **2 Pre-credit forecast and workload growth** at the first prompt, or start the forecast directly:

```powershell
Import-Module .\FinOpsToolkit.psm1
Start-FinOpsForecast
```

Explorer runs started with `-NonInteractive`, `-Scans`, or `-DataSource` skip that prompt and behave as before.

### Guided setup

Without a workspace name, the forecast signs you in first, using the same tenant and subscription picker as Explorer's scans: you choose a tenant by name, then its subscriptions. If your saved Azure sign-in has expired, or the tenant asks for MFA again, you're asked to sign in again first; Explorer doesn't fall back to an unnamed tenant or report that there are no subscriptions. It then opens a workspace named after the tenant's domain, such as `contoso` for contoso.onmicrosoft.com, so one customer's saved forecasts and review decisions never mix with another's. You can accept the name or type another.

A new workspace goes straight into a few questions:

1. **How many months of history**: 3 to 36. Twelve months can give a Ready forecast; fewer gives a Preliminary one. Live reads reach back 12 months, so choosing them with a longer history uses 12.
2. **The fiscal year's first month.** If the fiscal year started before the lookback window, the history also reaches back to its first month, because those months are actuals in the year's total.
3. **Where the history comes from.** A screen first sums up how the forecast is built and ranks the ways to read these months by how long they'd take; see [How long reading the history takes](#how-long-reading-the-history-takes). Then you choose:
   - **Live from Cost Management**, using your sign-in. No exports are needed; see [Cost Details](#read-cost-management-directly-cost-details).
   - **Exports**: find them for the selected subscriptions and the management groups and billing accounts above them, name a storage account, or point at a local copy.
   - **Monthly totals** you type in.

It then saves the settings and offers to refresh right away. For live reads, it says how many reports the first refresh requests and roughly how long they'll take.

For live reads of up to three subscriptions, each subscription gets one report per month. With more, guided setup looks for the one EA or MCA billing account that owns all of them before it shows the time estimates, so they say whether that account is open to you. If it is and you read live, it offers to read there, so one set of weekly reports covers every subscription; the default is whichever the estimates say is faster. Reading at a billing account needs a billing reader role. If the subscriptions belong to more than one account, or this sign-in can't confirm the owner of each, each subscription is read separately.

Live sources follow the forecast period: their first month is **AUTO**, so changing the lookback or fiscal year in **3 Period** changes what the next refresh reads.

Run it again any time with **G** on the review page. It replaces the source, scope, history length, and fiscal year. Assumptions, scheduled items, workloads, review decisions, and saved forecasts are kept. Opening a workspace that's already set up asks whether to open it or set it up again.

To pick the workspace yourself, name it with `Start-FinOpsForecast -WorkspaceName contoso-fy27`. An empty named workspace also starts guided setup. Non-interactive runs and runs with `-ConfigPath` use the `default` workspace unless you name one.

A workspace keeps settings, review decisions, cached export history, and saved forecasts under `FinOpsToolkit\Explorer\Forecast\<name>` in your local application data, readable only by you.

## How long reading the history takes

Most of a first refresh is spent waiting while Cost Management builds each live report, one at a time. The number of reports matters far more than your machine or network. Guided setup shows the ways to read ranked fastest first for your subscriptions and months, and **H** on the review page shows them again, marking the one the workspace uses.

| Way to read | First read | Each later refresh | Needs |
|---|---|---|---|
| Exports | Usually minutes, depending on file size | Only new export files | Exports that already cover the months, and Storage Blob Data Reader or a local copy |
| Live, at the billing account | About 5 weekly reports a month | 5 to 10 reports | An EA or MCA billing reader role on the one account that owns every subscription |
| Live, each subscription | One report per subscription a month | 1 to 2 reports per subscription | Cost Management Reader on each subscription (EA or MCA only) |

The estimates assume about 35 seconds for a subscription's monthly report, measured on a live tenant, and about a minute for a billing account's weekly report, which covers every subscription. They're rough: large subscriptions take longer, and throttling adds pauses. For example, 124 subscriptions with 4 months of history plus this month need 620 reports read one subscription at a time (about 6 hours), or 22 at the billing account (about 20 minutes). The billing account is only offered for more than three subscriptions; below that, reading each one is faster.

With more than 3 months of history, the screen recommends exports if they already cover the months, then the fastest live read you can use. To make a first read faster:

- Use exports the customer already has.
- Ask for an EA or MCA billing reader role, so one set of reports covers every subscription.
- Select only the subscriptions that matter for the forecast.
- Choose fewer months of history. Three is the minimum, and gives a Preliminary forecast.

Later refreshes keep every finished month. They read this month, and last month until it's final a few days after it ends. Leave the window open during a refresh. If a refresh fails partway, the months it read completely are kept and the next refresh carries on.

## The Setup & Review page

Everything happens on one page. Each line shows a status: **OK**, **CHECK** (a warning you should read), or **NEEDS ACTION** (blocks Ready).

| Section | What you set or check |
|---|---|
| 1 Source | Export locations (discover in Azure, enter a storage path, or a local folder), live Cost Details reports, the EA-to-MCA migration date, or a switch to manual inputs |
| 2 Scope | Selected subscriptions, or an MCA billing profile (its EA history before the migration is included for the same subscriptions) |
| 3 Period | Fiscal-year start month, current or next fiscal year, lookback length, finalization grace days, stale-data age |
| 4 Assumptions | Growth method settings, Marketplace and tax filters, workload mode and mapping, scheduled purchases, renewals, and business changes |
| 5 Exceptions | Everything that needs a human decision |
| 6 Reconciliation | Each month's raw export total against what was included and excluded |
| 7 Refresh | Refresh history; refresh now |

Other keys: **R** refresh, **W** workloads, **F** forecast and save, **P** preview report, **I** manual inputs, **G** guided setup, **H** how the forecast works and how long reading takes, **Q** quit.

After guided setup, a typical first run is:

1. **R** to read the history, if you didn't refresh during setup. Later refreshes only read what's new or changed.
2. **5 Exceptions**: work through anything marked REQUIRED.
3. **F** to save the forecast. It's only saved when the status is **READY**.

To set things up by hand instead, use **1 Source**: press **D** to discover exports, **A**/**L** to add a location, or **C** to add a Cost Details scope. If the history spans an EA-to-MCA move, press **T** there and enter the transition date. Then pick the scope in **2 Scope** and the fiscal year in **3 Period**.

## Short history: Preliminary forecasts

With 3 to 11 months of history, the forecast runs the same method on the months you have and marks the result **Preliminary**. The status line shows it in yellow, every report says so, and the method disclosure explains it. A Preliminary forecast can't be saved as a vintage; use **P** for a preview report.

Treat it as an early indication, not a number to commit to. N months give N − 1 month-to-month changes, so 3 months estimate growth from just 2 changes, and the range reflects only those. The minimum number of retained comparisons scales with the history, keeping the 8-of-11 share of a 12-month lookback. Raise the lookback to 12 in **3 Period** once enough months exist, and the same workspace can become Ready. A live source with its first month set to **AUTO** reads the extra months on the next refresh.

A short lookback doesn't shorten the fiscal year. Months of the fiscal year before the lookback window still count as actuals in the total, so they need data too. Until they have it, the **Fiscal-year actuals before the lookback** check fails, rather than counting them as zero.

## Read Cost Management directly (Cost Details)

When nobody has set up exports, or you can't reach the files, a **Cost Details** source asks Cost Management for ActualCost reports through the [Cost Details API](https://learn.microsoft.com/azure/cost-management-billing/automate/get-small-usage-datasets-on-demand). The reports have the same EA or MCA columns as an actual-cost export, so everything after the read (checks, reviews, reconciliation, the forecast) works the same way.

**Access.** You need Cost Management read access at the scope, such as Cost Management Reader at a subscription, or an EA or MCA billing reader role at a billing scope. On EA, the enrollment's charges-visibility setting must be on. Azure Reader on its own may not show costs. A quick test: if Cost analysis shows actual costs at that scope in the portal, the source should work.

**Scopes.** A subscription (`/subscriptions/<id>`), an EA enrollment, department, or enrollment account, or an MCA billing account, billing profile, invoice section, or customer (`/providers/Microsoft.Billing/billingAccounts/<id>/...`). Management groups and resource groups aren't supported by the API. Only EA and MCA agreements work; pay-as-you-go and Visual Studio subscriptions don't.

**How far back.** The API reaches 13 months. With **First month** set to **AUTO**, the default, the source requests what the forecast period needs: from the start of the lookback window, or from the fiscal year's first month if that's earlier, plus the current month through yesterday. Set **First month** to a month (yyyy-MM) to fix it, or to NONE to request every whole month the API can still reach. **Last month** narrows the end. A 12-month lookback needs 12 complete months, which the API can return. In the first few days of a month, until last month passes the grace period, the forecast window still starts one month further back than the API can reach. Months an earlier refresh already read are kept for that reason, so refresh at least once a month. A workspace whose very first refresh lands in those days is a month short until the grace period passes. Older history needs exports.

**After an EA-to-MCA move**, EA history stays in the EA enrollment and MCA history starts in the billing profile. Add one source for each, set **T** to the transition date, and give the EA source a last month and the MCA source a first month around it. See [the sample config](../samples/forecast/forecast-config.costdetails.sample.json). Each side needs its own access: a subscription that moved to MCA usually shows only its MCA costs at subscription scope.

**Large scopes.** Each report covers a week by default. Microsoft recommends day or week chunks, and Exports, above roughly 2 GB or 2 million rows a month. For a month that size, a first refresh means about 65 report requests and several gigabytes of downloads, and can take an hour. Set **Days per report** to 1 if a single week's report is too large to hold in memory.

**What's cached.** A month read at least the grace period after it closed is kept and never requested again. The current month and newly closed months are requested again on later refreshes, but not more than once every four hours, since Cost Management only refreshes these reports about that often. If a chunk fails, its month stays out until the next refresh reads it. If a refresh stops partway, months it already read completely are kept, so the next refresh carries on.

**Settle the boundary and tag key first.** Cached months depend on the migration boundary, the workload tag key, and the source's own scope and schema. Adding or changing other sources doesn't affect them. Changing those four means every month is read again, but months already beyond the API's reach can't be. The refresh warns and lists any months it had to drop, so set them before the first Cost Details refresh.

**Charge dates.** Learn describes this data as tied to when the billing system received a cost, so a month's report can include a charge dated in the month before. Those rows aren't counted twice or moved; they show as CHECK on the Source line and as `ExcludedOutsideRange` in reconciliation, like any export row outside its run's dates.

**What it sends.** One POST per chunk, to `generateCostDetailsReport` at your scope; it creates a temporary report, not an Azure resource. Then it polls the status link Cost Management returns, after checking it's on your cloud's Resource Manager endpoint and for the same scope. Report files come back as short-lived download links. They're fetched over HTTPS from your cloud's blob storage, without your Azure token or redirects. The links are never written to the console, the workspace, or reports.

## Review decisions

The forecast doesn't guess when the data is ambiguous. It asks, records your answer with a reason, and asks again if the underlying data changes later.

Manual-month approvals include the billing currency. Changing it reopens every
month for review; existing approvals saved before this check also need to be
confirmed once. No currency conversion is performed.

| Exception | Your choice |
|---|---|
| Anomalous month-to-month change | Retain, Exclude from growth, or Step change (a new level that held). Check what happened first; actual charges always stay in actuals. A drop back to the trend right after a spike is suggested as Exclude, not Step change. |
| Undefined change (previous month was zero or negative) | Acknowledge; it's left out of growth estimation. |
| Anomalous latest month | Baseline from the latest month, the median of the last three, or a manual value with a reason. |
| Unclassified publisher | Treat rows from non-Microsoft publishers as Marketplace or Microsoft. EA exports label every row `Azure`, so this comes up for EA. The decision covers the publisher names it lists; new rows from those publishers keep it, and a new publisher reopens it. |
| Overlapping export scopes | Pick which export to keep when two carry the same subscription and month. Charges without a subscription, such as a shared savings plan purchase, follow the same choice by billing profile. |
| Recurring purchase not scheduled | Add a scheduled item, or confirm it won't recur. |
| Legacy export file without a manifest | Approve only if you've confirmed it's the complete actual-cost export for the month. Its rows must reach the month's last day even when its folder name describes a whole month. Matching filenames in different sources are reviewed separately. |
| Positive refund rows, unknown charge types, boundary exclusions | Acknowledge after checking. |

## Scheduled items

Purchases and refunds aren't grown with the run rate, so future commitments come only from scheduled items. Each has a unique ID, a start month, and a recurrence (one-time, monthly, or annual). It also has a treatment:

- **Additive**: adds the amount.
- **AlreadyInBaseline**: adds nothing, because the run rate already includes it.
- **ReplacesBaselineAmount**: adds the amount minus the part of the baseline it replaces.

If an item covers an existing reservation or savings plan, give its commitment ID (the order ID or the full resource ID). Then, when that purchase has already posted in the current month, the item isn't added on top of the month-to-date actuals; the monthly CSV shows it under `ScheduledAlreadyPosted`. A refund for the same commitment does not mean the purchase has posted. A Purchase or Renewal item without a commitment ID gets a note in any current month where purchases have already posted, so you can check it isn't counted twice.

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

It refreshes, writes reports, and saves a vintage if the forecast is Ready. If it isn't, the reports are labeled **NotReady**, or **Preliminary** for a lookback under 12 months. No vintage is saved, and a non-terminating error lists the failing checks or explains the short history. `-ConfigPath` loads settings from JSON first; see [the sample config](../samples/forecast/forecast-config.sample.json).

## Reading the numbers

- **Central estimate** uses the median month-over-month change in run rate.
- **Sensitivity range** uses the 25th to 75th percentile of historical changes. It shows how much the history varied. It is **not** a confidence interval.
- **Custom percentiles** must satisfy `0 <= low < 50 < high <= 100`, so the range brackets the central median. This is checked for JSON settings as well as console edits.
- **Fiscal-year totals** add completed months, this month's actuals so far plus the rest of the month, the remaining forecast months, and scheduled items. Low and high each follow one growth path for the whole year.
- **Month-to-date coverage** comes from the verified run range, bounded by when the run was submitted. Days with no charges aren't forecast again. If selected runs have different coverage cutoffs, Ready is blocked until a refresh brings them into line.
- **Partial population** means a subscription in scope is missing data in some months. **Stale data** means the last refresh failed or the newest data is old. Both appear on every output.
- **Invalid pinned windows** block Ready and saving a vintage. The preview can use the latest eligible month, but the settings check explains why the requested window was rejected.
- **Zero and missing amounts** look different in HTML: a measured zero is `0.00`; a missing amount is blank. Table paging keeps keyboard focus on an enabled navigation button.

## Limits to know

- Learn doesn't say whether refund rows are negative; signs are kept as exported and positive refunds are flagged.
- `RoundingAdjustment` rows only appear at billing scope after an invoice, so subscription-scoped months can differ slightly from invoices.
- Cost data can change for up to 72 hours after a month ends. A month counts as final only when a whole-month run was submitted after the grace period (3 days by default).
- A run that starts after the first of a month never replaces that month's whole-month run; it shows as CHECK on the Source line. A month covered only by a run still in progress stays provisional.
- Rows dated outside a run's own start and end dates aren't counted, even when they fall in the same month. They show as CHECK on the Source line and as `ExcludedOutsideRange` in reconciliation. Their raw costs and row counts remain in the reconciliation totals.
- A manifest that lists the same partition twice is rejected, not counted twice. Identical legitimate charge rows within distinct partitions are still kept.
- A final month whose last charge precedes month end shows as CHECK on the Source line, in case the export didn't cover the whole month.
- If an already cached run becomes unreadable or invalid, refresh fails and keeps the last good cache, labeled Stale data.
- For local copies, updated files must have updated modification times. An in-place change preserving both size and modification time can't be detected from the listing. Changing source settings or ingestion rules requires a refresh.
- Reconciliation ignores differences under 0.000001, which come from decimal rounding of very long amounts.
- A first refresh reads about 10 MB of uncompressed CSV a second, roughly 10,000 real cost rows. Thirteen months at a million rows a month takes about 20 to 25 minutes the first time; later refreshes only read new runs. Cost Details sources also wait for each report to be generated.
- Cost Details reads at subscription scope have run against a live tenant, which is where the 35-second estimate comes from. Billing-scope reads haven't been timed on a live tenant yet. The tests use a synthetic API that follows the documented contract.
- Windows is the verified platform. The code is cross-platform, but Linux and macOS haven't been tested.

## Tests

```powershell
.\scripts\Invoke-ForecastTests.ps1
```

The suite uses synthetic data only and needs no Azure access. Add `-ToolkitRoot <path>` to include the Toolkit parity check, or `-Reducer PowerShell` to run it on the PowerShell fallback.
