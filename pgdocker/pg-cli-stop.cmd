@echo off
REM Stop and remove the container + network. The data volume is KEPT, so a later
REM pg-cli-start.cmd resumes with the same database.
cd /d "%~dp0"

docker compose down
echo Stopped. Data volume kept - pg-cli-start.cmd to resume.

