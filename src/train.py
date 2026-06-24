import pandas as pd
import mlflow
import mlflow.xgboost

# 1. Only import what is needed for the ML phase
from src.data import split_data
from src.model import get_model
from src.evaluate import calculate_rmspe

def run_training(processed_data_path: str):
    print(f"Loading processed features from {processed_data_path}...")
    
    # 2. Load the data that features.py already prepared and saved
    processed_df = pd.read_csv(processed_data_path)
    
    # 3. Split Data
    X_train, X_val, y_train, y_val = split_data(processed_df, target_col='Sales')
    
    # 4. Initialize MLflow
    mlflow.set_experiment("Rossmann_Sales_Forecasting")
    
    with mlflow.start_run():
        # 5. Train Model
        model = get_model(n_estimators=150, max_depth=8)
        model.fit(X_train, y_train)
        
        # 6. Evaluate
        predictions = model.predict(X_val)
        rmspe_score = calculate_rmspe(y_val.values, predictions)
        
        # 7. Log to MLflow
        mlflow.log_param("model_type", "XGBRegressor")
        mlflow.log_param("n_estimators", 150)
        mlflow.log_param("max_depth", 8)
        mlflow.log_metric("val_rmspe", rmspe_score)
        
        # Log the model artifact
        mlflow.xgboost.log_model(model, "xgboost_model")
        
        print(f"Training completed successfully. RMSPE: {rmspe_score:.4f}")

if __name__ == "__main__":
    # DVC will make sure this file exists before running.
    run_training("data/processed/train_features.csv")