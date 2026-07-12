@echo off
REM Build + run the PostgREST stack (PG18 + pg_semantic_platform extension +
REM PostgREST + Scalar docs). Own compose project (semantius-rest) on port 5434.
cd /d "%~dp0"

if not exist ".env" (
  copy ".env.example" ".env" >nul
  echo Created .env from .env.example - edit passwords/ports if you want.
)

if not exist "..\extension\pg_semantic_platform.control" (
  echo No extension build found in ..\extension.
  echo Generate it first from the repo root:  deno task extension 0.2.0
  goto :err
)

REM Build the DB image locally (from ..\extension), tagged :latest so compose
REM (SEMANTIUS_DB_VERSION defaults to latest) uses it without pulling. The
REM versioned tag + publish live in ..\docker-semantius (build.sh / CI).
pushd ..
docker build -f docker-semantius\Dockerfile -t ghcr.io/adenin-platform/semantius-db:latest . || (popd & goto :err)
popd

docker compose up -d || goto :err
docker compose ps
echo.
echo Ready (PostgREST stack). Default ports (see .env):
echo   API : http://localhost:3000/   (OpenAPI spec at /)
echo   Docs: http://localhost:8080/   (Scalar API reference)
echo   DBA : postgresql://postgres:^<POSTGRES_PASSWORD^>@localhost:5434/appdb
exit /b 0

:err
echo.
echo Failed. Is Docker Desktop running? Did you run "deno task extension"?
pause
exit /b 1
