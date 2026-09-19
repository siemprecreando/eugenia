#!/usr/bin/env python3
"""Audio de prueba con texto conocido, para el iPhone (ASR + hablantes + resumen).

Solo en macOS (usa `say` y `afconvert`): lo corre CI y lo publica como artefacto
`corpus-tts`. Dos voces DISTINTAS por idioma (una femenina y otra masculina si hay),
con un silencio entre turnos. Escribe también suites/tts.json con las transcripciones
de referencia, para que el WER se mida contra lo que se leyó de verdad.

Uso:  make-tts-corpus.py <salida>          (macOS: audio + suite)
      make-tts-corpus.py --suite-only      (cualquier sistema: solo suites/tts.json)
"""
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = json.load(open(os.path.join(HERE, "tts-corpus.json"), encoding="utf-8"))


def suite() -> dict:
    cases = []
    for c in CORPUS["cases"]:
        cases.append({
            "id": c["id"], "audioFile": c["file"], "language": c["language"], "kind": c["kind"],
            "referenceTranscript": " ".join(t for _, t in c["turns"]),
            "expected": c["expected"],
        })
    return {"suite": "tts", "cases": cases}


def voices(lang: str) -> list[str]:
    """Voces instaladas para el idioma; primero las de calidad mejorada."""
    out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True, check=True).stdout
    found = []
    for line in out.splitlines():
        m = re.match(r"^(.+?)\s+([a-z]{2}_[A-Z]{2})\s+#", line)
        if m and m.group(2).startswith(lang):
            found.append(m.group(1).strip())
    preferred = {"es": ["Paulina", "Jorge", "Mónica", "Juan", "Diego"],
                 "en": ["Samantha", "Daniel", "Alex", "Fred", "Karen"]}[lang]
    ordered = [v for v in preferred if v in found] + [v for v in found if v not in preferred]
    # "Eddy (Spanish (Spain))" y "Eddy (Spanish (Mexico))" son el MISMO timbre: con dos
    # así la separación de hablantes vería una sola persona. Uno por nombre base.
    distinct, seen = [], set()
    for v in ordered:
        base = v.split(" (")[0]
        if base not in seen:
            seen.add(base)
            distinct.append(v)
    if len(distinct) < 2:
        sys.exit(f"hacen falta dos voces {lang} distintas; hay: {found}")
    return distinct[:2]


def main() -> None:
    suite_path = os.path.join(HERE, "..", "suites", "tts.json")
    with open(suite_path, "w", encoding="utf-8") as f:
        json.dump(suite(), f, ensure_ascii=False, indent=2)
        f.write("\n")
    if sys.argv[1:] == ["--suite-only"]:
        return
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    for c in CORPUS["cases"]:
        v = voices(c["language"])
        print(c["id"], "voces:", v)
        with tempfile.TemporaryDirectory() as tmp:
            parts = []
            for i, (who, text) in enumerate(c["turns"]):
                aiff = os.path.join(tmp, f"{i:02d}.aiff")
                # [[slnc 700]]: pausa entre turnos, como en una conversación.
                subprocess.run(["say", "-v", v[who], "-o", aiff, f"[[slnc 700]] {text}"], check=True)
                parts.append(aiff)
            # Concatenar a un único WAV y pasarlo a AAC (lo mismo que graba la app).
            wav = os.path.join(tmp, "all.wav")
            concat_afconvert(parts, wav)
            subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "32000", wav,
                            os.path.join(out_dir, c["file"])], check=True)
    print("corpus en", out_dir)


def concat_afconvert(parts: list[str], wav: str) -> None:
    """Sin sox: cada trozo a PCM 16 kHz mono y se unen los datos a mano."""
    import wave
    frames = []
    params = None
    for p in parts:
        tmp_wav = p + ".wav"
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", p, tmp_wav], check=True)
        with wave.open(tmp_wav, "rb") as w:
            params = params or w.getparams()
            frames.append(w.readframes(w.getnframes()))
    with wave.open(wav, "wb") as w:
        w.setparams(params)
        for f in frames:
            w.writeframes(f)


if __name__ == "__main__":
    main()
