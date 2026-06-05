@echo off
REM Print a JWT access token for a user, minted from the test OIDC server.
REM Prints the token, or an error if the name is missing / no token is returned.
REM   get-user-token.cmd <user-name>
REM (No pause: the token is written to stdout so it can be captured/piped.)
cd /d "%~dp0"
deno run --allow-net --allow-read get_user_token.ts %*
