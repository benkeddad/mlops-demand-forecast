@echo off
setlocal enabledelayedexpansion

:: This script lives in scripts\, so move to the repository root.
cd /d "%~dp0.."

echo =======================================================
echo   Rossmann MLOps Non-Destructive Recovery Startup
echo =======================================================
echo.
echo This script will NOT delete:
echo   - PersistentVolumeClaims
echo   - Persistent data
echo   - Terraform state
echo   - Deployments
echo   - Services
echo   - ConfigMaps
echo.
echo Healthy resources will be skipped.
echo Unhealthy deployments will be restarted.
echo Missing resources will be recreated by Terraform.
echo =======================================================
echo.

echo =======================================================
echo   [1/6] Checking K3s
echo =======================================================

wsl -u root systemctl is-active --quiet k3s

if errorlevel 1 (
    echo K3s is not running. Starting K3s...
    wsl -u root systemctl start k3s

    if errorlevel 1 (
        echo ERROR: K3s could not be started.
        pause
        exit /b 1
    )
) else (
    echo K3s is already running. Skipping startup.
)

echo Waiting for Kubernetes API...
set /a WAIT_COUNT=0

:wait_k3s
wsl -u root k3s kubectl get nodes >nul 2>&1

if errorlevel 1 (
    set /a WAIT_COUNT+=1

    if !WAIT_COUNT! GEQ 40 (
        echo.
        echo ERROR: Kubernetes API did not become available after 2 minutes.
        pause
        exit /b 1
    )

    timeout /t 3 /nobreak >nul
    goto wait_k3s
)

echo Kubernetes API is online.

echo.
echo Current cluster node status:
wsl -u root k3s kubectl get nodes

echo =======================================================
echo   [2/6] Preparing Terraform Credentials
echo =======================================================

if not exist "deploy\terraform" (
    echo ERROR: deploy\terraform directory does not exist.
    pause
    exit /b 1
)

wsl -u root cat /etc/rancher/k3s/k3s.yaml > deploy\terraform\k3s.yaml

if errorlevel 1 (
    echo ERROR: Failed to copy the K3s kubeconfig.
    pause
    exit /b 1
)

echo Terraform kubeconfig is ready.

echo =======================================================
echo   [3/6] Checking Terraform
echo =======================================================

wsl -u root bash -c "bash $(wslpath '%CD%')/scripts/install_terraform.sh"

if errorlevel 1 (
    echo ERROR: Terraform install/check failed.
    pause
    exit /b 1
)

wsl -u root bash -c "cd $(wslpath '%CD%')/deploy/terraform && terraform init"

if errorlevel 1 (
    echo ERROR: terraform init failed.
    pause
    exit /b 1
)

echo Terraform is initialized.

echo =======================================================
echo   [4/6] Checking Required Kubernetes Resources
echo =======================================================

set "NEED_TERRAFORM_APPLY=0"

echo Checking ConfigMap postgres-init-config...
wsl -u root k3s kubectl get configmap postgres-init-config >nul 2>&1

if errorlevel 1 (
    echo MISSING: configmap/postgres-init-config
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: configmap/postgres-init-config
)

echo Checking PersistentVolumeClaim postgres-data-pvc...
wsl -u root k3s kubectl get pvc postgres-data-pvc >nul 2>&1

if errorlevel 1 (
    echo MISSING: pvc/postgres-data-pvc
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: pvc/postgres-data-pvc
)

echo Checking PersistentVolumeClaim mlflow-data-pvc...
wsl -u root k3s kubectl get pvc mlflow-data-pvc >nul 2>&1

if errorlevel 1 (
    echo MISSING: pvc/mlflow-data-pvc
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: pvc/mlflow-data-pvc
)

echo Checking PersistentVolumeClaim prefect-data-pvc...
wsl -u root k3s kubectl get pvc prefect-data-pvc >nul 2>&1

if errorlevel 1 (
    echo MISSING: pvc/prefect-data-pvc
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: pvc/prefect-data-pvc
)

echo Checking Service postgres...
wsl -u root k3s kubectl get service postgres >nul 2>&1

if errorlevel 1 (
    echo MISSING: service/postgres
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: service/postgres
)

echo Checking Service redis...
wsl -u root k3s kubectl get service redis >nul 2>&1

if errorlevel 1 (
    echo MISSING: service/redis
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: service/redis
)

echo Checking Service mlflow...
wsl -u root k3s kubectl get service mlflow >nul 2>&1

if errorlevel 1 (
    echo MISSING: service/mlflow
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: service/mlflow
)

echo Checking Service prefect...
wsl -u root k3s kubectl get service prefect >nul 2>&1

if errorlevel 1 (
    echo MISSING: service/prefect
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: service/prefect
)

echo Checking Service rossmann-api-service...
wsl -u root k3s kubectl get service rossmann-api-service >nul 2>&1

if errorlevel 1 (
    echo MISSING: service/rossmann-api-service
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: service/rossmann-api-service
)

echo Checking Deployment postgres...
wsl -u root k3s kubectl get deployment postgres >nul 2>&1

if errorlevel 1 (
    echo MISSING: deployment/postgres
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: deployment/postgres
)

echo Checking Deployment redis...
wsl -u root k3s kubectl get deployment redis >nul 2>&1

if errorlevel 1 (
    echo MISSING: deployment/redis
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: deployment/redis
)

echo Checking Deployment mlflow...
wsl -u root k3s kubectl get deployment mlflow >nul 2>&1

if errorlevel 1 (
    echo MISSING: deployment/mlflow
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: deployment/mlflow
)

echo Checking Deployment prefect...
wsl -u root k3s kubectl get deployment prefect >nul 2>&1

if errorlevel 1 (
    echo MISSING: deployment/prefect
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: deployment/prefect
)

echo Checking Deployment rossmann-api...
wsl -u root k3s kubectl get deployment rossmann-api >nul 2>&1

if errorlevel 1 (
    echo MISSING: deployment/rossmann-api
    set "NEED_TERRAFORM_APPLY=1"
) else (
    echo OK: deployment/rossmann-api
)

echo.

if "!NEED_TERRAFORM_APPLY!"=="1" (
    echo One or more required resources are missing.
    echo Running Terraform to recreate only missing resources...

    wsl -u root bash -c "cd $(wslpath '%CD%')/deploy/terraform && terraform apply -auto-approve"

    if errorlevel 1 (
        echo ERROR: Terraform could not recreate the missing resources.
        pause
        exit /b 1
    )

    echo Terraform reconciliation completed.
) else (
    echo All required Kubernetes resources exist.
    echo Skipping terraform apply to save startup time.
)

echo =======================================================
echo   [5/6] Checking Deployment Health
echo =======================================================

echo.
echo Checking PostgreSQL deployment...

wsl -u root k3s kubectl rollout status deployment/postgres --timeout=10s >nul 2>&1

if errorlevel 1 (
    echo PostgreSQL is not healthy. Restarting deployment/postgres...

    wsl -u root k3s kubectl rollout restart deployment/postgres

    if errorlevel 1 (
        echo ERROR: PostgreSQL restart command failed.
        pause
        exit /b 1
    )

    wsl -u root k3s kubectl rollout status deployment/postgres --timeout=180s

    if errorlevel 1 (
        echo ERROR: PostgreSQL did not become ready after restart.
        echo.
        wsl -u root k3s kubectl get pods
        pause
        exit /b 1
    )
) else (
    echo PostgreSQL is healthy. Skipping restart.
)

echo.
echo Checking Redis deployment...

wsl -u root k3s kubectl rollout status deployment/redis --timeout=10s >nul 2>&1

if errorlevel 1 (
    echo Redis is not healthy. Restarting deployment/redis...

    wsl -u root k3s kubectl rollout restart deployment/redis

    if errorlevel 1 (
        echo ERROR: Redis restart command failed.
        pause
        exit /b 1
    )

    wsl -u root k3s kubectl rollout status deployment/redis --timeout=180s

    if errorlevel 1 (
        echo ERROR: Redis did not become ready after restart.
        echo.
        wsl -u root k3s kubectl get pods
        pause
        exit /b 1
    )
) else (
    echo Redis is healthy. Skipping restart.
)

echo.
echo Checking MLflow deployment...

wsl -u root k3s kubectl rollout status deployment/mlflow --timeout=10s >nul 2>&1

if errorlevel 1 (
    echo MLflow is not healthy. Restarting deployment/mlflow...

    wsl -u root k3s kubectl rollout restart deployment/mlflow

    if errorlevel 1 (
        echo ERROR: MLflow restart command failed.
        pause
        exit /b 1
    )

    wsl -u root k3s kubectl rollout status deployment/mlflow --timeout=180s

    if errorlevel 1 (
        echo ERROR: MLflow did not become ready after restart.
        echo.
        wsl -u root k3s kubectl get pods
        pause
        exit /b 1
    )
) else (
    echo MLflow is healthy. Skipping restart.
)

echo.
echo Checking Prefect deployment...

wsl -u root k3s kubectl rollout status deployment/prefect --timeout=10s >nul 2>&1

if errorlevel 1 (
    echo Prefect is not healthy. Restarting deployment/prefect...

    wsl -u root k3s kubectl rollout restart deployment/prefect

    if errorlevel 1 (
        echo ERROR: Prefect restart command failed.
        pause
        exit /b 1
    )

    wsl -u root k3s kubectl rollout status deployment/prefect --timeout=180s

    if errorlevel 1 (
        echo ERROR: Prefect did not become ready after restart.
        echo.
        wsl -u root k3s kubectl get pods
        pause
        exit /b 1
    )
) else (
    echo Prefect is healthy. Skipping restart.
)

echo.
echo Checking Rossmann API deployment...

wsl -u root k3s kubectl rollout status deployment/rossmann-api --timeout=10s >nul 2>&1

if errorlevel 1 (
    echo Rossmann API is not healthy. Restarting deployment/rossmann-api...

    wsl -u root k3s kubectl rollout restart deployment/rossmann-api

    if errorlevel 1 (
        echo ERROR: Rossmann API restart command failed.
        pause
        exit /b 1
    )

    wsl -u root k3s kubectl rollout status deployment/rossmann-api --timeout=300s

    if errorlevel 1 (
        echo ERROR: Rossmann API did not become ready after restart.
        echo.
        wsl -u root k3s kubectl get pods
        pause
        exit /b 1
    )
) else (
    echo Rossmann API is healthy. Skipping restart.
)

echo.
echo All deployments are available.

echo =======================================================
echo   [6/6] Launching Interfaces and Live Logs
echo =======================================================

echo.
wsl -u root k3s kubectl get deployments
echo.
wsl -u root k3s kubectl get pods
echo.
wsl -u root k3s kubectl get pvc
echo.

start "Rossmann FastAPI App Console" wsl -u root bash -c "(while true; do k3s kubectl port-forward --address 0.0.0.0 svc/rossmann-api-service 8000:8000 >/dev/null 2>&1; sleep 3; done) & while true; do k3s kubectl logs -f deployment/rossmann-api; sleep 2; done"

start "MLflow Tracking Console" wsl -u root bash -c "(while true; do k3s kubectl port-forward --address 0.0.0.0 svc/mlflow 5000:5000 >/dev/null 2>&1; sleep 3; done) & while true; do k3s kubectl logs -f deployment/mlflow; sleep 2; done"

start "Prefect Orchestration Console" wsl -u root bash -c "(while true; do k3s kubectl port-forward --address 0.0.0.0 svc/prefect 4200:4200 >/dev/null 2>&1; sleep 3; done) & while true; do k3s kubectl logs -f deployment/prefect; sleep 2; done"

start "PostgreSQL Database Console" wsl -u root bash -c "(while true; do k3s kubectl port-forward --address 0.0.0.0 svc/postgres 5432:5432 >/dev/null 2>&1; sleep 3; done) & while true; do k3s kubectl logs -f deployment/postgres; sleep 2; done"

echo.
echo =======================================================
echo   Recovery Startup Complete
echo =======================================================
echo   No persistent data was deleted.
echo   Healthy deployments were not restarted.
echo.
echo   API Dashboard:    http://localhost:8000
echo   MLflow Dashboard: http://localhost:5000
echo   Prefect Portal:   http://localhost:4200
echo   Database Access:  localhost:5432
echo =======================================================

pause
exit /b 0