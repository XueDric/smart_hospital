@echo off
setlocal
set "NODE=%USERPROFILE%\.workbuddy-ai\binaries\node\versions\22.22.2-6\node.exe"
if exist "%NODE%" (
  "%NODE%" "%~dp0tools\serve.mjs"
) else (
  node "%~dp0tools\serve.mjs"
)
pause
