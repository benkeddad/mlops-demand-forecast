import pandas as pd
from evidently.report import Report
from evidently.metric_preset import DataDriftPreset

def generate_drift_report(reference_data_path: str, current_data_path: str, output_path: str):
    """Generates an HTML report comparing reference (train) and current (live) data."""
    # Load datasets
    ref_df = pd.read_csv(reference_data_path)
    curr_df = pd.read_csv(current_data_path)
    
    # Initialize and run Evidently report
    drift_report = Report(metrics=[DataDriftPreset()])
    drift_report.run(reference_data=ref_df, current_data=curr_df)
    
    # Save to HTML
    drift_report.save_html(output_path)
    print(f"Data drift report saved to {output_path}")

if __name__ == "__main__":
    # Placeholder paths; update these when you have live inference logs
    generate_drift_report(
        "data/reference_train_data.csv", 
        "data/live_inference_data.csv", 
        "monitoring/drift_report.html"
    )