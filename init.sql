-- ============================================================
-- 1. CLEANUP OLD STRUCTURES
-- ============================================================
DROP TRIGGER IF EXISTS test_insert_trig ON test CASCADE;
DROP FUNCTION IF EXISTS notify_test_insert() CASCADE;

DROP TRIGGER IF EXISTS train_alter_trig ON train CASCADE;
DROP FUNCTION IF EXISTS notify_train_change() CASCADE;

DROP TABLE IF EXISTS test CASCADE;
DROP TABLE IF EXISTS train CASCADE;

-- ============================================================
-- 2. TABLE CREATION
-- ============================================================
CREATE TABLE train (
    id SERIAL PRIMARY KEY,
    store INTEGER, 
    dayofweek INTEGER, 
    date DATE, 
    sales INTEGER, 
    customers INTEGER, 
    open INTEGER, 
    promo INTEGER, 
    stateholiday VARCHAR(10), 
    schoolholiday INTEGER
);

CREATE TABLE test (
    id SERIAL PRIMARY KEY, 
    store INTEGER, 
    dayofweek INTEGER, 
    date DATE, 
    open INTEGER,
    promo INTEGER, 
    stateholiday VARCHAR(10), 
    schoolholiday INTEGER, 
    predicted_sales FLOAT
);

-- ============================================================
-- 3. TRIGGER FUNCTIONS & BINDINGS
-- ============================================================
CREATE OR REPLACE FUNCTION notify_train_change() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('train_changed', 'update');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER train_alter_trig 
AFTER INSERT OR UPDATE OR DELETE ON train
FOR EACH STATEMENT EXECUTE FUNCTION notify_train_change();

CREATE OR REPLACE FUNCTION notify_test_insert() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('test_inserted', NEW.id::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER test_insert_trig 
AFTER INSERT ON test
FOR EACH ROW EXECUTE FUNCTION notify_test_insert();