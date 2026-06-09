@echo off
REM Run all auth checks against the running CLI container (needs Deno on PATH):
REM   verify_oauth.ts        - bearer: server validates the token + publishes claims
REM   test_oauth_security.ts - bearer: a hostile client cannot impersonate (needs _core)
REM   verify_session.ts      - session: SCRAM connect + SET ROLE + claims -> RLS (needs _core)
REM   test_session_trust.ts  - session: trust model + negatives
REM NOTE: unlike the .sh runner, this collapses ANY non-zero (incl. the "2 =
REM _core not deployed" skip) to exit 1 — deploy _core first for a clean run.
cd /d "%~dp0"

echo == verify_oauth.ts ==
deno run --allow-net verify_oauth.ts || goto :err
echo.
echo == test_oauth_security.ts ==
deno run --allow-net test_oauth_security.ts || goto :err
echo.
echo == verify_session.ts ==
deno run --allow-net --allow-env --allow-read verify_session.ts || goto :err
echo.
echo == test_session_trust.ts ==
deno run --allow-net --allow-env --allow-read test_session_trust.ts || goto :err

exit /b 0

:err
echo.
echo Check failed. Is the container running (pg-cli-start.cmd) and _core deployed?

exit /b 1
