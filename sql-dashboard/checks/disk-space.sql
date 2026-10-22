/*  Free space on every volume that holds database files
    Required permissions: VIEW SERVER STATE
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @freeWarnPct int = 20;
DECLARE @freeCritPct int = 10;

;WITH v AS (
    SELECT vs.volume_mount_point, vs.logical_volume_name, vs.total_bytes, vs.available_bytes,
           Files = COUNT(*)
    FROM sys.master_files mf
    JOIN sys.databases d ON d.database_id = mf.database_id AND d.state = 0
    CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
    GROUP BY vs.volume_mount_point, vs.logical_volume_name, vs.total_bytes, vs.available_bytes
)
SELECT Status = CASE WHEN FreePct < @freeCritPct THEN 'CRITICAL' WHEN FreePct < @freeWarnPct THEN 'WARNING' ELSE 'OK' END,
       Volume, Label, TotalGB, UsedGB, FreeGB, FreePct, DatabaseFiles
FROM (
    SELECT Volume  = volume_mount_point,
           Label   = logical_volume_name,
           TotalGB = CAST(total_bytes / 1073741824.0 AS decimal(18, 1)),
           UsedGB  = CAST((total_bytes - available_bytes) / 1073741824.0 AS decimal(18, 1)),
           FreeGB  = CAST(available_bytes / 1073741824.0 AS decimal(18, 1)),
           FreePct = CAST(available_bytes * 100.0 / NULLIF(total_bytes, 0) AS decimal(5, 1)),
           DatabaseFiles = Files
    FROM v
) x
ORDER BY FreePct;
