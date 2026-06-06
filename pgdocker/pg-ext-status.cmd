@echo off
REM Show the EXTENSION container's status: created / running (healthy) / exited.
REM Prints nothing under the header if it has been deleted (pg-ext-stop.cmd).
cd /d "%~dp0"
docker compose -f docker-compose.ext.yml -p semantius-ext ps -a
