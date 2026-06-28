@echo off

:: 1. Check if the virtual environment exists, create it, and install requirements if missing
if not exist venv\Scripts\activate.bat (
    echo Virtual environment not found. Creating "venv"...
    python -m venv venv
    
    echo Activating virtual environment...
    call venv\Scripts\activate.bat
    
    echo Installing dependencies from requirements.txt...
    if exist requirements.txt (
        pip install -r requirements.txt
    ) else (
        echo WARNING: requirements.txt not found. Skipping dependency installation.
    )
) else (
    echo Activating existing virtual environment...
    call venv\Scripts\activate.bat
)

:: 2. Force the user to choose a directory via a native Windows popup
echo Please select the folder containing your train.csv...
for /f "usebackq delims=" %%I in (`python -c "import tkinter as tk; from tkinter import filedialog; root=tk.Tk(); root.withdraw(); print(filedialog.askdirectory())"`) do set "TRAIN_DATA_DIR=%%I"

:: 3. Check if the user canceled the popup window
if "%TRAIN_DATA_DIR%"=="" (
    echo Error: You must select a folder to proceed.
    pause
    exit /b
)

:: 4. Start MLflow in a separate terminal window
echo Starting MLflow server...
start "MLflow Server" cmd /k "call venv\Scripts\activate.bat && mlflow server --host 127.0.0.1 --port 5000"

:: 5. Start Prefect in a separate terminal window
echo Starting Prefect server...
start "Prefect Server" cmd /k "call venv\Scripts\activate.bat && prefect server start"

:: 6. Wait a few seconds to let MLflow and Prefect boot up fully
echo Waiting 30 seconds for services to initialize...
timeout /t 30 /nobreak >nul

:: 7. Set necessary environment variables for the current session
set MLFLOW_TRACKING_URI=http://127.0.0.1:5000
set PREFECT_API_URL=http://127.0.0.1:4200/api

:: 8. Run Uvicorn with the dynamically chosen folder path
echo Starting Uvicorn API...
uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload --reload-dir "%TRAIN_DATA_DIR%" --reload-include "train.csv" --reload-exclude ".train_tracker"