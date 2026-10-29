@echo off
setlocal
cd /d "%~dp0"
rem A full frozen-source build, including native post-route hold repair.
set "FPGA_BUILD_PYTHON="
if exist "D:\Anaconda\python.exe" set "FPGA_BUILD_PYTHON=D:\Anaconda\python.exe"
if not defined FPGA_BUILD_PYTHON set "FPGA_BUILD_PYTHON=python"
"%FPGA_BUILD_PYTHON%" tools\build_gui.py %*
set "FPGA_BUILD_RESULT=%ERRORLEVEL%"
if not "%FPGA_BUILD_RESULT%"=="0" goto failed
echo.
echo [DONE] Command completed. A verified build prints its accepted candidate path.
echo The native GUI run table is separate from the acceptance report.
goto done
:failed
echo.
echo [FAILED] Build or final timing rejected. Do not use an intermediate BIT.
:done
pause
exit /b %FPGA_BUILD_RESULT%
