import psycopg2
from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT
import os
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("db_bootstrap")

def bootstrap_databases():
    # Connect to system 'postgres' database to check/create others
    conn = psycopg2.connect(
        host=os.getenv("DB_HOST", "postgres"),
        port=os.getenv("DB_PORT", "5432"),
        user=os.getenv("DB_USER", "user"),
        password=os.getenv("DB_PASSWORD", "Password"),
        database="postgres"
    )
    conn.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)
    cur = conn.cursor()
    
    # Define all required databases for the stack
    databases_to_ensure = ["mlflow", "prefect", "feast", "rossmann"]
    
    for db in databases_to_ensure:
        cur.execute("SELECT 1 FROM pg_catalog.pg_database WHERE datname = %s;", (db,))
        exists = cur.fetchone()
        if not exists:
            logger.info(f"Database '{db}' does not exist. Creating...")
            cur.execute(f'CREATE DATABASE "{db}";')
        else:
            logger.info(f"Database '{db}' already exists.")
            
    cur.close()
    conn.close()

if __name__ == "__main__":
    bootstrap_databases()