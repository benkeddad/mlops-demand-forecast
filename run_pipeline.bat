@echo off
setlocal enabledelayedexpansion

:: ==========================================================
:: 1/3: Running Data Pipeline via DVC...
:: ==========================================================
call venv\Scripts\activate

echo Installing/Updating dependencies...
pip install --upgrade -r requirements.txt
if %errorlevel% neq 0 (
    echo [ERROR] Failed to install requirements.
    pause
    exit /b %errorlevel%
)

echo Running DVC pipeline...
dvc repro
if %errorlevel% neq 0 (
    echo [ERROR] DVC pipeline failed. Deployment aborted.
    pause
    exit /b %errorlevel%
)

:: ==========================================================
:: 2/3: Automating .env configuration for Docker...
:: ==========================================================
echo Detecting latest MLflow model...
powershell -Command "$latest = Get-ChildItem -Path 'mlruns' -Recurse -Filter 'MLmodel' | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($latest) { $relPath = $latest.DirectoryName.Replace($pwd.Path, '').Replace('\', '/'); 'MODEL_URI=/code' + $relPath | Out-File -FilePath '.env' -Encoding ascii } else { Write-Error 'No MLmodel found.'; exit 1 }"

if %errorlevel% neq 0 (
    echo [ERROR] Could not generate .env file.
    pause
    exit /b %errorlevel%
)

:: ==========================================================
:: 3/3: Deploying FastAPI and MLflow via Docker...
:: ==========================================================
echo Rebuilding and deploying containers...
docker-compose down
docker-compose up -d --build

if %errorlevel% neq 0 (
    echo [ERROR] Docker deployment failed.
    pause
    exit /b %errorlevel%
)

echo ==========================================================
echo  SUCCESS: Your API is live and serving the latest model!
echo ==========================================================
pause