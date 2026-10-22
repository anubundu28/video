/*  Always On availability groups
    Required permissions: VIEW SERVER STATE
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @sendQueueWarnKB bigint = 1048576;   -- 1 GB
DECLARE @redoQueueWarnKB bigint = 1048576;   -- 1 GB
DECLARE @lagWarnSec      int    = 60;
DECLARE @lagCritSec      int    = 600;

IF ISNULL(CAST(SERVERPROPERTY('IsHadrEnabled') AS int), 0) = 0
    PRINT 'Always On availability groups are not enabled on this instance.';

-- ---- 1. Availability groups ------------------------------------------------
SELECT Status = CASE gs.synchronization_health WHEN 0 THEN 'CRITICAL' WHEN 1 THEN 'WARNING' ELSE 'OK' END,
       AvailabilityGroup = ag.name,
       PrimaryReplica    = gs.primary_replica,
       LocalRole         = rs.role_desc,
       SyncHealth        = gs.synchronization_health_desc,
       Listener          = (SELECT TOP (1) l.dns_name + ',' + CAST(l.port AS varchar(10))
                            FROM sys.availability_group_listeners l WHERE l.group_id = ag.group_id),
       Replicas          = (SELECT COUNT(*) FROM sys.availability_replicas r WHERE r.group_id = ag.group_id),
       Databases         = (SELECT COUNT(*) FROM sys.availability_databases_cluster d WHERE d.group_id = ag.group_id)
FROM sys.availability_groups ag
LEFT JOIN sys.dm_hadr_availability_group_states gs ON gs.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states rs ON rs.group_id = ag.group_id AND rs.is_local = 1
ORDER BY ag.name;

-- ---- 2. Database replica states --------------------------------------------
;WITH s AS (
    SELECT drs.*,
           PrimaryCommit = (SELECT TOP (1) p.last_commit_time
                            FROM sys.dm_hadr_database_replica_states p
                            JOIN sys.dm_hadr_availability_replica_states pr ON pr.replica_id = p.replica_id
                            WHERE p.group_database_id = drs.group_database_id AND pr.role = 1)
    FROM sys.dm_hadr_database_replica_states drs
)
SELECT Status = CASE
           WHEN s.synchronization_health = 0 THEN 'CRITICAL'
           WHEN ars.role = 2 AND DATEDIFF(SECOND, s.last_commit_time, s.PrimaryCommit) >= @lagCritSec THEN 'CRITICAL'
           WHEN s.is_suspended = 1 OR s.synchronization_health = 1 THEN 'WARNING'
           WHEN s.log_send_queue_size >= @sendQueueWarnKB OR s.redo_queue_size >= @redoQueueWarnKB THEN 'WARNING'
           WHEN ars.role = 2 AND DATEDIFF(SECOND, s.last_commit_time, s.PrimaryCommit) >= @lagWarnSec THEN 'WARNING'
           ELSE 'OK' END,
       AvailabilityGroup = ag.name,
       DatabaseName      = adc.database_name,
       Replica           = ar.replica_server_name,
       Role              = ars.role_desc,
       AvailabilityMode  = ar.availability_mode_desc,
       SyncState         = s.synchronization_state_desc,
       SyncHealth        = s.synchronization_health_desc,
       Suspended         = s.is_suspended,
       SuspendReason     = s.suspend_reason_desc,
       LogSendQueueKB    = s.log_send_queue_size,
       RedoQueueKB       = s.redo_queue_size,
       EstLagSec         = CASE WHEN ars.role = 2 THEN DATEDIFF(SECOND, s.last_commit_time, s.PrimaryCommit) END,
       LastCommitTime    = s.last_commit_time,
       Connected         = ars.connected_state_desc
FROM s
JOIN sys.availability_replicas ar ON ar.replica_id = s.replica_id
JOIN sys.availability_groups ag ON ag.group_id = s.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = s.replica_id
LEFT JOIN sys.availability_databases_cluster adc ON adc.group_database_id = s.group_database_id
ORDER BY ag.name, adc.database_name, ars.role, ar.replica_server_name;
