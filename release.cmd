@echo off
rem Runs release.ps1 without changing the system script policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0release.ps1" %*
