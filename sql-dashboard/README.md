# SQL Server Health Dashboard

A self-contained web dashboard for checking SQL Server replication and general instance health from a locked-down
jump server: **no installation, no internet, no CDN, no admin rights.**

It uses only what already ships with Windows:

| Piece | Built-in component |
|---|---|
| Local web server + SQL access | Windows PowerShell 5.1 + .NET Framework (`System.Data.SqlClient`) |
| User interface | Microsoft Edge or Google Chrome (plain HTML/CSS/JavaScript, no frameworks) |
| Launcher | `Start-Dashboard.cmd` |

```
sql-dashboard/
├── Start-Dashboard.cmd     double-click to start
├── server.ps1              local web server (127.0.0.1 only) + query runner
├── config.json             instances, checks, thresholds, options
├── checks/*.sql            the health-check queries (read-only)
├── web/                    the dashboard UI (index.html, styles.css, app.js, …)
└── logs/                   created at run time; one log file per day
```

## Quick start

1. Copy the whole `sql-dashboard` folder to the jump server (for example `C:\Tools\sql-dashboard`).
2. Edit `config.json` and list your instances (see below).
3. Double-click **`Start-Dashboard.cmd`**.
   A console window starts the local service and Edge/Chrome opens the dashboard.
4. Pick instances on the left and click **Check Replication Status**, or **Run full health check**.

Keep the console window open while you use the dashboard; close it (or press `Ctrl+C`) to stop.

> **Preview without SQL Server:** open `web/index.html` directly from disk. It runs in **demo mode** with sample data.

## Configuring instances

```json
"instances": [
  { "id": "prod-pub",  "name": "PROD-SQL01",      "server": "PROD-SQL01.corp.local",       "group": "Production", "role": "Publisher" },
  { "id": "prod-dist", "name": "PROD-SQL02\\DIST", "server": "PROD-SQL02.corp.local\\DIST", "group": "Production", "role": "Distributor" },
  { "id": "rpt-sub",   "name": "RPT-SQL01",       "server": "RPT-SQL01.corp.local,1433",   "group": "Reporting",  "role": "Subscriber",
    "auth": "sql", "username": "monitor_ro", "credentialKey": "reporting" }
]
```

| Field | Meaning |
|---|---|
| `id` | Unique key (letters, digits, dashes). |
| `name` | Display name. |
| `server` | Anything SSMS accepts: `host`, `host\instance`, `host,port`, an AG listener. Escape `\` as `\\` in JSON. |
| `group`, `role`, `description` | Optional labels for the sidebar. |
| `auth` | `windows` (default): uses the Windows account running the dashboard, exactly like SSMS with Windows Authentication. `sql`: SQL login. |
| `username`, `credentialKey` | SQL logins only. You are asked for the password **once at start-up**; instances sharing a `credentialKey` share one prompt. Passwords are kept in memory as `SecureString` and never written to disk. |
| `database` | Initial database (default `master`). |
| `encrypt`, `trustServerCertificate`, `multiSubnetFailover`, `connectTimeoutSeconds` | Per-instance overrides of the `connection` section. |

Other settings:

| Section | Setting | Default |
|---|---|---|
| `server` | `port` (tries the next 9 ports if busy), `openBrowser`, `browserAppMode` (opens Edge/Chrome as a clean app window), `maxConcurrentRequests`, `logToFile` | `8765`, `true`, `true`, `12`, `true` |
| `connection` | `connectTimeoutSeconds`, `commandTimeoutSeconds`, `maxRowsPerResultSet`, `encrypt`, `trustServerCertificate`, `applicationName` | `8`, `60`, `5000`, `false`, `true` |
| `ui` | `concurrency` (parallel queries from the browser), `pingOnLoad`, `defaultAutoRefreshMinutes` | `6`, `true`, `0` |

## Built-in checks

| Check | What it reports |
|---|---|
| **Replication Status** | On a **Distributor**: every Log Reader, Distribution and Merge agent with its state, latency, undistributed commands, last message, plus replication errors from the last 24 h. On any instance: published/subscribed databases (flags `log_reuse_wait = REPLICATION`) and subscriber-side subscriptions with last sync time. Run it on the Distributor for agent status. |
| Instance Overview | Version, uptime, CPU, memory, page life expectancy, sessions, blocking. |
| Availability Groups | AG health, replica roles, sync state, send/redo queues, estimated lag. |
| SQL Agent Jobs | Agent service state, failed/retried steps in 24 h, status of every job, long-running jobs. |
| Backup Status | Last full/diff/log backup per database against RPO thresholds. |
| Database Health | State, size, log used %, log reuse wait, risky settings (auto-shrink, page verify). |
| Disk Space | Free space on every volume holding data or log files. |
| Blocking & Long Queries | Head blockers, blocked requests, requests running > 5 min. |
| Top Wait Stats | Top 15 waits since restart (benign waits filtered) with hints. |
| Error Log | Errors/failures in the current error log in the last 24 h. |

Every row gets a **Status** of `OK`, `INFO`, `WARNING` or `CRITICAL`. The dashboard rolls these up per instance and
check, colours the rows, and counts them in the summary tiles. Thresholds are variables at the top of each `.sql` file.
Change them there.

### Adding your own check

1. Put a read-only query in `checks/my-check.sql`. Several result sets and `GO` separators are fine; `PRINT` output is
   shown as a message.
2. Optionally return a column named `Status` with values `OK` / `INFO` / `WARNING` / `CRITICAL` to get colour-coding.
3. Add an entry to `checks` in `config.json`:

```json
{ "id": "my-check", "title": "My Check", "description": "What it does.", "category": "Custom",
  "icon": "database", "file": "checks/my-check.sql", "resultTitles": ["First result set"] }
```

Icons: `replication, server, shield, clock, archive, database, disk, lock, activity, file`. Set `"featured": true` on one
check to put it on the big button (Replication Status by default). SQL files are re-read on every run, so edits take
effect immediately. Changes to `config.json` need a restart.

## Permissions

Grant the account(s) the dashboard connects as a read-only monitoring role, for example:

```sql
USE master;  GRANT VIEW SERVER STATE TO [CORP\dba-team];         -- DMVs (2022+: also VIEW SERVER PERFORMANCE STATE)
             GRANT VIEW ANY DEFINITION TO [CORP\dba-team];
USE msdb;    ALTER ROLE SQLAgentReaderRole ADD MEMBER [CORP\dba-team];   -- needs a user in msdb
             ALTER ROLE db_datareader       ADD MEMBER [CORP\dba-team];   -- backup history
USE distribution;  ALTER ROLE replmonitor ADD MEMBER [CORP\dba-team];     -- on the Distributor
```

Reading the error log needs `securityadmin` (or `sysadmin`). If it's missing, that check shows a message instead of
failing. Any check without the permissions it needs reports the SQL error for that instance only.

## Security

* The service listens on **127.0.0.1 only**, so other machines can't reach it.
* Each start generates a random **session key**, passed to the browser in the URL fragment (never sent over the
  network or logged) and required on every API call. Other users on a shared jump server can't use your session or
  your Windows credentials.
* `Host` and `Origin` headers are validated (blocks DNS rebinding and cross-site requests). A strict Content Security
  Policy forbids external or inline scripts.
* The browser can only choose a configured **instance id** and **check id**. It can never send SQL text. All checks
  are read-only (`READ UNCOMMITTED`, no writes).
* SQL results are rendered as text, never as HTML.
* Every check run is logged to `logs/dashboard-YYYYMMDD.log` (time, check, instance, duration, outcome).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Console flashes and closes / "running scripts is disabled" | The launcher uses `-ExecutionPolicy Bypass` for its own process only. If Group Policy enforces a policy, ask for the folder to be allowed, or sign the script. If the files came from a download or e-mail, right-click each → Properties → **Unblock**, or run `Get-ChildItem -Recurse | Unblock-File` in PowerShell. |
| Page says "Please open this dashboard in Microsoft Edge or Google Chrome" | Internet Explorer is not supported. Copy the address shown in the console (including `#t=…`) into Edge or Chrome. Edge ships with Windows Server 2022/2025 and Windows 10/11. |
| "No session key found" or "session key is no longer valid" | Open the exact address printed in the console. Each restart creates a new key. |
| Instance shows **down** | Same as SSMS: check the server name/port and firewall. The tooltip on the instance shows the full error. |
| "Login failed" with Windows auth | The dashboard runs as the user who started it. Start it as the account you use in SSMS (`runas /user:DOMAIN\admin "cmd /c Start-Dashboard.cmd"`). |
| TLS/certificate errors | Set `"encrypt": true` and `"trustServerCertificate": true` (or false with a trusted certificate) in `connection` or per instance. |
| Port already in use | The service tries the next 9 ports automatically, or set `server.port`. |

Requirements: Windows with PowerShell 5.1 (Windows Server 2016 and later, Windows 10/11; Server 2012 R2 with WMF 5.1),
Edge or Chrome, SQL Server 2012 or later (checks tested on SQL Server 2022 with transactional replication).
