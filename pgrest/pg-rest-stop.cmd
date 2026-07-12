@echo off
REM Stop the PostgREST-stack containers WITHOUT removing them. Containers, network,
REM and volumes are all KEPT, so pg-rest-start.cmd resumes the same containers. Use
REM pg-rest-destroy.cmd to actually remove containers + data.
cd /d "%~dp0"
docker compose stop
echo Stopped. Containers kept - pg-rest-start.cmd to resume.
