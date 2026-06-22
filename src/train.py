import mlflow
import mlflow.xgboost
from src.data import load_data, split_data
from src.features import build_features
from src.model import get_model
from src.evaluate import calculate_rmspe

def run_training(data_path: str):
    # 1. Prepare Data
    raw_df = load_data(data_path)
    processed_df = build_features(raw_df)
    
    # 2. Split Data
    X_train, X_val, y_train, y_val = split_data(processed_df, target_col='Sales')
    
    # 3. Initialize MLflow
    mlflow.set_experiment("Rossmann_Sales_Forecasting")
    
    with mlflow.start_run():
        # 4. Train Model
        model = get_model(n_estimators=150, max_depth=8)
        model.fit(X_train, y_train)
        
        # 5. Evaluate
        predictions = model.predict(X_val)
        rmspe_score = calculate_rmspe(y_val.values, predictions)
        
        # 6. Log to MLflow
        mlflow.log_param("model_type", "XGBRegressor")
        mlflow.log_param("n_estimators", 150)
        mlflow.log_param("max_depth", 8)
        mlflow.log_metric("val_rmspe", rmspe_score)
        
        # Log the model artifact
        mlflow.xgboost.log_model(model, "xgboost_model")
        
        print(f"Training completed successfully. RMSPE: {rmspe_score:.4f}")

if __name__ == "__main__":
    # Point this to your actual raw file name
    run_training("data/raw/train.csv")