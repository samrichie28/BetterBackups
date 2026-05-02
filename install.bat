@echo off
setlocal EnableDelayedExpansion
TITLE BetterBackups Master Installer

:: ==========================================
:: 1. AUTO-REQUEST ADMINISTRATOR PRIVILEGES
:: ==========================================
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrative Privileges...
    powershell -Command "Start-Process cmd -ArgumentList '/c %~dpnx0' -Verb RunAs"
    exit /b
)

set "INSTALL_DIR=%~dp0"
if "%INSTALL_DIR:~-1%"=="\" set "INSTALL_DIR=%INSTALL_DIR:~0,-1%"

:: ==========================================
:: 2. PRE-FLIGHT CHECKS & USER INPUT
:: ==========================================
cls
echo ========================================
echo  BETTERBACKUPS SETUP PREPARATION
echo ========================================
echo.

:: EARLY EXIT: Check if already installed
sc query BetterBackups >nul 2>&1
if %errorLevel% equ 0 (
    echo [!] BetterBackups is already installed and registered on this system.
    echo [!] The background engine is currently protecting your files.
    echo.
    echo Dashboard: http://localhost:8050
    echo.
    echo (If you need to reinstall or repair the engine, please remove the 
    echo  existing Windows Service first.)
    echo.
    pause
    exit /b
)

python --version >nul 2>&1
if %errorLevel% neq 0 (
    echo ERROR: Python is not installed or not in your system PATH. 
    echo Please install Python 3.10 or higher, ensure "Add to PATH" is checked, and try again.
    pause
    exit /b
)

set "CONFIG_PATH=%INSTALL_DIR%\config.yaml"
if not exist "%CONFIG_PATH%" (
    echo We need to set up your initial Administrator account.
    set /p UI_USER="Create a Web UI Username (Default: admin): "
    if "!UI_USER!"=="" set "UI_USER=admin"

    :: Safely prompt for a hidden password
    for /f "delims=" %%i in ('powershell -Command "$p=Read-Host 'Create a Web UI Password' -AsSecureString; [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($p))"') do set "UI_PASS=%%i"
)

:: ==========================================
:: 3. BUILD THE TEMPORARY WEB UI
:: ==========================================
set "UI_PY=%INSTALL_DIR%\installer_ui.py"
set "LOG_FILE=%INSTALL_DIR%\install_log.txt"
set "STATUS_FILE=%INSTALL_DIR%\install_status.txt"

echo INSTALLING > "%STATUS_FILE%"
echo [*] Initializing Setup Routine... > "%LOG_FILE%"

:: Use PowerShell to safely write the Python Micro-Server file
powershell -Command "$code = @'
import http.server, socketserver, json, os, threading, time

PORT = 8051
LOG_FILE = 'install_log.txt'
STATUS_FILE = 'install_status.txt'

HTML = '''<!DOCTYPE html>
<html lang='en'>
<head>
    <meta charset='UTF-8'>
    <title>BetterBackups Installer</title>
    <script src='https://cdn.tailwindcss.com'></script>
</head>
<body class='bg-gray-950 text-white flex flex-col items-center justify-center min-h-screen p-6 font-sans'>
    <div class='w-full max-w-4xl bg-gray-800 rounded-lg shadow-2xl border border-gray-700 overflow-hidden'>
        <div class='bg-gray-900 px-6 py-4 border-b border-gray-700 flex justify-between items-center'>
            <div class='flex items-center space-x-3'>
                <div class='w-3 h-3 rounded-full bg-blue-500 animate-pulse' id='pulse-dot'></div>
                <h1 class='text-xl font-bold text-cyan-400'>BetterBackups System Setup</h1>
            </div>
            <span id='status-badge' class='px-3 py-1 rounded text-xs font-bold bg-blue-900 text-blue-300'>INSTALLING...</span>
        </div>
        <div class='p-6'>
            <div class='bg-black rounded-lg border border-gray-700 p-4 h-[500px] overflow-y-auto font-mono text-sm text-gray-300 shadow-inner' id='terminal'>
                Initializing...
            </div>
        </div>
    </div>
    <script>
        let interval = setInterval(async () => {
            try {
                let res = await fetch('/api/progress');
                let data = await res.json();
                let term = document.getElementById('terminal');
                
                if (data.logs) {
                    term.textContent = data.logs;
                    term.scrollTop = term.scrollHeight;
                }
                
                if (data.status === 'SUCCESS') {
                    clearInterval(interval);
                    document.getElementById('pulse-dot').className = 'w-3 h-3 rounded-full bg-green-500';
                    let badge = document.getElementById('status-badge');
                    badge.className = 'px-3 py-1 rounded text-xs font-bold bg-green-900 text-green-300';
                    
                    let countdown = 5;
                    setInterval(() => {
                        badge.textContent = 'SUCCESS! REDIRECTING IN ' + countdown + '...';
                        if(countdown === 0) window.location.href = 'http://localhost:8050';
                        countdown--;
                    }, 1000);
                } else if (data.status === 'ERROR') {
                    clearInterval(interval);
                    document.getElementById('pulse-dot').className = 'w-3 h-3 rounded-full bg-red-500';
                    let badge = document.getElementById('status-badge');
                    badge.className = 'px-3 py-1 rounded text-xs font-bold bg-red-900 text-red-300';
                    badge.textContent = 'INSTALLATION FAILED';
                }
            } catch(e) {}
        }, 500);
    </script>
</body>
</html>'''

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args): pass
    
    def do_GET(self):
        if self.path == '/':
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            self.wfile.write(HTML.encode('utf-8'))
        elif self.path == '/api/progress':
            logs = ''
            if os.path.exists(LOG_FILE):
                with open(LOG_FILE, 'r', encoding='utf-8', errors='replace') as f: logs = f.read()
            status = 'INSTALLING'
            if os.path.exists(STATUS_FILE):
                with open(STATUS_FILE, 'r', encoding='utf-8', errors='replace') as f: status = f.read().strip()
            
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'logs': logs, 'status': status}).encode('utf-8'))
            
            if status in ['SUCCESS', 'ERROR']:
                threading.Thread(target=self.delayed_shutdown).start()
        else:
            self.send_response(404)
            self.end_headers()
            
    def delayed_shutdown(self):
        time.sleep(8)
        os._exit(0)

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(('', PORT), Handler) as httpd:
    httpd.serve_forever()
'@; Set-Content -Path '%UI_PY%' -Value $code -Encoding UTF8"

:: ==========================================
:: 4. LAUNCH UI & RUN SILENT INSTALLER
:: ==========================================
start /B python "%UI_PY%"
timeout /t 2 >nul
start http://localhost:8051

:: Route all operations to the background subroutine
call :DO_INSTALL >> "%LOG_FILE%" 2>&1

if %errorLevel% equ 0 (
    echo. >> "%LOG_FILE%"
    echo ======================================== >> "%LOG_FILE%"
    echo  INSTALLATION COMPLETE! >> "%LOG_FILE%"
    echo ======================================== >> "%LOG_FILE%"
    echo SUCCESS > "%STATUS_FILE%"
) else (
    echo. >> "%LOG_FILE%"
    echo ======================================== >> "%LOG_FILE%"
    echo  ERROR: INSTALLATION FAILED! >> "%LOG_FILE%"
    echo ======================================== >> "%LOG_FILE%"
    echo ERROR > "%STATUS_FILE%"
)

:: Wait for the Web UI to catch the success flag, then clean up temp files
timeout /t 10 >nul
del "%UI_PY%" >nul 2>&1
del "%LOG_FILE%" >nul 2>&1
del "%STATUS_FILE%" >nul 2>&1
exit /b

:: ==========================================
:: BACKGROUND INSTALLATION ROUTINE
:: ==========================================
:DO_INSTALL
echo ========================================
echo  BETTERBACKUPS BACKGROUND INSTALLER
echo ========================================
echo.

set "BIN_DIR=%INSTALL_DIR%\bin"
set "LOGS_DIR=%INSTALL_DIR%\logs"

if not exist "%BIN_DIR%" mkdir "%BIN_DIR%"
if not exist "%LOGS_DIR%" mkdir "%LOGS_DIR%"

echo [*] Creating isolated Python Virtual Environment...
if not exist "%INSTALL_DIR%\venv" (
    python -m venv "%INSTALL_DIR%\venv"
)

echo [*] Upgrading PIP...
"%INSTALL_DIR%\venv\Scripts\python.exe" -m pip install --upgrade pip

echo [*] Installing BetterBackups Python Dependencies...
"%INSTALL_DIR%\venv\Scripts\pip.exe" install -r "%INSTALL_DIR%\requirements.txt"

set "NSSM_EXE=%BIN_DIR%\nssm.exe"
if not exist "%NSSM_EXE%" (
    echo [*] Downloading NSSM ^(Windows Service Manager^)...
    powershell -Command "Invoke-WebRequest -Uri 'https://nssm.cc/release/nssm-2.24.zip' -OutFile '%BIN_DIR%\nssm.zip'"
    powershell -Command "Expand-Archive -Path '%BIN_DIR%\nssm.zip' -DestinationPath '%BIN_DIR%\nssm_temp' -Force"
    move /y "%BIN_DIR%\nssm_temp\nssm-2.24\win64\nssm.exe" "%NSSM_EXE%"
    rmdir /s /q "%BIN_DIR%\nssm_temp"
    del /q "%BIN_DIR%\nssm.zip"
)

set "RCLONE_EXE=%BIN_DIR%\rclone.exe"
if not exist "%RCLONE_EXE%" (
    echo [*] Downloading Rclone...
    powershell -Command "Invoke-WebRequest -Uri 'https://downloads.rclone.org/rclone-current-windows-amd64.zip' -OutFile '%BIN_DIR%\rclone.zip'"
    powershell -Command "Expand-Archive -Path '%BIN_DIR%\rclone.zip' -DestinationPath '%BIN_DIR%\rclone_temp' -Force"
    for /d %%I in ("%BIN_DIR%\rclone_temp\*") do move /y "%%I\rclone.exe" "%RCLONE_EXE%"
    rmdir /s /q "%BIN_DIR%\rclone_temp"
    del /q "%BIN_DIR%\rclone.zip"
)

if not exist "%CONFIG_PATH%" (
    echo [*] Generating secure configuration file...
    
    :: Generate PBKDF2 hash using Python safely
    for /f "delims=" %%H in ('"%INSTALL_DIR%\venv\Scripts\python.exe" -c "import hashlib, secrets, os; salt = secrets.token_hex(16); pw = os.environ.get('UI_PASS', ''); print(f'{salt}:{hashlib.pbkdf2_hmac(\"sha256\", pw.encode(\"utf-8\"), salt.encode(\"utf-8\"), 100000).hex()}')"') do set "HASH_OUT=%%H"

    echo app: > "%CONFIG_PATH%"
    echo   port: 8050 >> "%CONFIG_PATH%"
    echo   host: 0.0.0.0 >> "%CONFIG_PATH%"
    echo   log_level: INFO >> "%CONFIG_PATH%"
    echo   log_retention_days: 7 >> "%CONFIG_PATH%"
    echo security: >> "%CONFIG_PATH%"
    echo   auth_enabled: true >> "%CONFIG_PATH%"
    echo   username: !UI_USER! >> "%CONFIG_PATH%"
    echo   password_hash: !HASH_OUT! >> "%CONFIG_PATH%"
    echo   trusted_proxies: '' >> "%CONFIG_PATH%"
    echo   max_login_strikes: 5 >> "%CONFIG_PATH%"
    echo   lockout_duration_minutes: 15 >> "%CONFIG_PATH%"
    echo paths: >> "%CONFIG_PATH%"
    echo   rclone_exe: %RCLONE_EXE% >> "%CONFIG_PATH%"
    echo   rclone_config: %INSTALL_DIR%\rclone.conf >> "%CONFIG_PATH%"
    echo jobs: {} >> "%CONFIG_PATH%"
    echo notifications: >> "%CONFIG_PATH%"
    echo   discord_webhook_url: '' >> "%CONFIG_PATH%"
    
    :: Clear password from memory immediately
    set "UI_PASS=" 
)

echo [*] Checking Windows Firewall...
netsh advfirewall firewall show rule name="BetterBackups Web UI" >nul 2>&1
if %errorLevel% neq 0 (
    echo [*] Adding Port 8050 to Windows Firewall...
    netsh advfirewall firewall add rule name="BetterBackups Web UI" dir=in action=allow protocol=TCP localport=8050
)

echo [*] Registering Windows Background Service...
set "SERVICE_NAME=BetterBackups"
"%NSSM_EXE%" install %SERVICE_NAME% "%INSTALL_DIR%\venv\Scripts\python.exe"

"%NSSM_EXE%" set %SERVICE_NAME% AppParameters "-m uvicorn web.app:app --host 0.0.0.0 --port 8050"
"%NSSM_EXE%" set %SERVICE_NAME% AppDirectory "%INSTALL_DIR%"
"%NSSM_EXE%" set %SERVICE_NAME% AppStdout "%LOGS_DIR%\service.log"
"%NSSM_EXE%" set %SERVICE_NAME% AppStderr "%LOGS_DIR%\service.log"
"%NSSM_EXE%" set %SERVICE_NAME% AppStopMethodSkip 0
"%NSSM_EXE%" set %SERVICE_NAME% AppStopMethodConsole 15000

echo [*] Starting BetterBackups Service...
net start %SERVICE_NAME%

:: Delay slightly to ensure service bounds to port
timeout /t 3 >nul
exit /b 0