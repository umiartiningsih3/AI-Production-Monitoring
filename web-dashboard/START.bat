@echo off
setlocal
title Dashboard Produksi - JANGAN DITUTUP
cd /d "%~dp0"
rem PATH di laptop ini tidak memuat folder System32, jadi ditambahkan di sini
set "PATH=%SystemRoot%\System32;%SystemRoot%;%SystemRoot%\System32\WindowsPowerShell\v1.0;%PATH%"
if not exist logs mkdir logs

rem ---- cari Node.js ----
echo [%date% %time%] mencari node > logs\start.log
where node >> logs\start.log 2>&1
if not errorlevel 1 goto nodeok
for %%P in ("%ProgramFiles%\nodejs" "%ProgramFiles(x86)%\nodejs" "%LOCALAPPDATA%\Programs\nodejs" "%NVM_SYMLINK%" "%~dp0.node") do (
  if exist "%%~P\node.exe" set "NODEDIR=%%~P"
)
if not defined NODEDIR (
  for /f "delims=" %%F in ('dir /s /b "C:\laragon\bin\nodejs\node.exe" 2^>nul') do set "NODEDIR=%%~dpF"
)
if not defined NODEDIR goto unduhnode
set "PATH=%NODEDIR%;%PATH%"
echo pakai node di %NODEDIR%>> logs\start.log
goto nodeok

:unduhnode
rem Node.js belum ada sama sekali: unduh versi portable resmi dari nodejs.org (sekali saja)
echo  Node.js belum terpasang. Mengunduh Node.js portable dari nodejs.org (sekitar 30 MB)...
echo unduh node portable>> logs\start.log
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol='Tls12'; $v='v20.18.1'; $z=Join-Path $env:TEMP 'node-portable.zip'; Invoke-WebRequest -UseBasicParsing ('https://nodejs.org/dist/'+$v+'/node-'+$v+'-win-x64.zip') -OutFile $z; $t=Join-Path $env:TEMP 'node-portable'; if (Test-Path $t) { Remove-Item $t -Recurse -Force }; Expand-Archive $z $t; $d=Join-Path '%~dp0' '.node'; if (Test-Path $d) { Remove-Item $d -Recurse -Force }; Move-Item (Join-Path $t ('node-'+$v+'-win-x64')) $d; Remove-Item $z" >> logs\start.log 2>&1
if not exist "%~dp0.node\node.exe" (
  echo [X] Gagal mengunduh Node.js. Cek internet lalu jalankan START.bat lagi.
  echo GAGAL UNDUH NODE>> logs\start.log
  pause
  exit /b 1
)
set "PATH=%~dp0.node;%PATH%"

:nodeok
for /f "delims=" %%v in ('node -v') do set NODEV=%%v
echo [%date% %time%] node %NODEV% >> logs\start.log
echo.
echo  ==============================================================
echo    DASHBOARD PRODUKSI  (PBLIF3-MD04)
echo  ==============================================================
echo    Node.js %NODEV%
echo.

rem ---- install library React (sekali saja, butuh internet) ----
if not exist "client\node_modules\recharts" (
  echo  [1/3] Menginstall library React... ^(sekali saja, 1-3 menit^)
  pushd client
  call npm install --no-audit --no-fund > ..\logs\npm-install.log 2>&1
  if errorlevel 1 (
    popd
    echo [X] npm install gagal. Lihat logs\npm-install.log
    echo NPM INSTALL GAGAL>> logs\start.log
    pause
    exit /b 1
  )
  popd
) else (
  echo  [1/3] Library React sudah terpasang
)
echo npm install OK>> logs\start.log

rem ---- build tampilan ----
echo  [2/3] Membuat tampilan dashboard...
pushd client
call npm run build > ..\logs\build.log 2>&1
set BUILDERR=%errorlevel%
popd
if not "%BUILDERR%"=="0" (
  echo [!] Build gagal - lihat logs\build.log ^(server tetap dijalankan^)
  echo BUILD GAGAL>> logs\start.log
) else (
  echo BUILD OK>> logs\start.log
)
rem build ulang otomatis kalau file tampilan diubah
start "" /b cmd /c "cd client && npm run watch > ..\logs\build-watch.log 2>&1"

rem ---- jalankan server ----
echo  [3/3] Menjalankan server di http://localhost:3000
echo.
echo    Biarkan jendela ini terbuka selama memakai dashboard.
echo    Klik POST di Excel -^> dashboard ikut update otomatis.
echo.
start "" cmd /c "timeout /t 4 >nul & start http://localhost:3000"
echo SERVER START>> logs\start.log
node --watch server\index.js || node server\index.js
echo SERVER BERHENTI (kode %errorlevel%)>> logs\start.log
pause
