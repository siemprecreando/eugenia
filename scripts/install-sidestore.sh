#!/usr/bin/env bash
# Instala SideStore en el iPhone desde Linux, sin Mac. Plan, sección 6.2.
#
# QUÉ HACE: lanza Altcon, el contenedor oficial de SideStore, que lleva dentro
# AltServer-Linux. Ese es el que resuelve el huevo y la gallina — el .ipa de Eugenia
# está SIN FIRMAR, y para poner la primera app en el teléfono hace falta algo que
# firme con tu Apple ID. AltServer-Linux lo hace por USB.
#
# LO QUE TIENES QUE PONER TÚ, DENTRO DEL CONTENEDOR:
#   - Tu Apple ID y su contraseña, más el código de doble factor.
#   - Se quedan en el contenedor, que es efímero (--rm). No se guardan en el disco
#     ni salen de tu máquina más allá de Apple.
#   - Por eso este script lo ejecutas tú y no lo lanzo yo: no debo manejar tus
#     credenciales, igual que con la contraseña de GitHub.
#
# APPLE ID SECUNDARIO: la documentación de SideStore lo recomienda, y tiene sentido.
# El certificado de desarrollo gratuito va asociado a esa cuenta, y si algo se
# tuerce prefieres que no sea la cuenta con tus compras y tu iCloud.
set -uo pipefail

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31m    %s\033[0m\n' "$*"; }

OUT="${1:-$HOME/sidestore}"
mkdir -p "$OUT"

say "1/4 · ¿Está el iPhone conectado?"
if ! command -v idevice_id >/dev/null 2>&1; then
  fail "Falta idevice_id (paquete libimobiledevice-utils)."
  exit 1
fi
UDID=$(idevice_id -l 2>/dev/null | head -1)
if [ -z "$UDID" ]; then
  fail "No se ve ningún dispositivo."
  fail "Conecta el iPhone por cable, desbloquéalo y acepta 'Confiar en este ordenador'."
  fail "usbmuxd arranca solo al conectarlo (regla udev), no hace falta lanzarlo a mano."
  exit 1
fi
echo "    UDID: $UDID"

say "2/4 · Comprobando el socket de usbmuxd"
if [ ! -S /var/run/usbmuxd ] && [ ! -e /var/run/usbmuxd ]; then
  fail "/var/run/usbmuxd no existe todavía. Desconecta y vuelve a conectar el cable."
  exit 1
fi
echo "    ok"

say "3/4 · Lanzando Altcon (contenedor oficial de SideStore)"
cat <<'AVISO'
    Dentro del contenedor:
      · Te pedirá el PIN del teléfono para emparejar.
      · Luego el Apple ID y la contraseña, y el código de doble factor.
      · Elige instalar SideStore cuando te lo ofrezca.
      · Al terminar escribe 'exit'.

    Cuando salgas, el fichero .mobiledevicepairing queda en el directorio de salida.
AVISO
echo
read -r -p "    ¿Seguimos? [s/N] " answer
[ "$answer" = "s" ] || [ "$answer" = "S" ] || { echo "    cancelado"; exit 0; }

# --security-opt label=disable: Bazzite lleva SELinux, y sin esto el contenedor no
# puede tocar el socket de usbmuxd del host.
podman run --rm -it \
  --security-opt label=disable \
  -v "$OUT":/mnt \
  -v /var/run/usbmuxd:/var/run/usbmuxd \
  -v /var/lib/lockdown:/tmp/lockdown \
  ghcr.io/sidestore/altcon

say "4/4 · Resultado"
PAIRING=$(find "$OUT" -name "*.mobiledevicepairing" 2>/dev/null | head -1)
if [ -n "$PAIRING" ]; then
  echo "    Fichero de emparejamiento: $PAIRING"
  echo
  echo "    Sigue en el teléfono:"
  echo "      1. Instala StosVPN (o WireGuard) desde la App Store — SideStore lo necesita."
  echo "      2. Pasa ese fichero al iPhone y ábrelo con SideStore para importarlo."
  echo "      3. En SideStore, añade la fuente o instala directamente desde:"
  echo "         https://github.com/siemprecreando/eugenia/releases/latest/download/Eugenia.ipa"
else
  fail "No apareció ningún .mobiledevicepairing en $OUT."
  fail "Si el contenedor falló antes de emparejar, revisa el cable y el PIN."
fi
