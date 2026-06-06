@echo off
REM Stop and remove the EXTENSION container + network. The data volume is KEPT, so
REM a later pg-ext-start.cmd resumes with the same database.
cd /d "%~dp0"

docker compose -f docker-compose.ext.yml -p semantius-ext down
echo Stopped. Data volume kept - pg-ext-start.cmd to resume.
