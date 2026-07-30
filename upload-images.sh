#!/bin/bash
# Carica le foto dei piatti da demo-images/ (file <id>.jpg -> piatto con quell'id).
# Uso: ./upload-images.sh [url-base]   default: http://localhost:8081
# Nota: sul cluster le foto stanno in un emptyDir -> dopo un riavvio del pod
# menu-service vanno ricaricate (in Fase 2, con S3, sarebbero persistenti).
set -e

BASE="${1:-http://localhost:8081}"

for f in demo-images/*.jpg; do
  id=$(basename "$f" .jpg)
  echo "== piatto $id <- $f =="
  curl -sf -F "file=@$f" "$BASE/api/menu/$id/image" > /dev/null
done

echo "Fatto. Ricarica il menu nel browser."
