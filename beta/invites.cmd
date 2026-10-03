@echo off
rem Runs invites.ps1 without changing the system script policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0invites.ps1" %*
