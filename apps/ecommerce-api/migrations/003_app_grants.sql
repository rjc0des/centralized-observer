-- Exactly what the API needs, nothing more. New tables stay private until a
-- migration grants access explicitly.
--   products:    read the catalogue; change stock only (not prices or names)
--   orders:      create and read; never update or delete
--   order_items: create and read
GRANT SELECT ON products TO ecommerce_app;
GRANT UPDATE (stock) ON products TO ecommerce_app;
GRANT SELECT, INSERT ON orders, order_items TO ecommerce_app;
