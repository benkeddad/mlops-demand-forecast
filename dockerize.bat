@echo off

echo [1/6] Backing up and removing original DVC configurations...
if exist .dvc (
    xcopy /E /I /Y .dvc .dvc_backup >nul
    rmdir /S /Q .dvc
)

if exist dvc.lock (
    copy /Y dvc.lock dvc.lock.backup >nul
    del dvc.lock >nul
)

echo [2/6] Initializing clean DVC environment for Docker...
dvc init --no-scm

echo [3/6] Stopping existing Docker containers...
docker-compose down

echo [4/6] Rebuilding and launching Docker containers (with clean DVC state)...
docker-compose up --build -d

echo [5/6] Restoring original DVC files...
if exist .dvc_backup (
    rmdir /S /Q .dvc
    xcopy /E /I /Y .dvc_backup .dvc >nul
    rmdir /S /Q .dvc_backup
)

if exist dvc.lock.backup (
    copy /Y dvc.lock.backup dvc.lock >nul
    del dvc.lock.backup >nul
)

echo [6/6] Running DVC sync after restore...
dvc pull

echo ===================================================
echo Local DVC sync and Docker stack deployment complete!
echo ===================================================
pause