@echo off
REM Start the PostgREST-stack containers that pg-rest-create.cmd already created.
REM This ONLY starts existing (stopped) containers - it never creates them. If the
REM stack has not been created yet (or was destroyed), run pg-rest-create.cmd instead.
cd /d "%~dp0"

if not exist ".env" (
  echo No .env found. Run pg-rest-create.cmd first ^(it copies .env.example^).
  goto :err
)

for /f %%i in ('docker compose ps -aq') do set HAVE=1
if not defined HAVE (
  echo No containers exist. Run pg-rest-create.cmd first.
  goto :err
)

docker compose start || goto :err
docker compose ps
exit /b 0

:err
echo.
echo Failed. Is Docker Desktop running?
exit /b 1
