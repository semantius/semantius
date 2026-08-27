@echo off
setlocal enabledelayedexpansion
REM up.cmd  -  (re)create the PostgREST stack's CONTAINERS from the current compose
REM config and start them, KEEPING the database. See up.sh for the full rationale.
REM
REM This is "docker compose up --force-recreate". Reach for it after changing
REM docker-compose.yml, .env or the Caddyfile: the containers are replaced, your
REM data survives.
REM
REM It does NOT give you a clean database -- the image's first-init scripts run ONCE
REM per data directory, so an existing pgdata volume keeps the OLD schema no matter
REM how many times containers are recreated. For a fresh database use create.cmd.
REM
REM IMAGES COME FROM THE REGISTRY by default, like every other service in this
REM stack: the DB image is PULLED from GHCR, so this works in a fresh clone with no
REM Deno, no ..\extension and no local build. Pass --build to run YOUR working tree.
REM
REM Usage:
REM   up.cmd                  pull the published DB image, then up
REM   up.cmd 0.4.0-pg18       ... pinned to that tag (overrides SEMANTIUS_DB_VERSION)
REM   up.cmd --build          build the image from ..\extension instead of pulling
cd /d "%~dp0"

set "PULL=1"
set "DB_VERSION="

:parse
if "%~1"=="" goto :parsed
if /i "%~1"=="--build" ( set "PULL=0" & shift & goto :parse )
if /i "%~1"=="--pull" ( set "PULL=1" & shift & goto :parse )
set "ARG=%~1"
if "!ARG:~0,1!"=="-" (
  echo Unknown option: %~1
  echo Usage: up.cmd [--pull^|--build] [version]
  exit /b 1
)
REM A bare argument is the image tag.
set "DB_VERSION=%~1"
shift
goto :parse
:parsed

REM A tag selects a PUBLISHED image; build.sh tags whatever ..\extension holds, so
REM the two cannot be combined without lying about what is running.
if "%PULL%"=="0" if defined DB_VERSION (
  echo A version tag ^('!DB_VERSION!'^) applies only when pulling -- --build runs whatever ..\extension holds.
  exit /b 1
)

if not exist ".env" (
  copy ".env.example" ".env" >nul
  echo Created .env from .env.example - edit passwords/ports if you want.
)

REM An explicit tag wins over .env: the process environment takes precedence over
REM the .env file in docker compose's variable resolution.
if defined DB_VERSION (
  set "SEMANTIUS_DB_VERSION=!DB_VERSION!"
  echo Pinning SEMANTIUS_DB_VERSION=!DB_VERSION! for this run.
)

if "%PULL%"=="1" (
  REM The other services are pull_policy: always; `postgres` is not, because a
  REM local --build must survive an "up". So pull it explicitly here.
  REM NOTE: pulling `latest` OVERWRITES an image left by a previous --build.
  echo == Pulling the published DB image ==
  docker compose pull postgres || goto :err
) else (
  if not exist "..\extension\pg_semantius.control" (
    echo No extension build found in ..\extension.
    echo Generate it first from the repo root:  deno task extension 0.4.0
    echo Or drop --build to run the published image instead.
    goto :err
  )
  REM Package ..\extension into the image, tagged :latest so compose
  REM (SEMANTIUS_DB_VERSION defaults to latest) uses it without pulling. The
  REM versioned tag + publish live in ..\docker-postgres (build.sh / CI).
  echo == Building the DB image from local source ==
  pushd ..
  docker build -f docker-postgres\Dockerfile -t ghcr.io/semantius/postgres:latest . || (popd & goto :err)
  popd
)

REM --force-recreate: always replace existing containers with fresh ones from the
REM current compose config, so this can never resume a stale/half-built container
REM (e.g. one left port-unpublished by an earlier failed "up"). --remove-orphans
REM drops services no longer in compose. Named volumes are kept, so this does NOT
REM lose data -- only create.cmd and destroy.cmd do.
docker compose up -d --force-recreate --remove-orphans || goto :err
docker compose ps
echo.
echo Ready (PostgREST stack). Default ports (see .env):
echo   Admin: http://localhost:7070/   (SPA; API at /api/, docs at /api-docs/)
echo   API : http://localhost:3000/   (OpenAPI spec at /)
echo   Docs: http://localhost:8080/   (Scalar API reference)
echo   DBA : postgresql://postgres:^<POSTGRES_PASSWORD^>@localhost:5434/semantius
exit /b 0

:err
echo.
echo Failed. Is Docker Desktop running?
pause
exit /b 1
