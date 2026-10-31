CREATE TABLE IF NOT EXISTS products (
  id          SERIAL PRIMARY KEY,
  name        VARCHAR(255)   NOT NULL,
  description TEXT,
  price       NUMERIC(10, 2) NOT NULL,
  created_at  TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

-- Seed rows only when the table is empty, so running this file again does not create duplicates
INSERT INTO products (name, description, price)
SELECT * FROM (VALUES
  ('Laptop',     '14-inch developer laptop',    1299.99),
  ('Headphones', 'Noise-cancelling headphones',  199.50),
  ('Keyboard',   'Mechanical keyboard',           89.00)
) AS v(name, description, price)
WHERE NOT EXISTS (SELECT 1 FROM products);
