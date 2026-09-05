# Build and run the checks that do not need a Nuke NDK, a GPU or an NVIDIA runtime.
#
#   powershell.exe -ExecutionPolicy Bypass -File tests/run_tests.ps1
#
# Three things are verified:
#   1. the ACES colour pipeline is invertible (tests/test_aces_roundtrip.cpp)
#   2. the plug-in translation unit still compiles (against tests/mock_ddimage)
#   3. the two copies of VideoHeader still agree (tests/test_protocol_abi.cpp)

[CmdletBinding()]
param(
    [string]$VsDir = "",
    [switch]$SkipCompileCheck
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$build = Join-Path $repo "build_tests"
New-Item -ItemType Directory -Force -Path $build | Out-Null

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
        $hit = Get-ChildItem -Path $root -Recurse -Filter "vcvars64.bat" -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }

    throw "Could not locate vcvars64.bat. Pass -VsDir 'C:\Program Files\Microsoft Visual Studio\2022\Community'."
}

$vcvars = Find-VcVars -Hint $VsDir
Write-Host "Using $vcvars" -ForegroundColor DarkGray

# Everything runs inside one cmd session so vcvars only has to be sourced once.
$lines = @(
    "@echo off",
    "call `"$vcvars`" >nul || exit /b 1",
    "cd /d `"$repo`"",
    "",
    "echo === 1/3 ACES colour pipeline ===",
    "cl /nologo /EHsc /O2 /std:c++17 /W3 /I src tests\test_aces_roundtrip.cpp /Fo:build_tests\ /Fe:build_tests\test_aces.exe >build_tests\build_aces.log 2>&1 || (type build_tests\build_aces.log & exit /b 1)",
    "build_tests\test_aces.exe || exit /b 1",
    "",
    "echo.",
    "echo === 2/3 VideoHeader wire format ===",
    "cl /nologo /EHsc /O2 /std:c++17 /W3 /DNOMINMAX /DWIN32_LEAN_AND_MEAN /I tests /I src /I worker tests\test_protocol_abi.cpp tests\protocol_layout_plugin.cpp tests\protocol_layout_worker.cpp /Fo:build_tests\ /Fe:build_tests\test_abi.exe >build_tests\build_abi.log 2>&1 || (type build_tests\build_abi.log & exit /b 1)",
    "build_tests\test_abi.exe || exit /b 1"
)

if (-not $SkipCompileCheck) {
    $lines += @(
        "",
        "echo.",
        "echo === 3/3 Plug-in compile check (mock DDImage) ===",
        "cl /nologo /c /EHsc /O2 /std:c++17 /W3 /DNOMINMAX /DWIN32_LEAN_AND_MEAN /DDLSS5_VERSION_STRING=\`"test\`" /I src /I tests\mock_ddimage src\DLSS5Live.cpp /Fo:build_tests\syntax_ >build_tests\build_node.log 2>&1 || (type build_tests\build_node.log & exit /b 1)",
        "echo   [ ok ] src/DLSS5Live.cpp compiles"
    )
}

$bat = Join-Path $build "run_tests.bat"
Set-Content -Path $bat -Value $lines -Encoding ASCII

& cmd.exe /c "`"$bat`""
$code = $LASTEXITCODE

Write-Host ""
if ($code -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
} else {
    Write-Host "Checks failed (exit $code)." -ForegroundColor Red
}
exit $code
