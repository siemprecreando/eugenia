#!/usr/bin/env bash
# El bucle de pruebas Linux -> iPhone -> Linux. Plan, sección 6.5.
#
#   ./scripts/devtest.sh smoke      solo comprueba que el bucle funciona
#   ./scripts/devtest.sh asr        corre suites/asr.json
#
# Sale con código != 0 si algún caso falla. Eso es lo que permite iterar
# (cambiar -> compilar -> probar -> leer el fallo) sin tocar el teléfono.
set -uo pipefail

SUITE="${1:-smoke}"
# El nombre entra en una ruta: se valida antes de usarlo, aunque sea herramienta local.
if ! printf '%s' "$SUITE" | grep -qE '^[A-Za-z0-9_-]{1,40}$'; then
  echo "Nombre de suite no válido: '$SUITE' (solo letras, dígitos, guion y guion bajo)" >&2
  exit 2
fi
BUNDLE="${EUGENIA_BUNDLE:-com.eugenia.app}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$ROOT/run/$RUN_ID"
TIMEOUT="${EUGENIA_TIMEOUT:-600}"
AFC="$ROOT/scripts/afc.py"

mkdir -p "$RUN_DIR"
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m    %s\033[0m\n' "$*"; }
fail() { printf '\033[31m    %s\033[0m\n' "$*"; }

cleanup() {
  if [ -n "${SYSLOG_PID:-}" ] && kill -0 "$SYSLOG_PID" 2>/dev/null; then
    kill "$SYSLOG_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- 1. dispositivo
say "1/7 · Dispositivo"
if ! pymobiledevice3 usbmux list >/dev/null 2>&1; then
  fail "No se ve el iPhone. ¿Cable? ¿Desbloqueado? ¿usbmuxd corriendo?"
  fail "Si es la primera vez: ./scripts/setup-device.sh"
  exit 2
fi

if ! pymobiledevice3 apps list 2>/dev/null | grep -q "$BUNDLE"; then
  fail "La app $BUNDLE no está instalada en el teléfono."
  fail "Instálala con SideStore desde la Release de GitHub (plan 6.2), y comprueba"
  fail "que la FIRMA NO HA CADUCADO: con Apple ID gratuito dura 7 días."
  exit 2
fi
echo "    ok: $BUNDLE instalada"

# ------------------------------------------------------------------- 2. syslog
say "2/7 · Capturando syslog en segundo plano"
pymobiledevice3 syslog live > "$RUN_DIR/syslog.txt" 2>"$RUN_DIR/syslog.err" &
SYSLOG_PID=$!
sleep 2
if ! kill -0 "$SYSLOG_PID" 2>/dev/null; then
  warn "No se pudo capturar el syslog. Se sigue: el informe JSON es autosuficiente."
  warn "Detalle en $RUN_DIR/syslog.err"
  SYSLOG_PID=""
else
  echo "    ok: $RUN_DIR/syslog.txt"
fi

# ------------------------------------------------------------- 3. empujar suite
say "3/7 · Enviando el plan de pruebas"
SUITE_FILE="$ROOT/suites/$SUITE.json"
if [ ! -f "$SUITE_FILE" ]; then
  fail "No existe $SUITE_FILE"
  exit 2
fi

# Borrar informes anteriores ANTES de lanzar. Sin esto, si la app no llegara a
# escribir uno nuevo, el paso 5 se traería el de la ejecución anterior y daría un
# PASS falso: el peor fallo que puede tener un banco de pruebas.
STALE=$(python3 "$AFC" ls "/Documents/diagnostics" 2>/dev/null | grep '^report-' || true)
if [ -n "$STALE" ]; then
  echo "    limpiando $(echo "$STALE" | wc -l) informe(s) anterior(es)"
  echo "$STALE" | while read -r old_report; do
    python3 "$AFC" rm "/Documents/diagnostics/$old_report" >/dev/null 2>&1 || true
  done
fi
if ! python3 "$AFC" push "$SUITE_FILE" "/Documents/diagnostics/run.json"; then
  fail "No se pudo escribir en el contenedor de la app."
  fail "Causas típicas: la app instalada es Release (UIFileSharingEnabled=NO), o la"
  fail "ruta de importación de pymobiledevice3 cambió. Ver scripts/afc.py."
  exit 2
fi

# ------------------------------------------------------------------ 4. lanzar
say "4/7 · Lanzando la app"
if ! pymobiledevice3 developer dvt launch "$BUNDLE" >"$RUN_DIR/launch.txt" 2>&1; then
  warn "dvt launch falló. Modo degradado: ABRE LA APP A MANO en el teléfono."
  warn "El resto del bucle funciona igual — el disparo es un fichero, no un argumento."
  warn "Detalle en $RUN_DIR/launch.txt"
fi

# ------------------------------------------------- 5. esperar y traer el informe
say "5/7 · Esperando el informe (máx. ${TIMEOUT}s)"
REPORT=""
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  CANDIDATE=$(python3 "$AFC" ls "/Documents/diagnostics" 2>/dev/null | grep '^report-' | tail -1 || true)
  if [ -n "$CANDIDATE" ]; then
    if python3 "$AFC" pull "/Documents/diagnostics/$CANDIDATE" "$RUN_DIR/report.json" >/dev/null 2>&1; then
      REPORT="$RUN_DIR/report.json"
      python3 "$AFC" rm "/Documents/diagnostics/$CANDIDATE" >/dev/null 2>&1 || true
      break
    fi
  fi
  sleep 3
  ELAPSED=$((ELAPSED + 3))
  printf '\r    %ss…' "$ELAPSED"
done
printf '\n'

if [ -z "$REPORT" ]; then
  fail "No llegó ningún informe en ${TIMEOUT}s."
  fail "Mira $RUN_DIR/syslog.txt: si no hay líneas 'EV suite.start', la app no llegó"
  fail "a ver el run.json — o no arrancó, o es una build Release sin DiagnosticsRunner."
  exit 3
fi

# ---------------------------------------------------------------- 6. artefactos
say "6/7 · Trayendo artefactos y crashes"
python3 - "$REPORT" "$RUN_DIR" "$AFC" <<'PY'
import json, subprocess, sys
import os, re

report, run_dir, afc = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(report))

# SEGURIDAD — los nombres de artefacto vienen DEL DISPOSITIVO. Aunque hoy los escriba
# nuestra propia app, cruzan una frontera de confianza: son datos, no rutas de fiar.
# Sin este filtro, un artefacto llamado "../../../.ssh/authorized_keys" escribiría
# fuera del directorio de la ejecución, en el portátil.
SAFE = re.compile(r"^[A-Za-z0-9._-]{1,120}$")

for case in data.get("cases", []):
    for art in case.get("artifacts", []):
        name = os.path.basename(str(art))
        if not SAFE.match(name) or name in (".", ".."):
            print(f"    ARTEFACTO IGNORADO por nombre no seguro: {art!r}")
            continue
        target = os.path.join(run_dir, name)
        if os.path.relpath(target, run_dir).startswith(".."):
            print(f"    ARTEFACTO IGNORADO por salir del directorio: {art!r}")
            continue
        # "python3" y no sys.executable: es el mismo intérprete que usan los demás
        # pasos, y el que tiene instalado pymobiledevice3.
        subprocess.run(["python3", afc, "pull",
                        f"/Documents/diagnostics/{name}", target],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY
pymobiledevice3 crash pull "$RUN_DIR/crashes" >/dev/null 2>&1 && echo "    crashes en $RUN_DIR/crashes" || echo "    sin crashes nuevos"

# -------------------------------------------------------------------- 7. leer
say "7/7 · Resultado"
python3 - "$REPORT" "$RUN_DIR/syslog.txt" <<'PY'
import json, sys, datetime, os

report_path, syslog_path = sys.argv[1], sys.argv[2]
d = json.load(open(report_path))

run, env, summary = d["run"], d["env"], d["summary"]
print(f"    dispositivo {run['device']} · iOS {run['os']} · commit {run['commit'][:8]}")
battery = env["batteryLevel"]
battery_text = f"{battery:.0%}" if battery >= 0 else "n/d"
print(f"    IA {env['modelAvailability']} · térmica {env['thermalState']} "
      f"· batería {battery_text} · libre {env['freeDiskMB']} MB")

# Regla del plan 6.5: si arranca por encima de nominal, los números no son comparables.
if env["thermalState"].lower() not in ("nominal",):
    print(f"\n    AVISO: la suite arrancó en estado térmico '{env['thermalState']}'.")
    print("    Los tiempos y el consumo NO son comparables con otras ejecuciones.")

print()
for c in d["cases"]:
    icon = {"pass": "OK  ", "fail": "FALLA", "skipped": "salta", "error": "ERROR"}.get(c["status"], "?")
    print(f"    [{icon}] {c['id']}")
    if c["status"] in ("fail", "error", "skipped") and c.get("message"):
        print(f"            {c['message']}")
    if c["status"] == "fail":
        for k, v in sorted(c["metrics"].items()):
            exp = c["expected"].get(k)
            mark = ""
            if exp:
                if exp.get("max") is not None and v > exp["max"]: mark = f"  <-- supera max {exp['max']}"
                if exp.get("min") is not None and v < exp["min"]: mark = f"  <-- por debajo de min {exp['min']}"
            print(f"            {k} = {v:.3f}{mark}")
        # Recorte del syslog por la ventana temporal del caso: en vez de dejar
        # 40.000 líneas, se imprimen los segundos exactos del fallo.
        lw = c.get("logWindow")
        if lw and os.path.exists(syslog_path):
            try:
                fmt = "%Y-%m-%dT%H:%M:%SZ"
                start = datetime.datetime.strptime(lw["from"][:19] + "Z", fmt)
                end = datetime.datetime.strptime(lw["to"][:19] + "Z", fmt)
                lines = [l for l in open(syslog_path, errors="ignore")
                         if lw["category"] in l or "EV " in l or "ER " in l]
                if lines:
                    print(f"            --- syslog ({lw['category']}, {start.time()}–{end.time()}) ---")
                    for l in lines[-25:]:
                        print("            " + l.rstrip()[:160])
            except Exception:
                pass

print(f"\n    {summary['passed']} OK · {summary['failed']} fallos · {summary['skipped']} saltados")
sys.exit(1 if summary["failed"] else 0)
PY
STATUS=$?
echo
echo "    Todo en: $RUN_DIR"
exit $STATUS
