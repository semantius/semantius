@echo off
REM Destroy the PostgREST stack: containers, network, and data + jwks volumes.
REM Keeps the semantius/postgres image (reusable, versioned artifact) and leaves the
REM pgdocker stacks untouched.
cd /d "%~dp0"

set /p ans=This DELETES the PostgREST stack's DB volume (all data). Continue? [y/N]
if /i not "%ans%"=="y" (
  echo Cancelled.
  exit /b 0
)

docker compose down -v
echo Removed the PostgREST stack's containers, network, and data + jwks volumes (image kept).
