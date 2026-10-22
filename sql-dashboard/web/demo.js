/* =========================================================================
   Demo mode - sample data so the UI can be previewed without SQL Server.
   Used only when index.html is opened from disk (file://) or with #demo.
   Never used when the page is served by server.ps1 with a session key.
   ========================================================================= */
(function () {
  'use strict';

  const now = Date.now();
  const ago = (minutes) => {
    const d = new Date(now - minutes * 60000);
    const p = n => String(n).padStart(2, '0');
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  };

  // "Name:type" column specs -> column objects
  function T(spec, rows) {
    return {
      columns: spec.split('|').map(s => { const [name, type] = s.split(':'); return { name: name, type: type || 'nvarchar' }; }),
      rows: rows || [],
      truncated: false
    };
  }

  const config = {
    title: 'SQL Server Health Dashboard',
    environment: 'DEMO',
    version: '1.0.0',
    ui: { concurrency: 6, pingOnLoad: true, defaultAutoRefresh: 0 },
    instances: [
      { id: 'prod-pub', name: 'PROD-SQL01', server: 'PROD-SQL01.corp.local', group: 'Production', role: 'Publisher', description: 'Primary OLTP', auth: 'windows' },
      { id: 'prod-dist', name: 'PROD-SQL02\\DIST', server: 'PROD-SQL02.corp.local\\DIST', group: 'Production', role: 'Distributor', description: '', auth: 'windows' },
      { id: 'rpt-sub', name: 'RPT-SQL01', server: 'RPT-SQL01.corp.local,1433', group: 'Reporting', role: 'Subscriber', description: 'Reporting copy', auth: 'sql' },
      { id: 'dr-sql', name: 'DR-SQL01', server: 'DR-SQL01.corp.local', group: 'Disaster recovery', role: 'AG secondary', description: '', auth: 'windows' },
      { id: 'dev-sql', name: 'DEV-SQL03', server: 'DEV-SQL03.corp.local', group: 'Non-production', role: 'Dev', description: '', auth: 'windows' }
    ],
    checks: [
      { id: 'replication', title: 'Replication Status', description: 'Log Reader, Distribution and Merge agents, latency, undistributed commands and recent replication errors.', category: 'Replication', icon: 'replication', featured: true, resultTitles: ['Replication agents', 'Replication errors (last 24 h)', 'Replicated databases on this instance', 'Subscriptions (subscriber side)'] },
      { id: 'overview', title: 'Instance Overview', description: 'Version, uptime, CPU, memory, page life expectancy and current activity.', category: 'Instance', icon: 'server', resultTitles: ['Instance metrics'] },
      { id: 'ag', title: 'Availability Groups', description: 'Always On group health, synchronization state, send/redo queues and estimated lag.', category: 'High availability', icon: 'shield', resultTitles: ['Availability groups', 'Database replica states'] },
      { id: 'jobs', title: 'SQL Agent Jobs', description: 'Agent service state, failed job steps in the last 24 h and the status of every job.', category: 'Automation', icon: 'clock', resultTitles: ['SQL Server Agent service', 'Failed / retried steps (last 24 h)', 'Job overview'] },
      { id: 'backups', title: 'Backup Status', description: 'Last full, differential and log backup for every database against RPO thresholds.', category: 'Recovery', icon: 'archive', resultTitles: ['Backups by database'] },
      { id: 'databases', title: 'Database Health', description: 'Database state, size, log usage, log reuse waits and risky settings.', category: 'Databases', icon: 'database', resultTitles: ['Databases'] },
      { id: 'disk', title: 'Disk Space', description: 'Free space on every volume that holds data or log files.', category: 'Storage', icon: 'disk', resultTitles: ['Volumes'] },
      { id: 'blocking', title: 'Blocking & Long Queries', description: 'Head blockers, blocked sessions and requests running longer than 5 minutes.', category: 'Performance', icon: 'lock', resultTitles: ['Head blockers', 'Blocked requests', 'Long-running requests'] },
      { id: 'waits', title: 'Top Wait Stats', description: 'Where the instance spends its time waiting since the last restart.', category: 'Performance', icon: 'activity', resultTitles: ['Top waits'] },
      { id: 'errorlog', title: 'Error Log', description: 'Errors and failures written to the current SQL Server error log in the last 24 h.', category: 'Logs', icon: 'file', resultTitles: ['Error log entries (last 24 h)'] }
    ]
  };

  const VERSIONS = {
    'prod-pub': ['16.0.4135.4', 'RTM', 'CU15', 'Enterprise Edition (64-bit)'],
    'prod-dist': ['15.0.4385.2', 'RTM', 'CU27', 'Standard Edition (64-bit)'],
    'rpt-sub': ['15.0.4385.2', 'RTM', 'CU27', 'Standard Edition (64-bit)'],
    'dr-sql': ['16.0.4135.4', 'RTM', 'CU15', 'Enterprise Edition (64-bit)']
  };
  const NOT_DIST = 'This instance is not a Distributor - agent status and errors are read on the Distributor. Local publisher/subscriber details are shown below.';

  const AGENT_COLS = 'Status|AgentType|AgentState|Publisher|PublisherDB|Publication|Subscriber|SubscriberDB|LatencySec:int|PendingCommands:bigint|LastActivity:datetime|MinutesSinceActivity:int|LastMessage|AgentName|DistributionDB';
  const ERR_COLS = 'Status|ErrorTime:datetime|Source|ErrorCode|ErrorText|DistributionDB';
  const REPDB_COLS = 'Status|DatabaseName|Published:bit|MergePublished:bit|Subscribed:bit|Distributor:bit|LogReuseWait|Note';
  const SUB_COLS = 'Status|SubscriberDB|Publisher|PublisherDB|Publication|SubscriptionType|LastSync:datetime|MinutesSinceSync:int|DistributionAgent';

  const checks = {
    replication(id) {
      if (id === 'prod-dist') {
        return {
          messages: [],
          resultSets: [
            T(AGENT_COLS, [
              ['CRITICAL', 'Distribution', 'Failed', 'PROD-SQL01', 'Finance', 'Finance_Pub', 'BI-SQL01', 'FinanceDW', null, 182334, ago(47), 47, "The process could not connect to Subscriber 'BI-SQL01'. TCP Provider: The wait operation timed out.", 'PROD-SQL01-Finance-Finance_Pub-BI-SQL01-12', 'distribution'],
              ['WARNING', 'Distribution', 'In progress', 'PROD-SQL01', 'Inventory', 'Inventory_Pub', 'RPT-SQL01', 'InventoryRpt', 412, 64210, ago(0), 0, 'Delivering replicated transactions', 'PROD-SQL01-Inventory-Inventory_Pub-RPT-SQL01-9', 'distribution'],
              ['OK', 'Log Reader', 'In progress', 'PROD-SQL01', 'Finance', null, null, null, 2, null, ago(0), 0, '12 transaction(s) with 140 command(s) were delivered.', 'PROD-SQL01-Finance-3', 'distribution'],
              ['OK', 'Log Reader', 'Idle', 'PROD-SQL01', 'Inventory', null, null, null, 1, null, ago(1), 1, 'No replicated transactions are available.', 'PROD-SQL01-Inventory-2', 'distribution'],
              ['OK', 'Log Reader', 'Idle', 'PROD-SQL01', 'Sales', null, null, null, 1, null, ago(0), 0, 'No replicated transactions are available.', 'PROD-SQL01-Sales-1', 'distribution'],
              ['OK', 'Distribution', 'Idle', 'PROD-SQL01', 'Sales', 'Sales_Pub', 'RPT-SQL01', 'SalesRpt', 3, 0, ago(0), 0, 'No replicated transactions are available.', 'PROD-SQL01-Sales-Sales_Pub-RPT-SQL01-7', 'distribution'],
              ['OK', 'Distribution', 'Idle', 'PROD-SQL01', 'Sales', 'Sales_Pub', 'BI-SQL01', 'SalesDW', 4, 0, ago(2), 2, 'No replicated transactions are available.', 'PROD-SQL01-Sales-Sales_Pub-BI-SQL01-8', 'distribution']
            ]),
            T(ERR_COLS, [
              ['CRITICAL', ago(3), 'BI-SQL01', '-2', 'TCP Provider: The wait operation timed out.', 'distribution'],
              ['CRITICAL', ago(18), 'BI-SQL01', '-2', 'Login timeout expired', 'distribution'],
              ['WARNING', ago(312), 'RPT-SQL01', '20598', 'The row was not found at the Subscriber when applying the replicated UPDATE command for Table \'[dbo].[StockLevel]\' with Primary Key(s): [StockId] = 88213', 'distribution']
            ]),
            T(REPDB_COLS, [['OK', 'distribution', false, false, false, true, 'NOTHING', null]]),
            T(SUB_COLS, [])
          ]
        };
      }
      if (id === 'prod-pub') {
        return {
          messages: [NOT_DIST],
          resultSets: [
            T(AGENT_COLS, []), T(ERR_COLS, []),
            T(REPDB_COLS, [
              ['WARNING', 'Finance', true, false, false, false, 'REPLICATION', 'Log cannot be truncated until the Log Reader has processed it'],
              ['OK', 'Inventory', true, false, false, false, 'LOG_BACKUP', null],
              ['OK', 'Sales', true, false, false, false, 'NOTHING', null]
            ]),
            T(SUB_COLS, [])
          ]
        };
      }
      if (id === 'rpt-sub') {
        return {
          messages: [NOT_DIST],
          resultSets: [
            T(AGENT_COLS, []), T(ERR_COLS, []),
            T(REPDB_COLS, [['OK', 'InventoryRpt', false, false, true, false, 'NOTHING', null], ['OK', 'SalesRpt', false, false, true, false, 'NOTHING', null]]),
            T(SUB_COLS, [
              ['INFO', 'InventoryRpt', 'PROD-SQL01', 'Inventory', 'Inventory_Pub', 'Push', ago(7), 7, 'PROD-SQL01-Inventory-Inventory_Pub-RPT-SQL01-9'],
              ['INFO', 'SalesRpt', 'PROD-SQL01', 'Sales', 'Sales_Pub', 'Push', ago(1), 1, 'PROD-SQL01-Sales-Sales_Pub-RPT-SQL01-7']
            ])
          ]
        };
      }
      return { messages: [NOT_DIST], resultSets: [T(AGENT_COLS, []), T(ERR_COLS, []), T(REPDB_COLS, []), T(SUB_COLS, [])] };
    },

    overview(id) {
      const v = VERSIONS[id];
      const busy = id === 'prod-pub';
      return {
        messages: [],
        resultSets: [T('Status|Category|Metric|Value', [
          ['INFO', 'Instance', 'Server name', config.instances.find(i => i.id === id).name],
          ['INFO', 'Instance', 'Version', v[0] + ' ' + v[1] + ' ' + v[2]],
          ['INFO', 'Instance', 'Edition', v[3]],
          ['INFO', 'Instance', 'Always On enabled', id === 'prod-pub' || id === 'dr-sql' ? 'Yes' : 'No'],
          ['OK', 'Instance', 'Uptime', '41 d 6 h 12 m'],
          ['INFO', 'Resources', 'Logical CPUs', busy ? '32' : '16'],
          ['INFO', 'Resources', 'Physical memory', busy ? '256 GB' : '128 GB'],
          [busy ? 'WARNING' : 'OK', 'Load', 'SQL Server CPU %', busy ? '81 %' : '14 %'],
          [busy ? 'WARNING' : 'OK', 'Load', 'Total server CPU %', busy ? '84 %' : '17 %'],
          ['INFO', 'Memory', 'Total / target server memory', busy ? '229376 / 229376 MB' : '114688 / 114688 MB'],
          ['OK', 'Memory', 'Page life expectancy', busy ? '1840 s' : '9211 s'],
          ['OK', 'Memory', 'Memory grants pending', '0'],
          ['INFO', 'Activity', 'User sessions', busy ? '612' : '48'],
          ['INFO', 'Activity', 'Active requests', busy ? '37' : '3'],
          [busy ? 'WARNING' : 'OK', 'Activity', 'Blocked requests', busy ? '4' : '0'],
          ['INFO', 'Configuration', 'max degree of parallelism', '8'],
          ['INFO', 'Configuration', 'cost threshold for parallelism', '50']
        ])]
      };
    },

    ag(id) {
      const cols1 = 'Status|AvailabilityGroup|PrimaryReplica|LocalRole|SyncHealth|Listener|Replicas:int|Databases:int';
      const cols2 = 'Status|AvailabilityGroup|DatabaseName|Replica|Role|AvailabilityMode|SyncState|SyncHealth|Suspended:bit|SuspendReason|LogSendQueueKB:bigint|RedoQueueKB:bigint|EstLagSec:int|LastCommitTime:datetime|Connected';
      if (id !== 'prod-pub' && id !== 'dr-sql') {
        return { messages: ['Always On availability groups are not enabled on this instance.'], resultSets: [T(cols1), T(cols2)] };
      }
      const primary = id === 'prod-pub';
      return {
        messages: [],
        resultSets: [
          T(cols1, [['WARNING', 'AG_Sales', 'PROD-SQL01', primary ? 'PRIMARY' : 'SECONDARY', 'PARTIALLY_HEALTHY', 'sales-ag.corp.local,1433', 2, 3]]),
          T(cols2, [
            ['OK', 'AG_Sales', 'Sales', primary ? 'PROD-SQL01' : 'DR-SQL01', primary ? 'PRIMARY' : 'SECONDARY', primary ? 'SYNCHRONOUS_COMMIT' : 'ASYNCHRONOUS_COMMIT', primary ? 'SYNCHRONIZED' : 'SYNCHRONIZING', 'HEALTHY', false, null, 0, 0, primary ? null : 2, ago(0), 'CONNECTED'],
            ['WARNING', 'AG_Sales', 'Inventory', primary ? 'PROD-SQL01' : 'DR-SQL01', primary ? 'PRIMARY' : 'SECONDARY', primary ? 'SYNCHRONOUS_COMMIT' : 'ASYNCHRONOUS_COMMIT', 'SYNCHRONIZING', 'PARTIALLY_HEALTHY', false, null, 1650221, 230114, primary ? null : 96, ago(2), 'CONNECTED'],
            ['OK', 'AG_Sales', 'Finance', primary ? 'PROD-SQL01' : 'DR-SQL01', primary ? 'PRIMARY' : 'SECONDARY', primary ? 'SYNCHRONOUS_COMMIT' : 'ASYNCHRONOUS_COMMIT', primary ? 'SYNCHRONIZED' : 'SYNCHRONIZING', 'HEALTHY', false, null, 12, 0, primary ? null : 1, ago(0), 'CONNECTED']
          ])
        ]
      };
    },

    jobs(id) {
      const failed = id === 'prod-pub' ? [
        ['CRITICAL', 'DBA - IndexOptimize - USER_DATABASES', 1, 'IndexOptimize', 'Failed', ago(185), 5412, 16, 'Executed as user: CORP\\svc_sqlagent. The transaction log for database \'Sales\' is full due to \'LOG_BACKUP\'. [SQLSTATE 42000] (Error 9002). The step failed.'],
        ['WARNING', 'ETL - Load Inventory Snapshot', 2, 'Load staging', 'Retry', ago(410), 73, 0, 'Executed as user: CORP\\svc_etl. Deadlock victim. Retrying (attempt 1 of 3).']
      ] : [];
      return {
        messages: [],
        resultSets: [
          T('Status|Service|State|StartupType|ServiceAccount|LastStartup:datetime', [['OK', 'SQL Server Agent (MSSQLSERVER)', 'Running', 'Automatic', 'CORP\\svc_sqlagent', ago(59300)]]),
          T('Status|JobName|StepId:int|StepName|Outcome|RunAt:datetime|DurationSec:int|SqlSeverity:int|Message', failed),
          T('Status|JobName|Enabled:bit|Running:bit|RunningMin:int|LastOutcome|LastRun:datetime|NextRun:datetime|Category|Owner', [
            id === 'prod-pub' ? ['CRITICAL', 'DBA - IndexOptimize - USER_DATABASES', true, false, null, 'Failed', ago(185), ago(-1255), 'Database Maintenance', 'sa'] : ['OK', 'DBA - IndexOptimize - USER_DATABASES', true, false, null, 'Succeeded', ago(300), ago(-1140), 'Database Maintenance', 'sa'],
            ['OK', 'DBA - DatabaseBackup - FULL', true, false, null, 'Succeeded', ago(620), ago(820), 'Database Maintenance', 'sa'],
            ['OK', 'DBA - DatabaseBackup - LOG', true, false, null, 'Succeeded', ago(12), ago(-3), 'Database Maintenance', 'sa'],
            id === 'prod-dist' ? ['OK', 'Distribution clean up: distribution', true, true, 4, 'Succeeded', ago(10), null, 'REPL-Distribution Cleanup', 'sa'] : ['OK', 'syspolicy_purge_history', true, false, null, 'Succeeded', ago(700), ago(-740), '[Uncategorized (Local)]', 'sa'],
            ['INFO', 'ETL - Legacy export (retired)', false, false, null, 'Succeeded', ago(90000), null, 'Data Collector', 'CORP\\jdoe']
          ])
        ]
      };
    },

    backups(id) {
      const dbs = {
        'prod-pub': [['Sales', 'FULL'], ['Inventory', 'FULL'], ['Finance', 'FULL'], ['master', 'SIMPLE'], ['msdb', 'SIMPLE'], ['model', 'FULL']],
        'prod-dist': [['distribution', 'SIMPLE'], ['master', 'SIMPLE'], ['msdb', 'SIMPLE']],
        'rpt-sub': [['SalesRpt', 'SIMPLE'], ['InventoryRpt', 'SIMPLE'], ['AdHocAnalysis', 'FULL'], ['master', 'SIMPLE'], ['msdb', 'SIMPLE']],
        'dr-sql': [['master', 'SIMPLE'], ['msdb', 'SIMPLE']]
      }[id];
      const rows = dbs.map(([name, model], i) => {
        if (name === 'AdHocAnalysis') return ['CRITICAL', name, model, null, null, null, null, null];
        if (id === 'prod-pub' && name === 'Inventory') return ['WARNING', name, model, ago(1500 + i), ago(1500), ago(95), 25, 95];
        const logAgo = 8 + i * 3;
        return ['OK', name, model, ago(600 + i * 7), null, model === 'SIMPLE' ? null : ago(logAgo), 10, model === 'SIMPLE' ? null : logAgo];
      });
      return { messages: [], resultSets: [T('Status|DatabaseName|RecoveryModel|LastFull:datetime|LastDiff:datetime|LastLog:datetime|HoursSinceFull:int|MinutesSinceLog:int', rows)] };
    },

    databases(id) {
      const rows = {
        'prod-pub': [
          ['WARNING', 'Sales', 'ONLINE', 'MULTI_USER', 'FULL', 812345.0, 65536.0, 81.4, 'LOG_BACKUP', 160, 'CHECKSUM', null],
          ['OK', 'Finance', 'ONLINE', 'MULTI_USER', 'FULL', 210554.5, 16384.0, 22.9, 'REPLICATION', 160, 'CHECKSUM', null],
          ['OK', 'Inventory', 'ONLINE', 'MULTI_USER', 'FULL', 98304.0, 8192.0, 11.2, 'NOTHING', 150, 'CHECKSUM', null],
          ['OK', 'master', 'ONLINE', 'MULTI_USER', 'SIMPLE', 6.0, 2.0, 31.0, 'NOTHING', 160, 'CHECKSUM', null]
        ],
        'rpt-sub': [
          ['WARNING', 'AdHocAnalysis', 'ONLINE', 'MULTI_USER', 'FULL', 40960.0, 4096.0, 12.0, 'NOTHING', 130, 'TORN_PAGE_DETECTION', 'auto-shrink ON; page verify not CHECKSUM'],
          ['OK', 'SalesRpt', 'ONLINE', 'MULTI_USER', 'SIMPLE', 640000.0, 32768.0, 3.1, 'NOTHING', 150, 'CHECKSUM', null],
          ['OK', 'InventoryRpt', 'ONLINE', 'MULTI_USER', 'SIMPLE', 81920.0, 8192.0, 2.4, 'NOTHING', 150, 'CHECKSUM', null]
        ]
      }[id] || [
        ['OK', 'distribution', 'ONLINE', 'MULTI_USER', 'SIMPLE', 51200.0, 8192.0, 18.6, 'NOTHING', 150, 'CHECKSUM', null],
        ['OK', 'master', 'ONLINE', 'MULTI_USER', 'SIMPLE', 6.0, 2.0, 28.0, 'NOTHING', 150, 'CHECKSUM', null]
      ];
      return { messages: [], resultSets: [T('Status|DatabaseName|State|Access|RecoveryModel|DataMB:decimal|LogMB:decimal|LogUsedPct:decimal|LogReuseWait|Compatibility:tinyint|PageVerify|Notes', rows)] };
    },

    disk(id) {
      const lowL = id === 'prod-dist';
      return {
        messages: [],
        resultSets: [T('Status|Volume|Label|TotalGB:decimal|UsedGB:decimal|FreeGB:decimal|FreePct:decimal|DatabaseFiles:int', [
          lowL ? ['WARNING', 'L:\\', 'SQLLogs', 500.0, 431.2, 68.8, 13.8, 6] : ['OK', 'L:\\', 'SQLLogs', 500.0, 210.4, 289.6, 57.9, 6],
          ['OK', 'D:\\', 'SQLData', 4096.0, 2950.1, 1145.9, 28.0, 14],
          ['OK', 'T:\\', 'TempDB', 200.0, 64.0, 136.0, 68.0, 9]
        ])]
      };
    },

    blocking(id) {
      const hb = 'Status|HeadBlocker:smallint|BlockedCount:int|MaxWaitSec:int|LoginName|HostName|ProgramName|SessionStatus|OpenTran:int|LastRequest:datetime|LastSql';
      const br = 'Status|SessionId:smallint|BlockedBy:smallint|WaitType|WaitSec:int|WaitResource|DatabaseName|LoginName|HostName|Command|SqlText';
      const lr = 'Status|SessionId:smallint|ElapsedSec:int|CpuSec:int|LogicalReads:bigint|RequestStatus|Command|WaitType|DatabaseName|LoginName|HostName|ProgramName|Statement';
      if (id !== 'prod-pub') return { messages: [], resultSets: [T(hb), T(br), T(lr)] };
      return {
        messages: [],
        resultSets: [
          T(hb, [['WARNING', 187, 4, 96, 'CORP\\svc_erp', 'APP-ERP02', 'ERP Batch Posting', 'sleeping', 1, ago(3), 'BEGIN TRAN;\nUPDATE dbo.StockLevel SET Qty = Qty - @q WHERE StockId = @id;\n-- waiting for client to commit']]),
          T(br, [
            ['WARNING', 233, 187, 'LCK_M_U', 96, 'KEY: 7:72057594045923328 (8194443284a0)', 'Inventory', 'CORP\\svc_web', 'WEB-01', 'UPDATE', 'UPDATE dbo.StockLevel SET Reserved = Reserved + 1 WHERE StockId = @id'],
            ['WARNING', 245, 187, 'LCK_M_S', 61, 'KEY: 7:72057594045923328 (8194443284a0)', 'Inventory', 'CORP\\svc_web', 'WEB-02', 'SELECT', 'SELECT Qty, Reserved FROM dbo.StockLevel WHERE StockId = @id'],
            ['INFO', 251, 233, 'LCK_M_U', 12, 'KEY: 7:72057594045923328 (8194443284a0)', 'Inventory', 'CORP\\svc_web', 'WEB-01', 'UPDATE', 'UPDATE dbo.StockLevel SET Reserved = Reserved + 1 WHERE StockId = @id']
          ]),
          T(lr, [['WARNING', 312, 1420, 1310, 98234112, 'running', 'SELECT', 'CXPACKET', 'Sales', 'CORP\\analyst1', 'BI-WS-17', 'Microsoft SQL Server Management Studio - Query', 'SELECT c.Region, SUM(o.Total) FROM dbo.Orders o JOIN dbo.Customers c ON c.Id = o.CustomerId GROUP BY c.Region']])
        ]
      };
    },

    waits(id) {
      const busy = id === 'prod-pub';
      return {
        messages: [],
        resultSets: [T('WaitType|WaitPct:decimal|WaitSec:decimal|WaitingTasks:bigint|AvgWaitMs:decimal|SignalPct:decimal|Hint', [
          busy ? ['CXPACKET', 31.2, 912334, 88123441, 10.4, 4.1, 'Parallelism - review MAXDOP / cost threshold'] : ['WRITELOG', 28.5, 51233, 9123344, 5.6, 1.2, 'Transaction log writes - log disk latency'],
          ['PAGEIOLATCH_SH', 22.4, busy ? 655210 : 40211, 7712334, 8.5, 0.6, 'Reading data pages from disk - memory pressure or slow storage'],
          busy ? ['LCK_M_U', 12.1, 353812, 120334, 2940.3, 0.1, 'Lock waits - blocking'] : ['ASYNC_NETWORK_IO', 14.2, 25511, 1203344, 21.2, 0.4, 'Client consuming results slowly'],
          ['SOS_SCHEDULER_YIELD', 9.8, busy ? 286640 : 17605, 99812334, 2.9, 99.1, 'CPU pressure'],
          ['WRITELOG', 7.3, busy ? 213510 : 13110, 41233412, 5.2, 1.8, 'Transaction log writes - log disk latency'],
          ['HADR_SYNC_COMMIT', 4.4, 128690, 40123344, 3.2, 0.9, 'Synchronous AG commit latency'],
          ['OLEDB', 2.1, 61420, 912334, 67.3, 0.0, null]
        ])]
      };
    },

    errorlog(id) {
      const rows = id === 'prod-dist' ? [
        ['WARNING', ago(4), 'Logon', "Login failed for user 'CORP\\svc_bi'. Reason: Could not find a login matching the name provided. [CLIENT: 10.20.4.17]"],
        ['WARNING', ago(4), 'Logon', 'Error: 18456, Severity: 14, State: 5.'],
        ['CRITICAL', ago(220), 'spid84', 'Error: 1105, Severity: 17, State: 2. Could not allocate space for object \'dbo.MSrepl_commands\' in database \'distribution\' because the \'PRIMARY\' filegroup is full.']
      ] : id === 'prod-pub' ? [
        ['CRITICAL', ago(185), 'spid112', 'Error: 9002, Severity: 17, State: 2. The transaction log for database \'Sales\' is full due to \'LOG_BACKUP\'.']
      ] : [];
      return { messages: [], resultSets: [T('Status|LogDate:datetime|Source|Message', rows)] };
    }
  };

  function delay(ms) { return new Promise(r => setTimeout(r, ms)); }

  async function handle(path, body) {
    await delay(150 + Math.random() * 250);
    if (path === '/api/config') return JSON.parse(JSON.stringify(config));
    if (path !== '/api/run') throw new Error('Unknown endpoint');

    const id = body.instanceId;
    const t = 250 + Math.random() * 1100;
    if (id === 'dev-sql') {
      await delay(1500);
      return {
        instanceId: id, checkId: body.checkId, ok: false, durationMs: 8012, resultSets: [], messages: [],
        error: 'A network-related or instance-specific error occurred while establishing a connection to SQL Server. The server was not found or was not accessible. Verify that the instance name is correct and that SQL Server is configured to allow remote connections. (provider: TCP Provider, error: 0 - The wait operation timed out.)'
      };
    }
    await delay(t);
    if (body.checkId === '__ping') {
      const v = VERSIONS[id];
      return {
        instanceId: id, checkId: '__ping', ok: true, durationMs: Math.round(t / 20) + 3, messages: [],
        resultSets: [T('ServerName|ProductVersion|ProductLevel|UpdateLevel|Edition|IsHadrEnabled:int|LoginName', [[id.toUpperCase(), v[0], v[1], v[2], v[3], 0, 'CORP\\dba.user']])]
      };
    }
    const r = checks[body.checkId](id);
    return { instanceId: id, checkId: body.checkId, ok: true, durationMs: Math.round(t), error: null, messages: r.messages, resultSets: r.resultSets };
  }

  window.SqlDashDemo = { handle: handle };
})();
