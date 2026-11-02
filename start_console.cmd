@echo off
rem Stairwell Watch host console launcher.
rem Prefers an interpreter that ships tkinter; falls back to PATH python.
cd /d "%~dp0"

set "PY="
if exist "D:\Anaconda\python.exe" set "PY=D:\Anaconda\python.exe"
if not defined PY if exist "D:\Python\Python3.13.4\python.exe" set "PY=D:\Python\Python3.13.4\python.exe"
if not defined PY set "PY=python"

"%PY%" "tools\launch_console.py" %*
if errorlevel 1 pause
