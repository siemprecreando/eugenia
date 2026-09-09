#!/usr/bin/env python3
"""Acceso a Documents/ de la app desde Linux, por house_arrest/AFC.

Plan, sección 6.5, canal de RESULTADOS.

Se usa la API de Python de pymobiledevice3 en lugar de su CLI a propósito: la
invocación exacta de `pymobiledevice3 apps afc` cambia entre versiones y es
interactiva, mientras que estas clases son estables y se pueden guionizar.

Requiere `UIFileSharingEnabled` en el Info.plist, que solo está en Debug.

SI ESTO FALLA CON ImportError, es el único fichero que hay que tocar: la ruta de
importación de pymobiledevice3 habrá cambiado. Es exactamente una de las incógnitas
que el spike 8 del plan tiene que cerrar.
"""
import sys
import os
import argparse

BUNDLE = os.environ.get("EUGENIA_BUNDLE", "com.eugenia.app")


def connect():
    try:
        from pymobiledevice3.lockdown import create_using_usbmux
        from pymobiledevice3.services.house_arrest import HouseArrestService
    except ImportError as exc:
        sys.exit(
            f"No se pudo importar pymobiledevice3 ({exc}).\n"
            "  pip install --user pymobiledevice3\n"
            "Si el paquete está instalado, la ruta de importación ha cambiado: "
            "ajusta scripts/afc.py (spike 8 del plan)."
        )
    lockdown = create_using_usbmux()
    return HouseArrestService(lockdown=lockdown, bundle_id=BUNDLE)


def resolve(afc, path):
    """Normaliza la ruta según lo que AFC esté sirviendo de raíz.

    house_arrest puede montar la RAÍZ DEL CONTENEDOR (y entonces la ruta correcta es
    /Documents/x) o directamente la carpeta Documents (y entonces es /x). Cuál de las
    dos depende de la versión de pymobiledevice3 y del modo de vendido, y equivocarse
    da un "fichero no encontrado" que no explica nada.

    En vez de adivinar, se mira: si la raíz contiene una entrada 'Documents', estamos
    en el contenedor. Es una llamada y ahorra la peor sesión de depuración del spike 8.
    """
    path = "/" + path.strip("/")
    try:
        root = set(afc.listdir("/"))
    except Exception:
        return path

    at_container = "Documents" in root
    if at_container and not path.startswith("/Documents"):
        return "/Documents" + path
    if not at_container and path.startswith("/Documents"):
        stripped = path[len("/Documents"):]
        return stripped if stripped.startswith("/") else "/" + stripped
    return path


def cmd_ls(afc, args):
    for name in afc.listdir(resolve(afc, args.remote)):
        print(name)


def cmd_pull(afc, args):
    data = afc.get_file_contents(resolve(afc, args.remote))
    os.makedirs(os.path.dirname(os.path.abspath(args.local)) or ".", exist_ok=True)
    with open(args.local, "wb") as fh:
        fh.write(data)
    print(f"{args.remote} -> {args.local} ({len(data)} bytes)")


def cmd_push(afc, args):
    with open(args.local, "rb") as fh:
        data = fh.read()
    remote = resolve(afc, args.remote)
    # Crear los directorios intermedios: la primera vez, Documents/diagnostics/ no
    # existe todavía en el teléfono y set_file_contents no lo crea solo.
    parts = remote.strip("/").split("/")[:-1]
    for i in range(len(parts)):
        try:
            afc.makedirs("/" + "/".join(parts[: i + 1]))
        except Exception:
            pass
    afc.set_file_contents(remote, data)
    print(f"{args.local} -> {args.remote} ({len(data)} bytes)")


def cmd_rm(afc, args):
    afc.rm(resolve(afc, args.remote))
    print(f"borrado {args.remote}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("ls");   p.add_argument("remote", nargs="?", default="/");        p.set_defaults(fn=cmd_ls)
    p = sub.add_parser("pull"); p.add_argument("remote"); p.add_argument("local");       p.set_defaults(fn=cmd_pull)
    p = sub.add_parser("push"); p.add_argument("local");  p.add_argument("remote");      p.set_defaults(fn=cmd_push)
    p = sub.add_parser("rm");   p.add_argument("remote");                                p.set_defaults(fn=cmd_rm)

    args = parser.parse_args()
    afc = connect()
    args.fn(afc, args)


if __name__ == "__main__":
    main()
