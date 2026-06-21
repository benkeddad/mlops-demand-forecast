import pandas as pd

def build_features(df: pd.DataFrame) -> pd.DataFrame:
    """Extracts date features and handles missing values."""
    df_processed = df.copy()
    
    # Date feature engineering
    if 'Date' in df_processed.columns:
        df_processed['Date'] = pd.to_datetime(df_processed['Date'])
        df_processed['Year'] = df_processed['Date'].dt.year
        df_processed['Month'] = df_processed['Date'].dt.month
        df_processed['Day'] = df_processed['Date'].dt.day
        df_processed['DayOfWeek'] = df_processed['Date'].dt.dayofweek
        df_processed = df_processed.drop(columns=['Date'])
        
    # Handle missing values (e.g., Open, Promo, StateHoliday)
    df_processed.fillna(0, inplace=True)
    
    # Convert categorical to numeric if necessary
    df_processed = pd.get_dummies(df_processed, drop_first=True)
    
    return df_processed