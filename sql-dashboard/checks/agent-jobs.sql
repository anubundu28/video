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
