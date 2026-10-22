<#
.SYNOPSIS
    SQL Server Health Dashboard - local web server.

.DESCRIPTION
    Serves the dashboard UI from .\web and runs the read-only health-check
    queries in .\checks against the instances configured in config.json.

    Uses only what ships with Windows: Windows PowerShell 5.1 and the .NET
    Framework (System.Data.SqlClient). Nothing has to be installed.

    Security model
      * Listens on 127.0.0.1 only - never reachable from the network.
      * Every API call must carry a random per-session token that is handed
        to the browser at launch (other users on a shared jump server cannot
        call the API).
      * Host / Origin headers are validated (blocks DNS-rebinding and CSRF).
      * The browser can only pick an instance id and a check id from the
        config - it can never send SQL text.
      * SQL logins (if any) are prompted for at start-up and kept in memory
        as SecureString; nothing is written to disk.

.PARAMETER ConfigPath
    Path to the JSON configuration file. Defaults to .\config.json.

.PARAMETER Port
    Overrides server.port from the config file.

.PARAMETER NoBrowser
    Do not open a browser window automatically.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\server.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [int]$Port = 0,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Version = '1.0.0'

Add-Type -AssemblyName System.Data
# JavaScriptSerializer ships with .NET Framework 3.5+; fall back to ConvertTo-Json elsewhere.
$useJss = $true
try { Add-Type -AssemblyName System.Web.Extensions } catch { $useJss = $false }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-Opt {
    # Reads an optional property from a ConvertFrom-Json object.
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) {
        return $Object.$Name
    }
    return $Default
}

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line -ForegroundColor $Color
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
}

function New-SessionToken {
    $bytes = New-Object byte[] 32
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Find-Browser {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}
$config = (Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8) | ConvertFrom-Json

$serverCfg = Get-Opt $config 'server'
$connCfg = Get-Opt $config 'connection'

if ($Port -le 0) { $Port = [int](Get-Opt $serverCfg 'port' 8765) }
$maxConcurrent = [int](Get-Opt $serverCfg 'maxConcurrentRequests' 12)
$openBrowser = [bool](Get-Opt $serverCfg 'openBrowser' $true) -and -not $NoBrowser
$appMode = [bool](Get-Opt $serverCfg 'browserAppMode' $true)

if ([bool](Get-Opt $serverCfg 'logToFile' $true)) {
    $logDir = Join-Path $Root 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    $script:LogFile = Join-Path $logDir ('dashboard-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
}

$connectTimeout = [int](Get-Opt $connCfg 'connectTimeoutSeconds' 8)
$appName = [string](Get-Opt $connCfg 'applicationName' 'SQL Health Dashboard')
$defaultEncrypt = [bool](Get-Opt $connCfg 'encrypt' $false)
$defaultTrust = [bool](Get-Opt $connCfg 'trustServerCertificate' $true)

# --- Instances --------------------------------------------------------------
$instances = @{}
$instanceOrder = New-Object System.Collections.Generic.List[string]
$credentialCache = @{}

foreach ($i in @($config.instances)) {
    $id = [string](Get-Opt $i 'id')
    $serverName = [string](Get-Opt $i 'server')
    if (-not $id -or -not $serverName) { throw "Every instance needs an 'id' and a 'server'." }
    if ($instances.ContainsKey($id)) { throw "Duplicate instance id '$id'." }

    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $serverName
    $b['Initial Catalog'] = [string](Get-Opt $i 'database' 'master')
    $b['Application Name'] = $appName
    $b['Connect Timeout'] = [int](Get-Opt $i 'connectTimeoutSeconds' $connectTimeout)
    $b['Encrypt'] = [bool](Get-Opt $i 'encrypt' $defaultEncrypt)
    $b['TrustServerCertificate'] = [bool](Get-Opt $i 'trustServerCertificate' $defaultTrust)
    if ([bool](Get-Opt $i 'multiSubnetFailover' $false)) { $b['MultiSubnetFailover'] = $true }

    $auth = ([string](Get-Opt $i 'auth' 'windows')).ToLowerInvariant()
    $credential = $null
    if ($auth -eq 'sql') {
        $user = [string](Get-Opt $i 'username' '')
        $key = [string](Get-Opt $i 'credentialKey' $user)
        if (-not $credentialCache.ContainsKey($key)) {
            Write-Host ''
            Write-Host "SQL login required for '$id' ($serverName)" -ForegroundColor Cyan
            $psCred = Get-Credential -UserName $user -Message "SQL Server login for $serverName (credential set '$key')"
            if (-not $psCred) { throw "No credential entered for '$id'." }
            $securePassword = $psCred.Password.Copy()
            $securePassword.MakeReadOnly()
            $credentialCache[$key] = New-Object System.Data.SqlClient.SqlCredential($psCred.UserName.TrimStart('\'), $securePassword)
        }
        $credential = $credentialCache[$key]
    }
    else {
        $b['Integrated Security'] = $true
    }

    $instances[$id] = @{
        Id               = $id
        Name             = [string](Get-Opt $i 'name' $id)
        Server           = $serverName
        Group            = [string](Get-Opt $i 'group' 'Instances')
        Role             = [string](Get-Opt $i 'role' '')
        Description      = [string](Get-Opt $i 'description' '')
        Auth             = $auth
        ConnectionString = $b.ConnectionString
        Credential       = $credential
    }
    $instanceOrder.Add($id)
}
if ($instances.Count -eq 0) { throw 'No instances configured in config.json.' }

# --- Checks -----------------------------------------------------------------
$checks = @{}
$checkOrder = New-Object System.Collections.Generic.List[string]
$defaultCommandTimeout = [int](Get-Opt $connCfg 'commandTimeoutSeconds' 60)
$maxRows = [int](Get-Opt $connCfg 'maxRowsPerResultSet' 5000)

foreach ($c in @($config.checks)) {
    $id = [string](Get-Opt $c 'id')
    $file = [string](Get-Opt $c 'file')
    if (-not $id -or -not $file) { throw "Every check needs an 'id' and a 'file'." }
    if ([bool](Get-Opt $c 'enabled' $true) -eq $false) { continue }
    $path = [IO.Path]::GetFullPath((Join-Path $Root $file))
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Log "Check '$id' skipped - SQL file not found: $path" 'Yellow'
        continue
    }
    $checks[$id] = @{
        Id             = $id
        Title          = [string](Get-Opt $c 'title' $id)
        Description    = [string](Get-Opt $c 'description' '')
        Category       = [string](Get-Opt $c 'category' 'General')
        Icon           = [string](Get-Opt $c 'icon' 'database')
        Featured       = [bool](Get-Opt $c 'featured' $false)
        ResultTitles   = @(Get-Opt $c 'resultTitles' @())
        Path           = $path
        CommandTimeout = [int](Get-Opt $c 'commandTimeoutSeconds' $defaultCommandTimeout)
    }
    $checkOrder.Add($id)
}

# --- Public (browser-safe) view of the configuration ------------------------
$publicInstances = New-Object System.Collections.Generic.List[object]
foreach ($id in $instanceOrder) {
    $x = $instances[$id]
    $publicInstances.Add(@{ id = $x.Id; name = $x.Name; server = $x.Server; group = $x.Group; role = $x.Role; description = $x.Description; auth = $x.Auth })
}
$publicChecks = New-Object System.Collections.Generic.List[object]
foreach ($id in $checkOrder) {
    $x = $checks[$id]
    $titles = New-Object System.Collections.Generic.List[string]
    foreach ($t in $x.ResultTitles) { $titles.Add([string]$t) }
    $publicChecks.Add(@{ id = $x.Id; title = $x.Title; description = $x.Description; category = $x.Category; icon = $x.Icon; featured = $x.Featured; resultTitles = $titles })
}
$publicConfig = @{
    title       = [string](Get-Opt $config 'title' 'SQL Server Health Dashboard')
    environment = [string](Get-Opt $config 'environment' '')
    version     = $Version
    instances   = $publicInstances
    checks      = $publicChecks
    ui          = @{
        concurrency         = [int](Get-Opt (Get-Opt $config 'ui') 'concurrency' 6)
        pingOnLoad          = [bool](Get-Opt (Get-Opt $config 'ui') 'pingOnLoad' $true)
        defaultAutoRefresh  = [int](Get-Opt (Get-Opt $config 'ui') 'defaultAutoRefreshMinutes' 0)
    }
}

# ---------------------------------------------------------------------------
# Request handler - runs on a runspace-pool thread, one call per connection.
# ---------------------------------------------------------------------------
$handler = {
    param($Client, $Ctx)
    $ErrorActionPreference = 'Stop'

    $csp = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; font-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"

    function ConvertTo-JsonText($Object) {
        if (-not $Ctx.UseJss) { return (ConvertTo-Json -InputObject $Object -Depth 20 -Compress) }
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = [int]::MaxValue
        $ser.RecursionLimit = 64
        return $ser.Serialize($Object)
    }

    function Send-Response($Stream, [int]$Code, [string]$ContentType, [byte[]]$Body) {
        $reason = switch ($Code) {
            200 { 'OK' } 400 { 'Bad Request' } 401 { 'Unauthorized' } 403 { 'Forbidden' }
            404 { 'Not Found' } 405 { 'Method Not Allowed' } 413 { 'Payload Too Large' }
            default { 'Internal Server Error' }
        }
        if ($null -eq $Body) { $Body = [byte[]]@() }
        $head = "HTTP/1.1 $Code $reason`r`n" +
                "Content-Type: $ContentType`r`n" +
                "Content-Length: $($Body.Length)`r`n" +
                "Connection: close`r`n" +
                "Cache-Control: no-store`r`n" +
                "X-Content-Type-Options: nosniff`r`n" +
                "X-Frame-Options: DENY`r`n" +
                "Referrer-Policy: no-referrer`r`n" +
                "Content-Security-Policy: $csp`r`n`r`n"
        $hb = [Text.Encoding]::ASCII.GetBytes($head)
        $Stream.Write($hb, 0, $hb.Length)
        if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
        $Stream.Flush()
    }

    function Send-Json($Stream, [int]$Code, $Object) {
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-JsonText $Object))
        Send-Response $Stream $Code 'application/json; charset=utf-8' $bytes
    }

    function Read-Request($Stream) {
        $buffer = New-Object byte[] 16384
        $ms = New-Object System.IO.MemoryStream
        $headerEnd = -1
        while ($headerEnd -lt 0) {
            $n = $Stream.Read($buffer, 0, $buffer.Length)
            if ($n -le 0) { return $null }
            $ms.Write($buffer, 0, $n)
            if ($ms.Length -gt 65536) { throw 'Request headers too large.' }
            $headerEnd = [Text.Encoding]::ASCII.GetString($ms.ToArray()).IndexOf("`r`n`r`n")
        }
        $all = $ms.ToArray()
        $lines = [Text.Encoding]::ASCII.GetString($all, 0, $headerEnd) -split "`r`n"
        $parts = $lines[0] -split ' '
        if ($parts.Count -lt 3) { throw 'Malformed request line.' }

        $headers = @{}
        for ($k = 1; $k -lt $lines.Count; $k++) {
            $idx = $lines[$k].IndexOf(':')
            if ($idx -gt 0) { $headers[$lines[$k].Substring(0, $idx).Trim()] = $lines[$k].Substring($idx + 1).Trim() }
        }

        $length = 0
        if ($headers['Content-Length']) { $length = [int]$headers['Content-Length'] }
        if ($length -gt 1048576) { throw 'Request body too large.' }
        $bodyStart = $headerEnd + 4
        $body = New-Object System.IO.MemoryStream
        if ($all.Length -gt $bodyStart) { $body.Write($all, $bodyStart, $all.Length - $bodyStart) }
        while ($body.Length -lt $length) {
            $n = $Stream.Read($buffer, 0, $buffer.Length)
            if ($n -le 0) { break }
            $body.Write($buffer, 0, $n)
        }

        $target = $parts[1]
        $q = $target.IndexOf('?')
        $path = if ($q -ge 0) { $target.Substring(0, $q) } else { $target }
        return @{
            Method  = $parts[0].ToUpperInvariant()
            Path    = [Uri]::UnescapeDataString($path)
            Headers = $headers
            Body    = [Text.Encoding]::UTF8.GetString($body.ToArray())
        }
    }

    function Get-InnerMessage($Exception) {
        $e = $Exception
        while ($e.InnerException) { $e = $e.InnerException }
        return $e.Message
    }

    function Invoke-Sql($Instance, [string]$Sql, [int]$Timeout, [int]$MaxRows) {
        # Split on GO batch separators so check files can use them like in SSMS.
        $batches = [regex]::Split($Sql, '(?im)^\s*GO\s*(?:--.*)?$') | Where-Object { $_.Trim() }

        $messages = New-Object System.Collections.Generic.List[string]
        $sets = New-Object System.Collections.Generic.List[object]
        $conn = New-Object System.Data.SqlClient.SqlConnection($Instance.ConnectionString)
        if ($Instance.Credential) { $conn.Credential = $Instance.Credential }
        $conn.add_InfoMessage({
            param($sender, $e)
            # 8153 = "Null value is eliminated by an aggregate" - harmless noise
            foreach ($err in $e.Errors) { if ($err.Number -ne 8153) { [void]$messages.Add($err.Message) } }
        }.GetNewClosure())

        try {
            $conn.Open()
            foreach ($batch in $batches) {
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = $batch
                $cmd.CommandTimeout = $Timeout
                $reader = $cmd.ExecuteReader()
                try {
                    do {
                        if ($reader.FieldCount -gt 0) {
                            $columns = New-Object System.Collections.Generic.List[object]
                            for ($c = 0; $c -lt $reader.FieldCount; $c++) {
                                $columns.Add(@{ name = $reader.GetName($c); type = $reader.GetDataTypeName($c) })
                            }
                            $rows = New-Object System.Collections.Generic.List[object]
                            $truncated = $false
                            while ($reader.Read()) {
                                if ($rows.Count -ge $MaxRows) { $truncated = $true; continue }
                                $row = New-Object object[] $reader.FieldCount
                                for ($c = 0; $c -lt $reader.FieldCount; $c++) {
                                    # Assign directly (no helper function) so values are never
                                    # PSObject-wrapped, which would break JSON serialization.
                                    try { $v = $reader.GetValue($c) } catch { $row[$c] = '<unsupported type>'; continue }
                                    if ($v -is [System.DBNull]) { $row[$c] = $null }
                                    elseif ($v -is [string] -or $v -is [bool] -or $v -is [int] -or $v -is [long] -or
                                            $v -is [int16] -or $v -is [byte] -or $v -is [decimal]) { $row[$c] = $v }
                                    elseif ($v -is [double] -or $v -is [single]) {
                                        if ([double]::IsNaN($v) -or [double]::IsInfinity($v)) { $row[$c] = [string]$v } else { $row[$c] = $v }
                                    }
                                    elseif ($v -is [datetime]) { $row[$c] = $v.ToString('yyyy-MM-dd HH:mm:ss') }
                                    elseif ($v -is [datetimeoffset]) { $row[$c] = $v.ToString('yyyy-MM-dd HH:mm:ss zzz') }
                                    elseif ($v -is [byte[]]) {
                                        $hex = '0x' + ([BitConverter]::ToString($v, 0, [Math]::Min($v.Length, 64)) -replace '-', '')
                                        if ($v.Length -gt 64) { $hex += '...' }
                                        $row[$c] = $hex
                                    }
                                    else { $row[$c] = [string]$v }
                                }
                                $rows.Add($row)
                            }
                            $sets.Add(@{ columns = $columns; rows = $rows; truncated = $truncated })
                        }
                    } while ($reader.NextResult())
                }
                finally { $reader.Dispose(); $cmd.Dispose() }
            }
        }
        finally { $conn.Dispose() }

        return @{ resultSets = $sets; messages = $messages }
    }

    $stream = $null
    try {
        $Client.ReceiveTimeout = 15000
        $Client.SendTimeout = 30000
        $stream = $Client.GetStream()
        $req = Read-Request $stream
        if ($null -eq $req) { return }

        $port = $Ctx.Port
        $allowedHosts = @("127.0.0.1:$port", "localhost:$port")
        if ($allowedHosts -notcontains $req.Headers['Host']) {
            Send-Json $stream 403 @{ error = 'Invalid Host header.' }
            return
        }

        if ($req.Path.StartsWith('/api/')) {
            $origin = $req.Headers['Origin']
            if ($origin -and @("http://127.0.0.1:$port", "http://localhost:$port") -notcontains $origin) {
                Send-Json $stream 403 @{ error = 'Cross-origin request rejected.' }
                return
            }
            if ($req.Headers['X-Dashboard-Token'] -cne $Ctx.Token) {
                Send-Json $stream 401 @{ error = 'Missing or invalid session token. Re-open the dashboard from the launcher.' }
                return
            }

            switch ($req.Path) {
                '/api/config' {
                    Send-Json $stream 200 $Ctx.PublicConfig
                    return
                }
                '/api/run' {
                    if ($req.Method -ne 'POST') { Send-Json $stream 405 @{ error = 'POST required.' }; return }
                    $body = $req.Body | ConvertFrom-Json
                    $instance = $Ctx.Instances[[string]$body.instanceId]
                    $isPing = ([string]$body.checkId) -eq '__ping'
                    $check = if ($isPing) { $null } else { $Ctx.Checks[[string]$body.checkId] }
                    if (-not $instance -or (-not $isPing -and -not $check)) {
                        Send-Json $stream 400 @{ error = 'Unknown instance or check.' }
                        return
                    }

                    if ($isPing) {
                        $sql = $Ctx.PingSql; $timeout = 15; $label = 'ping'
                    } else {
                        $sql = [IO.File]::ReadAllText($check.Path); $timeout = $check.CommandTimeout; $label = $check.Id
                    }

                    $sw = [Diagnostics.Stopwatch]::StartNew()
                    $result = @{
                        instanceId = $instance.Id
                        checkId    = [string]$body.checkId
                        startedAt  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                        ok         = $true
                        error      = $null
                        resultSets = @()
                        messages   = @()
                    }
                    try {
                        $r = Invoke-Sql $instance $sql $timeout $Ctx.MaxRows
                        $result.resultSets = $r.resultSets
                        $result.messages = $r.messages
                    }
                    catch {
                        $result.ok = $false
                        $result.error = [string](Get-InnerMessage $_.Exception)
                    }
                    $sw.Stop()
                    $result.durationMs = [int]$sw.ElapsedMilliseconds

                    $status = if ($result.ok) { 'ok' } else { 'FAILED: ' + $result.error }
                    $Ctx.Log.Enqueue(('{0,-12} {1,-22} {2,6} ms  {3}' -f $label, $instance.Name, $result.durationMs, $status))
                    Send-Json $stream 200 $result
                    return
                }
                default {
                    Send-Json $stream 404 @{ error = 'Unknown API endpoint.' }
                    return
                }
            }
        }

        # ---- Static files ----
        if ($req.Method -ne 'GET') { Send-Json $stream 405 @{ error = 'Method not allowed.' }; return }
        $rel = if ($req.Path -eq '/' -or $req.Path -eq '') { 'index.html' } else { $req.Path.TrimStart('/') }
        $full = [IO.Path]::GetFullPath((Join-Path $Ctx.WebRoot $rel))
        if (-not $full.StartsWith($Ctx.WebRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
            -not [IO.File]::Exists($full)) {
            Send-Response $stream 404 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('Not found'))
            return
        }
        $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
        $type = $Ctx.MimeTypes[$ext]
        if (-not $type) {
            Send-Response $stream 404 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('Not found'))
            return
        }
        Send-Response $stream 200 $type ([IO.File]::ReadAllBytes($full))
    }
    catch {
        try {
            if ($stream) { Send-Json $stream 500 @{ error = [string](Get-InnerMessage $_.Exception) } }
        } catch { }
        $Ctx.Log.Enqueue('Request error: ' + $_.Exception.Message)
    }
    finally {
        if ($stream) { $stream.Dispose() }
        $Client.Close()
    }
}

# ---------------------------------------------------------------------------
# Start listening
# ---------------------------------------------------------------------------
$listener = $null
for ($p = $Port; $p -lt $Port + 10; $p++) {
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
        $listener.Start()
        $Port = $p
        break
    }
    catch {
        $listener = $null
        Write-Log "Port $p is in use, trying the next one..." 'Yellow'
    }
}
if (-not $listener) { throw "Could not bind to any port between $Port and $($Port + 9)." }

$token = New-SessionToken
$ctx = [hashtable]::Synchronized(@{
    Port         = $Port
    Token        = $token
    WebRoot      = [IO.Path]::GetFullPath((Join-Path $Root 'web'))
    Instances    = $instances
    Checks       = $checks
    PublicConfig = $publicConfig
    MaxRows      = $maxRows
    UseJss       = $useJss
    Log          = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
    PingSql      = @"
SET NOCOUNT ON;
SELECT CAST(SERVERPROPERTY('ServerName') AS nvarchar(256))     AS ServerName,
       CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64))  AS ProductVersion,
       CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(64))    AS ProductLevel,
       CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(64)) AS UpdateLevel,
       CAST(SERVERPROPERTY('Edition') AS nvarchar(128))        AS Edition,
       CAST(ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0) AS int) AS IsHadrEnabled,
       SUSER_SNAME()                                           AS LoginName;
"@
    MimeTypes    = @{
        '.html' = 'text/html; charset=utf-8'
        '.css'  = 'text/css; charset=utf-8'
        '.js'   = 'application/javascript; charset=utf-8'
        '.json' = 'application/json; charset=utf-8'
        '.svg'  = 'image/svg+xml'
        '.png'  = 'image/png'
        '.ico'  = 'image/x-icon'
        '.woff2' = 'font/woff2'
    }
})

$pool = [RunspaceFactory]::CreateRunspacePool(1, [Math]::Max(2, $maxConcurrent))
$pool.Open()

$url = "http://127.0.0.1:$Port/#t=$token"
try { $Host.UI.RawUI.WindowTitle = "SQL Health Dashboard - http://127.0.0.1:$Port" } catch { }

Write-Host ''
Write-Host '  SQL Server Health Dashboard' -ForegroundColor Cyan
Write-Host "  Version $Version  |  $($instances.Count) instance(s)  |  $($checks.Count) check(s)" -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Open this address in Edge or Chrome (it contains your session key):' -ForegroundColor Gray
Write-Host "  $url" -ForegroundColor Green
Write-Host ''
Write-Host '  Keep this window open while you use the dashboard. Press Ctrl+C to stop.' -ForegroundColor DarkGray
Write-Host ''
$who = try { [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { [Environment]::UserName }
Write-Log "Listening on 127.0.0.1:$Port as $who" 'Cyan'

if ($openBrowser) {
    try {
        $browser = Find-Browser
        if ($browser -and $appMode) { Start-Process -FilePath $browser -ArgumentList "--app=$url" }
        elseif ($browser) { Start-Process -FilePath $browser -ArgumentList $url }
        else { Start-Process $url }
    }
    catch { Write-Log "Could not open a browser automatically: $($_.Exception.Message)" 'Yellow' }
}

$jobs = New-Object System.Collections.Generic.List[object]
try {
    while ($true) {
        if ($listener.Pending()) {
            $client = $listener.AcceptTcpClient()
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($handler).AddArgument($client).AddArgument($ctx)
            $jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
        }
        else {
            Start-Sleep -Milliseconds 20
        }

        for ($k = $jobs.Count - 1; $k -ge 0; $k--) {
            $job = $jobs[$k]
            if ($job.Handle.IsCompleted) {
                try { [void]$job.PS.EndInvoke($job.Handle) }
                catch { Write-Log "Handler error: $($_.Exception.Message)" 'Red' }
                $job.PS.Dispose()
                $jobs.RemoveAt($k)
            }
        }

        $line = $null
        while ($ctx.Log.TryDequeue([ref]$line)) {
            $color = if ($line -match 'FAILED|error') { 'Red' } else { 'Gray' }
            Write-Log $line $color
        }
    }
}
finally {
    Write-Log 'Shutting down...' 'Cyan'
    $listener.Stop()
    foreach ($job in $jobs) { try { $job.PS.Stop(); $job.PS.Dispose() } catch { } }
    $pool.Close()
    $pool.Dispose()
}
