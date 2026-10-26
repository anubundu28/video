/* =========================================================================
   Demo mode - sample data so the UI can be previewed without SQL Server.
   Used only when index.html is opened from disk (file://) or with #demo.
   Never used when the page is served by server.ps1 with a session key.
   ========================================================================= */
(function () {
  'use strict';

  const now = Date.now();
  const p2 = n => String(n).padStart(2, '0');
  const ago = minutes => {
    const d = new Date(now - minutes * 60000);
    return d.getFullYear() + '-' + p2(d.getMonth() + 1) + '-' + p2(d.getDate()) + ' ' + p2(d.getHours()) + ':' + p2(d.getMinutes()) + ':' + p2(d.getSeconds());
  };
  const DAY = 1440;

  // "Name:type|Name:type" -> result set
  function T(spec, rows) {
    return { columns: spec.split('|').map(s => { const p = s.split(':'); return { name: p[0], type: p[1] || 'nvarchar' }; }), rows: rows || [], truncated: false };
  }

  const config = {
    title: 'SQL Server Health', environment: 'DEMO', version: '2.0.0',
    ui: { concurrency: 6, pingOnLoad: true, cacheSeconds: 120, defaultAutoRefresh: 0 },
    instances: [
      { id: 'prod-pub', name: 'PROD-SQL01', server: 'PROD-SQL01.corp.local', group: 'Production', role: 'Publisher', auth: 'windows' },
      { id: 'prod-dist', name: 'PROD-SQL02\\DIST', server: 'PROD-SQL02.corp.local\\DIST', group: 'Production', role: 'Distributor', auth: 'windows' },
      { id: 'rpt-sub', name: 'RPT-SQL01', server: 'RPT-SQL01.corp.local,1433', group: 'Reporting', role: 'Subscriber', auth: 'sql' },
      { id: 'dr-sql', name: 'DR-SQL01', server: 'DR-SQL01.corp.local', group: 'Disaster recovery', role: 'AG secondary', auth: 'windows' },
      { id: 'dev-sql', name: 'DEV-SQL03', server: 'DEV-SQL03.corp.local', group: 'Non-production', role: 'Dev', auth: 'windows' }
    ],
    checks: [
      { id: 'summary', title: 'Server overview', resultTitles: ['Summary', 'Disks', 'Databases', 'CPU history'] },
      { id: 'databases', title: 'All databases', resultTitles: ['Databases'] },
      { id: 'backup-missing', title: 'Missing full backups', resultTitles: ['No full backup in the last 7 days'], emptyMessages: ['Every online database has a full backup from the last 7 days.'] },
      { id: 'running-backups', title: 'Running backups', resultTitles: ['In progress', 'Completed in the last 24 h'], emptyMessages: ['No backup or restore is running right now.', 'No backups finished in the last 24 hours.'] },
      { id: 'backups', title: 'Backup RPO', resultTitles: ['Backups by database'] },
      { id: 'queries', title: 'Running queries', resultTitles: ['Active requests', 'Head blockers'], emptyMessages: ['Nothing is running right now - the server is idle.', 'No blocking.'] },
      { id: 'replication', title: 'Replication', resultTitles: ['Replication agents', 'Replication errors (last 24 h)', 'Replicated databases on this server', 'Subscriptions on this server'],
        emptyMessages: ['No replication agents here - agent status is read on the Distributor.', 'No replication errors in the last 24 hours.', 'No published or subscribed databases on this server.', 'No subscriptions on this server.'] },
      { id: 'ag', title: 'Availability groups', resultTitles: ['Availability groups', 'Database replica states'], emptyMessages: ['No availability groups on this server.', 'No availability databases.'] },
      { id: 'jobs', title: 'Agent jobs', resultTitles: ['SQL Server Agent service', 'Failed / retried steps (last 24 h)', 'All jobs'], emptyMessages: ['SQL Server Agent is not installed.', 'No job failures in the last 24 hours.', 'No jobs defined.'] },
      { id: 'waits', title: 'Wait statistics', resultTitles: ['Top waits'] },
      { id: 'errorlog', title: 'Error log', resultTitles: ['Error log entries'], emptyMessages: ['No errors logged in the last 24 hours.'] }
    ],
    pages: [
      { id: 'overview', title: 'Overview', icon: 'gauge', view: 'overview', checks: ['summary'], group: 'Server', description: '' },
      { id: 'databases', title: 'Databases', icon: 'database', checks: ['databases'], group: 'Server', badge: 'UserDatabases', description: 'Every database on this server with state, size, log usage and last full backup.' },
      { id: 'backup-missing', title: 'Missing backups', icon: 'archive', checks: ['backup-missing'], group: 'Backups', badge: 'BackupsMissing7d', description: 'Databases whose last full backup is older than 7 days (or that were never backed up).' },
      { id: 'running-backups', title: 'Running backups', icon: 'progress', checks: ['running-backups'], group: 'Backups', badge: 'RunningBackups', description: 'Live progress of backups and restores, and the backups completed in the last 24 hours.' },
      { id: 'backup-rpo', title: 'Backup RPO', icon: 'shield', checks: ['backups'], group: 'Backups', description: 'Full, differential and log backup age for every database against RPO thresholds.' },
      { id: 'queries', title: 'Running queries', icon: 'activity', checks: ['queries'], group: 'Activity', badge: 'ActiveRequests', description: 'What is executing right now, longest first, with blocking chains.' },
      { id: 'replication', title: 'Replication', icon: 'replication', checks: ['replication'], group: 'Activity', description: 'Replication agents, latency, undistributed commands, errors and subscriptions.' },
      { id: 'ag', title: 'Availability groups', icon: 'cluster', checks: ['ag'], group: 'More', description: 'Always On health, synchronization, queues and estimated lag.' },
      { id: 'jobs', title: 'Agent jobs', icon: 'clock', checks: ['jobs'], group: 'More', badge: 'FailedJobs24h', description: 'Agent service, failed steps in the last 24 h and the status of every job.' },
      { id: 'waits', title: 'Wait statistics', icon: 'hourglass', checks: ['waits'], group: 'More', description: 'Where the server spends its time waiting since the last restart.' },
      { id: 'errorlog', title: 'Error log', icon: 'file', checks: ['errorlog'], group: 'More', description: 'Errors and failures in the current SQL Server error log (last 24 h).' }
    ]
  };

  // ---- per-server profile ---------------------------------------------------
  const P = {
    'prod-pub': { ver: ['16.0.4135.4', 'RTM', 'CU15'], ed: 'Enterprise Edition (64-bit)', host: 'Windows Server 2022 Datacenter', cpus: 32, ram: 262144, max: 235520, used: 229376, cpu: 41, other: 6, ple: 1840, hadr: true, uptime: 59460,
      dbs: [['Sales', 812345, 65536, 'FULL'], ['Finance', 210554, 16384, 'FULL'], ['Inventory', 98304, 8192, 'FULL'], ['Customer360', 64000, 6144, 'FULL'], ['Audit', 40960, 10240, 'FULL'], ['SSISDB', 6144, 1024, 'SIMPLE'], ['ReportServer', 2048, 512, 'FULL']],
      disks: [['D:\\', 'SQLData', 4096, 1145.9, 8], ['L:\\', 'SQLLogs', 500, 289.6, 7], ['T:\\', 'TempDB', 200, 136, 9], ['C:\\', 'System', 150, 41.2, 4]],
      sessions: 612, requests: 37, blocked: 3, running: 1, missing: 2, failed: 1 },
    'prod-dist': { ver: ['15.0.4385.2', 'RTM', 'CU27'], ed: 'Standard Edition (64-bit)', host: 'Windows Server 2019 Standard', cpus: 16, ram: 131072, max: 2147483647, used: 118784, cpu: 12, other: 3, ple: 9211, uptime: 129600,
      dbs: [['distribution', 51200, 8192, 'SIMPLE']],
      disks: [['D:\\', 'SQLData', 1024, 610.4, 5], ['L:\\', 'SQLLogs', 500, 68.8, 5]],
      sessions: 48, requests: 6, blocked: 0, running: 0, missing: 0, failed: 0 },
    'rpt-sub': { ver: ['15.0.4385.2', 'RTM', 'CU27'], ed: 'Standard Edition (64-bit)', host: 'Windows Server 2019 Standard', cpus: 16, ram: 131072, max: 114688, used: 114688, cpu: 22, other: 4, ple: 4410, uptime: 20160,
      dbs: [['SalesRpt', 640000, 32768, 'SIMPLE'], ['InventoryRpt', 81920, 8192, 'SIMPLE'], ['AdHocAnalysis', 40960, 4096, 'FULL']],
      disks: [['E:\\', 'Reporting', 2048, 1101.5, 9], ['L:\\', 'Logs', 250, 160, 6]],
      sessions: 120, requests: 9, blocked: 0, running: 0, missing: 1, failed: 0 },
    'dr-sql': { ver: ['16.0.4135.4', 'RTM', 'CU15'], ed: 'Enterprise Edition (64-bit)', host: 'Windows Server 2022 Datacenter', cpus: 32, ram: 262144, max: 235520, used: 98304, cpu: 7, other: 2, ple: 22000, hadr: true, uptime: 3200,
      dbs: [['Sales', 812345, 65536, 'FULL'], ['Inventory', 98304, 8192, 'FULL'], ['Finance', 210554, 16384, 'FULL']],
      disks: [['D:\\', 'SQLData', 4096, 1980, 6], ['L:\\', 'SQLLogs', 500, 340, 6]],
      sessions: 14, requests: 2, blocked: 0, running: 1, missing: 0, failed: 0 }
  };
  const SYS = [['msdb', 1820, 240, 'SIMPLE'], ['tempdb', 32768, 8192, 'SIMPLE'], ['model', 16, 8, 'FULL'], ['master', 6, 2, 'SIMPLE']];
  const allDbs = id => P[id].dbs.map(d => d.concat(false)).concat(SYS.map(d => d.concat(true)));

  const checks = {
    summary(id) {
      const p = P[id];
      const dbs = allDbs(id);
      const data = dbs.reduce((a, d) => a + d[1], 0), log = dbs.reduce((a, d) => a + d[2], 0);
      const cpu = [];
      for (let i = 59; i >= 0; i--) {
        const wave = Math.sin(i / 6) * 9 + Math.sin(i / 2.3) * 4;
        cpu.push([i, Math.max(1, Math.round(p.cpu + wave + (i < 12 && id === 'prod-pub' ? 14 - i : 0))), Math.max(0, Math.round(p.other + Math.cos(i / 4) * 2))]);
      }
      return { messages: [], resultSets: [
        T('ServerName|MachineName|InstanceName|ProductVersion|ProductLevel|UpdateLevel|Edition|Collation|HostPlatform|IsClustered:bit|IsHadrEnabled:bit|StartTime:datetime|UptimeMinutes:int|LogicalCpus:int|SqlCpuPct:int|OtherCpuPct:int|PhysicalMemoryMB:bigint|MaxServerMemoryMB:bigint|TotalServerMemoryMB:bigint|TargetServerMemoryMB:bigint|PageLifeExpectancy:bigint|MemoryGrantsPending:bigint|MaxDop:int|CostThreshold:int|UserSessions:int|ActiveRequests:int|BlockedRequests:int|RunningBackups:int|BackupsMissing7d:int|FailedJobs24h:int|DatabaseCount:int|UserDatabases:int|OnlineDatabases:int|DataSizeMB:decimal|LogSizeMB:decimal|ServerTime:datetime', [[
          config.instances.find(i => i.id === id).name, config.instances.find(i => i.id === id).name.split('\\')[0], id === 'prod-dist' ? 'DIST' : 'MSSQLSERVER',
          p.ver[0], p.ver[1], p.ver[2], p.ed, 'SQL_Latin1_General_CP1_CI_AS', p.host, false, !!p.hadr, ago(p.uptime), p.uptime, p.cpus, cpu[59][1], cpu[59][2],
          p.ram, p.max, p.used, p.used, p.ple, 0, 8, 50, p.sessions, p.requests, p.blocked, p.running, p.missing, p.failed,
          dbs.length, p.dbs.length, dbs.length, data, log, ago(0)]]),
        T('Volume|Label|TotalGB:decimal|FreeGB:decimal|FreePct:decimal|DatabaseFiles:int', p.disks.map(d => [d[0], d[1], d[2], d[3], Math.round(1000 * d[3] / d[2]) / 10, d[4]])),
        T('DatabaseName|State|RecoveryModel|DataMB:decimal|LogMB:decimal|IsSystem:bit', dbs.sort((a, b) => (b[1] + b[2]) - (a[1] + a[2])).map(d => [d[0], 'ONLINE', d[3], d[1], d[2], d[4]])),
        T('MinutesAgo:int|SqlCpu:int|OtherCpu:int', cpu)
      ] };
    },

    databases(id) {
      const missing = { 'prod-pub': ['Audit', 'ReportServer'], 'rpt-sub': ['AdHocAnalysis'] }[id] || [];
      const rows = allDbs(id).map((d, i) => {
        const logPct = d[0] === 'Sales' ? 81.4 : d[0] === 'tempdb' ? 6.2 : Math.round((8 + (i * 17) % 40) * 10) / 10;
        const status = logPct >= 75 ? 'WARNING' : d[0] === 'AdHocAnalysis' ? 'WARNING' : 'OK';
        const full = missing.indexOf(d[0]) >= 0 ? (d[0] === 'Audit' ? ago(12 * DAY) : null) : d[0] === 'tempdb' ? null : ago(600 + i * 13);
        return [status, d[0], 'ONLINE', 'MULTI_USER', d[3], d[1], d[2], logPct, full, d[0] === 'Sales' ? 'LOG_BACKUP' : d[0] === 'Finance' && id === 'prod-pub' ? 'REPLICATION' : 'NOTHING',
          d[4] ? 160 : 150, d[0] === 'AdHocAnalysis' ? 'TORN_PAGE_DETECTION' : 'CHECKSUM', d[0] === 'AdHocAnalysis' ? 'auto-shrink ON; page verify not CHECKSUM' : null, d[4] ? 'sa' : 'CORP\\svc_sql', ago(d[4] ? 900000 : 400000 + i * 9000)];
      });
      return { messages: [], resultSets: [T('Status|DatabaseName|State|Access|RecoveryModel|DataMB:decimal|LogMB:decimal|LogUsedPct:decimal|LastFullBackup:datetime|LogReuseWait|Compatibility:tinyint|PageVerify|Notes|Owner|Created:datetime', rows)] };
    },

    'backup-missing'(id) {
      const rows = {
        'prod-pub': [
          ['CRITICAL', 'ReportServer', null, null, null, ago(30), 'FULL', 2.5, ago(400000), 'Never backed up (since creation / restore)'],
          ['CRITICAL', 'Audit', ago(12 * DAY), 12, ago(2 * DAY), ago(14), 'FULL', 50.0, ago(500000), 'Last full backup 12 days ago']
        ],
        'rpt-sub': [['CRITICAL', 'AdHocAnalysis', null, null, null, null, 'FULL', 44.0, ago(20 * DAY), 'Never backed up (since creation / restore)']]
      }[id] || [];
      return { messages: [], resultSets: [T('Status|DatabaseName|LastFullBackup:datetime|DaysSinceFull:int|LastDiff:datetime|LastLog:datetime|RecoveryModel|SizeGB:decimal|Created:datetime|Note', rows)] };
    },

    'running-backups'(id) {
      const live = {
        'prod-pub': [['OK', 142, 'BACKUP DATABASE', 'Sales', 63.4, ago(38), 38, 21.9, ago(-22), 'ASYNC_IO_COMPLETION', 'CORP\\svc_sqlagent', 'SQLAgent - TSQL JobStep (Job 0x8A1F... : Step 1)', "BACKUP DATABASE [Sales] TO URL = N'https://backup.blob.core.windows.net/sql/Sales_FULL.bak' WITH COMPRESSION, CHECKSUM, STATS = 5"]],
        'dr-sql': [['OK', 77, 'RESTORE LOG', 'Inventory', 91.0, ago(2), 2, 0.2, ago(-1), 'BACKUPIO', 'CORP\\svc_logship', 'SQLAgent - TSQL JobStep', "RESTORE LOG [Inventory] FROM DISK = N'\\\\backup01\\logship\\Inventory_2026.trn' WITH NORECOVERY"]]
      }[id] || [];
      const done = (P[id] ? P[id].dbs : []).slice(0, 4).map((d, i) => [d[0], i % 2 ? 'Log' : 'Full', ago(300 + i * 47), ago(280 + i * 47), i % 2 ? 14 : 1180 - i * 200, i % 2 ? 0.4 : Math.round(d[1] / 1024 * 0.7 * 10) / 10, i % 2 ? 0.1 : Math.round(d[1] / 1024 * 0.25 * 10) / 10, false, '\\\\backup01\\sql\\' + d[0] + (i % 2 ? '_LOG.trn' : '_FULL.bak'), 'CORP\\svc_sqlagent']);
      return { messages: [], resultSets: [
        T('Status|SessionId:smallint|Operation|DatabaseName|PercentComplete:decimal|Started:datetime|ElapsedMin:int|RemainingMin:decimal|EstimatedFinish:datetime|WaitType|LoginName|ProgramName|SqlText', live),
        T('DatabaseName|BackupType|Started:datetime|Finished:datetime|DurationSec:int|SizeGB:decimal|CompressedGB:decimal|CopyOnly:bit|Destination|StartedBy', done)
      ] };
    },

    backups(id) {
      const rows = allDbs(id).filter(d => d[0] !== 'tempdb').map((d, i) => {
        if (d[0] === 'ReportServer' || d[0] === 'AdHocAnalysis') return ['CRITICAL', d[0], d[3], null, null, null, null, null];
        if (d[0] === 'Audit') return ['CRITICAL', d[0], d[3], ago(12 * DAY), ago(2 * DAY), ago(14), 288, 14];
        if (d[0] === 'Inventory' && id === 'prod-pub') return ['WARNING', d[0], d[3], ago(1500), null, ago(95), 25, 95];
        const logAgo = 8 + i * 3;
        return ['OK', d[0], d[3], ago(600 + i * 7), null, d[3] === 'SIMPLE' ? null : ago(logAgo), 10, d[3] === 'SIMPLE' ? null : logAgo];
      });
      return { messages: [], resultSets: [T('Status|DatabaseName|RecoveryModel|LastFull:datetime|LastDiff:datetime|LastLog:datetime|HoursSinceFull:int|MinutesSinceLog:int', rows)] };
    },

    queries(id) {
      const A = 'Status|SessionId:smallint|ElapsedSec:int|DatabaseName|RequestStatus|Command|BlockedBy:smallint|WaitType|WaitSec:int|CpuSec:int|LogicalReads:bigint|Writes:bigint|LoginName|HostName|ProgramName|Statement';
      const H = 'Status|HeadBlocker:smallint|BlockedCount:int|MaxWaitSec:int|LoginName|HostName|ProgramName|SessionStatus|OpenTran:int|LastRequest:datetime|LastSql';
      if (id !== 'prod-pub') {
        return { messages: [], resultSets: [T(A, id === 'prod-dist' ? [['OK', 61, 3, 'distribution', 'suspended', 'WAITFOR', null, 'WAITFOR', 3, 0, 12, 0, 'CORP\\svc_sqlagent', 'PROD-SQL02', 'Replication Distribution Agent', 'WAITFOR DELAY @delay']] : []), T(H)] };
      }
      return { messages: [], resultSets: [
        T(A, [
          ['WARNING', 312, 1420, 'Sales', 'running', 'SELECT', null, 'CXPACKET', 0, 1310, 98234112, 0, 'CORP\\analyst1', 'BI-WS-17', 'Microsoft SQL Server Management Studio - Query', 'SELECT c.Region, SUM(o.Total) AS Revenue FROM dbo.Orders o JOIN dbo.Customers c ON c.Id = o.CustomerId WHERE o.OrderDate >= DATEADD(YEAR, -3, GETDATE()) GROUP BY c.Region'],
          ['WARNING', 233, 96, 'Inventory', 'suspended', 'UPDATE', 187, 'LCK_M_U', 96, 0, 18, 0, 'CORP\\svc_web', 'WEB-01', 'Inventory API', 'UPDATE dbo.StockLevel SET Reserved = Reserved + 1 WHERE StockId = @id'],
          ['WARNING', 245, 61, 'Inventory', 'suspended', 'SELECT', 187, 'LCK_M_S', 61, 0, 6, 0, 'CORP\\svc_web', 'WEB-02', 'Inventory API', 'SELECT Qty, Reserved FROM dbo.StockLevel WHERE StockId = @id'],
          ['OK', 142, 2280, 'Sales', 'suspended', 'BACKUP DATABASE', null, 'ASYNC_IO_COMPLETION', 1, 40, 0, 0, 'CORP\\svc_sqlagent', 'PROD-SQL01', 'SQLAgent - TSQL JobStep', 'BACKUP DATABASE [Sales] TO URL = ...'],
          ['OK', 251, 12, 'Inventory', 'suspended', 'UPDATE', 233, 'LCK_M_U', 12, 0, 4, 0, 'CORP\\svc_web', 'WEB-01', 'Inventory API', 'UPDATE dbo.StockLevel SET Reserved = Reserved + 1 WHERE StockId = @id'],
          ['OK', 198, 4, 'Sales', 'running', 'INSERT', null, null, 0, 3, 1820, 44, 'CORP\\svc_erp', 'APP-ERP01', 'ERP Order Entry', 'INSERT dbo.OrderLines (OrderId, Sku, Qty, Price) VALUES (@o, @s, @q, @p)'],
          ['OK', 204, 1, 'Finance', 'runnable', 'SELECT', null, 'SOS_SCHEDULER_YIELD', 0, 1, 5512, 0, 'CORP\\svc_fin', 'APP-FIN01', 'Finance Portal', 'SELECT TOP (50) * FROM dbo.LedgerEntries WHERE AccountId = @a ORDER BY PostedAt DESC']
        ]),
        T(H, [['WARNING', 187, 3, 96, 'CORP\\svc_erp', 'APP-ERP02', 'ERP Batch Posting', 'sleeping', 1, ago(2), 'BEGIN TRAN;\nUPDATE dbo.StockLevel SET Qty = Qty - @q WHERE StockId = @id;\n-- transaction left open by the application']])
      ] };
    },

    replication(id) {
      const AG = 'Status|AgentType|AgentState|Publisher|PublisherDB|Publication|Subscriber|SubscriberDB|LatencySec:int|PendingCommands:bigint|LastActivity:datetime|MinutesSinceActivity:int|LastMessage|AgentName|DistributionDB';
      const ER = 'Status|ErrorTime:datetime|Source|ErrorCode|ErrorText|DistributionDB';
      const RD = 'Status|DatabaseName|Published:bit|MergePublished:bit|Subscribed:bit|Distributor:bit|LogReuseWait|Note';
      const SB = 'Status|SubscriberDB|Publisher|PublisherDB|Publication|SubscriptionType|LastSync:datetime|MinutesSinceSync:int|DistributionAgent';
      const NOT = 'This server is not a Distributor - agent status and errors are read on the Distributor. Local publisher/subscriber details are shown below.';
      if (id === 'prod-dist') return { messages: [], resultSets: [
        T(AG, [
          ['CRITICAL', 'Distribution', 'Failed', 'PROD-SQL01', 'Finance', 'Finance_Pub', 'BI-SQL01', 'FinanceDW', null, 182334, ago(47), 47, "The process could not connect to Subscriber 'BI-SQL01'. TCP Provider: The wait operation timed out.", 'PROD-SQL01-Finance-Finance_Pub-BI-SQL01-12', 'distribution'],
          ['WARNING', 'Distribution', 'In progress', 'PROD-SQL01', 'Inventory', 'Inventory_Pub', 'RPT-SQL01', 'InventoryRpt', 412, 64210, ago(0), 0, 'Delivering replicated transactions', 'PROD-SQL01-Inventory-Inventory_Pub-RPT-SQL01-9', 'distribution'],
          ['OK', 'Log Reader', 'In progress', 'PROD-SQL01', 'Finance', null, null, null, 2, null, ago(0), 0, '12 transaction(s) with 140 command(s) were delivered.', 'PROD-SQL01-Finance-3', 'distribution'],
          ['OK', 'Log Reader', 'Idle', 'PROD-SQL01', 'Inventory', null, null, null, 1, null, ago(1), 1, 'No replicated transactions are available.', 'PROD-SQL01-Inventory-2', 'distribution'],
          ['OK', 'Log Reader', 'Idle', 'PROD-SQL01', 'Sales', null, null, null, 1, null, ago(0), 0, 'No replicated transactions are available.', 'PROD-SQL01-Sales-1', 'distribution'],
          ['OK', 'Distribution', 'Idle', 'PROD-SQL01', 'Sales', 'Sales_Pub', 'RPT-SQL01', 'SalesRpt', 3, 0, ago(0), 0, 'No replicated transactions are available.', 'PROD-SQL01-Sales-Sales_Pub-RPT-SQL01-7', 'distribution']
        ]),
        T(ER, [
          ['CRITICAL', ago(3), 'BI-SQL01', '-2', 'TCP Provider: The wait operation timed out.', 'distribution'],
          ['CRITICAL', ago(18), 'BI-SQL01', '-2', 'Login timeout expired', 'distribution'],
          ['WARNING', ago(312), 'RPT-SQL01', '20598', "The row was not found at the Subscriber when applying the replicated UPDATE command for Table '[dbo].[StockLevel]' with Primary Key(s): [StockId] = 88213", 'distribution']
        ]),
        T(RD, [['OK', 'distribution', false, false, false, true, 'NOTHING', null]]), T(SB)
      ] };
      if (id === 'prod-pub') return { messages: [NOT], resultSets: [T(AG), T(ER), T(RD, [
        ['WARNING', 'Finance', true, false, false, false, 'REPLICATION', 'Log cannot be truncated until the Log Reader has processed it'],
        ['OK', 'Inventory', true, false, false, false, 'LOG_BACKUP', null], ['OK', 'Sales', true, false, false, false, 'NOTHING', null]]), T(SB)] };
      if (id === 'rpt-sub') return { messages: [NOT], resultSets: [T(AG), T(ER),
        T(RD, [['OK', 'InventoryRpt', false, false, true, false, 'NOTHING', null], ['OK', 'SalesRpt', false, false, true, false, 'NOTHING', null]]),
        T(SB, [['INFO', 'InventoryRpt', 'PROD-SQL01', 'Inventory', 'Inventory_Pub', 'Push', ago(7), 7, 'PROD-SQL01-Inventory-Inventory_Pub-RPT-SQL01-9'],
          ['INFO', 'SalesRpt', 'PROD-SQL01', 'Sales', 'Sales_Pub', 'Push', ago(1), 1, 'PROD-SQL01-Sales-Sales_Pub-RPT-SQL01-7']])] };
      return { messages: [NOT], resultSets: [T(AG), T(ER), T(RD), T(SB)] };
    },

    ag(id) {
      const c1 = 'Status|AvailabilityGroup|PrimaryReplica|LocalRole|SyncHealth|Listener|Replicas:int|Databases:int';
      const c2 = 'Status|AvailabilityGroup|DatabaseName|Replica|Role|AvailabilityMode|SyncState|SyncHealth|Suspended:bit|SuspendReason|LogSendQueueKB:bigint|RedoQueueKB:bigint|EstLagSec:int|LastCommitTime:datetime|Connected';
      if (!P[id].hadr) return { messages: ['Always On availability groups are not enabled on this server.'], resultSets: [T(c1), T(c2)] };
      const prim = id === 'prod-pub';
      const r = prim ? 'PROD-SQL01' : 'DR-SQL01';
      return { messages: [], resultSets: [
        T(c1, [['WARNING', 'AG_Sales', 'PROD-SQL01', prim ? 'PRIMARY' : 'SECONDARY', 'PARTIALLY_HEALTHY', 'sales-ag.corp.local,1433', 2, 3]]),
        T(c2, [
          ['OK', 'AG_Sales', 'Sales', r, prim ? 'PRIMARY' : 'SECONDARY', prim ? 'SYNCHRONOUS_COMMIT' : 'ASYNCHRONOUS_COMMIT', prim ? 'SYNCHRONIZED' : 'SYNCHRONIZING', 'HEALTHY', false, null, 0, 0, prim ? null : 2, ago(0), 'CONNECTED'],
          ['WARNING', 'AG_Sales', 'Inventory', r, prim ? 'PRIMARY' : 'SECONDARY', prim ? 'SYNCHRONOUS_COMMIT' : 'ASYNCHRONOUS_COMMIT', 'SYNCHRONIZING', 'PARTIALLY_HEALTHY', false, null, 1650221, 230114, prim ? null : 96, ago(2), 'CONNECTED'],
          ['OK', 'AG_Sales', 'Finance', r, prim ? 'PRIMARY' : 'SECONDARY', prim ? 'SYNCHRONOUS_COMMIT' : 'ASYNCHRONOUS_COMMIT', prim ? 'SYNCHRONIZED' : 'SYNCHRONIZING', 'HEALTHY', false, null, 12, 0, prim ? null : 1, ago(0), 'CONNECTED']
        ])
      ] };
    },

    jobs(id) {
      const failed = id === 'prod-pub' ? [['CRITICAL', 'DBA - IndexOptimize - USER_DATABASES', 1, 'IndexOptimize', 'Failed', ago(185), 5412, 16, "Executed as user: CORP\\svc_sqlagent. The transaction log for database 'Sales' is full due to 'LOG_BACKUP'. [SQLSTATE 42000] (Error 9002). The step failed."]] : [];
      return { messages: [], resultSets: [
        T('Status|Service|State|StartupType|ServiceAccount|LastStartup:datetime', [['OK', 'SQL Server Agent (MSSQLSERVER)', 'Running', 'Automatic', 'CORP\\svc_sqlagent', ago(P[id].uptime)]]),
        T('Status|JobName|StepId:int|StepName|Outcome|RunAt:datetime|DurationSec:int|SqlSeverity:int|Message', failed),
        T('Status|JobName|Enabled:bit|Running:bit|RunningMin:int|LastOutcome|LastRun:datetime|NextRun:datetime|Category|Owner', [
          id === 'prod-pub' ? ['CRITICAL', 'DBA - IndexOptimize - USER_DATABASES', true, false, null, 'Failed', ago(185), ago(-1255), 'Database Maintenance', 'sa'] : ['OK', 'DBA - IndexOptimize - USER_DATABASES', true, false, null, 'Succeeded', ago(300), ago(-1140), 'Database Maintenance', 'sa'],
          ['OK', 'DBA - DatabaseBackup - FULL', true, id === 'prod-pub', id === 'prod-pub' ? 38 : null, 'Succeeded', ago(1440), ago(-60), 'Database Maintenance', 'sa'],
          ['OK', 'DBA - DatabaseBackup - LOG', true, false, null, 'Succeeded', ago(12), ago(-3), 'Database Maintenance', 'sa'],
          ['OK', 'syspolicy_purge_history', true, false, null, 'Succeeded', ago(700), ago(-740), '[Uncategorized (Local)]', 'sa'],
          ['INFO', 'ETL - Legacy export (retired)', false, false, null, 'Succeeded', ago(90000), null, 'Data Collector', 'CORP\\jdoe']
        ])
      ] };
    },

    waits(id) {
      const busy = id === 'prod-pub';
      return { messages: [], resultSets: [T('WaitType|WaitPct:decimal|WaitSec:decimal|WaitingTasks:bigint|AvgWaitMs:decimal|SignalPct:decimal|Hint', [
        busy ? ['CXPACKET', 31.2, 912334, 88123441, 10.4, 4.1, 'Parallelism - review MAXDOP / cost threshold'] : ['WRITELOG', 28.5, 51233, 9123344, 5.6, 1.2, 'Transaction log writes - log disk latency'],
        ['PAGEIOLATCH_SH', 22.4, busy ? 655210 : 40211, 7712334, 8.5, 0.6, 'Reading data pages from disk - memory pressure or slow storage'],
        busy ? ['LCK_M_U', 12.1, 353812, 120334, 2940.3, 0.1, 'Lock waits - blocking'] : ['ASYNC_NETWORK_IO', 14.2, 25511, 1203344, 21.2, 0.4, 'Client consuming results slowly'],
        ['SOS_SCHEDULER_YIELD', 9.8, busy ? 286640 : 17605, 99812334, 2.9, 99.1, 'CPU pressure'],
        ['WRITELOG', 7.3, busy ? 213510 : 13110, 41233412, 5.2, 1.8, 'Transaction log writes - log disk latency'],
        ['HADR_SYNC_COMMIT', 4.4, 128690, 40123344, 3.2, 0.9, 'Synchronous AG commit latency']
      ])] };
    },

    errorlog(id) {
      const rows = id === 'prod-dist' ? [
        ['WARNING', ago(4), 'Logon', "Login failed for user 'CORP\\svc_bi'. Reason: Could not find a login matching the name provided. [CLIENT: 10.20.4.17]"],
        ['CRITICAL', ago(220), 'spid84', "Error: 1105, Severity: 17, State: 2. Could not allocate space for object 'dbo.MSrepl_commands' in database 'distribution' because the 'PRIMARY' filegroup is full."]
      ] : id === 'prod-pub' ? [['CRITICAL', ago(185), 'spid112', "Error: 9002, Severity: 17, State: 2. The transaction log for database 'Sales' is full due to 'LOG_BACKUP'."]] : [];
      return { messages: [], resultSets: [T('Status|LogDate:datetime|Source|Message', rows)] };
    }
  };

  const delay = ms => new Promise(r => setTimeout(r, ms));

  async function handle(path, body) {
    await delay(120 + Math.random() * 200);
    if (path === '/api/config') return JSON.parse(JSON.stringify(config));
    const id = body.instanceId;
    const t = 200 + Math.random() * 700;
    if (id === 'dev-sql') {
      await delay(1200);
      return { instanceId: id, checkId: body.checkId, ok: false, durationMs: 8012, resultSets: [], messages: [],
        error: 'A network-related or instance-specific error occurred while establishing a connection to SQL Server. The server was not found or was not accessible. (provider: TCP Provider, error: 0 - The wait operation timed out.)' };
    }
    await delay(t);
    if (body.checkId === '__ping') {
      const p = P[id];
      return { instanceId: id, checkId: '__ping', ok: true, durationMs: Math.round(t / 20) + 3, messages: [],
        resultSets: [T('ServerName|ProductVersion|ProductLevel|UpdateLevel|Edition|IsHadrEnabled:int|LoginName', [[id, p.ver[0], p.ver[1], p.ver[2], p.ed, 0, 'CORP\\dba.user']])] };
    }
    const r = checks[body.checkId](id);
    return { instanceId: id, checkId: body.checkId, ok: true, durationMs: Math.round(t), error: null, messages: r.messages, resultSets: r.resultSets };
  }

  window.SqlDashDemo = { handle: handle };
})();
