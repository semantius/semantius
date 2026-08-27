@echo off
REM dokploy-build.cmd  -  regenerate the Dokploy blueprint in .\dokploy\ from this
REM folder's docker-compose.yml + Caddyfile.
REM
REM .\dokploy\ is GENERATED and COMMITTED -- never hand-edit it. Change the two
REM sources here, run this, and commit the result. The transform + validations live
REM in ..\scripts\dokploy-build.mjs; this is just the folder-local entry point, so
REM the blueprint is regenerated like every other stack operation
REM (create/start/test/...) rather than via a pnpm script.
REM
REM Needs Node (uses the `yaml` package from the repo root's node_modules -- run
REM `pnpm install` at the root once if it is missing).
cd /d "%~dp0"

where node >nul 2>&1
if errorlevel 1 (
  echo node not found - install Node.js ^(^>=18^) to build the blueprint.
  exit /b 1
)

node ..\scripts\dokploy-build.mjs %*
exit /b %ERRORLEVEL%
