@echo off
setlocal DisableDelayedExpansion
TITLE BetterBackups Master Installer

:: ==========================================
:: 1. AUTO-REQUEST ADMINISTRATOR PRIVILEGES
:: ==========================================
net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~dpnx0\"' -Verb RunAs"
    exit /b
)

:: Force directory to script location
cd /d "%~dp0"
set "INSTALL_DIR=%~dp0"
if "%INSTALL_DIR:~-1%"=="\" set "INSTALL_DIR=%INSTALL_DIR:~0,-1%"

:: ==========================================
:: 2. PRE-FLIGHT CHECKS
:: ==========================================
cls
echo ========================================
echo  BETTERBACKUPS SETUP PREPARATION
echo ========================================
echo.

sc query BetterBackups >nul 2>&1
if %errorLevel% equ 0 (
    color 0E
    echo [!] BetterBackups is already installed. Run uninstall.bat first.
    pause
    exit /b
)

python --version >nul 2>&1
if %errorLevel% neq 0 (
    color 0C
    echo [X] Python not found. Please install Python 3.10+ and add to PATH.
    pause
    exit /b
)

:: ==========================================
:: 3. COLLECT CREDENTIALS
:: ==========================================
set "CONFIG_PATH=%INSTALL_DIR%\config.yaml"
if exist "%CONFIG_PATH%" goto :SKIP_CREDS

set /p UI_USER="Create Admin Username (Default: admin): "
if "%UI_USER%"=="" set "UI_USER=admin"

:: Hidden password prompt via PowerShell
for /f "delims=" %%i in ('powershell -Command "$p=Read-Host 'Create Admin Password' -AsSecureString; [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($p))"') do set "UI_PASS=%%i"

:SKIP_CREDS

:: ==========================================
:: 4. EXTRACT PAYLOADS (ROBUST SPLIT METHOD)
:: ==========================================
set "LOG_FILE=%INSTALL_DIR%\install_log.txt"
set "STATUS_FILE=%INSTALL_DIR%\install_status.txt"
set "UI_PY=%INSTALL_DIR%\installer_ui.py"
set "SETUP_PS=%INSTALL_DIR%\setup.ps1"

echo [*] Initializing Setup Routine... > "%LOG_FILE%"
echo INSTALLING > "%STATUS_FILE%"

:: Extract using PowerShell Split (Immune to Batch parsing bugs)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c = [IO.File]::ReadAllText('%~f0'); $ui = $c -split '# <BEGIN_UI>\r?\n' | Select-Object -Last 1; $ui = $ui -split '# <END_UI>' | Select-Object -First 1; [IO.File]::WriteAllText('%UI_PY%', $ui); $ps = $c -split '# <BEGIN_PS>\r?\n' | Select-Object -Last 1; $ps = $ps -split '# <END_PS>' | Select-Object -First 1; [IO.File]::WriteAllText('%SETUP_PS%', $ps)"

if not exist "%UI_PY%" (
    color 0C
    echo [X] Extraction failed. Check folder permissions.
    pause
    exit /b
)

:: ==========================================
:: 5. LAUNCH UI & RUN INSTALLER
:: ==========================================
echo [*] Launching Setup UI...
:: We launch the UI with "python" so any silent crashes write to the CMD window
start /B python "%UI_PY%"
timeout /t 3 >nul
start http://localhost:8051

:: Run PowerShell Setup with gathered credentials passed as environment variables
set "TEMP_USER=%UI_USER%"
set "TEMP_PASS=%UI_PASS%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SETUP_PS%" -InstallDir "%INSTALL_DIR%" >> "%LOG_FILE%" 2>&1

if %errorLevel% equ 0 (
    echo SUCCESS > "%STATUS_FILE%"
    timeout /t 10 >nul
) else (
    echo ERROR > "%STATUS_FILE%"
    color 0C
    echo [X] INSTALLATION FAILED! Check the browser for logs.
    pause
)

:: Cleanup
set "TEMP_USER="
set "TEMP_PASS="
del "%UI_PY%" >nul 2>&1
del "%SETUP_PS%" >nul 2>&1
exit /b

:: ==========================================
:: PAYLOADS (DO NOT EDIT BELOW THIS LINE)
:: ==========================================

# <BEGIN_UI>
import http.server, socketserver, json, os, threading, time
PORT = 8051
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_FILE = os.path.join(BASE_DIR, 'install_log.txt')
STATUS_FILE = os.path.join(BASE_DIR, 'install_status.txt')
HTML = """
<!DOCTYPE html>
<html>
<head>
    <title>BetterBackups Setup</title>
    <script src='https://cdn.tailwindcss.com'></script>
    <style>
        body { background-color: #030712; color: #f9fafb; font-family: ui-sans-serif, system-ui; }
        .terminal-box { background-color: #000; border: 1px solid #374151; border-radius: 0.5rem; padding: 1rem; height: 500px; overflow-y: auto; font-family: ui-monospace, monospace; font-size: 0.875rem; white-space: pre-wrap; color: #d1d5db; }
    </style>
</head>
<body class='flex flex-col items-center justify-center min-h-screen p-6'>
    <div class='w-full max-w-4xl bg-gray-800 rounded-lg shadow-2xl border border-gray-700 overflow-hidden'>
        <div class='bg-gray-900 px-6 py-4 border-b border-gray-700 flex justify-between items-center'>
            <div class='flex items-center space-x-3'>
                <div class='w-3 h-3 rounded-full bg-blue-500 animate-pulse' id='pulse-dot'></div>
                <h1 class='text-xl font-bold text-cyan-400'>System Installation Status</h1>
            </div>
            <span id='status-badge' class='px-3 py-1 rounded text-xs font-bold bg-blue-900 text-blue-300 uppercase'>Initializing...</span>
        </div>
        <div class='p-6'>
            <div class='terminal-box' id='terminal'>Awaiting log stream...</div>
        </div>
    </div>
    <script>
        const terminal = document.getElementById('terminal');
        const badge = document.getElementById('status-badge');
        const dot = document.getElementById('pulse-dot');

        async function updateProgress() {
            try {
                const res = await fetch('/api/progress');
                const data = await res.json();
                
                if (data.logs) {
                    const shouldScroll = terminal.scrollHeight - terminal.clientHeight <= terminal.scrollTop + 50;
                    terminal.textContent = data.logs;
                    if (shouldScroll) { terminal.scrollTop = terminal.scrollHeight; }
                }

                if (data.status === 'SUCCESS') {
                    badge.textContent = 'Success! Redirecting...';
                    badge.className = 'px-3 py-1 rounded text-xs font-bold bg-green-900 text-green-300 uppercase';
                    dot.className = 'w-3 h-3 rounded-full bg-green-500';
                    setTimeout(() => window.location.href = 'http://localhost:8050', 5000);
                    return;
                } else if (data.status === 'ERROR') {
                    badge.textContent = 'Installation Failed';
                    badge.className = 'px-3 py-1 rounded text-xs font-bold bg-red-900 text-red-300 uppercase';
                    dot.className = 'w-3 h-3 rounded-full bg-red-500';
                    return;
                } else {
                    badge.textContent = data.status;
                }
                
                setTimeout(updateProgress, 1000);
            } catch (e) {
                setTimeout(updateProgress, 2000);
            }
        }
        updateProgress();
    </script>
</body>
</html>
"""

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args): pass
    def do_GET(self):
        if self.path == '/':
            self.send_response(200); self.send_header('Content-type', 'text/html'); self.end_headers(); self.wfile.write(HTML.encode('utf-8'))
        elif self.path == '/api/progress':
            logs = ''; status = 'INSTALLING'
            if os.path.exists(LOG_FILE):
                try:
                    with open(LOG_FILE, 'r', encoding='utf-8', errors='replace') as f: logs = f.read()
                except:
                    import subprocess
                    try: logs = subprocess.check_output(['powershell', '-NoProfile', '-Command', f'Get-Content "{LOG_FILE}" -Raw'], stderr=subprocess.STDOUT).decode('utf-8', errors='replace')
                    except: pass
            if os.path.exists(STATUS_FILE):
                try:
                    with open(STATUS_FILE, 'r') as f: status = f.read().strip()
                except: pass
            self.send_response(200); self.send_header('Content-type', 'application/json'); self.end_headers(); self.wfile.write(json.dumps({'logs': logs, 'status': status}).encode('utf-8'))
            if status in ['SUCCESS', 'ERROR']: threading.Thread(target=lambda: (time.sleep(15), os._exit(0))).start()

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(('127.0.0.1', PORT), Handler) as httpd:
    httpd.serve_forever()
# <END_UI>

# <BEGIN_PS>
param($InstallDir)
$ErrorActionPreference = "Stop"

$User = $env:TEMP_USER
$Pass = $env:TEMP_PASS

Write-Host "========================================"
Write-Host " BETTERBACKUPS BACKGROUND INSTALLER"
Write-Host "========================================"

$BinDir = Join-Path $InstallDir "bin"
$LogsDir = Join-Path $InstallDir "logs"
$Venv = Join-Path $InstallDir "venv"
$ConfigPath = Join-Path $InstallDir "config.yaml"

if (!(Test-Path $BinDir)) { New-Item -ItemType Directory $BinDir | Out-Null }
if (!(Test-Path $LogsDir)) { New-Item -ItemType Directory $LogsDir | Out-Null }

Write-Host "[*] Creating Virtual Environment (this may take a minute)..."
if (!(Test-Path $Venv)) { python -m venv $Venv }

Write-Host "[*] Upgrading PIP..."
& "$Venv\Scripts\python.exe" -m pip install --upgrade pip

Write-Host "[*] Installing BetterBackups Core Dependencies..."
& "$Venv\Scripts\pip.exe" install fastapi==0.109.2 uvicorn==0.27.1 websockets==12.0 PyYAML==6.0.1 APScheduler==3.10.4 jinja2==3.1.3

Write-Host "[*] Downloading NSSM..."
$NssmZip = Join-Path $BinDir "nssm.zip"
$NssmExe = Join-Path $BinDir "nssm.exe"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/NSSM/2.24.0" -OutFile $NssmZip
Expand-Archive $NssmZip -DestinationPath (Join-Path $BinDir "temp") -Force
$Found = Get-ChildItem -Path (Join-Path $BinDir "temp") -Filter "nssm.exe" -Recurse | Where-Object { $_.FullName -match "win64" } | Select-Object -First 1
Move-Item $Found.FullName $NssmExe -Force
Remove-Item (Join-Path $BinDir "temp") -Recurse -Force
Remove-Item $NssmZip

Write-Host "[*] Downloading Rclone..."
$RcloneZip = Join-Path $BinDir "rclone.zip"
$RcloneExe = Join-Path $BinDir "rclone.exe"
Invoke-WebRequest -Uri "https://downloads.rclone.org/rclone-current-windows-amd64.zip" -OutFile $RcloneZip
Expand-Archive $RcloneZip -DestinationPath (Join-Path $BinDir "rtemp") -Force
$FoundR = Get-ChildItem -Path (Join-Path $BinDir "rtemp") -Filter "rclone.exe" -Recurse | Select-Object -First 1
Move-Item $FoundR.FullName $RcloneExe -Force
Remove-Item (Join-Path $BinDir "rtemp") -Recurse -Force
Remove-Item $RcloneZip

if (!(Test-Path $ConfigPath)) {
    Write-Host "[*] Generating Configuration with secure hash..."
    
    # FIX: Shifted random salt and PBKDF2 hash generation entirely to Python to avoid PowerShell .NET inconsistencies
    $env:BB_INSTALL_PASS = $Pass
    $PyCode = "import hashlib, secrets, os; p=os.environ.get('BB_INSTALL_PASS',''); s=secrets.token_hex(16); h=hashlib.pbkdf2_hmac('sha256', p.encode('utf-8'), s.encode('utf-8'), 100000).hex(); print(f'{s}:{h}')"
    $FinalHash = & "$Venv\Scripts\python.exe" -c $PyCode

    $Yaml = @"
app:
  port: 8050
  host: 0.0.0.0
  log_level: INFO
  log_retention_days: 7
security:
  auth_enabled: true
  username: $User
  password_hash: $FinalHash
  trusted_proxies: ''
  max_login_strikes: 5
  lockout_duration_minutes: 15
paths:
  rclone_exe: $RcloneExe
  rclone_config: $(Join-Path $InstallDir 'rclone.conf')
jobs: {}
notifications:
  discord_webhook_url: ''
"@
    $Yaml | Out-File $ConfigPath -Encoding utf8
}

Write-Host "[*] Configuring Windows Firewall..."
netsh advfirewall firewall add rule name="BetterBackups Web UI" dir=in action=allow protocol=TCP localport=8050

Write-Host "[*] Registering Windows Background Service..."
& "$NssmExe" install BetterBackups "$Venv\Scripts\python.exe"
& "$NssmExe" set BetterBackups AppParameters "-m uvicorn web.app:app --host 0.0.0.0 --port 8050"
& "$NssmExe" set BetterBackups AppDirectory "$InstallDir"
& "$NssmExe" set BetterBackups AppStdout "$LogsDir\service.log"
& "$NssmExe" set BetterBackups AppStderr "$LogsDir\service.log"
& "$NssmExe" set BetterBackups AppStopMethodSkip 0
& "$NssmExe" set BetterBackups AppStopMethodConsole 15000
Start-Service BetterBackups
Write-Host "Success! System is live."
# <END_PS>