import pandas as pd
import mlflow
import mlflow.xgboost
import os
from data import split_data
from model import get_model
from evaluate import calculate_rmspe

_mlflow_uri = os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000")
mlflow.set_tracking_uri(_mlflow_uri)
mlflow.set_registry_uri(_mlflow_uri)

REGISTERED_MODEL_NAME = "Rossmann_XGBoost_Model"

def run_training(processed_data_path: str):
    print(f"Loading processed features from {processed_data_path}...")
    processed_df = pd.read_parquet(processed_data_path)

    X_train, X_val, y_train, y_val = split_data(processed_df, target_col='Sales')
    # NEW: renamed from "Rossmann_Sales_Forecasting" when the MLflow server's
    # --default-artifact-root moved to S3. MLflow records each experiment's
    # artifact_location at creation time and never changes it afterwards, so
    # the old experiment would keep writing to its original local PVC path
    # forever even after the server-wide default changed. A fresh experiment
    # name is required to actually pick up the new S3-backed root; the old
    # experiment (and its run/model history) is untouched and still browsable.
    mlflow.set_experiment("Rossmann_Sales_Forecasting_v2")

    with mlflow.start_run():
        # Store metadata reference to the exact parquet data used for training
        dataset = mlflow.data.from_pandas(processed_df, source=processed_data_path)
        mlflow.log_input(dataset, context="training")

        model = get_model(n_estimators=150, max_depth=8)
        model.fit(X_train, y_train)

        predictions = model.predict(X_val)
        rmspe_score = calculate_rmspe(y_val.values, predictions)

        mlflow.log_param("model_type", "XGBRegressor")
        mlflow.log_param("n_estimators", 150)
        mlflow.log_param("max_depth", 8)
        mlflow.log_metric("val_rmspe", rmspe_score)

        mlflow.xgboost.log_model(
            xgb_model=model,
            artifact_path="xgboost_model",
            registered_model_name=REGISTERED_MODEL_NAME
        )
        print(f"Training completed. RMSPE: {rmspe_score:.4f}")

if __name__ == "__main__":
    run_training("data/processed/train_features.parquet")