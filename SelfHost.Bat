@echo off
echo ===============================
echo   Windows 365 Environment Setter
echo ===============================
echo.
echo 1 = Turn On Selfhost
echo 2 = Turn Off SelfHost
echo.

set /p choice=Enter your choice (1 or 2): 

:: Key information
set key=HKCU\SOFTWARE\Microsoft\Windows365
set valueName=Environment

if "%choice%"=="1" (
    set valueData=0
) else if "%choice%"=="2" (
    reg delete HKCU\SOFTWARE\Microsoft\Windows365 /v Environment /f
    pause
    exit /b
) else (
    echo Invalid selection.
    pause
    exit /b
)

echo.
echo Updating registry...
echo Key:   %key%
echo Value: %valueName%
echo Data:  %valueData%
echo.

reg add "%key%" /v "%valueName%" /t REG_DWORD /d %valueData% /f

if %errorlevel%==0 (
    echo Registry updated successfully!
) else (
    echo Failed to update registry.
)

echo.
pause
