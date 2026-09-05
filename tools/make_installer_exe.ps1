<#
.SYNOPSIS
    Builds a single self-contained Setup .exe from the release package.

.DESCRIPTION
    The end user downloads one file, double-clicks it, and the plug-in is
    installed. No ZIP to extract, no compiler, no CMake, no Nuke NDK.

    The package is serialised into a flat archive, embedded in installer/
    setup_stub.cpp as a resource, and the result is linked against the static
    CRT so there is no Visual C++ redistributable to install first.

    IExpress was the obvious choice - it ships with Windows - but its
    AppLaunched step fails with 0x80070002 on current Windows builds even for a
    minimal one-file package: the payload extracts and nothing ever runs. The
    stub is ~200 lines of Win32 and fails legibly.

    Building the installer needs MSVC. Running it does not.

.EXAMPLE
    tools\build_and_install.bat /build-only
    tools\package_release.ps1
    tools\make_installer_exe.ps1
#>
param(
    [string]$PackageDir = "$PSScriptRoot\..\dist\DLSS5_Nuke",
    [string]$OutputDir  = "$PSScriptRoot\..\dist",
    [string]$VsDir      = "",
    [switch]$KeepIntermediates
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path "$PSScriptRoot\..").Path

Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "  DLSS 5 for Nuke (ACES fork) - Setup .exe builder " -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan

# ---- checks ----------------------------------------------------------------
if (-not (Test-Path $PackageDir)) {
    Write-Error "Package folder not found: $PackageDir`nRun tools\package_release.ps1 first."
    exit 1
}
$PackageDir = (Resolve-Path $PackageDir).Path

foreach ($required in @("install.bat", "register_plugin_path.ps1")) {
    if (-not (Test-Path (Join-Path $PackageDir $required))) {
        Write-Error "The package is missing $required. Re-run tools\package_release.ps1."
        exit 1
    }
}

$dlls = Get-ChildItem (Join-Path $PackageDir "bin") -Recurse -Filter "DLSS5Live.dll" -ErrorAction SilentlyContinue
if (-not $dlls) {
    Write-Error @"
The package contains no DLSS5Live.dll.

A Setup .exe exists so users without a compiler can install, so the DLLs have to
be built here first, on a machine with Nuke:

    tools\build_and_install.bat /build-only
    tools\package_release.ps1
"@
    exit 1
}

$stub = Join-Path $projectRoot "installer\setup_stub.cpp"
if (-not (Test-Path $stub)) { Write-Error "Missing $stub"; exit 1 }

$majors = @($dlls | ForEach-Object { $_.Directory.Name } | Sort-Object)
$version = "unknown"
$versionFile = Join-Path $PackageDir "VERSION.txt"
if (Test-Path $versionFile) { $version = (Get-Content $versionFile -TotalCount 1).Trim() }

Write-Host "`n[*] Package : $PackageDir" -ForegroundColor Yellow
Write-Host "[*] Covers  : $($majors -join ', ')" -ForegroundColor Yellow
Write-Host "[*] Version : $version" -ForegroundColor Yellow

# ---- toolchain -------------------------------------------------------------
function Find-VcVars {
    param([string]$Hint)
    if ($Hint) {
        $c = Join-Path $Hint "VC\Auxiliary\Build\vcvars64.bat"
        if (Test-Path $c) { return $c }
        throw "vcvars64.bat not found under -VsDir '$Hint'"
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $inst = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($inst) {
            $c = Join-Path $inst "VC\Auxiliary\Build\vcvars64.bat"
            if (Test-Path $c) { return $c }
        }
    }
    foreach ($root in @("${env:ProgramFiles}\Microsoft Visual Studio", "${env:ProgramFiles(x86)}\Microsoft Visual Studio")) {
        if (-not (Test-Path $root)) { continue }
        $hit = Get-ChildItem -Path $root -Recurse -Filter "vcvars64.bat" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    throw "Could not locate vcvars64.bat. Pass -VsDir 'C:\Program Files\Microsoft Visual Studio\2022\Community'."
}

$vcvars = Find-VcVars -Hint $VsDir
Write-Host "[*] MSVC    : $vcvars" -ForegroundColor Yellow

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
$OutputDir = (Resolve-Path $OutputDir).Path
$stage = Join-Path $OutputDir "_setup_build"
if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# ---- 1. serialise the package ----------------------------------------------
# Flat archive, uncompressed:
#   "DL5A" | uint32 count | { uint32 pathLen, path, uint32 dataLen, data }*
# Must match the reader in installer/setup_stub.cpp.
Write-Host "`n[1/3] Packing the release folder..." -ForegroundColor Yellow

$files = Get-ChildItem $PackageDir -Recurse -File | Sort-Object FullName
$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([System.Text.Encoding]::ASCII.GetBytes("DL5A"))
$bw.Write([uint32]$files.Count)

foreach ($f in $files) {
    $rel = $f.FullName.Substring($PackageDir.Length).TrimStart('\', '/').Replace('\', '/')
    $pathBytes = [System.Text.Encoding]::UTF8.GetBytes($rel)
    $data = [System.IO.File]::ReadAllBytes($f.FullName)
    $bw.Write([uint32]$pathBytes.Length)
    $bw.Write($pathBytes)
    $bw.Write([uint32]$data.Length)
    $bw.Write($data)
    Write-Host ("      {0,-42} {1,9:N0} b" -f $rel, $data.Length)
}
$bw.Flush()
$payloadPath = Join-Path $stage "payload.bin"
[System.IO.File]::WriteAllBytes($payloadPath, $ms.ToArray())
$bw.Dispose(); $ms.Dispose()
Write-Host ("      -> payload.bin {0:N0} KB across {1} files" -f ((Get-Item $payloadPath).Length / 1KB), $files.Count)

# ---- 2. resource script ----------------------------------------------------
# Version numbers must be plain integers for VERSIONINFO, so strip the label.
$numeric = "1.0.0.0"
if ($version -match '(\d+)\.(\d+)\.(\d+)') { $numeric = "$($matches[1]).$($matches[2]).$($matches[3]).0" }
$comma = $numeric.Replace('.', ',')

$rc = @"
#include <windows.h>

1 RCDATA "payload.bin"

VS_VERSION_INFO VERSIONINFO
FILEVERSION $comma
PRODUCTVERSION $comma
FILEOS VOS__WINDOWS32
FILETYPE VFT_APP
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904B0"
        BEGIN
            VALUE "FileDescription", "DLSS 5 for Foundry Nuke (ACES fork) - Setup"
            VALUE "FileVersion",     "$version"
            VALUE "ProductName",     "DLSS5Live ACES"
            VALUE "ProductVersion",  "$version"
            VALUE "LegalCopyright",  "MIT licensed. Not affiliated with NVIDIA or Foundry."
            VALUE "OriginalFilename","DLSS5-for-Nuke-ACES-Setup.exe"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x409, 1200
    END
END
"@
Set-Content -Path (Join-Path $stage "setup.rc") -Value $rc -Encoding ASCII

# ---- 3. compile ------------------------------------------------------------
Write-Host "`n[2/3] Compiling the stub..." -ForegroundColor Yellow

$exeName = "DLSS5-for-Nuke-ACES-$version-Setup.exe"
$exePath = Join-Path $OutputDir $exeName
if (Test-Path $exePath) { Remove-Item -LiteralPath $exePath -Force }

# /MT links the CRT statically: the installer must run on a machine that has
# never seen a Visual C++ redistributable.
$bat = @(
    "@echo off",
    "call `"$vcvars`" >nul || exit /b 1",
    "cd /d `"$stage`"",
    "rc.exe /nologo /fo setup.res setup.rc || exit /b 1",
    "cl.exe /nologo /EHsc /O2 /MT /std:c++17 /DNOMINMAX /DWIN32_LEAN_AND_MEAN `"$stub`" setup.res /Fe:`"$exePath`" /Fo:stub.obj /link /SUBSYSTEM:CONSOLE || exit /b 1"
)
$batPath = Join-Path $stage "build.bat"
Set-Content -Path $batPath -Value $bat -Encoding ASCII

$log = Join-Path $stage "build.log"
cmd.exe /c "`"$batPath`" > `"$log`" 2>&1"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exePath)) {
    Write-Host (Get-Content $log -Raw) -ForegroundColor Red
    Write-Error "Failed to build the setup stub."
    exit 1
}

Write-Host "`n[3/3] Done." -ForegroundColor Yellow
if (-not $KeepIntermediates) { Remove-Item -LiteralPath $stage -Recurse -Force }

$mb = [math]::Round((Get-Item $exePath).Length / 1MB, 2)
Write-Host "`n===================================================" -ForegroundColor Green
Write-Host "[SUCCESS] $exeName ($mb MB)" -ForegroundColor Green
Write-Host "          $exePath" -ForegroundColor Gray
Write-Host "===================================================" -ForegroundColor Green
Write-Host @"

One file. The user runs it and the plug-in is installed - no compiler, no
CMake, no Nuke NDK, no Visual C++ redistributable.

Setup.exe /uninstall  and  /y  are forwarded to install.bat.

It is unsigned, so a freshly downloaded copy triggers SmartScreen ("Windows
protected your PC" -> More info -> Run anyway). Signing needs a certificate,
which is a separate decision.
"@ -ForegroundColor Gray
