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
