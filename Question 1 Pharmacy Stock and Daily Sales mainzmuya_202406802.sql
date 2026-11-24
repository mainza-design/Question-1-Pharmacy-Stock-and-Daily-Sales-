/* #####################################################################
   QUESTION 1 - Pharmacy Stock and Daily Sales
   ##################################################################### */
DROP SCHEMA IF EXISTS q1 CASCADE;
CREATE SCHEMA q1;
SET search_path TO q1, public;

-- (a) Tables ------------------------------------------------------------
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL UNIQUE,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id      SERIAL PRIMARY KEY,
    medicine_id  INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity     INTEGER NOT NULL CHECK (quantity > 0),
    unit_price   NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on      DATE NOT NULL
);

CREATE TABLE stock_audit (
    audit_id     SERIAL PRIMARY KEY,
    medicine_id  INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty      INTEGER NOT NULL,
    new_qty      INTEGER NOT NULL,
    changed_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER       NOT NULL DEFAULT 0,
    total_amount NUMERIC(14,2) NOT NULL DEFAULT 0
);

-- (b) Function ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_price NUMERIC;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;
    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;
    RETURN v_price * p_quantity;
END $$;

-- (c) Procedure ---------------------------------------------------------
-- Any RAISE aborts the CALL, so a failed sale leaves both tables unchanged.
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INTEGER, p_quantity INTEGER, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC(10,2); v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date must not be NULL';
    END IF;

    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;   -- lock row
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: available %, requested %',
                        p_medicine_id, v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);        -- price snapshot

    UPDATE medicines SET stock_qty = stock_qty - p_quantity        -- deducted once
    WHERE medicine_id = p_medicine_id;
END $$;

-- (d) Trigger -----------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_stock_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
    RETURN NULL;   -- AFTER trigger: return value ignored
END $$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_fn_stock_audit();

-- (a) continued: seed data (sales are loaded through the procedure) -------
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
 ('Paracetamol 500mg', 2.50, 100),
 ('Amoxicillin 250mg', 6.00,  50),
 ('Ibuprofen 400mg',   4.00,  30),
 ('Cough Syrup 100ml', 15.00, 12);

CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(2,  5, CURRENT_DATE - 2);
CALL pr_record_sale(3,  8, CURRENT_DATE - 1);
CALL pr_record_sale(1, 20, CURRENT_DATE - 1);
CALL pr_record_sale(4,  3, CURRENT_DATE - 1);
CALL pr_record_sale(4,  2, CURRENT_DATE);

-- Demonstrations
SELECT fn_sale_value(2, 4) AS sale_value;                -- 24.00
SELECT * FROM stock_audit ORDER BY audit_id;
-- Invalid sale (oversell) - raises an error and changes nothing:
-- CALL pr_record_sale(3, 9999, CURRENT_DATE);

-- (e) View --------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

CALL pr_record_sale(4, 1, CURRENT_DATE);                 -- Cough Syrup now 6
SELECT * FROM v_low_stock;

-- (f) Index -------------------------------------------------------------
-- Equality column first (medicine_id), range column second (sold_on): the B-tree
-- jumps to one medicine and scans only the requested date range in order.
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;
SET enable_seqscan = off;     -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT * FROM sales
WHERE medicine_id = 1 AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job -----------------------------------------------------
-- Upsert on the primary key: a rerun REPLACES the totals, never adds to them.
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE) LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day, COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0)
    FROM sales WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty = EXCLUDED.total_qty, total_amount = EXCLUDED.total_amount;
END $$;

SELECT cron.schedule('q1_refresh_sales', '15 0 * * *',
       $$CALL q1.pr_refresh_sales(CURRENT_DATE - 1)$$);

CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);                 -- rerun: same result
SELECT * FROM daily_sales;