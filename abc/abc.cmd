@echo off
setlocal enableextensions

REM Windows wrapper for the abc-flow Python launcher.
REM
REM Keep this file next to:
REM   - abc   (python launcher)
REM   - abc.tcl
REM
REM Usage:
REM   abc [args...]

set "SCRIPT_DIR=%~dp0"

REM Prefer the Python Launcher (py) if available, fallback to python.
where py >nul 2>nul
if %ERRORLEVEL%==0 (
  py -3 "%SCRIPT_DIR%abc" %*
  exit /b %ERRORLEVEL%
)

python "%SCRIPT_DIR%abc" %*
exit /b %ERRORLEVEL%

