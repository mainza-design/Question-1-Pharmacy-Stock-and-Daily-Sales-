# Q1 – Pharmacy Stock and Daily Sales (schema `q1`)

**Purpose:** record medicine sales, prevent overselling, keep stock-change history, and produce daily sales totals.

## Objects
| Part | Object | What it does |
|---|---|---|
| (a) | `medicines`, `sales`, `stock_audit`, `daily_sales` | CHECKs: `unit_price > 0`, `stock_qty >= 0`, `quantity > 0`. 4 medicines, 6 sales loaded via the procedure |
| (b) | `fn_sale_value(id, qty)` | current price × qty; rejects unknown medicine / qty ≤ 0 |
| (c) | `pr_record_sale(id, qty, date)` | locks the row, checks stock, stores current price in the sale, deducts stock once; any error rolls back both tables |
| (d) | `trg_medicines_stock_audit` | AFTER UPDATE row trigger with `WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)` |
| (e) | `v_low_stock` | medicines with stock < 10 |
| (f) | `idx_sales_medicine_sold_on (medicine_id, sold_on)` | equality column first, range column second |
| (g) | `pr_refresh_sales(day)` + job `q1_refresh_sales` | upsert into `daily_sales`; cron `15 0 * * *` for yesterday |

## Run / test
1. Run the Q1 block; check `SELECT * FROM stock_audit;` and `SELECT * FROM v_low_stock;`.
2. An oversell such as `CALL pr_record_sale(3, 9999, CURRENT_DATE);` must fail and leave data unchanged.
3. Call `pr_refresh_sales` twice for the same day; totals stay the same.
