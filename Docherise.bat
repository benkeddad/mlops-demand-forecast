@echo off
echo [1/4] Initializing DVC locally...
dvc init --no-scm

echo [2/4] Pulling latest data from DVC remote...
dvc pull

echo [3/4] Stopping existing Docker containers...
docker-compose down

echo [4/4] Rebuilding and launching Docker containers...
docker-compose up --build -d

echo ===================================================
echo Local DVC sync and Docker stack deployment complete!
echo ===================================================
pause