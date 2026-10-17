@echo off
setlocal
rem ==========================================================================
rem  Smart Hospital - HarmonyOS build entry (wrapper around DevEco hvigor)
rem
rem  Why a wrapper instead of the DevEco-generated hvigorw:
rem    The generated hvigorw bootstraps pnpm + @ohos/hvigor from the network the
rem    first time (writing %USERPROFILE%\.hvigor). This repo ships the same
rem    0-byte hvigor/hvigor-wrapper.js placeholder as the DevEco New Project
rem    template, and an offline/competition machine may not be able to install
rem    that toolchain. So we call the hvigor that ships with the local DevEco
rem    Studio (6.26.4) and only fill in environment defaults. No downloads.
rem
rem  Usage (same arguments as the official hvigorw):
rem    .\hvigorw.bat --mode module -p product=default -p module=entry@default assembleHap --no-daemon
rem    .\hvigorw.bat clean
rem
rem  Overridable environment variables:
rem    HVIGOR_HOME       <DevEco>\tools\hvigor\bin  (auto-detected)
rem    DEVECO_SDK_HOME   <DevEco>\sdk               (auto-detected)
rem    JAVA_HOME         <DevEco>\jbr               (auto-detected; a Java 1.7 on
rem                      PATH makes PackageHap fail with UnsupportedClassVersionError 52.0)
rem    HVIGOR_USER_HOME  hvigor toolchain/cache home (default %USERPROFILE%\.hvigor)
rem ==========================================================================

rem --- locate hvigor ---
if not "%HVIGOR_HOME%"=="" goto have_hvigor
if exist "D:\DevEco Studio\tools\hvigor\bin\hvigorw.bat" set "HVIGOR_HOME=D:\DevEco Studio\tools\hvigor\bin"
if not "%HVIGOR_HOME%"=="" goto have_hvigor
if exist "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" set "HVIGOR_HOME=C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin"
if not "%HVIGOR_HOME%"=="" goto have_hvigor
if exist "%LOCALAPPDATA%\Huawei\DevEcoStudio\tools\hvigor\bin\hvigorw.bat" set "HVIGOR_HOME=%LOCALAPPDATA%\Huawei\DevEcoStudio\tools\hvigor\bin"
if not "%HVIGOR_HOME%"=="" goto have_hvigor
echo [hvigorw] Cannot find the hvigor bundled with DevEco Studio.
echo [hvigorw] Set HVIGOR_HOME to ...\DevEco Studio\tools\hvigor\bin, e.g.
echo [hvigorw]   set HVIGOR_HOME=D:\DevEco Studio\tools\hvigor\bin
echo [hvigorw] Or build from the DevEco Studio UI: Build ^> Build Hap(s).
exit /b 1

:have_hvigor

rem --- SDK / JDK defaults (both live next to tools\hvigor in a DevEco install) ---
if not "%DEVECO_SDK_HOME%"=="" goto have_sdk
for %%D in ("%HVIGOR_HOME%\..\..\..") do if exist "%%~fD\sdk" set "DEVECO_SDK_HOME=%%~fD\sdk"
:have_sdk
if not "%JAVA_HOME%"=="" goto have_java
for %%D in ("%HVIGOR_HOME%\..\..\..") do if exist "%%~fD\jbr" set "JAVA_HOME=%%~fD\jbr"
:have_java
if "%JAVA_HOME%"=="" goto run
set "PATH=%JAVA_HOME%\bin;%PATH%"

:run
call "%HVIGOR_HOME%\hvigorw.bat" %*
exit /b %ERRORLEVEL%
