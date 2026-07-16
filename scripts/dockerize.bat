@echo on
setlocal enabledelayedexpansion

:: Claude added this line: this script now lives in scripts/, so jump back to repo root first
cd /d "%~dp0.."

echo [1/3] Stopping old containers and removing volumes...
:: Claude modified these three lines: docker-compose.yaml moved to deploy/docker-compose.yaml
call docker-compose -f deploy\docker-compose.yaml down -v

echo [2/3] Building Docker images...
call docker-compose -f deploy\docker-compose.yaml build

echo [3/3] Starting Docker containers...
call docker-compose -f deploy\docker-compose.yaml up -d

echo ===================================================
echo Process complete! Check Docker Desktop.
echo Containers have been cleanly rebuilt and restarted.
echo ===================================================
pause
exit /b 0
