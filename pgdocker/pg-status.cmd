@echo off
REM Show the container's status: created / running (healthy) / exited.
REM Prints nothing under the header if it has been deleted (docker compose down).
cd /d "%~dp0"
docker compose ps -a

