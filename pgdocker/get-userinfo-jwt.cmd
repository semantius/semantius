@echo off
REM Show public.get_userinfo() for a given JWT (presented to Postgres via OAuth).
REM Prints the user-info JSON, the error, or a usage notice if no JWT is passed.
REM   get-userinfo-jwt.cmd <jwt>
cd /d "%~dp0"
deno run --allow-net get_userinfo_jwt.ts %*
pause
