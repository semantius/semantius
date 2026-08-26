@echo off
setlocal enabledelayedexpansion
REM pg-cli-deploy-module.cmd  -  Deploy one or more app modules onto the
REM already-running plain CLI-testing container (port 5432), via the CLI migrate
REM path.
REM
REM   pg-cli-deploy-module.cmd nwind
REM   pg-cli-deploy-module.cmd nwind,test
REM
REM The module list is passed straight to `migrate --apps`. migrate auto-prepends
REM `_core` (no-op if already applied). The connection comes from the
REM `.env.pgdocker-cli` profile (--env pgdocker-cli). Does NOT recreate the
REM container, dropall, or run tests. The mirror of pg-ext-deploy-module.cmd.
REM See pg-cli-deploy-module.sh for details.
cd /d "%~dp0"
set "REPO_ROOT=%~dp0.."

set "APPS=%~1"
if "%APPS%"=="" (
  echo usage: pg-cli-deploy-module.cmd ^<module[,module...]^>   e.g. nwind  or  nwind,test
  exit /b 2
)

echo == migrate --apps %APPS% --env pgdocker-cli ^(auto-prepends _core^) ==
pushd "%REPO_ROOT%"
call deno task migrate --apps %APPS% --env pgdocker-cli || (popd & goto :err)
popd

echo.
echo Deployed onto the CLI stack ^(port 5432^): %APPS%
exit /b 0

:err
echo.
echo migrate failed -- is the CLI container running? Start it with pg-cli-start.cmd
exit /b 1
