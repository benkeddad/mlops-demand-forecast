"""DVC "featurize_rich" stage: applies build_features_rich() (src/features.py)
to the full historical clean_data.parquet, producing train_features_rich.parquet
- the input src/train_optimal.py trains on, distinct from the lean
train_features.parquet the "featurize" stage (src/features.py's own
__main__ block) produces for src/train.py and serving.

Mirrors that script's own __main__ structure and S3 I/O closely - the only
difference is which build_features* function gets applied and which output
path gets written.

Also writes models/rich_feature_diagnostics.json and prints a clear warning
when the data doesn't actually have enough per-store history for the
lag/rolling features to be informative - a silent "technically ran, produced
mostly-zero-filled features" failure mode is far harder to catch than an
explicit one. See features.py's compute_rich_feature_diagnostics() and
RICH_FEATURE_COLD_START_WARNING_THRESHOLD below.
"""
import json
from pathlib import Path

import pandas as pd

from features import build_features_rich, compute_rich_feature_diagnostics, get_storage_options, DATA_STORAGE_ROOT

# If more than this fraction of rows are "cold start" (among a store's
# first 28 chronological rows, so SalesLag28/SalesRollingMean28/etc. are
# necessarily the fillna(0) default rather than a real value), the
# history-dependent features can't be doing much useful work regardless of
# how correct the code computing them is - not enough history exists.
RICH_FEATURE_COLD_START_WARNING_THRESHOLD = 0.10

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

    diagnostics = compute_rich_feature_diagnostics(processed_df)
    Path("models").mkdir(exist_ok=True)
    Path("models/rich_feature_diagnostics.json").write_text(json.dumps(diagnostics, indent=2), encoding="utf-8")
    print(f"Rich feature diagnostics: {diagnostics}")
    cold_start_fraction = diagnostics.get("cold_start_fraction_lag28", 0.0)
    if cold_start_fraction > RICH_FEATURE_COLD_START_WARNING_THRESHOLD:
        print(
            f"[WARNING] {cold_start_fraction:.1%} of rows are 'cold start' for the "
            f"28-day lag/rolling features (< {RICH_FEATURE_COLD_START_WARNING_THRESHOLD:.0%} "
            "expected) - meaning that many rows get the fillna(0) default rather than a "
            "real historical value. This directly limits how much the history-dependent "
            "features can help, independent of whether the code computing them is correct. "
            "Usually means the loaded train table doesn't span enough continuous days per "
            "store yet - check rows_per_store_min/median above."
        )

    processed_df["entity_id"] = processed_df["Store"].astype(int)
    processed_df["event_timestamp"] = pd.Timestamp.now()

    processed_df.to_parquet(output_s3_path, index=False, storage_options=get_storage_options())
    print(f"Saved directly to {output_s3_path}")

    # No Feast sync here - Feast serves the lean online feature set used by
    # the fast path; the rich, history-dependent features aren't (and
    # shouldn't be) materialized into Feast's low-latency online store.
