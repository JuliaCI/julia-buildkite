@echo off
rem Bridge from Inno Setup's compile-time SignTool (ISCC runs under Wine on the
rem linux publish agent) back to the host-side Azure Trusted Signing signer
rem codesign.sh. CODESIGN_SH / CODESIGN_HOOK_DONE[_WIN] are exported by
rem upload_julia.sh and Wine forwards linux environment variables verbatim.
rem
rem Two Wine quirks shape this bridge:
rem   * `start /unix` applies Windows->Unix path translation to its positional
rem     arguments, corrupting the codesign.sh host path -- so the signer script
rem     and the target are passed through the environment, not as arguments.
rem   * `start /wait /unix` does NOT wait for the launched *Unix* process: it
rem     returns before codesign.sh has signed, and ISCC then reaps the transient
rem     uninstaller temp out from under jsign. So launch asynchronously and
rem     block here until codesign.sh writes its exit code to a marker file.
rem
rem %1 is a Windows path, translated back inside codesign.sh. CI paths are
rem space-free, so the unquoted expansions below are safe.
set SIGN_TARGET=%~1
del "%CODESIGN_HOOK_DONE_WIN%" 2>nul
start /unix /bin/bash -c "$CODESIGN_SH $SIGN_TARGET; r=$?; echo $r > $CODESIGN_HOOK_DONE; exit $r"
:wait_signer
if exist "%CODESIGN_HOOK_DONE_WIN%" goto signer_done
rem ~1s poll; degrades to a busy-loop if ping is unavailable in this Wine.
ping -n 2 127.0.0.1 >nul 2>&1
goto wait_signer
:signer_done
set /p SIGNER_RC=<"%CODESIGN_HOOK_DONE_WIN%"
rem Consume the marker so the next (sequential) SignTool call can't misread a
rem stale exit code if its start-of-call delete ever no-ops.
del "%CODESIGN_HOOK_DONE_WIN%" 2>nul
if not "%SIGNER_RC%"=="0" exit /b 1
