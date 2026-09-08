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


def cmd_ls(afc, args):
    for name in afc.listdir(args.remote):
        print(name)


def cmd_pull(afc, args):
    data = afc.get_file_contents(args.remote)
    os.makedirs(os.path.dirname(os.path.abspath(args.local)) or ".", exist_ok=True)
    with open(args.local, "wb") as fh:
        fh.write(data)
    print(f"{args.remote} -> {args.local} ({len(data)} bytes)")


def cmd_push(afc, args):
    with open(args.local, "rb") as fh:
        data = fh.read()
    afc.set_file_contents(args.remote, data)
    print(f"{args.local} -> {args.remote} ({len(data)} bytes)")


def cmd_rm(afc, args):
    afc.rm(args.remote)
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
