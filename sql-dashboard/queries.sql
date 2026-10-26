/* =========================================================================
   SQL Server Health Dashboard - health-check queries (all read-only)

   Start-Dashboard.ps1 runs every section below against each configured
   SQL Server. A section starts with a line:   -- @check <id> [timeout=<seconds>]
   and runs until the next one. You can test any section in SSMS on its own.
   Thresholds (days, minutes, percentages) are variables at the top of each
   section - change them there.
   ========================================================================= */

-- @check summary
/*  Server overview - feeds the dashboard landing page
    Result sets (the UI reads them by position and column name):
      1. Summary    - one row: identity, version, CPU, memory, databases, alerts
      2. Disks      - volumes holding database files
      3. Databases  - every database with its allocated size (largest first)
    Required permissions: VIEW SERVER STATE, read access to msdb
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @start datetime, @cpus int, @memMB bigint, @sqlCpu int, @otherCpu int,
        @totalMB bigint, @targetMB bigint, @ple bigint, @maxMemMB bigint, @grants bigint,
        @sessions int, @requests int, @blocked int, @runningBackups int,
        @failedJobs int, @missingFull int, @host nvarchar(256), @maxdop int, @ctfp int;

CREATE TABLE #cpu (EventTime datetime, SqlCpu int, OtherCpu int);

BEGIN TRY
    SELECT @start = sqlserver_start_time, @cpus = cpu_count, @memMB = physical_memory_kb / 1024
    FROM sys.dm_os_sys_info;

    DECLARE @now bigint = (SELECT ms_ticks FROM sys.dm_os_sys_info);
    INSERT #cpu (EventTime, SqlCpu, OtherCpu)
    SELECT TOP (60)
           DATEADD(MILLISECOND, -1 * (@now - x.[timestamp]), GETDATE()),
           v.SqlCpu,
           CASE WHEN 100 - v.Idle - v.SqlCpu < 0 THEN 0 ELSE 100 - v.Idle - v.SqlCpu END
    FROM (SELECT [timestamp], rec = CONVERT(xml, record)
          FROM sys.dm_os_ring_buffers
          WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND record LIKE N'%<SystemHealth>%') x
    CROSS APPLY (SELECT SqlCpu = x.rec.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int'),
                        Idle   = x.rec.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int')) v
    ORDER BY x.[timestamp] DESC;
    SELECT TOP (1) @sqlCpu = SqlCpu, @otherCpu = OtherCpu FROM #cpu ORDER BY EventTime DESC;

    SELECT @totalMB  = MAX(CASE WHEN counter_name = 'Total Server Memory (KB)'  THEN cntr_value ELSE 0 END) / 1024,
           @targetMB = MAX(CASE WHEN counter_name = 'Target Server Memory (KB)' THEN cntr_value ELSE 0 END) / 1024,
           @grants   = MAX(CASE WHEN counter_name = 'Memory Grants Pending'     THEN cntr_value ELSE 0 END)
    FROM sys.dm_os_performance_counters
    WHERE object_name LIKE '%Memory Manager%';
    SELECT @ple = cntr_value FROM sys.dm_os_performance_counters
    WHERE object_name LIKE '%Buffer Manager%' AND counter_name = 'Page life expectancy';

    SELECT @sessions = COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1;
    SELECT @requests = COUNT(*),
           @blocked = SUM(CASE WHEN r.blocking_session_id > 0 AND r.blocking_session_id <> r.session_id THEN 1 ELSE 0 END),
           @runningBackups = SUM(CASE WHEN r.command LIKE 'BACKUP%' OR r.command LIKE 'RESTORE%' THEN 1 ELSE 0 END)
    FROM sys.dm_exec_requests r
    JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
    WHERE (s.is_user_process = 1 OR r.command LIKE 'BACKUP%' OR r.command LIKE 'RESTORE%') AND r.session_id <> @@SPID;
END TRY
BEGIN CATCH
    PRINT 'Some server metrics are unavailable (VIEW SERVER STATE required): ' + ERROR_MESSAGE();
END CATCH;

-- Host OS: sys.dm_os_host_info exists on SQL Server 2017+; otherwise parse @@VERSION.
BEGIN TRY
    EXEC sys.sp_executesql N'SELECT @h = host_distribution + ISNULL('' '' + NULLIF(host_service_pack_level, ''''), '''') FROM sys.dm_os_host_info',
                           N'@h nvarchar(256) OUTPUT', @host OUTPUT;
END TRY
BEGIN CATCH
    SET @host = NULL;
END CATCH;
IF @host IS NULL AND CHARINDEX(' on ', @@VERSION) > 0
    SET @host = LTRIM(RTRIM(REPLACE(REPLACE(SUBSTRING(@@VERSION, CHARINDEX(' on ', @@VERSION) + 4, 200), CHAR(10), ''), CHAR(13), '')));

SELECT @maxMemMB = CAST(value_in_use AS bigint) FROM sys.configurations WHERE name = 'max server memory (MB)';
SELECT @maxdop   = CAST(value_in_use AS int)    FROM sys.configurations WHERE name = 'max degree of parallelism';
SELECT @ctfp     = CAST(value_in_use AS int)    FROM sys.configurations WHERE name = 'cost threshold for parallelism';

BEGIN TRY
    SELECT @missingFull = COUNT(*)
    FROM sys.databases d
    WHERE d.database_id <> 2 AND d.state = 0 AND d.source_database_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM msdb.dbo.backupset b
                      WHERE b.database_name = d.name AND b.type = 'D'
                        AND b.backup_finish_date >= DATEADD(DAY, -7, GETDATE()));

    SELECT @failedJobs = COUNT(DISTINCT h.job_id)
    FROM msdb.dbo.sysjobhistory h
    WHERE h.step_id = 0 AND h.run_status = 0
      AND h.run_date >= CONVERT(int, CONVERT(char(8), DATEADD(DAY, -1, GETDATE()), 112))
      AND DATEADD(SECOND, (h.run_time / 10000) * 3600 + (h.run_time / 100 % 100) * 60 + h.run_time % 100,
                  CONVERT(datetime, CAST(h.run_date AS char(8)), 112)) >= DATEADD(HOUR, -24, GETDATE());
END TRY
BEGIN CATCH
    PRINT 'Backup / job history unavailable (msdb read access required): ' + ERROR_MESSAGE();
END CATCH;

-- ---- 1. Summary ------------------------------------------------------------
;WITH f AS (
    SELECT database_id,
           DataMB = SUM(CASE WHEN type <> 1 THEN CAST(size AS bigint) ELSE 0 END) * 8 / 1024.0,
           LogMB  = SUM(CASE WHEN type = 1 THEN CAST(size AS bigint) ELSE 0 END) * 8 / 1024.0
    FROM sys.master_files GROUP BY database_id
)
SELECT ServerName        = CAST(SERVERPROPERTY('ServerName') AS nvarchar(256)),
       MachineName       = CAST(SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS nvarchar(256)),
       InstanceName      = ISNULL(CAST(SERVERPROPERTY('InstanceName') AS nvarchar(128)), 'MSSQLSERVER'),
       ProductVersion    = CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)),
       ProductLevel      = CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(64)),
       UpdateLevel       = CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(64)),
       Edition           = CAST(SERVERPROPERTY('Edition') AS nvarchar(128)),
       Collation         = CAST(SERVERPROPERTY('Collation') AS nvarchar(128)),
       HostPlatform      = @host,
       IsClustered       = CAST(ISNULL(SERVERPROPERTY('IsClustered'), 0) AS bit),
       IsHadrEnabled     = CAST(ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0) AS bit),
       StartTime         = @start,
       UptimeMinutes     = DATEDIFF(MINUTE, @start, GETDATE()),
       LogicalCpus       = @cpus,
       SqlCpuPct         = @sqlCpu,
       OtherCpuPct       = @otherCpu,
       PhysicalMemoryMB  = @memMB,
       MaxServerMemoryMB = @maxMemMB,
       TotalServerMemoryMB  = @totalMB,
       TargetServerMemoryMB = @targetMB,
       PageLifeExpectancy   = @ple,
       MemoryGrantsPending  = @grants,
       MaxDop            = @maxdop,
       CostThreshold     = @ctfp,
       UserSessions      = @sessions,
       ActiveRequests    = @requests,
       BlockedRequests   = ISNULL(@blocked, 0),
       RunningBackups    = ISNULL(@runningBackups, 0),
       BackupsMissing7d  = @missingFull,
       FailedJobs24h     = @failedJobs,
       DatabaseCount     = (SELECT COUNT(*) FROM sys.databases WHERE source_database_id IS NULL),
       UserDatabases     = (SELECT COUNT(*) FROM sys.databases WHERE database_id > 4 AND source_database_id IS NULL),
       OnlineDatabases   = (SELECT COUNT(*) FROM sys.databases WHERE state = 0 AND source_database_id IS NULL),
       DataSizeMB        = CAST((SELECT SUM(DataMB) FROM f) AS decimal(18, 1)),
       LogSizeMB         = CAST((SELECT SUM(LogMB) FROM f) AS decimal(18, 1)),
       ServerTime        = GETDATE();

-- ---- 2. Disks --------------------------------------------------------------
BEGIN TRY
    ;WITH v AS (
        SELECT vs.volume_mount_point, vs.logical_volume_name, vs.total_bytes, vs.available_bytes, Files = COUNT(*)
        FROM sys.master_files mf
        JOIN sys.databases d ON d.database_id = mf.database_id AND d.state = 0
        CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
        GROUP BY vs.volume_mount_point, vs.logical_volume_name, vs.total_bytes, vs.available_bytes
    )
    SELECT Volume  = volume_mount_point,
           Label   = logical_volume_name,
           TotalGB = CAST(total_bytes / 1073741824.0 AS decimal(18, 1)),
           FreeGB  = CAST(available_bytes / 1073741824.0 AS decimal(18, 1)),
           FreePct = CAST(available_bytes * 100.0 / NULLIF(total_bytes, 0) AS decimal(5, 1)),
           DatabaseFiles = Files
    FROM v
    ORDER BY volume_mount_point;
END TRY
BEGIN CATCH
    PRINT 'Disk information unavailable: ' + ERROR_MESSAGE();
    SELECT Volume = CAST(NULL AS nvarchar(256)), Label = CAST(NULL AS nvarchar(256)), TotalGB = CAST(NULL AS decimal(18, 1)),
           FreeGB = CAST(NULL AS decimal(18, 1)), FreePct = CAST(NULL AS decimal(5, 1)), DatabaseFiles = CAST(NULL AS int)
    WHERE 1 = 0;
END CATCH;

-- ---- 3. Databases by size ---------------------------------------------------
SELECT DatabaseName  = d.name,
       State         = d.state_desc,
       RecoveryModel = d.recovery_model_desc,
       DataMB        = CAST(SUM(CASE WHEN mf.type <> 1 THEN CAST(mf.size AS bigint) ELSE 0 END) * 8 / 1024.0 AS decimal(18, 1)),
       LogMB         = CAST(SUM(CASE WHEN mf.type = 1 THEN CAST(mf.size AS bigint) ELSE 0 END) * 8 / 1024.0 AS decimal(18, 1)),
       IsSystem      = CAST(CASE WHEN d.database_id <= 4 THEN 1 ELSE 0 END AS bit)
FROM sys.databases d
JOIN sys.master_files mf ON mf.database_id = d.database_id
WHERE d.source_database_id IS NULL
GROUP BY d.name, d.state_desc, d.recovery_model_desc, d.database_id
ORDER BY SUM(CAST(mf.size AS bigint)) DESC;

-- @check databases
/*  Database state, size and transaction-log usage
    Required permissions: VIEW SERVER STATE (for DBCC SQLPERF)
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @logWarnPct int = 75;
DECLARE @logCritPct int = 90;

CREATE TABLE #log (DatabaseName sysname, LogSizeMB float, LogUsedPct float, Status int);
BEGIN TRY
    INSERT #log EXEC ('DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS');
END TRY
BEGIN CATCH
    PRINT 'Log usage unavailable: ' + ERROR_MESSAGE();
END CATCH;

SELECT Status = CASE
           WHEN d.state_desc IN ('SUSPECT', 'RECOVERY_PENDING', 'EMERGENCY') THEN 'CRITICAL'
           WHEN l.LogUsedPct >= @logCritPct THEN 'CRITICAL'
           WHEN d.state_desc = 'OFFLINE' THEN 'WARNING'
           WHEN l.LogUsedPct >= @logWarnPct THEN 'WARNING'
           WHEN d.is_auto_shrink_on = 1 OR d.user_access_desc <> 'MULTI_USER' THEN 'WARNING'
           WHEN d.state_desc <> 'ONLINE' THEN 'INFO'
           WHEN d.page_verify_option_desc <> 'CHECKSUM' OR d.is_auto_close_on = 1 THEN 'INFO'
           ELSE 'OK' END,
       DatabaseName   = d.name,
       State          = d.state_desc,
       Access         = d.user_access_desc,
       RecoveryModel  = d.recovery_model_desc,
       DataMB         = CAST(f.DataMB AS decimal(18, 1)),
       LogMB          = CAST(f.LogMB AS decimal(18, 1)),
       LogUsedPct     = CAST(l.LogUsedPct AS decimal(5, 1)),
       LastFullBackup = bk.LastFull,
       LogReuseWait   = d.log_reuse_wait_desc,
       Compatibility  = d.compatibility_level,
       PageVerify     = d.page_verify_option_desc,
       Notes = STUFF(
                   CASE WHEN d.is_auto_shrink_on = 1 THEN '; auto-shrink ON' ELSE '' END +
                   CASE WHEN d.is_auto_close_on = 1 THEN '; auto-close ON' ELSE '' END +
                   CASE WHEN d.page_verify_option_desc <> 'CHECKSUM' THEN '; page verify not CHECKSUM' ELSE '' END +
                   CASE WHEN d.is_read_only = 1 THEN '; read-only' ELSE '' END, 1, 2, ''),
       Owner          = SUSER_SNAME(d.owner_sid),
       Created        = d.create_date
FROM sys.databases d
OUTER APPLY (SELECT DataMB = SUM(CASE WHEN mf.type <> 1 THEN mf.size END) * 8 / 1024.0,
                    LogMB  = SUM(CASE WHEN mf.type = 1 THEN mf.size END) * 8 / 1024.0
             FROM sys.master_files mf WHERE mf.database_id = d.database_id) f
OUTER APPLY (SELECT LastFull = MAX(bs.backup_finish_date) FROM msdb.dbo.backupset bs
             WHERE bs.database_name = d.name AND bs.type = 'D' AND bs.backup_finish_date >= DATEADD(SECOND, -2, d.create_date)) bk
LEFT JOIN #log l ON l.DatabaseName = d.name
ORDER BY CASE WHEN d.state_desc <> 'ONLINE' THEN 0 ELSE 1 END, l.LogUsedPct DESC, d.name;

-- @check backup-missing
/*  Databases without a full backup in the last @days days
    An empty result means every online database is covered.
    Note: AG databases may be backed up on another replica.
    Required permissions: read access to msdb
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @days int = 7;

;WITH b AS (
    SELECT d.name, d.recovery_model_desc, d.state_desc, d.create_date, d.database_id,
           LastFull = MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END),
           LastDiff = MAX(CASE WHEN bs.type = 'I' THEN bs.backup_finish_date END),
           LastLog  = MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END)
    FROM sys.databases d
    LEFT JOIN msdb.dbo.backupset bs ON bs.database_name = d.name AND bs.backup_finish_date >= DATEADD(SECOND, -2, d.create_date)
    WHERE d.database_id <> 2 AND d.source_database_id IS NULL AND d.state = 0
    GROUP BY d.name, d.recovery_model_desc, d.state_desc, d.create_date, d.database_id
)
SELECT Status         = CASE WHEN b.LastFull IS NULL OR b.database_id > 4 THEN 'CRITICAL' ELSE 'WARNING' END,
       DatabaseName   = b.name,
       LastFullBackup = b.LastFull,
       DaysSinceFull  = DATEDIFF(DAY, b.LastFull, GETDATE()),
       LastDiff       = b.LastDiff,
       LastLog        = b.LastLog,
       RecoveryModel  = b.recovery_model_desc,
       SizeGB         = CAST((SELECT SUM(CAST(size AS bigint)) FROM sys.master_files mf WHERE mf.database_id = b.database_id) * 8 / 1048576.0 AS decimal(18, 2)),
       Created        = b.create_date,
       Note           = CASE WHEN b.LastFull IS NULL THEN 'Never backed up (since creation / restore)'
                             ELSE 'Last full backup ' + CAST(DATEDIFF(DAY, b.LastFull, GETDATE()) AS varchar(10)) + ' days ago' END
FROM b
WHERE b.LastFull IS NULL OR b.LastFull < DATEADD(DAY, -@days, GETDATE())
ORDER BY CASE WHEN b.LastFull IS NULL THEN 0 ELSE 1 END, b.LastFull, b.name;

-- @check running-backups
/*  Backups and restores in progress, plus backups completed in the last 24 hours
    Required permissions: VIEW SERVER STATE, read access to msdb
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @slowWarnMin int = 360;   -- a single backup running longer than 6 hours
DECLARE @hoursBack   int = 24;

-- ---- 1. In progress ---------------------------------------------------------
SELECT Status          = CASE WHEN DATEDIFF(MINUTE, r.start_time, GETDATE()) >= @slowWarnMin THEN 'WARNING' ELSE 'OK' END,
       SessionId       = r.session_id,
       Operation       = r.command,
       DatabaseName    = DB_NAME(r.database_id),
       PercentComplete = CAST(r.percent_complete AS decimal(5, 1)),
       Started         = r.start_time,
       ElapsedMin      = DATEDIFF(MINUTE, r.start_time, GETDATE()),
       RemainingMin    = CAST(r.estimated_completion_time / 60000.0 AS decimal(10, 1)),
       EstimatedFinish = CASE WHEN r.estimated_completion_time > 0 THEN DATEADD(MILLISECOND, CAST(r.estimated_completion_time AS int), GETDATE()) END,
       WaitType        = r.wait_type,
       LoginName       = s.login_name,
       ProgramName     = s.program_name,
       SqlText         = LEFT(t.text, 2000)
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.command LIKE 'BACKUP%' OR r.command LIKE 'RESTORE%'
ORDER BY r.start_time;

-- ---- 2. Completed in the last @hoursBack hours -----------------------------
SELECT TOP (200)
       DatabaseName   = bs.database_name,
       BackupType     = CASE bs.type WHEN 'D' THEN 'Full' WHEN 'I' THEN 'Differential' WHEN 'L' THEN 'Log'
                                     WHEN 'F' THEN 'File' WHEN 'G' THEN 'Diff file' WHEN 'P' THEN 'Partial' ELSE bs.type END,
       Started        = bs.backup_start_date,
       Finished       = bs.backup_finish_date,
       DurationSec    = DATEDIFF(SECOND, bs.backup_start_date, bs.backup_finish_date),
       SizeGB         = CAST(bs.backup_size / 1073741824.0 AS decimal(18, 2)),
       CompressedGB   = CAST(bs.compressed_backup_size / 1073741824.0 AS decimal(18, 2)),
       CopyOnly       = bs.is_copy_only,
       Destination    = mf.physical_device_name,
       StartedBy      = bs.user_name
FROM msdb.dbo.backupset bs
LEFT JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id AND mf.family_sequence_number = 1
WHERE bs.backup_finish_date >= DATEADD(HOUR, -@hoursBack, GETDATE())
ORDER BY bs.backup_finish_date DESC;

-- @check backups
/*  Backup status (from msdb backup history on this instance)
    Note: databases in an availability group may be backed up on another
    replica - check each replica, or the replica your backup jobs prefer.
    Required permissions: read access to msdb
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @fullCritHours    int = 192;   -- 8 days without a full backup
DECLARE @recentWarnHours  int = 26;    -- no full or differential in ~1 day
DECLARE @logWarnMinutes   int = 60;
DECLARE @logCritMinutes   int = 240;

;WITH b AS (
    SELECT d.name, d.recovery_model_desc, d.state_desc, d.create_date,
           LastFull = MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END),
           LastDiff = MAX(CASE WHEN bs.type = 'I' THEN bs.backup_finish_date END),
           LastLog  = MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END)
    FROM sys.databases d
    LEFT JOIN msdb.dbo.backupset bs ON bs.database_name = d.name AND bs.backup_finish_date >= DATEADD(SECOND, -2, d.create_date)
    WHERE d.database_id <> 2 AND d.source_database_id IS NULL AND d.state = 0
    GROUP BY d.name, d.recovery_model_desc, d.state_desc, d.create_date
)
SELECT Status = CASE
           WHEN LastFull IS NULL OR DATEDIFF(HOUR, LastFull, GETDATE()) >= @fullCritHours THEN 'CRITICAL'
           WHEN recovery_model_desc <> 'SIMPLE' AND name NOT IN ('master', 'msdb', 'model')
                AND (LastLog IS NULL OR DATEDIFF(MINUTE, LastLog, GETDATE()) >= @logCritMinutes) THEN 'CRITICAL'
           WHEN DATEDIFF(HOUR, (SELECT MAX(v) FROM (VALUES (LastFull), (LastDiff)) x(v)), GETDATE()) >= @recentWarnHours THEN 'WARNING'
           WHEN recovery_model_desc <> 'SIMPLE' AND name NOT IN ('master', 'msdb', 'model')
                AND DATEDIFF(MINUTE, LastLog, GETDATE()) >= @logWarnMinutes THEN 'WARNING'
           ELSE 'OK' END,
       DatabaseName   = name,
       RecoveryModel  = recovery_model_desc,
       LastFull, LastDiff, LastLog,
       HoursSinceFull = DATEDIFF(HOUR, LastFull, GETDATE()),
       MinutesSinceLog = CASE WHEN recovery_model_desc <> 'SIMPLE' THEN DATEDIFF(MINUTE, LastLog, GETDATE()) END
FROM b
ORDER BY CASE WHEN LastFull IS NULL THEN 0 ELSE 1 END, LastFull, name;

-- @check queries
/*  What is running right now: active user requests and blocking chains
    Required permissions: VIEW SERVER STATE
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @longWarnSec int = 300;      -- 5 minutes
DECLARE @longCritSec int = 1800;     -- 30 minutes
DECLARE @blockWarnMs int = 30000;
DECLARE @blockCritMs int = 300000;

SELECT r.session_id,
       blocking_session_id = CASE WHEN r.blocking_session_id = r.session_id THEN 0 ELSE r.blocking_session_id END,
       r.status, r.command, r.database_id, r.wait_type, r.wait_time, r.wait_resource, r.start_time,
       r.total_elapsed_time, r.cpu_time, r.logical_reads, r.writes, r.percent_complete,
       r.sql_handle, r.statement_start_offset, r.statement_end_offset
INTO #req
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
WHERE s.is_user_process = 1 AND r.session_id <> @@SPID
  AND ISNULL(r.wait_type, '') NOT IN ('BROKER_RECEIVE_WAITFOR', 'SP_SERVER_DIAGNOSTICS_SLEEP', 'XE_LIVE_TARGET_TVF');

-- ---- 1. Active requests -------------------------------------------------------
SELECT Status = CASE
           WHEN r.blocking_session_id > 0 AND r.wait_time >= @blockCritMs THEN 'CRITICAL'
           WHEN r.total_elapsed_time / 1000 >= @longCritSec AND r.command NOT LIKE 'BACKUP%' AND ISNULL(r.wait_type, '') <> 'WAITFOR' THEN 'CRITICAL'
           WHEN r.blocking_session_id > 0 AND r.wait_time >= @blockWarnMs THEN 'WARNING'
           WHEN r.total_elapsed_time / 1000 >= @longWarnSec AND r.command NOT LIKE 'BACKUP%' AND ISNULL(r.wait_type, '') <> 'WAITFOR' THEN 'WARNING'
           ELSE 'OK' END,
       SessionId     = r.session_id,
       ElapsedSec    = r.total_elapsed_time / 1000,
       DatabaseName  = DB_NAME(r.database_id),
       RequestStatus = r.status,
       Command       = r.command,
       BlockedBy     = NULLIF(r.blocking_session_id, 0),
       WaitType      = r.wait_type,
       WaitSec       = r.wait_time / 1000,
       CpuSec        = r.cpu_time / 1000,
       LogicalReads  = r.logical_reads,
       Writes        = r.writes,
       LoginName     = s.login_name,
       HostName      = s.host_name,
       ProgramName   = s.program_name,
       Statement     = LEFT(SUBSTRING(t.text, r.statement_start_offset / 2 + 1,
                           (CASE WHEN r.statement_end_offset = -1 THEN DATALENGTH(t.text) ELSE r.statement_end_offset END
                            - r.statement_start_offset) / 2 + 1), 4000)
FROM #req r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
ORDER BY r.total_elapsed_time DESC;

-- ---- 2. Head blockers -----------------------------------------------------------
;WITH hb AS (
    SELECT sid = b.blocking_session_id, BlockedCount = COUNT(*), MaxWait = MAX(b.wait_time)
    FROM #req b
    WHERE b.blocking_session_id > 0
      AND NOT EXISTS (SELECT 1 FROM #req x WHERE x.session_id = b.blocking_session_id AND x.blocking_session_id > 0)
    GROUP BY b.blocking_session_id
)
SELECT Status        = CASE WHEN hb.MaxWait >= @blockCritMs THEN 'CRITICAL' ELSE 'WARNING' END,
       HeadBlocker   = hb.sid,
       BlockedCount  = hb.BlockedCount,
       MaxWaitSec    = hb.MaxWait / 1000,
       LoginName     = s.login_name,
       HostName      = s.host_name,
       ProgramName   = s.program_name,
       SessionStatus = s.status,
       OpenTran      = s.open_transaction_count,
       LastRequest   = s.last_request_start_time,
       LastSql       = LEFT(t.text, 4000)
FROM hb
LEFT JOIN sys.dm_exec_sessions s ON s.session_id = hb.sid
LEFT JOIN sys.dm_exec_connections c ON c.session_id = hb.sid
OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) t
ORDER BY hb.BlockedCount DESC;

-- @check replication timeout=120
/*  Replication status
    -----------------------------------------------------------------------
    Works on any instance; what it returns depends on the instance's role:
      1. Replication agents      - on a Distributor (reads every distribution DB)
      2. Replication errors      - on a Distributor, last @errorHours hours
      3. Replicated databases    - publisher / subscriber / distributor flags
      4. Subscriptions           - subscriber side (MSreplication_subscriptions)

    Status column convention used by the dashboard: OK | INFO | WARNING | CRITICAL
    Required permissions: VIEW SERVER STATE, read access to the distribution
    database(s) (e.g. member of replmonitor role) and to subscriber databases.
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 10000;

-- ---- Thresholds (adjust to your environment) -----------------------------
DECLARE @latencyWarnSec  int    = 300;      -- 5 minutes
DECLARE @latencyCritSec  int    = 1800;     -- 30 minutes
DECLARE @pendingWarn     bigint = 50000;    -- undistributed commands
DECLARE @pendingCrit     bigint = 500000;
DECLARE @errorHours      int    = 24;

CREATE TABLE #agents (
    DistributionDB   sysname        NOT NULL,
    AgentType        varchar(20)    NOT NULL,
    RunStatus        int            NULL,
    Publisher        sysname        NULL,
    PublisherDB      sysname        NULL,
    Publication      sysname        NULL,
    Subscriber       sysname        NULL,
    SubscriberDB     sysname        NULL,
    LatencySec       int            NULL,
    PendingCommands  bigint         NULL,
    LastActivity     datetime       NULL,
    LastMessage      nvarchar(4000) NULL,
    AgentName        nvarchar(400)  NULL
);

CREATE TABLE #errors (
    DistributionDB sysname        NOT NULL,
    ErrorTime      datetime       NULL,
    Source         nvarchar(400)  NULL,
    ErrorCode      sysname        NULL,
    ErrorText      nvarchar(4000) NULL
);

DECLARE @db sysname, @q nvarchar(300), @srv nvarchar(max), @sql nvarchar(max);
DECLARE @distCount int = 0;

DECLARE dist_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE is_distributor = 1 AND state = 0;
OPEN dist_cur;
FETCH NEXT FROM dist_cur INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @distCount += 1;
    SET @q = QUOTENAME(@db);

    -- Server-name lookup: SQL 2016+ keeps replication server ids in MSreplservers.
    SET @srv = CASE WHEN OBJECT_ID(@q + N'.dbo.MSreplservers') IS NOT NULL
        THEN N'COALESCE((SELECT TOP (1) rs.srvname FROM ' + @q + N'.dbo.MSreplservers rs WHERE rs.srvid = {id}),
                        (SELECT TOP (1) s.name FROM sys.servers s WHERE s.server_id = {id}))'
        ELSE N'(SELECT TOP (1) s.name FROM sys.servers s WHERE s.server_id = {id})' END;

    -- Log Reader agents
    BEGIN TRY
        SET @sql = N'
        INSERT #agents (DistributionDB, AgentType, RunStatus, Publisher, PublisherDB, LatencySec, LastActivity, LastMessage, AgentName)
        SELECT @db, ''Log Reader'', h.runstatus, ' + REPLACE(@srv, N'{id}', N'a.publisher_id') + N', a.publisher_db,
               h.delivery_latency / 1000, h.[time], h.comments, a.name
        FROM ' + @q + N'.dbo.MSlogreader_agents a
        OUTER APPLY (SELECT TOP (1) x.runstatus, x.[time], x.comments, x.delivery_latency
                     FROM ' + @q + N'.dbo.MSlogreader_history x
                     WHERE x.agent_id = a.id ORDER BY x.[time] DESC, x.[timestamp] DESC) h;';
        EXEC sys.sp_executesql @sql, N'@db sysname', @db;
    END TRY
    BEGIN CATCH
        PRINT 'Log Reader agents in ' + @db + ' could not be read: ' + ERROR_MESSAGE();
    END CATCH;

    -- Distribution agents (+ undistributed commands)
    BEGIN TRY
        SET @sql = N'
        INSERT #agents (DistributionDB, AgentType, RunStatus, Publisher, PublisherDB, Publication, Subscriber, SubscriberDB,
                        LatencySec, PendingCommands, LastActivity, LastMessage, AgentName)
        SELECT @db, ''Distribution'', h.runstatus, ' + REPLACE(@srv, N'{id}', N'a.publisher_id') + N', a.publisher_db, a.publication,
               ' + REPLACE(@srv, N'{id}', N'a.subscriber_id') + N', a.subscriber_db,
               h.current_delivery_latency / 1000, ISNULL(p.pending, 0), h.[time], h.comments, a.name
        FROM ' + @q + N'.dbo.MSdistribution_agents a
        OUTER APPLY (SELECT TOP (1) x.runstatus, x.[time], x.comments, x.current_delivery_latency
                     FROM ' + @q + N'.dbo.MSdistribution_history x
                     WHERE x.agent_id = a.id ORDER BY x.[time] DESC, x.[timestamp] DESC) h
        OUTER APPLY (SELECT SUM(CAST(s.UndelivCmdsInDistDB AS bigint)) AS pending
                     FROM ' + @q + N'.dbo.MSdistribution_status s WHERE s.agent_id = a.id) p
        WHERE ISNULL(a.subscriber_id, 0) >= 0;   -- skip virtual / anonymous placeholders';
        EXEC sys.sp_executesql @sql, N'@db sysname', @db;
    END TRY
    BEGIN CATCH
        PRINT 'Distribution agents in ' + @db + ' could not be read: ' + ERROR_MESSAGE();
    END CATCH;

    -- Merge agents
    BEGIN TRY
        SET @sql = N'
        INSERT #agents (DistributionDB, AgentType, RunStatus, Publisher, PublisherDB, Publication, Subscriber, SubscriberDB,
                        LastActivity, LastMessage, AgentName)
        SELECT @db, ''Merge'', s.runstatus, ' + REPLACE(@srv, N'{id}', N'a.publisher_id') + N', a.publisher_db, a.publication,
               a.subscriber_name, a.subscriber_db, COALESCE(s.end_time, s.start_time), m.comments, a.name
        FROM ' + @q + N'.dbo.MSmerge_agents a
        OUTER APPLY (SELECT TOP (1) x.session_id, x.runstatus, x.start_time, x.end_time
                     FROM ' + @q + N'.dbo.MSmerge_sessions x
                     WHERE x.agent_id = a.id ORDER BY x.start_time DESC) s
        OUTER APPLY (SELECT TOP (1) y.comments
                     FROM ' + @q + N'.dbo.MSmerge_history y
                     WHERE y.session_id = s.session_id ORDER BY y.[time] DESC) m;';
        EXEC sys.sp_executesql @sql, N'@db sysname', @db;
    END TRY
    BEGIN CATCH
        PRINT 'Merge agents in ' + @db + ' could not be read: ' + ERROR_MESSAGE();
    END CATCH;

    -- Recent errors
    BEGIN TRY
        SET @sql = N'
        INSERT #errors (DistributionDB, ErrorTime, Source, ErrorCode, ErrorText)
        SELECT TOP (200) @db, e.[time], e.source_name, e.error_code, e.error_text
        FROM ' + @q + N'.dbo.MSrepl_errors e
        WHERE e.[time] >= DATEADD(HOUR, -@h, GETDATE())
        ORDER BY e.[time] DESC;';
        EXEC sys.sp_executesql @sql, N'@db sysname, @h int', @db, @errorHours;
    END TRY
    BEGIN CATCH
        PRINT 'Replication errors in ' + @db + ' could not be read: ' + ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM dist_cur INTO @db;
END
CLOSE dist_cur;
DEALLOCATE dist_cur;

IF @distCount = 0
    PRINT 'This instance is not a Distributor - agent status and errors are read on the Distributor. Local publisher/subscriber details are shown below.';

-- ---- 1. Replication agents -------------------------------------------------
;WITH a AS (
    SELECT *,
        Status = CASE
            WHEN RunStatus = 6                                              THEN 'CRITICAL'
            WHEN LatencySec >= @latencyCritSec OR PendingCommands >= @pendingCrit THEN 'CRITICAL'
            WHEN RunStatus = 5                                              THEN 'WARNING'
            WHEN LatencySec >= @latencyWarnSec OR PendingCommands >= @pendingWarn THEN 'WARNING'
            WHEN RunStatus = 2 AND AgentType IN ('Log Reader', 'Distribution')
                 AND ISNULL(PendingCommands, 0) > 0                         THEN 'WARNING'
            WHEN RunStatus IS NULL                                          THEN 'WARNING'
            ELSE 'OK' END
    FROM #agents
)
SELECT Status,
       AgentType,
       AgentState = CASE RunStatus WHEN 1 THEN 'Started' WHEN 2 THEN 'Stopped / completed' WHEN 3 THEN 'In progress'
                                   WHEN 4 THEN 'Idle' WHEN 5 THEN 'Retrying' WHEN 6 THEN 'Failed' ELSE 'No history' END,
       Publisher, PublisherDB, Publication, Subscriber, SubscriberDB,
       LatencySec, PendingCommands, LastActivity,
       MinutesSinceActivity = DATEDIFF(MINUTE, LastActivity, GETDATE()),
       LastMessage, AgentName, DistributionDB
FROM a
ORDER BY CASE Status WHEN 'CRITICAL' THEN 0 WHEN 'WARNING' THEN 1 ELSE 2 END, AgentType, Publisher, Publication;

-- ---- 2. Recent replication errors ------------------------------------------
SELECT Status = CASE WHEN ErrorTime >= DATEADD(HOUR, -1, GETDATE()) THEN 'CRITICAL' ELSE 'WARNING' END,
       ErrorTime, Source, ErrorCode, ErrorText, DistributionDB
FROM #errors
ORDER BY ErrorTime DESC;

-- ---- 3. Replicated databases on this instance ------------------------------
SELECT Status = CASE WHEN d.log_reuse_wait_desc = 'REPLICATION' THEN 'WARNING' ELSE 'OK' END,
       DatabaseName      = d.name,
       Published         = CAST(d.is_published AS bit),
       MergePublished    = CAST(d.is_merge_published AS bit),
       Subscribed        = CAST(d.is_subscribed AS bit),
       Distributor       = CAST(d.is_distributor AS bit),
       LogReuseWait      = d.log_reuse_wait_desc,
       Note = CASE WHEN d.log_reuse_wait_desc = 'REPLICATION'
                   THEN 'Log cannot be truncated until the Log Reader has processed it' END
FROM sys.databases d
WHERE d.is_published = 1 OR d.is_merge_published = 1 OR d.is_subscribed = 1 OR d.is_distributor = 1
ORDER BY d.name;

-- ---- 4. Subscriptions (subscriber side) -------------------------------------
CREATE TABLE #subs (
    SubscriberDB sysname, Publisher sysname NULL, PublisherDB sysname NULL, Publication sysname NULL,
    SubscriptionType varchar(10) NULL, LastSync datetime NULL, DistributionAgent nvarchar(400) NULL
);

DECLARE sub_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE state = 0 AND database_id > 4 AND HAS_DBACCESS(name) = 1;
OPEN sub_cur;
FETCH NEXT FROM sub_cur INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @q = QUOTENAME(@db);
    IF OBJECT_ID(@q + N'.dbo.MSreplication_subscriptions') IS NOT NULL
    BEGIN
    BEGIN TRY
        SET @sql = N'
        INSERT #subs
        SELECT @db, s.publisher, s.publisher_db, s.publication,
               CASE s.subscription_type WHEN 0 THEN ''Push'' WHEN 1 THEN ''Pull'' ELSE ''Anonymous'' END,
               s.[time], s.distribution_agent
        FROM ' + @q + N'.dbo.MSreplication_subscriptions s;';
        EXEC sys.sp_executesql @sql, N'@db sysname', @db;
    END TRY
    BEGIN CATCH
        PRINT 'Subscriptions in ' + @db + ' could not be read: ' + ERROR_MESSAGE();
    END CATCH;
    END
    FETCH NEXT FROM sub_cur INTO @db;
END
CLOSE sub_cur;
DEALLOCATE sub_cur;

SELECT Status = 'INFO',
       SubscriberDB, Publisher, PublisherDB, Publication, SubscriptionType,
       LastSync, MinutesSinceSync = DATEDIFF(MINUTE, LastSync, GETDATE()), DistributionAgent
FROM #subs
ORDER BY Publisher, Publication;

-- @check ag
/*  Always On availability groups
    Required permissions: VIEW SERVER STATE
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @sendQueueWarnKB bigint = 1048576;   -- 1 GB
DECLARE @redoQueueWarnKB bigint = 1048576;   -- 1 GB
DECLARE @lagWarnSec      int    = 60;
DECLARE @lagCritSec      int    = 600;

IF ISNULL(CAST(SERVERPROPERTY('IsHadrEnabled') AS int), 0) = 0
    PRINT 'Always On availability groups are not enabled on this instance.';

-- ---- 1. Availability groups ------------------------------------------------
SELECT Status = CASE gs.synchronization_health WHEN 0 THEN 'CRITICAL' WHEN 1 THEN 'WARNING' ELSE 'OK' END,
       AvailabilityGroup = ag.name,
       PrimaryReplica    = gs.primary_replica,
       LocalRole         = rs.role_desc,
       SyncHealth        = gs.synchronization_health_desc,
       Listener          = (SELECT TOP (1) l.dns_name + ',' + CAST(l.port AS varchar(10))
                            FROM sys.availability_group_listeners l WHERE l.group_id = ag.group_id),
       Replicas          = (SELECT COUNT(*) FROM sys.availability_replicas r WHERE r.group_id = ag.group_id),
       Databases         = (SELECT COUNT(*) FROM sys.availability_databases_cluster d WHERE d.group_id = ag.group_id)
FROM sys.availability_groups ag
LEFT JOIN sys.dm_hadr_availability_group_states gs ON gs.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states rs ON rs.group_id = ag.group_id AND rs.is_local = 1
ORDER BY ag.name;

-- ---- 2. Database replica states --------------------------------------------
;WITH s AS (
    SELECT drs.*,
           PrimaryCommit = (SELECT TOP (1) p.last_commit_time
                            FROM sys.dm_hadr_database_replica_states p
                            JOIN sys.dm_hadr_availability_replica_states pr ON pr.replica_id = p.replica_id
                            WHERE p.group_database_id = drs.group_database_id AND pr.role = 1)
    FROM sys.dm_hadr_database_replica_states drs
)
SELECT Status = CASE
           WHEN s.synchronization_health = 0 THEN 'CRITICAL'
           WHEN ars.role = 2 AND DATEDIFF(SECOND, s.last_commit_time, s.PrimaryCommit) >= @lagCritSec THEN 'CRITICAL'
           WHEN s.is_suspended = 1 OR s.synchronization_health = 1 THEN 'WARNING'
           WHEN s.log_send_queue_size >= @sendQueueWarnKB OR s.redo_queue_size >= @redoQueueWarnKB THEN 'WARNING'
           WHEN ars.role = 2 AND DATEDIFF(SECOND, s.last_commit_time, s.PrimaryCommit) >= @lagWarnSec THEN 'WARNING'
           ELSE 'OK' END,
       AvailabilityGroup = ag.name,
       DatabaseName      = adc.database_name,
       Replica           = ar.replica_server_name,
       Role              = ars.role_desc,
       AvailabilityMode  = ar.availability_mode_desc,
       SyncState         = s.synchronization_state_desc,
       SyncHealth        = s.synchronization_health_desc,
       Suspended         = s.is_suspended,
       SuspendReason     = s.suspend_reason_desc,
       LogSendQueueKB    = s.log_send_queue_size,
       RedoQueueKB       = s.redo_queue_size,
       EstLagSec         = CASE WHEN ars.role = 2 THEN DATEDIFF(SECOND, s.last_commit_time, s.PrimaryCommit) END,
       LastCommitTime    = s.last_commit_time,
       Connected         = ars.connected_state_desc
FROM s
JOIN sys.availability_replicas ar ON ar.replica_id = s.replica_id
JOIN sys.availability_groups ag ON ag.group_id = s.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = s.replica_id
LEFT JOIN sys.availability_databases_cluster adc ON adc.group_database_id = s.group_database_id
ORDER BY ag.name, adc.database_name, ars.role, ar.replica_server_name;

-- @check jobs
/*  SQL Server Agent jobs
    Required permissions: read access to msdb (e.g. SQLAgentReaderRole), VIEW SERVER STATE
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @hoursBack      int = 24;
DECLARE @longRunWarnMin int = 120;

DECLARE @since datetime = DATEADD(HOUR, -@hoursBack, GETDATE());
DECLARE @sinceInt int = CONVERT(int, CONVERT(char(8), @since, 112));

-- ---- 1. Agent service ------------------------------------------------------
BEGIN TRY
    SELECT Status = CASE WHEN s.status = 4 THEN 'OK' ELSE 'CRITICAL' END,
           Service = s.servicename, State = s.status_desc, StartupType = s.startup_type_desc,
           ServiceAccount = s.service_account, LastStartup = s.last_startup_time
    FROM sys.dm_server_services s
    WHERE s.servicename LIKE 'SQL Server Agent%';
END TRY
BEGIN CATCH
    PRINT 'Agent service state unavailable: ' + ERROR_MESSAGE();
END CATCH;

-- ---- 2. Failed / retried / cancelled steps in the window -------------------
;WITH h AS (
    SELECT h.*, RunAt = DATEADD(SECOND, (h.run_time / 10000) * 3600 + (h.run_time / 100 % 100) * 60 + h.run_time % 100,
                                 CONVERT(datetime, CAST(h.run_date AS char(8)), 112))
    FROM msdb.dbo.sysjobhistory h
    WHERE h.run_date >= @sinceInt AND h.step_id > 0 AND h.run_status IN (0, 2, 3)
)
SELECT Status = CASE h.run_status WHEN 0 THEN 'CRITICAL' ELSE 'WARNING' END,
       JobName   = j.name,
       StepId    = h.step_id,
       StepName  = h.step_name,
       Outcome   = CASE h.run_status WHEN 0 THEN 'Failed' WHEN 2 THEN 'Retry' WHEN 3 THEN 'Cancelled' END,
       RunAt     = h.RunAt,
       DurationSec = (h.run_duration / 10000) * 3600 + (h.run_duration / 100 % 100) * 60 + h.run_duration % 100,
       SqlSeverity = h.sql_severity,
       Message   = LEFT(h.message, 2000)
FROM h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE h.RunAt >= @since
ORDER BY h.RunAt DESC;

-- ---- 3. Job overview -------------------------------------------------------
DECLARE @session int = (SELECT MAX(session_id) FROM msdb.dbo.syssessions);

SELECT Status = CASE
           WHEN j.enabled = 1 AND js.last_run_outcome = 0 THEN 'CRITICAL'
           WHEN a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL
                AND DATEDIFF(MINUTE, a.start_execution_date, GETDATE()) >= @longRunWarnMin THEN 'WARNING'
           WHEN j.enabled = 0 THEN 'INFO'
           ELSE 'OK' END,
       JobName     = j.name,
       Enabled     = CAST(j.enabled AS bit),
       Running     = CAST(CASE WHEN a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL THEN 1 ELSE 0 END AS bit),
       RunningMin  = CASE WHEN a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL
                          THEN DATEDIFF(MINUTE, a.start_execution_date, GETDATE()) END,
       LastOutcome = CASE js.last_run_outcome WHEN 0 THEN 'Failed' WHEN 1 THEN 'Succeeded' WHEN 3 THEN 'Cancelled'
                                              WHEN 5 THEN 'Unknown' END,
       LastRun     = CASE WHEN js.last_run_date > 0 THEN
                         DATEADD(SECOND, (js.last_run_time / 10000) * 3600 + (js.last_run_time / 100 % 100) * 60 + js.last_run_time % 100,
                                 CONVERT(datetime, CAST(js.last_run_date AS char(8)), 112)) END,
       NextRun     = a.next_scheduled_run_date,
       Category    = c.name,
       Owner       = SUSER_SNAME(j.owner_sid)
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.sysjobservers js ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.sysjobactivity a ON a.job_id = j.job_id AND a.session_id = @session
LEFT JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
ORDER BY CASE WHEN j.enabled = 1 AND js.last_run_outcome = 0 THEN 0 ELSE 1 END, j.name;

-- @check waits
/*  Top wait statistics since the last restart (benign waits filtered out)
    Required permissions: VIEW SERVER STATE
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

;WITH w AS (
    SELECT wait_type, wait_time_ms, signal_wait_time_ms, waiting_tasks_count
    FROM sys.dm_os_wait_stats
    WHERE waiting_tasks_count > 0
      AND wait_type NOT IN (
        'BROKER_EVENTHANDLER', 'BROKER_RECEIVE_WAITFOR', 'BROKER_TASK_STOP', 'BROKER_TO_FLUSH', 'BROKER_TRANSMITTER',
        'CHECKPOINT_QUEUE', 'CHKPT', 'CLR_AUTO_EVENT', 'CLR_MANUAL_EVENT', 'CLR_SEMAPHORE', 'CXCONSUMER',
        'DBMIRROR_DBM_EVENT', 'DBMIRROR_EVENTS_QUEUE', 'DBMIRROR_WORKER_QUEUE', 'DBMIRRORING_CMD',
        'DIRTY_PAGE_POLL', 'DISPATCHER_QUEUE_SEMAPHORE', 'EXECSYNC', 'FSAGENT', 'FT_IFTS_SCHEDULER_IDLE_WAIT',
        'FT_IFTSHC_MUTEX', 'HADR_CLUSAPI_CALL', 'HADR_FILESTREAM_IOMGR_IOCOMPLETION', 'HADR_LOGCAPTURE_WAIT',
        'HADR_NOTIFICATION_DEQUEUE', 'HADR_TIMER_TASK', 'HADR_WORK_QUEUE', 'KSOURCE_WAKEUP', 'LAZYWRITER_SLEEP',
        'LOGMGR_QUEUE', 'MEMORY_ALLOCATION_EXT', 'ONDEMAND_TASK_QUEUE', 'PARALLEL_REDO_DRAIN_WORKER',
        'PARALLEL_REDO_LOG_CACHE', 'PARALLEL_REDO_TRAN_LIST', 'PARALLEL_REDO_WORKER_SYNC', 'PARALLEL_REDO_WORKER_WAIT_WORK',
        'PREEMPTIVE_XE_GETTARGETSTATE', 'PWAIT_ALL_COMPONENTS_INITIALIZED', 'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
        'PWAIT_EXTENSIBILITY_CLEANUP_TASK', 'QDS_ASYNC_QUEUE', 'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
        'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', 'QDS_SHUTDOWN_QUEUE', 'REDO_THREAD_PENDING_WORK', 'REQUEST_FOR_DEADLOCK_SEARCH',
        'RESOURCE_QUEUE', 'SERVER_IDLE_CHECK', 'SLEEP_BPOOL_FLUSH', 'SLEEP_DBSTARTUP', 'SLEEP_DCOMSTARTUP',
        'SLEEP_MASTERDBREADY', 'SLEEP_PHYSMASTERDBREADY', 'STARTUP_DEPENDENCY_MANAGER', 'AZURE_IMDS_VERSIONS', 'PVS_PREALLOCATE', 'MSQL_XP', 'SLEEP_MASTERMDREADY', 'SLEEP_MASTERUPGRADED', 'SLEEP_MSDBSTARTUP', 'SLEEP_SYSTEMTASK',
        'SLEEP_TASK', 'SLEEP_TEMPDBSTARTUP', 'SNI_HTTP_ACCEPT', 'SOS_WORK_DISPATCHER', 'SP_SERVER_DIAGNOSTICS_SLEEP',
        'SQLTRACE_BUFFER_FLUSH', 'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', 'SQLTRACE_WAIT_ENTRIES', 'UCS_SESSION_REGISTRATION',
        'VDI_CLIENT_OTHER', 'WAIT_FOR_RESULTS', 'WAIT_XTP_CKPT_CLOSE', 'WAIT_XTP_HOST_WAIT', 'WAIT_XTP_OFFLINE_CKPT_NEW_LOG',
        'WAIT_XTP_RECOVERY', 'WAITFOR', 'WAITFOR_TASKSHUTDOWN', 'XE_BUFFERMGR_ALLPROCESSED_EVENT', 'XE_DISPATCHER_JOIN',
        'XE_DISPATCHER_WAIT', 'XE_LIVE_TARGET_TVF', 'XE_TIMER_EVENT')
)
SELECT TOP (15)
       WaitType      = wait_type,
       WaitPct       = CAST(100.0 * wait_time_ms / SUM(wait_time_ms) OVER () AS decimal(5, 1)),
       WaitSec       = CAST(wait_time_ms / 1000.0 AS decimal(18, 0)),
       WaitingTasks  = waiting_tasks_count,
       AvgWaitMs     = CAST(1.0 * wait_time_ms / waiting_tasks_count AS decimal(18, 1)),
       SignalPct     = CAST(100.0 * signal_wait_time_ms / NULLIF(wait_time_ms, 0) AS decimal(5, 1)),
       Hint = CASE
            WHEN wait_type LIKE 'PAGEIOLATCH%' THEN 'Reading data pages from disk - memory pressure or slow storage'
            WHEN wait_type = 'WRITELOG' THEN 'Transaction log writes - log disk latency'
            WHEN wait_type LIKE 'LCK_M_%' THEN 'Lock waits - blocking'
            WHEN wait_type = 'CXPACKET' THEN 'Parallelism - review MAXDOP / cost threshold'
            WHEN wait_type = 'SOS_SCHEDULER_YIELD' THEN 'CPU pressure'
            WHEN wait_type = 'ASYNC_NETWORK_IO' THEN 'Client consuming results slowly'
            WHEN wait_type = 'RESOURCE_SEMAPHORE' THEN 'Queries waiting for memory grants'
            WHEN wait_type LIKE 'HADR_SYNC_COMMIT' THEN 'Synchronous AG commit latency'
            WHEN wait_type LIKE 'PAGELATCH%' THEN 'In-memory page contention (often tempdb)'
            WHEN wait_type = 'THREADPOOL' THEN 'Worker thread starvation'
            END
FROM w
ORDER BY wait_time_ms DESC;

-- @check errorlog
/*  Errors in the current SQL Server error log
    Required permissions: securityadmin (or sysadmin) to read the error log
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;

DECLARE @hoursBack int = 24;

CREATE TABLE #log (LogDate datetime, ProcessInfo nvarchar(100), [Text] nvarchar(max));

BEGIN TRY
    INSERT #log EXEC master.dbo.xp_readerrorlog 0, 1, N'error';
    INSERT #log EXEC master.dbo.xp_readerrorlog 0, 1, N'fail';
END TRY
BEGIN CATCH
    PRINT 'The error log could not be read (securityadmin or sysadmin required): ' + ERROR_MESSAGE();
END CATCH;

SELECT DISTINCT
       Status = CASE WHEN [Text] LIKE '%Severity: 2[0-5]%' OR [Text] LIKE '%Severity: 1[7-9]%'
                       OR [Text] LIKE '%corrupt%' OR [Text] LIKE '%stack dump%' THEN 'CRITICAL'
                     ELSE 'WARNING' END,
       LogDate, Source = ProcessInfo, Message = LEFT([Text], 4000)
FROM #log
WHERE LogDate >= DATEADD(HOUR, -@hoursBack, GETDATE())
  AND [Text] NOT LIKE '%found 0 errors%'
  AND [Text] NOT LIKE '%without errors%'
  AND [Text] NOT LIKE 'Logging SQL Server messages in file%'
  AND [Text] NOT LIKE '%error log has been reinitialized%'
  AND [Text] NOT LIKE 'Registry startup parameters%'
  AND [Text] NOT LIKE '%-e %ERRORLOG%'
ORDER BY LogDate DESC;
