@echo off
rem Runs run-server.ps1 without changing the system script policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-server.ps1" %*
