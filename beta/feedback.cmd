@echo off
rem Runs feedback.ps1 without changing the system script policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0feedback.ps1" %*
