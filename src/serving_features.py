"""Computes prediction-time features for the `test` table's rows, matching
whatever feature schema the *currently loaded* model actually expects -
lean (src/train.py, build_features()) or rich (src/train_optimal.py,
build_features_rich()) - by reading the loaded model's own MLflow-logged
input signature, not a hardcoded assumption about which training path
produced it. A model trained with any RFECV-selected subset of either
feature set works here without new code: whatever columns its signature
names are what gets computed and returned, in that order.

Shared by app/main.py's perform_batch_prediction() (the live, event-driven
path fired by the test_inserted Postgres trigger) and
src/predict_initial.py (the one-shot catch-up run at container boot) - the
same "single implementation, two call sites" pattern those two already use
for build_features() itself.
"""
from typing import Iterable, Optional

import pandas as pd

from features import build_features, build_features_rich, RICH_HISTORY_DEPENDENT_PREFIXES

# Longest lookback any rich feature needs (SalesLag28 / a 28-day rolling
# window) plus a safety margin for weekends/gaps in a store's own calendar -
# bounds the historical query instead of ever pulling the full
# multi-million-row train table for one prediction batch.
HISTORY_LOOKBACK_DAYS = 40


def needs_sales_history(model_input_columns: Iterable[str]) -> bool:
    """True if any of the model's expected input columns can only be
    computed from a store's own past Sales (see
    RICH_HISTORY_DEPENDENT_PREFIXES in src/features.py) - i.e. whether a
    historical lookback query is needed at all before predicting this
    batch. A lean (src/train.py) model's signature never trips this."""
    return any(col.startswith(RICH_HISTORY_DEPENDENT_PREFIXES) for col in model_input_columns)


def compute_prediction_features(
    new_rows_df: pd.DataFrame,
    model_input_columns: Iterable[str],
    history_df: Optional[pd.DataFrame] = None,
) -> pd.DataFrame:
    """
    new_rows_df: the batch of rows needing a prediction, already
        canonical-cased (Store, DayOfWeek, Date, Promo, StateHoliday,
        SchoolHoliday, ...) - no Sales column, that's what's being predicted.
    model_input_columns: model.metadata.get_input_schema().input_names()
        from the currently-loaded pyfunc model - determines both which
        feature function to run and which columns (and order) to return.
    history_df: only required when needs_sales_history(model_input_columns)
        is True - real historical (Store, Date, Sales) rows for the stores
        present in new_rows_df, covering at least HISTORY_LOOKBACK_DAYS
        before new_rows_df's earliest date. Ignored otherwise.

    Returns a DataFrame with exactly model_input_columns, in that order,
    ready for model.predict(). Raises ValueError if the model needs history
    but none was given, or if a computed frame is still missing a column
    the model's signature requires (a real mismatch, not something to
    silently paper over with a default).
    """
    model_input_columns = list(model_input_columns)

    if needs_sales_history(model_input_columns):
        if history_df is None or history_df.empty:
            raise ValueError(
                "This model's signature requires Sales-history features "
                f"({model_input_columns}), but no history_df was provided."
            )
        key_cols = [c for c in ("Store", "Date") if c in new_rows_df.columns]
        combined = pd.concat([history_df, new_rows_df], ignore_index=True, sort=False)
        processed = build_features_rich(combined)
        # Isolate the new rows by (Store, Date), not by "Sales is NaN" - a
        # real historical day can legitimately have zero (but known) sales,
        # and build_features_rich() deliberately leaves Sales unfilled so
        # "unknown" and "zero" stay distinguishable (see its docstring).
        result = processed.merge(new_rows_df[key_cols], on=key_cols, how="inner")
    else:
        result = build_features(new_rows_df)

    missing = [c for c in model_input_columns if c not in result.columns]
    if missing:
        raise ValueError(
            f"Computed features are missing column(s) the model's signature requires: {missing}. "
            f"Available columns: {sorted(result.columns.tolist())}"
        )

    features_only = result[model_input_columns].copy()
    return features_only.apply(pd.to_numeric, errors="coerce").fillna(0)
