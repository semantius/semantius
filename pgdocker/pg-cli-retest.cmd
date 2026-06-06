@echo off
setlocal enabledelayedexpansion
REM pg-cli-retest.cmd  -  Path A harness: deploy `_core,cloud,test,nwind` via the
REM CLI migrate path onto the plain CLI-testing container, then run the pgTAP
REM suite. The mirror of pg-ext-retest.cmd. See pg-cli-retest.sh for details.
cd /d "%~dp0"
set "REPO_ROOT=%~dp0.."
set "CONTAINER=postgres18-cli"

echo == [1/3] Creating a fresh CLI-testing container ==
call pg-cli-create.cmd || goto :err

set "POSTGRES_DB=appdb"
for /f "usebackq tokens=1,* delims==" %%A in (".env") do (
  if /i "%%A"=="POSTGRES_DB" set "POSTGRES_DB=%%B"
)

echo == [2/3] Waiting for the DBA login to accept connections ==
set /a tries=0
:wait
docker exec %CONTAINER% pg_isready -U postgres -d %POSTGRES_DB% >nul 2>&1
if not errorlevel 1 goto :ready
set /a tries+=1
if %tries% geq 90 (
  echo Timed out waiting for PostgreSQL to accept connections.
  docker compose logs --tail 60
  goto :err
)
ping -n 3 127.0.0.1 >nul
goto :wait
:ready
echo PostgreSQL ready.

echo == [3/3] retest (dropall -^> migrate _core,cloud,test,nwind -^> test) ==
pushd "%REPO_ROOT%"
call deno task retest --confirm --env pgdocker || (popd & goto :err)
popd

echo.
echo Path A complete. If all tests are green, the migrate path is good.
exit /b 0

:err
echo.
echo pg-cli-retest failed.
exit /b 1
