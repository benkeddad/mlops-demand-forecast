import os
import sys

# Insert the project root directory into Python's search path
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src.train import run_training

def main():
    print("Starting ML Pipeline...")
    data_file = "data/raw/train.csv"
    
    if not os.path.exists(data_file):
        raise FileNotFoundError(f"Data file not found at {data_file}. Please copy train.csv here.")
        
    run_training(data_file)
    print("Pipeline executed successfully.")

if __name__ == "__main__":
    main()