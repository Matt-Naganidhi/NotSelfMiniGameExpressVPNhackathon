@echo off
setlocal EnableDelayedExpansion

:: Lock working directory to folder containing this bat file
:: This fixes the "package.json not found" bug after UAC re-launch
cd /d "%~dp0"

title EQGate Setup

:: Full paths — never rely on PATH for system tools
set PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set PS=%ProgramFiles%\PowerShell\7\pwsh.exe
set CURL=%SystemRoot%\System32\curl.exe
set REG=%SystemRoot%\System32\reg.exe
set MSIEXEC=%SystemRoot%\System32\msiexec.exe

:: ── Parse arguments ───────────────────────────────────────
set MODE=full
set NGROK_MODE=0
if /i "%~1"=="--help"    goto SHOW_HELP
if /i "%~1"=="-h"        goto SHOW_HELP
if /i "%~1"=="--install" ( set MODE=install & goto MAIN )
if /i "%~1"=="--start"   ( set MODE=start   & goto MAIN )
if /i "%~1"=="--ngrok"   ( set NGROK_MODE=1 & goto MAIN )
if /i "%~1"=="--rename"  goto DO_RENAME

:MAIN
cls
echo.
echo  +=======================================================+
echo  ^|           EQGate  -  Setup Utility                   ^|
echo  +=======================================================+
echo  Project: %~dp0
echo.

:: ── Elevation ─────────────────────────────────────────────
net session >nul 2>&1
if not errorlevel 1 goto ELEVATED_OK

echo  [!] Requesting Administrator rights...

:: Pass project dir as extra arg so re-launched process can cd to it
if exist "%PS%" (
  "%PS%" -NoProfile -Command "Start-Process cmd -ArgumentList '/c cd /d ""%~dp0"" && ""%~f0"" %*' -Verb RunAs -Wait" >nul 2>&1
  if not errorlevel 1 exit /b 0
)

:: VBScript fallback
set _VBS=%TEMP%\eq_elev_%RANDOM%.vbs
echo Set sh=CreateObject("Shell.Application") > "%_VBS%"
echo sh.ShellExecute "cmd.exe", "/c cd /d ""%~dp0"" && ""%~f0"" %*", "", "runas", 1 >> "%_VBS%"
cscript //nologo "%_VBS%" >nul 2>&1
del /f /q "%_VBS%" >nul 2>&1
if not errorlevel 1 exit /b 0

echo  [WARN] Could not elevate. Continuing anyway — some installs may fail.
echo.

:ELEVATED_OK
echo  [OK] Running as Administrator.
echo.

:: ── Check / install Node.js ───────────────────────────────
call :FN_NODE
if errorlevel 1 (
  echo.
  echo  [FATAL] Node.js could not be installed.
  echo          Install manually from https://nodejs.org then re-run.
  pause & exit /b 1
)

:: ── Check / install Python (optional) ────────────────────
call :FN_PYTHON

:: ── Route to install or start ─────────────────────────────
if /i "%MODE%"=="start"  goto DO_START
goto DO_INSTALL


:DO_INSTALL
echo.
echo  [INSTALL] Setting up EQGate project...
echo  [DIR]     %CD%
echo.

if not exist "%~dp0package.json" (
  echo  [ERROR] package.json not found in %~dp0
  echo          Make sure setup.bat is inside the EQGate project folder.
  pause & exit /b 1
)

if not exist "%~dp0public" mkdir "%~dp0public"
if exist "%~dp0index.html" (
  echo  [SETUP] Moving index.html -^> public\index.html
  move /Y "%~dp0index.html" "%~dp0public\index.html" >nul
)

echo  [NPM] Installing dependencies...
call npm install
if errorlevel 1 ( echo  [ERROR] npm install failed. & pause & exit /b 1 )
echo  [NPM] Done.
echo.

:: Install ngrok during setup so it's ready for --ngrok flag
call :FN_NGROK
echo.

if /i "%MODE%"=="install" (
  echo  Complete! Run:  setup.bat --start
  echo  For remote access: setup.bat --ngrok
  pause & exit /b 0
)

:DO_START
echo.
echo  +=======================================================+
echo  ^|   Starting EQGate on http://localhost:3000           ^|
echo  +=======================================================+
echo.

if "%NGROK_MODE%"=="1" (
  call :FN_NGROK
  echo.
  echo  [INFO] Starting server + ngrok tunnel...
  echo  [INFO] The public URL will appear in the server console automatically.
  echo.
  start "EQGate-Server" /min cmd /c "cd /d "%~dp0" && node server.js"
  timeout /t 2 >nul
  ngrok http 3000
) else (
  echo  [TIP] To share publicly, run: setup.bat --ngrok
  echo.
  start "" /b cmd /c "timeout /t 2 >nul && start http://localhost:3000"
  node server.js
)
goto :eof


:DO_RENAME
set OLD_BRAND=%~2
set NEW_BRAND=%~3
set PREV=
if /i "%~4"=="--preview" set PREV=--preview
if "%OLD_BRAND%"=="" ( echo [ERROR] Usage: setup.bat --rename OldName NewName [--preview] & pause & exit /b 1 )
if "%NEW_BRAND%"=="" ( echo [ERROR] Missing new name. & pause & exit /b 1 )
call :FN_PYTHON
if errorlevel 1 ( echo [ERROR] Python needed for --rename. & pause & exit /b 1 )
echo.
echo  Rebranding: %OLD_BRAND% -^> %NEW_BRAND% %PREV%
echo.
python "%~dp0rename.py" --from "%OLD_BRAND%" --to "%NEW_BRAND%" %PREV% --rename-files
pause & exit /b 0


:: =============================================================
::  FN_NODE  — ensure Node.js v18+ is installed
:: =============================================================
:FN_NODE
echo  [CHECK] Node.js...
call :FN_REFRESHPATH

where node >nul 2>&1
if not errorlevel 1 (
  node -e "process.exit(parseInt(process.version.slice(1))>=18?0:1)" >nul 2>&1
  if not errorlevel 1 (
    for /f %%v in ('node --version') do echo  [OK] Node.js %%v
    exit /b 0
  )
  echo  [WARN] Node.js below v18 — upgrading...
)

echo  [AUTO-INSTALL] Installing Node.js LTS...

where winget >nul 2>&1
if not errorlevel 1 (
  echo  [WINGET] Installing via winget...
  winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements --silent
  call :FN_REFRESHPATH
  where node >nul 2>&1
  if not errorlevel 1 ( for /f %%v in ('node --version') do echo  [OK] Node.js %%v & exit /b 0 )
)

set _NODE_MSI=%TEMP%\nodejs_lts.msi
call :FN_DOWNLOAD "https://nodejs.org/dist/v20.18.0/node-v20.18.0-x64.msi" "%_NODE_MSI%"
if not exist "%_NODE_MSI%" ( echo  [ERROR] Download failed. & exit /b 1 )

echo  [INSTALL] Running Node.js MSI...
"%MSIEXEC%" /i "%_NODE_MSI%" /qn /norestart ADDLOCAL=ALL
del /f /q "%_NODE_MSI%" >nul 2>&1
call :FN_REFRESHPATH

where node >nul 2>&1
if errorlevel 1 ( echo  [ERROR] Node installed but not on PATH yet. Restart terminal and retry. & exit /b 1 )
for /f %%v in ('node --version') do echo  [OK] Node.js %%v installed.
exit /b 0


:: =============================================================
::  FN_PYTHON  — ensure Python 3 is installed (optional)
:: =============================================================
:FN_PYTHON
echo  [CHECK] Python 3...
call :FN_REFRESHPATH

where python >nul 2>&1
if not errorlevel 1 (
  python -c "import sys;sys.exit(0 if sys.version_info.major==3 else 1)" >nul 2>&1
  if not errorlevel 1 ( for /f %%v in ('python --version') do echo  [OK] %%v & exit /b 0 )
)
where python3 >nul 2>&1
if not errorlevel 1 ( for /f %%v in ('python3 --version') do echo  [OK] %%v & exit /b 0 )

echo  [AUTO-INSTALL] Installing Python 3...

where winget >nul 2>&1
if not errorlevel 1 (
  winget install --id Python.Python.3.12 -e --accept-source-agreements --accept-package-agreements --silent
  call :FN_REFRESHPATH
  where python >nul 2>&1
  if not errorlevel 1 ( for /f %%v in ('python --version') do echo  [OK] %%v & exit /b 0 )
)

set _PY_EXE=%TEMP%\python_setup.exe
call :FN_DOWNLOAD "https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe" "%_PY_EXE%"
if not exist "%_PY_EXE%" ( echo  [WARN] Python download failed — rename utility unavailable. & exit /b 1 )
"%_PY_EXE%" /quiet InstallAllUsers=1 PrependPath=1 Include_test=0
del /f /q "%_PY_EXE%" >nul 2>&1
call :FN_REFRESHPATH
where python >nul 2>&1
if errorlevel 1 ( echo  [WARN] Python installed but not on PATH yet. & exit /b 1 )
for /f %%v in ('python --version') do echo  [OK] %%v
exit /b 0


:: =============================================================
::  FN_NGROK  — ensure ngrok is installed
:: =============================================================
:FN_NGROK
echo  [CHECK] ngrok...
call :FN_REFRESHPATH
where ngrok >nul 2>&1
if not errorlevel 1 ( echo  [OK] ngrok found. & exit /b 0 )

echo  [AUTO-INSTALL] Installing ngrok...
where winget >nul 2>&1
if not errorlevel 1 (
  winget install --id ngrok.ngrok -e --accept-source-agreements --accept-package-agreements --silent
  call :FN_REFRESHPATH
  where ngrok >nul 2>&1
  if not errorlevel 1 ( echo  [OK] ngrok installed. & exit /b 0 )
)

set _NGROK_ZIP=%TEMP%\ngrok.zip
call :FN_DOWNLOAD "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip" "%_NGROK_ZIP%"
if exist "%_NGROK_ZIP%" (
  tar -xf "%_NGROK_ZIP%" -C "%~dp0" >nul 2>&1
  if not exist "%~dp0ngrok.exe" if exist "%PS%" (
    "%PS%" -NoProfile -Command "Expand-Archive '%_NGROK_ZIP%' '%~dp0' -Force" >nul 2>&1
  )
  del /f /q "%_NGROK_ZIP%" >nul 2>&1
)
if exist "%~dp0ngrok.exe" ( set PATH=%~dp0;%PATH% & echo  [OK] ngrok ready. & exit /b 0 )
echo  [WARN] Could not install ngrok. Download from https://ngrok.com/download
exit /b 1


:: =============================================================
::  FN_DOWNLOAD <url> <dest>
::  Tries curl → bitsadmin → PowerShell (all by full path)
:: =============================================================
:FN_DOWNLOAD
set _URL=%~1
set _DST=%~2
echo  [DOWNLOAD] %_URL%

if exist "%CURL%" (
  "%CURL%" -L -s -o "%_DST%" "%_URL%" >nul 2>&1
  if exist "%_DST%" exit /b 0
)

bitsadmin /transfer eqgate_dl /download /priority normal "%_URL%" "%_DST%" >nul 2>&1
if exist "%_DST%" exit /b 0

if exist "%PS%" (
  "%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri '%_URL%' -OutFile '%_DST%' -UseBasicParsing" >nul 2>&1
  if exist "%_DST%" exit /b 0
)

echo  [ERROR] All download methods failed.
exit /b 1


:: =============================================================
::  FN_REFRESHPATH — re-read PATH from registry (no restart needed)
:: =============================================================
:FN_REFRESHPATH
set _SP=
set _UP=
for /f "usebackq skip=2 tokens=1,2,*" %%A in (`"%REG%" query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path 2^>nul`) do if /i "%%A"=="Path" set _SP=%%C
for /f "usebackq skip=2 tokens=1,2,*" %%A in (`"%REG%" query "HKCU\Environment" /v Path 2^>nul`) do if /i "%%A"=="Path" set _UP=%%C
if defined _SP set PATH=%_SP%
if defined _UP set PATH=%PATH%;%_UP%
set PATH=%PATH%;%ProgramFiles%\nodejs;%APPDATA%\npm
set PATH=%PATH%;%LOCALAPPDATA%\Programs\Python\Python312
set PATH=%PATH%;%LOCALAPPDATA%\Programs\Python\Python311
set PATH=%PATH%;%LOCALAPPDATA%\Programs\Python\Python310
set PATH=%PATH%;%SystemRoot%\System32
exit /b 0


:SHOW_HELP
echo.
echo  EQGate Setup - Auto-installs Node.js, Python, ngrok
echo.
echo  USAGE  (from CMD):        setup.bat [option]
echo  USAGE  (from PowerShell): .\setup.bat [option]
echo.
echo  OPTIONS:
echo    (none)                   Install deps + start server
echo    --install                Install npm deps only
echo    --start                  Start server (skip install)
echo    --ngrok                  Start server + ngrok tunnel
echo    --rename OLD NEW         Rebrand project files
echo    --rename OLD NEW --preview  Dry run only
echo    --help                   Show this screen
echo.
pause & exit /b 0
