@echo off
title HEVC 4:4:4 Private Preview Configuration

echo ==========================================
echo      HEVC 4:4:4 Private Preview Toggle
echo ==========================================
echo.
echo 1 = Enable HEVC 4:4:4 Preview
echo 2 = Disable HEVC 4:4:4 Preview
echo.
set /p choice=Enter your choice (1 or 2):

:: Registry locations
set TSKEY=HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services
set CLOUDKEY=HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\RdpCloudStackSettings

if "%choice%"=="1" goto ENABLE
if "%choice%"=="2" goto DISABLE

echo.
echo Invalid selection.
pause
exit /b

:ENABLE
echo.
echo Enabling HEVC 4:4:4 Private Preview...
echo.

:: Enable Hardware Acceleration
reg add "%TSKEY%" /v bEnumerateHWBeforeSW /t REG_DWORD /d 1 /f

:: Enable HEVC Hardware Encoding
reg add "%TSKEY%" /v HEVCHardwareEncodePreferred /t REG_DWORD /d 1 /f

:: Keep AVC available for fallback
reg add "%TSKEY%" /v AVCHardwareEncodePreferred /t REG_DWORD /d 1 /f
reg add "%TSKEY%" /v AVC444ModePreferred /t REG_DWORD /d 1 /f

:: Enable HEVC 4:4:4 Preview
reg add "%CLOUDKEY%" /v EnableHEVC444Threshold /t REG_DWORD /d 100 /f

:: High Quality Image Mode (4:4:4)
reg add "%TSKEY%" /v ImageQuality /t REG_DWORD /d 2 /f

echo.
echo HEVC 4:4:4 Preview ENABLED.
echo Disconnect and reconnect your session.
goto END

:DISABLE
echo.
echo Disabling HEVC 4:4:4 Private Preview...
echo.

reg add "%CLOUDKEY%" /v EnableHEVC444Threshold /t REG_DWORD /d 0 /f

:: Optional - restore standard HEVC profile
reg add "%TSKEY%" /v ImageQuality /t REG_DWORD /d 3 /f

echo.
echo HEVC 4:4:4 Preview DISABLED.
echo Disconnect and reconnect your session.
goto END

:END
echo.
pause
