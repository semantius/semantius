@echo off
REM Show the PostgREST-stack containers' status: created / running / exited.
cd /d "%~dp0"
docker compose ps -a
