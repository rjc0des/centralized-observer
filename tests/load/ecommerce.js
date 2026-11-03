// k6 load profile for the e-commerce API: browse-heavy shoppers who sometimes buy
// and check an order. Run with `make load` (DURATION env, default 2m).
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://ecommerce-api:3000';

export const options = {
  scenarios: {
    shoppers: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '20s', target: 10 },
        { duration: __ENV.DURATION || '2m', target: 10 },
        { duration: '10s', target: 0 },
      ],
    },
  },
  // Mirrors the SLOs: p95 < 500ms and < 1% failed requests.
  thresholds: {
    http_req_duration: ['p(95)<500'],
    http_req_failed: ['rate<0.01'],
  },
};

const JSON_HEADERS = { headers: { 'Content-Type': 'application/json' } };

export function setup() {
  const res = http.get(`${BASE_URL}/products`);
  // LIMITED-001 is excluded: it exists to test the out-of-stock path.
  return res.json('products').filter((p) => p.sku !== 'LIMITED-001').map((p) => p.id);
}

export default function (productIds) {
  const products = http.get(`${BASE_URL}/products`, { tags: { name: 'GET /products' } });
  check(products, { 'products 200': (r) => r.status === 200 });

  if (Math.random() < 0.3) {
    const items = [{ product_id: productIds[Math.floor(Math.random() * productIds.length)], quantity: 1 + Math.floor(Math.random() * 3) }];
    const order = http.post(`${BASE_URL}/orders`, JSON.stringify({ items }), { ...JSON_HEADERS, tags: { name: 'POST /orders' } });
    check(order, { 'order 201': (r) => r.status === 201 });

    if (order.status === 201 && Math.random() < 0.5) {
      const fetched = http.get(`${BASE_URL}/orders/${order.json('id')}`, { tags: { name: 'GET /orders/:id' } });
      check(fetched, { 'order lookup 200': (r) => r.status === 200 });
    }
  }
  sleep(0.5 + Math.random());
}
