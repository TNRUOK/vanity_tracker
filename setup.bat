@echo off
echo ===================================================
echo       Vanity Tracker - Quick Installation & Setup
echo ===================================================
echo.

echo [1/4] Checking Flutter SDK...
where flutter >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Flutter is not found in your PATH.
    echo Please install Flutter from https://docs.flutter.dev/get-started/install/windows
    echo and add flutter/bin to your environment variables.
    pause
    exit /b 1
)

echo [2/4] Fetching app packages and dependencies...
call flutter pub get
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Failed to fetch packages.
    pause
    exit /b 1
)

echo.
echo [3/4] Running automated unit tests...
call flutter test
if %ERRORLEVEL% NEQ 0 (
    echo [WARNING] Some tests failed. Check logs above.
) else (
    echo [SUCCESS] All unit tests passed!
)

echo.
echo [4/4] Setup complete!
echo.
echo To launch the app on your connected device/emulator:
echo   flutter run
echo.
pause
