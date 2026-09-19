#!/usr/bin/env bash
# XcodeGen en CI, versión FIJA y comprobada por SHA-256.
#
# Antes era `brew install xcodegen`: la fórmula del momento, sin anclar, ejecutándose
# en el trabajo que compila el .ipa que se instala en el teléfono. XcodeGen escribe
# el proyecto; uno comprometido podría colar una fase de compilación en la app
# (revisión de supply chain 2026-09-18). Para actualizar: cambiar VERSION y SHA256
# con el `digest` de `gh api repos/yonaskolb/XcodeGen/releases/tags/<versión>`.
set -euo pipefail
VERSION="2.46.0"
SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
DIR="${RUNNER_TEMP:-$(mktemp -d)}/xcodegen-$VERSION"

mkdir -p "$DIR"
curl -sSfL --retry 3 -o "$DIR/xcodegen.zip" \
  "https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip"
echo "$SHA256  $DIR/xcodegen.zip" | shasum -a 256 -c -
unzip -q -o "$DIR/xcodegen.zip" -d "$DIR"
# El binario busca sus plantillas en ../share: se usa en su sitio, sin instalar.
if [ -n "${GITHUB_PATH:-}" ]; then echo "$DIR/xcodegen/bin" >> "$GITHUB_PATH"; fi
"$DIR/xcodegen/bin/xcodegen" --version
