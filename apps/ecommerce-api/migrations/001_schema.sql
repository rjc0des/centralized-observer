-- uuidv7() (PostgreSQL 18+) gives time-ordered UUIDs: good B-tree locality for primary keys.

CREATE TABLE products (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  sku         text NOT NULL UNIQUE,
  name        text NOT NULL,
  price_cents integer NOT NULL CHECK (price_cents >= 0),
  stock       integer NOT NULL CHECK (stock >= 0),
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE orders (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  status      text NOT NULL DEFAULT 'created',
  total_cents bigint NOT NULL CHECK (total_cents >= 0),
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE order_items (
  order_id         uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
  product_id       uuid NOT NULL REFERENCES products (id),
  quantity         integer NOT NULL CHECK (quantity > 0),
  unit_price_cents integer NOT NULL CHECK (unit_price_cents >= 0),
  PRIMARY KEY (order_id, product_id)
);

-- The PK covers lookups by order_id; product_id needs its own index for the FK.
CREATE INDEX order_items_product_id_idx ON order_items (product_id);
CREATE INDEX orders_created_at_idx ON orders (created_at);
