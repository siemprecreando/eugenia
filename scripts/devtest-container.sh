#!/usr/bin/env bash
# Corre devtest.sh dentro del contenedor eugenia-devtools (pymobiledevice3 no se
# instala en Bazzite). Mismos argumentos: ./scripts/devtest-container.sh smoke
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
podman image exists eugenia-devtools || podman build -q -t eugenia-devtools "$ROOT/scripts/devtools"
# --privileged + --network host: el túnel de iOS 17+ (--userspace) y usbmuxd.
# label=disable: SELinux de Bazzite no deja tocar el socket de usbmuxd si no.
TTY=(); [ -t 0 ] && TTY=(-it)
exec podman run --rm "${TTY[@]}" --privileged --network host --security-opt label=disable \
  -v /var/run/usbmuxd:/var/run/usbmuxd -v /var/lib/lockdown:/var/lib/lockdown \
  -v "$ROOT":"$ROOT" -w "$ROOT" \
  ${EUGENIA_BUNDLE:+-e EUGENIA_BUNDLE="$EUGENIA_BUNDLE"} \
  ${EUGENIA_TIMEOUT:+-e EUGENIA_TIMEOUT="$EUGENIA_TIMEOUT"} \
  eugenia-devtools bash scripts/devtest.sh "$@"
