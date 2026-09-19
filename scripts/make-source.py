#!/usr/bin/env python3
"""Fuente de SideStore/AltStore para Eugenia: lo que hace aparecer el botón
"Update" en SideStore cuando hay versión nueva.

Se genera a partir del .ipa YA COMPILADO (versión, tamaño, permisos del Info.plist)
para que la fuente nunca diga algo distinto de lo que se instala. SideStore compara
los permisos declarados con los del .ipa: si faltara alguno, rechazaría instalar.

Uso: make-source.py Eugenia.ipa v0.2.0 > source.json
La publica el trabajo `release` de CI junto al .ipa; URL estable:
  https://github.com/siemprecreando/eugenia/releases/latest/download/source.json
"""
import json
import os
import plistlib
import sys
import zipfile
from datetime import datetime, timezone

REPO = "siemprecreando/eugenia"
BUNDLE_ID = "com.eugenia.app"


def main() -> None:
    ipa, tag = sys.argv[1], sys.argv[2]
    with zipfile.ZipFile(ipa) as z:
        info_name = next(n for n in z.namelist()
                         if n.startswith("Payload/") and n.endswith(".app/Info.plist") and n.count("/") == 2)
        info = plistlib.loads(z.read(info_name))

    version = info["CFBundleShortVersionString"]
    if tag.lstrip("v") != version:
        sys.exit(f"la etiqueta {tag} no coincide con la versión del .ipa {version}")
    privacy = {k: v for k, v in info.items() if k.startswith("NS") and k.endswith("UsageDescription")}

    entitlements_path = os.path.join(os.path.dirname(__file__), "..", "Eugenia", "Resources", "Eugenia.entitlements")
    with open(entitlements_path, "rb") as f:
        entitlements = sorted(plistlib.load(f).keys())

    source = {
        "name": "Eugenia",
        "identifier": "com.eugenia.source",
        "subtitle": "Reuniones grabadas, transcritas y resumidas en el iPhone",
        "website": f"https://github.com/{REPO}",
        "apps": [{
            "name": "Eugenia",
            "bundleIdentifier": BUNDLE_ID,
            "developerName": "Sergio",
            "subtitle": "Graba, transcribe y resume reuniones sin sacar nada del iPhone.",
            "localizedDescription": "Graba reuniones, las transcribe, separa quién habla y las resume "
                                    "con Apple Intelligence. Todo se procesa en el iPhone.",
            "iconURL": f"https://raw.githubusercontent.com/{REPO}/main/Eugenia/Resources/"
                       "Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png",
            "tintColor": "#3C6FF5",
            "category": "productivity",
            "versions": [{
                "version": version,
                "buildVersion": str(info.get("CFBundleVersion", "1")),
                "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "localizedDescription": f"Eugenia {version}",
                "downloadURL": f"https://github.com/{REPO}/releases/download/{tag}/Eugenia.ipa",
                "size": os.path.getsize(ipa),
                "minOSVersion": str(info.get("MinimumOSVersion", "26.0")),
            }],
            "appPermissions": {"entitlements": entitlements, "privacy": privacy},
        }],
        "news": [],
    }
    json.dump(source, sys.stdout, ensure_ascii=False, indent=2)
    print()


if __name__ == "__main__":
    main()
