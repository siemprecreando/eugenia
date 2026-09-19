#!/usr/bin/env bash
# Corre devtest.sh dentro del contenedor eugenia-devtools (pymobiledevice3 no se
# instala en Bazzite). Mismos argumentos: ./scripts/devtest-container.sh smoke
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# La etiqueta de la imagen es la huella de lo que la define: cambiar una versión
# anclada reconstruye sola (antes la imagen vieja se usaba para siempre).
TAG="eugenia-devtools:$(cat "$ROOT/scripts/devtools/Containerfile" "$ROOT/scripts/devtools/requirements.txt" | sha256sum | cut -c1-12)"
podman image exists "$TAG" || podman build -q -t "$TAG" "$ROOT/scripts/devtools"
# --privileged + --network host: el túnel de iOS 17+ (--userspace) y usbmuxd.
# label=disable: SELinux de Bazzite no deja tocar el socket de usbmuxd si no.
# Emparejamiento en SOLO LECTURA: el contenedor lo usa, no tiene por qué cambiarlo.
TTY=(); [ -t 0 ] && TTY=(-it)
exec podman run --rm "${TTY[@]}" --privileged --network host --security-opt label=disable \
  -v /var/run/usbmuxd:/var/run/usbmuxd -v /var/lib/lockdown:/var/lib/lockdown:ro \
  -v "$ROOT":"$ROOT" -w "$ROOT" \
  ${EUGENIA_BUNDLE:+-e EUGENIA_BUNDLE="$EUGENIA_BUNDLE"} \
  ${EUGENIA_TIMEOUT:+-e EUGENIA_TIMEOUT="$EUGENIA_TIMEOUT"} \
  "$TAG" bash scripts/devtest.sh "$@"
