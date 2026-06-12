@echo off
setlocal enabledelayedexpansion
REM pg-ext-retest.cmd  -  Path B harness: prove the extension-installed `_core`
REM is equivalent to the migrate-installed `_core` by running the SAME pgTAP
REM suite on top of an EXTENSION install. See pg-ext-retest.sh for details.
REM
REM Fully non-interactive. Steps:
REM   1. down -v        reset the ext stack (wipe the data volume). NOT
REM                     pg-ext-delete, which prompts and would hang.
REM   2. pg-ext-create  fresh ext container; CREATE EXTENSION installs _core and
REM                     creates + seeds the _versions guard rows.
REM   3. readiness gate poll until the pg_semantic_platform extension is present.
REM   4. migrate --apps test,nwind   migrate auto-prepends _core, SKIPPED
REM                     because the extension seeded _versions; deploys only
REM                     test,nwind. (The extension's _core already includes the
REM                     webhook_receivers/dashboards tables that test.0030_seed
REM                     and several test files depend on.)
REM   5. test           run the full pgTAP suite against the ext DB.
cd /d "%~dp0"
set "REPO_ROOT=%~dp0.."
set "COMPOSE_FILE=docker-compose.ext.yml"
set "PROJECT=semantius-ext"
set "CONTAINER=postgres18-ext"

echo == [1/5] Resetting the extension stack (down -v) ==
docker compose -f "%COMPOSE_FILE%" -p "%PROJECT%" down -v || goto :err

echo == [2/5] Creating a fresh extension container ==
call "%~dp0pg-ext-create.cmd" || goto :err

REM Derive the DBA connection from the live .env (NOT hard-coded: the checked-out
REM .env uses `devpassword`). Defaults match docker-compose.ext.yml.
set "POSTGRES_PASSWORD="
set "POSTGRES_DB=appdb"
set "POSTGRES_EXT_PORT=5433"
for /f "usebackq tokens=1,* delims==" %%A in (".env") do (
  if /i "%%A"=="POSTGRES_PASSWORD" set "POSTGRES_PASSWORD=%%B"
  if /i "%%A"=="POSTGRES_DB" set "POSTGRES_DB=%%B"
  if /i "%%A"=="POSTGRES_EXT_PORT" set "POSTGRES_EXT_PORT=%%B"
)
if not defined POSTGRES_PASSWORD (
  echo POSTGRES_PASSWORD not found in .env & goto :err
)
set "EXT_URL=postgresql://postgres:%POSTGRES_PASSWORD%@localhost:%POSTGRES_EXT_PORT%/%POSTGRES_DB%"

echo == [3/5] Waiting for the pg_semantic_platform extension to install ==
REM Tolerate early connection refused / empty results.
set /a tries=0
:wait
set "EXTOK="
for /f "usebackq delims=" %%R in (`docker exec %CONTAINER% psql -U postgres -d %POSTGRES_DB% -tAc "SELECT 1 FROM pg_extension WHERE extname='pg_semantic_platform'" 2^>nul`) do set "EXTOK=%%R"
if "%EXTOK%"=="1" goto :ready
set /a tries+=1
if %tries% geq 90 (
  echo Timed out waiting for the pg_semantic_platform extension to install.
  docker compose -f "%COMPOSE_FILE%" -p "%PROJECT%" logs --tail 60
  goto :err
)
REM wait ~2s without needing console input
ping -n 3 127.0.0.1 >nul
goto :wait
:ready
echo Extension present.

echo == [4/5] Deploying test,nwind (migrate skips the seeded _core) ==
pushd "%REPO_ROOT%"
call deno task migrate --apps test,nwind --database-url "%EXT_URL%" || (popd & goto :err)

echo == [5/5] Running the pgTAP suite against the extension DB ==
call deno task test --database-url "%EXT_URL%" || (popd & goto :err)
popd

echo.
echo Path B complete. If all tests are green, extension-_core == migrate-_core.
exit /b 0

:err
echo.
echo pg-ext-retest failed.
exit /b 1
