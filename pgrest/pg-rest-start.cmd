@echo off
REM Start the PostgREST-stack containers (reuses the existing image). Use
REM pg-rest-create.cmd if you regenerated the extension or changed the Dockerfile.
cd /d "%~dp0"

if not exist ".env" (
  echo No .env found. Run pg-rest-create.cmd first ^(it copies .env.example^).
  goto :err
)

docker compose up -d || goto :err
docker compose ps
exit /b 0

:err
echo.
echo Failed. Is Docker Desktop running?
exit /b 1
