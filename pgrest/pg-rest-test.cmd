@echo off
setlocal enabledelayedexpansion
REM pg-rest-test.cmd  -  Test the EXACT pgrest deployment behavior end to end -- a
REM FRESH container, a FRESH data volume, and `_core` installed via CREATE EXTENSION
REM pg_semantic_platform (the whole _core install in ONE transaction), then deploy
REM test,nwind and run the full pgTAP suite. See pg-rest-test.sh for the full
REM rationale.
REM
REM This is the FIRST-TIME test of a clean install (not a re-test): it rebuilds from
REM current source, exercising the image build + init scripts + role bootstrap from
REM scratch -- the real production install path. Twin of pgdocker/pg-ext-retest.cmd.
REM
REM DESTRUCTIVE: wipes the pgrest data volume and rebuilds from current source.
REM PROMPTS for confirmation first (like pg-rest-destroy.cmd); bypass with -y/--yes
REM or ASSUME_YES=1 / CI=true. Afterwards the stack holds test,nwind; run
REM pg-rest-create.cmd for a clean semantius.
REM
REM Steps: 0 regen extension SQL, 1 down -v, 2 pg-rest-create, 3 wait for extension,
REM        4 migrate test,nwind, 5 test.
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

REM Safety: this DESTROYS the running pgrest stack + its data volume (down -v) and
REM rebuilds it. Confirm before any changes -- same guard as pg-rest-destroy.cmd.
REM Bypass for automation: pass -y/--yes, or set ASSUME_YES=1 or CI=true.
set "FORCE=0"
if /i "%~1"=="-y" set "FORCE=1"
if /i "%~1"=="--yes" set "FORCE=1"
if "%ASSUME_YES%"=="1" set "FORCE=1"
if "%CI%"=="true" set "FORCE=1"
if "%FORCE%"=="0" (
  set /p ans=This DESTROYS the running pgrest stack and WIPES its data volume ^('%POSTGRES_DB%', all data^), then rebuilds. Continue? [y/N]
  if /i not "!ans!"=="y" ( echo Cancelled. & exit /b 0 )
)

REM [0/5] Regenerate the extension from CURRENT migrations (skip with SKIP_EXT_REGEN=1).
REM Version inferred from the newest built extension SQL (dir /o-n = name-descending).
if not "%SKIP_EXT_REGEN%"=="1" (
  set "VERSION="
  for /f "delims=" %%F in ('dir /b /o-n "%REPO_ROOT%\extension\pg_semantic_platform--*.sql" 2^>nul') do (
    if not defined VERSION (
      set "FN=%%F"
      set "FN=!FN:pg_semantic_platform--=!"
      set "VERSION=!FN:.sql=!"
    )
  )
  if not defined VERSION (
    echo Cannot infer extension version. Run "deno task extension <ver>" once, or set SKIP_EXT_REGEN=1.
    goto :err
  )
  echo == [0/5] Regenerating the extension SQL from current migrations (v!VERSION!) ==
  pushd "%REPO_ROOT%"
  call deno task extension "!VERSION!" || (popd & goto :err)
  popd
)

echo == [1/5] Resetting the pgrest stack (down -v) ==
docker compose down -v || goto :err

echo == [2/5] Rebuilding the image + bringing the stack up fresh ==
call "%SCRIPT_DIR%pg-rest-create.cmd" || goto :err

echo == [3/5] Waiting for the pg_semantic_platform extension to install ==
set /a tries=0
:wait
set "EXTOK="
for /f "usebackq delims=" %%R in (`docker exec %CONTAINER% psql -U postgres -d %POSTGRES_DB% -tAc "SELECT 1 FROM pg_extension WHERE extname='pg_semantic_platform'" 2^>nul`) do set "EXTOK=%%R"
if "%EXTOK%"=="1" goto :ready
set /a tries+=1
if %tries% geq 90 (
  echo Timed out waiting for the pg_semantic_platform extension to install.
  docker compose logs --tail 60 postgres
  goto :err
)
ping -n 3 127.0.0.1 >nul
goto :wait
:ready
echo Extension present.

echo == [4/5] Deploying test,nwind (migrate skips the seeded _core) ==
pushd "%REPO_ROOT%"
call deno task migrate --apps test,nwind --database-url "%REST_URL%" || (popd & goto :err)

echo == [5/5] Running the pgTAP suite against the extension DB ==
call deno task test --database-url "%REST_URL%" || (popd & goto :err)
popd

echo.
echo pg-rest-test complete. If all tests are green, the CREATE EXTENSION
echo install of _core is equivalent to the migrate install. Run pg-rest-create.cmd
echo for a clean semantius (this left the test,nwind fixtures in place).
exit /b 0

:err
echo.
echo pg-rest-test failed.
exit /b 1
