@echo off
setlocal EnableDelayedExpansion
TITLE BetterBackups Uninstaller

:: Auto-Request Admin
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrative Privileges...
    powershell -Command "Start-Process cmd -ArgumentList '/c %~dpnx0' -Verb RunAs"
    exit /b
)

set "INSTALL_DIR=%~dp0"
if "%INSTALL_DIR:~-1%"=="\" set "INSTALL_DIR=%INSTALL_DIR:~0,-1%"
set "NSSM_EXE=%INSTALL_DIR%\bin\nssm.exe"
set "SERVICE_NAME=BetterBackups"

echo ========================================
echo  UNINSTALLING BETTERBACKUPS
echo ========================================
echo.

echo [*] Stopping Windows Service...
net stop %SERVICE_NAME% >nul 2>&1

if exist "%NSSM_EXE%" (
    echo [*] Removing Windows Service...
    "%NSSM_EXE%" remove %SERVICE_NAME% confirm >nul 2>&1
) else (
    echo [!] NSSM not found, attempting native service removal...
    sc delete %SERVICE_NAME% >nul 2>&1
)

echo [*] Removing Windows Firewall Rules...
netsh advfirewall firewall delete rule name="BetterBackups Web UI" >nul 2>&1

echo.
echo ========================================
echo  UNINSTALL COMPLETE
echo ========================================
echo The BetterBackups background service and firewall rules have been removed.
echo You can now safely delete this entire folder.
echo.
pause