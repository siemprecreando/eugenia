#!/usr/bin/env bash
# Modelos de separación de hablantes (FluidAudio, pipeline offline) DENTRO de la app.
#
# Por qué (revisión de seguridad 2026-09-18): FluidAudio los descarga la primera vez
# de la rama `main` de Hugging Face, sin fijar versión ni comprobar nada. Aquí se
# bajan de un commit FIJO y cada fichero se compara con su SHA-256 anotado en
# diarizer-models.sha256. Si algo no cuadra, el build falla. La app los lleva dentro
# y la librería funciona en modo sin red: nada que descargar, nada que suplantar.
#
# Uso: scripts/fetch-diarizer-models.sh   (lo llama CI antes de generar el proyecto)
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="FluidInference/speaker-diarization-coreml"
COMMIT="1ed7a662fdc7109e36d822db793ee6eebdaf8594"
# FluidAudio busca <directorio>/speaker-diarization/<modelo>: el nombre del repo SIN
# "-coreml" (Repo.folderName). Con el nombre del repo tal cual, en modo sin red falla
# con modelMissing — lo cazó la prueba de CI, no el teléfono.
DEST="DiarizerModels/speaker-diarization"
MANIFEST="$PWD/scripts/diarizer-models.sha256"

if command -v sha256sum >/dev/null; then SHA="sha256sum"; else SHA="shasum -a 256"; fi

mkdir -p "$DEST"
cd "$DEST"
while read -r _ path; do
  [ -f "$path" ] && continue
  mkdir -p "$(dirname "$path")"
  curl -sSfL --retry 3 -o "$path.part" "https://huggingface.co/$REPO/resolve/$COMMIT/$path"
  mv "$path.part" "$path"
done < "$MANIFEST"
$SHA -c --quiet "$MANIFEST"
echo "modelos de hablantes verificados: $(wc -l < "$MANIFEST") ficheros"
