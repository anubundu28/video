/*  Server overview - feeds the dashboard landing page
    Result sets (the UI reads them by position and column name):
      1. Summary    - one row: identity, version, CPU, memory, databases, alerts
      2. Disks      - volumes holding database files
      3. Databases  - every database with its allocated size (largest first)
      4. CPU history- SQL / other CPU %, one sample per minute (last 60 min)
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

-- ---- 4. CPU history (oldest first) -----------------------------------------
SELECT MinutesAgo = DATEDIFF(MINUTE, EventTime, GETDATE()), SqlCpu, OtherCpu
FROM #cpu
ORDER BY EventTime;
