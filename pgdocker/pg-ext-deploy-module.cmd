@echo off
setlocal enabledelayedexpansion
REM pg-ext-deploy-module.cmd  -  Deploy one or more app modules onto the
REM already-running EXTENSION container (port 5433), via the CLI migrate path.
REM
REM   pg-ext-deploy-module.cmd nwind
REM   pg-ext-deploy-module.cmd test,nwind
REM
REM The module list is passed straight to `migrate --apps`. `_core` comes from the
REM extension (CREATE EXTENSION), so migrate auto-prepends `_core` but SKIPS it
REM (the extension seeded `_versions`); only the given modules are deployed. The
REM connection comes from the `.env.pgdocker-ext` profile (--env pgdocker-ext).
REM Does NOT reset the stack or run tests. The mirror of pg-cli-deploy-module.cmd.
REM See pg-ext-deploy-module.sh for details.
cd /d "%~dp0"
set "REPO_ROOT=%~dp0.."

set "APPS=%~1"
if "%APPS%"=="" (
  echo usage: pg-ext-deploy-module.cmd ^<module[,module...]^>   e.g. nwind  or  test,nwind
  exit /b 2
)

echo == migrate --apps %APPS% --env pgdocker-ext ^(migrate skips the seeded _core^) ==
pushd "%REPO_ROOT%"
call deno task migrate --apps %APPS% --env pgdocker-ext || (popd & goto :err)
popd

echo.
echo Deployed onto the extension stack ^(port 5433^): %APPS%
exit /b 0

:err
echo.
echo migrate failed -- is the ext container running? Start it with pg-ext-start.cmd
exit /b 1
