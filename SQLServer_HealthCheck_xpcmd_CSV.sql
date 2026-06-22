/*==============================================================================
  SQL SERVER 2017 - HEALTH CHECK  ->  ONE CSV PER SECTION  (xp_cmdshell + bcp)
  ----------------------------------------------------------------------------
  Writes each diagnostic section to its own .csv file using bcp, driven entirely
  from T-SQL via xp_cmdshell. Column headers are added automatically using
  sys.dm_exec_describe_first_result_set.

  >> SECURITY WARNING <<
  This script ENABLES xp_cmdshell (a powerful, often-disabled feature that lets
  SQL Server run OS commands). It is disabled again at the very end IF it was
  off before you started. Run only on a server where you are authorised to.

  REQUIREMENTS
   - sysadmin (to toggle xp_cmdshell).
   - The SQL Server *service account* must have WRITE access to @OutDir, and
     bcp.exe must be on the server's PATH (installed with SQL tools).
   - bcp connects back to the instance; default uses -T (trusted = the service
     account). For SQL auth, set @BcpAuth below.

  CAVEAT (CSV + commas)
   - bcp does NOT quote fields. Free-text columns (query text, job messages)
     have commas/newlines stripped to spaces so rows stay intact. If any other
     text could contain commas, switch @Delim to '|' (pipe) - Excel opens it via
     Data > From Text, or just rename .csv handling.
  ----------------------------------------------------------------------------
  EDIT THE 3 SETTINGS BELOW, THEN RUN THE WHOLE SCRIPT.
==============================================================================*/
SET NOCOUNT ON;

------------------------------------------------------------------- SETTINGS ----
DECLARE @OutDir     VARCHAR(260) = 'C:\SQLHealthCheck\';   -- MUST end with backslash
DECLARE @TargetDB   SYSNAME      = DB_NAME();              -- DB for per-database sections (11-15)
DECLARE @Delim      CHAR(1)      = ',';                    -- ',' for CSV, or '|' if data has commas
DECLARE @BcpAuth    VARCHAR(200) = ' -T ';                 -- trusted. For SQL auth: ' -U sa -P P@ssw0rd '
--------------------------------------------------------------------------------

DECLARE @srv SYSNAME = CONVERT(SYSNAME, SERVERPROPERTY('ServerName'));
DECLARE @wasOff BIT  = 0;

-- 1) Enable xp_cmdshell (remember prior state) ---------------------------------
IF EXISTS (SELECT 1 FROM sys.configurations WHERE name='xp_cmdshell' AND value_in_use=0)
    SET @wasOff = 1;

EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'xp_cmdshell', 1;          RECONFIGURE;

-- 2) Create output folder ------------------------------------------------------
DECLARE @dirNoSlash VARCHAR(260) =
    CASE WHEN RIGHT(@OutDir,1)='\' THEN LEFT(@OutDir, LEN(@OutDir)-1) ELSE @OutDir END;
DECLARE @mk VARCHAR(600) = 'if not exist "'+@dirNoSlash+'" mkdir "'+@dirNoSlash+'"';
EXEC xp_cmdshell @mk, no_output;

-- 3) Section catalogue ---------------------------------------------------------
--    Scope: 'S' = server-wide (runs in master) ; 'D' = per-database (@TargetDB)
IF OBJECT_ID('tempdb..#sections') IS NOT NULL DROP TABLE #sections;
CREATE TABLE #sections (seq INT IDENTITY, name VARCHAR(60), scope CHAR(1), q NVARCHAR(MAX));

INSERT INTO #sections (name, scope, q) VALUES
('01_InstanceOverview','S',
 N'SELECT @@SERVERNAME AS ServerName, CAST(SERVERPROPERTY(''MachineName'') AS NVARCHAR(128)) AS MachineName, CAST(SERVERPROPERTY(''ProductVersion'') AS NVARCHAR(50)) AS ProductVersion, CAST(SERVERPROPERTY(''ProductLevel'') AS NVARCHAR(50)) AS ProductLevel, CAST(SERVERPROPERTY(''Edition'') AS NVARCHAR(100)) AS Edition, CAST(SERVERPROPERTY(''Collation'') AS NVARCHAR(100)) AS ServerCollation, DATEDIFF(HOUR,(SELECT sqlserver_start_time FROM sys.dm_os_sys_info),GETDATE()) AS Uptime_Hours'),

('02_Configuration','S',
 N'SELECT name AS ConfigName, CAST(value AS BIGINT) AS ConfiguredValue, CAST(value_in_use AS BIGINT) AS RunningValue, CASE WHEN value<>value_in_use THEN ''PENDING RESTART'' ELSE '''' END AS Note FROM sys.configurations WHERE name IN (''max server memory (MB)'',''min server memory (MB)'',''max degree of parallelism'',''cost threshold for parallelism'',''optimize for ad hoc workloads'',''backup compression default'',''fill factor (%)'',''max worker threads'') ORDER BY name'),

('03_DatabaseSettings','S',
 N'SELECT name AS DatabaseName, state_desc AS State, recovery_model_desc AS RecoveryModel, compatibility_level AS CompatLevel, page_verify_option_desc AS PageVerify, is_auto_shrink_on AS AutoShrink, is_auto_close_on AS AutoClose, is_auto_update_stats_on AS AutoUpdateStats, is_read_committed_snapshot_on AS RCSI, SUSER_SNAME(owner_sid) AS DBOwner FROM sys.databases ORDER BY name'),

('04_FilesAndAutogrowth','S',
 N'SELECT DB_NAME(database_id) AS DatabaseName, type_desc AS FileType, name AS LogicalName, physical_name AS PhysicalPath, CAST(size*8.0/1024 AS DECIMAL(12,2)) AS SizeMB, is_percent_growth AS PctGrowth FROM sys.master_files ORDER BY DB_NAME(database_id), type_desc DESC'),

('05_BackupStatus','S',
 N'SELECT d.name AS DatabaseName, d.recovery_model_desc AS RecoveryModel, b.LastFull, DATEDIFF(HOUR,b.LastFull,GETDATE()) AS FullAge_Hrs, b.LastLog, CASE WHEN b.LastFull IS NULL THEN ''NEVER BACKED UP'' WHEN DATEDIFF(HOUR,b.LastFull,GETDATE())>24 THEN ''Full > 24h old'' ELSE ''OK'' END AS BackupWarning FROM sys.databases d LEFT JOIN (SELECT database_name, MAX(CASE WHEN type=''D'' THEN backup_finish_date END) AS LastFull, MAX(CASE WHEN type=''L'' THEN backup_finish_date END) AS LastLog FROM msdb.dbo.backupset GROUP BY database_name) b ON b.database_name=d.name WHERE d.database_id<>2 ORDER BY BackupWarning DESC, d.name'),

('06_LogReuseWait','S',
 N'SELECT name AS DatabaseName, recovery_model_desc AS RecoveryModel, log_reuse_wait_desc AS LogReuseWait FROM sys.databases ORDER BY name'),

('08_WaitStats','S',
 N'SELECT TOP 25 wait_type, waiting_tasks_count AS WaitCount, CAST(wait_time_ms/1000.0 AS DECIMAL(14,2)) AS TotalWait_s, CAST(signal_wait_time_ms/1000.0 AS DECIMAL(14,2)) AS SignalWait_s FROM sys.dm_os_wait_stats WHERE waiting_tasks_count>0 AND wait_type NOT IN (''SLEEP_TASK'',''LAZYWRITER_SLEEP'',''WAITFOR'',''SLEEP_SYSTEMTASK'',''BROKER_TASK_STOP'',''CHECKPOINT_QUEUE'',''XE_TIMER_EVENT'',''XE_DISPATCHER_WAIT'',''REQUEST_FOR_DEADLOCK_SEARCH'',''LOGMGR_QUEUE'',''DIRTY_PAGE_POLL'',''HADR_FILESTREAM_IOMGR_IOCOMPLETION'',''DISPATCHER_QUEUE_SEMAPHORE'',''SQLTRACE_INCREMENTAL_FLUSH_SLEEP'',''CLR_AUTO_EVENT'',''CLR_MANUAL_EVENT'',''FT_IFTS_SCHEDULER_IDLE_WAIT'',''BROKER_TO_FLUSH'',''SP_SERVER_DIAGNOSTICS_SLEEP'',''QDS_PERSIST_TASK_MAIN_LOOP_SLEEP'',''QDS_ASYNC_QUEUE'',''SLEEP_BPOOL_FLUSH'') ORDER BY wait_time_ms DESC'),

('09_BufferByDatabase','S',
 N'SELECT CASE database_id WHEN 32767 THEN ''RESOURCE_DB'' ELSE DB_NAME(database_id) END AS DatabaseName, COUNT(*) AS BufferPages, CAST(COUNT(*)*8.0/1024 AS DECIMAL(12,2)) AS BufferMB FROM sys.dm_os_buffer_descriptors GROUP BY database_id ORDER BY BufferPages DESC'),

('10_MissingIndexes','S',
 N'SELECT TOP 50 DB_NAME(mid.database_id) AS DatabaseName, OBJECT_NAME(mid.object_id, mid.database_id) AS TableName, CAST(migs.avg_total_user_cost*migs.avg_user_impact*(migs.user_seeks+migs.user_scans) AS DECIMAL(18,2)) AS ImprovementMeasure, migs.user_seeks+migs.user_scans AS SeeksScans, CAST(migs.avg_user_impact AS DECIMAL(5,1)) AS AvgImpactPct, mid.equality_columns AS EqualityCols, mid.inequality_columns AS InequalityCols, mid.included_columns AS IncludedCols, mid.statement AS TableStatement FROM sys.dm_db_missing_index_groups mig JOIN sys.dm_db_missing_index_group_stats migs ON migs.group_handle=mig.index_group_handle JOIN sys.dm_db_missing_index_details mid ON mig.index_handle=mid.index_handle ORDER BY ImprovementMeasure DESC'),

('11_IndexUsage','D',
 N'SELECT OBJECT_SCHEMA_NAME(i.object_id) AS SchemaName, OBJECT_NAME(i.object_id) AS TableName, i.name AS IndexName, i.type_desc AS IndexType, ISNULL(us.user_seeks,0)+ISNULL(us.user_scans,0)+ISNULL(us.user_lookups,0) AS TotalReads, ISNULL(us.user_updates,0) AS Writes, CASE WHEN i.is_primary_key=0 AND i.is_unique=0 AND ISNULL(us.user_seeks,0)+ISNULL(us.user_scans,0)+ISNULL(us.user_lookups,0)=0 AND ISNULL(us.user_updates,0)>0 THEN ''UNUSED-consider DROP'' ELSE '''' END AS UsageWarning FROM sys.indexes i LEFT JOIN sys.dm_db_index_usage_stats us ON us.object_id=i.object_id AND us.index_id=i.index_id AND us.database_id=DB_ID() WHERE OBJECTPROPERTY(i.object_id,''IsUserTable'')=1 AND i.type_desc<>''HEAP'' ORDER BY Writes DESC, TotalReads ASC'),

('12_Fragmentation','D',
 N'SELECT OBJECT_SCHEMA_NAME(ips.object_id) AS SchemaName, OBJECT_NAME(ips.object_id) AS TableName, i.name AS IndexName, CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,2)) AS FragPct, ips.page_count AS Pages, CAST(ips.page_count*8.0/1024 AS DECIMAL(12,2)) AS SizeMB, CASE WHEN ips.avg_fragmentation_in_percent>30 THEN ''REBUILD'' WHEN ips.avg_fragmentation_in_percent>5 THEN ''REORGANIZE'' ELSE ''OK'' END AS Recommendation FROM sys.dm_db_index_physical_stats(DB_ID(),NULL,NULL,NULL,''LIMITED'') ips JOIN sys.indexes i ON i.object_id=ips.object_id AND i.index_id=ips.index_id WHERE ips.page_count>=1000 AND i.index_id>0 AND i.name IS NOT NULL ORDER BY ips.avg_fragmentation_in_percent DESC'),

('13_Heaps','D',
 N'SELECT OBJECT_SCHEMA_NAME(i.object_id) AS SchemaName, OBJECT_NAME(i.object_id) AS TableName, ps.row_count AS RowCnt, CAST(ps.reserved_page_count*8.0/1024 AS DECIMAL(12,2)) AS ReservedMB FROM sys.indexes i JOIN sys.dm_db_partition_stats ps ON ps.object_id=i.object_id AND ps.index_id=i.index_id WHERE i.type_desc=''HEAP'' AND OBJECTPROPERTY(i.object_id,''IsUserTable'')=1 ORDER BY ps.row_count DESC'),

('14_DuplicateIndexes','D',
 N'WITH idx AS (SELECT i.object_id, i.index_id, i.name AS index_name, keys=STUFF((SELECT '',''+c.name FROM sys.index_columns ic JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id WHERE ic.object_id=i.object_id AND ic.index_id=i.index_id AND ic.is_included_column=0 ORDER BY ic.key_ordinal FOR XML PATH('''')),1,1,'''') FROM sys.indexes i WHERE i.type IN (1,2) AND OBJECTPROPERTY(i.object_id,''IsUserTable'')=1) SELECT OBJECT_SCHEMA_NAME(a.object_id) AS SchemaName, OBJECT_NAME(a.object_id) AS TableName, a.index_name AS Index1, b.index_name AS Index2_Duplicate, a.keys AS KeyColumns FROM idx a JOIN idx b ON a.object_id=b.object_id AND a.keys=b.keys AND a.index_id<b.index_id ORDER BY TableName'),

('15_StaleStatistics','D',
 N'SELECT OBJECT_SCHEMA_NAME(s.object_id) AS SchemaName, OBJECT_NAME(s.object_id) AS TableName, s.name AS StatName, sp.last_updated AS LastUpdated, sp.rows AS Rws, sp.modification_counter AS RowsModified, CAST(100.0*sp.modification_counter/NULLIF(sp.rows,0) AS DECIMAL(6,2)) AS PctModified FROM sys.stats s CROSS APPLY sys.dm_db_stats_properties(s.object_id,s.stats_id) sp WHERE OBJECTPROPERTY(s.object_id,''IsUserTable'')=1 AND sp.rows>1000 AND (sp.modification_counter>sp.rows*0.20 OR sp.last_updated<DATEADD(DAY,-30,GETDATE())) ORDER BY PctModified DESC'),

('16a_TopQueries_CPU','S',
 N'SELECT TOP 20 qs.execution_count AS Execs, CAST(qs.total_worker_time/1000.0 AS DECIMAL(18,2)) AS TotalCPU_ms, CAST(qs.total_worker_time/1000.0/qs.execution_count AS DECIMAL(18,2)) AS AvgCPU_ms, qs.total_logical_reads/qs.execution_count AS AvgLogicalReads, DB_NAME(st.dbid) AS DatabaseName, REPLACE(REPLACE(REPLACE(SUBSTRING(st.text,(qs.statement_start_offset/2)+1,((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END - qs.statement_start_offset)/2)+1),CHAR(13),'' ''),CHAR(10),'' ''),'','','' '') AS QueryText FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st ORDER BY qs.total_worker_time DESC'),

('16b_TopQueries_Reads','S',
 N'SELECT TOP 20 qs.execution_count AS Execs, qs.total_logical_reads AS TotalLogicalReads, qs.total_logical_reads/qs.execution_count AS AvgLogicalReads, DB_NAME(st.dbid) AS DatabaseName, REPLACE(REPLACE(REPLACE(SUBSTRING(st.text,(qs.statement_start_offset/2)+1,((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END - qs.statement_start_offset)/2)+1),CHAR(13),'' ''),CHAR(10),'' ''),'','','' '') AS QueryText FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st ORDER BY qs.total_logical_reads DESC'),

('17_BlockingActivity','S',
 N'SELECT r.session_id AS SPID, r.blocking_session_id AS BlockedBy, r.status, r.wait_type, r.wait_time AS WaitTime_ms, r.cpu_time AS CPU_ms, r.total_elapsed_time AS Elapsed_ms, DB_NAME(r.database_id) AS DatabaseName, s.login_name, s.host_name, REPLACE(REPLACE(REPLACE(SUBSTRING(t.text,(r.statement_start_offset/2)+1,((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text) ELSE r.statement_end_offset END - r.statement_start_offset)/2)+1),CHAR(13),'' ''),CHAR(10),'' ''),'','','' '') AS CurrentStatement FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id=r.session_id CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t WHERE s.is_user_process=1 ORDER BY r.blocking_session_id DESC, r.total_elapsed_time DESC'),

('18_AgentJobFailures','S',
 N'SELECT j.name AS JobName, j.enabled AS Enabled, h.run_status AS RunStatus, msdb.dbo.agent_datetime(h.run_date,h.run_time) AS RunDateTime, h.run_duration AS RunDurationRaw, REPLACE(REPLACE(REPLACE(h.message,CHAR(13),'' ''),CHAR(10),'' ''),'','','' '') AS Message FROM msdb.dbo.sysjobs j JOIN msdb.dbo.sysjobhistory h ON h.job_id=j.job_id WHERE h.step_id=0 AND h.run_status<>1 AND msdb.dbo.agent_datetime(h.run_date,h.run_time)>DATEADD(DAY,-7,GETDATE()) ORDER BY RunDateTime DESC'),

('19a_SysadminMembers','S',
 N'SELECT sp.name AS LoginName, sp.type_desc AS LoginType, sp.is_disabled AS Disabled, sp.create_date AS CreateDate, sp.modify_date AS ModifyDate FROM sys.server_role_members rm JOIN sys.server_principals sp ON sp.principal_id=rm.member_principal_id JOIN sys.server_principals r ON r.principal_id=rm.role_principal_id WHERE r.name=''sysadmin'' ORDER BY sp.name'),

('19b_WeakSqlLogins','S',
 N'SELECT name AS SqlLogin, is_policy_checked AS PolicyChecked, is_expiration_checked AS ExpirationChecked, is_disabled AS Disabled, modify_date AS ModifyDate FROM sys.sql_logins WHERE is_policy_checked=0 OR is_expiration_checked=0 ORDER BY name'),

('20_TempDBFiles','S',
 N'SELECT name AS LogicalName, type_desc AS FileType, CAST(size*8.0/1024 AS DECIMAL(12,2)) AS SizeMB, is_percent_growth AS PctGrowth, physical_name AS PhysicalPath FROM sys.master_files WHERE database_id=2 ORDER BY type_desc DESC, file_id');

-- 4) Loop: build header + bcp data + combine ----------------------------------
IF OBJECT_ID('tempdb..#log') IS NOT NULL DROP TABLE #log;
CREATE TABLE #log (id INT IDENTITY, section VARCHAR(60), bcp_output NVARCHAR(500));

DECLARE @seq INT, @name VARCHAR(60), @scope CHAR(1), @q NVARCHAR(MAX);
DECLARE @db SYSNAME, @file VARCHAR(400), @tmp VARCHAR(400), @hdr NVARCHAR(MAX), @cmd VARCHAR(8000);

DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT seq,name,scope,q FROM #sections ORDER BY seq;
OPEN c;
FETCH NEXT FROM c INTO @seq,@name,@scope,@q;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @db   = CASE WHEN @scope='D' THEN @TargetDB ELSE 'master' END;
    SET @file = @OutDir + @name + '.csv';
    SET @tmp  = @OutDir + @name + '.tmp';

    -- 4a) Header line from the query's result-set shape
    SET @hdr = NULL;
    BEGIN TRY
        SELECT @hdr = STRING_AGG(CAST(name AS NVARCHAR(MAX)), @Delim) WITHIN GROUP (ORDER BY column_ordinal)
        FROM sys.dm_exec_describe_first_result_set(@q, NULL, 0)
        WHERE is_hidden = 0;
    END TRY
    BEGIN CATCH SET @hdr = NULL; END CATCH;

    -- 4b) Write header (overwrites/creates the .csv)
    IF @hdr IS NOT NULL
    BEGIN
        SET @cmd = 'echo ' + @hdr + '>"' + @file + '"';
        EXEC xp_cmdshell @cmd, no_output;
    END

    -- 4c) bcp the data to a temp file
    SET @cmd = 'bcp "' + @q + '" queryout "' + @tmp + '" -c -t' + @Delim
             + ' -S "' + @srv + '"' + @BcpAuth + ' -d "' + @db + '"';
    INSERT INTO #log (bcp_output)          -- xp_cmdshell returns ONE column only
    EXEC xp_cmdshell @cmd;
    UPDATE #log SET section=@name WHERE section IS NULL;

    -- 4d) Append data to the .csv, then remove temp
    SET @cmd = 'if exist "' + @tmp + '" type "' + @tmp + '" >> "' + @file + '"';
    EXEC xp_cmdshell @cmd, no_output;
    SET @cmd = 'if exist "' + @tmp + '" del "' + @tmp + '"';
    EXEC xp_cmdshell @cmd, no_output;

    FETCH NEXT FROM c INTO @seq,@name,@scope,@q;
END
CLOSE c; DEALLOCATE c;

-- 5) Report --------------------------------------------------------------------
PRINT '===== CSV export complete. Files in: ' + @OutDir + ' =====';
SELECT section, bcp_output
FROM #log
WHERE bcp_output IS NOT NULL AND bcp_output LIKE '%rows copied%'
ORDER BY id;

-- Full bcp log (uncomment to see errors / details per section)
-- SELECT * FROM #log ORDER BY id;

-- 6) Restore xp_cmdshell to its previous state --------------------------------
IF @wasOff = 1
BEGIN
    EXEC sp_configure 'xp_cmdshell', 0; RECONFIGURE;
    PRINT 'xp_cmdshell disabled again (it was off before this run).';
END
GO
