@echo off
setlocal EnableExtensions
title Windows Deep Cleaner
chcp 65001 >nul

set "ROOT=%~dp0"
set "MAIN=%ROOT%src\Main.ps1"

if not exist "%MAIN%" (
    echo [LOI] Khong tim thay "%MAIN%"
    pause
    exit /b 1
)

:: ---- Kiem tra quyen Administrator, neu chua co thi tu nang quyen ----
set "DWC_SELF=%~f0"
set "DWC_ARGS=%*"
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Dang yeu cau quyen Administrator...
    if "%~1"=="" (
        powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:DWC_SELF -Verb RunAs"
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:DWC_SELF -ArgumentList $env:DWC_ARGS -Verb RunAs"
    )
    exit /b
)

:: ---- Co tham so: chuyen thang cho PowerShell ----
if not "%~1"=="" goto :passthru

:menu
cls
echo ==============================================================
echo   WINDOWS DEEP CLEANER
echo   Preview truoc - chi xoa khi ban xac nhan ro rang
echo ==============================================================
echo   [1] Quet + bao cao + menu don dep  (khuyen dung)
echo   [2] Chi quet va xuat bao cao (Preview, khong xoa gi)
echo   [3] Don Temp an toan ngay (khong hoi, chi file tam cu)
echo   [4] Ap dung file CSV da danh dau (cot Delete = YES)
echo   [5] Dang ky lich chay tu dong hang tuan (chi don Temp)
echo   [6] Huy lich chay tu dong
echo   [0] Thoat
echo.
set "CHOICE="
set /p "CHOICE=Lua chon: "

if "%CHOICE%"=="1" goto :opt1
if "%CHOICE%"=="2" goto :opt2
if "%CHOICE%"=="3" goto :opt3
if "%CHOICE%"=="4" goto :opt4
if "%CHOICE%"=="5" goto :opt5
if "%CHOICE%"=="6" goto :opt6
if "%CHOICE%"=="0" exit /b 0
goto :menu

:passthru
powershell -NoProfile -ExecutionPolicy Bypass -File "%MAIN%" %*
goto :end

:opt1
powershell -NoProfile -ExecutionPolicy Bypass -File "%MAIN%"
goto :end

:opt2
powershell -NoProfile -ExecutionPolicy Bypass -File "%MAIN%" -PreviewOnly
goto :end

:opt3
powershell -NoProfile -ExecutionPolicy Bypass -File "%MAIN%" -AutoSafeClean
goto :end

:opt4
set "CSV="
set /p "CSV=Keo tha hoac nhap duong dan file CSV: "
if not defined CSV goto :menu
set "CSV=%CSV:"=%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%MAIN%" -ApplyReviewFile "%CSV%"
goto :end

:opt5
powershell -NoProfile -ExecutionPolicy Bypass -File "%MAIN%" -RegisterSchedule
goto :end

:opt6
powershell -NoProfile -ExecutionPolicy Bypass -File "%MAIN%" -UnregisterSchedule
goto :end

:end
echo.
pause
endlocal
