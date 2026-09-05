<#
.SYNOPSIS
    Assembles the Release folder and ZIP that end users install with install.bat.

.DESCRIPTION
    This is the maintainer-side half of the "no compiler needed" install path:
    run it once on a machine that has Nuke, and everyone else installs the
    resulting ZIP with no Visual Studio, no CMake and no Nuke NDK.

    Only project-authored files go in. Upstream's version of this script also
    reached for nvngx_dlss.dll, nvngx_dlssnr.dll, dxgi.dll, ReShade.ini and the
    RenoDX addon if they happened to be on the maintainer's machine, which
    contradicts the repository's own runtime policy and would have shipped
    third-party binaries inside a public Release. Those are refused here, and
    the script says so when it finds them.

.EXAMPLE
    tools\build_and_install.ps1            # build first
    tools\package_release.ps1 -CreateZip
#>
param(
    [string]$OutputDir = "$PSScriptRoot\..\dist\DLSS5_Nuke",
    [switch]$CreateZip = $false,
    [switch]$AllowMissingWorker = $false
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path "$PSScriptRoot\..").Path

Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "  DLSS 5 for Nuke (ACES fork) - Release Packaging  " -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan

# ---- version ---------------------------------------------------------------
$version = "0.0.0"
$cmakePath = Join-Path $projectRoot "CMakeLists.txt"
if (Test-Path $cmakePath) {
    $c = Get-Content $cmakePath -Raw
    if ($c -match 'project\s*\(\s*DLSS5Live\s+VERSION\s+([0-9\.]+)') { $version = $matches[1] }
}
# Match the string compiled into the node header, so "which build is this?" has
# one answer everywhere: the ZIP name, VERSION.txt and the node's own title.
$versionLabel = "v$version-aces"
Write-Host "`n[*] Version: $versionLabel" -ForegroundColor Yellow

# ---- clean output ----------------------------------------------------------
if (Test-Path $OutputDir) { Remove-Item $OutputDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
New-Item -ItemType Directory -Force -Path "$OutputDir\runtime" | Out-Null

# ---- plug-in DLLs ----------------------------------------------------------
# Every bin\Nuke<major> that carries a DLL, rather than a hardcoded 15 and 17,
# so a Release can cover whatever versions were actually built.
$binDir = Join-Path $projectRoot "bin"
$majors = @()

if (Test-Path $binDir) {
    foreach ($d in Get-ChildItem $binDir -Directory -Filter "Nuke*") {
        $dll = Join-Path $d.FullName "DLSS5Live.dll"
        if (-not (Test-Path $dll)) { continue }
        New-Item -ItemType Directory -Force -Path "$OutputDir\bin\$($d.Name)" | Out-Null
        Copy-Item $dll "$OutputDir\bin\$($d.Name)\DLSS5Live.dll" -Force
        $majors += $d.Name
        $size = [math]::Round((Get-Item $dll).Length / 1KB)
        Write-Host "    [+] bin\$($d.Name)\DLSS5Live.dll  ($size KB)" -ForegroundColor Green
    }
}

if ($majors.Count -eq 0) {
    Write-Error @"
No plug-in DLLs found under $binDir.

A Release ZIP exists so that users without a compiler can install, which means
the DLLs have to be built here first, on a machine that has Nuke:

    tools\build_and_install.bat /build-only

Building requires a Nuke installation: the plug-in links against DDImage from
its NDK, and the NDK ships inside Nuke rather than as a separate download.
"@
    exit 1
}

# ---- worker ----------------------------------------------------------------
$workerDir = Join-Path $projectRoot "bin\worker"
$workerOk = $true
foreach ($f in @("DLSS_Nuke_Worker.exe", "nvngx.dll")) {
    $src = Join-Path $workerDir $f
    if (Test-Path $src) {
        Copy-Item $src "$OutputDir\runtime\$f" -Force
        Write-Host "    [+] runtime\$f" -ForegroundColor Green
    } else {
        $workerOk = $false
        Write-Warning "Missing $f - build it with tools\build_and_install.bat"
    }
}
if (-not $workerOk -and -not $AllowMissingWorker) {
    Write-Error "The worker is missing. Build it, or pass -AllowMissingWorker on purpose."
    exit 1
}

# ---- installer and docs ----------------------------------------------------
$flat = @{
    "install\install.bat"             = "install.bat"
    "install\DLSS5Live-uninstall.bat" = "DLSS5Live-uninstall.bat"
    "install\register_plugin_path.ps1" = "register_plugin_path.ps1"
    "install\init.py"                 = "init.py"
    "install\menu.py"                 = "menu.py"
    "install\DLSS5.png"               = "DLSS5.png"
    "README.md"                       = "README.md"
    "docs\ACES.md"                    = "ACES.md"
    "LICENSE"                         = "LICENSE"
}
foreach ($k in $flat.Keys) {
    $src = Join-Path $projectRoot $k
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $OutputDir $flat[$k]) -Force
    } elseif ($k -like "install\*") {
        Write-Error "Required file missing from the package: $k"
        exit 1
    }
}
Write-Host "    [+] install.bat, register_plugin_path.ps1, init.py, menu.py, icon, docs" -ForegroundColor Green

# install.bat reads this to report what it is installing, and writes a copy into
# the install directory so the next run can say what it is replacing.
Set-Content -Path "$OutputDir\VERSION.txt" -Value $versionLabel

# ---- runtime policy check --------------------------------------------------
# A stray NVIDIA or ReShade binary in the tree must never reach a public ZIP.
$forbidden = @("_nvngx.dll", "nvngx_dlss.dll", "nvngx_dlssnr.dll", "dxgi.dll",
               "renodx-dlss5.addon64", "ReShade.ini", "ReShade64.dll")
$leaked = Get-ChildItem $OutputDir -Recurse -File |
          Where-Object { $forbidden -contains $_.Name }
if ($leaked) {
    Write-Host ""
    foreach ($f in $leaked) { Write-Warning "Third-party runtime file in the package: $($f.FullName)" }
    Write-Error "Refusing to package third-party runtime binaries. Remove them and re-run."
    exit 1
}
Write-Host "    [+] runtime policy check passed (no third-party binaries)" -ForegroundColor Green

# ---- line-ending check -----------------------------------------------------
# cmd.exe tracks its position in a running .bat by byte offset. With LF-only
# line endings it mis-seeks after returning from `call :label` and silently
# skips the next line: no error, no output, the statement just never runs.
# A .gitattributes keeps the repository right; this catches a package assembled
# from a working tree that predates it.
$badEol = @()
foreach ($f in Get-ChildItem $OutputDir -Recurse -File -Include "*.bat", "*.cmd") {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    if ($text -match "(?<!`r)`n") { $badEol += $f.FullName }
}
if ($badEol) {
    Write-Host ""
    foreach ($f in $badEol) { Write-Warning "LF line endings in $f" }
    Write-Error @"
Batch files in the package must use CRLF.

Fix the working tree and re-run:
    git add --renormalize .
"@
    exit 1
}
Write-Host "    [+] batch files use CRLF" -ForegroundColor Green

Write-Host "`n[SUCCESS] Package assembled: $OutputDir" -ForegroundColor Green
Write-Host "          Nuke versions: $($majors -join ', ')" -ForegroundColor Gray

# ---- zip -------------------------------------------------------------------
if ($CreateZip) {
    $distParent = Split-Path -Parent $OutputDir
    $zipPath = Join-Path $distParent "DLSS5-for-Nuke-ACES-$versionLabel.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path "$OutputDir\*" -DestinationPath $zipPath -Force
    $mb = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
    Write-Host "`n[SUCCESS] Release ZIP: $zipPath ($mb MB)" -ForegroundColor Green
    Write-Host "          Users extract it and run install.bat. No compiler needed." -ForegroundColor Gray
}

Write-Host "===================================================" -ForegroundColor Cyan
