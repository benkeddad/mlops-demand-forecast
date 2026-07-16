@echo on
setlocal enabledelayedexpansion

:: This script lives in scripts\, so move to the repository root.
cd /d "%~dp0.."

echo =======================================================
echo   Docker Compose Full Clean Deployment
echo =======================================================
echo.
echo WARNING:
echo This script permanently deletes all Docker Compose data
echo belonging to this project, including:
echo.
echo   - Running and stopped project containers
echo   - Project networks
echo   - Project named volumes
echo   - Project anonymous volumes
echo   - Postgres persistent data
echo   - MLflow persistent data
echo   - Locally built project images
echo   - Orphaned project containers
echo.
echo Unrelated Docker projects will not be touched.
echo =======================================================
echo.

echo [1/3] Destroying the existing Docker Compose stack...

call docker-compose -f deploy\docker-compose.yaml down --volumes --rmi all --remove-orphans
if errorlevel 1 (
    echo.
    echo ERROR: Docker Compose destruction failed.
    pause
    exit /b 1
)

echo.
echo Existing project containers, volumes, networks, images,
echo and orphaned containers have been removed.

echo.
echo [2/3] Rebuilding every image from scratch...

call docker-compose -f deploy\docker-compose.yaml build --no-cache --pull
if errorlevel 1 (
    echo.
    echo ERROR: Docker image rebuild failed.
    pause
    exit /b 1
)

echo.
echo [3/3] Creating a completely new Docker Compose stack...

call docker-compose -f deploy\docker-compose.yaml up -d --force-recreate --renew-anon-volumes
if errorlevel 1 (
    echo.
    echo ERROR: Docker Compose startup failed.
    pause
    exit /b 1
)

echo.
echo Current Docker Compose status:
call docker-compose -f deploy\docker-compose.yaml ps

if errorlevel 1 (
    echo.
    echo ERROR: Unable to retrieve Docker Compose status.
    pause
    exit /b 1
)

echo.
echo =======================================================
echo   Full Clean Deployment Completed
echo =======================================================
echo.
echo   All project containers were recreated.
echo   All project volumes were recreated.
echo   All project images were rebuilt without cache.
echo   All previous project data was permanently deleted.
echo.
echo   API Dashboard:    http://localhost:8000
echo   MLflow Dashboard: http://localhost:5000
echo   Prefect Portal:   http://localhost:4200
echo   Database Access:  localhost:5432
echo =======================================================

pause
exit /b 0