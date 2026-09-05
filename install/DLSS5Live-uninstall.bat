@echo off
setlocal
chcp 65001 >nul
title DLSS 5 for Nuke (ACES fork) - Uninstall

REM ============================================================================
REM  Installed to %USERPROFILE%\.nuke\DLSS5Live-uninstall.bat by install.bat.
REM
REM  It lives one level above the plug-in folder on purpose. An uninstaller that
REM  sits inside the directory it deletes gets pulled out from under cmd while
REM  it is still reading lines from it: the folder goes, the script dies with an
REM  error, and everything after the deletion - cleaning the init.py entry -
REM  never runs.
REM
REM  So: copy the real installer out to %TEMP%, run the uninstall from there,
REM  and let this file survive to tidy up afterwards.
REM ============================================================================

set "PLUGIN_DIR=%~dp0DLSS5Live"
set "TMPD=%TEMP%\DLSS5Live-uninstall"

if not exist "%PLUGIN_DIR%\install.bat" (
    echo.
    echo The plug-in does not look installed at:
    echo   %PLUGIN_DIR%
    echo.
    echo Nothing to do. You can delete this file.
    echo.
    if /I not "%~1"=="/y" pause
    exit /b 1
)

if exist "%TMPD%" rmdir /S /Q "%TMPD%" >nul 2>&1
mkdir "%TMPD%" >nul 2>&1
if not exist "%TMPD%" (
    echo [ERROR] Could not create "%TMPD%".
    if /I not "%~1"=="/y" pause
    exit /b 1
)

copy /Y "%PLUGIN_DIR%\install.bat" "%TMPD%\install.bat" >nul
if exist "%PLUGIN_DIR%\register_plugin_path.ps1" (
    copy /Y "%PLUGIN_DIR%\register_plugin_path.ps1" "%TMPD%\register_plugin_path.ps1" >nul
)

REM Leave the plug-in folder before anything tries to delete it.
cd /d "%TMPD%"
call "%TMPD%\install.bat" /uninstall %*
set "RC=%ERRORLEVEL%"

cd /d "%USERPROFILE%"
rmdir /S /Q "%TMPD%" >nul 2>&1
exit /b %RC%
