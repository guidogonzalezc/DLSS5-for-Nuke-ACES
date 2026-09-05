# Add or remove the DLSS5Live plug-in path in a Nuke user init.py.
#
# Called by tools\build_and_install.bat. It lives in its own file rather than
# inline in the batch script because the block contains quotes, parentheses and
# regex metacharacters, and cmd's escaping rules mangle them.
#
# The user's init.py is theirs: this only ever appends or removes one clearly
# marked block, and takes a timestamped backup before touching anything.
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
# install\install.bat, which greps for that string, will not append a second
# registration on top of this one.
$Block = @(
    ""
    $BeginMarker
    "import os, nuke"
    "_dlss_p = os.path.expanduser('~/.nuke/DLSS5Live').replace('\\', '/')"
    "if os.path.isdir(_dlss_p) and _dlss_p not in nuke.pluginPath():"
    "    nuke.pluginAddPath(_dlss_p)"
    $EndMarker
)

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

    if (Test-Path $InitFile) {
        $text = Get-Content $InitFile -Raw
        # Match upstream's own detection: any mention of DLSS5Live counts as
        # already registered, so the two installers never stack their blocks.
        if ($text -match "DLSS5Live") {
            Say "Plug-in path already registered (init.py left untouched)"
            exit 0
        }
        Backup $InitFile
    }

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
$pattern = "(?ms)\r?\n?" + [regex]::Escape($BeginMarker) + ".*?" + [regex]::Escape($EndMarker) + "\r?\n?"

if ($text -notmatch $pattern) {
    Say "No ACES-fork block found in init.py."
    Say "If you installed with install\install.bat instead, remove its DLSS5"
    Say "block by hand."
    exit 0
}

Backup $InitFile
Set-Content -Path $InitFile -Value ($text -replace $pattern, [Environment]::NewLine) -NoNewline
Say "Cleaned the plug-in block out of init.py"
exit 0
