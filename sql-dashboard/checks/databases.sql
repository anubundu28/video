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
       LogReuseWait   = d.log_reuse_wait_desc,
       Compatibility  = d.compatibility_level,
       PageVerify     = d.page_verify_option_desc,
       Notes = STUFF(
                   CASE WHEN d.is_auto_shrink_on = 1 THEN '; auto-shrink ON' ELSE '' END +
                   CASE WHEN d.is_auto_close_on = 1 THEN '; auto-close ON' ELSE '' END +
                   CASE WHEN d.page_verify_option_desc <> 'CHECKSUM' THEN '; page verify not CHECKSUM' ELSE '' END +
                   CASE WHEN d.is_read_only = 1 THEN '; read-only' ELSE '' END, 1, 2, ''),
       Created        = d.create_date
FROM sys.databases d
OUTER APPLY (SELECT DataMB = SUM(CASE WHEN mf.type <> 1 THEN mf.size END) * 8 / 1024.0,
                    LogMB  = SUM(CASE WHEN mf.type = 1 THEN mf.size END) * 8 / 1024.0
             FROM sys.master_files mf WHERE mf.database_id = d.database_id) f
LEFT JOIN #log l ON l.DatabaseName = d.name
ORDER BY CASE WHEN d.state_desc <> 'ONLINE' THEN 0 ELSE 1 END, l.LogUsedPct DESC, d.name;
