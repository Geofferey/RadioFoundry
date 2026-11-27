# SPDX-License-Identifier: MIT
# Copyright (c) 2026 The RadioFoundry Authors
#
# Builds RadioFoundry firmware for one radio from Windows.
#
# The firmware is cross compiled by a Linux toolchain (platform/<p>/platform.toml [toolchain]), and neither of them is
# built for Windows, so this script drives the build inside WSL against this same checkout: the tree stays where it
# is, on an NTFS drive, and git, the editor and the images are all where Windows left them. Nothing is copied and no
# second clone is made.
#
# Everything the build prints appears in a terminal window of its own, from the first dependency check to the last
# linker line, and the window stays open at the end so a failure can be read.
#
#   tools\build.ps1 dm32                 build/dm32/rfoundry_dm32.bin
#   tools\build.ps1 dm32 size            a make target instead of the image (size, clean, print-config, ...)
#   tools\build.ps1 dm32 CONFIG_GPS=n    a feature switch off, or any other make variable
#   tools\build.ps1 dm32 -Setup          only prepare the environment, build nothing
#   tools\build.ps1 -List                the radios this tree can build
#
# First run on a new machine: it installs what is missing (WSL and a distribution, the Ubuntu packages a toolchain
# build needs, the third_party submodules, then the toolchain itself) and the C-SKY toolchain is built from source,
# which takes a while. Later runs find all of it and go straight to make.
#
# Options:
#   -Board <id>      the radio, as boards/<id> (positional, so -Board is optional)
#   -Distro <name>   which WSL distribution to build in (default: the first real one installed)
#   -Jobs <n>        parallel make jobs (default: the processor count)
#   -Setup           prepare the environment and stop
#   -SkipSetup       assume the environment is ready and run make alone (a fast rebuild)
#   -Here            run in this console instead of a new window, for a script or CI
#   -CloseWhenDone   do not wait for a key before the window closes
#   -AI              the ordinary window, and every line of it also written to build/build-<radio>.log, so the build
#                    can be read back whole (by an agent, or by you after the window is gone) while the window still
#                    shows it live. Nothing about the window changes
#   -List            list the radios and exit
[CmdletBinding()]
param(
	[Parameter(Position = 0)][string]$Board,
	[string]$Distro,
	[int]$Jobs = 0,
	[switch]$Setup,
	[switch]$SkipSetup,
	[switch]$Here,
	[switch]$CloseWhenDone,
	[switch]$AI,
	[switch]$List,
	[Parameter(ValueFromRemainingArguments = $true)][string[]]$MakeArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# wsl.exe writes UTF-16 by default, which turns every parsed list into "U b u n t u"; this makes it UTF-8
$env:WSL_UTF8 = '1'

function Fail($Message) {
	Write-Host "build: $Message" -ForegroundColor Red
	exit 2
}

function Info($Message) { Write-Host "build: $Message" -ForegroundColor Cyan }

# Brings a newly started console to the front. Windows opens it behind whatever has focus as often as not, and a
# build you cannot see is a build you forget is running -- it also has to be in front to type a sudo password into.
# SetForegroundWindow alone is refused unless the caller already owns the foreground, so the window is restored
# first and AppActivate (which plays by the shell's rules) is the fallback.
if (-not ('RF.Win' -as [type])) {
	Add-Type -Namespace RF -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
'@
}

function Show-Window($Proc) {
	# The console window does not exist the instant Start-Process returns
	for ($i = 0; $i -lt 60; $i++) {
		try { $Proc.Refresh() } catch { return }
		if ($Proc.HasExited) { return }
		if ($Proc.MainWindowHandle -ne [IntPtr]::Zero) { break }
		Start-Sleep -Milliseconds 50
	}
	$h = $Proc.MainWindowHandle
	if ($h -eq [IntPtr]::Zero) { return }
	if ([RF.Win]::IsIconic($h)) { [void][RF.Win]::ShowWindow($h, 9) }	# SW_RESTORE
	if (-not [RF.Win]::SetForegroundWindow($h)) {
		try { (New-Object -ComObject WScript.Shell).AppActivate($Proc.Id) | Out-Null } catch { }
	}
}

# A Windows path as the distribution sees it. wslpath is the only correct translation (a mapped or subst drive does
# not follow the C:\ -> /mnt/c rule), but wsl.exe eats the backslashes on the way in, so hand it forward slashes.
function Convert-ToWslPath($WindowsPath, $InDistro) {
	$arg = $WindowsPath -replace '\\', '/'
	$out = (& wsl.exe -d $InDistro -- wslpath -a "$arg" 2>$null | Select-Object -First 1)
	if (-not $out) { return '' }
	return $out.Trim()
}

# The checkout this script sits in, never the current directory: the script works from anywhere
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not (Test-Path (Join-Path $Root 'Makefile'))) { Fail "no Makefile in $Root; is tools\build.ps1 still in the tree?" }

# ------------------------------------------------------------------ WSL
$wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wsl) {
	Fail @"
WSL is not installed on this machine.

Install it from an ADMINISTRATOR PowerShell, then reboot and run this script again:

    wsl --install -d Ubuntu-24.04

(It needs the reboot: the Windows Subsystem for Linux is a feature, not just a package. This script cannot
elevate itself to do it for you.)
"@
}

# `wsl -l -q` lists installed distributions. The ones Docker Desktop manages are not general purpose, so skip them.
$installed = @()
try {
	$installed = @(& wsl.exe -l -q 2>$null |
		ForEach-Object { $_.Trim() } |
		Where-Object { $_ -and $_ -notmatch '^docker-desktop' })
} catch { $installed = @() }

if ($Distro) {
	if ($installed -notcontains $Distro) {
		Fail "no WSL distribution named '$Distro'. Installed: $(if ($installed) { $installed -join ', ' } else { '(none)' })"
	}
} elseif ($installed.Count -ge 1) {
	$Distro = $installed[0]
} else {
	Info 'no WSL distribution is installed; installing Ubuntu-24.04 (this downloads a few hundred MB)'
	# --no-launch keeps it from opening its own first-run shell; the user set-up below happens on first use
	& wsl.exe --install -d Ubuntu-24.04 --no-launch
	if ($LASTEXITCODE -ne 0) {
		Fail @"
installing Ubuntu-24.04 failed (exit $LASTEXITCODE).

Run this once from an ADMINISTRATOR PowerShell, reboot if it asks, then run this script again:

    wsl --install -d Ubuntu-24.04
"@
	}
	$installed = @(& wsl.exe -l -q 2>$null | ForEach-Object { $_.Trim() } |
		Where-Object { $_ -and $_ -notmatch '^docker-desktop' })
	if (-not $installed) { Fail 'Ubuntu-24.04 installed but no distribution is listed; reboot and try again' }
	$Distro = $installed[0]
	Info "a new distribution needs a user account the first time. A window will open: pick a username and password."
	Info 'that password is the one sudo asks for later in the build.'
	Start-Process -FilePath 'wsl.exe' -ArgumentList '-d', $Distro -Wait
}
Info "WSL distribution: $Distro"

# This checkout, as the distribution sees it (/mnt/c/...)
$WslRoot = Convert-ToWslPath $Root $Distro
if (-not $WslRoot) { Fail "could not translate $Root into a WSL path" }
Info "tree: $Root  ->  $WslRoot"

# ------------------------------------------------------------------ the radios
# The board list comes from the registry, so a radio added to boards/ needs no edit here
$boardList = @(& wsl.exe -d $Distro -- sh -c "cd '$WslRoot' && tools/boards.py list 2>/dev/null" |
	ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $boardList) {
	# A distribution without Python 3.11 cannot answer yet; fall back to the directories themselves
	$boardList = @(Get-ChildItem (Join-Path $Root 'boards') -Directory |
		Where-Object { Test-Path (Join-Path $_.FullName 'board.mk') } | ForEach-Object { $_.Name })
}

if ($List) {
	Write-Host "`nRadios this tree can build:`n"
	$boardList | ForEach-Object { Write-Host "    $_" }
	Write-Host ''
	exit 0
}

if (-not $Board) {
	Write-Host @"

build: say which radio to build.

    tools\build.ps1 <radio>

Radios: $($boardList -join ', ')

There is deliberately no default: an image for the wrong radio is easy to miss.
"@
	exit 2
}
if ($boardList -notcontains $Board) {
	Fail "no radio '$Board'. They are: $($boardList -join ', ')"
}

if ($Jobs -le 0) {
	$Jobs = [int]$env:NUMBER_OF_PROCESSORS
	if ($Jobs -le 0) { $Jobs = 4 }
}

$doSetup = -not $SkipSetup
$doBuild = -not $Setup
$extra = if ($MakeArgs) { $MakeArgs -join ' ' } else { '' }
$inline = [bool]$Here

# ------------------------------------------------------------------ the program that runs inside WSL
# Written to a temporary file rather than passed as one long -c string: no quoting of a quoting of a quote, and the
# window shows a readable script if anything goes wrong. It must have Unix line endings, or bash reads "set -u\r".
$statusWin = Join-Path $env:TEMP "rfoundry-build-$PID.status"
$scriptWin = Join-Path $env:TEMP "rfoundry-build-$PID.sh"
$statusWsl = Convert-ToWslPath $statusWin $Distro

# -AI keeps the whole run in build/, which is git ignored, so it can be read back after the window is gone
$LogWin = ''
$LogWsl = ''
if ($AI) {
	$LogWin = Join-Path $Root "build\build-$Board.log"
	$null = New-Item -ItemType Directory -Force -Path (Split-Path $LogWin) -ErrorAction SilentlyContinue
	$LogWsl = Convert-ToWslPath $LogWin $Distro
	if (-not $LogWsl) { Fail "could not translate $LogWin into a WSL path" }
}

$bash = @'
# Driven by tools/build.ps1; this file is generated per run and lives in the Windows temporary directory.
set -u

ROOT="@@ROOT@@"
BOARD="@@BOARD@@"
JOBS="@@JOBS@@"
EXTRA="@@EXTRA@@"
DO_SETUP=@@DOSETUP@@
DO_BUILD=@@DOBUILD@@
STATUS="@@STATUS@@"
KEEP_OPEN=@@KEEPOPEN@@
LOG="@@LOG@@"

# -AI: everything this script prints goes to the window as usual and to the log as well, so the run can be read
# back in full afterwards. tee, not a plain redirect, because the window has to stay live.
if [ -n "$LOG" ]; then
	mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
	: > "$LOG" 2>/dev/null || true
	exec > >(tee -a "$LOG") 2>&1
fi

bold=""; red=""; grn=""; off=""
if [ -t 1 ]; then bold=$(printf '\033[1m'); red=$(printf '\033[31m'); grn=$(printf '\033[32m'); off=$(printf '\033[0m'); fi
say()  { printf '\n%s== %s%s\n' "$bold" "$*" "$off"; }
note() { printf '   %s\n' "$*"; }

finish() {
	rc=$1
	echo "$rc" > "$STATUS" 2>/dev/null || true
	echo
	if [ "$rc" -eq 0 ]; then
		printf '%s=== done ===%s\n' "$grn" "$off"
	else
		printf '%s=== FAILED (exit %s) ===%s\n' "$red" "$rc" "$off"
	fi
	if [ "$KEEP_OPEN" -eq 1 ]; then
		echo
		printf 'Press Enter to close this window... '
		read -r _ignored || true
	fi
	exit "$rc"
}

cd "$ROOT" || finish 2

say "RadioFoundry firmware build"
note "radio:  $BOARD"
note "tree:   $ROOT"
note "distro: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
note "jobs:   $JOBS"

# ---------------------------------------------------------------- set-up
if [ "$DO_SETUP" -eq 1 ]; then
	say "Python"
	PY=$(tools/rfoundry_python.sh 2>/dev/null) || PY=""
	if [ -z "$PY" ]; then
		note "no Python 3.11 or later; installing python3 (sudo will ask for your WSL password)"
		echo
		sudo apt-get update && sudo apt-get install -y python3 || finish 1
		PY=$(tools/rfoundry_python.sh) || finish 1
	fi
	note "$PY ($("$PY" -c 'import sys; print(sys.version.split()[0])'))"

	# The radio's platform and that platform's toolchain, from the registry: no list of radios lives in this script
	PLATFORM=$("$PY" tools/boards.py get "$BOARD" platform) || finish 1
	TC_CC=$("$PY" tools/boards.py platform "$PLATFORM" toolchain.cc) || finish 1
	TC_NAME=$("$PY" tools/boards.py platform "$PLATFORM" toolchain.name) || finish 1
	TC_BUILD=$("$PY" tools/boards.py platform "$PLATFORM" toolchain.build) || finish 1

	say "Toolchain: $TC_NAME ($TC_CC) for platform $PLATFORM"
	# print-cc is the compiler this tree would really use for this radio, found the Makefile's own way
	HAVE=$(make BOARD="$BOARD" print-cc 2>/dev/null | tail -1)
	if [ -n "$HAVE" ] && "$HAVE" --version > /dev/null 2>&1; then
		note "installed: $HAVE"
		note "$("$HAVE" --version | head -1)"
	else
		note "not installed yet ($TC_CC)"

		# The packages a toolchain source build needs: a host compiler and make, GCC's own libraries (GMP, MPFR,
		# MPC, ISL) and the tools its configure looks for. texinfo matters even here: without makeinfo, binutils
		# stops at doc/bfd.info.
		say "Host packages"
		PKGS="build-essential libgmp-dev libmpfr-dev libmpc-dev libisl-dev texinfo bison flex curl git xz-utils"
		NEED=""
		for p in $PKGS; do
			[ "$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null)" = "install ok installed" ] || NEED="$NEED $p"
		done
		if [ -z "$NEED" ]; then
			note "all present"
		else
			note "missing:$NEED"
			note "apt needs root: sudo will ask for your WSL password now."
			echo
			sudo apt-get update || finish 1
			sudo apt-get install -y $NEED || finish 1
			note "installed"
		fi

		# A source build keeps its trees under ~/toolchains/src. Reaching here means the compiler is NOT
		# installed, so any tree there is from a run that failed or was interrupted -- and its config.cache
		# still records the environment of that run. Installing a missing package (bison, texinfo) changes
		# that environment, and the next configure refuses to continue: "`YACC' has changed since the
		# previous run ... run `make distclean' and/or `rm ./config.cache' and start over". Clear the build
		# trees so configure starts clean. The downloaded archives and unpacked sources stay, so nothing is
		# fetched twice.
		STALE=$(ls -d "$HOME"/toolchains/src/b-* 2>/dev/null || true)
		if [ -n "$STALE" ]; then
			say "Clearing a half finished toolchain build"
			for d in $STALE; do
				note "removing $d"
				rm -rf "$d"
			done
			note "the archives and unpacked sources stay, so nothing is downloaded twice"
		fi

		say "Building the $TC_NAME toolchain with $TC_BUILD"
		note "a source build takes a while (tens of minutes); everything it prints follows"
		echo
		"./$TC_BUILD" || finish 1
	fi

	# ------------------------------------------------------------ submodules
	say "Submodules (third_party)"
	if [ -n "${RFOUNDRY_THIRD_PARTY:-}" ]; then
		note "RFOUNDRY_THIRD_PARTY is set, so this tree uses that checkout's copies"
	else
		# The tree belongs to the Windows user, not to this one, and git will not read such a directory
		# unless told it is safe. core.eol/autocrlf: a Linux toolchain compiles this, so LF everywhere.
		G="git -c safe.directory=* -c core.autocrlf=false -c core.eol=lf"
		SUBS=$($G config --file .gitmodules --get-regexp '\.path$' | awk '{print $2}')
		MISS=""
		for s in $SUBS; do [ -e "$s/.git" ] || MISS="$MISS $s"; done
		if [ -n "$MISS" ]; then
			note "checking out:$MISS"
			$G submodule update --init --depth 1 || finish 1
		else
			note "all checked out"
		fi
		# Our .gitattributes pins this tree to LF but cannot reach inside a submodule, and the vendors' own say
		# "* text=auto" with no eol, which on Windows means CRLF. Their indexes are LF, so rewrite what came out
		# converted.
		for s in $SUBS; do
			[ -e "$s/.git" ] || continue
			$G -C "$s" config core.eol lf
			$G -C "$s" config core.autocrlf false
			n=$($G -C "$s" ls-files --eol | awk '$2 == "w/crlf"' | wc -l)
			[ "$n" -eq 0 ] && continue
			note "$s: $n files were checked out CRLF, rewriting as LF"
			$G -C "$s" checkout-index --all --force
		done
	fi
fi

if [ "$DO_BUILD" -eq 0 ]; then
	say "Set-up only (-Setup), nothing built"
	finish 0
fi

# ---------------------------------------------------------------- build
say "make BOARD=$BOARD -j$JOBS $EXTRA"
echo
# shellcheck disable=SC2086
make BOARD="$BOARD" -j"$JOBS" $EXTRA
rc=$?
[ $rc -eq 0 ] || finish $rc

say "Images"
for f in build/"$BOARD"*/rfoundry_"$BOARD"*.bin build/"$BOARD"*/rfoundry_"$BOARD"*.elf; do
	[ -f "$f" ] || continue
	note "$(ls -la "$f" | awk '{printf "%-10s %s\n", $5, $9}')"
done
finish 0
'@

$bash = $bash.
	Replace('@@ROOT@@', $WslRoot).
	Replace('@@BOARD@@', $Board).
	Replace('@@JOBS@@', "$Jobs").
	Replace('@@EXTRA@@', $extra).
	Replace('@@DOSETUP@@', $(if ($doSetup) { '1' } else { '0' })).
	Replace('@@DOBUILD@@', $(if ($doBuild) { '1' } else { '0' })).
	Replace('@@STATUS@@', $statusWsl).
	Replace('@@LOG@@', $LogWsl).
	Replace('@@KEEPOPEN@@', $(if ($CloseWhenDone -or $inline) { '0' } else { '1' }))

# LF, and no byte order mark: bash would choke on either
[System.IO.File]::WriteAllText($scriptWin, ($bash -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding $false))
$scriptWsl = Convert-ToWslPath $scriptWin $Distro
if (-not $scriptWsl) { Fail "could not translate $scriptWin into a WSL path" }
Remove-Item $statusWin -ErrorAction SilentlyContinue

try {
	if ($LogWin) { Info "logging the whole run to $LogWin" }
	if ($inline) {
		& wsl.exe -d $Distro -- bash $scriptWsl
		$code = $LASTEXITCODE
	} else {
		Info 'opening a terminal window for the build; it stays open when it finishes'
		# A window of its own, so the whole build is visible and a failure can be read before it closes.
		# Not -Wait: the window has to be brought to the front first, and -Wait would not return until it closed.
		$p = Start-Process -FilePath 'wsl.exe' -ArgumentList '-d', $Distro, '--', 'bash', $scriptWsl -PassThru
		Show-Window $p
		$p.WaitForExit()
		$code = $p.ExitCode
	}

	# The window's own exit status is lost when a user closes it, so the script leaves its result behind
	if (Test-Path $statusWin) {
		$code = [int](Get-Content $statusWin -First 1).Trim()
	}

	if ($code -eq 0 -and $doBuild) {
		Info "done. Images in $(Join-Path $Root "build\$Board")"
	} elseif ($code -eq 0) {
		Info 'done.'
	} else {
		Write-Host "build: FAILED (exit $code)" -ForegroundColor Red
	}
	exit $code
} finally {
	Remove-Item $scriptWin, $statusWin -ErrorAction SilentlyContinue
}
