@echo off
REM Stop and remove the container + network. The data volume is KEPT, so a later
REM start.cmd resumes with the same database.
cd /d "%~dp0"

docker compose down
echo Stopped. Data volume kept - start.cmd to resume.
pause
