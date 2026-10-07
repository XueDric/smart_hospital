@echo off
rem Wrapper around build.ps1 so that no "-ExecutionPolicy Bypass" is needed
rem (a fresh Windows box forbids running .ps1 files by default).
rem Usage:  build.cmd  [same options as build.ps1]
rem NOTE: keep this file ASCII-only and WITHOUT a BOM -- a BOM in a .cmd file
rem       makes cmd.exe try to execute the BOM bytes.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
exit /b %ERRORLEVEL%
