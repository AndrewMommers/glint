@echo off
rem Serves the website from this PC at http://localhost:8099 and opens it.
rem Close this window to stop it.
cd /d "%~dp0..\website"
start "" http://localhost:8099/
python -m http.server 8099 --bind 127.0.0.1
