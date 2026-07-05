@echo on
setlocal enabledelayedexpansion

echo [1/3] Stopping old containers and removing volumes...
call docker-compose down -v

echo [2/3] Building Docker images...
call docker-compose build

echo [3/3] Starting Docker containers...
call docker-compose up -d

echo ===================================================
echo Process complete! Check Docker Desktop.
echo Containers have been cleanly rebuilt and restarted.
echo ===================================================
pause
exit /b 0
