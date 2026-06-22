# SQL Server — Comprehensive Health Check & Diagnostic Guide

Companion documentation for **`SQLServer_HealthCheck_2017.sql`**.

A single, **read-only** T-SQL script that diagnoses an instance end-to-end:
server configuration, backups, transaction logs, integrity, waits, memory,
indexes (usage / missing / fragmentation / duplicates), statistics, expensive
queries, blocking, Agent jobs, security, and TempDB.

> **It makes no changes.** Every query reads from DMVs / system catalogs. The
> only "write-ish" thing it produces is *suggested* `CREATE INDEX` / `ALTER INDEX`
> text for you to review and run manually.

---

## How to run

1. Open `SQLServer_HealthCheck_2017.sql` in **SSMS**.
2. Set results to **Grid** mode — `Ctrl+D`.
3. Run **section by section** (each block is separated by `GO`), or run the whole
   file and read each result grid.
4. For per-database sections, switch context first:

   ```sql
   USE [YourDatabase];
   GO
   ```

### Scope of each section

| Scope | Sections | Note |
|-------|----------|------|
| **Server-wide** (any DB context) | 1–10, 16–20 | Run from `master` or anywhere |
| **Per-database** (current DB only) | **11, 12, 13, 14, 15** | `USE [YourDB]` **first** |

Section 12 contains a commented-out **cursor block** that sweeps fragmentation
across *all* online user databases in one pass.

---

## Section reference

| # | Section | What it answers |
|---|---------|-----------------|
| 1 | Instance / host overview | Version, CU, edition, cores, RAM, uptime, OS memory pressure |
| 2 | `sp_configure` settings | max/min memory, **MAXDOP**, cost threshold, ad-hoc, backup compression; flags pending-restart values |
| 3 | Database settings | Recovery model, compat level, **AUTO_SHRINK / AUTO_CLOSE**, page-verify, RCSI |
| 4 | File sizes & autogrowth | Sizes, free space, flags **percent-growth** & tiny increments |
| 5 | **Backup status** | Last full/diff/log per DB; flags never-backed-up & FULL recovery with no log backup |
| 6 | Transaction log usage | Used %, `log_reuse_wait_desc` (why log won't truncate) |
| 7 | DBCC CHECKDB | Last known-good integrity check (`dbi_dbccLastKnownGood`) |
| 8 | **Wait statistics** | Top resource bottlenecks since restart (benign waits filtered) |
| 9 | Memory / buffer pool | PLE, cache hit ratio, buffer pages per DB |
| 10 | **Missing indexes** | Engine suggestions ranked by impact + ready `CREATE INDEX` text |
| 11 | **Index usage** | Unused (drop candidates) & write-heavy indexes |
| 12 | **Fragmentation** | REORG/REBUILD guidance + generated `ALTER INDEX` text |
| 13 | Heaps | Tables with no clustered index |
| 14 | Duplicate indexes | Exact key-column overlaps (pure overhead) |
| 15 | Stale statistics | Old / heavily-modified stats that cause bad plans |
| 16 | Top expensive queries | By total CPU and by logical reads |
| 17 | Blocking / long-running | Current active requests & blocking chains |
| 18 | Agent job failures | Failed jobs in the last 7 days |
| 19 | Security | sysadmin members; SQL logins with weak policy |
| 20 | TempDB config | File count vs CPUs, equal sizing, autogrowth |

---

## How to read the results

### Configuration (Section 2) — sensible starting points
| Setting | Common recommendation |
|---------|-----------------------|
| `max server memory (MB)` | Leave RAM for the OS (e.g. ~10–20%); never leave at default 2 PB |
| `cost threshold for parallelism` | Raise from default **5** to **~50** on OLTP |
| `max degree of parallelism` | Often = physical cores per NUMA node, capped at 8; **0/1 are rarely right** |
| `optimize for ad hoc workloads` | Usually **1** (reduces plan-cache bloat) |
| `backup compression default` | Usually **1** |

> Any row showing `*** PENDING RESTART ***` has a configured value that differs
> from the running value — it won't take effect until the service restarts.

### Backups (Section 5)
- `*** NEVER BACKED UP ***` → no recoverability. Fix immediately.
- `FULL recovery but no recent LOG backup` → the log file **will grow forever**
  until you either run log backups or switch to SIMPLE recovery.

### Wait stats (Section 8)
Common signals:
| Wait type | Typical meaning |
|-----------|-----------------|
| `PAGEIOLATCH_*` | Slow storage **or** under-indexing (reading too much from disk) |
| `CXPACKET` / `CXCONSUMER` | Parallelism — revisit MAXDOP / cost threshold |
| `LCK_M_*` | Blocking / locking contention |
| `WRITELOG` | Log write latency (slow log disk) |
| `RESOURCE_SEMAPHORE` | Memory grant pressure |
| `SOS_SCHEDULER_YIELD` | CPU pressure |

High `SignalWait_s` relative to total wait = **CPU pressure** (tasks ready but waiting for a scheduler).

### Indexes
- **Missing (10):** these are *hints*, not orders. **Consolidate** overlapping
  suggestions, mind column order (equality → inequality → include), and never
  apply all of them blindly.
- **Usage (11):** `*** UNUSED ***` = reads of 0 with writes > 0. Safe drop
  candidates — but confirm against **uptime** (stats reset on restart) and
  watch for month-end / reporting workloads.
- **Fragmentation (12):**
  - 5–30 % → `REORGANIZE`
  - \> 30 % → `REBUILD`
  - Ignores indexes < 1000 pages (fragmentation is irrelevant at small sizes).

### Statistics (15)
Stale or heavily-modified statistics cause the optimizer to pick bad plans even
when indexes are fine. Update with `UPDATE STATISTICS` / `sp_updatestats`.

---

## Caveats

- **Stats reset on restart.** Index-usage (11), wait stats (8) and query stats
  (16) accumulate only since the last service restart — compare against the
  uptime in Section 1 before drawing conclusions.
- **Plan cache is volatile.** Section 16 only sees queries currently cached;
  memory pressure or recompiles can evict them. For historical analysis enable
  **Query Store** per database.
- **`READ UNCOMMITTED`** is set so the script never blocks the server; it may
  read in-flight values for the activity sections — that's intentional and fine
  for diagnostics.
- **Permissions:** needs `VIEW SERVER STATE`, plus access to `msdb` (backups,
  Agent jobs) and the target user databases.

---

## Suggested cadence

| Frequency | Sections |
|-----------|----------|
| **Daily** | 5 (backups), 18 (job failures), 7 (CHECKDB), 17 (blocking) |
| **Weekly** | 8 (waits), 11–12 (index usage/fragmentation), 15 (stats), 16 (top queries) |
| **On change / quarterly** | 1–4 (config & files), 19 (security), 20 (TempDB) |

---

## Remediation is manual by design

The script **diagnoses**; it does not auto-fix. For ongoing maintenance
(index/stats), the community-standard tool is **Ola Hallengren's Maintenance
Solution** (`IndexOptimize`), which handles REORG/REBUILD thresholds and stats
updates safely. The generated `ALTER INDEX` statements in Section 12 are for
one-off, reviewed fixes.

---

*Generated for SQL Server 2017 (compatibility level 140). Most sections also run
on SQL Server 2016+; 2019/2022-only settings are referenced harmlessly where noted.*
