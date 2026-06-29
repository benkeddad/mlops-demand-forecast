@echo off
echo [1/6] Backing up your original DVC configurations...
if exist .dvc (
    xcopy /E /I /Y .dvc .dvc_backup >nul
)
if exist dvc.lock (
    copy /Y dvc.lock dvc.lock.backup >nul
)


echo [3/6] Clearing lock state and forcing clean DVC init for Docker...
dvc init --no-scm -f

echo [4/6] Stopping existing Docker containers...
docker-compose down

echo [5/6] Rebuilding and launching Docker containers (with clean DVC state)...
docker-compose up --build -d

echo [6/6] Restoring original DVC files back to your host workspace...
if exist .dvc_backup (
    rmdir /S /Q .dvc
    xcopy /E /I /Y .dvc_backup .dvc >nul
    rmdir /S /Q .dvc_backup
)
if exist dvc.lock.backup (
    copy /Y dvc.lock.backup dvc.lock >nul
    del dvc.lock.backup >nul
)

echo ===================================================
echo Local DVC sync and Docker stack deployment complete!
echo ===================================================
pause