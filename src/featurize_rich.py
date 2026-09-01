"""DVC "featurize_rich" stage: applies build_features_rich() (src/features.py)
to the full historical clean_data.parquet, producing train_features_rich.parquet
- the input src/train_optimal.py trains on, distinct from the lean
train_features.parquet the "featurize" stage (src/features.py's own
__main__ block) produces for src/train.py and serving.

Mirrors that script's own __main__ structure and S3 I/O closely - the only
difference is which build_features* function gets applied and which output
path gets written.
"""
import pandas as pd

from features import build_features_rich, get_storage_options, DATA_STORAGE_ROOT

if __name__ == "__main__":
    print("Running Rich Feature Engineering (RFECV+Optuna path)...")
    input_s3_path = f"{DATA_STORAGE_ROOT}/clean_data.parquet"
    output_s3_path = f"{DATA_STORAGE_ROOT}/train_features_rich.parquet"

    clean_df = pd.read_parquet(input_s3_path, storage_options=get_storage_options())

    processed_df = build_features_rich(clean_df)
    if "Store" not in processed_df.columns:
        raise ValueError(
            "Missing required column 'Store' after rich feature preprocessing. "
            f"Available columns: {sorted(processed_df.columns.tolist())}"
        )

    processed_df["entity_id"] = processed_df["Store"].astype(int)
    processed_df["event_timestamp"] = pd.Timestamp.now()

    processed_df.to_parquet(output_s3_path, index=False, storage_options=get_storage_options())
    print(f"Saved directly to {output_s3_path}")

    # No Feast sync here - Feast serves the lean online feature set used by
    # the fast path; the rich, history-dependent features aren't (and
    # shouldn't be) materialized into Feast's low-latency online store.
