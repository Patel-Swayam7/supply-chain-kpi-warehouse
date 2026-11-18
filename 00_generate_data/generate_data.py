"""
Step 0: Generate the simulated supply chain dataset (raw CSVs).

Creates realistic order line and inventory data for a distributor shipping
60 SKUs from 5 distribution centers to 150 customers, Jan 2025 to Jun 2026.

Realism built in on purpose, so the KPIs have something to measure:
  - each warehouse has its own processing speed and reliability
  - some categories stock out more often, causing partial shipments
  - a small share of lines are late, partially shipped, or still open (backlog)
  - inventory levels follow a weekly random walk sized to each SKU's demand

Fixed random seed: everyone who runs this gets the exact same data.

Usage (from the project root):
    python3 00_generate_data/generate_data.py
"""

import csv
import os
import random
from datetime import date, timedelta

SEED = 42
N_ORDER_LINES = 40_000
START = date(2025, 1, 1)
END = date(2026, 6, 30)          # "as of" date: anything not shipped by now is backlog
OUT_DIR = "data"

random.seed(SEED)
os.makedirs(OUT_DIR, exist_ok=True)


def write_csv(name, header, rows):
    path = os.path.join(OUT_DIR, name)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(header)
        w.writerows(rows)
    print(f"  {name:<28} {len(rows):>7,} rows")


# ---------------------------------------------------------------------
# Dimensions
# ---------------------------------------------------------------------
# Warehouses: (key, name, city, state, extra processing days, late-ship probability)
WAREHOUSES = [
    (1, "DC Dallas",      "Dallas",      "TX", 0, 0.04),
    (2, "DC Newark",      "Newark",      "NJ", 1, 0.08),
    (3, "DC Chicago",     "Chicago",     "IL", 0, 0.06),
    (4, "DC Los Angeles", "Los Angeles", "CA", 1, 0.12),
    (5, "DC Atlanta",     "Atlanta",     "GA", 0, 0.05),
]

# Categories: (name, cost range, markup, stockout probability)
CATEGORIES = [
    ("Electrical Components", (4, 40),    1.45, 0.05),
    ("Power Supplies",        (35, 180),  1.35, 0.09),
    ("Sensors",               (12, 90),   1.50, 0.07),
    ("Cables & Connectors",   (2, 25),    1.60, 0.03),
    ("Control Panels",        (150, 600), 1.30, 0.12),
]
NOUNS = {
    "Electrical Components": ["Relay", "Contactor", "Fuse Holder", "Circuit Breaker", "Terminal Block",
                              "Surge Protector", "Capacitor Bank", "Switch Module", "Transformer", "Timer Relay",
                              "Overload Relay", "Isolator"],
    "Power Supplies":        ["DIN PSU", "UPS Module", "DC Converter", "Battery Pack", "Inverter",
                              "Rectifier", "Servo Stabilizer", "Power Module", "Charger", "Voltage Regulator",
                              "Redundancy Module", "Buffer Module"],
    "Sensors":               ["Proximity Sensor", "Temperature Sensor", "Pressure Sensor", "Flow Meter", "Level Sensor",
                              "Photoelectric Sensor", "Current Sensor", "Encoder", "Limit Switch", "Vibration Sensor",
                              "Humidity Sensor", "Load Cell"],
    "Cables & Connectors":   ["Power Cable", "Control Cable", "M12 Connector", "Cable Gland", "Patch Cord",
                              "Shielded Cable", "Ferrule Kit", "Junction Box", "Wire Duct", "Cable Tie Pack",
                              "Plug Connector", "Bus Bar"],
    "Control Panels":        ["PLC Panel", "MCC Panel", "VFD Panel", "Distribution Board", "Relay Panel",
                              "HMI Enclosure", "Starter Panel", "Automation Panel", "Metering Panel", "APFC Panel",
                              "Lighting Panel", "Pump Panel"],
}

products = []   # (key, sku, name, category, unit_cost, unit_price)
cat_by_product = {}
key = 1
for cat, (lo, hi), markup, _ in CATEGORIES:
    for noun in NOUNS[cat]:
        cost = round(random.uniform(lo, hi), 2)
        price = round(cost * markup, 2)
        sku = f"{cat[:3].upper()}-{key:04d}"
        products.append((key, sku, noun, cat, cost, price))
        cat_by_product[key] = cat
        key += 1

stockout_prob = {c[0]: c[3] for c in CATEGORIES}

REGIONS = ["Northeast", "Southeast", "Midwest", "Southwest", "West"]
SEGMENTS = [("OEM", 0.25), ("Distributor", 0.35), ("Contractor", 0.40)]
customers = []  # (key, name, region, segment)
for k in range(1, 151):
    seg = random.choices([s for s, _ in SEGMENTS], weights=[w for _, w in SEGMENTS])[0]
    customers.append((k, f"Customer {k:03d}", random.choice(REGIONS), seg))

# ---------------------------------------------------------------------
# Fact: order lines
# ---------------------------------------------------------------------
# Skew demand: some products and customers order far more than others
product_weights = [random.paretovariate(1.6) for _ in products]
customer_weights = [random.paretovariate(1.4) for _ in customers]
warehouse_weights = [0.26, 0.22, 0.20, 0.17, 0.15]

days_span = (END - START).days
order_lines = []
line_id = 1
order_id = 100000
while line_id <= N_ORDER_LINES:
    order_id += 1
    # Orders get a little busier over time (business growth)
    d = START + timedelta(days=int(days_span * (random.random() ** 0.85)))
    if d.weekday() >= 5:                      # no orders on weekends
        d -= timedelta(days=d.weekday() - 4)
    cust = random.choices(customers, weights=customer_weights)[0]
    wh = random.choices(WAREHOUSES, weights=warehouse_weights)[0]
    n_lines = random.choices([1, 2, 3, 4, 5], weights=[35, 28, 18, 12, 7])[0]
    chosen = random.choices(products, weights=product_weights, k=n_lines)

    for p in chosen:
        if line_id > N_ORDER_LINES:
            break
        pkey, _, _, cat, cost, price = p
        ordered = max(1, int(random.lognormvariate(2.3, 0.8)))
        if cat == "Control Panels":
            ordered = max(1, ordered // 6)

        promised = d + timedelta(days=random.randint(5, 12))

        # Shipping: base processing + warehouse speed + occasional delay
        processing = random.randint(1, 4) + wh[4]
        if random.random() < wh[5]:
            processing += random.randint(4, 12)       # late shipment
        ship = d + timedelta(days=processing)
        transit = random.randint(1, 4)
        delivery = ship + timedelta(days=transit)

        # Partial shipment when the item stocks out
        shipped = ordered
        if random.random() < stockout_prob[cat]:
            shipped = int(ordered * random.uniform(0.3, 0.9))

        # Recent orders, and a few stuck backorders, are still open
        status = "Delivered"
        ship_s, deliv_s = ship.isoformat(), delivery.isoformat()
        # a few recent lines are stuck on backorder (supplier delays)
        stuck_backorder = d > END - timedelta(days=75) and random.random() < 0.03
        if ship > END or stuck_backorder:
            status, shipped, ship_s, deliv_s = "Open", 0, "", ""
        elif delivery > END:
            status, deliv_s = "Shipped", ""

        # Price can drift slightly by contract
        line_price = round(price * random.uniform(0.92, 1.03), 2)

        order_lines.append((
            line_id, order_id, d.isoformat(), promised.isoformat(), ship_s, deliv_s,
            pkey, cust[0], wh[0], ordered, shipped, line_price, cost, status,
        ))
        line_id += 1

# Put lines in date order and renumber, like a real order system would
order_lines.sort(key=lambda r: (r[2], r[1], r[0]))
order_renumber = {}
renumbered = []
for i, r in enumerate(order_lines, start=1):
    new_order = order_renumber.setdefault(r[1], 100001 + len(order_renumber))
    renumbered.append((i, new_order) + r[2:])
order_lines = renumbered

# ---------------------------------------------------------------------
# Fact: weekly inventory snapshots (every Monday, per product per warehouse)
# Sized so each SKU holds roughly 4 to 8 weeks of its own demand
# ---------------------------------------------------------------------
weeks = (END - START).days // 7 + 1
weekly_demand = {}
for row in order_lines:
    k = (row[6], row[8])
    weekly_demand[k] = weekly_demand.get(k, 0) + row[9]
for k in weekly_demand:
    weekly_demand[k] /= weeks

first_monday = START + timedelta(days=(7 - START.weekday()) % 7)
inventory = []
for p in products:
    pkey, cost = p[0], p[4]
    for wh in WAREHOUSES:
        demand = weekly_demand.get((pkey, wh[0]), 0.5)
        target = demand * random.uniform(4, 8)
        level = target
        snap = first_monday
        while snap <= END:
            level = max(0.0, level + random.gauss(0, target * 0.15) + (target - level) * 0.3)
            inventory.append((snap.isoformat(), pkey, wh[0], int(round(level)), cost))
            snap += timedelta(days=7)

# ---------------------------------------------------------------------
# Write CSVs
# ---------------------------------------------------------------------
print("Writing raw CSVs to data/:")
write_csv("products.csv", ["product_id", "sku", "product_name", "category", "unit_cost", "unit_price"], products)
write_csv("customers.csv", ["customer_id", "customer_name", "region", "segment"], customers)
write_csv("warehouses.csv", ["warehouse_id", "warehouse_name", "city", "state"], [w[:4] for w in WAREHOUSES])
write_csv("order_lines.csv",
          ["order_line_id", "order_id", "order_date", "promised_date", "ship_date", "delivery_date",
           "product_id", "customer_id", "warehouse_id", "ordered_qty", "shipped_qty",
           "unit_price", "unit_cost", "line_status"],
          order_lines)
write_csv("inventory_snapshots.csv",
          ["snapshot_date", "product_id", "warehouse_id", "on_hand_qty", "unit_cost"],
          inventory)
print("Done.")
