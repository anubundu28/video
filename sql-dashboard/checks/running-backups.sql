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
