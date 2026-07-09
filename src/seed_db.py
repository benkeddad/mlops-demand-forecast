# Add io and create_engine imports to the top of app/main.py
import io
from sqlalchemy import create_engine
from fastapi import UploadFile, File

@app.post("/upload", summary="Upload new training data directly to the database")
async def upload_new_data(file: UploadFile = File(...)):
    try:
        # Read the incoming file directly into memory
        contents = await file.read()
        df = pd.read_csv(io.BytesIO(contents))
        
        # Connect to the database
        engine = create_engine(DB_URL)
        
        # Append the new records to your train table
        # This insertion automatically fires your 'train_changed' database trigger
        df.to_sql("train", engine, if_exists="append", index=False)
        
        return {
            "status": "Success", 
            "message": f"Inserted {len(df)} rows into the train table. Training pipeline triggered."
        }
    except Exception as exc:
        return {"status": "Error", "detail": str(exc)}