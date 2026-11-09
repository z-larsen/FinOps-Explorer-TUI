# Sample scan export

A complete report set from one FinOps Explorer TUI run, so you can see the output format
without running a scan first.

**The data is synthetic.** Subscriptions, resource names, tags, costs, and
contacts are fabricated for demonstration. No Azure environment was queried to
produce these files, and nothing here reflects a real tenant.

| File | What it is |
| ---- | ---------- |
| `FinOpsReport.html` | The full report: FinOps story, scan status, KPI reference, and every result table. Open it in a browser. |
| `ScanSummary.txt` | Plain-text summary of the same run. |
| `Get-*.csv` | One CSV per scan. Failed or empty scans still get a row carrying their status. |

Each run writes its own folder on the machine running the tool, under your local
application data directory. Reports are never uploaded anywhere by FinOps Explorer.
See [Reports and privacy](../../README.md#reports-and-privacy).

These are scan outputs, not forecast reports. For the separate pre-credit
forecast and workload-growth outputs, see the [forecast usage guide](../../docs/forecast.md#outputs).
