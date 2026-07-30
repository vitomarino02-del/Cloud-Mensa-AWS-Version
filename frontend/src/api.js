const j = (r) => { if (!r.ok) return r.json().then(e => Promise.reject(e)); return r.json() }
const post = (url, body) =>
  fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body || {}) }).then(j)

export const api = {
  menu: () => fetch('/api/menu').then(j),
  createOrder: (customer, items) => post('/api/orders', { customer, items }),
  order: (id) => fetch(`/api/orders/${id}`).then(j),
  activeOrders: () => fetch('/api/orders?active=1').then(j),
  advance: (id) => post(`/api/orders/${id}/advance`),
}
