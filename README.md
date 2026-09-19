# Eugenia — código

App de iPhone. Graba, transcribe y resume reuniones **sin que el audio salga del
dispositivo**. Plan completo en [`../plan-summary-ai-iphone.md`](../plan-summary-ai-iphone.md).

- **Dispositivo de destino:** un iPhone 17e con iOS 26.
- **Se compila** en GitHub Actions (no hay Mac), **sin firmar**.
- **Se instala** con SideStore, que firma en el propio teléfono con un Apple ID gratuito.
- **Se prueba** desde Linux con `pymobiledevice3`, contra el teléfono real.

> ### Estado (2026-09-18): v0.2.0 — todas las fases del plan implementadas
>
> - **En el iPhone:** v0.1.2 instalada con SideStore y `smoke` en verde. La v0.2.0 se
>   publica como Release cuando CI (compilación + 45 pruebas unitarias + 8 de
>   interfaz) está en verde.
> - **Repositorio PÚBLICO y build Debug**, a propósito y de forma temporal: se pasa a
>   privado y a Release cuando Sergio dé la app por probada.
> - **Qué hace la v0.2:** grabación robusta (se guarda cada 10 s, se reanuda tras
>   llamadas y cortes, recupera grabaciones interrumpidas), transcripción con marcas de
>   tiempo, **quién habla** (separación de hablantes y, si se activa, reconocimiento de
>   voces conocidas), resumen por plantillas con tareas que siguen a su dueño,
>   preguntas a una reunión o a todas, búsqueda, carpetas, exportar (texto, Markdown,
>   PDF, JSON) y copia cifrada, importar audio/vídeo/PDF/texto, Live Activity y botón
>   en el Centro de Control, atajos de Siri, bloqueo con Face ID, sugerencias desde el
>   calendario, interfaz en español e inglés.
> - **Nombres de hablantes (v0.2.1):** se ponen solos si alguien se presenta ("soy
>   Marta", "I'm Kevin") y, con Apple Intelligence, cuando a alguien le llaman por su
>   nombre y contesta. Nunca pisan un nombre puesto a mano. En la transcripción: tocar
>   el nombre lo cambia en toda la reunión (también en resumen y tareas); mantener
>   pulsada una frase permite atribuirla a otro hablante o a una persona nueva.
> - **Audio (v0.2.1):** por defecto NO se guarda. Se borra en cuanto se han
>   transcrito y separado los hablantes; quedan la transcripción con quién habló en
>   cada momento y el resumen. Ajustes › Gestión de espacio permite guardarlo
>   (nunca, 7/30/90 días, 1 año), y las favoritas lo conservan siempre.
> - **Sin probar en el teléfono:** resumen (hace falta activar Apple Intelligence),
>   separación de hablantes con audio real, y batería/temperatura en reuniones largas.
>
> El historial de cómo se llegó al primer build verde está en git.

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

**3. Instalar.**

*La primera vez, si no tienes SideStore todavía:* el `.ipa` está **sin firmar**, y
para poner la primera app en el teléfono hace falta algo que firme con tu Apple ID.
Desde Linux eso lo hace **iloader**, el instalador que recomienda SideStore:

```bash
./scripts/install-sidestore.sh     # extrae iloader en ~/Applications y lo abre
```

Conecta el iPhone por cable antes. En la ventana de iloader pones el Apple ID —**se
recomienda una cuenta secundaria**— e instala SideStore con su fichero de
emparejamiento.

> **Trampas encontradas en la primera instalación (2026-09-18):**
> - **Altcon ya no sirve.** Desde principios de septiembre de 2026 Apple responde
>   `503` al login de AltServer-Linux (`ALTAppleAPI (17)`), también con los
>   servidores de anisette de SideStore. Por eso el script usa iloader (≥ 2.3.2 trae
>   el arreglo). Además Altcon no ofrecía instalar nada: dejaba una shell `root@…`.
> - El **AppImage** de iloader abre una ventana en blanco en Bazzite
>   (`EGL_BAD_PARAMETER`: su WebKit empaquetado choca con el Mesa del sistema).
>   El script extrae el **RPM** y usa el WebKit del sistema, que sí funciona.
> - El servidor de anisette por defecto de AltServer-Linux (armconverter.com) está
>   caído (502).
> - El **modo de desarrollador** no aparece en Ajustes hasta que algo lo revela.
>   Desde Linux: `pymobiledevice3 amfi reveal-developer-mode`. En Bazzite
>   pymobiledevice3 no compila con `pip --user` (faltan cabeceras); se usa desde un
>   contenedor `python:3.12` montando `/var/run/usbmuxd` y `/var/lib/lockdown`.

*Ya con SideStore instalado:* instala o actualiza directamente desde

```
https://github.com/siemprecreando/eugenia/releases/latest/download/Eugenia.ipa
```

**Actualizar con el botón "Update" de SideStore.** Cada Release publica también una
*fuente* de SideStore. Se añade una vez en SideStore › Sources › **+**:

```
https://github.com/siemprecreando/eugenia/releases/latest/download/source.json
```

A partir de ahí, una versión nueva aparece como **Update** en SideStore y se
actualiza conservando las reuniones. La genera `scripts/make-source.py` a partir del
propio `.ipa` (versión, tamaño, permisos), así que no puede decir algo distinto de lo
que se instala.

**Comprobar que un `.ipa` salió de este repositorio** (desde v0.2.0):
`gh attestation verify Eugenia.ipa -R siemprecreando/eugenia`.

Recuerda que la firma **caduca a los 7 días** y SideStore la refresca sola, siempre
que tenga el VPN local (LocalDevVPN) configurado.

**4. Probar** (sin instalar nada en esta máquina: pymobiledevice3 corre en un
contenedor, `scripts/devtools/`, que se construye solo la primera vez):

```bash
./scripts/devtest-container.sh smoke     # ¿funciona el bucle entero?
./scripts/devtest-container.sh asr       # la suite de ASR sobre el corpus
```

El script detecta solo el identificador con el que SideStore instaló la app
(`com.eugenia.app.<TEAMID>`). `setup-device.sh` queda para máquinas con
pymobiledevice3 nativo; aquí no hace falta: el modo desarrollador se activó con
`amfi reveal-developer-mode` y la imagen de desarrollador la monta `devtest.sh`.

> **La "pantalla negra" (resuelta 2026-09-18, medida en el iPhone):** una app lanzada
> con `pymobiledevice3 developer dvt launch` queda viva y en primer plano pero SIN
> PINTAR (negro total, sin barra de estado) hasta que se cambia de app y se vuelve.
> Captura antes = app normal; 8 s y 30 s después del lanzamiento remoto = negro. No
> pasa al abrirla desde el icono ni al girar el teléfono. `devtest.sh` ahora cierra
> la app al terminar (`dvt kill`), así nunca se queda negra en la mano de Sergio.
>
> **Resumen probado en el iPhone (v0.2.1, Apple Intelligence activo):** la suite
> `llm` salía "OK" con 4 tareas, pero eran UNA (el presupuesto) partida en citas
> literales; el certificado y la propuesta a Delta no aparecían. El modelo reutilizaba
> el id "c1" del estado abierto para tareas nuevas. Desde v0.2.2 los ids los pone la
> app, la tarea se pide como acción y la suite exige las 3 tareas con responsable y
> estado (`expectedItems`). La prueba de arranque tampoco comprobaba su umbral.
>
> **Audio de prueba:** CI genera dos voces sintéticas con texto conocido (artefacto
> `corpus-tts-<sha>`). `gh run download <run> -n corpus-tts-<sha> -D dist/corpus-tts`
> y `./scripts/devtest-container.sh tts` lo empuja solo y mide WER y hablantes. Una
> suite con casos saltados por falta de audio ya NO sale verde.
>
> **Trampas del bucle de pruebas (2026-09-18):**
> - pymobiledevice3 pasó a **API asíncrona**; `afc.py` ya vale para las dos.
> - En iOS 17+ los servicios de desarrollador (lanzar la app, capturas) van por un
>   túnel. `remote tunneld` no encuentra el iPhone en Bazzite; **`--userspace`** sí,
>   sin root. Captura de pantalla: `pymobiledevice3 developer dvt screenshot --userspace x.png`.
> - `apps list | grep -q` con `pipefail` da **falso negativo** (SIGPIPE sobre ~1 MB).

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
project.yml                  proyecto XcodeGen: app + extensión de widgets (Live Activity, Control)
.github/workflows/build.yml  CI: entitlements, compila sin firmar, pruebas, capturas, Release en tags
scripts/                     instalar SideStore, bucle de pruebas contra el iPhone, icono
suites/                      planes de prueba que consume el DiagnosticsRunner
Shared/RecordingActivity.swift   lo que comparten app y widget (Live Activity, intents)
Widgets/                     Live Activity con Dynamic Island y el botón "Grabar" del Control Center
Eugenia/
  Core/Recorder.swift        máquina de estados de la grabación; el audio a disco SIEMPRE primero
  Core/AudioSource.swift     micrófono (perfiles, reanudación tras interrupciones) | fichero
  Core/AudioFileWriter.swift audio en trozos de 180 s: un corte no pierde más que eso
  Core/Transcriber.swift     SpeechAnalyzer + SpeechTranscriber, con marcas de tiempo
  Core/ProcessingQueue.swift cola persistente: transcribir → hablantes → resumir → indexar
  Core/Diarization.swift     quién habla (FluidAudio) y huellas de voz opcionales
  Core/Summarizer.swift      FoundationModels, map-reduce con puntos de control; plantillas
  Core/SearchIndex.swift     búsqueda por palabras + por significado
  Core/Store.swift           persistencia; protegida contra un índice corrupto
  Core/Models.swift          el modelo de datos (compatible hacia atrás con v0.1)
  Core/Exporter.swift        texto, Markdown, PDF, JSON "eugenia.note/1", archivo cifrado EUGX1
  Core/Backup.swift          copia y restauración (fusiona por id, no pisa)
  Core/Importer.swift        audio/vídeo, PDF (con OCR), texto
  Core/Services.swift        notificaciones, atajos (CRM), retención de audio
  System/                    App Intents, calendario, Face ID, Live Activity
  Diagnostics/               el ejecutor de pruebas que vive dentro de la app (solo Debug)
  UI/                        lista, grabación, detalle, preguntar, ajustes, bienvenida
  Resources/en.lproj/        traducción al inglés (el español es el idioma base)
```

## Qué se puede probar sin el teléfono, y qué no

CI corre en `macos-26` con simulador. Esto es lo medido, no lo supuesto:

| | Estado |
|---|---|
| Que la app compile y produzca un `.ipa` arm64 con dSYM | ✅ en cada push |
| Pruebas unitarias: WER, troceado, tareas, hablantes, búsqueda, exportar, cifrado, persistencia | ✅ 45 pruebas |
| Que la app **arranque** sin reventar | ✅ en el simulador |
| Que la app **se pueda usar**: lista, detalle, grabación, ajustes, búsqueda, preguntar, bienvenida, inglés | ✅ 8 pruebas de interfaz |
| **Ver la interfaz** desde Linux | ✅ capturas publicadas como artefacto |
| El bucle completo: empujar plan → lanzar → recoger informe | ✅ el contenedor del simulador hace de AFC |
| La traza `os_log` con `%{public}s` | ✅ legible desde fuera |
| **El resumen con `FoundationModels`** | ❌ **no fiable en CI** |
| ASR, diarización, micrófono, batería, térmica, jetsam | ❌ solo en el dispositivo |

### Ver la app sin el teléfono

`EugeniaUITests` arranca la app en el simulador, navega y deja capturas que CI publica
como artefacto `capturas-<sha>`. Se bajan con:

    gh run download <run-id> -n capturas-<sha> -D dist/capturas

Cubre el hueco entre *compila* y *se puede usar*: un `@EnvironmentObject` que falta
compila perfectamente y tira la app en el primer render. Lo que **no** cubre: audio,
transcripción y resumen. Eso es el teléfono.

> **Trampa (v0.2):** el simulador de CI arranca en **inglés**. Mientras la app solo
> estaba en español daba igual; con la traducción al inglés, las pruebas que buscan
> "Ajustes" o "Sin reuniones todavía" dejaron de encontrarlos. Las pruebas fijan el
> idioma con `-AppleLanguages (es)` y una prueba aparte comprueba el inglés.
> Y `upload-artifact` rechaza nombres con comillas o `:`: los adjuntos de XCTest los
> traen, así que el paso de extraer capturas los sanea.

Los datos de muestra (`--ui-demo`) viven en memoria y no tocan el disco. La reunión
larga es la del spike 4b, para que la captura del detalle enseñe si la pantalla sabe
representar un acuerdo que cambió de dueño.

### Lo que encontraron las capturas

Tres fallos que un build verde no ve, todos del run `34375999617`:

1. **El idioma del bundle (serio).** El `.ipa` publicado llevaba
   `CFBundleDevelopmentRegion: en` y ninguna localización. `Locale.current` se resuelve
   contra las localizaciones del Info.plist, **no** contra Ajustes: en un iPhone en
   español la app habría pedido el modelo de voz **inglés** para una reunión en español.
   Transcripción ilegible y sin ningún error visible. El síntoma que lo delató era
   cosmético —fechas en inglés en una interfaz en español— y el error de la captura de
   grabación decía `not subscribed to transcription.en`.
   Arreglado con dos candados independientes: el Info.plist declara `es`/`en`, y
   `Recorder.languageCode(preferred:)` decide con `Locale.preferredLanguages`, que no
   depende del bundle. Cubierto por `LanguageTests`.
2. **El volcado del `NSError` en pantalla.** La pantalla de grabación enseñaba
   `Error Domain=SFSpeechErrorDomain Code=1 ... UserInfo={...}`. Ahora una frase legible
   con el dato técnico entre paréntesis; el crudo va al log y al informe. La prueba de
   interfaz falla si vuelve a aparecer un `Error Domain=` en pantalla.
3. **La insignia de IA congelada.** Se leía dentro de `body`, así que SwiftUI no tenía
   ninguna dependencia que invalidar y se quedaba con el primer valor para siempre.
   Se reevalúa al volver a primer plano.

**Sobre el LLM en CI, porque la primera lectura fue engañosa.** Un build reportó
`llm=available` y el siguiente `llm=unavailable(modelNotReady)`. Apple Intelligence no
está provisionado en los runners de GitHub, y el `.available` apareció antes de que el
modelo estuviera listo — no era una buena noticia, era un valor prematuro.

Y en el run `34376954716` quedó demostrado del todo: `llm=available`, la llamada
lanzada, y la generación falló con

    FoundationModels.LanguageModelSession.GenerationError Code=-1
      └─ ModelManagerServices.ModelManagerError Code=1026

Eso deja una lección para el producto, no solo para CI: **`availability` puede decir
`.available` y la llamada fallar igualmente**. La comprobación no puede hacerse una vez
al arrancar y darse por buena — hay que tratar el error de la llamada, que es lo que
hace `Recorder.summarize`. Y por eso el usuario debe saber siempre que **la
transcripción está guardada aunque el resumen falle**.

La suite `suites/llm.json` se queda: lleva el spike 4b del plan —el presupuesto que se
asigna a Marta, se reasigna a Javier y se aparca— y se lanza contra el iPhone con
`./scripts/devtest.sh llm`. En CI se intenta y se salta.

---

## Repaso de errores y revisión de seguridad

Antes del primer push se hizo una pasada de depuración por lectura (no hay compilador
en esta máquina) y una revisión de seguridad. Salieron **22 correcciones y 6 hallazgos
de seguridad**. Los que merecen quedar escritos:

### Habrían roto la compilación

- **13 llamadas a `Log.event(…, nil, …)`.** `caseId` tenía etiqueta y valor por
  defecto: un parámetro así no se puede pasar posicionalmente. Se reordenó la firma
  para que `detail` vaya sin etiqueta, que es el uso normal.
- **Dos `@Guide` apilados** sobre la misma propiedad en `ActionItemDraft`. No está
  soportado; la descripción y la restricción van en una sola llamada.

### Habrían fallado en el teléfono, sin dar un error útil

- **El formato del micrófono se leía antes de activar la sesión de audio**, cuando
  `outputFormat(forBus:)` todavía devuelve 0 Hz. El fichero se habría creado con
  `sampleRate: 0` y habría fallado al escribir, no al crearse. Ahora hay un
  `prepare()` explícito y una comprobación que falla con un mensaje legible.
- **`SWIFT_ACTIVE_COMPILATION_CONDITIONS` en vez de `OTHER_SWIFT_FLAGS: "-D DEBUG"`.**
  Con la segunda forma el flag se parte en dos argumentos y hay versiones de
  `xcodebuild` donde no llega — y si no llega, la app se compila **sin**
  `DiagnosticsRunner` y el banco de pruebas no arranca nunca.

### Habrían dado resultados incorrectos en silencio, que es lo peor

- **Los buffers de audio llegaban desordenados al ASR.** Cada buffer abría su propio
  `Task` para llegar al actor, y varios `Task` esperando a un mismo actor **no**
  conservan el orden de llegada. La transcripción habría salido sutilmente rota sin
  un solo error en el log. Ahora hay un `AsyncStream` —que sí garantiza el orden— con
  un único consumidor, y además fuera del `@MainActor`, así el camino del audio no
  compite con la interfaz. El mismo bug estaba en el banco de pruebas, donde habría
  falseado justo las métricas de WER que deciden la puerta de la Fase 0.
- **`devtest.sh` podía dar un PASS falso.** Los informes se llamaban `report-<uuid>` y
  el script cogía "el último" alfabéticamente; con un UUID eso no es el más reciente.
  Si la app no llegaba a escribir uno nuevo, se traía el de la ejecución anterior y
  daba verde. Ahora el nombre lleva marca de tiempo ordenable y el script borra los
  informes viejos **antes** de lanzar.
- **`peakMemoryMB` no era un pico.** Leía la huella una sola vez al final, que es
  precisamente el número que no sirve para el riesgo R11: el jetsam ocurre en el
  máximo, no en el valor con el que terminas. Ahora se muestrea cada 250 ms.
- **Una cola acotada habría perdido audio.** El primer arreglo del orden usaba
  `.bufferingNewest(512)`, que descarta cuando se llena. Descartar aquí es perder
  audio que el usuario cree grabado. Ahora la cola no tiene límite y el freno se
  aplica **solo al ASR**, que es ciudadano de segunda; el disco no pierde nada.

### Seguridad

| # | Hallazgo | Gravedad | Estado |
|---|---|---|---|
| S1 | `Log.failure` volcaba `String(describing: error)`, y un error de `FoundationModels` puede llevar dentro el prompt — que es el fragmento de transcripción. **Contenido de reuniones en el syslog**, legible por cualquier ordenador emparejado | **Alta** | Corregido: solo se registra el tipo del error y su dominio/código |
| S2 | Transcripciones y audio sin clase de protección de datos | Media | Corregido con `.completeUnlessOpen` — **no** `.complete`, que dejaría el fichero ilegible con el teléfono bloqueado y rompería la grabación en segundo plano |
| S3 | `devtest.sh` escribía en el portátil usando nombres de fichero venidos **del dispositivo**: un artefacto llamado `../../../.ssh/…` habría escrito fuera del directorio | Media | Corregido: se sanea a *basename* y se valida |
| S4 | `UIFileSharingEnabled` expone **todo** `Documents/`. Con el audio ahí, una build Debug en un teléfono emparejado entregaba las reuniones enteras | Media | Corregido a medias: en `Documents/` solo viven los diagnósticos y el resto va a Application Support. **Pero** una app con firma de desarrollo (la de SideStore) deja leer el contenedor ENTERO a un ordenador emparejado: la defensa real es no emparejar el iPhone con ordenadores ajenos |
| S5 | `GITHUB_TOKEN` con permisos por defecto y una acción de terceros anclada a una etiqueta mutable (`@v2`) | Baja | Corregido: lectura por defecto, acciones ancladas a SHA, y solo el trabajo `release` (que no compila nada) puede escribir |
| S6 | El nombre de la suite entraba sin validar en una ruta | Baja | Corregido |

**Red.** La app no hace ninguna llamada de red. Los modelos de separación de
hablantes (~21 MB) van DENTRO de la app: CI los baja de un commit fijo de Hugging Face
y comprueba cada fichero con su SHA-256 (`scripts/fetch-diarizer-models.sh`,
`scripts/diarizer-models.sha256`); la librería se pone en modo sin red.

**Qué puede sacar datos del teléfono** (corregido: antes decía que solo "Enviar al
CRM", y era falso). Los atajos de Siri/Atajos que devuelven la transcripción o
exportan una reunión exigen el mismo consentimiento de Ajustes, piden Face ID si el
bloqueo está activo, y ninguno funciona con el teléfono bloqueado.

**Riesgo residual aceptado:** en Debug, los ficheros de `Documents/diagnostics/`
—incluidas las transcripciones de las pruebas— sí son accesibles por AFC y desde la
app Archivos. Es el precio de poder sacar los resultados del teléfono, y por eso el
corpus de pruebas debe ser audio grabado a propósito, no reuniones reales.

### Segunda revisión (v0.2, 2026-09-18): 24 fallos y 21 hallazgos de seguridad

Dos revisiones independientes por lectura del código. Lo corregido que más importa:

**Habrían perdido reuniones:**
- **Arrancar con el teléfono bloqueado borraba el índice.** Si iOS abría la app en
  segundo plano (tarea nocturna, Siri) el índice estaba cifrado; "no se puede leer" se
  trataba como "no hay reuniones" y el siguiente guardado pisaba todas con una. Ahora
  el índice usa la protección "hasta el primer desbloqueo", se distingue "no existe"
  de "no se puede leer" (se bloquea la escritura) y se relee al desbloquear. Lo mismo
  en las huellas de voz.
- **Una llamada podía terminar la grabación** en vez de pausarla (los cambios de
  configuración de audio durante la llamada reiniciaban el micrófono y fallaba).
- **Tras 30 s de silencio la transcripción en vivo se paraba para siempre**: el freno
  confundía silencio con atasco. Ahora, 10 s sin resultados = silencio.
- **"Volver a transcribir" borraba transcripción y resumen antes de tener los
  nuevos**; si fallaba, la nota quedaba vacía. Ahora se sustituyen solo al terminar bien.
- **Borrar la reunión que se está grabando** dejaba grabadora, Live Activity y cola
  rotas. Ya no se ofrece, y parar limpia siempre.

**Otros:** Siri/botón de acción no empezaban a grabar si la pantalla de grabación
seguía abierta; "Grabar otra" heredaba el título anterior; Face ID en bucle al
cancelar; empezar a grabar marcaba como fallido el resumen en curso; la cola se
quedaba parada tras grabar; tareas distintas se fusionaban entre fragmentos del
resumen; un fallo tardío marcaba como fallida la grabación nueva; la búsqueda no veía
los renombrados; un arranque fallido dejaba el micrófono activo.

**Seguridad:**

| Hallazgo | Corrección |
|---|---|
| El bloqueo de Face ID no tapaba las hojas (preguntar, compartir, grabar) ni su captura en el selector de apps | La tapa es una ventana propia por encima de todo |
| Siri/Atajos leían reuniones con el teléfono bloqueado y saltándose Face ID | Todos exigen teléfono desbloqueado, piden Face ID si está activo, y transcripción/exportar piden el consentimiento |
| Copia cifrada: 210.000 iteraciones (cifra de SHA-512, no de SHA-256), sin versión en cabecera, registros que se podían quitar o cortar sin que se notara | Formato EUGX2: 600.000 iteraciones anotadas en la cabecera, cada registro autenticado con su posición y un registro final; contraseña ≥ 12 y normalizada. Las copias EUGX1 se siguen leyendo |
| Una copia ajena podía colar en su índice el audio de otra nota (y borrarlo después) | Solo se acepta el audio `<id>-NNN.m4a` de la propia nota; el índice se valida antes de mover nada |
| Copias en claro que quedaban en tmp (exportaciones, vídeo importado, WAV de hablantes) | Se borran al cerrar la hoja de compartir y al arrancar |
| PDF o texto ajeno podía tumbar la app por memoria | Tope de 500 páginas, 20 MB de texto e imagen de OCR de 3.000 px; "Abrir en Eugenia" espera a Face ID |
| Modelos de hablantes bajados de una rama que puede cambiar, sin comprobar | Dentro de la app, commit fijo y SHA-256 |
| CI: `brew install xcodegen` sin anclar y con token de escritura | XcodeGen fijo por SHA-256, sin credenciales guardadas, publicación en un trabajo aparte con atestación de procedencia (`gh attestation verify Eugenia.ipa -R siemprecreando/eugenia`) |
| FluidAudio anclado por etiqueta | Anclado al commit |
| Contenedor de pruebas con dependencias sin anclar y acceso a las claves de emparejamiento | Todas las dependencias con versión y SHA-256; emparejamiento en solo lectura; la imagen se reconstruye sola al cambiar |
| Títulos de reuniones en la pantalla bloqueada | Ajuste "Ocultar títulos en la pantalla bloqueada" |
| El correo de seguimiento copiado al Portapapeles Universal | Solo en este iPhone y caduca a los 2 min |

**Aceptado y anotado:** con build Debug y firma de desarrollo, un ordenador emparejado
puede leer todo el contenedor y depurar la app; eso se va con el build Release.

**Regenerar las dependencias ancladas del contenedor:**

    cd scripts/devtools && podman run --rm -v "$PWD":/w:Z -w /w python:3.12@<digest> \
      bash -c "pip install pip-tools==7.4.1 && pip-compile --generate-hashes --allow-unsafe --strip-extras -o requirements.txt requirements.in"

---

## Decisiones que conviene conocer antes de tocar nada

**`SWIFT_VERSION` es 5.0, no 6.** Ojo al subir: el bloque que recibe el audio del
micrófono se crea en el hilo principal y se llama desde el de audio; en Swift 6 eso
casca en ejecución. Hay que sacarlo a una función no aislada antes de migrar. El plan pide Swift 6 con concurrencia estricta, y
ahí es donde hay que llegar. Pero el primer objetivo es un build verde que se pueda
instalar; pelearse a ciegas con errores de aislamiento de actores, sin compilador
local y a 10-15 minutos por intento en CI, es la peor forma de avanzar. Se sube a 6 en cuanto el ciclo esté cerrado. Está anotado en `project.yml`.

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
