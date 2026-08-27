@echo off
setlocal enabledelayedexpansion
REM test.cmd  -  Test the EXACT PostgREST deployment behavior end to end -- a
REM FRESH container, a FRESH data volume, and `_core` installed via CREATE EXTENSION
REM pg_semantius (the whole _core install in ONE transaction), then deploy
REM nwind,test and run the full pgTAP suite. See test.sh for the full
REM rationale.
REM
REM This is the FIRST-TIME test of a clean install (not a re-test): it rebuilds from
REM current source, exercising the image build + init scripts + role bootstrap from
REM scratch -- the real production install path. Twin of pgdocker/pg-ext-retest.cmd.
REM
REM DESTRUCTIVE: wipes the stack's data volume and rebuilds from current source.
REM PROMPTS for confirmation first (like destroy.cmd); bypass with -y/--yes
REM or ASSUME_YES=1 / CI=true. Afterwards the stack holds nwind,test; run
REM create.cmd for a clean semantius.
REM
REM Usage:
REM   test.cmd                test LOCAL source: regenerate the extension, build the
REM                           image, run the suite  (the default -- the pre-release
REM                           check that YOUR migrations install cleanly)
REM   test.cmd --pull         test the PUBLISHED image, pulled fresh from GHCR
REM   test.cmd 0.4.0-pg18     ... pinned to that tag (a tag always implies --pull)
REM   -y/--yes                skip the confirmation prompt
REM
REM NOTE the default is the opposite way round from create/up, deliberately: they are
REM stack operations, so they run the registry image like every other service; this is
REM a source-testing tool, so it defaults to the source you are sitting on.
REM
REM Steps: 0 regen extension SQL, 1 create (wipes the volume + builds/pulls the
REM        image + brings the stack up), 2 wait for extension, 3 migrate
REM        nwind,test, 4 test.
cd /d "%~dp0"
set "SCRIPT_DIR=%~dp0"
set "REPO_ROOT=%~dp0.."
set "CONTAINER=postgres18-rest"

if not exist ".env" (
  copy /y ".env.example" ".env" >nul
  echo Created .env from .env.example.
)

REM Derive DBA connection from .env (defaults match .env.example).
set "POSTGRES_PASSWORD=postgres"
set "POSTGRES_PORT=5434"
set "POSTGRES_DB=semantius"
for /f "usebackq tokens=1,* delims==" %%A in (".env") do (
  if /i "%%A"=="POSTGRES_PASSWORD" set "POSTGRES_PASSWORD=%%B"
  if /i "%%A"=="POSTGRES_PORT" set "POSTGRES_PORT=%%B"
  if /i "%%A"=="POSTGRES_DB" set "POSTGRES_DB=%%B"
)
set "REST_URL=postgresql://postgres:%POSTGRES_PASSWORD%@localhost:%POSTGRES_PORT%/%POSTGRES_DB%"

REM Safety: this DESTROYS the running PostgREST stack + its data volume (down -v) and
REM rebuilds it. Confirm before any changes -- same guard as destroy.cmd.
REM Bypass for automation: pass -y/--yes, or set ASSUME_YES=1 or CI=true.
set "FORCE=0"
set "PULL=0"
set "BUILD=0"
set "DB_VERSION="
:parse
if "%~1"=="" goto :parsed
if /i "%~1"=="-y" ( set "FORCE=1" & shift & goto :parse )
if /i "%~1"=="--yes" ( set "FORCE=1" & shift & goto :parse )
if /i "%~1"=="--pull" ( set "PULL=1" & shift & goto :parse )
if /i "%~1"=="--build" ( set "BUILD=1" & shift & goto :parse )
set "ARG=%~1"
if "!ARG:~0,1!"=="-" (
  echo Unknown option: %~1
  echo Usage: test.cmd [--pull^|--build] [version] [-y]
  exit /b 1
)
REM A bare argument is the image tag.
set "DB_VERSION=%~1"
shift
goto :parse
:parsed

REM A tag names a PUBLISHED image, so it implies --pull and cannot combine with
REM --build (which runs whatever ..\extension holds).
if "%BUILD%"=="1" (
  if "%PULL%"=="1" goto :badcombo
  if defined DB_VERSION goto :badcombo
)
if defined DB_VERSION set "PULL=1"
if "%ASSUME_YES%"=="1" set "FORCE=1"
if "%CI%"=="true" set "FORCE=1"
if "%FORCE%"=="0" (
  set /p ans=This DESTROYS the running PostgREST stack and WIPES its data volume ^('%POSTGRES_DB%', all data^), then rebuilds. Continue? [y/N]
  if /i not "!ans!"=="y" ( echo Cancelled. & exit /b 0 )
)

REM [0/5] Regenerate the extension from CURRENT migrations (skip with SKIP_EXT_REGEN=1).
REM Version inferred from the newest built extension SQL (dir /o-n = name-descending).
if "%PULL%"=="1" (
  echo == [0/4] Skipped -- --pull tests the PUBLISHED image, not local source ==
) else if not "%SKIP_EXT_REGEN%"=="1" (
  set "VERSION="
  for /f "delims=" %%F in ('dir /b /o-n "%REPO_ROOT%\extension\pg_semantius--*.sql" 2^>nul') do (
    if not defined VERSION (
      set "FN=%%F"
      set "FN=!FN:pg_semantius--=!"
      set "VERSION=!FN:.sql=!"
    )
  )
  if not defined VERSION (
    echo Cannot infer extension version. Run "deno task extension <ver>" once, or set SKIP_EXT_REGEN=1.
    goto :err
  )
  echo == [0/4] Regenerating the extension SQL from current migrations ^(v!VERSION!^) ==
  pushd "%REPO_ROOT%"
  call deno task extension "!VERSION!" || (popd & goto :err)
  popd
)

REM create wipes the volume itself (that is what create means here), so the suite
REM always runs against a database the image built from scratch.
if "%PULL%"=="1" (
  echo == [1/4] Creating the stack from scratch, on the PUBLISHED image ==
  call "%SCRIPT_DIR%create.cmd" -y --pull !DB_VERSION! || goto :err
) else (
  echo == [1/4] Creating the stack from scratch, on a locally built image ==
  call "%SCRIPT_DIR%create.cmd" -y --build || goto :err
)

echo == [2/4] Waiting for the pg_semantius extension to install ==
set /a tries=0
:wait
set "EXTOK="
for /f "usebackq delims=" %%R in (`docker exec %CONTAINER% psql -U postgres -d %POSTGRES_DB% -tAc "SELECT 1 FROM pg_extension WHERE extname='pg_semantius'" 2^>nul`) do set "EXTOK=%%R"
if "%EXTOK%"=="1" goto :ready
set /a tries+=1
if %tries% geq 90 (
  echo Timed out waiting for the pg_semantius extension to install.
  docker compose logs --tail 60 postgres
  goto :err
)
ping -n 3 127.0.0.1 >nul
goto :wait
:ready
echo Extension present.

echo == [3/4] Deploying nwind,test (migrate skips the seeded _core) ==
pushd "%REPO_ROOT%"
call deno task migrate --apps nwind,test --database-url "%REST_URL%" || (popd & goto :err)

echo == [4/4] Running the pgTAP suite against the extension DB ==
call deno task test --database-url "%REST_URL%" || (popd & goto :err)
popd

echo.
echo Test complete. If all tests are green, the CREATE EXTENSION
echo install of _core is equivalent to the migrate install. Run create.cmd
echo for a clean semantius (this left the nwind,test fixtures in place).
exit /b 0

:badcombo
echo --build tests local source; drop --pull / the version tag.
exit /b 1

:err
echo.
echo Test failed.
exit /b 1
