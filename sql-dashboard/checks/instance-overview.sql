/*  Instance overview: version, uptime, CPU, memory and load
    Required permissions: VIEW SERVER STATE
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @cpuWarn int = 75, @cpuCrit int = 90, @pleWarn int = 300;

DECLARE @m TABLE (Seq int IDENTITY, Status varchar(10), Category nvarchar(40), Metric nvarchar(80), Value nvarchar(400));

-- Identity
INSERT @m (Status, Category, Metric, Value) VALUES
    ('INFO', 'Instance', 'Server name', CAST(SERVERPROPERTY('ServerName') AS nvarchar(256))),
    ('INFO', 'Instance', 'Version', CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)) + ' '
                                    + CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(64))
                                    + ISNULL(' ' + CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(64)), '')),
    ('INFO', 'Instance', 'Edition', CAST(SERVERPROPERTY('Edition') AS nvarchar(128))),
    ('INFO', 'Instance', 'Clustered (FCI)', CASE WHEN SERVERPROPERTY('IsClustered') = 1 THEN 'Yes' ELSE 'No' END),
    ('INFO', 'Instance', 'Always On enabled', CASE WHEN SERVERPROPERTY('IsHadrEnabled') = 1 THEN 'Yes' ELSE 'No' END);

BEGIN TRY
    DECLARE @start datetime, @cpus int, @memMB bigint;
    SELECT @start = sqlserver_start_time, @cpus = cpu_count, @memMB = physical_memory_kb / 1024 FROM sys.dm_os_sys_info;

    INSERT @m (Status, Category, Metric, Value) VALUES
        ('INFO', 'Instance', 'Started', CONVERT(varchar(19), @start, 120)),
        (CASE WHEN DATEDIFF(HOUR, @start, GETDATE()) < 1 THEN 'WARNING' ELSE 'OK' END, 'Instance', 'Uptime',
            CAST(DATEDIFF(MINUTE, @start, GETDATE()) / 1440 AS varchar(10)) + ' d '
            + CAST(DATEDIFF(MINUTE, @start, GETDATE()) / 60 % 24 AS varchar(10)) + ' h '
            + CAST(DATEDIFF(MINUTE, @start, GETDATE()) % 60 AS varchar(10)) + ' m'),
        ('INFO', 'Resources', 'Logical CPUs', CAST(@cpus AS varchar(10))),
        ('INFO', 'Resources', 'Physical memory', CAST(@memMB / 1024 AS varchar(20)) + ' GB');

    -- CPU from the scheduler-monitor ring buffer (sampled once a minute)
    DECLARE @sqlCpu int, @idle int;
    SELECT TOP (1)
        @sqlCpu = rec.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int'),
        @idle   = rec.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int')
    FROM (SELECT CONVERT(xml, record) AS rec, [timestamp]
          FROM sys.dm_os_ring_buffers
          WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND record LIKE N'%<SystemHealth>%') x
    ORDER BY [timestamp] DESC;

    INSERT @m (Status, Category, Metric, Value) VALUES
        (CASE WHEN @sqlCpu >= @cpuCrit THEN 'CRITICAL' WHEN @sqlCpu >= @cpuWarn THEN 'WARNING' ELSE 'OK' END,
            'Load', 'SQL Server CPU %', CAST(@sqlCpu AS varchar(10)) + ' %'),
        (CASE WHEN 100 - @idle >= @cpuCrit THEN 'CRITICAL' WHEN 100 - @idle >= @cpuWarn THEN 'WARNING' ELSE 'OK' END,
            'Load', 'Total server CPU %', CAST(100 - @idle AS varchar(10)) + ' %');

    -- Memory & buffer pool
    DECLARE @total bigint, @target bigint, @ple bigint, @grantsPending bigint;
    SELECT @total  = MAX(CASE WHEN counter_name = 'Total Server Memory (KB)' THEN cntr_value END),
           @target = MAX(CASE WHEN counter_name = 'Target Server Memory (KB)' THEN cntr_value END),
           @grantsPending = MAX(CASE WHEN counter_name = 'Memory Grants Pending' THEN cntr_value END)
    FROM sys.dm_os_performance_counters
    WHERE object_name LIKE '%Memory Manager%';
    SELECT @ple = cntr_value FROM sys.dm_os_performance_counters
    WHERE object_name LIKE '%Buffer Manager%' AND counter_name = 'Page life expectancy';

    INSERT @m (Status, Category, Metric, Value) VALUES
        ('INFO', 'Memory', 'Total / target server memory', CAST(@total / 1024 AS varchar(20)) + ' / ' + CAST(@target / 1024 AS varchar(20)) + ' MB'),
        (CASE WHEN @ple < @pleWarn THEN 'WARNING' ELSE 'OK' END, 'Memory', 'Page life expectancy', CAST(@ple AS varchar(20)) + ' s'),
        (CASE WHEN @grantsPending > 0 THEN 'WARNING' ELSE 'OK' END, 'Memory', 'Memory grants pending', CAST(@grantsPending AS varchar(20)));

    -- Activity
    DECLARE @sessions int, @requests int, @blocked int, @maxMem bigint, @dbCount int;
    SELECT @maxMem = CAST(value_in_use AS bigint) FROM sys.configurations WHERE name = 'max server memory (MB)';
    SELECT @dbCount = COUNT(*) FROM sys.databases;
    SELECT @sessions = COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1;
    SELECT @requests = COUNT(*), @blocked = SUM(CASE WHEN blocking_session_id > 0 THEN 1 ELSE 0 END)
    FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
    WHERE s.is_user_process = 1 AND r.session_id <> @@SPID;

    INSERT @m (Status, Category, Metric, Value) VALUES
        ('INFO', 'Activity', 'User sessions', CAST(@sessions AS varchar(10))),
        ('INFO', 'Activity', 'Active requests', CAST(@requests AS varchar(10))),
        (CASE WHEN @blocked > 0 THEN 'WARNING' ELSE 'OK' END, 'Activity', 'Blocked requests', CAST(ISNULL(@blocked, 0) AS varchar(10))),
        ('INFO', 'Activity', 'Databases', CAST(@dbCount AS varchar(10))),
        ('INFO', 'Memory', 'Max server memory', CAST(@maxMem AS varchar(20)) + ' MB');
END TRY
BEGIN CATCH
    PRINT 'Some metrics are unavailable (VIEW SERVER STATE required): ' + ERROR_MESSAGE();
END CATCH;

INSERT @m (Status, Category, Metric, Value)
SELECT 'INFO', 'Configuration', name, CAST(value_in_use AS nvarchar(40))
FROM sys.configurations
WHERE name IN ('max degree of parallelism', 'cost threshold for parallelism', 'optimize for ad hoc workloads', 'backup compression default');

SELECT Status, Category, Metric, Value FROM @m ORDER BY Seq;
