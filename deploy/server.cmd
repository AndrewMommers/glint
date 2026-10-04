@echo off
rem Runs server.ps1 without changing the system script policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" %*
