# kitchen-service: consuma gli eventi ordine da RabbitMQ.
# In locale "notifica" = riga di log; in Fase 2 (AWS) al suo posto ci sara' SNS.
import os
import json
import time
import logging
import pika

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("kitchen")

RABBITMQ_URL = os.environ.get("RABBITMQ_URL", "amqp://guest:guest@localhost:5672/")
EXCHANGE = "order.events"


def on_message(ch, method, properties, body):
    try:
        ev = json.loads(body)
    except Exception:
        ev = {"raw": body.decode(errors="replace")}
    t, data = ev.get("type"), ev.get("data", {})
    if t == "order.created":
        log.info("NUOVO ORDINE #%s per %s - %s articoli (tot %.2f EUR)",
                 data.get("id"), data.get("customer"),
                 len(data.get("items", [])), data.get("total", 0))
    elif t == "order.ready":
        log.info("ORDINE #%s PRONTO -> avvisa %s", data.get("id"),
                 data.get("customer"))
    else:
        log.info("evento %s: %s", t, data)


def main():
    # RabbitMQ potrebbe non essere ancora pronto: riprova ogni 5 secondi
    while True:
        try:
            conn = pika.BlockingConnection(pika.URLParameters(RABBITMQ_URL))
            ch = conn.channel()
            ch.exchange_declare(exchange=EXCHANGE, exchange_type="fanout",
                                durable=True)
            q = ch.queue_declare(queue="kitchen", durable=True)
            ch.queue_bind(exchange=EXCHANGE, queue=q.method.queue)
            log.info("In ascolto sull'exchange '%s'...", EXCHANGE)
            ch.basic_consume(queue=q.method.queue,
                             on_message_callback=on_message, auto_ack=True)
            ch.start_consuming()
        except pika.exceptions.AMQPConnectionError:
            log.warning("RabbitMQ non pronto, ritento fra 5s...")
            time.sleep(5)
        except KeyboardInterrupt:
            break


if __name__ == "__main__":
    main()
