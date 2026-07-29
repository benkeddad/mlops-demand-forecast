# CHANGED: Create custom image to install asyncpg driver on top of official Prefect base
FROM prefecthq/prefect:2.14-python3.10
RUN pip install --no-cache-dir asyncpg
# END OF CHANGE