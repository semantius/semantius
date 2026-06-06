@echo off
REM Destroy the EXTENSION variant only: its container, network, data volume, and
REM the postgres18-ext:local image. Leaves the CLI-testing stack untouched.
cd /d "%~dp0"

set "ans="
set /p "ans=This DELETES the extension DB volume and image. Continue? [y/N] "
if /i not "%ans%"=="y" (
  echo Cancelled.
  exit /b 0
)

docker compose -f docker-compose.ext.yml -p semantius-ext down -v --rmi local
echo Removed the extension container, network, data volume, and image.
