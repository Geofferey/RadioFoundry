# SPDX-License-Identifier: MIT
# Copyright (c) 2026 The RadioFoundry Authors
#
# Drives the debug link from Windows: picks the serial port, runs tools/rfoundry_debug.py against it, and keeps every
# line in a log.
#
# The debug link runs on the radio's host port (docs/dev/debug-link.md). On a radio without USB that is the
# programming cable, a CH340 or FTDI, which Windows gives a COM number and WSL does not see at all: a WSL
# distribution has no /dev/ttyUSB*, so the firmware is built in WSL (tools\build.ps1) and talked to from Windows,
# here. Both halves read the same tree.
#
# Everything it prints is also appended to build\debug.log, with the command and a time stamp, so a session can be
# read back whole afterwards - by you, or by an agent helping you read it.
#
#   tools\debug.ps1                        pick a port, then pick from the usual commands
#   tools\debug.ps1 version                the firmware version, board and feature switches
#   tools\debug.ps1 diag --watch 1         the counters once a second, until Ctrl+C
#   tools\debug.ps1 log --follow           the firmware's dlog() ring, as it is written
#   tools\debug.ps1 view --section core    the radio state as key=value (--json for a script)
#   tools\debug.ps1 screenshot -o shot.png --scale 3
#   tools\debug.ps1 -Ports                 list the serial ports and exit
#
# Options:
#   -Port <COMn>   the port to use, instead of asking or remembering
#   -Log <path>    a log of your own (default build\debug.log)
#   -NoLog         do not write a log
#   -Ports         list the serial ports and exit
#
# Those four are matched in full and are not case sensitive. Everything else is passed to rfoundry_debug.py
# untouched, so every command and switch it has works here: `rfoundry_debug.py --help` lists them. `--` passes the
# rest through even if it looks like one of the four. The safety limits are the firmware's and the tool's, not this
# script's: injected PTT stops on its own, and the HIL tests are the ones that need --allow-rf.
#
# The arguments are read here rather than declared in a param() block on purpose. A param() block makes PowerShell
# bind them, and PowerShell matches a parameter on any unambiguous prefix and adds its own common parameters on top,
# so `-o shot.png` (rfoundry_debug.py's output file) is refused as an ambiguous prefix of -OutVariable and -OutBuffer,
# and -v, -d and -e would go the same way. A wrapper that forwards arbitrary options cannot let that happen.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Port = ''
$Log = ''
$NoLog = $false
$Ports = $false
$DebugArgs = @()

for ($i = 0; $i -lt $args.Count; $i++) {
	$a = [string]$args[$i]
	switch -Exact ($a.ToLowerInvariant()) {
		'-port' {
			if ($i + 1 -ge $args.Count) { Write-Host 'debug: -Port needs a port name' -ForegroundColor Red; exit 2 }
			$Port = [string]$args[++$i]
		}
		'-log' {
			if ($i + 1 -ge $args.Count) { Write-Host 'debug: -Log needs a path' -ForegroundColor Red; exit 2 }
			$Log = [string]$args[++$i]
		}
		'-nolog' { $NoLog = $true }
		'-ports' { $Ports = $true }
		'--' {
			# Everything after this is the tool's, whatever it looks like
			if ($i + 1 -lt $args.Count) { $DebugArgs += $args[($i + 1)..($args.Count - 1)] }
			$i = $args.Count
		}
		default { $DebugArgs += $a }
	}
}
$DebugArgs = @($DebugArgs)

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Tool = Join-Path $Root 'tools\rfoundry_debug.py'
if (-not (Test-Path $Tool)) { Write-Host "debug: no $Tool" -ForegroundColor Red; exit 2 }

function Fail($m) { Write-Host "debug: $m" -ForegroundColor Red; exit 2 }
function Info($m) { Write-Host "debug: $m" -ForegroundColor Cyan }

# Read-Host throws when there is no console to type at (a non-interactive host, a script, an agent running this).
# Asking is then the wrong thing to do, so each caller passes what to use instead.
function Read-Choice($Prompt, $Default) {
	try {
		return Read-Host $Prompt
	} catch {
		Info "nothing to type at here, so taking '$Default' (pass it explicitly to choose)"
		return $Default
	}
}

# ------------------------------------------------------------------ Python
# Windows Python, never the WSL one: the COM port only exists on this side. pyserial is the one dependency.
$Py = $null
foreach ($c in 'python', 'python3', 'py') {
	$cmd = Get-Command $c -ErrorAction SilentlyContinue
	if (-not $cmd) { continue }
	# The Microsoft Store stub answers to the name but runs nothing
	& $cmd.Source -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>$null
	if ($LASTEXITCODE -eq 0) { $Py = $cmd.Source; break }
}
if (-not $Py) { Fail 'no usable Python 3 on PATH. Install Python 3 for Windows (python.org or winget install Python.Python.3.12)' }

& $Py -c 'import serial' 2>$null
if ($LASTEXITCODE -ne 0) {
	Info 'pyserial is missing; installing it for this Python'
	& $Py -m pip install --user pyserial
	& $Py -c 'import serial' 2>$null
	if ($LASTEXITCODE -ne 0) { Fail "could not import pyserial after installing it. Try: $Py -m pip install pyserial" }
}

# ------------------------------------------------------------------ the serial ports
# Win32_PnPEntity carries the friendly name ("USB-SERIAL CH340 (COM4)"); GetPortNames catches anything it misses.
function Get-SerialPorts {
	$named = @{}
	Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
		Where-Object { $_.Name -match '\((COM\d+)\)' } |
		ForEach-Object {
			$null = $_.Name -match '\((COM\d+)\)'
			$named[$Matches[1]] = $_.Name
		}
	$all = @()
	# GetPortNames reads the registry and repeats a port that is listed more than once there, so normalize and
	# make the names unique before anything is shown or counted
	try { $all = @([System.IO.Ports.SerialPort]::GetPortNames()) } catch { $all = @() }
	$all = @($all | Where-Object { $_ } | ForEach-Object { $_.Trim().ToUpper() } | Sort-Object -Unique)
	foreach ($k in $named.Keys) { if ($all -notcontains $k) { $all += $k } }

	$all | Sort-Object -Unique | Sort-Object { [int]($_ -replace '\D', '') } | ForEach-Object {
		$name = if ($named.ContainsKey($_)) { $named[$_] } else { $_ }
		# A programming cable is one of these bridges. A Bluetooth or motherboard port never is, so it sorts last.
		$likely = $name -match 'CH340|CH910|FTDI|FT232|CP210|PL2303|Prolific|USB.?SERIAL|Silicon Labs'
		[pscustomobject]@{ Port = $_; Name = $name; Likely = $likely }
	}
}

$found = @(Get-SerialPorts)

if ($Ports) {
	if (-not $found) { Write-Host "`nNo serial ports found.`n"; exit 1 }
	Write-Host "`nSerial ports:`n"
	foreach ($p in $found) {
		$mark = if ($p.Likely) { '  <- programming cable?' } else { '' }
		Write-Host ("    {0,-6} {1}{2}" -f $p.Port, $p.Name, $mark)
	}
	Write-Host ''
	exit 0
}

# The port last used, so a session of several commands only asks once
$remember = Join-Path $Root 'build\.debug-port'

if (-not $Port) {
	if (-not $found) {
		Fail @'
no serial ports found. Plug the programming cable in and check Device Manager shows it
(a CH340 or FTDI under Ports). On a radio with no USB the cable IS the host port.
'@
	}
	$likely = @($found | Where-Object { $_.Likely })
	$last = if (Test-Path $remember) { (Get-Content $remember -First 1).Trim() } else { '' }

	if ($last -and ($found.Port -contains $last)) {
		$Port = $last
		Info "using $Port (last used; -Port or delete build\.debug-port to change)"
	} elseif ($likely.Count -eq 1) {
		$Port = $likely[0].Port
		Info "using $Port ($($likely[0].Name)) - the only cable that looks like a programming cable"
	} else {
		# More than one candidate, or none obvious: ask.
		Write-Host "`nWhich serial port is the radio on?`n"
		for ($i = 0; $i -lt $found.Count; $i++) {
			$p = $found[$i]
			$mark = if ($p.Likely) { '  <- programming cable?' } else { '' }
			Write-Host ("    [{0}] {1,-6} {2}{3}" -f ($i + 1), $p.Port, $p.Name, $mark)
		}
		Write-Host ''
		# Without a console, the likeliest cable beats refusing to run
		$fallback = if ($likely.Count -ge 1) { $likely[0].Port } else { $found[0].Port }
		$pick = Read-Choice "Number (1-$($found.Count)), or a port name" $fallback
		if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $found.Count) {
			$Port = $found[[int]$pick - 1].Port
		} elseif ($found.Port -contains $pick.Trim().ToUpper()) {
			$Port = $pick.Trim().ToUpper()
		} else {
			Fail "'$pick' is not one of the ports listed"
		}
	}
}

$null = New-Item -ItemType Directory -Force -Path (Join-Path $Root 'build') -ErrorAction SilentlyContinue
Set-Content -Path $remember -Value $Port -Encoding ascii -ErrorAction SilentlyContinue

# ------------------------------------------------------------------ the command
if (-not $DebugArgs -or $DebugArgs.Count -eq 0) {
	# The read-only commands a bench session starts with (docs/dev/debug-link.md). Nothing here transmits.
	$menu = @(
		@{ Label = 'version      firmware version, board, feature switches'; Args = @('version') }
		@{ Label = 'diag         the counters once'; Args = @('diag') }
		@{ Label = 'diag --watch the counters once a second, until Ctrl+C'; Args = @('diag', '--watch', '1') }
		@{ Label = 'view core    the radio state as key=value'; Args = @('view', '--section', 'core') }
		@{ Label = 'log --follow the firmware dlog() ring, as it is written'; Args = @('log', '--follow') }
		@{ Label = 'screenshot   the display, to build\screen.png'; Args = @('screenshot', '-o', 'build\screen.png', '--scale', '3') }
		@{ Label = 'storage info whether the settings region is ours or foreign'; Args = @('storage', 'info') }
	)
	Write-Host "`nWhat should it ask the radio on $Port ?`n"
	for ($i = 0; $i -lt $menu.Count; $i++) {
		Write-Host ("    [{0}] {1}" -f ($i + 1), $menu[$i].Label)
	}
	Write-Host "`n    (or pass a command: tools\debug.ps1 <command> [switches])`n"
	# Without a console, version: it is read-only, quick, and the one command that proves the link at all
	$pick = Read-Choice "Number (1-$($menu.Count))" '1'
	if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $menu.Count) {
		$DebugArgs = $menu[[int]$pick - 1].Args
	} else {
		Fail "'$pick' is not one of the choices"
	}
}

# ------------------------------------------------------------------ run it
if (-not $Log) { $Log = Join-Path $Root 'build\debug.log' }

$argv = @('--port', $Port) + $DebugArgs
Info "$Port : rfoundry_debug.py $($DebugArgs -join ' ')"
if (-not $NoLog) { Info "logging to $Log" }

# -u: unbuffered, so --watch and --follow reach the console and the log line by line instead of in blocks
if ($NoLog) {
	& $Py -u $Tool @argv
	$code = $LASTEXITCODE
} else {
	$header = "`n=== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Port  rfoundry_debug.py $($DebugArgs -join ' ')"
	Add-Content -Path $Log -Value $header -Encoding utf8
	& $Py -u $Tool @argv 2>&1 | Tee-Object -FilePath $Log -Append
	$code = $LASTEXITCODE
	Add-Content -Path $Log -Value "=== exit $code" -Encoding utf8
}

if ($code -ne 0) {
	Write-Host ''
	Write-Host "debug: rfoundry_debug.py exited $code" -ForegroundColor Red
	Write-Host @"
If it timed out or said nothing came back:
  - is $Port the programming cable?  tools\debug.ps1 -Ports
  - is the radio on, and running RadioFoundry rather than the stock firmware?
  - is another program holding the port (a CPS, a terminal, a previous --follow)?
  - the host port is 115200 8N1; the debug link shares it with the CPS and the hotspot
"@ -ForegroundColor Yellow
}
exit $code
