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
import asyncio
import inspect

BUNDLE = os.environ.get("EUGENIA_BUNDLE", "com.eugenia.app")


async def _(value):
    """Espera `value` si es awaitable. pymobiledevice3 pasó a API asíncrona en 2026
    (create_using_usbmux, HouseArrestService.create y las operaciones AFC son
    corrutinas); así el script vale para la versión vieja y la nueva."""
    return await value if inspect.isawaitable(value) else value


async def connect():
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
    lockdown = await _(create_using_usbmux())
    if hasattr(HouseArrestService, "create"):          # API nueva
        return await HouseArrestService.create(lockdown, bundle_id=BUNDLE)
    return HouseArrestService(lockdown=lockdown, bundle_id=BUNDLE)  # API vieja


async def resolve(afc, path):
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
        root = set(await _(afc.listdir("/")))
    except Exception:
        return path

    at_container = "Documents" in root
    if at_container and not path.startswith("/Documents"):
        return "/Documents" + path
    if not at_container and path.startswith("/Documents"):
        stripped = path[len("/Documents"):]
        return stripped if stripped.startswith("/") else "/" + stripped
    return path


async def cmd_ls(afc, args):
    for name in await _(afc.listdir(await resolve(afc, args.remote))):
        print(name)


async def cmd_pull(afc, args):
    data = await _(afc.get_file_contents(await resolve(afc, args.remote)))
    os.makedirs(os.path.dirname(os.path.abspath(args.local)) or ".", exist_ok=True)
    with open(args.local, "wb") as fh:
        fh.write(data)
    print(f"{args.remote} -> {args.local} ({len(data)} bytes)")


async def cmd_push(afc, args):
    with open(args.local, "rb") as fh:
        data = fh.read()
    remote = await resolve(afc, args.remote)
    # Crear los directorios intermedios: la primera vez, Documents/diagnostics/ no
    # existe todavía en el teléfono y set_file_contents no lo crea solo.
    parts = remote.strip("/").split("/")[:-1]
    for i in range(len(parts)):
        try:
            await _(afc.makedirs("/" + "/".join(parts[: i + 1])))
        except Exception:
            pass
    await _(afc.set_file_contents(remote, data))
    print(f"{args.local} -> {args.remote} ({len(data)} bytes)")


async def cmd_rm(afc, args):
    await _(afc.rm(await resolve(afc, args.remote)))
    print(f"borrado {args.remote}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("ls");   p.add_argument("remote", nargs="?", default="/");        p.set_defaults(fn=cmd_ls)
    p = sub.add_parser("pull"); p.add_argument("remote"); p.add_argument("local");       p.set_defaults(fn=cmd_pull)
    p = sub.add_parser("push"); p.add_argument("local");  p.add_argument("remote");      p.set_defaults(fn=cmd_push)
    p = sub.add_parser("rm");   p.add_argument("remote");                                p.set_defaults(fn=cmd_rm)

    args = parser.parse_args()
    asyncio.run(run(args))


async def run(args):
    afc = await connect()
    try:
        await args.fn(afc, args)
    finally:
        close = getattr(afc, "aclose", None) or getattr(afc, "close", None)
        if close:
            await _(close())


if __name__ == "__main__":
    main()
