@echo off
rem Bridge from Inno Setup's compile-time SignTool (ISCC runs under Wine
rem on the linux publish agent) back to the host-side Azure Trusted Signing
rem signer: Wine's start.exe can launch host binaries via /unix. CODESIGN_SH
rem holds the host path of utilities/windows/codesign.sh (exported by
rem upload_julia.sh; linux environment variables are visible inside Wine).
rem %1 is a Windows-style path, translated back via winepath in codesign.sh.
start /wait /unix /bin/bash "%CODESIGN_SH%" %1
if errorlevel 1 exit /b 1
