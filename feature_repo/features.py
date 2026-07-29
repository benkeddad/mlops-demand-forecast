from datetime import timedelta
from feast import Entity, FeatureView, Field
from feast.types import Int64, String
from feast.infra.offline_stores.contrib.postgres_offline_store.postgres_source import PostgreSQLSource

# 1. Define the entity identifier used in main.py's get_online_features call
store_entity = Entity(
    name="entity_id", 
    join_keys=["entity_id"]
)

# 2. Extract raw data and compute sub-date features matching your model's inputs
rossmann_source = PostgreSQLSource(
    name="rossmann_train_source",
    query="""
        SELECT 
            store AS entity_id,
            store AS "Store",
            dayofweek AS "DayOfWeek",
            promo AS "Promo",
            stateholiday AS "StateHoliday",
            schoolholiday AS "SchoolHoliday",
            EXTRACT(YEAR FROM date)::INTEGER AS "Year",
            EXTRACT(MONTH FROM date)::INTEGER AS "Month",
            EXTRACT(DAY FROM date)::INTEGER AS "Day",
            date AS event_timestamp
        FROM train
    """,
    timestamp_field="event_timestamp",
)

# 3. Create the feature view requested by the FastAPI prediction block
rossmann_features_view = FeatureView(
    name="rossmann_features",
    entities=[store_entity],
    ttl=timedelta(days=3650),
    schema=[
        Field(name="Store", dtype=Int64),
        Field(name="DayOfWeek", dtype=Int64),
        Field(name="Promo", dtype=Int64),
        Field(name="StateHoliday", dtype=String),
        Field(name="SchoolHoliday", dtype=Int64),
        Field(name="Year", dtype=Int64),
        Field(name="Month", dtype=Int64),
        Field(name="Day", dtype=Int64),
    ],
    source=rossmann_source,
)