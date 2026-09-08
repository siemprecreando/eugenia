#!/usr/bin/env bash
# La conexión que se hace UNA SOLA VEZ. Plan, sección 6.5.
#
# Después de esto, el emparejamiento y el Modo Desarrollador sobreviven a los
# reinicios: no hay que repetir el ritual cada mañana.
set -euo pipefail

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

say "1/5 · Herramientas"
missing=0
for tool in pymobiledevice3 idevicepair idevice_id; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "  FALTA: $tool"
    missing=1
  else
    echo "  ok: $tool"
  fi
done
if [ "$missing" = 1 ]; then
  cat <<'HELP'

  En Fedora:
    sudo dnf install libimobiledevice-utils usbmuxd
    pipx install pymobiledevice3     # o: pip install --user pymobiledevice3
  Y asegúrate de que usbmuxd está corriendo:
    systemctl status usbmuxd
HELP
  exit 1
fi

say "2/5 · ¿Se ve el iPhone? (conéctalo por cable y desbloquéalo)"
pymobiledevice3 usbmux list
UDID=$(idevice_id -l | head -1 || true)
[ -n "$UDID" ] || { echo "No hay ningún dispositivo. Cable, desbloqueo y 'Confiar en este ordenador'."; exit 1; }
echo "UDID: $UDID"

say "3/5 · Emparejamiento (el mismo que necesita SideStore)"
idevicepair pair || echo "  (si ya estaba emparejado, esto es normal)"

say "4/5 · Modo Desarrollador — el teléfono se va a REINICIAR"
echo "  Tras el reinicio: Ajustes › Privacidad y seguridad › Modo Desarrollador."
read -r -p "  ¿Continuar? [s/N] " answer
if [ "$answer" = "s" ] || [ "$answer" = "S" ]; then
  pymobiledevice3 amfi enable-developer-mode || echo "  (puede que ya estuviera activado)"
fi

say "5/5 · Developer Disk Image"
pymobiledevice3 mounter auto-mount || echo "  (puede que ya estuviera montado)"

say "Listo"
cat <<'DONE'
  A partir de aquí:
    ./scripts/devtest.sh smoke     · prueba que el bucle entero funciona
    ./scripts/devtest.sh asr       · corre la suite de ASR sobre el corpus

  El cable ya no es obligatorio: con usbmuxd en modo red se puede trabajar por WiFi
  en la misma red. Si algo deja de responder, vuelve a conectar por cable.
DONE
