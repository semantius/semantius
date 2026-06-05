@echo off
REM Build the image and create + start the container (first run, or after
REM changing the Dockerfile / patches). Creates .env from the template if missing.
cd /d "%~dp0"

if not exist ".env" (
  copy ".env.example" ".env" >nul
  echo Created .env from .env.example - edit POSTGRES_PASSWORD if you want.
)

docker compose up -d --build || goto :err
docker compose ps
echo.
echo Ready. DBA connection string:
echo   postgresql://postgres:^<POSTGRES_PASSWORD^>@localhost:5432/appdb

exit /b 0

:err
echo.
echo Failed. Is Docker Desktop running?
pause
exit /b 1
