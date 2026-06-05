@echo off
REM Start the container (reuses the existing image; recreates the container if
REM needed). Use create.cmd if you changed the Dockerfile or patches.
cd /d "%~dp0"

if not exist ".env" (
  echo No .env found. Run create.cmd first ^(it copies .env.example^).
  pause
  exit /b 1
)

docker compose up -d || goto :err
docker compose ps
pause
exit /b 0

:err
echo.
echo Failed. Is Docker Desktop running?
pause
exit /b 1
