<#
.SYNOPSIS
    duckdb-oracle test for Windows: stock DuckDB CLI + the shipped duckdb-oracle extension + (optionally) the
    end-to-end SQL tests in test/e2e against a real Oracle database. The same script runs locally and in CI
    (.github/workflows/windows.yml and e2e-oracle19c.yml), so the runs are identical.

.DESCRIPTION
    1. Downloads the official DuckDB CLI for the version pinned in tools/duckdb-cli-pins.json and verifies its
       SHA-256 (or uses the binary given with -DuckDB). The CLI found on PATH is never used.
    2. Unpacks the shipped package duckdb_oracle-windows_<arch>.zip (default: next to this script; -Extension takes a
       zip or a file already named duckdb_oracle.duckdb_extension - nothing is renamed) and verifies that the stock
       CLI does NOT already contain duckdb_oracle.
    3. Checks which oci.dll the extension will load (same search policy as the extension itself) and whether it is
       64-bit, and detects Windows on ARM and any architecture mismatch between duckdb.exe, the extension and oci.dll.
    4. LOADs duckdb_oracle.duckdb_extension with -unsigned, shows duckdb_extensions() and oracle_client_info().
    5. Unless -SkipOracle: waits for the database (-WaitForDatabase), then runs every test/e2e/*.sql against it:
       SELECT FROM dual, one test per mapped type, NULLs, a multi-batch fetch, LIMIT early termination, and Oracle
       errors that must surface ORA- codes while the process keeps running.
    6. Optional: if $env:ORACLE_DSN_23AI is set, the same tests plus test/e2e/23ai (BOOLEAN / JSON / VECTOR) against
       a 23ai/26ai database (for example gvenzl/oracle-free on localhost:1522/FREEPDB1).
    Every DuckDB run prints its exit code in decimal and hex, so an access violation shows up as 0xC0000005. Each run
    has a timeout so a hang is reported instead of blocking forever.

    -Strict is the CI mode: a skipped Oracle step, a missing or wrong-architecture oci.dll and architecture warnings
    are failures instead of warnings.

    The password is read ONLY from $env:ORACLE_PASSWORD, by the extension itself. It is never placed on a command
    line or in a SQL file, and it is removed from any output before printing. Set it without echoing, e.g.:
        $s = Read-Host 'Oracle password' -AsSecureString
        $env:ORACLE_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
    The connect string and user come from -Dsn / -User, else $env:ORACLE_DSN / $env:ORACLE_USER.

.EXAMPLE
    .\test-windows.ps1 -SkipOracle                 # load test only (what windows.yml runs)
.EXAMPLE
    .\test-windows.ps1 -Dsn dbhost:1521/ORCLPDB1 -User SCOTT      # plus the end-to-end tests
.EXAMPLE
    .\test-windows.ps1 -Strict -WaitForDatabase 300 -Extension .\duckdb_oracle-windows_amd64.zip   # what e2e-oracle19c.yml runs
.EXAMPLE
    .\test-windows.ps1 -DuckDB C:\tools\duckdb.exe -Extension .\duckdb_oracle-windows_amd64.zip
#>
[CmdletBinding()]
param(
    [string]$Extension = '',
    [string]$DuckDB = '',
    [string]$Dsn = $(if ($env:ORACLE_DSN) { $env:ORACLE_DSN } else { 'localhost:1521/ORCLPDB1' }),
    [string]$User = $(if ($env:ORACLE_USER) { $env:ORACLE_USER } else { 'SAMPLE_DEV' }),
    [switch]$SkipOracle,
    # CI mode: skipped Oracle steps, a missing / wrong-architecture oci.dll and architecture warnings fail the run.
    [switch]$Strict,
    # Seconds to wait for the database to answer SELECT 1 FROM dual before the tests start (0 = do not wait).
    [int]$WaitForDatabase = 0,
    [int]$TimeoutSeconds = 120,
    # Directory with the end-to-end SQL tests (shared with the CI workflow).
    [string]$E2EDir = '',
    # DuckDB CLI release to download. Default: the version pinned in -PinFile. Another version has no pinned
    # checksum and needs -SkipChecksum.
    [string]$DuckDBVersion = '',
    [string]$PinFile = '',
    [switch]$SkipChecksum,
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

function Test-HasSecret([string]$Text) {
    foreach ($secret in @($env:ORACLE_PASSWORD, $env:ORACLE_PASSWORD_23AI)) {
        if ($secret -and $secret.Length -ge 4 -and $Text -and $Text.Contains($secret)) { return $true }
    }
    return $false
}

function Hide-Secrets([string]$Text) {
    # The password never goes on a command line or into SQL; this also keeps it out of anything printed.
    foreach ($secret in @($env:ORACLE_PASSWORD, $env:ORACLE_PASSWORD_23AI)) {
        if ($secret -and $secret.Length -ge 4 -and $Text) { $Text = $Text.Replace($secret, '***') }
    }
    return $Text
}

function Invoke-DuckDB {
    # Runs the CLI on a SQL file (no SQL on the command line), with a timeout.
    param([string]$Name, [string]$Sql, [switch]$Unsigned, [string[]]$ExtraArgs = @(), [int]$Timeout = 0, [switch]$Quiet)
    if ($Timeout -le 0) { $Timeout = $TimeoutSeconds }
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
    $timedOut = -not $p.WaitForExit($Timeout * 1000)
    if ($timedOut) {
        try { $p.Kill() } catch { }
        $code = -1
    } else {
        $p.WaitForExit()
        $code = [int]$p.ExitCode
    }
    $rawOut = $(if (Test-Path $outFile) { [IO.File]::ReadAllText($outFile) } else { '' })
    $rawErr = $(if (Test-Path $errFile) { [IO.File]::ReadAllText($errFile) } else { '' })
    $leaked = (Test-HasSecret $rawOut) -or (Test-HasSecret $rawErr)   # checked BEFORE redaction
    $stdout = Hide-Secrets $rawOut
    $stderr = Hide-Secrets $rawErr
    if (-not $Quiet) {
        if ($stdout) { Write-Host $stdout.TrimEnd() }
        if ($stderr) { Write-Host $stderr.TrimEnd() -ForegroundColor Yellow }
        if ($timedOut) {
            Write-Host ("TIMEOUT after {0}s (process killed) - treat as a hang" -f $Timeout) -ForegroundColor Red
        } else {
            Write-Host ('exit code: ' + (Format-ExitCode $code))
        }
    }
    return [pscustomobject]@{ Code = $code; TimedOut = $timedOut; Out = $stdout; Err = $stderr; Leaked = $leaked }
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
# The version and the SHA-256 of each official release asset are pinned in tools/duckdb-cli-pins.json (the one
# place shared with the CI workflows). The CLI is downloaded and verified here; a duckdb.exe on PATH is never used.
function Get-DuckDBPin {
    $candidates = @()
    if ($PinFile) { $candidates += $PinFile }
    $candidates += (Join-Path $PSScriptRoot 'tools\duckdb-cli-pins.json')
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return (Get-Content -Raw -LiteralPath $c | ConvertFrom-Json) }
    }
    return $null
}
$Pin = Get-DuckDBPin
# No second copy of the version lives in this script: it comes from the pin file (or -DuckDBVersion).
if (-not $DuckDBVersion -and $Pin) { $DuckDBVersion = $Pin.version }

Write-Section ('Stock DuckDB CLI ' + $(if ($DuckDBVersion) { $DuckDBVersion } else { '(version not pinned)' }))
$script:DuckDBExe = $null
if ($DuckDB) {
    $script:DuckDBExe = (Resolve-Path $DuckDB).Path
    Write-Host "Using the DuckDB CLI given with -DuckDB (no download, no checksum check): $script:DuckDBExe"
} else {
    if (-not $DuckDBVersion) { throw 'tools\duckdb-cli-pins.json was not found next to this script, so there is no pinned DuckDB version. Pass -PinFile, or -DuckDB <your duckdb.exe>, or -DuckDBVersion together with -SkipChecksum.' }
    $zipName = if ($DuckDBArch -eq 'arm64') { 'duckdb_cli-windows-arm64.zip' } else { 'duckdb_cli-windows-amd64.zip' }
    $wantHash = $null
    if ($Pin -and $Pin.version -eq $DuckDBVersion) {
        $prop = $Pin.sha256.PSObject.Properties[$zipName]
        if ($prop) { $wantHash = ([string]$prop.Value).ToLowerInvariant() }
    }
    if (-not $wantHash -and -not $SkipChecksum) {
        throw ("No pinned SHA-256 for {0} {1} (pin file: tools\duckdb-cli-pins.json{2}). Use the pinned version, or pass -SkipChecksum to download it unverified." -f $zipName, $DuckDBVersion, $(if ($Pin) { '' } else { ' - NOT FOUND next to this script; pass -PinFile' }))
    }
    $url = "https://github.com/duckdb/duckdb/releases/download/$DuckDBVersion/$zipName"
    $dir = Join-Path $WorkDir "duckdb-$DuckDBVersion-$DuckDBArch"
    $zip = Join-Path $WorkDir ("$DuckDBVersion-$zipName")
    $haveZip = $false
    if (Test-Path -LiteralPath $zip) {
        # a cached download is reused only if it still matches the pinned checksum
        if ($wantHash -and ((Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant() -eq $wantHash)) { $haveZip = $true }
        else { Remove-Item -Force -LiteralPath $zip; if (Test-Path $dir) { Remove-Item -Recurse -Force $dir } }
    }
    if (-not $haveZip) {
        Write-Host "Downloading $url"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
        $gotHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
        if ($wantHash) {
            if ($gotHash -ne $wantHash) {
                Remove-Item -Force -LiteralPath $zip
                Add-Result 'duckdb checksum' 'FAIL' ("{0}: downloaded {1}, pinned {2}" -f $zipName, $gotHash, $wantHash)
                throw ("CHECKSUM MISMATCH for {0} {1}`n  pinned:     {2}`n  downloaded: {3}" -f $zipName, $DuckDBVersion, $wantHash, $gotHash)
            }
        } else {
            Write-Warning "-SkipChecksum: $zipName $DuckDBVersion was NOT verified (sha256 $gotHash)"
        }
    }
    if ($wantHash) { Write-Host ("SHA-256 verified against tools\duckdb-cli-pins.json: {0}" -f $wantHash); Add-Result 'duckdb checksum' 'PASS' ($zipName + ' ' + $DuckDBVersion) }
    $exe = Join-Path $dir 'duckdb.exe'
    if (-not (Test-Path $exe)) { Expand-Archive -Path $zip -DestinationPath $dir -Force }
    $script:DuckDBExe = $exe
}
$eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$verText = ((& $script:DuckDBExe -version) 2>&1 | Out-String).Trim()
$ErrorActionPreference = $eap
$CliArch = Get-PeMachine $script:DuckDBExe
Write-Host ('DuckDB CLI     : {0}' -f $script:DuckDBExe)
Write-Host ('Version        : {0}' -f $verText)
Write-Host ('CLI arch       : {0}{1}' -f $CliArch, $(if ($HostArch -eq 'ARM64' -and $CliArch -eq 'x64') { ' (runs under x64 emulation on this ARM64 host)' } else { '' }))
if (-not $DuckDBVersion) {
    Add-Result 'duckdb version' 'PASS' ($verText + ' (no pinned version to compare with)')
} elseif ($verText -notmatch [regex]::Escape($DuckDBVersion)) {
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
# Mirrors the extension's own search (src/client_locator.zig):
#   1) $env:DUCKDB_ORACLE_CLIENT_LIB_DIR, and nothing else, if it is set;
#   2) otherwise the extension's directory, duckdb.exe's directory, then each ABSOLUTE entry of PATH.
# The current directory, System32 and relative PATH entries are never searched. The extension skips an oci.dll of the
# wrong architecture and goes on; this script is stricter on purpose: the FIRST one must match duckdb.exe, so that
# the setup is unambiguous.
$candidates = New-Object System.Collections.ArrayList
$libDirOverride = $env:DUCKDB_ORACLE_CLIENT_LIB_DIR
if ($libDirOverride) {
    Write-Host "DUCKDB_ORACLE_CLIENT_LIB_DIR is set: the extension will ONLY look in $libDirOverride"
    $null = $candidates.Add([pscustomobject]@{ Source = 'DUCKDB_ORACLE_CLIENT_LIB_DIR'; Dir = $libDirOverride })
} else {
    $null = $candidates.Add([pscustomobject]@{ Source = 'extension dir'; Dir = (Split-Path $Extension) })
    $null = $candidates.Add([pscustomobject]@{ Source = 'duckdb.exe dir'; Dir = (Split-Path $script:DuckDBExe) })
    $i = 0
    foreach ($d in ($env:PATH -split [regex]::Escape([IO.Path]::PathSeparator))) {
        $i++
        $d = $d.Trim().Trim('"')
        if (-not $d) { continue }
        # relative entries are never searched: on Windows only X:\ and \\server paths are absolute
        $isAbsolute = $(if ($env:OS -eq 'Windows_NT') { $d -match '^([A-Za-z]:[\\/]|\\\\)' } else { [IO.Path]::IsPathRooted($d) })
        if (-not $isAbsolute) { continue }
        $null = $candidates.Add([pscustomobject]@{ Source = "PATH[$i]"; Dir = $d })
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
$ociBad = $(if ($Strict) { 'FAIL' } else { 'WARN' })
if ($found.Count -eq 0) {
    Write-Warning 'No oci.dll found. LOAD will still work, but oracle_query() will fail with DPI-1047.'
    Add-Result 'oci.dll' $ociBad 'not found: put the x64 Oracle Instant Client directory on PATH (or set DUCKDB_ORACLE_CLIENT_LIB_DIR)'
} else {
    Write-Host 'oci.dll candidates in search order:'
    $found | Format-Table -AutoSize | Out-String | Write-Host
    $first = $found[0]
    $OciArch = $first.Arch
    Write-Host ('First oci.dll (expected to be loaded): {0} [{1}, {2}]' -f $first.Path, $first.Arch, $first.Version)
    if ($first.Arch -ne $CliArch) {
        $msg = ('The first oci.dll is {0}, but duckdb.exe is {1}. They must match. ' -f $first.Arch, $CliArch) +
            'Put the matching Instant Client first on PATH, or set $env:DUCKDB_ORACLE_CLIENT_LIB_DIR to its directory.'
        Write-Warning $msg
        Add-Result 'oci.dll' $ociBad ('first is ' + $first.Arch + ' (duckdb.exe is ' + $CliArch + '): ' + $first.Path + ' - ' + $msg)
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
    Add-Result 'architecture' $(if ($Strict) { 'FAIL' } else { 'WARN' }) ($archProblems -join ' | ')
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

# --- end-to-end SQL tests (test/e2e) ----------------------------------------
# Each *.sql file in test/e2e is run in its own DuckDB process, after LOADing the extension. They are shared with
# the CI workflow (e2e-oracle19c.yml), which runs this script, so local and CI runs are identical.
#   @DSN@ in the SQL is replaced by the connect string. The login comes from ORACLE_USER / ORACLE_PASSWORD in the
#   environment; no password ever appears in SQL or on a command line.
# Header comments in a test file control how it is judged:
#   -- e2e: <title>              shown in the log
#   -- expect-error: <regex>     the run must fail with a DuckDB error (exit 1) whose output matches; repeatable.
#                                The file starts with ".bail off" so later statements still run, which is how a test
#                                shows that the process survives Oracle errors. A crash or hang fails.
#   -- expect-output: <regex>    the output must match; repeatable
#   -- timeout: <seconds>        per-file limit (default: -TimeoutSeconds)
#   -- optional                  a failure is a warning (for example when an account may not see a view)
# Without expect-error a file passes if DuckDB exits 0; its SQL asserts with error(), which fails the run.
function Read-E2EDirectives([string]$Text) {
    $d = [pscustomobject]@{ Title = ''; ExpectError = @(); ExpectOutput = @(); Timeout = 0; Optional = $false }
    foreach ($line in ($Text -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -eq '') { continue }
        if (-not $t.StartsWith('--')) { break }
        if ($t -match '^--\s*e2e:\s*(.+)$') { $d.Title = $Matches[1].Trim() }
        elseif ($t -match '^--\s*expect-error:\s*(.+)$') { $d.ExpectError += $Matches[1].Trim() }
        elseif ($t -match '^--\s*expect-output:\s*(.+)$') { $d.ExpectOutput += $Matches[1].Trim() }
        elseif ($t -match '^--\s*timeout:\s*(\d+)\s*$') { $d.Timeout = [int]$Matches[1] }
        elseif ($t -match '^--\s*optional\s*$') { $d.Optional = $true }
    }
    return $d
}

function Invoke-E2ESuite {
    param([string]$Dir, [string]$Group, [string]$SuiteDsn)
    $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.sql' -File | Sort-Object Name)
    if ($files.Count -eq 0) { Add-Result "e2e $Group" 'FAIL' "no .sql files in $Dir"; return }
    foreach ($f in $files) {
        $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
        $d = Read-E2EDirectives $text
        $title = $(if ($d.Title) { $d.Title } else { $f.BaseName })
        $name = ('{0}/{1}' -f $Group, $f.BaseName)
        Write-Section ('e2e {0}: {1}' -f $name, $title)
        $sql = ('LOAD {0};' -f (SqlLit $ExtSql)) + "`n" + $text.Replace('@DSN@', $SuiteDsn.Replace("'", "''"))
        $timeout = $(if ($d.Timeout -gt 0) { $d.Timeout } else { $TimeoutSeconds })
        $r = Invoke-DuckDB -Name ('e2e-' + $Group + '-' + $f.BaseName) -Unsigned -Sql $sql -Timeout $timeout
        $combined = $r.Out + "`n" + $r.Err
        $problems = @()
        if ($r.TimedOut) { $problems += 'TIMEOUT (hang)' }
        elseif ($d.ExpectError.Count -gt 0) {
            if ($r.Code -ne 1) { $problems += ('expected a DuckDB error (exit code 1), got exit code ' + (Format-ExitCode $r.Code)) }
        }
        elseif ($r.Code -ne 0) { $problems += ('exit code ' + (Format-ExitCode $r.Code)) }
        foreach ($rx in (@($d.ExpectError) + @($d.ExpectOutput))) {
            if ($combined -notmatch $rx) { $problems += ('output does not match /' + $rx + '/') }
        }
        if ($r.Leaked) { $problems += 'THE PASSWORD APPEARED IN THE OUTPUT (it is redacted in this log)' }
        $failedChecks = @($r.Err -split "`r?`n" | Where-Object { $_ -match 'FAILED:' } | ForEach-Object { $_.Trim() })
        $status = $(if ($problems.Count -eq 0) { 'PASS' } elseif ($d.Optional) { 'WARN' } else { 'FAIL' })
        $detail = $(if ($problems.Count -eq 0) { (Format-ExitCode $r.Code) } else { ($problems + $failedChecks) -join '; ' })
        Add-Result ('e2e ' + $name) $status $detail
    }
}

function Wait-ForDatabase([string]$WaitDsn, [int]$Seconds) {
    # Polls oracle_query('SELECT 1 FROM dual') through the extension until it succeeds or the time is up.
    $deadline = (Get-Date).AddSeconds($Seconds)
    $attempt = 0
    $last = ''
    $sql = ('LOAD {0};' -f (SqlLit $ExtSql)) + "`n" + ("SELECT * FROM oracle_query({0}, 'SELECT 1 FROM dual');" -f (SqlLit $WaitDsn))
    Write-Host ("Waiting up to {0}s for the database at {1} ..." -f $Seconds, $WaitDsn)
    while ($true) {
        $attempt++
        $r = Invoke-DuckDB -Name 'database-ready' -Unsigned -Sql $sql -Timeout 90 -Quiet
        if ($r.Code -eq 0 -and -not $r.TimedOut) {
            Write-Host ("Database is ready (attempt {0})." -f $attempt)
            return $true
        }
        $last = (($r.Err + "`n" + $r.Out) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($r.TimedOut) { $last = 'the attempt itself timed out' }
        if ((Get-Date) -ge $deadline) { break }
        Write-Host ("  attempt {0}: not ready yet ({1}); retrying in 10s" -f $attempt, $last)
        Start-Sleep -Seconds 10
    }
    Write-Host ("Database did not become ready within {0}s. Last error: {1}" -f $Seconds, $last) -ForegroundColor Red
    return $false
}

if ($SkipOracle) {
    Write-Section 'Oracle end-to-end tests: skipped (-SkipOracle)'
    Add-Result 'oracle e2e' 'SKIP' '-SkipOracle'
} elseif (-not $env:ORACLE_PASSWORD) {
    Write-Section 'Oracle end-to-end tests: not run'
    Write-Warning 'ORACLE_PASSWORD is not set. Set it without echoing (see Get-Help .\test-windows.ps1) and re-run.'
    Add-Result 'oracle e2e' $(if ($Strict) { 'FAIL' } else { 'SKIP' }) 'ORACLE_PASSWORD not set'
} else {
    if (-not $E2EDir) { $E2EDir = Join-Path $PSScriptRoot 'test\e2e' }
    if (-not (Test-Path -LiteralPath $E2EDir)) {
        Write-Section 'Oracle end-to-end tests: not run'
        Write-Warning "End-to-end tests not found at $E2EDir (run this script from a repository checkout, or pass -E2EDir)."
        Add-Result 'oracle e2e' $(if ($Strict) { 'FAIL' } else { 'SKIP' }) "test directory not found: $E2EDir"
    } else {
        $env:ORACLE_USER = $User     # the extension reads the login from the environment
        Write-Host ("DSN: {0}   user: {1}   password: from `$env:ORACLE_PASSWORD (not shown)" -f $Dsn, $User)
        $ready = $true
        if ($WaitForDatabase -gt 0) {
            Write-Section 'Waiting for the database'
            $ready = Wait-ForDatabase $Dsn $WaitForDatabase
            Add-Result 'database ready' $(if ($ready) { 'PASS' } else { 'FAIL' }) $(if ($ready) { $Dsn } else { "no answer from $Dsn within ${WaitForDatabase}s" })
        }
        if ($ready) { Invoke-E2ESuite -Dir $E2EDir -Group 'oracle' -SuiteDsn $Dsn }
    }
}

# --- optional: Oracle 23ai / 26ai database -----------------------------------
# Skipped unless $env:ORACLE_DSN_23AI is set, e.g. 'localhost:1522/FREEPDB1' for
#   docker run -d -p 1522:1521 -e ORACLE_PASSWORD=... gvenzl/oracle-free
# User:     $env:ORACLE_USER_23AI (default SYSTEM)
# Password: $env:ORACLE_PASSWORD_23AI (falls back to $env:ORACLE_PASSWORD). Handed to duckdb.exe only through its
#           environment (ORACLE_PASSWORD), never on a command line or in a SQL file.
# Runs the same test/e2e suite against that database, plus test/e2e/23ai when the loaded Oracle client is 23 or newer
# (BOOLEAN and VECTOR need a 23ai+ client, native JSON 21c+).
if (-not $env:ORACLE_DSN_23AI) {
    Write-Section 'Oracle 23ai/26ai section: skipped (ORACLE_DSN_23AI not set)'
    Add-Result '23ai/26ai section' 'SKIP' 'ORACLE_DSN_23AI not set'
} else {
    $dsn23 = $env:ORACLE_DSN_23AI
    $user23 = $(if ($env:ORACLE_USER_23AI) { $env:ORACLE_USER_23AI } else { 'SYSTEM' })
    $pw23 = $(if ($env:ORACLE_PASSWORD_23AI) { $env:ORACLE_PASSWORD_23AI } else { $env:ORACLE_PASSWORD })
    if (-not $E2EDir) { $E2EDir = Join-Path $PSScriptRoot 'test\e2e' }
    if (-not $pw23) {
        Write-Section 'Oracle 23ai/26ai section: skipped'
        Write-Warning 'Set $env:ORACLE_PASSWORD_23AI (or ORACLE_PASSWORD) for the 23ai/26ai database.'
        Add-Result '23ai/26ai section' 'SKIP' 'no password in environment'
    } elseif (-not (Test-Path -LiteralPath $E2EDir)) {
        Add-Result '23ai/26ai section' 'SKIP' "test directory not found: $E2EDir"
    } else {
        $savedUser = $env:ORACLE_USER
        $savedPw = $env:ORACLE_PASSWORD
        try {
            $env:ORACLE_USER = $user23
            $env:ORACLE_PASSWORD = $pw23   # inherited by duckdb.exe only
            Write-Section 'Oracle 23ai/26ai database'
            Write-Host ("DSN: {0}   user: {1}   password: from environment (not shown)" -f $dsn23, $user23)

            $r = Invoke-DuckDB -Name 'client23' -Unsigned -ExtraArgs @('-csv', '-noheader') -Quiet -Sql @"
LOAD $(SqlLit $ExtSql);
SELECT coalesce(client_version, 'none') FROM oracle_client_info();
"@
            $clientVer = ($r.Out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
            if ($clientVer) { $clientVer = $clientVer.Trim() }
            $clientMajor = 0
            if ($clientVer -match '^(\d+)\.') { $clientMajor = [int]$Matches[1] }
            Write-Host ("Oracle client in use: {0}" -f $clientVer)

            Invoke-E2ESuite -Dir $E2EDir -Group 'oracle23ai' -SuiteDsn $dsn23
            $dir23 = Join-Path $E2EDir '23ai'
            if ($clientMajor -lt 23) {
                Write-Warning ("Client {0} is older than 23ai: skipping BOOLEAN/JSON/VECTOR tests. Put a 23ai/26ai x64 Instant Client first on PATH or set DUCKDB_ORACLE_CLIENT_LIB_DIR." -f $clientVer)
                Add-Result '23ai: BOOLEAN/JSON/VECTOR' 'SKIP' ("client " + $clientVer + " < 23")
            } elseif (Test-Path -LiteralPath $dir23) {
                Invoke-E2ESuite -Dir $dir23 -Group 'oracle23ai-types' -SuiteDsn $dsn23
            }
        } finally {
            $env:ORACLE_USER = $savedUser
            $env:ORACLE_PASSWORD = $savedPw
        }
    }
}

# --- summary -----------------------------------------------------------------
Write-Section 'Summary'
$Results | Format-Table -AutoSize -Wrap | Out-String | Write-Host
$failed = @($Results | Where-Object { $_.Status -eq 'FAIL' })
$exitCode = 0
if ($failed.Count -gt 0) {
    Write-Host ("{0} step(s) FAILED" -f $failed.Count) -ForegroundColor Red
    foreach ($f in $failed) { Write-Host ("  FAILED: {0}: {1}" -f $f.Step, $f.Detail) -ForegroundColor Red }
    $exitCode = 1
} else {
    Write-Host 'All executed steps passed.' -ForegroundColor Green
}
Write-Host ('test-windows.ps1 exit code: ' + (Format-ExitCode $exitCode))
exit $exitCode
