@echo off
REM Run all auth checks against the running EXTENSION container (needs Deno on
REM PATH). The extension installs _core, so rbac.uid()/get_userinfo() exist.
REM Targets the ext stack's port (5433):
REM   verify_oauth.ts        - bearer: server validates the token + publishes claims
REM   test_oauth_security.ts - bearer: a hostile client cannot impersonate
REM   verify_session.ts      - session: SCRAM connect + SET ROLE + claims -> RLS
REM   test_session_trust.ts  - session: trust model + negatives
REM NOTE: like the other .cmd runner, this collapses ANY non-zero to exit 1.
cd /d "%~dp0"

echo == verify_oauth.ts (port 5433) ==
deno run --allow-net verify_oauth.ts --port 5433 || goto :err
echo.
echo == test_oauth_security.ts (port 5433) ==
deno run --allow-net test_oauth_security.ts --port 5433 || goto :err
echo.
echo == verify_session.ts (port 5433) ==
deno run --allow-net --allow-env --allow-read verify_session.ts --port 5433 || goto :err
echo.
echo == test_session_trust.ts (port 5433) ==
deno run --allow-net --allow-env --allow-read test_session_trust.ts --port 5433 || goto :err

exit /b 0

:err
echo.
echo Check failed. Is the container running (pg-ext-start.cmd) and the extension installed?

exit /b 1
