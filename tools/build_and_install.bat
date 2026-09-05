@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
title DLSS 5 for Nuke (ACES fork) - Build and Install

REM ============================================================================
REM  Build DLSS5Live from source and install it into %USERPROFILE%\.nuke.
REM
REM  install\install.bat deploys a Release ZIP that already contains compiled
REM  DLLs. This repository ships source only, so this script compiles first and
REM  then installs into exactly the same layout.
REM
REM  Usage:
REM    tools\build_and_install.bat                 auto-detect everything
REM    tools\build_and_install.bat /nuke "C:\Program Files\Nuke15.1v5"
REM    tools\build_and_install.bat /skip-tests /skip-worker
REM    tools\build_and_install.bat /build-only
REM    tools\build_and_install.bat /uninstall
REM ============================================================================

set "REPO=%~dp0.."
pushd "%REPO%" >nul
set "REPO=%CD%"
popd >nul

set "NUKE_USER_DIR=%USERPROFILE%\.nuke"
set "PLUGIN_DIR=%NUKE_USER_DIR%\DLSS5Live"
set "RUNTIME_TARGET=%PLUGIN_DIR%\runtime"
set "INIT_FILE=%NUKE_USER_DIR%\init.py"

set "NUKE_DIRS="
set "SKIP_TESTS="
set "SKIP_WORKER="
set "BUILD_ONLY="
set "DO_UNINSTALL="
set "FAILED="
set "BUILT_ANY="

REM ---------------------------------------------------------------- arguments
:parse_args
if "%~1"=="" goto args_done
if /I "%~1"=="/?"           goto usage
if /I "%~1"=="/help"        goto usage
if /I "%~1"=="-h"           goto usage
if /I "%~1"=="/nuke"        goto arg_nuke
if /I "%~1"=="/skip-tests"  set "SKIP_TESTS=1" & shift & goto parse_args
if /I "%~1"=="/skip-worker" set "SKIP_WORKER=1" & shift & goto parse_args
if /I "%~1"=="/build-only"  set "BUILD_ONLY=1" & shift & goto parse_args
if /I "%~1"=="/uninstall"   set "DO_UNINSTALL=1" & shift & goto parse_args
echo [ERROR] Unknown option: %~1
echo.
set "USAGE_EXIT=1"
goto usage

:arg_nuke
shift
if "%~1"=="" echo [ERROR] /nuke needs a directory & exit /b 1
set "NUKE_DIRS=!NUKE_DIRS!%~1;"
shift
goto parse_args

:args_done

echo ===================================================
echo   DLSS 5 for Foundry Nuke - ACES fork
echo   Build and Install from source
echo ===================================================
echo.
echo   Repository: %REPO%
echo.

if defined DO_UNINSTALL goto uninstall

REM ------------------------------------------------------------- [1] toolchain
echo [1/6] Locating build tools...

call :find_vs
if not defined VCVARS (
    echo.
    echo [ERROR] Visual Studio with the C++ toolset was not found.
    echo         Install "Desktop development with C++" from the Visual Studio
    echo         Installer, then run this script again.
    exit /b 1
)
echo       MSVC   : !VCVARS!

call :find_tool cmake.exe CMAKE_EXE
if not defined CMAKE_EXE (
    echo [ERROR] cmake.exe not found on PATH nor bundled with Visual Studio.
    echo         Install the "C++ CMake tools for Windows" component.
    exit /b 1
)
echo       CMake  : !CMAKE_EXE!

call :find_tool ninja.exe NINJA_EXE
if not defined NINJA_EXE (
    echo [ERROR] ninja.exe not found on PATH nor bundled with Visual Studio.
    echo         It ships with the "C++ CMake tools for Windows" component.
    exit /b 1
)
echo       Ninja  : !NINJA_EXE!
echo.

REM ----------------------------------------------------------------- [2] Nuke
echo [2/6] Locating Nuke NDK...

if not defined NUKE_DIRS if defined DLSS5_NUKE_DIRS set "NUKE_DIRS=%DLSS5_NUKE_DIRS%"
if not defined NUKE_DIRS call :find_nuke

if not defined NUKE_DIRS (
    echo.
    echo [ERROR] No Nuke installation found.
    echo.
    echo         A Nuke install is required: the plug-in links against DDImage
    echo         from its NDK, and a DLL built for one Nuke major version will
    echo         not load in another.
    echo.
    echo         Searched Program Files, Program Files x86, C:\ and D:\ for a
    echo         Nuke*v* folder containing include\DDImage\Iop.h
    echo.
    echo         Point at it explicitly if it lives elsewhere:
    echo           tools\build_and_install.bat /nuke "D:\Nuke15.1v5"
    exit /b 1
)

for %%D in ("!NUKE_DIRS:;=" "!") do (
    if not "%%~D"=="" echo       Nuke   : %%~D
)
echo.

REM ---------------------------------------------------------------- [3] tests
if defined SKIP_TESTS (
    echo [3/6] Skipping colour pipeline tests ^(/skip-tests^).
    echo.
    goto do_build
)

echo [3/6] Verifying the ACES colour pipeline...
echo.
powershell.exe -ExecutionPolicy Bypass -File "%REPO%\tests\run_tests.ps1" -VsDir "!VS_ROOT!"
if errorlevel 1 (
    echo.
    echo [ERROR] The colour pipeline checks failed. Not installing.
    echo         Please report this along with the output above.
    exit /b 1
)
echo.

REM -------------------------------------------------------- [4] build plug-in
:do_build
echo [4/6] Building DLSS5Live.dll...
echo.

for %%D in ("!NUKE_DIRS:;=" "!") do (
    if not "%%~D"=="" call :build_plugin "%%~D"
)

if defined FAILED (
    echo.
    echo [ERROR] At least one plug-in build failed. Not installing.
    exit /b 1
)
if not defined BUILT_ANY (
    echo.
    echo [ERROR] Nothing was built.
    exit /b 1
)
echo.

REM ---------------------------------------------------------- [5] build worker
if defined SKIP_WORKER (
    echo [5/6] Skipping worker build ^(/skip-worker^).
    echo.
    goto do_install
)

echo [5/6] Building the worker process...
echo.
call :build_worker
if defined FAILED (
    echo.
    echo [ERROR] Worker build failed. Not installing.
    exit /b 1
)
echo.

:do_install
if defined BUILD_ONLY (
    echo [6/6] Skipping install ^(/build-only^).
    echo.
    echo Binaries are in %REPO%\bin
    exit /b 0
)

REM -------------------------------------------------------------- [6] install
echo [6/6] Installing to %PLUGIN_DIR%...

if not exist "%NUKE_USER_DIR%" mkdir "%NUKE_USER_DIR%"
if not exist "%PLUGIN_DIR%"    mkdir "%PLUGIN_DIR%"
if not exist "%RUNTIME_TARGET%" mkdir "%RUNTIME_TARGET%"

REM A stray DLL in the search root shadows the versioned one and loads the
REM wrong ABI into Nuke. Upstream's installer clears these too.
if exist "%PLUGIN_DIR%\DLSS5Live.dll"    del /Q /F "%PLUGIN_DIR%\DLSS5Live.dll"    >nul 2>&1
if exist "%NUKE_USER_DIR%\DLSS5Live.dll" del /Q /F "%NUKE_USER_DIR%\DLSS5Live.dll" >nul 2>&1

for /D %%B in ("%REPO%\bin\Nuke*") do call :install_dll "%%~B"
if defined FAILED (
    echo.
    echo [ERROR] Install incomplete.
    exit /b 1
)

if exist "%REPO%\install\init.py"   copy /Y "%REPO%\install\init.py"   "%PLUGIN_DIR%\init.py"   >nul
if exist "%REPO%\install\menu.py"   copy /Y "%REPO%\install\menu.py"   "%PLUGIN_DIR%\menu.py"   >nul
if exist "%REPO%\install\DLSS5.png" copy /Y "%REPO%\install\DLSS5.png" "%PLUGIN_DIR%\DLSS5.png" >nul
if exist "%REPO%\README.md"         copy /Y "%REPO%\README.md"         "%PLUGIN_DIR%\README.md" >nul
if exist "%REPO%\docs\ACES.md"      copy /Y "%REPO%\docs\ACES.md"      "%PLUGIN_DIR%\ACES.md"   >nul
echo       Installed init.py, menu.py, icon and docs

if exist "%REPO%\bin\worker\DLSS_Nuke_Worker.exe" (
    copy /Y "%REPO%\bin\worker\DLSS_Nuke_Worker.exe" "%RUNTIME_TARGET%\DLSS_Nuke_Worker.exe" >nul
    copy /Y "%REPO%\bin\worker\nvngx.dll"            "%RUNTIME_TARGET%\nvngx.dll"            >nul
    echo       Installed DLSS_Nuke_Worker.exe and the caller shim
)

REM Register the plug-in search path. Delegated to a PowerShell script rather
REM than inlined here: the block contains quotes, parentheses and regex
REM metacharacters that cmd's escaping rules mangle.
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%REPO%\tools\register_plugin_path.ps1" -Action install -InitFile "%INIT_FILE%"
if errorlevel 1 (
    echo.
    echo [ERROR] Could not register the plug-in path in %INIT_FILE%.
    echo         The files are installed; add this line to that file by hand:
    echo             nuke.pluginAddPath^(os.path.expanduser^('~/.nuke/DLSS5Live'^)^)
    exit /b 1
)

echo.
echo ===================================================
echo [SUCCESS] Build and install complete.
echo ===================================================
echo.
echo Installed to: %PLUGIN_DIR%
for /D %%B in ("%PLUGIN_DIR%\bin\Nuke*") do echo   [+] bin\%%~nxB\DLSS5Live.dll

if exist "%RUNTIME_TARGET%\DLSS_Nuke_Worker.exe" (
    echo   [+] runtime\DLSS_Nuke_Worker.exe
    echo   [+] runtime\nvngx.dll               ^(project-built caller shim^)
)

echo.
echo ---------------------------------------------------
echo STILL REQUIRED - the NVIDIA runtime
echo ---------------------------------------------------
echo This project does not ship NVIDIA binaries. Put your own legally
echo obtained copies into:
echo   %RUNTIME_TARGET%
echo.
echo   _nvngx.dll           NGX core        ^(note the leading underscore^)
echo   nvngx_dlssnr.dll     DLSS-NR model
echo.
echo Do not overwrite runtime\nvngx.dll - that is this project's caller
echo shim, and it is a different file from NVIDIA's _nvngx.dll.
echo.
echo ---------------------------------------------------
echo TESTING THE ACES FORK
echo ---------------------------------------------------
echo 1. Start Nuke, press Tab, create "DLSS5Live".
echo 2. The node header should read v1.1.0-aces. If it says v1.0.0 you are
echo    still loading an older DLL from somewhere else.
echo 3. Set nvngx.dll ^(Worker^) Path to:
echo    %RUNTIME_TARGET%\DLSS_Nuke_Worker.exe
echo 4. In ACES Color Management, set Working Space to your Nuke working
echo    space ^(ACEScg with a standard OCIO ACES config^).
echo 5. Colour check: set Upscaling Mode to 1.0x ^(DLAA^), then Merge
echo    ^(difference^) the node against its own input. You should see only
echo    the neural difference - no overall cast, no shift on a grey ramp.
echo    Toggle Enable Color Management to compare against upstream behaviour.
echo.
pause
exit /b 0

REM ============================================================================
REM  Subroutines
REM ============================================================================

:usage
echo Usage: tools\build_and_install.bat [options]
echo.
echo   /nuke "PATH"    Nuke install directory. Repeat for several versions.
echo                   Auto-detected when omitted.
echo   /skip-tests     Do not run the colour pipeline verification first.
echo   /skip-worker    Do not build DLSS_Nuke_Worker.exe and the caller shim.
echo   /build-only     Compile into bin\ but do not install into ~\.nuke.
echo   /uninstall      Remove ~\.nuke\DLSS5Live and the init.py registration.
echo   /^?              This help.
echo.
echo Environment:
echo   DLSS5_NUKE_DIRS  Semicolon-separated Nuke directories, used when /nuke
echo                    is not given.
if defined USAGE_EXIT exit /b 1
exit /b 0

REM ---------------------------------------------------------------------------
:find_vs
REM Sets VCVARS and VS_ROOT.
set "VCVARS="
set "VS_ROOT="
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "!VSWHERE!" (
    for /f "usebackq delims=" %%I in (`"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2^>nul`) do (
        if exist "%%I\VC\Auxiliary\Build\vcvars64.bat" (
            set "VS_ROOT=%%I"
            set "VCVARS=%%I\VC\Auxiliary\Build\vcvars64.bat"
        )
    )
)
if defined VCVARS exit /b 0

REM vswhere is missing on some installs; fall back to scanning.
for %%R in ("%ProgramFiles%\Microsoft Visual Studio" "%ProgramFiles(x86)%\Microsoft Visual Studio") do (
    if exist "%%~R" (
        for /f "usebackq delims=" %%F in (`dir /b /s "%%~R\vcvars64.bat" 2^>nul`) do (
            if not defined VCVARS (
                set "VCVARS=%%F"
                for %%P in ("%%F\..\..\..\..") do set "VS_ROOT=%%~fP"
            )
        )
    )
)
exit /b 0

REM ---------------------------------------------------------------------------
:find_tool
REM %1 = executable name, %2 = variable to set.
set "%~2="
for %%X in (%~1) do if not "%%~$PATH:X"=="" set "%~2=%%~$PATH:X"
if defined %~2 exit /b 0
if not defined VS_ROOT exit /b 0

set "_CMDIR=!VS_ROOT!\Common7\IDE\CommonExtensions\Microsoft\CMake"
if /I "%~1"=="cmake.exe" if exist "!_CMDIR!\CMake\bin\cmake.exe" set "%~2=!_CMDIR!\CMake\bin\cmake.exe"
if /I "%~1"=="ninja.exe" if exist "!_CMDIR!\Ninja\ninja.exe"     set "%~2=!_CMDIR!\Ninja\ninja.exe"
exit /b 0

REM ---------------------------------------------------------------------------
:find_nuke
REM Appends every Nuke install carrying an NDK to NUKE_DIRS.
for %%R in ("%ProgramFiles%" "%ProgramFiles(x86)%" "C:\" "D:\") do (
    if exist "%%~R" (
        for /D %%N in ("%%~R\Nuke*") do call :check_nuke "%%~N"
    )
)
exit /b 0

:check_nuke
REM Only accept a directory that actually carries the NDK we link against.
if not exist "%~1\include\DDImage\Iop.h" exit /b 0
if not exist "%~1\DDImage.lib" exit /b 0
echo !NUKE_DIRS! | findstr /I /C:"%~1;" >nul 2>&1 && exit /b 0
set "NUKE_DIRS=!NUKE_DIRS!%~1;"
exit /b 0

REM ---------------------------------------------------------------------------
:install_dll
REM %1 = a bin\Nuke<major> directory produced by :build_plugin.
set "SRCDIR=%~1"
set "BNAME=%~nx1"
if not exist "!SRCDIR!\DLSS5Live.dll" exit /b 0
if not exist "%PLUGIN_DIR%\bin\!BNAME!" mkdir "%PLUGIN_DIR%\bin\!BNAME!"

REM Nuke holds the DLL open while it is running, so a plain copy can fail with
REM the plug-in already loaded. Rotate the old one out of the way rather than
REM leave a half-finished install behind.
copy /Y "!SRCDIR!\DLSS5Live.dll" "%PLUGIN_DIR%\bin\!BNAME!\DLSS5Live.dll" >nul 2>&1
if not errorlevel 1 (
    echo       Installed bin\!BNAME!\DLSS5Live.dll
    exit /b 0
)

if exist "%PLUGIN_DIR%\bin\!BNAME!\DLSS5Live.dll.old" del /Q /F "%PLUGIN_DIR%\bin\!BNAME!\DLSS5Live.dll.old" >nul 2>&1
move /Y "%PLUGIN_DIR%\bin\!BNAME!\DLSS5Live.dll" "%PLUGIN_DIR%\bin\!BNAME!\DLSS5Live.dll.old" >nul 2>&1
copy /Y "!SRCDIR!\DLSS5Live.dll" "%PLUGIN_DIR%\bin\!BNAME!\DLSS5Live.dll" >nul 2>&1
if errorlevel 1 (
    echo       [FAIL] Could not write bin\!BNAME!\DLSS5Live.dll - is Nuke still running?
    set "FAILED=1"
    exit /b 0
)
echo       Installed bin\!BNAME!\DLSS5Live.dll ^(previous one kept as .old^)
exit /b 0

REM ---------------------------------------------------------------------------
:build_plugin
REM %1 = Nuke install directory. Derives the major version from the folder name
REM      so any Nuke release works, not just the two upstream ships DLLs for.
set "NDIR=%~1"
set "NNAME=%~nx1"
set "NVER=!NNAME:Nuke=!"
for /f "tokens=1 delims=.v" %%V in ("!NVER!") do set "NMAJOR=%%V"

if not defined NMAJOR (
    echo       [SKIP] Cannot read a major version from "!NNAME!"
    exit /b 0
)

echo       --- Nuke !NMAJOR!  ^(!NDIR!^)
set "BUILDDIR=%REPO%\build_nuke!NMAJOR!"
set "OUTDIR=%REPO%\bin\Nuke!NMAJOR!"
if not exist "!BUILDDIR!" mkdir "!BUILDDIR!"
if not exist "!OUTDIR!"   mkdir "!OUTDIR!"

set "NDIR_FWD=!NDIR:\=/!"
set "LOG=!BUILDDIR!\build.log"

cmd /c ""!VCVARS!" >nul && cd /d "!BUILDDIR!" && "!CMAKE_EXE!" "%REPO%" -G Ninja -DCMAKE_MAKE_PROGRAM="!NINJA_EXE!" -DCMAKE_BUILD_TYPE=Release -DNUKE_INSTALL_DIR="!NDIR_FWD!" && "!CMAKE_EXE!" --build ." >"!LOG!" 2>&1
if errorlevel 1 (
    echo       [FAIL] Build failed for Nuke !NMAJOR!. Last lines of !LOG!:
    echo.
    powershell.exe -NoProfile -Command "Get-Content '!LOG!' -Tail 25 | ForEach-Object { '            ' + $_ }"
    set "FAILED=1"
    exit /b 0
)

if not exist "!BUILDDIR!\DLSS5Live.dll" (
    echo       [FAIL] Nuke !NMAJOR!: the build reported success but produced no DLL.
    set "FAILED=1"
    exit /b 0
)

REM Nuke keeps the DLL locked while it is running; rotate rather than fail.
copy /Y "!BUILDDIR!\DLSS5Live.dll" "!OUTDIR!\DLSS5Live.dll" >nul 2>&1
if errorlevel 1 (
    if exist "!OUTDIR!\DLSS5Live.dll.old" del /Q /F "!OUTDIR!\DLSS5Live.dll.old" >nul 2>&1
    move /Y "!OUTDIR!\DLSS5Live.dll" "!OUTDIR!\DLSS5Live.dll.old" >nul 2>&1
    copy /Y "!BUILDDIR!\DLSS5Live.dll" "!OUTDIR!\DLSS5Live.dll" >nul
)
echo       [ OK ] bin\Nuke!NMAJOR!\DLSS5Live.dll
set "BUILT_ANY=1"
exit /b 0

REM ---------------------------------------------------------------------------
:build_worker
set "BUILDDIR=%REPO%\build_worker"
set "OUTDIR=%REPO%\bin\worker"
if not exist "!BUILDDIR!" mkdir "!BUILDDIR!"
if not exist "!OUTDIR!"   mkdir "!OUTDIR!"
set "LOG=!BUILDDIR!\build.log"

cmd /c ""!VCVARS!" >nul && cd /d "!BUILDDIR!" && "!CMAKE_EXE!" "%REPO%\worker" -G Ninja -DCMAKE_MAKE_PROGRAM="!NINJA_EXE!" -DCMAKE_BUILD_TYPE=Release && "!CMAKE_EXE!" --build ." >"!LOG!" 2>&1
if errorlevel 1 (
    echo       [FAIL] Worker build failed. Last lines of !LOG!:
    echo.
    powershell.exe -NoProfile -Command "Get-Content '!LOG!' -Tail 25 | ForEach-Object { '            ' + $_ }"
    set "FAILED=1"
    exit /b 0
)

if not exist "!BUILDDIR!\DLSS_Nuke_Worker.exe" (
    echo       [FAIL] DLSS_Nuke_Worker.exe was not produced.
    set "FAILED=1"
    exit /b 0
)
if not exist "!BUILDDIR!\nvngx.dll" (
    echo       [FAIL] The caller shim nvngx.dll was not produced.
    set "FAILED=1"
    exit /b 0
)

copy /Y "!BUILDDIR!\DLSS_Nuke_Worker.exe" "!OUTDIR!\DLSS_Nuke_Worker.exe" >nul
copy /Y "!BUILDDIR!\nvngx.dll"            "!OUTDIR!\nvngx.dll"            >nul
echo       [ OK ] bin\worker\DLSS_Nuke_Worker.exe
echo       [ OK ] bin\worker\nvngx.dll  ^(caller shim, not NVIDIA's runtime^)
exit /b 0

REM ---------------------------------------------------------------------------
:uninstall
echo Removing the plug-in...
echo.

if exist "%PLUGIN_DIR%" (
    rmdir /S /Q "%PLUGIN_DIR%"
    echo   [*] Removed %PLUGIN_DIR%
) else (
    echo   [*] %PLUGIN_DIR% was not present
)

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%REPO%\tools\register_plugin_path.ps1" -Action uninstall -InitFile "%INIT_FILE%" -Indent "  "

echo.
echo Done. Your own init.py content was preserved.
echo.
pause
exit /b 0
