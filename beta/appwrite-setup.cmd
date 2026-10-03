@echo off
rem Runs appwrite-setup.ps1 without changing the system script policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0appwrite-setup.ps1" %*
