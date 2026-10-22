/*  Top wait statistics since the last restart (benign waits filtered out)
    Required permissions: VIEW SERVER STATE
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

;WITH w AS (
    SELECT wait_type, wait_time_ms, signal_wait_time_ms, waiting_tasks_count
    FROM sys.dm_os_wait_stats
    WHERE waiting_tasks_count > 0
      AND wait_type NOT IN (
        'BROKER_EVENTHANDLER', 'BROKER_RECEIVE_WAITFOR', 'BROKER_TASK_STOP', 'BROKER_TO_FLUSH', 'BROKER_TRANSMITTER',
        'CHECKPOINT_QUEUE', 'CHKPT', 'CLR_AUTO_EVENT', 'CLR_MANUAL_EVENT', 'CLR_SEMAPHORE', 'CXCONSUMER',
        'DBMIRROR_DBM_EVENT', 'DBMIRROR_EVENTS_QUEUE', 'DBMIRROR_WORKER_QUEUE', 'DBMIRRORING_CMD',
        'DIRTY_PAGE_POLL', 'DISPATCHER_QUEUE_SEMAPHORE', 'EXECSYNC', 'FSAGENT', 'FT_IFTS_SCHEDULER_IDLE_WAIT',
        'FT_IFTSHC_MUTEX', 'HADR_CLUSAPI_CALL', 'HADR_FILESTREAM_IOMGR_IOCOMPLETION', 'HADR_LOGCAPTURE_WAIT',
        'HADR_NOTIFICATION_DEQUEUE', 'HADR_TIMER_TASK', 'HADR_WORK_QUEUE', 'KSOURCE_WAKEUP', 'LAZYWRITER_SLEEP',
        'LOGMGR_QUEUE', 'MEMORY_ALLOCATION_EXT', 'ONDEMAND_TASK_QUEUE', 'PARALLEL_REDO_DRAIN_WORKER',
        'PARALLEL_REDO_LOG_CACHE', 'PARALLEL_REDO_TRAN_LIST', 'PARALLEL_REDO_WORKER_SYNC', 'PARALLEL_REDO_WORKER_WAIT_WORK',
        'PREEMPTIVE_XE_GETTARGETSTATE', 'PWAIT_ALL_COMPONENTS_INITIALIZED', 'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
        'PWAIT_EXTENSIBILITY_CLEANUP_TASK', 'QDS_ASYNC_QUEUE', 'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
        'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', 'QDS_SHUTDOWN_QUEUE', 'REDO_THREAD_PENDING_WORK', 'REQUEST_FOR_DEADLOCK_SEARCH',
        'RESOURCE_QUEUE', 'SERVER_IDLE_CHECK', 'SLEEP_BPOOL_FLUSH', 'SLEEP_DBSTARTUP', 'SLEEP_DCOMSTARTUP',
        'SLEEP_MASTERDBREADY', 'SLEEP_PHYSMASTERDBREADY', 'STARTUP_DEPENDENCY_MANAGER', 'AZURE_IMDS_VERSIONS', 'PVS_PREALLOCATE', 'MSQL_XP', 'SLEEP_MASTERMDREADY', 'SLEEP_MASTERUPGRADED', 'SLEEP_MSDBSTARTUP', 'SLEEP_SYSTEMTASK',
        'SLEEP_TASK', 'SLEEP_TEMPDBSTARTUP', 'SNI_HTTP_ACCEPT', 'SOS_WORK_DISPATCHER', 'SP_SERVER_DIAGNOSTICS_SLEEP',
        'SQLTRACE_BUFFER_FLUSH', 'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', 'SQLTRACE_WAIT_ENTRIES', 'UCS_SESSION_REGISTRATION',
        'VDI_CLIENT_OTHER', 'WAIT_FOR_RESULTS', 'WAIT_XTP_CKPT_CLOSE', 'WAIT_XTP_HOST_WAIT', 'WAIT_XTP_OFFLINE_CKPT_NEW_LOG',
        'WAIT_XTP_RECOVERY', 'WAITFOR', 'WAITFOR_TASKSHUTDOWN', 'XE_BUFFERMGR_ALLPROCESSED_EVENT', 'XE_DISPATCHER_JOIN',
        'XE_DISPATCHER_WAIT', 'XE_LIVE_TARGET_TVF', 'XE_TIMER_EVENT')
)
SELECT TOP (15)
       WaitType      = wait_type,
       WaitPct       = CAST(100.0 * wait_time_ms / SUM(wait_time_ms) OVER () AS decimal(5, 1)),
       WaitSec       = CAST(wait_time_ms / 1000.0 AS decimal(18, 0)),
       WaitingTasks  = waiting_tasks_count,
       AvgWaitMs     = CAST(1.0 * wait_time_ms / waiting_tasks_count AS decimal(18, 1)),
       SignalPct     = CAST(100.0 * signal_wait_time_ms / NULLIF(wait_time_ms, 0) AS decimal(5, 1)),
       Hint = CASE
            WHEN wait_type LIKE 'PAGEIOLATCH%' THEN 'Reading data pages from disk - memory pressure or slow storage'
            WHEN wait_type = 'WRITELOG' THEN 'Transaction log writes - log disk latency'
            WHEN wait_type LIKE 'LCK_M_%' THEN 'Lock waits - blocking'
            WHEN wait_type = 'CXPACKET' THEN 'Parallelism - review MAXDOP / cost threshold'
            WHEN wait_type = 'SOS_SCHEDULER_YIELD' THEN 'CPU pressure'
            WHEN wait_type = 'ASYNC_NETWORK_IO' THEN 'Client consuming results slowly'
            WHEN wait_type = 'RESOURCE_SEMAPHORE' THEN 'Queries waiting for memory grants'
            WHEN wait_type LIKE 'HADR_SYNC_COMMIT' THEN 'Synchronous AG commit latency'
            WHEN wait_type LIKE 'PAGELATCH%' THEN 'In-memory page contention (often tempdb)'
            WHEN wait_type = 'THREADPOOL' THEN 'Worker thread starvation'
            END
FROM w
ORDER BY wait_time_ms DESC;
