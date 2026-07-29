@echo on
setlocal enabledelayedexpansion

:: This script lives in scripts\, so move to the repository root.
cd /d "%~dp0.."

echo ===================================================
echo   Docker Compose Non-Destructive Reconciliation
echo ===================================================
echo.
echo Existing containers and volumes will be preserved.
echo Healthy and unchanged containers will not be recreated.
echo.

echo [1/2] Checking the Docker Compose configuration...

call docker-compose -f deploy\docker-compose.yaml config --quiet
if errorlevel 1 (
    echo.
    echo ERROR: Docker Compose configuration is invalid.
    pause
    exit /b 1
)

echo Docker Compose configuration is valid.

echo.
echo [2/2] Reconciling Docker Compose services...

call docker-compose -f deploy\docker-compose.yaml up -d
if errorlevel 1 (
    echo.
    echo ERROR: Docker Compose reconciliation failed.
    pause
    exit /b 1
)

echo.
echo Current service status:
call docker-compose -f deploy\docker-compose.yaml ps

echo.
echo ===================================================
echo   Reconciliation completed successfully.
echo.
echo   Existing volumes were preserved.
echo   Healthy unchanged containers were preserved.
echo   Missing or stopped services were started.
echo ===================================================

pause
exit /b 0