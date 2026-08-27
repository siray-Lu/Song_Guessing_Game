@echo off
chcp 65001 >nul
title Cloudflare Login (Wrangler)
set "PATH=C:\Users\Siray\AppData\Local\node-portable\node-v22.20.0-win-x64;%PATH%"
cd /d "%~dp0worker"
echo.
echo  A Cloudflare authorization page will open in your browser.
echo  Click "Allow" there, then come back to this window.
echo.
call "node_modules\.bin\wrangler.cmd" login
echo.
echo  ---- done. you can close this window ----
pause
