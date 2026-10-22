/*  Blocking and long-running requests
    Required permissions: VIEW SERVER STATE
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @waitWarnMs     int = 30000;    -- 30 seconds
DECLARE @waitCritMs     int = 300000;   -- 5 minutes
DECLARE @longRunWarnSec int = 300;
DECLARE @longRunCritSec int = 1800;

SELECT r.session_id,
       -- a parallel query can report itself as its blocker; ignore that
       blocking_session_id = CASE WHEN r.blocking_session_id = r.session_id THEN 0 ELSE r.blocking_session_id END, r.wait_type, r.wait_time, r.wait_resource,
       r.database_id, r.command, r.status, r.start_time, r.total_elapsed_time, r.cpu_time,
       r.logical_reads, r.sql_handle, r.statement_start_offset, r.statement_end_offset
INTO #req
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
WHERE s.is_user_process = 1 AND r.session_id <> @@SPID;

-- ---- 1. Head blockers --------------------------------------------------------
;WITH hb AS (
    SELECT sid = b.blocking_session_id, BlockedCount = COUNT(*), MaxWait = MAX(b.wait_time)
    FROM #req b
    WHERE b.blocking_session_id > 0
      AND NOT EXISTS (SELECT 1 FROM #req x WHERE x.session_id = b.blocking_session_id AND x.blocking_session_id > 0)
    GROUP BY b.blocking_session_id
)
SELECT Status = CASE WHEN hb.MaxWait >= @waitCritMs THEN 'CRITICAL' ELSE 'WARNING' END,
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

-- ---- 2. Blocked requests -----------------------------------------------------
SELECT Status = CASE WHEN r.wait_time >= @waitCritMs THEN 'CRITICAL' WHEN r.wait_time >= @waitWarnMs THEN 'WARNING' ELSE 'INFO' END,
       SessionId    = r.session_id,
       BlockedBy    = r.blocking_session_id,
       WaitType     = r.wait_type,
       WaitSec      = r.wait_time / 1000,
       WaitResource = r.wait_resource,
       DatabaseName = DB_NAME(r.database_id),
       LoginName    = s.login_name,
       HostName     = s.host_name,
       Command      = r.command,
       SqlText      = LEFT(t.text, 4000)
FROM #req r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.blocking_session_id > 0
ORDER BY r.wait_time DESC;

-- ---- 3. Long-running requests ------------------------------------------------
SELECT Status = CASE WHEN r.total_elapsed_time / 1000 >= @longRunCritSec THEN 'CRITICAL' ELSE 'WARNING' END,
       SessionId    = r.session_id,
       ElapsedSec   = r.total_elapsed_time / 1000,
       CpuSec       = r.cpu_time / 1000,
       LogicalReads = r.logical_reads,
       RequestStatus = r.status,
       Command      = r.command,
       WaitType     = r.wait_type,
       DatabaseName = DB_NAME(r.database_id),
       LoginName    = s.login_name,
       HostName     = s.host_name,
       ProgramName  = s.program_name,
       Statement    = LEFT(SUBSTRING(t.text, r.statement_start_offset / 2 + 1,
                          (CASE WHEN r.statement_end_offset = -1 THEN DATALENGTH(t.text) ELSE r.statement_end_offset END
                           - r.statement_start_offset) / 2 + 1), 4000)
FROM #req r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.total_elapsed_time / 1000 >= @longRunWarnSec
  AND r.wait_type NOT IN ('WAITFOR', 'BROKER_RECEIVE_WAITFOR', 'SP_SERVER_DIAGNOSTICS_SLEEP', 'XE_LIVE_TARGET_TVF')
  AND r.command NOT IN ('BACKUP DATABASE', 'BACKUP LOG')   -- shown by the backup check instead
ORDER BY r.total_elapsed_time DESC;
