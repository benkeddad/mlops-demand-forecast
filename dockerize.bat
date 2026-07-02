@echo on
setlocal enabledelayedexpansion

echo [1/12] Backing up current local DVC configurations...
if exist .dvc (
    xcopy /E /I /Y .dvc .dvc_backup
    rmdir /S /Q .dvc
)
if exist dvc.lock (
    copy /Y dvc.lock dvc.lock.backup
    del dvc.lock
)

echo [2/12] Backing up current local MLflow tracking folders...
if exist mlartifacts (
    xcopy /E /I /Y mlartifacts mlartifacts_backup
    rmdir /S /Q mlartifacts
)
if exist mlruns (
    xcopy /E /I /Y mlruns mlruns_backup
    rmdir /S /Q mlruns
)

echo [3/12] Initializing clean temporary DVC environment...
call dvc init --no-scm
if %ERRORLEVEL% neq 0 pause

echo [4/12] Activating virtual environment and updating dependencies...
set "VENV_PATH="
if exist venv\Scripts\activate.bat set "VENV_PATH=venv"
if exist .venv\Scripts\activate.bat set "VENV_PATH=.venv"

if defined VENV_PATH (
    echo Activating local environment: .\%VENV_PATH%
    call .\%VENV_PATH%\Scripts\activate.bat
    if exist requirements.txt (
        call pip install --no-cache-dir -r requirements.txt
    )
) else (
    echo [WARNING] No venv found. Using global system Python...
    if exist requirements.txt (
        call pip install --no-cache-dir -r requirements.txt
    )
)
if %ERRORLEVEL% neq 0 pause

echo [5/12] Launching local MLflow server in a separate terminal window...
if defined VENV_PATH (
    start "MLflow_Local_Server" cmd /k "call .\%VENV_PATH%\Scripts\activate.bat && mlflow server --host 127.0.0.1 --port 5000"
) else (
    start "MLflow_Local_Server" cmd /k "mlflow server --host 127.0.0.1 --port 5000"
)
timeout /t 10

echo [6/12] Running local DVC pipeline training...
call dvc repro
if %ERRORLEVEL% neq 0 (
    echo [CRITICAL ERROR] dvc repro failed with exit code %ERRORLEVEL%
    pause
    goto :FAILURE
)

echo [7/12] Shutting down local MLflow server...
for /f "tokens=5" %%a in ('netstat -aon ^| findstr :5000') do taskkill /f /pid %%a
taskkill /f /fi "WINDOWTITLE eq MLflow_Local_Server"

echo [8/12] Stopping existing Docker containers...
call docker-compose down -v

echo [9/12] Rebuilding and launching Docker containers...
call docker-compose up --build -d

echo [10/12] Wiping training configurations and restoring original DVC state...
if exist .dvc rmdir /S /Q .dvc
if exist .dvc_backup (
    xcopy /E /I /Y .dvc_backup .dvc
    rmdir /S /Q .dvc_backup
)
if exist dvc.lock.backup (
    copy /Y dvc.lock.backup dvc.lock
    del dvc.lock.backup
)

echo [11/12] Wiping training logs and swapping back original MLflow files...
if exist mlartifacts rmdir /S /Q mlartifacts
if exist mlartifacts_backup (
    xcopy /E /I /Y mlartifacts_backup mlartifacts
    rmdir /S /Q mlartifacts_backup
)
if exist mlruns rmdir /S /Q mlruns
if exist mlruns_backup (
    xcopy /E /I /Y mlruns_backup mlruns
    rmdir /S /Q mlruns_backup
)

echo [12/12] Running final local DVC pull sync...
call dvc pull

echo ===================================================
echo Process complete!
echo ===================================================
pause
exit /b 0

:FAILURE
echo ===================================================
echo Script stopped at failure point to preserve state.
echo ===================================================
pause
exit /b 1