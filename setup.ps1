# ===================================================
# Vanity Tracker - Quick Installation & Setup (PowerShell)
# ===================================================

Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "      Vanity Tracker - Quick Installation" -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Check Flutter
Write-Host "[1/4] Checking Flutter installation..." -ForegroundColor Yellow
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Flutter SDK not found in PATH." -ForegroundColor Red
    Write-Host "Please download Flutter from https://docs.flutter.dev/get-started/install/windows"
    Write-Host "and add C:\src\flutter\bin to your System PATH."
    exit 1
}

# 2. Get packages
Write-Host "[2/4] Installing dependencies (flutter pub get)..." -ForegroundColor Yellow
flutter pub get

# 3. Run tests
Write-Host "`n[3/4] Running automated tests (flutter test)..." -ForegroundColor Yellow
flutter test

# 4. Success message
Write-Host "`n[4/4] Setup completed successfully!" -ForegroundColor Green
Write-Host "To launch the app on your emulator/device, run:" -ForegroundColor White
Write-Host "   flutter run" -ForegroundColor Cyan
