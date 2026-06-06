@echo off
REM Start the container (reuses the existing image; recreates the container if
REM needed). Use pg-create.cmd if you changed the Dockerfile or patches.
cd /d "%~dp0"

if not exist ".env" (
  echo No .env found. Run pg-create.cmd first ^(it copies .env.example^).
  pause
  exit /b 1
)

docker compose up -d || goto :err
docker compose ps

exit /b 0

:err
echo.
echo Failed. Is Docker Desktop running?

exit /b 1
