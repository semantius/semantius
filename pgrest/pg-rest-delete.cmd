@echo off
REM Destroy the PostgREST stack: containers, network, data + jwks volumes, and the
REM postgres18-rest:local image. Leaves the pgdocker stacks untouched.
cd /d "%~dp0"

set /p ans=This DELETES the pgrest DB volume and image. Continue? [y/N]
if /i not "%ans%"=="y" (
  echo Cancelled.
  exit /b 0
)

docker compose down -v --rmi local
echo Removed the pgrest containers, network, data + jwks volumes, and image.
