-- Demo catalogue. Stock is effectively unlimited so load tests don't sell out,
-- except LIMITED-001 (stock 5), which exists to exercise the out-of-stock path.
INSERT INTO products (sku, name, price_cents, stock) VALUES
  ('KB-001',      'Mechanical Keyboard',  8999, 1000000),
  ('MS-001',      'Wireless Mouse',       2999, 1000000),
  ('MN-001',      '27-inch Monitor',     24999, 1000000),
  ('HD-001',      'USB-C Hub',            3999, 1000000),
  ('HP-001',      'Noise-Cancelling Headphones', 19999, 1000000),
  ('CM-001',      '1080p Webcam',         5999, 1000000),
  ('DK-001',      'Standing Desk',       34999, 1000000),
  ('CH-001',      'Ergonomic Chair',     29999, 1000000),
  ('SS-001',      '1TB SSD',              7999, 1000000),
  ('LIMITED-001', 'Limited Edition Mug',  1499, 5);
