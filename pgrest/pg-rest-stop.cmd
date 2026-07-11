@echo off
REM Stop + remove the PostgREST-stack containers + network. Volumes are KEPT, so a
REM later pg-rest-start.cmd resumes with the same database.
cd /d "%~dp0"
docker compose down
echo Stopped. Data volume kept - pg-rest-start.cmd to resume.
