import React, { useEffect, useState } from 'react'
import { api } from './api.js'

export default function App() {
  const [tab, setTab] = useState('menu')
  return (
    <div className="app">
      <h1>🍝 Mensa Universitaria</h1>
      <div className="muted" style={{ color: '#9db4d0' }}>Ordina, paga alla cassa, ritira quando pronto</div>
      <div className="tabs">
        <button className={tab === 'menu' ? 'on' : ''} onClick={() => setTab('menu')}>Menu & Ordina</button>
        <button className={tab === 'kitchen' ? 'on' : ''} onClick={() => setTab('kitchen')}>Display Cucina</button>
      </div>
      {tab === 'menu' ? <MenuOrder /> : <Kitchen />}
    </div>
  )
}

function MenuOrder() {
  const [menu, setMenu] = useState([])
  const [cart, setCart] = useState({})     // dish_id -> {dish, qty}
  const [customer, setCustomer] = useState('')
  const [placed, setPlaced] = useState(null)
  const [err, setErr] = useState('')

  useEffect(() => { api.menu().then(setMenu).catch(e => setErr(e.error || 'Errore menu')) }, [])

  // polling stato ordine piazzato
  useEffect(() => {
    if (!placed) return
    const t = setInterval(() => api.order(placed.id).then(setPlaced).catch(() => {}), 2000)
    return () => clearInterval(t)
  }, [placed && placed.id])

  const add = (d) => setCart(c => ({ ...c, [d.id]: { dish: d, qty: (c[d.id]?.qty || 0) + 1 } }))
  const sub = (d) => setCart(c => {
    const q = (c[d.id]?.qty || 0) - 1; const n = { ...c }
    if (q <= 0) delete n[d.id]; else n[d.id] = { dish: d, qty: q }; return n
  })
  const total = Object.values(cart).reduce((s, x) => s + x.dish.price * x.qty, 0)

  const submit = () => {
    const items = Object.values(cart).map(x => ({ dish_id: x.dish.id, qty: x.qty }))
    api.createOrder(customer, items)
      .then(o => { setPlaced(o); setCart({}); setErr('') })
      .catch(e => setErr(e.error || 'Errore ordine'))
  }

  return (
    <>
      {err && <p className="err">⚠ {err}</p>}
      {placed && (
        <div className="cart">
          <h2>Ordine #{placed.id} <span className={'badge s-' + placed.status}>{placed.status.replace('_', ' ')}</span></h2>
          <div className="muted">{placed.customer} · totale {placed.total.toFixed(2)} €</div>
        </div>
      )}
      <div className="grid">
        {menu.map(d => (
          <div className="card" key={d.id}>
            {d.image_url ? <img src={d.image_url} alt={d.name} /> : <div className="ph">nessuna foto</div>}
            <div className="body">
              <div className="cat">{d.category}</div>
              <strong>{d.name}</strong>
              <div className="muted">{d.description}</div>
              <div className="row">
                <span className="price">{d.price.toFixed(2)} €</span>
                <span>
                  <button onClick={() => sub(d)}>−</button>
                  <span style={{ padding: '0 8px' }}>{cart[d.id]?.qty || 0}</span>
                  <button onClick={() => add(d)}>+</button>
                </span>
              </div>
            </div>
          </div>
        ))}
      </div>
      <div className="cart">
        <h2>Il tuo ordine — {total.toFixed(2)} €</h2>
        {Object.values(cart).length === 0 && <div className="muted">Carrello vuoto.</div>}
        {Object.values(cart).map(x => (
          <div className="row" key={x.dish.id}>
            <span>{x.qty}× {x.dish.name}</span>
            <span className="price">{(x.dish.price * x.qty).toFixed(2)} €</span>
          </div>
        ))}
        <div className="row" style={{ marginTop: 12 }}>
          <input placeholder="Il tuo nome" value={customer} onChange={e => setCustomer(e.target.value)} />
          <button className="alt" disabled={!customer || total === 0} onClick={submit}>Invia ordine</button>
        </div>
      </div>
    </>
  )
}

function Kitchen() {
  const [orders, setOrders] = useState([])
  const load = () => api.activeOrders().then(setOrders).catch(() => {})
  useEffect(() => { load(); const t = setInterval(load, 2000); return () => clearInterval(t) }, [])
  const adv = (id) => api.advance(id).then(load).catch(() => {})
  return (
    <div>
      <h2 style={{ color: '#fff' }}>Ordini in corso ({orders.length})</h2>
      {orders.length === 0 && <div className="muted" style={{ color: '#9db4d0' }}>Nessun ordine attivo.</div>}
      {orders.map(o => (
        <div className="krow" key={o.id}>
          <div>
            <strong>#{o.id} — {o.customer}</strong>{' '}
            <span className={'badge s-' + o.status}>{o.status.replace('_', ' ')}</span>
            <div className="muted">{o.items.map(i => `${i.qty}× ${i.dish_name}`).join(', ')}</div>
          </div>
          <button className="alt" onClick={() => adv(o.id)}>Avanza stato →</button>
        </div>
      ))}
    </div>
  )
}
