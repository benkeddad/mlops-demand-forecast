-- init.sql
CREATE TABLE train (
    Store INTEGER, DayOfWeek INTEGER, Date DATE, Sales INTEGER, 
    Customers INTEGER, Open INTEGER, Promo INTEGER, 
    StateHoliday VARCHAR(10), SchoolHoliday INTEGER
);

CREATE TABLE test (
    Id SERIAL PRIMARY KEY, Store INTEGER, DayOfWeek INTEGER, 
    Date DATE, Promo INTEGER, StateHoliday VARCHAR(10), 
    SchoolHoliday INTEGER, predicted_sales FLOAT
);

-- Trigger to notify when train table gets new data
CREATE OR REPLACE FUNCTION notify_train_change() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('train_changed', 'update');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER train_alter_trig AFTER INSERT OR UPDATE OR DELETE ON train
FOR EACH STATEMENT EXECUTE FUNCTION notify_train_change();

-- Trigger to notify when test rows are inserted for predictions
CREATE OR REPLACE FUNCTION notify_test_insert() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('test_inserted', NEW.Id::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER test_insert_trig AFTER INSERT ON test
FOR EACH ROW EXECUTE FUNCTION notify_test_insert();