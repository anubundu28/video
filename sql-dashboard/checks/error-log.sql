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
