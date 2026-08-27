@echo off
REM Refresh the OIDC signing keys (JWKS) after the identity provider rotates them:
REM re-run the one-shot jwks-fetch to pull the current keys from JWKS_URL into the
REM shared volume, then restart ONLY the PostgREST container so it re-reads them.
REM
REM A restart is required (not a reload signal): PostgREST reads its jwt-secret from
REM the PGRST_JWT_SECRET env var (@/jwks/jwks.json), and env-var config is not
REM re-applied on a config reload - only a restart re-reads the file. The database
REM stays up; it is a ~1s blip on the API container.
REM
REM Most IdPs rotate slowly, so on demand is usually enough. For a fast-rotating
REM IdP, schedule it (e.g. a daily task) - see README ("Key rotation").
cd /d "%~dp0"

if not exist ".env" (
  echo No .env found. Run create.cmd first ^(it copies .env.example^).
  goto :err
)

for /f %%i in ('docker compose ps -aq') do set HAVE=1
if not defined HAVE (
  echo No containers exist. Run up.cmd ^(keeps existing data^) or create.cmd ^(fresh database^).
  goto :err
)

echo Refreshing JWKS from the issuer ...
docker compose run --rm jwks-fetch || goto :err

echo Restarting PostgREST to pick up the new keys ...
docker compose restart postgrest || goto :err

echo Done - PostgREST is validating against the refreshed JWKS.
exit /b 0

:err
echo.
echo Failed. Is Docker Desktop running, and has the stack been created?
exit /b 1
