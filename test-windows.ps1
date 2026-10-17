<#
.SYNOPSIS
    duckdb-oracle smoke test for Windows: stock DuckDB CLI (default v1.5.6) + external duckdb-oracle
    extension + (optionally) the local Oracle 19c Docker container.

.DESCRIPTION
    1. Checks which oci.dll the extension will load and whether it is 64-bit.
    2. Verifies that the stock DuckDB CLI does NOT already contain duckdb_oracle.
    Also detects the host architecture (Windows on ARM) and warns on any
    architecture mismatch between duckdb.exe, the extension and oci.dll.
    3. Unpacks the shipped package duckdb_oracle-windows_<arch>.zip (default:
       next to this script; -Extension takes a zip or a file that is already
       named duckdb_oracle.duckdb_extension - nothing is renamed), then
       LOADs duckdb_oracle.duckdb_extension with -unsigned and prints
       duckdb_extensions() and oracle_client_info().
    4. Unless -SkipOracle: runs queries against the Oracle container
       (SELECT * FROM dual, a type-coverage query, multi-batch + LIMIT) and an
       unreachable-DSN error check.
    5. Optional: if $env:ORACLE_DSN_23AI is set, the same checks plus
       BOOLEAN / JSON / VECTOR mapping against a 23ai/26ai database (for
       example gvenzl/oracle-free on localhost:1522/FREEPDB1).
    Every DuckDB run prints its exit code in decimal and hex, so an access
    violation shows up as 0xC0000005. Each run has a timeout so a hang is
    reported instead of blocking forever.

    The password is read ONLY from $env:ORACLE_PASSWORD by the extension
    itself. It is never placed on a command line, in a SQL file, or printed.
    Set it without echoing, e.g.:
        $s = Read-Host 'Oracle password' -AsSecureString
        $env:ORACLE_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))

.EXAMPLE
    .\test-windows.ps1
.EXAMPLE
    .\test-windows.ps1 -DuckDB C:\tools\duckdb.exe -Extension .\duckdb_oracle-windows_amd64.zip
.EXAMPLE
    .\test-windows.ps1 -SkipOracle      # load test only (what CI runs)
.EXAMPLE
    .\test-windows.ps1 -SkipOracle -DuckDBVersion v1.3.2   # another official release
#>
[CmdletBinding()]
param(
    [string]$Extension = '',
    [string]$DuckDB = '',
    [string]$Dsn = 'localhost:1521/ORCLPDB1',
    [string]$User = 'SAMPLE_DEV',
    [switch]$SkipOracle,
    [int]$TimeoutSeconds = 120,
    # Official DuckDB release to download/expect (any 1.x >= the footer's C API
    # version works; v1.5.6 is the tested baseline).
    [string]$DuckDBVersion = 'v1.5.6',
    # CLI to download when -DuckDB is not given. x64 is also the right choice on
    # Windows ARM64 hosts (no ARM64 Oracle Instant Client exists).
    [ValidateSet('x64', 'arm64')]
    [string]$DuckDBArch = 'x64'
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$WorkDir = Join-Path ([IO.Path]::GetTempPath()) 'duckdb-oracle-smoke'
$null = New-Item -ItemType Directory -Force -Path $WorkDir
$Results = New-Object System.Collections.ArrayList

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor Cyan
}

function Format-ExitCode([int]$Code) {
    # Int32 formatting with X8 gives the NTSTATUS form, e.g. -1073741819 -> C0000005
    return ('{0} (0x{1})' -f $Code, $Code.ToString('X8'))
}

function Add-Result([string]$Step, [string]$Status, [string]$Detail) {
    $null = $Results.Add([pscustomobject]@{ Step = $Step; Status = $Status; Detail = $Detail })
}

function Get-PeMachine([string]$Path) {
    # Returns 'x64', 'x86', 'ARM64' or 'unknown (0x....)' by reading the PE header.
    $fs = [IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 4096
        $n = $fs.Read($buf, 0, $buf.Length)
    } finally { $fs.Dispose() }
    if ($n -lt 64 -or $buf[0] -ne 0x4D -or $buf[1] -ne 0x5A) { return 'not a PE file' }
    $peOffset = [BitConverter]::ToInt32($buf, 0x3C)
    if ($peOffset -lt 0 -or $peOffset + 6 -gt $n) { return 'not a PE file' }
    if ($buf[$peOffset] -ne 0x50 -or $buf[$peOffset + 1] -ne 0x45) { return 'not a PE file' }
    $machine = [BitConverter]::ToUInt16($buf, $peOffset + 4)
    switch ($machine) {
        0x8664 { return 'x64' }
        0x014C { return 'x86' }
        0xAA64 { return 'ARM64' }
        default { return ('unknown (0x{0:X4})' -f $machine) }
    }
}

function Invoke-DuckDB {
    # Runs the CLI on a SQL file (no SQL on the command line), with a timeout.
    param([string]$Name, [string]$Sql, [switch]$Unsigned, [string[]]$ExtraArgs = @())
    $sqlFile = Join-Path $WorkDir ($Name + '.sql')
    $outFile = Join-Path $WorkDir ($Name + '.out.txt')
    $errFile = Join-Path $WorkDir ($Name + '.err.txt')
    [IO.File]::WriteAllText($sqlFile, $Sql, (New-Object Text.UTF8Encoding $false))
    $argList = @()
    if ($Unsigned) { $argList += '-unsigned' }
    $argList += $ExtraArgs
    $argList += @('-bail', '-f', ('"{0}"' -f $sqlFile))
    $p = Start-Process -FilePath $script:DuckDBExe -ArgumentList ($argList -join ' ') -NoNewWindow -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $null = $p.Handle   # make ExitCode available after exit (PowerShell quirk)
    $timedOut = -not $p.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        try { $p.Kill() } catch { }
        $code = -1
    } else {
        $p.WaitForExit()
        $code = [int]$p.ExitCode
    }
    $stdout = if (Test-Path $outFile) { [IO.File]::ReadAllText($outFile) } else { '' }
    $stderr = if (Test-Path $errFile) { [IO.File]::ReadAllText($errFile) } else { '' }
    if ($stdout) { Write-Host $stdout.TrimEnd() }
    if ($stderr) { Write-Host $stderr.TrimEnd() -ForegroundColor Yellow }
    if ($timedOut) {
        Write-Host ("TIMEOUT after {0}s (process killed) - treat as a hang" -f $TimeoutSeconds) -ForegroundColor Red
    } else {
        Write-Host ('exit code: ' + (Format-ExitCode $code))
    }
    return [pscustomobject]@{ Code = $code; TimedOut = $timedOut; Out = $stdout; Err = $stderr }
}

function SqlLit([string]$s) { return "'" + $s.Replace("'", "''") + "'" }

# ---------------------------------------------------------------------------
function Get-HostArch {
    # Native machine architecture, also correct for an x64 PowerShell running
    # under emulation on Windows ARM64 (the registry value is not virtualised).
    try {
        $v = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name PROCESSOR_ARCHITECTURE -ErrorAction Stop).PROCESSOR_ARCHITECTURE
        if ($v) { return (ConvertTo-Arch $v) }
    } catch { }
    if ($env:PROCESSOR_ARCHITEW6432) { return (ConvertTo-Arch $env:PROCESSOR_ARCHITEW6432) }
    if ($env:PROCESSOR_ARCHITECTURE) { return (ConvertTo-Arch $env:PROCESSOR_ARCHITECTURE) }
    try { return (ConvertTo-Arch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString())) } catch { return 'unknown' }
}

function ConvertTo-Arch([string]$a) {
    switch -regex ($a) {
        '^(AMD64|x64|X64)$' { return 'x64' }
        '^(ARM64|Arm64|arm64)$' { return 'ARM64' }
        '^(x86|X86)$' { return 'x86' }
        default { return $a }
    }
}

Write-Section 'Environment'
$HostArch = Get-HostArch
$PsArch = if ($env:PROCESSOR_ARCHITEW6432) { 'x86' } elseif ($env:PROCESSOR_ARCHITECTURE) { ConvertTo-Arch $env:PROCESSOR_ARCHITECTURE } else {
    try { ConvertTo-Arch ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()) } catch { 'unknown' } }
Write-Host ('PowerShell     : {0} ({1} process)' -f $PSVersionTable.PSVersion, $PsArch)
Write-Host ('OS             : {0}' -f [Environment]::OSVersion.VersionString)
Write-Host ('Host arch      : {0}' -f $HostArch)
if ($HostArch -eq 'ARM64') {
    Write-Host ('Windows on ARM detected. Oracle publishes no Windows ARM64 Instant Client, so the supported setup is: ' +
        'x64 DuckDB CLI + duckdb_oracle-windows_amd64 + x64 Instant Client, running under x64 emulation.') -ForegroundColor Yellow
}

# --- DuckDB CLI --------------------------------------------------------------
Write-Section "Stock DuckDB CLI $DuckDBVersion"
$script:DuckDBExe = $null
if ($DuckDB) {
    $script:DuckDBExe = (Resolve-Path $DuckDB).Path
} else {
    $onPath = Get-Command duckdb.exe -ErrorAction SilentlyContinue
    if ($onPath) {
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $v = (& $onPath.Source -version) 2>$null | Out-String
        $ErrorActionPreference = $eap
        $onPathArch = Get-PeMachine $onPath.Source
        if (($v -match [regex]::Escape($DuckDBVersion)) -and ($onPathArch -eq (ConvertTo-Arch $DuckDBArch))) { $script:DuckDBExe = $onPath.Source }
        else { Write-Host ("duckdb on PATH is '{0}' ({1}), not {2} {3}; downloading the official CLI" -f $v.Trim(), $onPathArch, $DuckDBVersion, $DuckDBArch) }
    }
    if (-not $script:DuckDBExe) {
        $zipName = if ($DuckDBArch -eq 'arm64') { 'duckdb_cli-windows-arm64.zip' } else { 'duckdb_cli-windows-amd64.zip' }
        $url = "https://github.com/duckdb/duckdb/releases/download/$DuckDBVersion/$zipName"
        $dir = Join-Path $WorkDir "duckdb-$DuckDBVersion-$DuckDBArch"
        $exe = Join-Path $dir 'duckdb.exe'
        if (-not (Test-Path $exe)) {
            $zip = Join-Path $WorkDir $zipName
            Write-Host "Downloading $url"
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
            Expand-Archive -Path $zip -DestinationPath $dir -Force
        }
        $script:DuckDBExe = $exe
    }
}
$eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$verText = ((& $script:DuckDBExe -version) 2>&1 | Out-String).Trim()
$ErrorActionPreference = $eap
$CliArch = Get-PeMachine $script:DuckDBExe
Write-Host ('DuckDB CLI     : {0}' -f $script:DuckDBExe)
Write-Host ('Version        : {0}' -f $verText)
Write-Host ('CLI arch       : {0}{1}' -f $CliArch, $(if ($HostArch -eq 'ARM64' -and $CliArch -eq 'x64') { ' (runs under x64 emulation on this ARM64 host)' } else { '' }))
if ($verText -notmatch [regex]::Escape($DuckDBVersion)) {
    Add-Result 'duckdb version' 'FAIL' $verText
    Write-Warning "Expected DuckDB $DuckDBVersion"
} else {
    Add-Result 'duckdb version' 'PASS' $verText
}

# --- extension --------------------------------------------------------------
# Shipped form: duckdb_oracle-windows_<arch>.zip containing exactly
# duckdb_oracle.duckdb_extension. DuckDB derives the init symbol from the file
# name ("<name>.duckdb_extension" -> "<name>_init_c_api"), so the file is loaded
# under its exact shipped name and is never renamed here: a wrongly named
# artifact fails this script instead of being papered over.
$ShippedName = 'duckdb_oracle.duckdb_extension'
if (-not $Extension) {
    # pick the package matching duckdb.exe
    $pkgName = if ($CliArch -eq 'ARM64') { 'duckdb_oracle-windows_arm64.zip' } else { 'duckdb_oracle-windows_amd64.zip' }
    $Extension = Join-Path $PSScriptRoot $pkgName
}
if (-not (Test-Path $Extension)) { throw "Extension package not found: $Extension (pass -Extension <zip or $ShippedName>)" }
$Extension = (Resolve-Path $Extension).Path
if ($Extension -like '*.zip') {
    $pkg = $Extension
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($pkg)
    try { $entries = @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }
    if ($entries.Count -ne 1 -or $entries[0] -ne $ShippedName) {
        Add-Result 'package' 'FAIL' ("{0} must contain exactly {1}; found: {2}" -f (Split-Path $pkg -Leaf), $ShippedName, ($entries -join ', '))
        throw ("Bad package {0}: it must contain exactly {1}, found [{2}]" -f $pkg, $ShippedName, ($entries -join ', '))
    }
    $extDir = Join-Path $WorkDir ('pkg-' + [IO.Path]::GetFileNameWithoutExtension($pkg))
    if (Test-Path $extDir) { Remove-Item -Recurse -Force $extDir }
    Expand-Archive -Path $pkg -DestinationPath $extDir -Force
    $Extension = Join-Path $extDir $ShippedName
    Write-Host ('Package        : {0} -> {1}' -f $pkg, $Extension)
    Add-Result 'package' 'PASS' ((Split-Path $pkg -Leaf) + ' contains exactly ' + $ShippedName)
} elseif ((Split-Path $Extension -Leaf) -ne $ShippedName) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($Extension)
    Add-Result 'package' 'FAIL' ("file name must be $ShippedName")
    throw ("'{0}' is not named {1}. DuckDB would look for '{2}_init_c_api' and LOAD would fail. Use the shipped zip or rename the file." -f $Extension, $ShippedName, $stem)
}
$ExtSql = $Extension.Replace('\', '/')
$ExtArch = Get-PeMachine $Extension
Write-Host ('Extension      : {0}' -f $Extension)
Write-Host ('Extension arch : {0}' -f $ExtArch)
Write-Host ('SHA256         : {0}' -f (Get-FileHash -Algorithm SHA256 $Extension).Hash)

# --- oci.dll resolution ------------------------------------------------------
Write-Section 'Oracle client (oci.dll) resolution'
# ODPI-C load order: 1) $env:DUCKDB_ORACLE_CLIENT_LIB_DIR only, if set;
# 2) the extension's own directory; 3) Windows LoadLibrary search
# (directory of duckdb.exe, System32, Windows, current dir, PATH in order).
$candidates = New-Object System.Collections.ArrayList
$libDirOverride = $env:DUCKDB_ORACLE_CLIENT_LIB_DIR
if ($libDirOverride) {
    Write-Host "DUCKDB_ORACLE_CLIENT_LIB_DIR is set: ODPI-C will ONLY look in $libDirOverride"
    $null = $candidates.Add([pscustomobject]@{ Source = 'DUCKDB_ORACLE_CLIENT_LIB_DIR'; Dir = $libDirOverride })
} else {
    $null = $candidates.Add([pscustomobject]@{ Source = 'extension dir'; Dir = (Split-Path $Extension) })
    $null = $candidates.Add([pscustomobject]@{ Source = 'duckdb.exe dir'; Dir = (Split-Path $script:DuckDBExe) })
    $null = $candidates.Add([pscustomobject]@{ Source = 'System32'; Dir = [Environment]::SystemDirectory })
    $null = $candidates.Add([pscustomobject]@{ Source = 'Windows'; Dir = $env:windir })
    $null = $candidates.Add([pscustomobject]@{ Source = 'current dir'; Dir = (Get-Location).Path })
    $i = 0
    foreach ($d in ($env:PATH -split [regex]::Escape([IO.Path]::PathSeparator))) {
        $i++
        if ($d.Trim()) { $null = $candidates.Add([pscustomobject]@{ Source = "PATH[$i]"; Dir = $d.Trim() }) }
    }
}
$found = @()
foreach ($c in $candidates) {
    if (-not $c.Dir) { continue }
    $p = Join-Path ([Environment]::ExpandEnvironmentVariables($c.Dir)) 'oci.dll'
    if (Test-Path -LiteralPath $p -PathType Leaf) {
        $arch = Get-PeMachine $p
        $ver = (Get-Item -LiteralPath $p).VersionInfo.ProductVersion
        $found += [pscustomobject]@{ Source = $c.Source; Path = $p; Arch = $arch; Version = $ver }
    }
}
$OciArch = $null
if ($found.Count -eq 0) {
    Write-Warning 'No oci.dll found. LOAD will still work, but oracle_query() will fail with DPI-1047.'
    Add-Result 'oci.dll' 'WARN' 'not found'
} else {
    Write-Host 'oci.dll candidates in load order:'
    $found | Format-Table -AutoSize | Out-String | Write-Host
    $first = $found[0]
    $OciArch = $first.Arch
    Write-Host ('First oci.dll (expected to be loaded): {0} [{1}, {2}]' -f $first.Path, $first.Arch, $first.Version)
    if ($first.Arch -ne $CliArch) {
        Write-Warning ('The first oci.dll is {0}, but duckdb.exe is {1}. They must match. ' -f $first.Arch, $CliArch +
            'Put the matching Instant Client first on PATH, or set $env:DUCKDB_ORACLE_CLIENT_LIB_DIR to its directory.')
        Add-Result 'oci.dll' 'WARN' ('first is ' + $first.Arch + ' (duckdb.exe is ' + $CliArch + '): ' + $first.Path)
    } else {
        Add-Result 'oci.dll' 'PASS' ($first.Path + ' ' + $first.Version + ' [' + $first.Arch + ']')
    }
    $other = @($found | Where-Object { $_.Arch -ne $CliArch })
    if ($other.Count -gt 0 -and $first.Arch -eq $CliArch) { Write-Host ('Note: {0} oci.dll of another architecture later in the search order (ignored because a matching one comes first).' -f $other.Count) }
}

# --- architecture consistency --------------------------------------------------
Write-Section 'Architecture check: host / duckdb.exe / extension / oci.dll'
$archRow = [pscustomobject]@{ Host = $HostArch; 'duckdb.exe' = $CliArch; Extension = $ExtArch; 'oci.dll' = $(if ($OciArch) { $OciArch } else { '(none)' }) }
$archRow | Format-Table -AutoSize | Out-String | Write-Host
$archProblems = @()
if ($ExtArch -ne $CliArch) {
    $archProblems += ('extension is {0} but duckdb.exe is {1}: LOAD will fail. Use duckdb_oracle-windows_{2}.' -f $ExtArch, $CliArch, $(if ($CliArch -eq 'ARM64') { 'arm64' } else { 'amd64' }))
}
if ($OciArch -and $OciArch -ne $CliArch) {
    $archProblems += ('oci.dll is {0} but duckdb.exe is {1}: the client cannot be loaded.' -f $OciArch, $CliArch)
}
if ($CliArch -eq 'ARM64') {
    $archProblems += ('duckdb.exe is native ARM64: Oracle publishes no Windows ARM64 Instant Client, so oracle_query() cannot work in this process. ' +
        'Use the x64 DuckDB CLI (-DuckDBArch x64) + duckdb_oracle-windows_amd64 + the x64 Instant Client (x64 emulation).')
}
if ($HostArch -eq 'ARM64' -and $CliArch -eq 'x64') {
    Write-Host 'x64 duckdb.exe on an ARM64 host: this is the supported Windows-on-ARM setup (needs the x64 Instant Client and the x64 VC++ redistributable).'
}
if ($archProblems.Count -gt 0) {
    foreach ($m in $archProblems) { Write-Warning $m }
    Add-Result 'architecture' 'WARN' ($archProblems -join ' | ')
} else {
    Add-Result 'architecture' 'PASS' ('host ' + $HostArch + ', duckdb/extension ' + $CliArch + $(if ($OciArch) { ', oci.dll ' + $OciArch } else { '' }))
}

# --- 1. not built in ---------------------------------------------------------
Write-Section '1. duckdb_oracle must not be built into / preloaded in the stock CLI'
$r = Invoke-DuckDB -Name 'precheck' -ExtraArgs @('-csv', '-noheader') -Sql @"
SELECT count(*) FROM duckdb_extensions() WHERE extension_name = 'duckdb_oracle' AND (loaded OR installed);
SELECT count(*) FROM duckdb_functions() WHERE function_name LIKE 'oracle_%';
"@
$lines = @($r.Out -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
if ($r.Code -eq 0 -and ($lines -join ',') -eq '0,0') { Add-Result 'not built in' 'PASS' '0 rows, 0 oracle_* functions' }
else { Add-Result 'not built in' 'FAIL' ("exit " + (Format-ExitCode $r.Code) + ", output: " + ($lines -join ',')) }

# --- 2. LOAD -----------------------------------------------------------------
Write-Section '2. LOAD the external extension + oracle_client_info()'
$r = Invoke-DuckDB -Name 'load' -Unsigned -Sql @"
LOAD $(SqlLit $ExtSql);
SELECT extension_name, loaded, installed, extension_version, install_mode FROM duckdb_extensions() WHERE extension_name = 'duckdb_oracle';
.mode line
SELECT * FROM oracle_client_info();
"@
if ($r.Code -eq 0) { Add-Result 'LOAD + oracle_client_info' 'PASS' (Format-ExitCode $r.Code) }
elseif ($r.TimedOut) { Add-Result 'LOAD + oracle_client_info' 'FAIL' 'TIMEOUT (hang)' }
else { Add-Result 'LOAD + oracle_client_info' 'FAIL' (Format-ExitCode $r.Code) }

$r = Invoke-DuckDB -Name 'loaded' -Unsigned -ExtraArgs @('-csv', '-noheader') -Sql @"
LOAD $(SqlLit $ExtSql);
SELECT loaded FROM duckdb_extensions() WHERE extension_name = 'duckdb_oracle';
"@
if ($r.Code -eq 0 -and $r.Out.Trim() -eq 'true') { Add-Result 'loaded=true' 'PASS' '' }
else { Add-Result 'loaded=true' 'FAIL' ("exit " + (Format-ExitCode $r.Code) + ", output: " + $r.Out.Trim()) }

# Oracle SQL covering the mapped types, built from literals / CAST on dual.
$typesSql = @"
SELECT
  CAST(42 AS NUMBER(10))                                  AS num_int,
  CAST(12345.67 AS NUMBER(12,2))                          AS num_dec,
  CAST(123456789012345678901234 AS NUMBER(30))            AS num_big,
  CAST(1.5 AS NUMBER)                                     AS num_plain,
  CAST(1.5 AS BINARY_DOUBLE)                              AS bin_double,
  CAST(2.5 AS BINARY_FLOAT)                               AS bin_float,
  CAST('hello' AS VARCHAR2(20))                           AS vc,
  CAST(UNISTR('gr\00FC\00DFe') AS NVARCHAR2(20))          AS nvc,
  CAST('abc' AS CHAR(5))                                  AS ch,
  CAST(UNISTR('xyz') AS NCHAR(5))                         AS nch,
  TO_CLOB('clob text')                                    AS clob_col,
  TO_NCLOB('nclob text')                                  AS nclob_col,
  DATE '2024-02-29'                                       AS d,
  TIMESTAMP '2024-02-29 13:45:30.123456'                  AS ts,
  TIMESTAMP '2024-01-01 10:00:00 +05:30'                  AS tstz,
  CAST(TIMESTAMP '2024-01-01 10:00:00 +05:30' AS TIMESTAMP WITH LOCAL TIME ZONE) AS tsltz,
  HEXTORAW('DEADBEEF')                                    AS raw_col,
  TO_BLOB(HEXTORAW('CAFEBABE'))                           AS blob_col,
  INTERVAL '3 04:05:06.007' DAY TO SECOND                 AS ids,
  INTERVAL '2-3' YEAR TO MONTH                            AS iym,
  CAST(NULL AS NUMBER(10))                                AS null_int,
  CAST(NULL AS NUMBER(12,2))                              AS null_dec,
  CAST(NULL AS VARCHAR2(10))                              AS null_vc,
  CAST(NULL AS DATE)                                      AS null_date,
  CAST(NULL AS RAW(4))                                    AS null_raw,
  ROWID                                                   AS rid
FROM dual
"@

# --- 3. Oracle ---------------------------------------------------------------
if ($SkipOracle) {
    Write-Section '3. Oracle queries: skipped (-SkipOracle)'
    Add-Result 'oracle queries' 'SKIP' '-SkipOracle'
} elseif (-not $env:ORACLE_PASSWORD) {
    Write-Section '3. Oracle queries: skipped'
    Write-Warning 'ORACLE_PASSWORD is not set. Set it without echoing (see Get-Help .\test-windows.ps1) and re-run.'
    Add-Result 'oracle queries' 'SKIP' 'ORACLE_PASSWORD not set'
} else {
    $q = "oracle_query($(SqlLit $Dsn), {0}, user := $(SqlLit $User))"
    Write-Host ("DSN: {0}   user: {1}   password: from `$env:ORACLE_PASSWORD (not shown)" -f $Dsn, $User)

    Write-Section '3a. SELECT * FROM dual'
    $r = Invoke-DuckDB -Name 'dual' -Unsigned -Sql @"
LOAD $(SqlLit $ExtSql);
SELECT * FROM $($q -f (SqlLit 'SELECT * FROM dual'));
"@
    Add-Result 'SELECT * FROM dual' $(if ($r.Code -eq 0) { 'PASS' } else { 'FAIL' }) (Format-ExitCode $r.Code)

    $tq = $q -f (SqlLit $typesSql)

    Write-Section '3b. Type coverage: DESCRIBE, values, per-column checks'
    $r = Invoke-DuckDB -Name 'types' -Unsigned -Sql @"
LOAD $(SqlLit $ExtSql);
.mode box
SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM $tq);
.mode line
SELECT * FROM $tq;
SELECT
  num_int = 42                                          AS ok_num_int,
  num_dec = 12345.67                                    AS ok_num_dec,
  num_big = 123456789012345678901234                    AS ok_num_big,
  num_plain = 1.5                                       AS ok_num_plain,
  bin_double = 1.5                                      AS ok_bin_double,
  bin_float = 2.5                                       AS ok_bin_float,
  vc = 'hello'                                          AS ok_vc,
  nvc = 'gr' || chr(252) || chr(223) || 'e'             AS ok_nvc,
  ch = 'abc  '                                          AS ok_ch,
  rtrim(nch) = 'xyz'                                    AS ok_nch,
  clob_col = 'clob text'                                AS ok_clob,
  nclob_col = 'nclob text'                              AS ok_nclob,
  d = TIMESTAMP '2024-02-29 00:00:00'                   AS ok_date,
  ts = TIMESTAMP '2024-02-29 13:45:30.123456'           AS ok_ts,
  tstz = TIMESTAMPTZ '2024-01-01 04:30:00+00'           AS ok_tstz,
  tsltz = TIMESTAMPTZ '2024-01-01 04:30:00+00'          AS ok_tsltz,
  raw_col = '\xDE\xAD\xBE\xEF'::BLOB                    AS ok_raw,
  blob_col = '\xCA\xFE\xBA\xBE'::BLOB                   AS ok_blob,
  ids = INTERVAL '3 days 04:05:06.007'                  AS ok_interval_ds,
  iym = INTERVAL '27 months'                            AS ok_interval_ym,
  null_int IS NULL AND null_dec IS NULL AND null_vc IS NULL AND null_date IS NULL AND null_raw IS NULL AS ok_nulls,
  length(rid) >= 18                                     AS ok_rowid
FROM $tq;
"@
    $okLines = @($r.Out -split "`r?`n" | Where-Object { $_ -match '^\s*ok_\w+\s*=' })
    $bad = @($okLines | Where-Object { $_ -notmatch '=\s*true\s*$' })
    if ($r.Code -eq 0 -and $okLines.Count -gt 0 -and $bad.Count -eq 0) { Add-Result 'type coverage' 'PASS' ("{0} checks true" -f $okLines.Count) }
    else { Add-Result 'type coverage' 'FAIL' ("exit " + (Format-ExitCode $r.Code) + "; not true: " + (($bad | ForEach-Object { $_.Trim() }) -join '; ')) }

    Write-Section '3c. Multi-batch fetch (5000 rows) and early termination (LIMIT)'
    $r = Invoke-DuckDB -Name 'batches' -Unsigned -ExtraArgs @('-csv') -Sql @"
LOAD $(SqlLit $ExtSql);
SELECT count(*) AS n, sum(n) AS s, count(*) FILTER (WHERE n IS NULL) AS nulls FROM $($q -f (SqlLit 'SELECT CAST(level AS NUMBER(10)) AS n FROM dual CONNECT BY level <= 5000'));
SELECT * FROM $($q -f (SqlLit 'SELECT CAST(level AS NUMBER(10)) AS n FROM dual CONNECT BY level <= 100000')) LIMIT 3;
SELECT count(*) AS nulls_roundtrip FROM $($q -f (SqlLit 'SELECT CASE WHEN MOD(level, 2) = 0 THEN NULL ELSE level END AS v FROM dual CONNECT BY level <= 3000')) WHERE v IS NULL;
"@
    $ok = $r.Code -eq 0 -and $r.Out -match '5000,12502500,0' -and $r.Out -match '(?m)^1500\s*$'
    Add-Result 'batches/LIMIT/NULLs' $(if ($ok) { 'PASS' } else { 'FAIL' }) (Format-ExitCode $r.Code)

    Write-Section '3d. Error path: unreachable DSN must give a DuckDB error with ORA-/DPI-, not a crash'
    $r = Invoke-DuckDB -Name 'unreachable' -Unsigned -Sql @"
LOAD $(SqlLit $ExtSql);
SELECT * FROM oracle_query('127.0.0.1:1/NOPE', 'SELECT * FROM dual', user := $(SqlLit $User));
"@
    $ok = (-not $r.TimedOut) -and $r.Code -eq 1 -and (($r.Out + $r.Err) -match '(ORA|DPI)-\d+')
    Add-Result 'unreachable DSN error' $(if ($ok) { 'PASS' } else { 'FAIL' }) (Format-ExitCode $r.Code)
}

# --- 4. optional: Oracle 23ai / 26ai database --------------------------------
# Skipped unless $env:ORACLE_DSN_23AI is set, e.g. 'localhost:1522/FREEPDB1' for
#   docker run -d -p 1522:1521 -e ORACLE_PASSWORD=... gvenzl/oracle-free
# User:     $env:ORACLE_USER_23AI (default SYSTEM)
# Password: $env:ORACLE_PASSWORD_23AI (falls back to $env:ORACLE_PASSWORD). It is
#           handed to duckdb.exe only through its environment (ORACLE_PASSWORD),
#           never on a command line or in a SQL file.
if (-not $env:ORACLE_DSN_23AI) {
    Write-Section '4. Oracle 23ai/26ai section: skipped (ORACLE_DSN_23AI not set)'
    Add-Result '23ai/26ai section' 'SKIP' 'ORACLE_DSN_23AI not set'
} else {
    $dsn23 = $env:ORACLE_DSN_23AI
    $user23 = if ($env:ORACLE_USER_23AI) { $env:ORACLE_USER_23AI } else { 'SYSTEM' }
    $pw23 = if ($env:ORACLE_PASSWORD_23AI) { $env:ORACLE_PASSWORD_23AI } else { $env:ORACLE_PASSWORD }
    if (-not $pw23) {
        Write-Section '4. Oracle 23ai/26ai section: skipped'
        Write-Warning 'Set $env:ORACLE_PASSWORD_23AI (or ORACLE_PASSWORD) for the 23ai/26ai database.'
        Add-Result '23ai/26ai section' 'SKIP' 'no password in environment'
    } else {
        $savedPw = $env:ORACLE_PASSWORD
        try {
            $env:ORACLE_PASSWORD = $pw23   # inherited by duckdb.exe only
            $q23 = "oracle_query($(SqlLit $dsn23), {0}, user := $(SqlLit $user23))"
            Write-Section '4. Oracle 23ai/26ai database'
            Write-Host ("DSN: {0}   user: {1}   password: from environment (not shown)" -f $dsn23, $user23)

            # Which client will be used? VECTOR/BOOLEAN need a 23ai+ client, native JSON 21c+.
            $r = Invoke-DuckDB -Name 'client23' -Unsigned -ExtraArgs @('-csv', '-noheader') -Sql @"
LOAD $(SqlLit $ExtSql);
SELECT coalesce(client_version, 'none') FROM oracle_client_info();
"@
            $clientVer = ($r.Out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
            if ($clientVer) { $clientVer = $clientVer.Trim() }
            $clientMajor = 0
            if ($clientVer -match '^(\d+)\.') { $clientMajor = [int]$Matches[1] }
            Write-Host ("Oracle client in use: {0}" -f $clientVer)

            Write-Section '4a. 23ai/26ai: SELECT * FROM dual + server version'
            $r = Invoke-DuckDB -Name 'dual23' -Unsigned -Sql @"
LOAD $(SqlLit $ExtSql);
SELECT * FROM $($q23 -f (SqlLit 'SELECT * FROM dual'));
SELECT * FROM $($q23 -f (SqlLit 'SELECT banner_full FROM v$version'));
"@
            Add-Result '23ai: dual' $(if ($r.Code -eq 0) { 'PASS' } else { 'FAIL' }) (Format-ExitCode $r.Code)

            Write-Section '4b. 23ai/26ai: 19c type-coverage query must behave identically'
            $tq23 = $q23 -f (SqlLit $typesSql)
            $r = Invoke-DuckDB -Name 'types23' -Unsigned -Sql @"
LOAD $(SqlLit $ExtSql);
.mode line
SELECT num_int = 42 AND num_dec = 12345.67 AND vc = 'hello' AND d = TIMESTAMP '2024-02-29 00:00:00'
       AND ts = TIMESTAMP '2024-02-29 13:45:30.123456' AND tstz = TIMESTAMPTZ '2024-01-01 04:30:00+00'
       AND clob_col = 'clob text' AND blob_col = '\xCA\xFE\xBA\xBE'::BLOB AND null_int IS NULL AS ok_19c_types_on_23ai
FROM $tq23;
"@
            $ok = $r.Code -eq 0 -and $r.Out -match 'ok_19c_types_on_23ai\s*=\s*true'
            Add-Result '23ai: 19c types' $(if ($ok) { 'PASS' } else { 'FAIL' }) (Format-ExitCode $r.Code)

            if ($clientMajor -lt 23) {
                Write-Warning ("Client {0} is older than 23ai: skipping BOOLEAN/JSON/VECTOR checks. Put a 23ai/26ai x64 Instant Client first on PATH or set DUCKDB_ORACLE_CLIENT_LIB_DIR." -f $clientVer)
                Add-Result '23ai: BOOLEAN/JSON/VECTOR' 'SKIP' ("client " + $clientVer + " < 23")
            } else {
                $newSql = @"
SELECT
  TRUE                                                AS b_true,
  FALSE                                               AS b_false,
  CAST(NULL AS BOOLEAN)                               AS b_null,
  JSON('{"a":1,"b":[true,null,"x"],"c":{"d":1.5}}')   AS j,
  CAST(NULL AS JSON)                                  AS j_null,
  TO_VECTOR('[1.5,2,3]', 3, FLOAT32)                  AS v32,
  TO_VECTOR('[1.5,2,3]', 3, FLOAT64)                  AS v64,
  TO_VECTOR('[1,-2,3]', 3, INT8)                      AS vi8,
  CAST(NULL AS VECTOR(3, FLOAT32))                    AS v_null
FROM dual
"@
                $nq = $q23 -f (SqlLit $newSql)
                Write-Section '4c. 23ai/26ai: BOOLEAN / JSON / VECTOR mapping'
                $r = Invoke-DuckDB -Name 'new23' -Unsigned -Sql @"
LOAD $(SqlLit $ExtSql);
.mode box
SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM $nq);
.mode line
SELECT * FROM $nq;
SELECT
  b_true = true AND b_false = false AND b_null IS NULL                   AS ok_boolean,
  json_extract(j, '$.a')::INTEGER = 1
    AND json_extract_string(j, '$.b[2]') = 'x'
    AND json_extract(j, '$.b[0]')::BOOLEAN = true
    AND json_extract(j, '$.c.d')::DOUBLE = 1.5                           AS ok_json,
  j_null IS NULL                                                          AS ok_json_null,
  v32 = [1.5, 2, 3]::FLOAT[] AND typeof(v32) = 'FLOAT[]'                 AS ok_vector_float32,
  v64 = [1.5, 2, 3]::DOUBLE[] AND typeof(v64) = 'DOUBLE[]'               AS ok_vector_float64,
  vi8 = [1, -2, 3]::FLOAT[]                                               AS ok_vector_int8,
  v_null IS NULL                                                          AS ok_vector_null
FROM $nq;
.mode csv
SELECT count(*) AS n, sum(v[1]) AS s1, sum(v[2]) AS s2, count(*) FILTER (WHERE len(v) = 2) AS len2
FROM $($q23 -f (SqlLit "SELECT TO_VECTOR('[' || level || ',' || (2*level) || ']', 2, FLOAT32) AS v FROM dual CONNECT BY level <= 3000"));
"@
                $okLines = @($r.Out -split "`r?`n" | Where-Object { $_ -match '^\s*ok_\w+\s*=' })
                $bad = @($okLines | Where-Object { $_ -notmatch '=\s*true\s*$' })
                # 3000 rows (2 DuckDB chunks): sum(1..3000)=4501500, doubled 9003000
                $multi = $r.Out -match '3000,4501500\.0,9003000\.0,3000'
                if ($r.Code -eq 0 -and $okLines.Count -eq 7 -and $bad.Count -eq 0 -and $multi) {
                    Add-Result '23ai: BOOLEAN/JSON/VECTOR' 'PASS' '7 checks true + 3000-row VECTOR list'
                } else {
                    Add-Result '23ai: BOOLEAN/JSON/VECTOR' 'FAIL' ("exit " + (Format-ExitCode $r.Code) + "; multi-chunk=" + $multi + "; not true: " + (($bad | ForEach-Object { $_.Trim() }) -join '; '))
                }
            }
        } finally {
            $env:ORACLE_PASSWORD = $savedPw
        }
    }
}

# --- summary -----------------------------------------------------------------
Write-Section 'Summary'
$Results | Format-Table -AutoSize -Wrap | Out-String | Write-Host
$failed = @($Results | Where-Object { $_.Status -eq 'FAIL' })
if ($failed.Count -gt 0) {
    Write-Host ("{0} step(s) FAILED" -f $failed.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'All executed steps passed.' -ForegroundColor Green
exit 0
