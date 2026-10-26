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
