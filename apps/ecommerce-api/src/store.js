'use strict';

// All SQL lives here. Values are always passed as parameters ($1), never interpolated.

// healthPool (optional): a separate pool for ping(), so health reflects Postgres
// itself, not whether the request pool has a free connection.
function createStore(pool, { healthPool = pool } = {}) {
  return {
    ping: () => healthPool.query('SELECT 1'),

    async listProducts() {
      const { rows } = await pool.query(
        'SELECT id, sku, name, price_cents, stock FROM products ORDER BY sku',
      );
      return rows;
    },

    async getOrder(id) {
      const { rows } = await pool.query(
        `SELECT o.id, o.status, o.total_cents, o.created_at,
                json_agg(json_build_object(
                  'product_id', i.product_id,
                  'quantity', i.quantity,
                  'unit_price_cents', i.unit_price_cents) ORDER BY i.product_id) AS items
           FROM orders o
           JOIN order_items i ON i.order_id = o.id
          WHERE o.id = $1
          GROUP BY o.id`,
        [id],
      );
      return rows[0] ?? null;
    },

    // Returns { ok: true, order } or { ok: false, reason, productId }.
    async createOrder(items) {
      // Merge duplicate lines for the same product. UUIDs compared lowercase (Postgres output).
      const wanted = new Map();
      for (const { product_id: id, quantity } of items) {
        const key = id.toLowerCase();
        wanted.set(key, (wanted.get(key) ?? 0) + quantity);
      }
      const ids = [...wanted.keys()];

      const client = await pool.connect();
      try {
        await client.query('BEGIN');
        // Lock the product rows (in a fixed order, to avoid deadlocks between
        // concurrent orders) so stock can't change between check and update.
        const { rows: products } = await client.query(
          'SELECT id, price_cents, stock FROM products WHERE id = ANY($1::uuid[]) ORDER BY id FOR UPDATE',
          [ids],
        );

        const missing = ids.find((id) => !products.some((p) => p.id === id));
        if (missing) {
          await client.query('ROLLBACK');
          return { ok: false, reason: 'unknown_product', productId: missing };
        }
        const short = products.find((p) => p.stock < wanted.get(p.id));
        if (short) {
          await client.query('ROLLBACK');
          return { ok: false, reason: 'insufficient_stock', productId: short.id };
        }

        const total = products.reduce((sum, p) => sum + p.price_cents * wanted.get(p.id), 0);
        const { rows: [order] } = await client.query(
          'INSERT INTO orders (total_cents) VALUES ($1) RETURNING id, status, total_cents, created_at',
          [total],
        );
        for (const p of products) {
          await client.query('UPDATE products SET stock = stock - $2 WHERE id = $1', [p.id, wanted.get(p.id)]);
          await client.query(
            'INSERT INTO order_items (order_id, product_id, quantity, unit_price_cents) VALUES ($1, $2, $3, $4)',
            [order.id, p.id, wanted.get(p.id), p.price_cents],
          );
        }
        await client.query('COMMIT');

        const lines = products.map((p) => ({
          product_id: p.id,
          quantity: wanted.get(p.id),
          unit_price_cents: p.price_cents,
        }));
        return { ok: true, order: { ...order, items: lines } };
      } catch (err) {
        await client.query('ROLLBACK').catch(() => {});
        throw err;
      } finally {
        client.release();
      }
    },
  };
}

module.exports = { createStore };
