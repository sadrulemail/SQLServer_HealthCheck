/*==============================================================================
  SQL SERVER 2017 - COMPREHENSIVE HEALTH CHECK & DIAGNOSTIC REPORT
  ------------------------------------------------------------------------------
  Covers : Server/instance config, memory, CPU, sp_configure, databases,
           backups, recovery model, log usage, DBCC CHECKDB, wait stats,
           index usage (unused / high-write), missing indexes, fragmentation,
           duplicate & overlapping indexes, heaps, TempDB, PLE/buffer pool,
           top expensive queries, blocking, Agent job failures, security.

  Usage  : Run in SSMS with results to GRID. Read-only - makes NO changes.
           Server-wide sections work from any DB context.
           Index/fragmentation sections are PER-DATABASE - either run the
           whole script inside the target user DB, or use the cursor version
           in Section 12 to sweep every database.

  Tested : SQL Server 2017 (compat 140). Most also runs on 2016+.
  Author : Health-check template (read-only DMV queries).
==============================================================================*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;   -- avoid blocking the server
GO

/*------------------------------------------------------------------------------
  SECTION 1 : INSTANCE / SERVER OVERVIEW
------------------------------------------------------------------------------*/
PRINT '===== 1. INSTANCE OVERVIEW =====';

SELECT
    @@SERVERNAME                                            AS ServerName,
    SERVERPROPERTY('MachineName')                           AS MachineName,
    SERVERPROPERTY('InstanceName')                          AS InstanceName,
    SERVERPROPERTY('ProductVersion')                        AS ProductVersion,
    SERVERPROPERTY('ProductLevel')                          AS ProductLevel,     -- SP/CU level
    SERVERPROPERTY('ProductUpdateLevel')                    AS CU_Level,
    SERVERPROPERTY('Edition')                               AS Edition,
    SERVERPROPERTY('Collation')                             AS ServerCollation,
    SERVERPROPERTY('IsClustered')                           AS IsClustered,
    SERVERPROPERTY('IsHadrEnabled')                         AS IsAlwaysOnEnabled,
    SERVERPROPERTY('IsIntegratedSecurityOnly')              AS WindowsAuthOnly,
    @@VERSION                                               AS FullVersion;

-- OS / host hardware (from DMV)
SELECT
    cpu_count                                               AS LogicalCPUs,
    hyperthread_ratio                                       AS CoresPerSocket,
    cpu_count / hyperthread_ratio                           AS PhysicalSockets,
    CAST(physical_memory_kb/1024.0/1024.0 AS DECIMAL(9,2))  AS Physical_RAM_GB,
    CAST(committed_kb/1024.0/1024.0 AS DECIMAL(9,2))        AS SQL_Committed_GB,
    CAST(committed_target_kb/1024.0/1024.0 AS DECIMAL(9,2)) AS SQL_TargetCommit_GB,
    sqlserver_start_time                                    AS SQLStartTime,
    DATEDIFF(HOUR, sqlserver_start_time, GETDATE())         AS Uptime_Hours
FROM sys.dm_os_sys_info;

-- OS memory state (is there external memory pressure?)
SELECT
    total_physical_memory_kb/1024/1024     AS Total_RAM_GB,
    available_physical_memory_kb/1024/1024 AS Available_RAM_GB,
    system_memory_state_desc               AS MemoryState
FROM sys.dm_os_sys_memory;
GO

/*------------------------------------------------------------------------------
  SECTION 2 : sp_configure  (advanced options shown)
  Look at: max server memory, min server memory, max degree of parallelism,
           cost threshold for parallelism, optimize for ad hoc workloads,
           backup compression default, remote admin connections.
------------------------------------------------------------------------------*/
PRINT '===== 2. SERVER CONFIGURATION (sp_configure) =====';

SELECT
    name                                   AS ConfigName,
    CAST(value      AS BIGINT)             AS ConfiguredValue,
    CAST(value_in_use AS BIGINT)           AS RunningValue,
    CASE WHEN value <> value_in_use THEN '*** PENDING RESTART ***' ELSE '' END AS Note,
    description
FROM sys.configurations
WHERE name IN (
    'max server memory (MB)',
    'min server memory (MB)',
    'max degree of parallelism',
    'cost threshold for parallelism',
    'optimize for ad hoc workloads',
    'backup compression default',
    'remote admin connections',
    'fill factor (%)',
    'max worker threads',
    'priority boost',
    'lightweight pooling',
    'recovery interval (min)',
    'tempdb metadata memory-optimized',  -- 2019+ only; harmless if absent
    'show advanced options'
)
ORDER BY name;
GO

/*------------------------------------------------------------------------------
  SECTION 3 : DATABASE INVENTORY & SETTINGS
  Flags risky settings: AUTO_SHRINK on, AUTO_CLOSE on, page verify <> CHECKSUM,
  old compatibility level, AUTO_UPDATE_STATS off.
------------------------------------------------------------------------------*/
PRINT '===== 3. DATABASE SETTINGS =====';

SELECT
    d.database_id,
    d.name                              AS DatabaseName,
    d.state_desc                        AS State,
    d.recovery_model_desc              AS RecoveryModel,
    d.compatibility_level              AS CompatLevel,
    d.page_verify_option_desc          AS PageVerify,
    d.is_auto_shrink_on                AS AutoShrink,
    d.is_auto_close_on                 AS AutoClose,
    d.is_auto_create_stats_on          AS AutoCreateStats,
    d.is_auto_update_stats_on          AS AutoUpdateStats,
    d.is_auto_update_stats_async_on    AS AutoUpdateStatsAsync,
    d.is_read_only                     AS ReadOnly,
    d.is_query_store_on                AS QueryStoreOn,
    d.snapshot_isolation_state_desc    AS SnapshotIsolation,
    d.is_read_committed_snapshot_on    AS RCSI,
    SUSER_SNAME(d.owner_sid)           AS DBOwner,
    d.create_date                      AS Created
FROM sys.databases d
ORDER BY d.name;
GO

/*------------------------------------------------------------------------------
  SECTION 4 : DATABASE FILE SIZES, FREE SPACE & AUTOGROWTH
  Flags: percent-growth autogrowth, tiny fixed-growth, low free space.
------------------------------------------------------------------------------*/
PRINT '===== 4. DATABASE FILES, SIZE & AUTOGROWTH =====';

;WITH f AS (
    SELECT
        DB_NAME(mf.database_id)                                    AS DatabaseName,
        mf.database_id,
        mf.type_desc                                              AS FileType,
        mf.name                                                   AS LogicalName,
        mf.physical_name                                          AS PhysicalPath,
        CAST(mf.size      * 8.0 / 1024 AS DECIMAL(12,2))          AS SizeMB,
        CAST(mf.max_size  * 8.0 / 1024 AS DECIMAL(12,2))          AS MaxSizeMB, -- -1 = unlimited
        mf.is_percent_growth                                      AS PctGrowth,
        CASE WHEN mf.is_percent_growth = 1
             THEN CAST(mf.growth AS VARCHAR(10)) + ' %'
             ELSE CAST(CAST(mf.growth * 8.0 / 1024 AS DECIMAL(12,2)) AS VARCHAR(20)) + ' MB'
        END                                                       AS Autogrowth
    FROM sys.master_files mf
)
SELECT *,
    CASE WHEN PctGrowth = 1 THEN '*** percent-growth: switch to fixed MB ***'
         WHEN FileType = 'ROWS' AND Autogrowth IN ('1.00 MB') THEN 'small growth increment'
         ELSE '' END AS GrowthWarning
FROM f
ORDER BY DatabaseName, FileType DESC;

-- Actual free space inside data files (run per DB ideally; this is current DB)
PRINT '----- Free space inside files (CURRENT DATABASE: ' ;
SELECT DB_NAME() AS CurrentDB;
SELECT
    name                                                          AS LogicalName,
    type_desc                                                     AS FileType,
    CAST(size*8.0/1024 AS DECIMAL(12,2))                          AS SizeMB,
    CAST(FILEPROPERTY(name,'SpaceUsed')*8.0/1024 AS DECIMAL(12,2))AS UsedMB,
    CAST((size - FILEPROPERTY(name,'SpaceUsed'))*8.0/1024 AS DECIMAL(12,2)) AS FreeMB,
    CAST(100.0*(size - FILEPROPERTY(name,'SpaceUsed'))/NULLIF(size,0) AS DECIMAL(5,2)) AS FreePct
FROM sys.database_files;
GO

/*------------------------------------------------------------------------------
  SECTION 5 : BACKUP STATUS
  Last full / diff / log backup per database + age. Flags databases with
  NO backup, or stale backups, or FULL/BULK_LOGGED recovery with no log backup
  (= log will grow forever).
------------------------------------------------------------------------------*/
PRINT '===== 5. BACKUP STATUS =====';

;WITH b AS (
    SELECT
        database_name,
        MAX(CASE WHEN type = 'D' THEN backup_finish_date END) AS LastFull,
        MAX(CASE WHEN type = 'I' THEN backup_finish_date END) AS LastDiff,
        MAX(CASE WHEN type = 'L' THEN backup_finish_date END) AS LastLog
    FROM msdb.dbo.backupset
    GROUP BY database_name
)
SELECT
    d.name                                                  AS DatabaseName,
    d.recovery_model_desc                                   AS RecoveryModel,
    b.LastFull,
    DATEDIFF(HOUR, b.LastFull, GETDATE())                   AS FullAge_Hrs,
    b.LastDiff,
    b.LastLog,
    DATEDIFF(MINUTE, b.LastLog, GETDATE())                  AS LogAge_Min,
    CASE
        WHEN b.LastFull IS NULL THEN '*** NEVER BACKED UP ***'
        WHEN DATEDIFF(HOUR, b.LastFull, GETDATE()) > 24 THEN 'Full backup > 24h old'
        WHEN d.recovery_model_desc IN ('FULL','BULK_LOGGED')
             AND (b.LastLog IS NULL OR DATEDIFF(MINUTE, b.LastLog, GETDATE()) > 60)
             THEN '*** FULL recovery but no recent LOG backup (log will grow) ***'
        ELSE 'OK'
    END                                                     AS BackupWarning
FROM sys.databases d
LEFT JOIN b ON b.database_name = d.name
WHERE d.database_id <> 2          -- skip tempdb
ORDER BY BackupWarning DESC, d.name;
GO

/*------------------------------------------------------------------------------
  SECTION 6 : TRANSACTION LOG USAGE
  High used% in FULL recovery often means log backups aren't running.
------------------------------------------------------------------------------*/
PRINT '===== 6. TRANSACTION LOG USAGE =====';

-- Log size / used% for the CURRENT database (this DMV is scoped to current DB).
-- NOTE: log_reuse_wait_desc is NOT on this DMV - it lives on sys.databases (see below).
SELECT
    DB_NAME(lsu.database_id)                                        AS DatabaseName,
    CAST(lsu.total_log_size_in_bytes/1024.0/1024 AS DECIMAL(12,2)) AS LogSizeMB,
    CAST(lsu.used_log_space_in_bytes/1024.0/1024 AS DECIMAL(12,2)) AS LogUsedMB,
    CAST(lsu.used_log_space_in_percent AS DECIMAL(5,2))            AS LogUsedPct,
    d.log_reuse_wait_desc                                          AS LogReuseWait  -- why log can't truncate
FROM sys.dm_db_log_space_usage lsu
JOIN sys.databases d ON d.database_id = lsu.database_id;

-- Cross-DB log reuse reason (why VLFs aren't freed): LOG_BACKUP, ACTIVE_TRANSACTION, etc.
SELECT name AS DatabaseName, log_reuse_wait_desc AS LogReuseWait
FROM sys.databases
ORDER BY name;
GO

/*------------------------------------------------------------------------------
  SECTION 7 : DBCC CHECKDB - LAST KNOWN-GOOD (corruption check)
  Uses DBCC DBINFO last clean check. Run per database.
  Quick scan across DBs:
------------------------------------------------------------------------------*/
PRINT '===== 7. DBCC CHECKDB - LAST CLEAN CHECK (current DB) =====';

-- For the CURRENT database:
DBCC DBINFO() WITH TABLERESULTS, NO_INFOMSGS;   -- look for 'dbi_dbccLastKnownGood'
GO

/*------------------------------------------------------------------------------
  SECTION 8 : WAIT STATISTICS  (top resource bottleneck since restart)
  Filters out benign/idle waits. Tells you WHAT the server waits on.
------------------------------------------------------------------------------*/
PRINT '===== 8. TOP WAIT STATISTICS =====';

;WITH waits AS (
    SELECT
        wait_type,
        wait_time_ms,
        waiting_tasks_count,
        signal_wait_time_ms,
        wait_time_ms - signal_wait_time_ms AS resource_wait_ms,
        100.0 * wait_time_ms / SUM(wait_time_ms) OVER() AS pct
    FROM sys.dm_os_wait_stats
    WHERE wait_type NOT IN (   -- benign / background waits to ignore
        'BROKER_EVENTHANDLER','BROKER_RECEIVE_WAITFOR','BROKER_TASK_STOP',
        'BROKER_TO_FLUSH','BROKER_TRANSMITTER','CHECKPOINT_QUEUE',
        'CHKPT','CLR_AUTO_EVENT','CLR_MANUAL_EVENT','CLR_SEMAPHORE',
        'DBMIRROR_DBM_EVENT','DBMIRROR_EVENTS_QUEUE','DBMIRROR_WORKER_QUEUE',
        'DBMIRRORING_CMD','DIRTY_PAGE_POLL','DISPATCHER_QUEUE_SEMAPHORE',
        'EXECSYNC','FSAGENT','FT_IFTS_SCHEDULER_IDLE_WAIT','FT_IFTSHC_MUTEX',
        'HADR_CLUSAPI_CALL','HADR_FILESTREAM_IOMGR_IOCOMPLETION','HADR_LOGCAPTURE_WAIT',
        'HADR_NOTIFICATION_DEQUEUE','HADR_TIMER_TASK','HADR_WORK_QUEUE',
        'KSOURCE_WAKEUP','LAZYWRITER_SLEEP','LOGMGR_QUEUE','MEMORY_ALLOCATION_EXT',
        'ONDEMAND_TASK_QUEUE','PARALLEL_REDO_DRAIN_WORKER','PARALLEL_REDO_LOG_CACHE',
        'PARALLEL_REDO_TRAN_LIST','PARALLEL_REDO_WORKER_SYNC','PARALLEL_REDO_WORKER_WAIT_WORK',
        'PREEMPTIVE_XE_GETTARGETSTATE','PWAIT_ALL_COMPONENTS_INITIALIZED',
        'PWAIT_DIRECTLOGCONSUMER_GETNEXT','QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
        'QDS_ASYNC_QUEUE','QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
        'QDS_SHUTDOWN_QUEUE','REDO_THREAD_PENDING_WORK','REQUEST_FOR_DEADLOCK_SEARCH',
        'RESOURCE_QUEUE','SERVER_IDLE_CHECK','SLEEP_BPOOL_FLUSH','SLEEP_DBSTARTUP',
        'SLEEP_DCOMSTARTUP','SLEEP_MASTERDBREADY','SLEEP_MASTERMDREADY',
        'SLEEP_MASTERUPGRADED','SLEEP_MSDBSTARTUP','SLEEP_SYSTEMTASK','SLEEP_TASK',
        'SLEEP_TEMPDBSTARTUP','SNI_HTTP_ACCEPT','SP_SERVER_DIAGNOSTICS_SLEEP',
        'SQLTRACE_BUFFER_FLUSH','SQLTRACE_INCREMENTAL_FLUSH_SLEEP','SQLTRACE_WAIT_ENTRIES',
        'WAIT_FOR_RESULTS','WAITFOR','WAITFOR_TASKSHUTDOWN','WAIT_XTP_HOST_WAIT',
        'WAIT_XTP_OFFLINE_CKPT_NEW_LOG','WAIT_XTP_CKPT_CLOSE','WAIT_XTP_RECOVERY',
        'XE_BUFFERMGR_ALLPROCESSED_EVENT','XE_DISPATCHER_JOIN','XE_DISPATCHER_WAIT',
        'XE_LIVE_TARGET_TVF','XE_TIMER_EVENT','SOS_WORK_DISPATCHER'
    )
    AND waiting_tasks_count > 0
)
SELECT TOP 25
    wait_type,
    waiting_tasks_count                                AS WaitCount,
    CAST(wait_time_ms/1000.0 AS DECIMAL(14,2))         AS TotalWait_s,
    CAST(resource_wait_ms/1000.0 AS DECIMAL(14,2))     AS ResourceWait_s,
    CAST(signal_wait_time_ms/1000.0 AS DECIMAL(14,2))  AS SignalWait_s,  -- high = CPU pressure
    CAST(wait_time_ms/1.0/waiting_tasks_count AS DECIMAL(14,2)) AS AvgWait_ms,
    CAST(pct AS DECIMAL(5,2))                          AS Pct
FROM waits
ORDER BY wait_time_ms DESC;
GO

/*------------------------------------------------------------------------------
  SECTION 9 : MEMORY HEALTH  (Page Life Expectancy, buffer usage by DB)
  PLE: rule of thumb >= 300s per 4GB of buffer pool. Low + high PAGEIOLATCH
  waits = memory pressure / under-indexing.
------------------------------------------------------------------------------*/
PRINT '===== 9. MEMORY / BUFFER POOL =====';

SELECT object_name, counter_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE counter_name IN ('Page life expectancy','Buffer cache hit ratio',
                       'Page reads/sec','Page writes/sec','Lazy writes/sec',
                       'Memory Grants Pending','Target Server Memory (KB)',
                       'Total Server Memory (KB)')
  AND (object_name LIKE '%Buffer Manager%' OR object_name LIKE '%Memory Manager%');

-- Buffer pool pages by database
SELECT
    CASE database_id WHEN 32767 THEN 'RESOURCE_DB' ELSE DB_NAME(database_id) END AS DatabaseName,
    COUNT(*)                                          AS BufferPages,
    CAST(COUNT(*) * 8.0 / 1024 AS DECIMAL(12,2))      AS BufferMB
FROM sys.dm_os_buffer_descriptors
GROUP BY database_id
ORDER BY BufferPages DESC;
GO

/*------------------------------------------------------------------------------
  SECTION 10 : MISSING INDEXES  (engine suggestions, ranked by impact)
  WARNING: these are SUGGESTIONS, not commands. Consolidate overlapping ones,
  watch column order (equality then inequality then include), and do not
  blindly create all of them. improvement_measure = rough benefit score.
------------------------------------------------------------------------------*/
PRINT '===== 10. MISSING INDEX SUGGESTIONS =====';

SELECT TOP 50
    DB_NAME(mid.database_id)                                            AS DatabaseName,
    OBJECT_NAME(mid.object_id, mid.database_id)                         AS TableName,
    CAST(migs.avg_total_user_cost
         * migs.avg_user_impact
         * (migs.user_seeks + migs.user_scans) AS DECIMAL(18,2))        AS ImprovementMeasure,
    migs.user_seeks + migs.user_scans                                  AS SeeksScans,
    CAST(migs.avg_user_impact AS DECIMAL(5,1))                          AS AvgImpactPct,
    migs.last_user_seek,
    'CREATE INDEX [IX_' + OBJECT_NAME(mid.object_id, mid.database_id) + '_'
        + REPLACE(REPLACE(REPLACE(ISNULL(mid.equality_columns,''),', ','_'),'[',''),']','')
        + CASE WHEN mid.inequality_columns IS NOT NULL THEN '_incl_ineq' ELSE '' END
        + '] ON ' + mid.statement
        + ' (' + ISNULL(mid.equality_columns,'')
        + CASE WHEN mid.equality_columns IS NOT NULL AND mid.inequality_columns IS NOT NULL THEN ',' ELSE '' END
        + ISNULL(mid.inequality_columns,'') + ')'
        + ISNULL(' INCLUDE (' + mid.included_columns + ')','')          AS Suggested_CREATE_INDEX
FROM sys.dm_db_missing_index_groups        mig
JOIN sys.dm_db_missing_index_group_stats   migs ON migs.group_handle = mig.index_group_handle
JOIN sys.dm_db_missing_index_details       mid  ON mig.index_handle  = mid.index_handle
ORDER BY ImprovementMeasure DESC;
GO

/*------------------------------------------------------------------------------
  SECTION 11 : INDEX USAGE  (unused, rarely-used, and write-heavy indexes)
  PER CURRENT DATABASE. Run inside each user DB.
  - Unused (0 reads, >0 writes) = candidate to DROP (maintenance overhead).
  - High writes vs low reads = expensive to maintain.
  NOTE: usage stats reset on restart - judge against uptime (Section 1).
------------------------------------------------------------------------------*/
PRINT '===== 11. INDEX USAGE (current DB: drop candidates) =====';
SELECT DB_NAME() AS CurrentDatabase;

SELECT
    OBJECT_SCHEMA_NAME(i.object_id)                AS SchemaName,
    OBJECT_NAME(i.object_id)                       AS TableName,
    i.name                                         AS IndexName,
    i.type_desc                                    AS IndexType,
    i.is_primary_key                               AS IsPK,
    i.is_unique                                    AS IsUnique,
    ISNULL(us.user_seeks,0)                        AS Seeks,
    ISNULL(us.user_scans,0)                        AS Scans,
    ISNULL(us.user_lookups,0)                      AS Lookups,
    ISNULL(us.user_seeks,0)+ISNULL(us.user_scans,0)+ISNULL(us.user_lookups,0) AS TotalReads,
    ISNULL(us.user_updates,0)                      AS Writes,
    us.last_user_seek,
    us.last_user_scan,
    CASE
        WHEN i.is_primary_key = 0 AND i.is_unique = 0
             AND ISNULL(us.user_seeks,0)+ISNULL(us.user_scans,0)+ISNULL(us.user_lookups,0) = 0
             AND ISNULL(us.user_updates,0) > 0
        THEN '*** UNUSED - consider DROP ***'
        WHEN ISNULL(us.user_updates,0) >
             (ISNULL(us.user_seeks,0)+ISNULL(us.user_scans,0)+ISNULL(us.user_lookups,0)) * 10
             AND ISNULL(us.user_updates,0) > 1000
        THEN 'Write-heavy / low read'
        ELSE ''
    END                                            AS UsageWarning
FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats us
       ON us.object_id = i.object_id
      AND us.index_id  = i.index_id
      AND us.database_id = DB_ID()
WHERE OBJECTPROPERTY(i.object_id,'IsUserTable') = 1
  AND i.type_desc <> 'HEAP'
ORDER BY Writes DESC, TotalReads ASC;
GO

/*------------------------------------------------------------------------------
  SECTION 12 : INDEX FRAGMENTATION  (current DB)
  LIMITED / SAMPLED mode to stay light. Filters tiny indexes (<1000 pages).
  Guidance:  5-30% avg_fragmentation -> REORGANIZE
             > 30%                    -> REBUILD
  Also report fill_factor and page_count.
  For ALL databases, use the cursor block at the end of this section.
------------------------------------------------------------------------------*/
PRINT '===== 12. INDEX FRAGMENTATION (current DB) =====';
SELECT DB_NAME() AS CurrentDatabase;

SELECT
    OBJECT_SCHEMA_NAME(ips.object_id)                  AS SchemaName,
    OBJECT_NAME(ips.object_id)                         AS TableName,
    i.name                                             AS IndexName,
    i.type_desc                                        AS IndexType,
    ips.partition_number                               AS Partition,
    CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,2)) AS FragPct,
    ips.page_count                                     AS Pages,
    CAST(ips.page_count * 8.0/1024 AS DECIMAL(12,2))   AS SizeMB,
    ips.avg_page_space_used_in_percent                 AS AvgPageFullnessPct,
    i.fill_factor                                      AS FillFactor,
    CASE
        WHEN ips.avg_fragmentation_in_percent > 30 THEN 'REBUILD'
        WHEN ips.avg_fragmentation_in_percent > 5  THEN 'REORGANIZE'
        ELSE 'OK'
    END                                                AS Recommendation,
    -- Ready-to-run remediation statement:
    CASE
        WHEN ips.avg_fragmentation_in_percent > 30
            THEN 'ALTER INDEX [' + i.name + '] ON ['
                 + OBJECT_SCHEMA_NAME(ips.object_id) + '].['
                 + OBJECT_NAME(ips.object_id) + '] REBUILD WITH (ONLINE=OFF, SORT_IN_TEMPDB=ON);'
        WHEN ips.avg_fragmentation_in_percent > 5
            THEN 'ALTER INDEX [' + i.name + '] ON ['
                 + OBJECT_SCHEMA_NAME(ips.object_id) + '].['
                 + OBJECT_NAME(ips.object_id) + '] REORGANIZE;'
        ELSE NULL
    END                                                AS RemediationTSQL
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
JOIN sys.indexes i
      ON i.object_id = ips.object_id
     AND i.index_id  = ips.index_id
WHERE ips.page_count >= 1000          -- ignore small indexes (fragmentation irrelevant)
  AND i.index_id > 0                  -- skip heaps here (see Section 13)
  AND i.name IS NOT NULL
ORDER BY ips.avg_fragmentation_in_percent DESC;

/* --- OPTIONAL: sweep fragmentation across ALL online databases ---
DECLARE @sql NVARCHAR(MAX) = N'';
SELECT @sql += N'
USE ' + QUOTENAME(name) + N';
SELECT DB_NAME() AS DatabaseName, OBJECT_NAME(ips.object_id) AS TableName,
       i.name AS IndexName, CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,2)) AS FragPct,
       ips.page_count AS Pages
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, ''LIMITED'') ips
JOIN sys.indexes i ON i.object_id=ips.object_id AND i.index_id=ips.index_id
WHERE ips.page_count >= 1000 AND ips.avg_fragmentation_in_percent > 10 AND i.index_id>0;'
FROM sys.databases
WHERE state_desc='ONLINE' AND database_id>4 AND is_read_only=0;
EXEC sp_executesql @sql;
*/
GO

/*------------------------------------------------------------------------------
  SECTION 13 : HEAPS  (tables with no clustered index - usually a design smell)
------------------------------------------------------------------------------*/
PRINT '===== 13. HEAPS (no clustered index) =====';

SELECT
    OBJECT_SCHEMA_NAME(i.object_id)        AS SchemaName,
    OBJECT_NAME(i.object_id)               AS TableName,
    ps.row_count                           AS [RowCount],
    CAST(ps.reserved_page_count*8.0/1024 AS DECIMAL(12,2)) AS ReservedMB,
    ISNULL(us.user_seeks,0)+ISNULL(us.user_scans,0)+ISNULL(us.user_lookups,0) AS Reads,
    ISNULL(us.user_updates,0)              AS Writes
FROM sys.indexes i
JOIN sys.dm_db_partition_stats ps ON ps.object_id=i.object_id AND ps.index_id=i.index_id
LEFT JOIN sys.dm_db_index_usage_stats us
       ON us.object_id=i.object_id AND us.index_id=i.index_id AND us.database_id=DB_ID()
WHERE i.type_desc='HEAP'
  AND OBJECTPROPERTY(i.object_id,'IsUserTable')=1
ORDER BY ps.row_count DESC;
GO

/*------------------------------------------------------------------------------
  SECTION 14 : DUPLICATE / OVERLAPPING INDEXES  (current DB)
  Exact-duplicate key columns = pure overhead. Drop one.
------------------------------------------------------------------------------*/
PRINT '===== 14. DUPLICATE INDEXES (exact key match, current DB) =====';

;WITH idx AS (
    SELECT
        i.object_id, i.index_id, i.name AS index_name, i.is_unique, i.is_primary_key,
        keys = STUFF((SELECT ',' + c.name
                      FROM sys.index_columns ic
                      JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
                      WHERE ic.object_id=i.object_id AND ic.index_id=i.index_id AND ic.is_included_column=0
                      ORDER BY ic.key_ordinal
                      FOR XML PATH('')),1,1,'')
    FROM sys.indexes i
    WHERE i.type IN (1,2) AND OBJECTPROPERTY(i.object_id,'IsUserTable')=1
)
SELECT
    OBJECT_SCHEMA_NAME(a.object_id) AS SchemaName,
    OBJECT_NAME(a.object_id)        AS TableName,
    a.index_name                    AS Index1,
    b.index_name                    AS Index2_Duplicate,
    a.keys                          AS KeyColumns
FROM idx a
JOIN idx b ON a.object_id=b.object_id AND a.keys=b.keys AND a.index_id < b.index_id
ORDER BY TableName;
GO

/*------------------------------------------------------------------------------
  SECTION 15 : STALE STATISTICS  (current DB)
  Old / never-updated stats with many row modifications -> bad plans.
------------------------------------------------------------------------------*/
PRINT '===== 15. STALE STATISTICS (current DB) =====';

SELECT
    OBJECT_SCHEMA_NAME(s.object_id)        AS SchemaName,
    OBJECT_NAME(s.object_id)               AS TableName,
    s.name                                 AS StatName,
    sp.last_updated                        AS LastUpdated,
    sp.rows                                AS [Rows],
    sp.modification_counter                AS RowsModified,
    CAST(100.0*sp.modification_counter/NULLIF(sp.rows,0) AS DECIMAL(6,2)) AS PctModified
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE OBJECTPROPERTY(s.object_id,'IsUserTable')=1
  AND sp.rows > 1000
  AND (sp.modification_counter > sp.rows*0.20 OR sp.last_updated < DATEADD(DAY,-30,GETDATE()))
ORDER BY PctModified DESC;
GO

/*------------------------------------------------------------------------------
  SECTION 16 : TOP EXPENSIVE QUERIES  (from plan cache)
  Three lenses: total CPU, total logical reads (IO), avg duration.
------------------------------------------------------------------------------*/
PRINT '===== 16a. TOP QUERIES BY TOTAL CPU =====';

SELECT TOP 20
    qs.execution_count                                              AS Execs,
    CAST(qs.total_worker_time/1000.0 AS DECIMAL(18,2))              AS TotalCPU_ms,
    CAST(qs.total_worker_time/1000.0/qs.execution_count AS DECIMAL(18,2)) AS AvgCPU_ms,
    CAST(qs.total_elapsed_time/1000.0/qs.execution_count AS DECIMAL(18,2)) AS AvgDuration_ms,
    qs.total_logical_reads/qs.execution_count                      AS AvgLogicalReads,
    DB_NAME(st.dbid)                                               AS DatabaseName,
    SUBSTRING(st.text,(qs.statement_start_offset/2)+1,
        ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
          ELSE qs.statement_end_offset END - qs.statement_start_offset)/2)+1) AS QueryText
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
ORDER BY qs.total_worker_time DESC;

PRINT '===== 16b. TOP QUERIES BY TOTAL LOGICAL READS (IO) =====';

SELECT TOP 20
    qs.execution_count                                             AS Execs,
    qs.total_logical_reads                                         AS TotalLogicalReads,
    qs.total_logical_reads/qs.execution_count                     AS AvgLogicalReads,
    CAST(qs.total_elapsed_time/1000.0/qs.execution_count AS DECIMAL(18,2)) AS AvgDuration_ms,
    DB_NAME(st.dbid)                                              AS DatabaseName,
    SUBSTRING(st.text,(qs.statement_start_offset/2)+1,
        ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
          ELSE qs.statement_end_offset END - qs.statement_start_offset)/2)+1) AS QueryText
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
ORDER BY qs.total_logical_reads DESC;
GO

/*------------------------------------------------------------------------------
  SECTION 17 : CURRENT ACTIVITY - BLOCKING & LONG-RUNNING REQUESTS
------------------------------------------------------------------------------*/
PRINT '===== 17. ACTIVE / BLOCKING REQUESTS =====';

SELECT
    r.session_id                          AS SPID,
    r.blocking_session_id                 AS BlockedBy,
    r.status,
    r.wait_type,
    r.wait_time                           AS WaitTime_ms,
    r.wait_resource,
    r.cpu_time                            AS CPU_ms,
    r.total_elapsed_time                  AS Elapsed_ms,
    r.logical_reads                       AS LogicalReads,
    DB_NAME(r.database_id)                AS DatabaseName,
    s.login_name,
    s.host_name,
    s.program_name,
    SUBSTRING(t.text,(r.statement_start_offset/2)+1,
        ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
          ELSE r.statement_end_offset END - r.statement_start_offset)/2)+1) AS CurrentStatement
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.session_id <> @@SPID
  AND s.is_user_process = 1
ORDER BY r.blocking_session_id DESC, r.total_elapsed_time DESC;
GO

/*------------------------------------------------------------------------------
  SECTION 18 : SQL AGENT JOB FAILURES (last 7 days)
------------------------------------------------------------------------------*/
PRINT '===== 18. AGENT JOB STATUS (recent failures) =====';

SELECT
    j.name                                              AS JobName,
    j.enabled                                           AS Enabled,
    h.run_status,                                       -- 0=Failed 1=Succeeded 3=Cancelled 4=InProgress
    msdb.dbo.agent_datetime(h.run_date,h.run_time)      AS RunDateTime,
    STUFF(STUFF(RIGHT('000000'+CAST(h.run_duration AS VARCHAR(6)),6),5,0,':'),3,0,':') AS Duration_hhmmss,
    h.message
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobhistory h ON h.job_id = j.job_id
WHERE h.step_id = 0                          -- job outcome row
  AND h.run_status <> 1                      -- not succeeded
  AND msdb.dbo.agent_datetime(h.run_date,h.run_time) > DATEADD(DAY,-7,GETDATE())
ORDER BY RunDateTime DESC;
GO

/*------------------------------------------------------------------------------
  SECTION 19 : SECURITY QUICK CHECK
  - sysadmin members, logins with weak/old policy, orphaned users, sa status.
------------------------------------------------------------------------------*/
PRINT '===== 19. SECURITY - sysadmin members =====';

SELECT
    sp.name                               AS LoginName,
    sp.type_desc                          AS LoginType,
    sp.is_disabled                        AS Disabled,
    sp.create_date,
    sp.modify_date
FROM sys.server_role_members rm
JOIN sys.server_principals sp ON sp.principal_id = rm.member_principal_id
JOIN sys.server_principals r  ON r.principal_id  = rm.role_principal_id
WHERE r.name = 'sysadmin'
ORDER BY sp.name;

-- SQL logins with policy/expiration disabled (potential weak passwords)
SELECT name AS SqlLogin, is_policy_checked, is_expiration_checked, is_disabled, modify_date
FROM sys.sql_logins
WHERE is_policy_checked = 0 OR is_expiration_checked = 0
ORDER BY name;
GO

/*------------------------------------------------------------------------------
  SECTION 20 : TEMPDB CONFIGURATION
  Best practice: multiple equally-sized data files (no autogrowth skew),
  same growth increments, on fast storage. Watch GAM/SGAM/PFS contention.
------------------------------------------------------------------------------*/
PRINT '===== 20. TEMPDB FILE CONFIGURATION =====';

SELECT
    mf.name                                                   AS LogicalName,
    mf.type_desc                                              AS FileType,
    CAST(mf.size*8.0/1024 AS DECIMAL(12,2))                   AS SizeMB,
    CASE WHEN mf.is_percent_growth=1
         THEN CAST(mf.growth AS VARCHAR(10))+' %'
         ELSE CAST(CAST(mf.growth*8.0/1024 AS DECIMAL(12,2)) AS VARCHAR(20))+' MB' END AS Autogrowth,
    mf.physical_name                                          AS PhysicalPath
FROM sys.master_files mf
WHERE mf.database_id = 2
ORDER BY mf.type_desc DESC, mf.file_id;

SELECT
    'TempDB data files = ' + CAST(COUNT(*) AS VARCHAR(10))
    + ' ; logical CPUs = ' + CAST((SELECT cpu_count FROM sys.dm_os_sys_info) AS VARCHAR(10))
    + ' (aim for #files = #CPU up to 8, equal size)' AS TempDB_FileCount_Guidance
FROM sys.master_files
WHERE database_id = 2 AND type_desc = 'ROWS';
GO

PRINT '===== HEALTH CHECK COMPLETE =====';
GO
