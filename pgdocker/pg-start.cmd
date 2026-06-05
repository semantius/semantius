@echo off
REM Start the container (reuses the existing image; recreates the container if
<<<<<<< HEAD
REM needed). Use pg-create.cmd if you changed the Dockerfile or patches.
cd /d "%~dp0"

if not exist ".env" (
  echo No .env found. Run pg-create.cmd first ^(it copies .env.example^).
=======
REM needed). Use create.cmd if you changed the Dockerfile or patches.
cd /d "%~dp0"

if not exist ".env" (
  echo No .env found. Run create.cmd first ^(it copies .env.example^).
>>>>>>> fe81bf7ce46305effe75b62721279acf0977134e
  pause
  exit /b 1
)

docker compose up -d || goto :err
docker compose ps
<<<<<<< HEAD

=======
pause
>>>>>>> fe81bf7ce46305effe75b62721279acf0977134e
exit /b 0

:err
echo.
echo Failed. Is Docker Desktop running?
<<<<<<< HEAD

=======
pause
>>>>>>> fe81bf7ce46305effe75b62721279acf0977134e
exit /b 1
