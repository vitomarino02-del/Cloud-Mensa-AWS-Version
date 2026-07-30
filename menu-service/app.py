# menu-service: catalogo piatti + immagini
# Le foto vanno su volume locale (Fase 1) o su S3 (Fase 2), scelta con STORAGE_BACKEND.
import os
import uuid
import io
import time
from flask import Flask, request, jsonify, send_file
from flask_cors import CORS
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy.exc import IntegrityError, ProgrammingError, OperationalError

db = SQLAlchemy()

STORAGE_BACKEND = os.environ.get("STORAGE_BACKEND", "local")  # local | s3
IMAGE_DIR = os.environ.get("IMAGE_DIR", "/data/images")


class Dish(db.Model):
    __tablename__ = "dishes"
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False)
    description = db.Column(db.String(255))
    price = db.Column(db.Numeric(6, 2), nullable=False, default=0)
    category = db.Column(db.String(40), default="primo")  # primo|secondo|contorno|bevanda|dolce
    image_key = db.Column(db.String(200))
    available = db.Column(db.Boolean, default=True)

    def to_dict(self):
        return {
            "id": self.id, "name": self.name, "description": self.description,
            "price": float(self.price), "category": self.category,
            "available": self.available,
            "image_url": image_url(self.image_key) if self.image_key else None,
        }


# --- storage immagini: stesse funzioni, backend diverso in base all'ambiente ---

def save_image(data, content_type):
    ext = ".png" if "png" in content_type else ".jpg"
    key = uuid.uuid4().hex + ext
    if STORAGE_BACKEND == "s3":
        import boto3
        s3 = boto3.client("s3", region_name=os.environ.get("AWS_REGION", "us-east-1"))
        s3.put_object(Bucket=os.environ["S3_BUCKET"], Key=key, Body=data,
                      ContentType=content_type)
    else:
        os.makedirs(IMAGE_DIR, exist_ok=True)
        with open(os.path.join(IMAGE_DIR, key), "wb") as f:
            f.write(data)
    return key


def image_url(key):
    if STORAGE_BACKEND == "s3":
        bucket = os.environ["S3_BUCKET"]
        region = os.environ.get("AWS_REGION", "us-east-1")
        return f"https://{bucket}.s3.{region}.amazonaws.com/{key}"
    return f"/api/menu/images/{key}"  # servita da questo stesso servizio


SEED = [
    ("Pasta alla Norma", "Pomodoro, melanzane e ricotta salata", 4.50, "primo"),
    ("Risotto ai funghi", "Riso carnaroli e funghi porcini", 5.00, "primo"),
    ("Cotoletta alla milanese", "Con patatine fritte", 6.00, "secondo"),
    ("Pollo alla griglia", "Petto di pollo con insalata", 5.50, "secondo"),
    ("Insalata mista", "Verdure fresche di stagione", 3.00, "contorno"),
    ("Patatine fritte", "Porzione media", 2.50, "contorno"),
    ("Acqua naturale 0.5L", "Bottiglia", 0.50, "bevanda"),
    ("Coca-Cola 0.33L", "Lattina", 1.50, "bevanda"),
    ("Tiramisu", "Fatto in casa", 3.00, "dolce"),
]


def create_app():
    app = Flask(__name__)
    CORS(app)
    app.config["SQLALCHEMY_DATABASE_URI"] = os.environ.get(
        "DATABASE_URL", "postgresql://mensa:mensa@localhost:5432/mensa")
    app.config["MAX_CONTENT_LENGTH"] = 5 * 1024 * 1024  # upload max 5 MB
    db.init_app(app)

    # In Kubernetes non esiste depends_on: il DB potrebbe non essere ancora
    # pronto, quindi si riprova. Se invece un altro worker ha gia' creato
    # tabelle e seed (race), si prosegue.
    with app.app_context():
        for _ in range(30):
            try:
                db.create_all()
                if Dish.query.count() == 0:
                    for name, desc, price, cat in SEED:
                        db.session.add(Dish(name=name, description=desc,
                                            price=price, category=cat))
                    db.session.commit()
                break
            except (IntegrityError, ProgrammingError):
                db.session.rollback()   # race: ha gia' fatto tutto un altro
                break
            except OperationalError:
                db.session.rollback()   # DB non pronto: aspetta e riprova
                time.sleep(2)

    @app.get("/healthz")
    def healthz():
        return {"status": "ok", "service": "menu-service"}

    @app.get("/api/menu")
    def list_menu():
        dishes = Dish.query.filter_by(available=True).order_by(Dish.id).all()
        return jsonify([d.to_dict() for d in dishes])

    @app.post("/api/menu/<int:dish_id>/image")
    def upload_image(dish_id):
        dish = Dish.query.get_or_404(dish_id)
        f = request.files.get("file")
        if not f:
            return {"error": "file mancante"}, 400
        dish.image_key = save_image(f.read(), f.content_type or "image/jpeg")
        db.session.commit()
        return dish.to_dict(), 201

    @app.get("/api/menu/images/<key>")
    def serve_image(key):
        # usata solo con storage locale (con S3 l'URL punta direttamente al bucket)
        path = os.path.join(IMAGE_DIR, os.path.basename(key))
        if not os.path.exists(path):
            return {"error": "immagine non trovata"}, 404
        mime = "image/png" if key.endswith(".png") else "image/jpeg"
        return send_file(path, mimetype=mime)

    return app


app = create_app()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)
