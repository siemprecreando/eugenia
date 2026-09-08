#!/usr/bin/env python3
"""Rechaza los entitlements que la firma con Apple ID gratuito NO admite.

Plan, secciones 6.2 y 6.4.

Si alguna de estas claves llega al bundle, la app COMPILA pero NO INSTALA, y el
error que devuelve SideStore no dice cuál es. Mejor fallar aquí, en 2 segundos.

POR QUÉ NO ES UN grep: la primera versión de esta comprobación era `grep -E` sobre
los ficheros, y se detectaba a sí misma — el comentario del .entitlements que
explica qué claves están prohibidas las contiene literalmente. Aquí se parsea el
plist y se miran las CLAVES REALES, que es lo que de verdad importa.

Sin dependencias externas: plistlib es de la biblioteca estándar, y project.yml se
mira como texto porque no lleva comentarios con esos nombres.
"""
import os
import plistlib
import re
import sys

FORBIDDEN = {
    "com.apple.developer.icloud-services":       "CloudKit / iCloud",
    "com.apple.developer.icloud-container-identifiers": "contenedores de iCloud",
    "com.apple.developer.ubiquity-kvstore-identifier":  "almacén clave-valor de iCloud",
    "com.apple.security.application-groups":     "App Groups (widgets con datos, extensiones)",
    "aps-environment":                           "notificaciones push / APNs",
    "com.apple.developer.applesignin":           "Sign in with Apple",
    "com.apple.developer.associated-domains":    "dominios asociados",
    "com.apple.developer.healthkit":             "HealthKit",
    "com.apple.developer.in-app-payments":       "Apple Pay",
}

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
problems = []


def walk_keys(obj, path=""):
    """Todas las claves de un plist, incluidas las anidadas."""
    if isinstance(obj, dict):
        for key, value in obj.items():
            yield key, f"{path}/{key}" if path else key
            yield from walk_keys(value, f"{path}/{key}" if path else key)
    elif isinstance(obj, list):
        for i, value in enumerate(obj):
            yield from walk_keys(value, f"{path}[{i}]")


def check_plists():
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in (".git", "build", "Payload", "run")]
        for name in filenames:
            if not name.endswith((".plist", ".entitlements")):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, ROOT)
            try:
                with open(full, "rb") as fh:
                    data = plistlib.load(fh)
            except Exception as exc:
                problems.append(f"{rel}: no es un plist válido ({exc})")
                continue
            for key, where in walk_keys(data):
                if key in FORBIDDEN:
                    problems.append(f"{rel}: clave '{where}' — {FORBIDDEN[key]}")


def check_project_yml():
    """project.yml puede inyectar entitlements desde `properties:`."""
    path = os.path.join(ROOT, "project.yml")
    if not os.path.exists(path):
        return
    text = open(path, encoding="utf-8").read()
    for key, label in FORBIDDEN.items():
        if re.search(rf"^\s*{re.escape(key)}\s*:", text, re.MULTILINE):
            problems.append(f"project.yml: declara '{key}' — {label}")

    # UIFileSharingEnabled abre Documents/ por AFC: imprescindible para el banco de
    # pruebas (6.5) e inaceptable en Release, donde expondría el audio de las
    # reuniones en la app Archivos.
    for name, body in yaml_blocks(text, "Release"):
        if re.search(r'EUGENIA_FILE_SHARING:\s*"?YES"?', body):
            problems.append("project.yml: EUGENIA_FILE_SHARING=YES en el bloque "
                            f"{name}. En Release expondría el audio de las reuniones "
                            "en la app Archivos. Ver plan 6.5.")


def yaml_blocks(text, key):
    """Devuelve (nombre, cuerpo) de cada bloque `key:` usando la indentación.

    Sin PyYAML a propósito: los runners de macOS de GitHub no lo traen garantizado
    y esta comprobación tiene que correr antes que ningún `brew install`.
    """
    lines = text.splitlines()
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped != f"{key}:":
            continue
        indent = len(line) - len(line.lstrip())
        body = []
        for following in lines[i + 1:]:
            if not following.strip():
                body.append(following)
                continue
            if len(following) - len(following.lstrip()) <= indent:
                break
            body.append(following)
        yield key, "\n".join(body)


check_plists()
check_project_yml()

if problems:
    print("ERROR: configuración que la firma gratuita no admite (plan 6.2):\n")
    for p in problems:
        print(f"  · {p}")
    print("\nEstas claves exigen la membresía de 99 EUR/año. Quítalas, o paga la cuenta.")
    sys.exit(1)

print("OK: sin entitlements de pago, y UIFileSharingEnabled confinado a Debug.")
