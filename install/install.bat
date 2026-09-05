@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
title DLSS 5 for Nuke (ACES fork) - Installer

REM ============================================================================
REM  Installs prebuilt DLSS5Live binaries into %USERPROFILE%\.nuke.
REM
REM  No compiler, no CMake, no Visual Studio, no Nuke NDK. Run this from an
REM  extracted Release ZIP. To build from source instead, use
REM  tools\build_and_install.bat.
REM
REM  Any previous install is removed first, including one made by the original
REM  upstream installer. The one thing that is never touched is the NVIDIA
REM  runtime you supplied yourself.
REM
REM  Usage:
REM    install.bat                  install or upgrade
REM    install.bat /keep-versions   keep DLLs for Nuke versions this package
REM                                 does not ship
REM    install.bat /uninstall       remove the plug-in
REM    install.bat /y               do not wait for a keypress at the end
REM ============================================================================

REM Resolve everything that depends on %~dp0 BEFORE parsing arguments. `shift`
REM reassigns %0, so after the first shift %~dp0 no longer points at this script
REM and quietly resolves against the current directory instead.
set "SCRIPT_DIR=%~dp0"

set "NUKE_USER_DIR=%USERPROFILE%\.nuke"
set "PLUGIN_DIR=%NUKE_USER_DIR%\DLSS5Live"
set "RUNTIME_TARGET=%PLUGIN_DIR%\runtime"
set "INIT_FILE=%NUKE_USER_DIR%\init.py"

REM The ZIP puts everything beside install.bat; a repo checkout has it one level
REM up, inside install\.
set "PKG=%SCRIPT_DIR%"
if not exist "%PKG%bin" if exist "%SCRIPT_DIR%..\bin" set "PKG=%SCRIPT_DIR%..\"

set "REGISTER_PS1=%SCRIPT_DIR%register_plugin_path.ps1"
if not exist "%REGISTER_PS1%" set "REGISTER_PS1=%PKG%install\register_plugin_path.ps1"

set "DO_UNINSTALL="
set "KEEP_VERSIONS="
set "NO_PAUSE="

:parse_args
if "%~1"=="" goto args_done
if /I "%~1"=="/?"             goto usage
if /I "%~1"=="/help"          goto usage
if /I "%~1"=="/uninstall"     set "DO_UNINSTALL=1"   & shift & goto parse_args
if /I "%~1"=="/keep-versions" set "KEEP_VERSIONS=1"  & shift & goto parse_args
if /I "%~1"=="/y"             set "NO_PAUSE=1"       & shift & goto parse_args
echo [ERROR] Unknown option: %~1
echo.
set "USAGE_EXIT=1"
goto usage
:args_done

echo ===================================================
echo   DLSS 5 for Foundry Nuke - ACES fork
echo   Installer
echo ===================================================
echo.

if defined DO_UNINSTALL goto uninstall

REM -------------------------------------------------------- what is in the box
call :read_package_version
call :count_package_dlls

if "!PKG_DLL_COUNT!"=="0" (
    echo [ERROR] This package contains no compiled plug-in.
    echo.
    echo         Expected at least one of:
    echo           %PKG%bin\Nuke15\DLSS5Live.dll
    echo           %PKG%bin\Nuke17\DLSS5Live.dll
    echo.
    echo         If you downloaded a Release ZIP, it is incomplete - please
    echo         report it. If you are running from a source checkout, there
    echo         are no binaries to install; build them first with:
    echo           tools\build_and_install.bat
    goto fail
)

echo   Package  : !PKG_VERSION!
echo   Contains : !PKG_MAJORS!
echo   Target   : %PLUGIN_DIR%
echo.

REM ------------------------------------------------- [1] previous installation
echo [1/4] Checking for a previous installation...
call :read_installed_version
call :list_installed_majors

if not defined FOUND_PREVIOUS (
    echo       None found. This is a fresh install.
) else (
    echo       Found    : !INSTALLED_VERSION!
    if defined INSTALLED_MAJORS echo       DLLs for : !INSTALLED_MAJORS!
    call :warn_dropped_majors
)
echo.

REM ------------------------------------------------------- [2] remove the old
echo [2/4] Removing the previous installation...

if not exist "%PLUGIN_DIR%" mkdir "%PLUGIN_DIR%"
if not exist "%RUNTIME_TARGET%" mkdir "%RUNTIME_TARGET%"

REM A DLL sitting in the search root shadows the versioned one and loads the
REM wrong ABI into Nuke.
call :remove_file "%PLUGIN_DIR%\DLSS5Live.dll"
call :remove_file "%NUKE_USER_DIR%\DLSS5Live.dll"

if defined KEEP_VERSIONS (
    echo       Keeping DLLs for Nuke versions this package does not ship ^(/keep-versions^)
    for %%M in (!PKG_MAJORS_RAW!) do call :remove_dir "%PLUGIN_DIR%\bin\Nuke%%M"
) else (
    for /D %%B in ("%PLUGIN_DIR%\bin\Nuke*") do call :remove_dir "%%~B"
)

call :remove_file "%PLUGIN_DIR%\init.py"
call :remove_file "%PLUGIN_DIR%\menu.py"
call :remove_file "%PLUGIN_DIR%\DLSS5.png"
call :remove_file "%PLUGIN_DIR%\README.md"
call :remove_file "%PLUGIN_DIR%\ACES.md"
call :remove_file "%PLUGIN_DIR%\VERSION.txt"
call :remove_file "%PLUGIN_DIR%\uninstall.bat"
call :remove_file "%PLUGIN_DIR%\install.bat"
call :remove_file "%PLUGIN_DIR%\register_plugin_path.ps1"

REM Only the two files this project owns. Everything else under runtime\ is the
REM NVIDIA runtime the user supplied, and re-obtaining it is a nuisance, so it
REM is deliberately left in place.
call :remove_file "%RUNTIME_TARGET%\DLSS_Nuke_Worker.exe"
call :remove_file "%RUNTIME_TARGET%\nvngx.dll"

if defined REMOVED_ANY (
    echo       Your NVIDIA runtime files under runtime\ were left untouched.
) else (
    echo       Nothing to remove.
)
echo.

REM ------------------------------------------------------------ [3] install
echo [3/4] Installing...

for /D %%B in ("%PKG%bin\Nuke*") do call :install_dll "%%~B"
if defined FAILED goto fail

call :copy_if "%PKG%init.py"   "%PLUGIN_DIR%\init.py"
call :copy_if "%PKG%menu.py"   "%PLUGIN_DIR%\menu.py"
call :copy_if "%PKG%DLSS5.png" "%PLUGIN_DIR%\DLSS5.png"
call :copy_if "%PKG%README.md" "%PLUGIN_DIR%\README.md"
call :copy_if "%PKG%ACES.md"   "%PLUGIN_DIR%\ACES.md"
echo       Installed init.py, menu.py, icon and docs

if exist "%PKG%runtime\DLSS_Nuke_Worker.exe" (
    copy /Y "%PKG%runtime\DLSS_Nuke_Worker.exe" "%RUNTIME_TARGET%\DLSS_Nuke_Worker.exe" >nul
    echo       Installed runtime\DLSS_Nuke_Worker.exe
)
if exist "%PKG%runtime\nvngx.dll" (
    copy /Y "%PKG%runtime\nvngx.dll" "%RUNTIME_TARGET%\nvngx.dll" >nul
    echo       Installed runtime\nvngx.dll ^(caller shim^)
)

REM Leave the uninstaller behind. Someone who installed from a one-click .exe
REM has no extracted ZIP to go back to, so without this there is no way to
REM remove the plug-in cleanly.
REM
REM The entry point goes one level up, beside the plug-in folder rather than
REM inside it: an uninstaller that lives in the directory it deletes is pulled
REM out from under cmd mid-run, and everything after the deletion silently stops
REM happening.
call :copy_if "%SCRIPT_DIR%install.bat" "%PLUGIN_DIR%\install.bat"
call :copy_if "%REGISTER_PS1%"          "%PLUGIN_DIR%\register_plugin_path.ps1"
call :copy_if "%PKG%DLSS5Live-uninstall.bat" "%NUKE_USER_DIR%\DLSS5Live-uninstall.bat"
if exist "%NUKE_USER_DIR%\DLSS5Live-uninstall.bat" echo       Installed ..\DLSS5Live-uninstall.bat

REM A stamp so the next run can report what it is replacing.
>"%PLUGIN_DIR%\VERSION.txt" echo !PKG_VERSION!
>>"%PLUGIN_DIR%\VERSION.txt" echo installed=%DATE% %TIME%
>>"%PLUGIN_DIR%\VERSION.txt" echo nuke=!PKG_MAJORS_RAW!
echo.

REM ---------------------------------------------------------- [4] register
echo [4/4] Registering the plug-in path...
if not exist "!REGISTER_PS1!" (
    echo       [WARN] register_plugin_path.ps1 is missing from this package.
    echo              Add this to %INIT_FILE% by hand:
    echo                  import os, nuke
    echo                  nuke.pluginAddPath^(os.path.expanduser^('~/.nuke/DLSS5Live'^)^)
) else (
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File "!REGISTER_PS1!" -Action install -InitFile "%INIT_FILE%"
)
echo.

echo ===================================================
echo [SUCCESS] Installed !PKG_VERSION!
echo ===================================================
echo.
call :report_runtime
echo.
echo Next: start Nuke, press Tab, create "DLSS5Live".
echo The node header should read !PKG_VERSION!.
echo.
if not defined NO_PAUSE pause
exit /b 0

REM ============================================================================
REM  Subroutines
REM ============================================================================

:usage
echo Usage: install.bat [options]
echo.
echo   /keep-versions  Keep installed DLLs for Nuke versions this package does
echo                   not ship. By default every previously installed DLL is
echo                   removed so no stale build can be loaded.
echo   /uninstall      Remove the plug-in and the init.py registration.
echo   /y              Do not wait for a keypress at the end.
echo   /^?              This help.
if defined USAGE_EXIT exit /b 1
exit /b 0

REM ---------------------------------------------------------------------------
:read_package_version
set "PKG_VERSION=unknown version"
if exist "%PKG%VERSION.txt" (
    for /f "usebackq delims=" %%V in ("%PKG%VERSION.txt") do (
        if not defined _GOTVER set "PKG_VERSION=%%V" & set "_GOTVER=1"
    )
)
set "_GOTVER="
exit /b 0

REM ---------------------------------------------------------------------------
:count_package_dlls
set "PKG_DLL_COUNT=0"
set "PKG_MAJORS="
set "PKG_MAJORS_RAW="
for /D %%B in ("%PKG%bin\Nuke*") do call :count_one "%%~B"
if "!PKG_DLL_COUNT!"=="0" set "PKG_MAJORS=none"
exit /b 0

:count_one
if not exist "%~1\DLSS5Live.dll" exit /b 0
set /a PKG_DLL_COUNT+=1
set "_N=%~nx1"
set "_M=!_N:Nuke=!"
set "PKG_MAJORS=!PKG_MAJORS!Nuke!_M! "
set "PKG_MAJORS_RAW=!PKG_MAJORS_RAW!!_M! "
exit /b 0

REM ---------------------------------------------------------------------------
:read_installed_version
set "FOUND_PREVIOUS="
set "INSTALLED_VERSION=an unlabelled build"
if not exist "%PLUGIN_DIR%" exit /b 0
set "FOUND_PREVIOUS=1"
if exist "%PLUGIN_DIR%\VERSION.txt" (
    for /f "usebackq delims=" %%V in ("%PLUGIN_DIR%\VERSION.txt") do (
        if not defined _GOTIVER set "INSTALLED_VERSION=%%V" & set "_GOTIVER=1"
    )
)
set "_GOTIVER="
exit /b 0

REM ---------------------------------------------------------------------------
:list_installed_majors
set "INSTALLED_MAJORS="
set "INSTALLED_MAJORS_RAW="
if not exist "%PLUGIN_DIR%\bin" exit /b 0
for /D %%B in ("%PLUGIN_DIR%\bin\Nuke*") do call :list_one "%%~B"
exit /b 0

:list_one
if not exist "%~1\DLSS5Live.dll" exit /b 0
set "_N=%~nx1"
set "INSTALLED_MAJORS=!INSTALLED_MAJORS!!_N! "
set "INSTALLED_MAJORS_RAW=!INSTALLED_MAJORS_RAW!!_N:Nuke=! "
exit /b 0

REM ---------------------------------------------------------------------------
:warn_dropped_majors
REM Deleting a DLL for a Nuke version the new package does not ship would leave
REM that Nuke without the plug-in, so say so rather than doing it quietly.
if defined KEEP_VERSIONS exit /b 0
if not defined INSTALLED_MAJORS_RAW exit /b 0
set "DROPPED="
for %%I in (!INSTALLED_MAJORS_RAW!) do call :check_dropped %%I
if not defined DROPPED exit /b 0
echo.
echo       [NOTE] This package has no DLL for Nuke:!DROPPED!
echo              Those will be removed, so the plug-in will stop appearing in
echo              that version of Nuke. Pass /keep-versions to leave them.
exit /b 0

:check_dropped
echo !PKG_MAJORS_RAW! | findstr /C:"%~1 " >nul 2>&1 && exit /b 0
set "DROPPED=!DROPPED! %~1"
exit /b 0

REM ---------------------------------------------------------------------------
:remove_file
if not exist "%~1" exit /b 0
del /Q /F "%~1" >nul 2>&1
if exist "%~1" (
    echo       [WARN] Could not remove "%~1" - is Nuke still running?
    exit /b 0
)
echo       Removed %~nx1
set "REMOVED_ANY=1"
exit /b 0

:remove_dir
if not exist "%~1" exit /b 0
rmdir /S /Q "%~1" >nul 2>&1
if exist "%~1" (
    echo       [WARN] Could not remove "%~1" - is Nuke still running?
    exit /b 0
)
echo       Removed bin\%~nx1
set "REMOVED_ANY=1"
exit /b 0

REM ---------------------------------------------------------------------------
:copy_if
if not exist "%~1" exit /b 0
copy /Y "%~1" "%~2" >nul
exit /b 0

REM ---------------------------------------------------------------------------
:install_dll
if not exist "%~1\DLSS5Live.dll" exit /b 0
set "_N=%~nx1"
if not exist "%PLUGIN_DIR%\bin\!_N!" mkdir "%PLUGIN_DIR%\bin\!_N!"
copy /Y "%~1\DLSS5Live.dll" "%PLUGIN_DIR%\bin\!_N!\DLSS5Live.dll" >nul 2>&1
if errorlevel 1 (
    echo       [FAIL] Could not write bin\!_N!\DLSS5Live.dll - close Nuke and try again.
    set "FAILED=1"
    exit /b 0
)
echo       Installed bin\!_N!\DLSS5Live.dll
exit /b 0

REM ---------------------------------------------------------------------------
:report_runtime
echo ---------------------------------------------------
echo NVIDIA runtime
echo ---------------------------------------------------
echo This project ships no NVIDIA binaries. Put your own legally obtained
echo copies in:
echo   %RUNTIME_TARGET%
echo.
call :runtime_line "_nvngx.dll"       "NGX core          - you supply this"
call :runtime_line "nvngx_dlssnr.dll" "DLSS-NR model     - you supply this"
call :runtime_line "nvngx.dll"        "caller shim       - shipped by this project"
call :runtime_line "DLSS_Nuke_Worker.exe" "worker process    - shipped by this project"
echo.
echo Do not overwrite runtime\nvngx.dll with NVIDIA's file: the shim and
echo NVIDIA's _nvngx.dll are different files that both have to be present.
exit /b 0

:runtime_line
if exist "%RUNTIME_TARGET%\%~1" (
    echo   [ok     ] %~1
) else (
    echo   [MISSING] %~1   ^(%~2^)
)
exit /b 0

REM ---------------------------------------------------------------------------
:uninstall
echo Removing the plug-in...
echo.

if exist "%PLUGIN_DIR%" (
    call :save_runtime_note
    REM Never hold the directory open while deleting it.
    cd /d "%TEMP%" >nul 2>&1
    rmdir /S /Q "%PLUGIN_DIR%" >nul 2>&1
    if exist "%PLUGIN_DIR%" (
        echo   [WARN] Could not fully remove %PLUGIN_DIR% - close Nuke and retry.
    ) else (
        echo   [*] Removed %PLUGIN_DIR%
    )
) else (
    echo   [*] %PLUGIN_DIR% was not present
)

if exist "!REGISTER_PS1!" (
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File "!REGISTER_PS1!" -Action uninstall -InitFile "%INIT_FILE%" -Indent "  "
) else (
    echo   [!] register_plugin_path.ps1 not found; remove the DLSS5 block from
    echo       %INIT_FILE% by hand.
)

REM DLSS5Live-uninstall.bat is almost certainly the script that called us, and
REM cmd reads the next line of a batch file after a `call` returns. Deleting it
REM here kills the caller mid-run with "The batch file cannot be found" - which
REM is exactly how the init.py cleanup above got skipped once. Leave it and say
REM so instead.
if exist "%NUKE_USER_DIR%\DLSS5Live-uninstall.bat" (
    echo.
    echo   [*] You can now delete:
    echo       %NUKE_USER_DIR%\DLSS5Live-uninstall.bat
)

if exist "%NUKE_USER_DIR%\runtime" (
    echo.
    echo   [!] %NUKE_USER_DIR%\runtime still exists. That is the legacy runtime
    echo       location and it was not touched, in case your NVIDIA files are
    echo       in it.
)

echo.
echo Done. Your own init.py content was preserved.
echo.
if not defined NO_PAUSE pause
exit /b 0

:save_runtime_note
REM Uninstall removes runtime\ along with everything else, so warn first: the
REM NVIDIA files in there were supplied by the user and are not re-downloadable
REM from this project.
if not exist "%RUNTIME_TARGET%\_nvngx.dll" if not exist "%RUNTIME_TARGET%\nvngx_dlssnr.dll" exit /b 0
echo   [!] %RUNTIME_TARGET% contains NVIDIA runtime files you supplied.
echo       They are about to be deleted along with the plug-in folder. Copy
echo       them elsewhere now if you want to keep them.
echo.
if defined NO_PAUSE exit /b 0
pause
exit /b 0

REM ---------------------------------------------------------------------------
:fail
echo.
if not defined NO_PAUSE pause
exit /b 1
