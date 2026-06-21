import pandas as pd
from sklearn.model_selection import train_test_split

def load_data(file_path: str) -> pd.DataFrame:
    """Loads raw data from an Excel or CSV file."""
    if file_path.endswith('.xlsx'):
        df = pd.read_excel(file_path)
    else:
        df = pd.read_csv(file_path)
    return df

def split_data(df: pd.DataFrame, target_col: str = 'Sales', test_size: float = 0.2):
    """Splits data temporally or randomly into train and validation sets."""
    # Assuming chronological order for time-series; shuffle=False is critical
    X = df.drop(columns=[target_col])
    y = df[target_col]
    
    X_train, X_val, y_train, y_val = train_test_split(
        X, y, test_size=test_size, shuffle=False
    )
    return X_train, X_val, y_train, y_val