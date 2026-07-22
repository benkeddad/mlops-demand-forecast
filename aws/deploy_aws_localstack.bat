@echo off
setlocal enabledelayedexpansion
title Rossmann - AWS (LocalStack) Deploy

echo =========================================================
echo  Rossmann Demand Forecast - AWS/LocalStack Deploy
echo  Run this from the repository root.
echo =========================================================
echo.

REM ============================================================
REM STEP 0: Sanity check we're being run from the repo root
REM ============================================================
wsl bash -c "test -d deploy/terraform-aws"
if %errorlevel% neq 0 (
    echo ERROR: deploy\terraform-aws not found from the current directory.
    echo Run this script from the repository root: scripts\deploy_aws_localstack.bat
    exit /b 1
)

REM ============================================================
REM STEP 1: Confirm LocalStack is actually reachable before we
REM waste time on a terraform apply that will just hang.
REM ============================================================
echo [STEP 1] Checking LocalStack is running on 127.0.0.1:4566 ...
curl -s -o nul -w "%%{http_code}" http://localhost:4566/_localstack/health > "%TEMP%\ls_health.txt" 2>nul
set /p LS_HEALTH=<"%TEMP%\ls_health.txt"
if not "!LS_HEALTH!"=="200" (
    echo ERROR: LocalStack does not appear to be running at http://localhost:4566
    echo Open LocalStack Desktop and confirm the instance status is green, then re-run this script.
    exit /b 1
)
echo   LocalStack is up.
echo.

REM ============================================================
REM STEP 2: Make sure the AWS CLI exists inside WSL2 (idempotent,
REM same "check then install" pattern as scripts\install_terraform.sh)
REM ============================================================
echo [STEP 2] Checking for the AWS CLI in WSL2 ...
wsl bash -c "command -v aws >/dev/null 2>&1"
if %errorlevel% neq 0 (
    echo   Not found - installing via pip...
    wsl bash -c "pip3 install --break-system-packages awscli >/dev/null 2>&1 || pip3 install awscli"
    wsl bash -c "command -v aws >/dev/null 2>&1"
    if %errorlevel% neq 0 (
        echo ERROR: Could not install the AWS CLI. Install it manually inside WSL2 and re-run.
        exit /b 1
    )
)
echo   AWS CLI OK.
echo.

REM ============================================================
REM STEP 3: terraform init + apply against the AWS/LocalStack module
REM (reuses the terraform binary already installed for the K3s path)
REM ============================================================
echo [STEP 3] Running terraform init/apply in deploy\terraform-aws ...
wsl bash -c "cd deploy/terraform-aws && terraform init -input=false && terraform apply -auto-approve"
if %errorlevel% neq 0 (
    echo ERROR: terraform apply failed. Check the output above.
    exit /b 1
)
echo   Infrastructure applied: S3, RDS, ECR, ECS cluster/services, Secrets Manager, Cloud Map.
echo.

REM ============================================================
REM STEP 4: Capture the terraform outputs the rest of this script needs
REM ============================================================
echo [STEP 4] Reading terraform outputs ...
for /f "delims=" %%i in ('wsl bash -c "cd deploy/terraform-aws && terraform output -raw rds_endpoint"') do set RDS_ENDPOINT=%%i
for /f "delims=" %%i in ('wsl bash -c "cd deploy/terraform-aws && terraform output -raw api_ecr_repository_url"') do set API_REPO=%%i
for /f "delims=" %%i in ('wsl bash -c "cd deploy/terraform-aws && terraform output -raw mlflow_ecr_repository_url"') do set MLFLOW_REPO=%%i
for /f "delims=" %%i in ('wsl bash -c "cd deploy/terraform-aws && terraform output -raw prefect_ecr_repository_url"') do set PREFECT_REPO=%%i
for /f "delims=" %%i in ('wsl bash -c "cd deploy/terraform-aws && terraform output -raw mlflow_artifacts_bucket"') do set MLFLOW_BUCKET=%%i

if "!RDS_ENDPOINT!"=="" (
    echo ERROR: Could not read the rds_endpoint output. Did terraform apply succeed?
    exit /b 1
)
echo   RDS endpoint:  !RDS_ENDPOINT!
echo   API repo:      !API_REPO!
echo   MLflow repo:   !MLFLOW_REPO!
echo   Prefect repo:  !PREFECT_REPO!
echo.

REM Registry hostname = everything before the first "/" in the repo URL.
REM (Not a fixed-offset substring - "rossmann-api" and "rossmann-prefect"
REM  are different lengths, so a fixed cut would break on some repos.)
for /f "tokens=1 delims=/" %%a in ("!API_REPO!") do set ECR_HOST=%%a

REM ============================================================
REM STEP 5: Patch feature_store.yaml with the real RDS endpoint
REM (one script, one shell boundary - see patch_feature_store_aws.py
REM  for why this isn't inlined through batch -> bash -> python)
REM ============================================================
echo [STEP 5] Patching feature_repo\feature_store.yaml for AWS ...
wsl bash -c "python3 scripts/patch_feature_store_aws.py '!RDS_ENDPOINT!'"
if %errorlevel% neq 0 (
    echo ERROR: Failed to patch feature_store.yaml.
    exit /b 1
)
echo.

REM ============================================================
REM STEP 6: Make sure requirements.txt has the feast[aws] extra
REM ============================================================
echo [STEP 6] Checking requirements.txt has feast[aws] ...
wsl bash -c "grep -q 'feast\[.*aws.*\]' requirements.txt || sed -i 's/feast\[postgres,redis\]/feast[postgres,redis,aws]/' requirements.txt"
echo   OK.
echo.

REM ============================================================
REM STEP 7: ECR login
REM ============================================================
echo [STEP 7] Logging in to local ECR (!ECR_HOST!) ...
wsl bash -c "aws --endpoint-url=http://localhost:4566 ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin !ECR_HOST!"
echo.

REM ============================================================
REM STEP 8: Build + tag + push all three images
REM (feature_store.yaml is now baked into the api image, since
REM docker/api.Dockerfile COPYs feature_repo/ at build time)
REM ============================================================
echo [STEP 8] Building and pushing images ...

echo   -- api --
wsl bash -c "docker build -t rossmann-api -f docker/api.Dockerfile . && docker tag rossmann-api !API_REPO!:latest && docker push !API_REPO!:latest"
if %errorlevel% neq 0 (echo ERROR: api image build/push failed. & exit /b 1)

echo   -- mlflow --
wsl bash -c "docker build -t rossmann-mlflow -f docker/mlflow.Dockerfile . && docker tag rossmann-mlflow !MLFLOW_REPO!:latest && docker push !MLFLOW_REPO!:latest"
if %errorlevel% neq 0 (echo ERROR: mlflow image build/push failed. & exit /b 1)

echo   -- prefect --
wsl bash -c "docker build -t rossmann-prefect -f docker/prefect.Dockerfile . && docker tag rossmann-prefect !PREFECT_REPO!:latest && docker push !PREFECT_REPO!:latest"
if %errorlevel% neq 0 (echo ERROR: prefect image build/push failed. & exit /b 1)

echo   All three images pushed.
echo.

REM ============================================================
REM STEP 9: Force ECS to redeploy with the freshly pushed images
REM (the services were created by `terraform apply` in Step 3,
REM but before any image existed for them to run)
REM ============================================================
echo [STEP 9] Forcing ECS services to pick up the new images ...
wsl bash -c "aws --endpoint-url=http://localhost:4566 ecs update-service --cluster rossmann-cluster --service mlflow --force-new-deployment --region us-east-1 >/dev/null"
wsl bash -c "aws --endpoint-url=http://localhost:4566 ecs update-service --cluster rossmann-cluster --service prefect --force-new-deployment --region us-east-1 >/dev/null"
wsl bash -c "aws --endpoint-url=http://localhost:4566 ecs update-service --cluster rossmann-cluster --service api --force-new-deployment --region us-east-1 >/dev/null"
echo   Redeploy triggered for mlflow, prefect, api.
echo.

echo =========================================================
echo  Done. MLflow artifacts bucket: !MLFLOW_BUCKET!
echo.
echo  Tail logs with, e.g.:
echo    wsl awslocal logs tail /ecs/rossmann-api --follow
echo    wsl awslocal logs tail /ecs/rossmann-mlflow --follow
echo    wsl awslocal logs tail /ecs/rossmann-prefect --follow
echo =========================================================

endlocal
