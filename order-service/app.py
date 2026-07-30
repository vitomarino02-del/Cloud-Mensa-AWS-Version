# order-service: gestione ordini
# Postgres = storico ordini, Redis = tabellone cucina (ordini attivi),
# RabbitMQ = eventi verso kitchen-service.
import os
import json
import time
import logging
from flask import Flask, request, jsonify
from flask_cors import CORS
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy.exc import IntegrityError, ProgrammingError, OperationalError
import redis
import pika

db = SQLAlchemy()
log = logging.getLogger("order-service")

REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379/0")
RABBITMQ_URL = os.environ.get("RABBITMQ_URL", "amqp://guest:guest@localhost:5672/")
EXCHANGE = "order.events"     # exchange fanout: il messaggio arriva a tutti i consumer
BOARD_KEY = "kitchen:board"   # hash Redis: id ordine -> json

STATES = ["ricevuto", "in_preparazione", "pronto", "ritirato"]


class Dish(db.Model):
    """Stessa tabella del menu-service, qui usata in sola lettura.
    Lo schema DEVE essere identico a quello del menu-service: in K8s l'ordine
    di avvio e' casuale e la tabella la crea il primo servizio che parte."""
    __tablename__ = "dishes"
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False)
    description = db.Column(db.String(255))
    price = db.Column(db.Numeric(6, 2), nullable=False, default=0)
    category = db.Column(db.String(40), default="primo")
    image_key = db.Column(db.String(200))
    available = db.Column(db.Boolean, default=True)


class Order(db.Model):
    __tablename__ = "orders"
    id = db.Column(db.Integer, primary_key=True)
    customer = db.Column(db.String(120), nullable=False)
    status = db.Column(db.String(20), nullable=False, default="ricevuto")
    total = db.Column(db.Numeric(7, 2), nullable=False, default=0)
    created_at = db.Column(db.DateTime, server_default=db.func.now())
    items = db.relationship("OrderItem", backref="order",
                            cascade="all, delete-orphan")

    def to_dict(self):
        return {"id": self.id, "customer": self.customer, "status": self.status,
                "total": float(self.total),
                "items": [i.to_dict() for i in self.items]}


class OrderItem(db.Model):
    __tablename__ = "order_items"
    id = db.Column(db.Integer, primary_key=True)
    order_id = db.Column(db.Integer, db.ForeignKey("orders.id"), nullable=False)
    dish_id = db.Column(db.Integer, db.ForeignKey("dishes.id"), nullable=False)
    dish_name = db.Column(db.String(120))   # nome e prezzo copiati: lo storico
    qty = db.Column(db.Integer, nullable=False, default=1)
    unit_price = db.Column(db.Numeric(6, 2), nullable=False, default=0)  # resta giusto anche se il menu cambia

    def to_dict(self):
        return {"dish_id": self.dish_id, "dish_name": self.dish_name,
                "qty": self.qty, "unit_price": float(self.unit_price)}


# --- tabellone su Redis: se Redis non risponde l'app continua a funzionare ---

_redis = None

def r():
    global _redis
    if _redis is None:
        _redis = redis.from_url(REDIS_URL, decode_responses=True)
    return _redis


def board_put(order):
    try:
        r().hset(BOARD_KEY, order["id"], json.dumps(order))
    except Exception as e:
        log.warning("Redis non disponibile: %s", e)


def board_remove(order_id):
    try:
        r().hdel(BOARD_KEY, order_id)
    except Exception as e:
        log.warning("Redis non disponibile: %s", e)


def board_all():
    try:
        return [json.loads(v) for v in r().hvals(BOARD_KEY)]
    except Exception as e:
        log.warning("Redis non disponibile: %s", e)
        return []


# --- eventi su RabbitMQ ---

def publish(event_type, payload):
    body = json.dumps({"type": event_type, "data": payload})
    try:
        conn = pika.BlockingConnection(pika.URLParameters(RABBITMQ_URL))
        ch = conn.channel()
        ch.exchange_declare(exchange=EXCHANGE, exchange_type="fanout", durable=True)
        ch.basic_publish(exchange=EXCHANGE, routing_key="", body=body)
        conn.close()
    except Exception as e:
        log.warning("RabbitMQ non disponibile: %s", e)


def create_app():
    app = Flask(__name__)
    CORS(app)
    app.config["SQLALCHEMY_DATABASE_URI"] = os.environ.get(
        "DATABASE_URL", "postgresql://mensa:mensa@localhost:5432/mensa")
    db.init_app(app)

    # DB non pronto -> riprova; tabelle gia' create dal menu-service -> prosegui
    with app.app_context():
        for _ in range(30):
            try:
                db.create_all()
                break
            except (IntegrityError, ProgrammingError):
                db.session.rollback()
                break
            except OperationalError:
                db.session.rollback()
                time.sleep(2)

    @app.get("/healthz")
    def healthz():
        return {"status": "ok", "service": "order-service"}

    @app.post("/api/orders")
    def create_order():
        d = request.get_json(force=True)
        customer = d.get("customer", "").strip()
        items = d.get("items", [])
        if not customer or not items:
            return {"error": "cliente e items obbligatori"}, 400
        order = Order(customer=customer, status="ricevuto", total=0)
        db.session.add(order)
        total = 0
        for it in items:
            dish = db.session.get(Dish, it["dish_id"])
            if not dish:
                return {"error": f"piatto {it['dish_id']} inesistente"}, 400
            qty = int(it.get("qty", 1))
            total += float(dish.price) * qty   # totale calcolato lato server
            order.items.append(OrderItem(dish_id=dish.id, dish_name=dish.name,
                                         qty=qty, unit_price=dish.price))
        order.total = total
        db.session.commit()
        board_put(order.to_dict())              # lavagna cucina
        publish("order.created", order.to_dict())  # campanello
        return jsonify(order.to_dict()), 201

    @app.get("/api/orders")
    def list_orders():
        # ?active=1 -> tabellone veloce da Redis; senza -> storico da Postgres
        if request.args.get("active"):
            board = board_all()
            board.sort(key=lambda o: o["id"])
            return jsonify(board)
        orders = Order.query.order_by(Order.id.desc()).limit(50).all()
        return jsonify([o.to_dict() for o in orders])

    @app.get("/api/orders/<int:oid>")
    def get_order(oid):
        return jsonify(Order.query.get_or_404(oid).to_dict())

    @app.post("/api/orders/<int:oid>/advance")
    def advance(oid):
        order = Order.query.get_or_404(oid)
        i = STATES.index(order.status)
        if i >= len(STATES) - 1:
            return {"error": "ordine gia' completato"}, 409
        order.status = STATES[i + 1]
        db.session.commit()
        if order.status == "ritirato":
            board_remove(order.id)   # via dalla lavagna, resta nello storico
        else:
            board_put(order.to_dict())
        if order.status == "pronto":
            publish("order.ready", order.to_dict())
        return jsonify(order.to_dict())

    return app


app = create_app()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5002)
