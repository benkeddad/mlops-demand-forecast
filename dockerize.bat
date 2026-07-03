@echo on
setlocal enabledelayedexpansion

echo [1/8] Backing up current local DVC and MLflow...
if exist .dvc (
    xcopy /E /I /Y .dvc .dvc_backup >nul
    rmdir /S /Q .dvc
)
if exist dvc.lock (
    copy /Y dvc.lock dvc.lock.backup >nul
    del dvc.lock
)
if exist mlartifacts (
    xcopy /E /I /Y mlartifacts mlartifacts_backup >nul
    rmdir /S /Q mlartifacts
)
if exist mlruns (
    xcopy /E /I /Y mlruns mlruns_backup >nul
    rmdir /S /Q mlruns
)

echo [2/8] Initializing clean temporary DVC for Docker...
call dvc init --no-scm
if %ERRORLEVEL% neq 0 pause

echo [3/8] Stopping old containers...
call docker-compose down -v

echo [4/8] Building Docker images...
:: We ONLY build here so the fresh .dvc is copied into the image.
:: We do NOT start the containers yet!
call docker-compose build

echo [5/8] Wiping temporary DVC and restoring your original local files...
if exist .dvc rmdir /S /Q .dvc
if exist .dvc_backup (
    xcopy /E /I /Y .dvc_backup .dvc >nul
    rmdir /S /Q .dvc_backup
)
if exist dvc.lock.backup (
    copy /Y dvc.lock.backup dvc.lock >nul
    del dvc.lock.backup
)
if exist mlartifacts_backup (
    xcopy /E /I /Y mlartifacts_backup mlartifacts >nul
    rmdir /S /Q mlartifacts_backup
)
if exist mlruns_backup (
    xcopy /E /I /Y mlruns_backup mlruns >nul
    rmdir /S /Q mlruns_backup
)

echo [6/8] Starting Docker containers...
:: Now we start them AFTER your local files are safely restored.
call docker-compose up -d

echo [7/8] Giving containers a moment to boot...
timeout /t 5

echo [8/8] Running final local DVC pull sync...
call dvc pull

echo ===================================================
echo Process complete! Check Docker Desktop.
echo Your containers should be running with the clean DVC,
echo and your local machine has its original DVC restored.
echo ===================================================
pause
exit /b 0