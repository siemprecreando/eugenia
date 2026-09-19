#!/usr/bin/env bash
# Instala SideStore en el iPhone desde Linux, sin Mac. Plan, sección 6.2.
#
# QUÉ HACE: descarga y abre iloader (github.com/nab138/iloader), el instalador que
# recomienda hoy la documentación de SideStore. Es una app de escritorio: tú pones
# el Apple ID en su ventana, instala SideStore y deja el fichero de emparejamiento
# en el teléfono. Tus credenciales no pasan por este script.
#
# POR QUÉ NO ALTCON: hasta 2026-09 se usaba Altcon (AltServer-Linux en un
# contenedor). Desde principios de septiembre de 2026 Apple rechaza su login con
# HTTP 503 ("ALTAppleAPI (17)"), da igual el servidor de anisette. iloader >= 2.3.2
# trae el arreglo. Detalles en el README.
#
# APPLE ID SECUNDARIO: recomendado. El certificado de desarrollo gratuito va
# asociado a esa cuenta.
set -uo pipefail

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31m    %s\033[0m\n' "$*"; }

# Se usa el RPM desempaquetado, NO el AppImage: el WebKit que lleva dentro el
# AppImage no puede con el Mesa de Bazzite/Fedora 44 ("Could not create default EGL
# display: EGL_BAD_PARAMETER") y la ventana sale en blanco. El binario del RPM usa
# el webkit2gtk-4.1 del sistema, que sí funciona. No se instala el RPM (rpm-ostree),
# solo se extrae.
DIR="$HOME/Applications"
APP="$DIR/iloader-rpm/usr/bin/iloader"
# Versión y hash ANCLADOS (revisión de supply chain 2026-09-18). iloader maneja tu
# contraseña de Apple ID: no se ejecuta nada que no coincida con este hash, que es el
# que publica GitHub para el asset de la v2.3.3 (y el que verifica su firma minisign).
ILOADER_VERSION="v2.3.3"
ILOADER_SHA256="2dd4eba385bca8fc9eeba835a3448ba2c5497716319b277713e56cdb85e9fd35"

say "1/3 · ¿Está el iPhone conectado?"
UDID=$(idevice_id -l 2>/dev/null | head -1)
if [ -z "$UDID" ]; then
  fail "No se ve ningún dispositivo. Conecta el cable, desbloquea y acepta 'Confiar'."
  exit 1
fi
echo "    UDID: $UDID"

say "2/3 · iloader"
RPM="$DIR/iloader-linux-x86_64.rpm"
if [ ! -f "$RPM" ] || ! echo "$ILOADER_SHA256  $RPM" | sha256sum -c --quiet 2>/dev/null; then
  mkdir -p "$DIR"
  gh release download "$ILOADER_VERSION" -R nab138/iloader -p 'iloader-linux-x86_64.rpm' -D "$DIR" --clobber \
    || { fail "No se pudo descargar iloader."; exit 1; }
  rm -rf "$DIR/iloader-rpm"
fi
if ! echo "$ILOADER_SHA256  $RPM" | sha256sum -c --quiet; then
  fail "El hash de iloader NO coincide. No se ejecuta."
  rm -f "$RPM"
  exit 1
fi
if [ ! -x "$APP" ]; then
  mkdir -p "$DIR/iloader-rpm"
  (cd "$DIR/iloader-rpm" && rpm2cpio "$RPM" | cpio -idm --quiet)
fi
echo "    $APP"

say "3/3 · Abriendo iloader"
cat <<'AVISO'
    En la ventana:
      · Inicia sesión con tu Apple ID (y el código de doble factor).
      · Elige el iPhone e instala SideStore.
      · Deja que coloque el fichero de emparejamiento en el teléfono.
    Luego, en el iPhone: confía en tu Apple ID (Ajustes → General → VPN y gestión
    de dispositivos), instala LocalDevVPN desde la App Store y abre SideStore.
AVISO
cd "$(dirname "$APP")" && exec "$APP"
