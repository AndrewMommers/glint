@echo off
rem Runs deploy.ps1 without changing the system script policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
