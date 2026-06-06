@echo off
REM Start the EXTENSION-variant container (reuses the existing image; recreates
REM the container if needed). Use pg-ext-create.cmd if you regenerated the
REM extension (deno task extension) or changed the Dockerfile.
cd /d "%~dp0"

if not exist ".env" (
  echo No .env found. Run pg-ext-create.cmd first ^(it copies .env.example^).
  pause
  exit /b 1
)

docker compose -f docker-compose.ext.yml -p semantius-ext up -d || goto :err
docker compose -f docker-compose.ext.yml -p semantius-ext ps

exit /b 0

:err
echo.
echo Failed. Is Docker Desktop running?

exit /b 1
