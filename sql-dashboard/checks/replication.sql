/*  Replication status
    -----------------------------------------------------------------------
    Works on any instance; what it returns depends on the instance's role:
      1. Replication agents      - on a Distributor (reads every distribution DB)
      2. Replication errors      - on a Distributor, last @errorHours hours
      3. Replicated databases    - publisher / subscriber / distributor flags
      4. Subscriptions           - subscriber side (MSreplication_subscriptions)

    Status column convention used by the dashboard: OK | INFO | WARNING | CRITICAL
    Required permissions: VIEW SERVER STATE, read access to the distribution
    database(s) (e.g. member of replmonitor role) and to subscriber databases.
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 10000;

-- ---- Thresholds (adjust to your environment) -----------------------------
DECLARE @latencyWarnSec  int    = 300;      -- 5 minutes
DECLARE @latencyCritSec  int    = 1800;     -- 30 minutes
DECLARE @pendingWarn     bigint = 50000;    -- undistributed commands
DECLARE @pendingCrit     bigint = 500000;
DECLARE @errorHours      int    = 24;

CREATE TABLE #agents (
    DistributionDB   sysname        NOT NULL,
    AgentType        varchar(20)    NOT NULL,
    RunStatus        int            NULL,
    Publisher        sysname        NULL,
    PublisherDB      sysname        NULL,
    Publication      sysname        NULL,
    Subscriber       sysname        NULL,
    SubscriberDB     sysname        NULL,
    LatencySec       int            NULL,
    PendingCommands  bigint         NULL,
    LastActivity     datetime       NULL,
    LastMessage      nvarchar(4000) NULL,
    AgentName        nvarchar(400)  NULL
);

CREATE TABLE #errors (
    DistributionDB sysname        NOT NULL,
    ErrorTime      datetime       NULL,
    Source         nvarchar(400)  NULL,
    ErrorCode      sysname        NULL,
    ErrorText      nvarchar(4000) NULL
);

DECLARE @db sysname, @q nvarchar(300), @srv nvarchar(max), @sql nvarchar(max);
DECLARE @distCount int = 0;

DECLARE dist_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE is_distributor = 1 AND state = 0;
OPEN dist_cur;
FETCH NEXT FROM dist_cur INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @distCount += 1;
    SET @q = QUOTENAME(@db);

    -- Server-name lookup: SQL 2016+ keeps replication server ids in MSreplservers.
    SET @srv = CASE WHEN OBJECT_ID(@q + N'.dbo.MSreplservers') IS NOT NULL
        THEN N'COALESCE((SELECT TOP (1) rs.srvname FROM ' + @q + N'.dbo.MSreplservers rs WHERE rs.srvid = {id}),
                        (SELECT TOP (1) s.name FROM sys.servers s WHERE s.server_id = {id}))'
        ELSE N'(SELECT TOP (1) s.name FROM sys.servers s WHERE s.server_id = {id})' END;

    -- Log Reader agents
    BEGIN TRY
        SET @sql = N'
        INSERT #agents (DistributionDB, AgentType, RunStatus, Publisher, PublisherDB, LatencySec, LastActivity, LastMessage, AgentName)
        SELECT @db, ''Log Reader'', h.runstatus, ' + REPLACE(@srv, N'{id}', N'a.publisher_id') + N', a.publisher_db,
               h.delivery_latency / 1000, h.[time], h.comments, a.name
        FROM ' + @q + N'.dbo.MSlogreader_agents a
        OUTER APPLY (SELECT TOP (1) x.runstatus, x.[time], x.comments, x.delivery_latency
                     FROM ' + @q + N'.dbo.MSlogreader_history x
                     WHERE x.agent_id = a.id ORDER BY x.[time] DESC, x.[timestamp] DESC) h;';
        EXEC sys.sp_executesql @sql, N'@db sysname', @db;
    END TRY
    BEGIN CATCH
        PRINT 'Log Reader agents in ' + @db + ' could not be read: ' + ERROR_MESSAGE();
    END CATCH;

    -- Distribution agents (+ undistributed commands)
    BEGIN TRY
        SET @sql = N'
        INSERT #agents (DistributionDB, AgentType, RunStatus, Publisher, PublisherDB, Publication, Subscriber, SubscriberDB,
                        LatencySec, PendingCommands, LastActivity, LastMessage, AgentName)
        SELECT @db, ''Distribution'', h.runstatus, ' + REPLACE(@srv, N'{id}', N'a.publisher_id') + N', a.publisher_db, a.publication,
               ' + REPLACE(@srv, N'{id}', N'a.subscriber_id') + N', a.subscriber_db,
               h.current_delivery_latency / 1000, ISNULL(p.pending, 0), h.[time], h.comments, a.name
        FROM ' + @q + N'.dbo.MSdistribution_agents a
        OUTER APPLY (SELECT TOP (1) x.runstatus, x.[time], x.comments, x.current_delivery_latency
                     FROM ' + @q + N'.dbo.MSdistribution_history x
                     WHERE x.agent_id = a.id ORDER BY x.[time] DESC, x.[timestamp] DESC) h
        OUTER APPLY (SELECT SUM(CAST(s.UndelivCmdsInDistDB AS bigint)) AS pending
                     FROM ' + @q + N'.dbo.MSdistribution_status s WHERE s.agent_id = a.id) p
        WHERE ISNULL(a.subscriber_id, 0) >= 0;   -- skip virtual / anonymous placeholders';
        EXEC sys.sp_executesql @sql, N'@db sysname', @db;
    END TRY
    BEGIN CATCH
        PRINT 'Distribution agents in ' + @db + ' could not be read: ' + ERROR_MESSAGE();
    END CATCH;

    -- Merge agents
    BEGIN TRY
        SET @sql = N'
        INSERT #agents (DistributionDB, AgentType, RunStatus, Publisher, PublisherDB, Publication, Subscriber, SubscriberDB,
                        LastActivity, LastMessage, AgentName)
        SELECT @db, ''Merge'', s.runstatus, ' + REPLACE(@srv, N'{id}', N'a.publisher_id') + N', a.publisher_db, a.publication,
               a.subscriber_name, a.subscriber_db, COALESCE(s.end_time, s.start_time), m.comments, a.name
        FROM ' + @q + N'.dbo.MSmerge_agents a
        OUTER APPLY (SELECT TOP (1) x.session_id, x.runstatus, x.start_time, x.end_time
                     FROM ' + @q + N'.dbo.MSmerge_sessions x
                     WHERE x.agent_id = a.id ORDER BY x.start_time DESC) s
        OUTER APPLY (SELECT TOP (1) y.comments
                     FROM ' + @q + N'.dbo.MSmerge_history y
                     WHERE y.session_id = s.session_id ORDER BY y.[time] DESC) m;';
        EXEC sys.sp_executesql @sql, N'@db sysname', @db;
    END TRY
    BEGIN CATCH
        PRINT 'Merge agents in ' + @db + ' could not be read: ' + ERROR_MESSAGE();
    END CATCH;

    -- Recent errors
    BEGIN TRY
        SET @sql = N'
        INSERT #errors (DistributionDB, ErrorTime, Source, ErrorCode, ErrorText)
        SELECT TOP (200) @db, e.[time], e.source_name, e.error_code, e.error_text
        FROM ' + @q + N'.dbo.MSrepl_errors e
        WHERE e.[time] >= DATEADD(HOUR, -@h, GETDATE())
        ORDER BY e.[time] DESC;';
        EXEC sys.sp_executesql @sql, N'@db sysname, @h int', @db, @errorHours;
    END TRY
    BEGIN CATCH
        PRINT 'Replication errors in ' + @db + ' could not be read: ' + ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM dist_cur INTO @db;
END
CLOSE dist_cur;
DEALLOCATE dist_cur;

IF @distCount = 0
    PRINT 'This instance is not a Distributor - agent status and errors are read on the Distributor. Local publisher/subscriber details are shown below.';

-- ---- 1. Replication agents -------------------------------------------------
;WITH a AS (
    SELECT *,
        Status = CASE
            WHEN RunStatus = 6                                              THEN 'CRITICAL'
            WHEN LatencySec >= @latencyCritSec OR PendingCommands >= @pendingCrit THEN 'CRITICAL'
            WHEN RunStatus = 5                                              THEN 'WARNING'
            WHEN LatencySec >= @latencyWarnSec OR PendingCommands >= @pendingWarn THEN 'WARNING'
            WHEN RunStatus = 2 AND AgentType IN ('Log Reader', 'Distribution')
                 AND ISNULL(PendingCommands, 0) > 0                         THEN 'WARNING'
            WHEN RunStatus IS NULL                                          THEN 'WARNING'
            ELSE 'OK' END
    FROM #agents
)
SELECT Status,
       AgentType,
       AgentState = CASE RunStatus WHEN 1 THEN 'Started' WHEN 2 THEN 'Stopped / completed' WHEN 3 THEN 'In progress'
                                   WHEN 4 THEN 'Idle' WHEN 5 THEN 'Retrying' WHEN 6 THEN 'Failed' ELSE 'No history' END,
       Publisher, PublisherDB, Publication, Subscriber, SubscriberDB,
       LatencySec, PendingCommands, LastActivity,
       MinutesSinceActivity = DATEDIFF(MINUTE, LastActivity, GETDATE()),
       LastMessage, AgentName, DistributionDB
FROM a
ORDER BY CASE Status WHEN 'CRITICAL' THEN 0 WHEN 'WARNING' THEN 1 ELSE 2 END, AgentType, Publisher, Publication;

-- ---- 2. Recent replication errors ------------------------------------------
SELECT Status = CASE WHEN ErrorTime >= DATEADD(HOUR, -1, GETDATE()) THEN 'CRITICAL' ELSE 'WARNING' END,
       ErrorTime, Source, ErrorCode, ErrorText, DistributionDB
FROM #errors
ORDER BY ErrorTime DESC;

-- ---- 3. Replicated databases on this instance ------------------------------
SELECT Status = CASE WHEN d.log_reuse_wait_desc = 'REPLICATION' THEN 'WARNING' ELSE 'OK' END,
       DatabaseName      = d.name,
       Published         = CAST(d.is_published AS bit),
       MergePublished    = CAST(d.is_merge_published AS bit),
       Subscribed        = CAST(d.is_subscribed AS bit),
       Distributor       = CAST(d.is_distributor AS bit),
       LogReuseWait      = d.log_reuse_wait_desc,
       Note = CASE WHEN d.log_reuse_wait_desc = 'REPLICATION'
                   THEN 'Log cannot be truncated until the Log Reader has processed it' END
FROM sys.databases d
WHERE d.is_published = 1 OR d.is_merge_published = 1 OR d.is_subscribed = 1 OR d.is_distributor = 1
ORDER BY d.name;

-- ---- 4. Subscriptions (subscriber side) -------------------------------------
CREATE TABLE #subs (
    SubscriberDB sysname, Publisher sysname NULL, PublisherDB sysname NULL, Publication sysname NULL,
    SubscriptionType varchar(10) NULL, LastSync datetime NULL, DistributionAgent nvarchar(400) NULL
);

DECLARE sub_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE state = 0 AND database_id > 4 AND HAS_DBACCESS(name) = 1;
OPEN sub_cur;
FETCH NEXT FROM sub_cur INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @q = QUOTENAME(@db);
    IF OBJECT_ID(@q + N'.dbo.MSreplication_subscriptions') IS NOT NULL
    BEGIN
    BEGIN TRY
        SET @sql = N'
        INSERT #subs
        SELECT @db, s.publisher, s.publisher_db, s.publication,
               CASE s.subscription_type WHEN 0 THEN ''Push'' WHEN 1 THEN ''Pull'' ELSE ''Anonymous'' END,
               s.[time], s.distribution_agent
        FROM ' + @q + N'.dbo.MSreplication_subscriptions s;';
        EXEC sys.sp_executesql @sql, N'@db sysname', @db;
    END TRY
    BEGIN CATCH
        PRINT 'Subscriptions in ' + @db + ' could not be read: ' + ERROR_MESSAGE();
    END CATCH;
    END
    FETCH NEXT FROM sub_cur INTO @db;
END
CLOSE sub_cur;
DEALLOCATE sub_cur;

SELECT Status = 'INFO',
       SubscriberDB, Publisher, PublisherDB, Publication, SubscriptionType,
       LastSync, MinutesSinceSync = DATEDIFF(MINUTE, LastSync, GETDATE()), DistributionAgent
FROM #subs
ORDER BY Publisher, Publication;
