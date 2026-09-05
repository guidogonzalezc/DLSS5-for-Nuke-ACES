# Add, migrate or remove the DLSS5Live plug-in path in a Nuke user init.py.
#
# Called by install\install.bat and tools\build_and_install.bat. It lives in its
# own file rather than inline in those batch scripts because the block contains
# quotes, parentheses and regex metacharacters, and cmd's escaping rules mangle
# them.
#
# The user's init.py is theirs. This only ever appends, replaces or removes one
# clearly marked block, and takes a timestamped backup before touching anything.
#
#   register_plugin_path.ps1 -Action install   -InitFile "$env:USERPROFILE\.nuke\init.py"
#   register_plugin_path.ps1 -Action uninstall -InitFile "$env:USERPROFILE\.nuke\init.py"

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet("install", "uninstall")]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$InitFile,

    [string]$Indent = "      "
)

$ErrorActionPreference = "Stop"

$BeginMarker = "# --- DLSS5Live (ACES fork) BEGIN ---"
$EndMarker   = "# --- DLSS5Live (ACES fork) END ---"

# The block deliberately contains the literal "DLSS5Live" so that upstream's
# installer, which greps for that string, will not append a second registration
# on top of this one.
$Block = @(
    ""
    $BeginMarker
    "import os, nuke"
    "_dlss_p = os.path.expanduser('~/.nuke/DLSS5Live').replace('\\', '/')"
    "if os.path.isdir(_dlss_p) and _dlss_p not in nuke.pluginPath():"
    "    nuke.pluginAddPath(_dlss_p)"
    $EndMarker
)

# Upstream's installer writes this exact block. It points at the same directory,
# so it is not broken - but it has no end marker, which makes it impossible to
# remove cleanly later. Matched strictly: anything that is not upstream's block
# verbatim is treated as a hand-written registration and left alone.
# [ \t]* rather than \s*: \s matches newlines, which would let the pattern
# swallow blank lines and unrelated code around the block.
$UpstreamPattern = "(?m)^[ \t]*# --- DLSS 5 Native Live ---[ \t]*\r?\n" +
                   "[ \t]*import os, nuke[ \t]*\r?\n" +
                   # The .replace(...) argument is the one cosmetically variable
                   # part (how many backslashes survived whoever wrote the file),
                   # so match its shape rather than its exact characters. The
                   # marker comment plus the surrounding four lines are what make
                   # this specific enough to edit safely.
                   "[ \t]*_dlss_p = os\.path\.expanduser\('~/\.nuke/DLSS5Live'\)\.replace\([^)]*\)[ \t]*\r?\n" +
                   "[ \t]*if os\.path\.isdir\(_dlss_p\) and _dlss_p not in nuke\.pluginPath\(\):[ \t]*\r?\n" +
                   "[ \t]*nuke\.pluginAddPath\(_dlss_p\)[ \t]*\r?\n?"

$OursPattern = "(?ms)\r?\n?" + [regex]::Escape($BeginMarker) + ".*?" + [regex]::Escape($EndMarker) + "\r?\n?"

function Say([string]$m) { Write-Host ($Indent + $m) }

function Backup([string]$path) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $dest = "$path.bak-$stamp"
    Copy-Item $path $dest -Force
    Say ("Backed up your init.py to " + (Split-Path $dest -Leaf))
}

if ($Action -eq "install") {
    $dir = Split-Path $InitFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    if (-not (Test-Path $InitFile)) {
        Add-Content -Path $InitFile -Value $Block
        Say "Registered the plug-in path in init.py"
        exit 0
    }

    $text = Get-Content $InitFile -Raw
    if ($null -eq $text) { $text = "" }

    if ($text -match $OursPattern) {
        Say "Plug-in path already registered (init.py left untouched)"
        exit 0
    }

    if ($text -match $UpstreamPattern) {
        # Upgrade in place: swap upstream's unmarked block for the marked one so
        # a later /uninstall can find it.
        Backup $InitFile
        $replacement = ($Block | Select-Object -Skip 1) -join [Environment]::NewLine
        Set-Content -Path $InitFile -Value ($text -replace $UpstreamPattern, ($replacement + [Environment]::NewLine)) -NoNewline
        Say "Replaced the previous DLSS5 block in init.py with a removable one"
        exit 0
    }

    if ($text -match "DLSS5Live") {
        Say "init.py already mentions DLSS5Live but not in a block this script"
        Say "wrote. Leaving it untouched - check it points at ~/.nuke/DLSS5Live."
        exit 0
    }

    Backup $InitFile
    Add-Content -Path $InitFile -Value $Block
    Say "Registered the plug-in path in init.py"
    exit 0
}

# ---- uninstall -------------------------------------------------------------

if (-not (Test-Path $InitFile)) {
    Say "No init.py to clean"
    exit 0
}

$text = Get-Content $InitFile -Raw
if ($null -eq $text) { $text = "" }

$pattern = $null
if     ($text -match $OursPattern)     { $pattern = $OursPattern }
elseif ($text -match $UpstreamPattern) { $pattern = $UpstreamPattern }

if (-not $pattern) {
    if ($text -match "DLSS5Live") {
        Say "init.py mentions DLSS5Live but not in a block this script wrote."
        Say "Remove that entry by hand if you want it gone."
    } else {
        Say "Nothing to clean in init.py"
    }
    exit 0
}

Backup $InitFile
Set-Content -Path $InitFile -Value ($text -replace $pattern, [Environment]::NewLine) -NoNewline
Say "Cleaned the plug-in block out of init.py"
exit 0
