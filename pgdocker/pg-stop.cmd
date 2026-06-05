@echo off
REM Stop and remove the container + network. The data volume is KEPT, so a later
<<<<<<< HEAD
REM pg-start.cmd resumes with the same database.
cd /d "%~dp0"

docker compose down
echo Stopped. Data volume kept - pg-start.cmd to resume.

=======
REM start.cmd resumes with the same database.
cd /d "%~dp0"

docker compose down
echo Stopped. Data volume kept - start.cmd to resume.
pause
>>>>>>> fe81bf7ce46305effe75b62721279acf0977134e
