# Eugenia — código

App de iPhone. Graba, transcribe y resume reuniones **sin que el audio salga del
dispositivo**. Plan completo en [`../plan-summary-ai-iphone.md`](../plan-summary-ai-iphone.md).

- **Dispositivo de destino:** un iPhone 17e con iOS 26.
- **Se compila** en GitHub Actions (no hay Mac), **sin firmar**.
- **Se instala** con SideStore, que firma en el propio teléfono con un Apple ID gratuito.
- **Se prueba** desde Linux con `pymobiledevice3`, contra el teléfono real.

> ### Estado: NUNCA COMPILADO
>
> No hay Mac en el equipo, así que **este código no ha pasado por un compilador
> todavía**. Lo verificado hasta ahora es: sintaxis de los shell scripts (`bash -n`),
> `afc.py` (`py_compile`), y que los YAML y JSON parsean. El primer `git push` a un
> repositorio con Actions es lo que dirá la verdad, y va a hacer falta más de una
> ronda de correcciones. Los puntos con más probabilidad de fallar están marcados en
> el propio código; el principal son los nombres de `AssetInventory` en
> `Core/Transcriber.swift`.

---

## Poner la app en el teléfono

**1. Repositorio.** Crea uno en GitHub y sube esta carpeta.

```bash
cd app
git init && git add . && git commit -m "Eugenia: esqueleto de la Fase 1"
git remote add origin git@github.com:<tu-usuario>/eugenia.git
git push -u origin main
```

> Si lo haces **público**, los minutos de macOS son gratis e ilimitados. Si lo haces
> **privado**, tienes ~200 min de macOS al mes (multiplicador ×10 sobre los 2.000 del
> plan Free): unos 15–20 builds. Por eso el workflow solo se dispara en `main`, en
> tags y a mano. Ver plan 6.3.

**2. Compilar.** El push lanza Actions. Al terminar, descarga `Eugenia.ipa` del
artefacto, o crea un tag (`git tag v0.1.0 && git push --tags`) para que salga como
Release, que es lo que SideStore sabe instalar desde una URL.

**3. Instalar.** SideStore en el iPhone → añadir el `.ipa`. Recuerda que la firma
**caduca a los 7 días** y SideStore la refresca solo.

**4. Conectar el teléfono a esta máquina, una vez:**

```bash
./scripts/setup-device.sh
```

**5. Probar:**

```bash
./scripts/devtest.sh smoke     # ¿funciona el bucle entero?
./scripts/devtest.sh asr       # la suite de ASR sobre el corpus
```

`smoke` no necesita audio ni LLM: solo comprueba que Linux puede empujar un plan de
pruebas, lanzar la app, y recuperar el informe. **Es el spike 8 del plan y es lo
primero que tiene que estar verde.** Si eso no funciona, nada más importa.

Para la suite `asr` hay que empujar antes el audio del corpus:

```bash
python3 scripts/afc.py push corpus/es-sala-4personas-2m.m4a \
        /Documents/diagnostics/audio/es-sala-4personas-2m.m4a
```

---

## Qué hay dentro

```
project.yml                  proyecto XcodeGen (no hay .pbxproj que mantener a mano)
.github/workflows/build.yml  CI: comprueba entitlements, compila sin firmar, empaqueta
scripts/
  check-entitlements.py      rechaza iCloud / App Groups / push antes de compilar
  setup-device.sh            la conexión de una sola vez
  devtest.sh                 el bucle: lanzar, observar, recoger, diagnosticar
  afc.py                     acceso a Documents/ de la app por house_arrest
suites/                      planes de prueba que consume el DiagnosticsRunner
Eugenia/
  Core/Log.swift             os_log disciplinado. Ojo con la redacción por defecto
  Core/AudioSource.swift     micrófono | fichero — el requisito que hace probable la app
  Core/Transcriber.swift     SpeechAnalyzer + SpeechTranscriber
  Core/Summarizer.swift      FoundationModels, map-reduce con acarreo de estado
  Core/Recorder.swift        orquestación; el audio a disco SIEMPRE primero
  Core/Store.swift           persistencia en JSON + ficheros
  Diagnostics/               el ejecutor de pruebas que vive dentro de la app
  UI/                        tres pantallas: biblioteca, grabación, detalle
```

## Decisiones que conviene conocer antes de tocar nada

**`SWIFT_VERSION` es 5.0, no 6.** El plan pide Swift 6 con concurrencia estricta, y
ahí es donde hay que llegar. Pero el primer objetivo es un build verde que se pueda
instalar; pelearse a ciegas con errores de aislamiento de actores, sin compilador
local y a 10 minutos por intento en CI, es la peor forma de gastar los 200 minutos
del mes. Se sube a 6 en cuanto el ciclo esté cerrado. Está anotado en `project.yml`.

**El disparo de las pruebas es un fichero, no un argumento.** Linux escribe
`Documents/diagnostics/run.json` y luego lanza la app; la app lo ve al arrancar. Así
el bucle no depende de que `dvt launch` sepa pasar argumentos — que es una de las
incógnitas del spike 8. Si `dvt launch` falla, `devtest.sh` te dice que abras la app
a mano y el resto sigue funcionando.

**`UIFileSharingEnabled` solo en Debug.** Es lo que abre `Documents/` por AFC y hace
posible el canal de resultados. También expondría el audio de las reuniones en la app
Archivos, así que en Release vale `NO` y `check-entitlements.py` lo comprueba.

**El audio se escribe a disco antes de ir al ASR.** En `Recorder.ingest`, y en ese
orden a propósito: si falla la escritura se para la grabación; si falla el ASR, la
grabación continúa. El audio es sagrado (plan 5.1).

**Nada de `print`.** Todo por `Log`, porque el syslog es lo que se lee desde Linux.
Y `os_log` redacta las interpolaciones por defecto: sin `privacy: .public` verías
`<private>`. Los helpers de `Log` ya lo marcan. El contenido de las reuniones no se
registra nunca, ni en Debug.
