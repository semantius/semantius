@echo off
REM Build + run the EXTENSION variant: PostgreSQL with Semantius core installed
REM as an extension (CREATE EXTENSION semantius), instead of the CLI migrate
REM path. For the plain CLI-testing container, use pg-cli-create.cmd.
REM Runs as its own compose project (semantius-ext) on port 5433.
cd /d "%~dp0"

if not exist ".env" (
  copy ".env.example" ".env" >nul
  echo Created .env from .env.example - edit POSTGRES_PASSWORD if you want.
)

if not exist "..\extension\semantius.control" (
  echo No extension build found in ..\extension.
  echo Generate it first from the repo root:  deno task extension
  goto :err
)

docker compose build postgres || goto :err
docker compose -f docker-compose.ext.yml -p semantius-ext up -d --build || goto :err
docker compose -f docker-compose.ext.yml -p semantius-ext ps
echo.
echo Ready (extension variant). DBA connection string:
echo   postgresql://postgres:^<POSTGRES_PASSWORD^>@localhost:5433/appdb

exit /b 0

:err
echo.
echo Failed. Is Docker Desktop running? Did you run "deno task extension"?
pause
exit /b 1
