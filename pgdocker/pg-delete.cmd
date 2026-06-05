@echo off
REM Destroy everything: container, network, the DATA VOLUME (database is erased),
REM and the locally built image. Asks for confirmation first.
cd /d "%~dp0"

set "ans="
set /p "ans=This DELETES the database volume and the built image. Continue? [y/N] "
if /i not "%ans%"=="y" (
  echo Cancelled.
  pause
  exit /b 0
)

docker compose down -v --rmi local
echo Removed container, network, data volume, and image.
<<<<<<< HEAD

=======
pause
>>>>>>> fe81bf7ce46305effe75b62721279acf0977134e
