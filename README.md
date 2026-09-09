# Eugenia — código

App de iPhone. Graba, transcribe y resume reuniones **sin que el audio salga del
dispositivo**. Plan completo en [`../plan-summary-ai-iphone.md`](../plan-summary-ai-iphone.md).

- **Dispositivo de destino:** un iPhone 17e con iOS 26.
- **Se compila** en GitHub Actions (no hay Mac), **sin firmar**.
- **Se instala** con SideStore, que firma en el propio teléfono con un Apple ID gratuito.
- **Se prueba** desde Linux con `pymobiledevice3`, contra el teléfono real.

> ### Estado: COMPILA. Nunca ejecutado en un teléfono.
>
> El build pasa en GitHub Actions (`macos-26`, Xcode 26.6, SDK iOS 26.5) y produce un
> `.ipa` con un binario arm64 de dispositivo y su dSYM. Hicieron falta **cuatro
> rondas**:
>
> 1. `no such module 'FoundationModels'` — la imagen `macos-15` trae el SDK de iOS 18.
>    Era el entorno, no el código.
> 2. Un único error de Swift: `.completeFileProtectionUnlessOpen`, que yo había
>    escrito con las palabras en otro orden. Todo lo demás compiló a la primera,
>    incluidos `AssetInventory`, `SpeechAnalyzer` y los macros `@Generable`/`@Guide`,
>    que eran los puntos que más dudas daban.
> 3. Verde, pero el `.ipa` venía partido en un `debug.dylib` y **sin dSYM** — y aun
>    así salía verde. Corregido y ahora el build falla si el dSYM no aparece.
> 4. Verde y correcto.
>
> **Lo que sigue sin estar probado es todo lo que importa:** que la app arranque, que
> grabe, que `SpeechTranscriber` transcriba y que `FoundationModels` resuma. Que
> compile solo significa que los tipos encajan. El siguiente paso real es el spike 8
> del plan — instalar con SideStore y ver si `./scripts/devtest.sh smoke` cierra el
> bucle.

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
Desde Linux eso lo resuelve **Altcon**, el contenedor oficial de SideStore que lleva
AltServer-Linux dentro:

```bash
./scripts/install-sidestore.sh
```

Conecta el iPhone por cable antes (`usbmuxd` arranca solo, por regla udev). El
contenedor te pedirá el PIN del teléfono y tu Apple ID — **se recomienda una cuenta
secundaria**, porque el certificado de desarrollo gratuito queda asociado a ella.
Al salir deja un fichero `.mobiledevicepairing` que hay que importar en SideStore.

*Ya con SideStore instalado:* instala o actualiza directamente desde

```
https://github.com/siemprecreando/eugenia/releases/latest/download/Eugenia.ipa
```

Recuerda que la firma **caduca a los 7 días** y SideStore la refresca sola, siempre
que tenga el VPN local (StosVPN o WireGuard) configurado.

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
  install-sidestore.sh       pone SideStore en el teléfono vía Altcon (solo la 1ª vez)
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

## Qué se puede probar sin el teléfono, y qué no

CI corre en `macos-26` con simulador. Esto es lo medido, no lo supuesto:

| | Estado |
|---|---|
| Que la app compile y produzca un `.ipa` arm64 con dSYM | ✅ en cada push |
| Pruebas unitarias: WER, troceado, contrato JSON, persistencia, backlog | ✅ 5 suites |
| Que la app **arranque** sin reventar | ✅ en el simulador |
| Que la app **se pueda usar**: lista, detalle, grabación | ✅ 3 pruebas de interfaz |
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
| S4 | `UIFileSharingEnabled` expone **todo** `Documents/`. Con el audio ahí, una build Debug en un teléfono emparejado entregaba las reuniones enteras | Media | Corregido: en `Documents/` solo viven los diagnósticos; audio, transcripciones e índice se movieron a Application Support, que AFC no vende |
| S5 | `GITHUB_TOKEN` con permisos por defecto y una acción de terceros anclada a una etiqueta mutable (`@v2`) | Baja | `permissions: contents: write` añadido. La etiqueta mutable queda documentada: asumible sin secretos en el repo, hay que anclar a SHA si eso cambia |
| S6 | El nombre de la suite entraba sin validar en una ruta | Baja | Corregido |

**Lo que la revisión confirmó que está bien:** la app no tiene **ni una sola** llamada
de red — ni `URLSession`, ni sockets, ni una URL. La tesis "tus reuniones nunca salen
de tu iPhone" es hoy verificable leyendo el código, no solo confiando en el plan.

**Riesgo residual aceptado:** en Debug, los ficheros de `Documents/diagnostics/`
—incluidas las transcripciones de las pruebas— sí son accesibles por AFC y desde la
app Archivos. Es el precio de poder sacar los resultados del teléfono, y por eso el
corpus de pruebas debe ser audio grabado a propósito, no reuniones reales.

---

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
