<#
.SYNOPSIS
    SQL Server Health Dashboard

.DESCRIPTION
    Runs the read-only health checks in queries.sql against the SQL Servers
    listed in the CONFIGURATION section, saves the results next to
    dashboard.html (as dashboard-data.js) and opens the dashboard in the
    browser.

    Uses only Windows PowerShell 5.1 and the .NET Framework that ship with
    Windows. Nothing is installed, no web server is started and no network
    port is opened.

.NOTES
    How to run:
      1. Edit the CONFIGURATION section below.
      2. Open Windows PowerShell in this folder and run:
           powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-Dashboard.ps1
      3. The dashboard opens in Edge/Chrome. Run the script again to refresh,
         or set $RefreshMinutes so it keeps collecting while the window is open.

    Files:
      Start-Dashboard.ps1   this script
      queries.sql           the health-check queries
      dashboard.html        the dashboard (HTML, CSS and JavaScript)
      dashboard-data.js     created by this script - the collected results
#>
[CmdletBinding()]
param(
    [switch]$NoBrowser
)

# =============================== CONFIGURATION ===============================
# Name   : label shown in the dashboard
# Server : what you type in SSMS "Server name" - host, host\instance or host,port
# Group, Role : optional labels for the server list
# Auth   : 'Windows' (default - your Windows login, like SSMS) or 'SQL'
#          (with UserName; the password is asked once when the script starts)
$Servers = @(
    @{ Name = 'PROD-SQL01';      Server = 'PROD-SQL01.corp.local'; Group = 'Production'; Role = 'Publisher' }
    @{ Name = 'PROD-SQL02\DIST'; Server = 'PROD-SQL02\DIST';       Group = 'Production'; Role = 'Distributor' }
    @{ Name = 'RPT-SQL01';       Server = 'RPT-SQL01,1433';        Group = 'Reporting';  Role = 'Subscriber'; Auth = 'SQL'; UserName = 'monitor_ro' }
)

$Title                  = 'SQL Server Health'
$Environment            = 'PRODUCTION'   # badge next to the title; '' to hide
$RefreshMinutes         = 0              # 0 = collect once; e.g. 5 = collect again every 5 minutes
$ConnectTimeoutSeconds  = 8
$QueryTimeoutSeconds    = 60             # per check; a check can override it with timeout= in queries.sql
$MaxRowsPerResult       = 5000
$EncryptConnection      = $false
$TrustServerCertificate = $true
$ParallelServers        = 8              # servers queried at the same time
# =============================================================================

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$QueriesPath = Join-Path $Root 'queries.sql'
$HtmlPath = Join-Path $Root 'dashboard.html'
$DataPath = Join-Path $Root 'dashboard-data.js'

Add-Type -AssemblyName System.Data
# JavaScriptSerializer ships with .NET Framework 3.5+; fall back to ConvertTo-Json elsewhere.
$useJss = $true
try { Add-Type -AssemblyName System.Web.Extensions } catch { $useJss = $false }

function Write-Status([string]$Message, [string]$Color = 'Gray') {
    Write-Host ('{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor $Color
}

foreach ($p in @($QueriesPath, $HtmlPath)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing file: $p (keep all files in the same folder)" }
}

# ---- Read the checks from queries.sql -------------------------------------------
$checks = New-Object System.Collections.Generic.List[object]
$current = $null
foreach ($line in [IO.File]::ReadAllLines($QueriesPath)) {
    $m = [regex]::Match($line, '^\s*--\s*@check\s+([\w-]+)(?:\s+timeout=(\d+))?')
    if ($m.Success) {
        $current = @{ Id = $m.Groups[1].Value; Timeout = $QueryTimeoutSeconds; Lines = New-Object System.Collections.Generic.List[string] }
        if ($m.Groups[2].Success) { $current.Timeout = [int]$m.Groups[2].Value }
        $checks.Add($current)
    }
    elseif ($current) { $current.Lines.Add($line) }
}
foreach ($c in $checks) {
    # GO separates batches, like in SSMS
    $c.Batches = @([regex]::Split(($c.Lines -join "`r`n"), '(?im)^\s*GO\s*(?:--.*)?$') | Where-Object { $_.Trim() })
    $c.Remove('Lines')
}
if ($checks.Count -eq 0) { throw 'No "-- @check" sections found in queries.sql.' }

# ---- Connection details ------------------------------------------------------------
$serverList = New-Object System.Collections.Generic.List[object]
$credentials = @{}
$usedIds = @{}
foreach ($s in $Servers) {
    if (-not $s.Server) { throw 'Every server needs a Server value.' }
    $name = if ($s.Name) { [string]$s.Name } else { [string]$s.Server }
    $id = ($name -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant()
    if (-not $id) { $id = 'server' }
    $n = 2; $base = $id
    while ($usedIds.ContainsKey($id)) { $id = "$base-$n"; $n++ }
    $usedIds[$id] = $true

    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = [string]$s.Server
    $b['Initial Catalog'] = 'master'
    $b['Application Name'] = 'SQL Health Dashboard'
    $b['Connect Timeout'] = $ConnectTimeoutSeconds
    $b['Encrypt'] = $EncryptConnection
    $b['TrustServerCertificate'] = $TrustServerCertificate

    $credential = $null
    if ([string]$s.Auth -eq 'SQL') {
        $user = [string]$s.UserName
        if (-not $credentials.ContainsKey($user)) {
            $psCred = Get-Credential -UserName $user -Message "SQL Server login for $name"
            if (-not $psCred) { throw "No password entered for $name." }
            $password = $psCred.Password.Copy()
            $password.MakeReadOnly()
            $credentials[$user] = New-Object System.Data.SqlClient.SqlCredential($psCred.UserName.TrimStart('\'), $password)
        }
        $credential = $credentials[$user]
    }
    else {
        $b['Integrated Security'] = $true
    }

    $serverList.Add(@{
        Id = $id; Name = $name; Server = [string]$s.Server; Group = [string]$s.Group; Role = [string]$s.Role
        ConnectionString = $b.ConnectionString; Credential = $credential
    })
}

# ---- Runs every check on one server (in its own runspace) --------------------------
$worker = {
    param($Srv, $Checks, $MaxRows, $Results)

    $out = @{ ok = $true; error = $null; latencyMs = $null; checks = @{} }
    foreach ($c in $Checks) {
        $res = @{
            ok = $true; error = $null; durationMs = 0
            resultSets = New-Object System.Collections.Generic.List[object]
            messages   = New-Object System.Collections.Generic.List[string]
        }
        $messages = $res.messages
        $sw = [Diagnostics.Stopwatch]::StartNew()
        # A new (pooled) connection per check, so temp tables never collide between checks.
        $conn = New-Object System.Data.SqlClient.SqlConnection($Srv.ConnectionString)
        if ($Srv.Credential) { $conn.Credential = $Srv.Credential }
        $conn.add_InfoMessage({
            param($sender, $e)
            # 8153 = "Null value is eliminated by an aggregate" - harmless noise
            foreach ($m in $e.Errors) { if ($m.Number -ne 8153) { [void]$messages.Add($m.Message) } }
        }.GetNewClosure())
        try {
            $conn.Open()
            if ($null -eq $out.latencyMs) { $out.latencyMs = [int]$sw.ElapsedMilliseconds }
            foreach ($batch in $c.Batches) {
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = $batch
                $cmd.CommandTimeout = $c.Timeout
                $reader = $cmd.ExecuteReader()
                try {
                    do {
                        if ($reader.FieldCount -gt 0) {
                            $columns = New-Object System.Collections.Generic.List[object]
                            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                                $columns.Add(@{ name = $reader.GetName($i); type = $reader.GetDataTypeName($i) })
                            }
                            $rows = New-Object System.Collections.Generic.List[object]
                            $truncated = $false
                            while ($reader.Read()) {
                                if ($rows.Count -ge $MaxRows) { $truncated = $true; continue }
                                $row = New-Object object[] $reader.FieldCount
                                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                                    # Assign directly (no helper function) so values are never
                                    # PSObject-wrapped, which would break JSON serialization.
                                    try { $v = $reader.GetValue($i) } catch { $row[$i] = '<unsupported type>'; continue }
                                    if ($v -is [System.DBNull]) { $row[$i] = $null }
                                    elseif ($v -is [string] -or $v -is [bool] -or $v -is [int] -or $v -is [long] -or
                                            $v -is [int16] -or $v -is [byte] -or $v -is [decimal]) { $row[$i] = $v }
                                    elseif ($v -is [double] -or $v -is [single]) {
                                        if ([double]::IsNaN($v) -or [double]::IsInfinity($v)) { $row[$i] = [string]$v } else { $row[$i] = $v }
                                    }
                                    elseif ($v -is [datetime]) { $row[$i] = $v.ToString('yyyy-MM-dd HH:mm:ss') }
                                    elseif ($v -is [datetimeoffset]) { $row[$i] = $v.ToString('yyyy-MM-dd HH:mm:ss zzz') }
                                    elseif ($v -is [byte[]]) {
                                        $hex = '0x' + ([BitConverter]::ToString($v, 0, [Math]::Min($v.Length, 64)) -replace '-', '')
                                        if ($v.Length -gt 64) { $hex += '...' }
                                        $row[$i] = $hex
                                    }
                                    else { $row[$i] = [string]$v }
                                }
                                $rows.Add($row)
                            }
                            $res.resultSets.Add(@{ columns = $columns; rows = $rows; truncated = $truncated })
                        }
                    } while ($reader.NextResult())
                }
                finally { $reader.Dispose(); $cmd.Dispose() }
            }
        }
        catch {
            $ex = $_.Exception
            while ($ex.InnerException) { $ex = $ex.InnerException }
            $res.ok = $false
            $res.error = [string]$ex.Message
            if ($conn.State -ne [System.Data.ConnectionState]::Open) {
                # Could not connect - no point trying the remaining checks.
                $out.ok = $false
                $out.error = [string]$ex.Message
            }
        }
        finally { $conn.Dispose() }
        $res.durationMs = [int]$sw.ElapsedMilliseconds
        $out.checks[$c.Id] = $res
        if (-not $out.ok) { break }
    }
    $Results[$Srv.Id] = $out
}

function ConvertTo-JsonText($Object) {
    if (-not $useJss) { return (ConvertTo-Json -InputObject $Object -Depth 20 -Compress) }
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    $ser.RecursionLimit = 64
    return $ser.Serialize($Object)
}

function Invoke-Collection {
    $started = Get-Date
    Write-Status ("Checking {0} server(s)..." -f $serverList.Count) 'Cyan'

    $results = [hashtable]::Synchronized(@{})
    $pool = [RunspaceFactory]::CreateRunspacePool(1, [Math]::Max(1, $ParallelServers))
    $pool.Open()
    $jobs = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($s in $serverList) {
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($worker).AddArgument($s).AddArgument($checks).AddArgument($MaxRowsPerResult).AddArgument($results)
            $jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); Server = $s })
        }
        while (@($jobs | Where-Object { -not $_.Handle.IsCompleted }).Count -gt 0) {
            $done = @($jobs | Where-Object { $_.Handle.IsCompleted }).Count
            Write-Progress -Activity 'Collecting SQL Server health data' -Status "$done of $($jobs.Count) servers done" -PercentComplete (100 * $done / $jobs.Count)
            Start-Sleep -Milliseconds 250
        }
        Write-Progress -Activity 'Collecting SQL Server health data' -Completed
        foreach ($j in $jobs) {
            try { [void]$j.PS.EndInvoke($j.Handle) } catch { }
            foreach ($err in $j.PS.Streams.Error) { Write-Status ("{0}: {1}" -f $j.Server.Name, $err) 'Red' }
            $j.PS.Dispose()
        }
    }
    finally { $pool.Close(); $pool.Dispose() }

    $who = try { [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { [Environment]::UserName }
    $serversOut = New-Object System.Collections.Generic.List[object]
    foreach ($s in $serverList) {
        $r = $results[$s.Id]
        if (-not $r) { $r = @{ ok = $false; error = 'Collection did not finish for this server.'; latencyMs = $null; checks = @{} } }
        $failed = @($r.checks.Values | Where-Object { -not $_.ok }).Count
        if (-not $r.ok) { Write-Status ("{0,-28} UNREACHABLE  {1}" -f $s.Name, $r.error) 'Red' }
        elseif ($failed) { Write-Status ("{0,-28} OK ({1} check(s) failed - see dashboard)" -f $s.Name, $failed) 'Yellow' }
        else { Write-Status ("{0,-28} OK" -f $s.Name) 'Green' }
        $serversOut.Add(@{
            id = $s.Id; name = $s.Name; server = $s.Server; group = $s.Group; role = $s.Role
            ok = [bool]$r.ok; error = $r.error; latencyMs = $r.latencyMs; checks = $r.checks
        })
    }

    $data = @{
        title          = $Title
        environment    = $Environment
        generatedAt    = $started.ToString('yyyy-MM-dd HH:mm:ss')
        generatedBy    = [string]$who
        refreshMinutes = $RefreshMinutes
        servers        = $serversOut
    }
    $text = 'window.DASHBOARD_DATA = ' + (ConvertTo-JsonText $data) + ';'
    $tmp = $DataPath + '.tmp'
    [IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $DataPath -Force
    Write-Status ("Saved results ({0:N1} s)" -f ((Get-Date) - $started).TotalSeconds) 'Cyan'
}

function Open-Dashboard {
    $uri = ([Uri]$HtmlPath).AbsoluteUri
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')
    )
    $browser = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    try {
        if ($browser) { Start-Process -FilePath $browser -ArgumentList "--app=$uri" }
        else { Start-Process $HtmlPath }
    }
    catch { Write-Status "Open this file in Edge or Chrome: $HtmlPath" 'Yellow' }
}

# ---- Run ---------------------------------------------------------------------------------
Invoke-Collection
if (-not $NoBrowser) { Open-Dashboard }

if ($RefreshMinutes -gt 0) {
    Write-Status "Collecting again every $RefreshMinutes minute(s) - keep this window open, press Ctrl+C to stop." 'Cyan'
    while ($true) {
        Start-Sleep -Seconds ($RefreshMinutes * 60)
        Invoke-Collection
    }
}
else {
    Write-Status 'Done. Run this script again to refresh the dashboard.' 'Cyan'
}
