@echo off
setlocal
cd /d "%~dp0"
title WinSlim Ultra - may yeu 2-4 GB RAM

:menu
cls
echo.
echo  ============================================================
echo    WinSlim ULTRA  -  toi uu cho may rat yeu
echo    2-4 GB RAM / CPU doi cu / SSD nho hoac HDD
echo  ============================================================
echo.
echo    [1] Toi uu ngay (ULTRA)      - tu xin quyen Admin
echo    [2] Xem bao cao may           - khong thay doi gi
echo    [3] Mo menu day du            - bam R de hoan tac
echo    [4] Mo thu muc backup / log
echo    [0] Thoat
echo.
set "choice="
set /p "choice=  Chon [1-4, 0]: "
if "%choice%"=="" set "choice=1"

if "%choice%"=="1" goto ultra
if "%choice%"=="2" goto report
if "%choice%"=="3" goto fullmenu
if "%choice%"=="4" goto folders
if "%choice%"=="0" goto end
goto menu

:ultra
cls
echo.
echo  Dang mo WinSlim ULTRA...
echo  - Tat hieu ung/thumbnail, dich vu nen, Xbox, Insider, Geolocation
echo  - Tat auto-start OneDrive/Teams/Edge
echo  - Windows Search tat neu RAM <= 4 GB
echo  - Go bot app nang (Widgets, Mail, Phone Link, Dev Home...)
echo.
echo  Ban co the hoan tac registry/service/task bang menu [3] -^> R.
echo.
pause
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinSlim.ps1" -Preset Ultra
goto done

:report
cls
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinSlim.ps1" -Report -NoElevate
goto done

:fullmenu
cls
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinSlim.ps1"
goto done

:folders
if exist "%ProgramData%\WinSlim\Backups" start "" "%ProgramData%\WinSlim\Backups"
if exist "%LOCALAPPDATA%\WinSlim\Logs" start "" "%LOCALAPPDATA%\WinSlim\Logs"
goto menu

:done
echo.
pause
goto menu

:end
endlocal
