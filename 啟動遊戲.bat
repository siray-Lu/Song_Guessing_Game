@echo off
cd /d "%~dp0"

powershell -NoProfile -Command "if (-not (Get-NetTCPConnection -LocalPort 8794 -State Listen -ErrorAction SilentlyContinue)) { Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0_serve.ps1\"' }"

ping -n 2 127.0.0.1 >nul

start "" "http://localhost:8794/index.html"
