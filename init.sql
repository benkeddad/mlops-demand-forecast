-- ============================================================
-- 1. CLEANUP OLD STRUCTURES
-- ============================================================
DROP TRIGGER IF EXISTS test_insert_trig ON test CASCADE;
DROP FUNCTION IF EXISTS notify_test_insert() CASCADE;

DROP TRIGGER IF EXISTS train_changed_trigger ON train CASCADE;
DROP FUNCTION IF EXISTS notify_train_changed() CASCADE;

DROP TABLE IF EXISTS test CASCADE;
DROP TABLE IF EXISTS train CASCADE;

-- ============================================================
-- 2. TRIGGER FUNCTIONS
-- ============================================================
-- Trigger function for the test table inserts
CREATE OR REPLACE FUNCTION notify_test_insert()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('test_inserted', 'new_data');
    RETURN NEW; -- Row-level triggers return NEW
END;
$$ LANGUAGE plpgsql;

-- Trigger function for the train table updates
CREATE OR REPLACE FUNCTION notify_train_changed()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('train_changed', 'new_training_data');
    RETURN NULL; -- Statement-level triggers return NULL
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 3. TABLE CREATION & TRIGGER BINDINGS
-- ============================================================
-- Create the training dataset table
CREATE TABLE train (
    id SERIAL PRIMARY KEY,
    store INT NOT NULL,
    dayofweek INT,
    sales INT,
    customers INT,
    open INT,
    promo INT,
    stateholiday VARCHAR(10),
    schoolholiday INT,
    year INT,
    month INT,
    day INT
);

-- Bind trigger to the train table
CREATE TRIGGER train_changed_trigger
AFTER INSERT ON train
FOR EACH STATEMENT
EXECUTE FUNCTION notify_train_changed();

-- Recreate the test table exactly as verified
CREATE TABLE test (
    Id SERIAL PRIMARY KEY, 
    Store INTEGER, 
    DayOfWeek INTEGER, 
    Date DATE, 
    Open INTEGER,            -- Included column
    Promo INTEGER, 
    StateHoliday VARCHAR(10), 
    SchoolHoliday INTEGER, 
    predicted_sales FLOAT
);

-- Reattach the row-level trigger for FastAPI exactly as verified
CREATE TRIGGER test_insert_trig 
AFTER INSERT ON test
FOR EACH ROW 
EXECUTE FUNCTION notify_test_insert();