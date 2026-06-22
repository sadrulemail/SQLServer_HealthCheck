<#
================================================================================
  SQL SERVER 2017 - HEALTH CHECK  ->  CSV PER SECTION
  ----------------------------------------------------------------------------
  Runs each diagnostic section and writes its own CSV file into a timestamped
  folder. Read-only (DMV / catalog queries only).

  Requires : SqlServer PowerShell module (Invoke-Sqlcmd).
             Install once:  Install-Module SqlServer -Scope CurrentUser
  ----------------------------------------------------------------------------
  EXAMPLES
    # Windows auth, default local instance, all server-wide + one target DB
    .\SQLServer_HealthCheck_Export.ps1 -ServerInstance "localhost" -TargetDatabase "MyDb"
    powershell.exe -ExecutionPolicy Bypass -File "C:\Users\HP\SQLServer_HealthCheck_Export.ps1" -ServerInstance "localhost" -TargetDatabase "MyDb"

    # Named instance + SQL auth
    .\SQLServer_HealthCheck_Export.ps1 -ServerInstance "SRV01\SQL2017" `
        -TargetDatabase "Sales" -SqlUser "sa" -SqlPassword "P@ssw0rd"

    # Custom output location
    .\SQLServer_HealthCheck_Export.ps1 -ServerInstance "localhost" `
        -TargetDatabase "Sales" -OutputRoot "D:\HealthChecks"
================================================================================
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ServerInstance,

    # Database used for the PER-DATABASE sections (11-15). Defaults to master,
    # which means those sections report on master only - set this to your DB.
    [string] $TargetDatabase = "master",

    [string] $SqlUser,
    [string] $SqlPassword,

    [string] $OutputRoot = "$env:USERPROFILE\SQLHealthCheck",

    [int]    $QueryTimeoutSec = 300
)

# --- Setup ---------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Error "SqlServer module not found. Run:  Install-Module SqlServer -Scope CurrentUser"
    return
}
Import-Module SqlServer -ErrorAction Stop

$stamp     = Get-Date -Format "yyyyMMdd_HHmmss"
$safeSrv   = ($ServerInstance -replace '[\\/:*?""<>|]', '_')
$outDir    = Join-Path $OutputRoot "$safeSrv`_$stamp"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Write-Host "Output folder: $outDir" -ForegroundColor Cyan

# Common auth splat for Invoke-Sqlcmd
$auth = @{
    ServerInstance = $ServerInstance
    QueryTimeout   = $QueryTimeoutSec
    ErrorAction    = 'Stop'
}
if ($SqlUser) { $auth.Username = $SqlUser; $auth.Password = $SqlPassword }

# --- Section definitions -------------------------------------------------------
# Each entry: ordered name (becomes NN_Name.csv), the DB to run in, and the query.
# Db = 'master'  -> server-wide section (any context works)
# Db = '$TARGET' -> per-database section, runs against -TargetDatabase
$sections = [ordered]@{}

$sections["01_InstanceOverview"] = @{ Db='master'; Q=@"
SELECT @@SERVERNAME AS ServerName, SERVERPROPERTY('MachineName') AS MachineName,
 SERVERPROPERTY('InstanceName') AS InstanceName, SERVERPROPERTY('ProductVersion') AS ProductVersion,
 SERVERPROPERTY('ProductLevel') AS ProductLevel, SERVERPROPERTY('ProductUpdateLevel') AS CU_Level,
 SERVERPROPERTY('Edition') AS Edition, SERVERPROPERTY('Collation') AS ServerCollation,
 SERVERPROPERTY('IsClustered') AS IsClustered, SERVERPROPERTY('IsHadrEnabled') AS IsAlwaysOnEnabled,
 SERVERPROPERTY('IsIntegratedSecurityOnly') AS WindowsAuthOnly;
"@ }

$sections["01b_HostHardware"] = @{ Db='master'; Q=@"
SELECT cpu_count AS LogicalCPUs, hyperthread_ratio AS CoresPerSocket,
 cpu_count/hyperthread_ratio AS PhysicalSockets,
 CAST(physical_memory_kb/1024.0/1024 AS DECIMAL(9,2)) AS Physical_RAM_GB,
 CAST(committed_kb/1024.0/1024 AS DECIMAL(9,2)) AS SQL_Committed_GB,
 CAST(committed_target_kb/1024.0/1024 AS DECIMAL(9,2)) AS SQL_TargetCommit_GB,
 sqlserver_start_time AS SQLStartTime,
 DATEDIFF(HOUR, sqlserver_start_time, GETDATE()) AS Uptime_Hours
FROM sys.dm_os_sys_info;
"@ }

$sections["02_Configuration"] = @{ Db='master'; Q=@"
SELECT name AS ConfigName, CAST(value AS BIGINT) AS ConfiguredValue,
 CAST(value_in_use AS BIGINT) AS RunningValue,
 CASE WHEN value<>value_in_use THEN 'PENDING RESTART' ELSE '' END AS Note, description
FROM sys.configurations
WHERE name IN ('max server memory (MB)','min server memory (MB)','max degree of parallelism',
 'cost threshold for parallelism','optimize for ad hoc workloads','backup compression default',
 'remote admin connections','fill factor (%)','max worker threads','priority boost',
 'lightweight pooling','recovery interval (min)','show advanced options')
ORDER BY name;
"@ }

$sections["03_DatabaseSettings"] = @{ Db='master'; Q=@"
SELECT database_id, name AS DatabaseName, state_desc AS State, recovery_model_desc AS RecoveryModel,
 compatibility_level AS CompatLevel, page_verify_option_desc AS PageVerify,
 is_auto_shrink_on AS AutoShrink, is_auto_close_on AS AutoClose,
 is_auto_create_stats_on AS AutoCreateStats, is_auto_update_stats_on AS AutoUpdateStats,
 is_read_only AS ReadOnly, is_query_store_on AS QueryStoreOn,
 is_read_committed_snapshot_on AS RCSI, SUSER_SNAME(owner_sid) AS DBOwner, create_date AS Created
FROM sys.databases ORDER BY name;
"@ }

$sections["04_FilesAndAutogrowth"] = @{ Db='master'; Q=@"
SELECT DB_NAME(mf.database_id) AS DatabaseName, mf.type_desc AS FileType, mf.name AS LogicalName,
 mf.physical_name AS PhysicalPath, CAST(mf.size*8.0/1024 AS DECIMAL(12,2)) AS SizeMB,
 CAST(mf.max_size*8.0/1024 AS DECIMAL(12,2)) AS MaxSizeMB, mf.is_percent_growth AS PctGrowth,
 CASE WHEN mf.is_percent_growth=1 THEN CAST(mf.growth AS VARCHAR(10))+' %'
      ELSE CAST(CAST(mf.growth*8.0/1024 AS DECIMAL(12,2)) AS VARCHAR(20))+' MB' END AS Autogrowth
FROM sys.master_files mf ORDER BY DatabaseName, FileType DESC;
"@ }

$sections["05_BackupStatus"] = @{ Db='master'; Q=@"
;WITH b AS (SELECT database_name,
   MAX(CASE WHEN type='D' THEN backup_finish_date END) AS LastFull,
   MAX(CASE WHEN type='I' THEN backup_finish_date END) AS LastDiff,
   MAX(CASE WHEN type='L' THEN backup_finish_date END) AS LastLog
 FROM msdb.dbo.backupset GROUP BY database_name)
SELECT d.name AS DatabaseName, d.recovery_model_desc AS RecoveryModel, b.LastFull,
 DATEDIFF(HOUR,b.LastFull,GETDATE()) AS FullAge_Hrs, b.LastDiff, b.LastLog,
 DATEDIFF(MINUTE,b.LastLog,GETDATE()) AS LogAge_Min,
 CASE WHEN b.LastFull IS NULL THEN 'NEVER BACKED UP'
   WHEN DATEDIFF(HOUR,b.LastFull,GETDATE())>24 THEN 'Full backup > 24h old'
   WHEN d.recovery_model_desc IN ('FULL','BULK_LOGGED') AND (b.LastLog IS NULL OR DATEDIFF(MINUTE,b.LastLog,GETDATE())>60)
     THEN 'FULL recovery but no recent LOG backup' ELSE 'OK' END AS BackupWarning
FROM sys.databases d LEFT JOIN b ON b.database_name=d.name
WHERE d.database_id<>2 ORDER BY BackupWarning DESC, d.name;
"@ }

$sections["06_LogReuseWait"] = @{ Db='master'; Q=@"
SELECT name AS DatabaseName, recovery_model_desc AS RecoveryModel,
 log_reuse_wait_desc AS LogReuseWait FROM sys.databases ORDER BY name;
"@ }

$sections["08_WaitStats"] = @{ Db='master'; Q=@"
;WITH waits AS (SELECT wait_type, wait_time_ms, waiting_tasks_count, signal_wait_time_ms,
   wait_time_ms-signal_wait_time_ms AS resource_wait_ms,
   100.0*wait_time_ms/SUM(wait_time_ms) OVER() AS pct
 FROM sys.dm_os_wait_stats
 WHERE waiting_tasks_count>0 AND wait_type NOT IN (
   'BROKER_EVENTHANDLER','BROKER_RECEIVE_WAITFOR','BROKER_TASK_STOP','BROKER_TO_FLUSH',
   'BROKER_TRANSMITTER','CHECKPOINT_QUEUE','CHKPT','CLR_AUTO_EVENT','CLR_MANUAL_EVENT',
   'CLR_SEMAPHORE','DBMIRROR_DBM_EVENT','DBMIRROR_EVENTS_QUEUE','DBMIRROR_WORKER_QUEUE',
   'DBMIRRORING_CMD','DIRTY_PAGE_POLL','DISPATCHER_QUEUE_SEMAPHORE','EXECSYNC','FSAGENT',
   'FT_IFTS_SCHEDULER_IDLE_WAIT','FT_IFTSHC_MUTEX','HADR_CLUSAPI_CALL',
   'HADR_FILESTREAM_IOMGR_IOCOMPLETION','HADR_LOGCAPTURE_WAIT','HADR_NOTIFICATION_DEQUEUE',
   'HADR_TIMER_TASK','HADR_WORK_QUEUE','KSOURCE_WAKEUP','LAZYWRITER_SLEEP','LOGMGR_QUEUE',
   'MEMORY_ALLOCATION_EXT','ONDEMAND_TASK_QUEUE','PREEMPTIVE_XE_GETTARGETSTATE',
   'PWAIT_ALL_COMPONENTS_INITIALIZED','QDS_PERSIST_TASK_MAIN_LOOP_SLEEP','QDS_ASYNC_QUEUE',
   'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP','QDS_SHUTDOWN_QUEUE','REQUEST_FOR_DEADLOCK_SEARCH',
   'RESOURCE_QUEUE','SERVER_IDLE_CHECK','SLEEP_BPOOL_FLUSH','SLEEP_DBSTARTUP','SLEEP_DCOMSTARTUP',
   'SLEEP_MASTERDBREADY','SLEEP_MASTERMDREADY','SLEEP_MASTERUPGRADED','SLEEP_MSDBSTARTUP',
   'SLEEP_SYSTEMTASK','SLEEP_TASK','SLEEP_TEMPDBSTARTUP','SNI_HTTP_ACCEPT','SP_SERVER_DIAGNOSTICS_SLEEP',
   'SQLTRACE_BUFFER_FLUSH','SQLTRACE_INCREMENTAL_FLUSH_SLEEP','SQLTRACE_WAIT_ENTRIES',
   'WAIT_FOR_RESULTS','WAITFOR','WAITFOR_TASKSHUTDOWN','XE_BUFFERMGR_ALLPROCESSED_EVENT',
   'XE_DISPATCHER_JOIN','XE_DISPATCHER_WAIT','XE_LIVE_TARGET_TVF','XE_TIMER_EVENT','SOS_WORK_DISPATCHER'))
SELECT TOP 25 wait_type, waiting_tasks_count AS WaitCount,
 CAST(wait_time_ms/1000.0 AS DECIMAL(14,2)) AS TotalWait_s,
 CAST(resource_wait_ms/1000.0 AS DECIMAL(14,2)) AS ResourceWait_s,
 CAST(signal_wait_time_ms/1000.0 AS DECIMAL(14,2)) AS SignalWait_s,
 CAST(wait_time_ms/1.0/waiting_tasks_count AS DECIMAL(14,2)) AS AvgWait_ms,
 CAST(pct AS DECIMAL(5,2)) AS Pct
FROM waits ORDER BY wait_time_ms DESC;
"@ }

$sections["09_BufferByDatabase"] = @{ Db='master'; Q=@"
SELECT CASE database_id WHEN 32767 THEN 'RESOURCE_DB' ELSE DB_NAME(database_id) END AS DatabaseName,
 COUNT(*) AS BufferPages, CAST(COUNT(*)*8.0/1024 AS DECIMAL(12,2)) AS BufferMB
FROM sys.dm_os_buffer_descriptors GROUP BY database_id ORDER BY BufferPages DESC;
"@ }

$sections["10_MissingIndexes"] = @{ Db='master'; Q=@"
SELECT TOP 50 DB_NAME(mid.database_id) AS DatabaseName,
 OBJECT_NAME(mid.object_id, mid.database_id) AS TableName,
 CAST(migs.avg_total_user_cost*migs.avg_user_impact*(migs.user_seeks+migs.user_scans) AS DECIMAL(18,2)) AS ImprovementMeasure,
 migs.user_seeks+migs.user_scans AS SeeksScans, CAST(migs.avg_user_impact AS DECIMAL(5,1)) AS AvgImpactPct,
 migs.last_user_seek,
 'CREATE INDEX [IX_'+OBJECT_NAME(mid.object_id,mid.database_id)+'_'+
   REPLACE(REPLACE(REPLACE(ISNULL(mid.equality_columns,''),', ','_'),'[',''),']','')+
   CASE WHEN mid.inequality_columns IS NOT NULL THEN '_incl_ineq' ELSE '' END+'] ON '+mid.statement+
   ' ('+ISNULL(mid.equality_columns,'')+
   CASE WHEN mid.equality_columns IS NOT NULL AND mid.inequality_columns IS NOT NULL THEN ',' ELSE '' END+
   ISNULL(mid.inequality_columns,'')+')'+ISNULL(' INCLUDE ('+mid.included_columns+')','') AS Suggested_CREATE_INDEX
FROM sys.dm_db_missing_index_groups mig
JOIN sys.dm_db_missing_index_group_stats migs ON migs.group_handle=mig.index_group_handle
JOIN sys.dm_db_missing_index_details mid ON mig.index_handle=mid.index_handle
ORDER BY ImprovementMeasure DESC;
"@ }

$sections["11_IndexUsage"] = @{ Db='$TARGET'; Q=@"
SELECT OBJECT_SCHEMA_NAME(i.object_id) AS SchemaName, OBJECT_NAME(i.object_id) AS TableName,
 i.name AS IndexName, i.type_desc AS IndexType, i.is_primary_key AS IsPK, i.is_unique AS IsUnique,
 ISNULL(us.user_seeks,0) AS Seeks, ISNULL(us.user_scans,0) AS Scans, ISNULL(us.user_lookups,0) AS Lookups,
 ISNULL(us.user_seeks,0)+ISNULL(us.user_scans,0)+ISNULL(us.user_lookups,0) AS TotalReads,
 ISNULL(us.user_updates,0) AS Writes, us.last_user_seek, us.last_user_scan,
 CASE WHEN i.is_primary_key=0 AND i.is_unique=0
   AND ISNULL(us.user_seeks,0)+ISNULL(us.user_scans,0)+ISNULL(us.user_lookups,0)=0
   AND ISNULL(us.user_updates,0)>0 THEN 'UNUSED - consider DROP'
  WHEN ISNULL(us.user_updates,0) > (ISNULL(us.user_seeks,0)+ISNULL(us.user_scans,0)+ISNULL(us.user_lookups,0))*10
   AND ISNULL(us.user_updates,0)>1000 THEN 'Write-heavy / low read' ELSE '' END AS UsageWarning
FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats us ON us.object_id=i.object_id AND us.index_id=i.index_id AND us.database_id=DB_ID()
WHERE OBJECTPROPERTY(i.object_id,'IsUserTable')=1 AND i.type_desc<>'HEAP'
ORDER BY Writes DESC, TotalReads ASC;
"@ }

$sections["12_Fragmentation"] = @{ Db='$TARGET'; Q=@"
SELECT OBJECT_SCHEMA_NAME(ips.object_id) AS SchemaName, OBJECT_NAME(ips.object_id) AS TableName,
 i.name AS IndexName, i.type_desc AS IndexType, ips.partition_number AS [Partition],
 CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,2)) AS FragPct, ips.page_count AS Pages,
 CAST(ips.page_count*8.0/1024 AS DECIMAL(12,2)) AS SizeMB,
 ips.avg_page_space_used_in_percent AS AvgPageFullnessPct, i.fill_factor AS FillFactor,
 CASE WHEN ips.avg_fragmentation_in_percent>30 THEN 'REBUILD'
   WHEN ips.avg_fragmentation_in_percent>5 THEN 'REORGANIZE' ELSE 'OK' END AS Recommendation,
 CASE WHEN ips.avg_fragmentation_in_percent>30
   THEN 'ALTER INDEX ['+i.name+'] ON ['+OBJECT_SCHEMA_NAME(ips.object_id)+'].['+OBJECT_NAME(ips.object_id)+'] REBUILD WITH (ONLINE=OFF, SORT_IN_TEMPDB=ON);'
  WHEN ips.avg_fragmentation_in_percent>5
   THEN 'ALTER INDEX ['+i.name+'] ON ['+OBJECT_SCHEMA_NAME(ips.object_id)+'].['+OBJECT_NAME(ips.object_id)+'] REORGANIZE;'
  ELSE NULL END AS RemediationTSQL
FROM sys.dm_db_index_physical_stats(DB_ID(),NULL,NULL,NULL,'LIMITED') ips
JOIN sys.indexes i ON i.object_id=ips.object_id AND i.index_id=ips.index_id
WHERE ips.page_count>=1000 AND i.index_id>0 AND i.name IS NOT NULL
ORDER BY ips.avg_fragmentation_in_percent DESC;
"@ }

$sections["13_Heaps"] = @{ Db='$TARGET'; Q=@"
SELECT OBJECT_SCHEMA_NAME(i.object_id) AS SchemaName, OBJECT_NAME(i.object_id) AS TableName,
 ps.row_count AS [RowCount], CAST(ps.reserved_page_count*8.0/1024 AS DECIMAL(12,2)) AS ReservedMB,
 ISNULL(us.user_seeks,0)+ISNULL(us.user_scans,0)+ISNULL(us.user_lookups,0) AS Reads,
 ISNULL(us.user_updates,0) AS Writes
FROM sys.indexes i
JOIN sys.dm_db_partition_stats ps ON ps.object_id=i.object_id AND ps.index_id=i.index_id
LEFT JOIN sys.dm_db_index_usage_stats us ON us.object_id=i.object_id AND us.index_id=i.index_id AND us.database_id=DB_ID()
WHERE i.type_desc='HEAP' AND OBJECTPROPERTY(i.object_id,'IsUserTable')=1
ORDER BY ps.row_count DESC;
"@ }

$sections["14_DuplicateIndexes"] = @{ Db='$TARGET'; Q=@"
;WITH idx AS (SELECT i.object_id, i.index_id, i.name AS index_name,
   keys = STUFF((SELECT ','+c.name FROM sys.index_columns ic
     JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
     WHERE ic.object_id=i.object_id AND ic.index_id=i.index_id AND ic.is_included_column=0
     ORDER BY ic.key_ordinal FOR XML PATH('')),1,1,'')
 FROM sys.indexes i WHERE i.type IN (1,2) AND OBJECTPROPERTY(i.object_id,'IsUserTable')=1)
SELECT OBJECT_SCHEMA_NAME(a.object_id) AS SchemaName, OBJECT_NAME(a.object_id) AS TableName,
 a.index_name AS Index1, b.index_name AS Index2_Duplicate, a.keys AS KeyColumns
FROM idx a JOIN idx b ON a.object_id=b.object_id AND a.keys=b.keys AND a.index_id<b.index_id
ORDER BY TableName;
"@ }

$sections["15_StaleStatistics"] = @{ Db='$TARGET'; Q=@"
SELECT OBJECT_SCHEMA_NAME(s.object_id) AS SchemaName, OBJECT_NAME(s.object_id) AS TableName,
 s.name AS StatName, sp.last_updated AS LastUpdated, sp.rows AS [Rows],
 sp.modification_counter AS RowsModified,
 CAST(100.0*sp.modification_counter/NULLIF(sp.rows,0) AS DECIMAL(6,2)) AS PctModified
FROM sys.stats s CROSS APPLY sys.dm_db_stats_properties(s.object_id,s.stats_id) sp
WHERE OBJECTPROPERTY(s.object_id,'IsUserTable')=1 AND sp.rows>1000
 AND (sp.modification_counter>sp.rows*0.20 OR sp.last_updated<DATEADD(DAY,-30,GETDATE()))
ORDER BY PctModified DESC;
"@ }

$sections["16a_TopQueries_CPU"] = @{ Db='master'; Q=@"
SELECT TOP 20 qs.execution_count AS Execs,
 CAST(qs.total_worker_time/1000.0 AS DECIMAL(18,2)) AS TotalCPU_ms,
 CAST(qs.total_worker_time/1000.0/qs.execution_count AS DECIMAL(18,2)) AS AvgCPU_ms,
 CAST(qs.total_elapsed_time/1000.0/qs.execution_count AS DECIMAL(18,2)) AS AvgDuration_ms,
 qs.total_logical_reads/qs.execution_count AS AvgLogicalReads, DB_NAME(st.dbid) AS DatabaseName,
 SUBSTRING(st.text,(qs.statement_start_offset/2)+1,
   ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END
     - qs.statement_start_offset)/2)+1) AS QueryText
FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
ORDER BY qs.total_worker_time DESC;
"@ }

$sections["16b_TopQueries_Reads"] = @{ Db='master'; Q=@"
SELECT TOP 20 qs.execution_count AS Execs, qs.total_logical_reads AS TotalLogicalReads,
 qs.total_logical_reads/qs.execution_count AS AvgLogicalReads,
 CAST(qs.total_elapsed_time/1000.0/qs.execution_count AS DECIMAL(18,2)) AS AvgDuration_ms,
 DB_NAME(st.dbid) AS DatabaseName,
 SUBSTRING(st.text,(qs.statement_start_offset/2)+1,
   ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END
     - qs.statement_start_offset)/2)+1) AS QueryText
FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
ORDER BY qs.total_logical_reads DESC;
"@ }

$sections["17_BlockingActivity"] = @{ Db='master'; Q=@"
SELECT r.session_id AS SPID, r.blocking_session_id AS BlockedBy, r.status, r.wait_type,
 r.wait_time AS WaitTime_ms, r.wait_resource, r.cpu_time AS CPU_ms, r.total_elapsed_time AS Elapsed_ms,
 r.logical_reads AS LogicalReads, DB_NAME(r.database_id) AS DatabaseName,
 s.login_name, s.host_name, s.program_name,
 SUBSTRING(t.text,(r.statement_start_offset/2)+1,
   ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text) ELSE r.statement_end_offset END
     - r.statement_start_offset)/2)+1) AS CurrentStatement
FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id=r.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.session_id<>@@SPID AND s.is_user_process=1
ORDER BY r.blocking_session_id DESC, r.total_elapsed_time DESC;
"@ }

$sections["18_AgentJobFailures"] = @{ Db='master'; Q=@"
SELECT j.name AS JobName, j.enabled AS Enabled, h.run_status,
 msdb.dbo.agent_datetime(h.run_date,h.run_time) AS RunDateTime,
 STUFF(STUFF(RIGHT('000000'+CAST(h.run_duration AS VARCHAR(6)),6),5,0,':'),3,0,':') AS Duration_hhmmss,
 h.message
FROM msdb.dbo.sysjobs j JOIN msdb.dbo.sysjobhistory h ON h.job_id=j.job_id
WHERE h.step_id=0 AND h.run_status<>1
 AND msdb.dbo.agent_datetime(h.run_date,h.run_time)>DATEADD(DAY,-7,GETDATE())
ORDER BY RunDateTime DESC;
"@ }

$sections["19a_SysadminMembers"] = @{ Db='master'; Q=@"
SELECT sp.name AS LoginName, sp.type_desc AS LoginType, sp.is_disabled AS Disabled,
 sp.create_date, sp.modify_date
FROM sys.server_role_members rm
JOIN sys.server_principals sp ON sp.principal_id=rm.member_principal_id
JOIN sys.server_principals r ON r.principal_id=rm.role_principal_id
WHERE r.name='sysadmin' ORDER BY sp.name;
"@ }

$sections["19b_WeakSqlLogins"] = @{ Db='master'; Q=@"
SELECT name AS SqlLogin, is_policy_checked, is_expiration_checked, is_disabled, modify_date
FROM sys.sql_logins WHERE is_policy_checked=0 OR is_expiration_checked=0 ORDER BY name;
"@ }

$sections["20_TempDBFiles"] = @{ Db='master'; Q=@"
SELECT mf.name AS LogicalName, mf.type_desc AS FileType,
 CAST(mf.size*8.0/1024 AS DECIMAL(12,2)) AS SizeMB,
 CASE WHEN mf.is_percent_growth=1 THEN CAST(mf.growth AS VARCHAR(10))+' %'
   ELSE CAST(CAST(mf.growth*8.0/1024 AS DECIMAL(12,2)) AS VARCHAR(20))+' MB' END AS Autogrowth,
 mf.physical_name AS PhysicalPath
FROM sys.master_files mf WHERE mf.database_id=2 ORDER BY mf.type_desc DESC, mf.file_id;
"@ }

# --- Run each section, export CSV ---------------------------------------------
$summary = @()
foreach ($name in $sections.Keys) {
    $def     = $sections[$name]
    $db      = if ($def.Db -eq '$TARGET') { $TargetDatabase } else { $def.Db }
    $csvPath = Join-Path $outDir ("{0}.csv" -f $name)
    Write-Host ("Running {0,-26} (db: {1}) ..." -f $name, $db) -NoNewline
    try {
        $rows = Invoke-Sqlcmd @auth -Database $db -Query $def.Q
        if ($null -eq $rows) { $rows = @() }
        # Force array so single-row results still export with headers
        @($rows) | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        $count = @($rows).Count
        Write-Host (" {0} rows -> {1}" -f $count, (Split-Path $csvPath -Leaf)) -ForegroundColor Green
        $summary += [pscustomobject]@{ Section=$name; Database=$db; Rows=$count; Status='OK'; File="$name.csv" }
    }
    catch {
        Write-Host " FAILED" -ForegroundColor Red
        Write-Warning ("  {0}: {1}" -f $name, $_.Exception.Message)
        $summary += [pscustomobject]@{ Section=$name; Database=$db; Rows=0; Status='ERROR: '+$_.Exception.Message; File='' }
    }
}

# Manifest of what ran
$summary | Export-Csv -Path (Join-Path $outDir "00_RunSummary.csv") -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "Done. $($summary.Count) sections. CSVs in:" -ForegroundColor Cyan
Write-Host "  $outDir" -ForegroundColor Yellow
$summary | Format-Table -AutoSize
