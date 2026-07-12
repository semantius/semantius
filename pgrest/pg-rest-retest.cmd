@echo off
setlocal
REM pg-rest-retest.cmd  -  Retest the ALREADY-RUNNING pgrest database IN PLACE.
REM Thin wrapper around the CLI `retest` (dropall -> migrate --apps test,nwind ->
REM test) pointed at this stack's appdb over its fixed connection string -- the same
REM in-place reset used on hosted Postgres (e.g. Neon) where you cannot drop and
REM recreate the database/container.
REM
REM Extra args are forwarded to `deno task retest` (e.g. --confirm to skip the
REM prompt, --failfast). The CLI prompts for confirmation unless --confirm is passed.
REM
REM NOTE: on the pgrest stack `_core` is installed via CREATE EXTENSION, so dropall
REM leaves the extension-owned `_core` in place and only resets the test/nwind
REM objects. To fully rebuild and reinstall `_core` the real way (fresh container +
REM CREATE EXTENSION), use pg-rest-test.cmd.
cd /d "%~dp0"
set "REPO_ROOT=%~dp0.."
set "CONTAINER=postgres18-rest"

if not exist ".env" (
  echo .env not found in %CD% -- run pg-rest-create.cmd first. & exit /b 1
)

set "POSTGRES_PASSWORD=postgres"
set "POSTGRES_PORT=5434"
set "POSTGRES_DB=appdb"
for /f "usebackq tokens=1,* delims==" %%A in (".env") do (
  if /i "%%A"=="POSTGRES_PASSWORD" set "POSTGRES_PASSWORD=%%B"
  if /i "%%A"=="POSTGRES_PORT" set "POSTGRES_PORT=%%B"
  if /i "%%A"=="POSTGRES_DB" set "POSTGRES_DB=%%B"
)
set "REST_URL=postgresql://postgres:%POSTGRES_PASSWORD%@localhost:%POSTGRES_PORT%/%POSTGRES_DB%"

set "UP="
for /f "usebackq delims=" %%N in (`docker ps --format "{{.Names}}" ^| findstr /x "%CONTAINER%"`) do set "UP=%%N"
if not defined UP (
  echo Container '%CONTAINER%' is not running.
  echo Start the stack first:  pg-rest-create.cmd   ^(or pg-rest-start.cmd^)
  exit /b 1
)

echo == Retesting '%POSTGRES_DB%' in place via "deno task retest" ==
pushd "%REPO_ROOT%"
call deno task retest --database-url "%REST_URL%" %*
set "RC=%ERRORLEVEL%"
popd
exit /b %RC%
