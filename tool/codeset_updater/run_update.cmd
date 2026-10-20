@echo off
rem Interim scheduler entry (Windows Task Scheduler) until the repository is on GitHub.
rem Register once (weekly, Tuesdays 09:00 local time):
rem   schtasks /Create /TN "SOLIS\Codeset update" /SC WEEKLY /D TUE /ST 09:00 /TR "C:\Users\varsh\solis_mobile\tool\codeset_updater\run_update.cmd"
rem Run now:  schtasks /Run /TN "SOLIS\Codeset update"
rem Remove:   schtasks /Delete /TN "SOLIS\Codeset update" /F
setlocal
set TEMP=D:\temp
set TMP=D:\temp
set SOLIS_CODESETS_CACHE=C:\Users\varsh\AppData\Local\Temp\solis_codesets
cd /d C:\Users\varsh\solis_mobile
echo ==== %DATE% %TIME% >> D:\temp\solis_codeset_update.log
python -P tool\codeset_updater\update.py >> D:\temp\solis_codeset_update.log 2>&1
set RC=%ERRORLEVEL%
echo exit %RC% >> D:\temp\solis_codeset_update.log
exit /b %RC%
