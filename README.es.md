# PlugPilot

Una app de barra de menús para macOS que automatiza radios y ventiladores
según la fuente de alimentación, en Mac Intel genéricos.
*(Read this in [English](README.md).)*

![Menú de PlugPilot](docs/menu.png)

## Qué hace

PlugPilot añade un ítem en la barra de menús con un panel informativo
(fuente de alimentación, estado de Bluetooth, Wi-Fi/Ethernet, temperatura de
CPU y batería, RPM de ventiladores) y tres automatizaciones
**independientes**, todas **desactivadas por defecto**:

- **Bluetooth solo con cargador** — enciende Bluetooth con el cargador
  conectado, lo apaga en batería.
- **Wi-Fi solo sin Ethernet** — apaga Wi-Fi siempre que hay un enlace Ethernet
  real (cable/dock), sin importar la alimentación; lo enciende en cualquier
  otro caso. La detección de Ethernet recorre el IORegistry para distinguir
  un enlace físico de otros virtuales (PAN de Bluetooth, tethering de
  iPhone/iPad por USB), así que funciona sin importar el idioma del sistema.
- **Intensidad de ventiladores (solo con cargador)** — un único submenú con
  cinco opciones (Por defecto/Suave/Media/Fuerte/Extremo); "Por defecto" deja
  los ventiladores en modo automático del SMC, las otras cuatro fuerzan las
  RPM con el cargador conectado a esa intensidad (25/33/50/75 % del máximo
  que reporta el SMC de cada ventilador, nunca por debajo de su mínimo de
  fábrica). Vuelve al modo automático en batería o al elegir "Por defecto".

Activar el toggle de Bluetooth o Wi-Fi aplica su política de inmediato con
el estado actual; desactivarlo **no restaura nada** — quedan como estén,
porque el usuario manda. La intensidad de ventiladores funciona igual pero
al revés: elegir una intensidad distinta de "Por defecto" se aplica de
inmediato, y elegir "Por defecto" siempre devuelve el control al modo
automático del SMC.

Cada automatización se degrada con elegancia: en máquinas sin ventiladores,
sin batería o sin hardware Wi-Fi, los ítems de menú correspondientes se
ocultan automáticamente (las capacidades se detectan una sola vez, en el
arranque).

## Requisitos

- macOS 13 (Ventura) o posterior.
- **Mac Intel genérico.** Todo el comportamiento dependiente del hardware
  (número de ventiladores, rangos de RPM, claves de sensores de temperatura)
  se detecta en tiempo de ejecución a través del SMC de Apple, así que
  PlugPilot debería funcionar en distintos modelos de Mac Intel sin ajustes
  por máquina.
- **Apple Silicon no está soportado.** El control de ventiladores de esta
  app habla con el protocolo del user client de AppleSMC de la era Intel
  (claves `F#Md`/`F#Tg`/`F#Mn`/`F#Mx`) que los Mac con Apple Silicon no
  exponen de la misma forma. Soportar los Mac de la serie M requeriría un
  enfoque de bajo nivel distinto y no verificado, fuera del alcance de este
  proyecto.

## Instalación (desde un release)

1. Descarga el último `PlugPilot-<versión>.zip` desde la página de
   [Releases](../../releases) y descomprímelo.
2. Mueve `PlugPilot.app` a `/Aplicaciones` (o donde prefieras).
3. Los releases **no están notarizados** por Apple, así que Gatekeeper se
   negará a abrirlo con un doble clic normal. En su lugar: **clic derecho
   (o Control-clic) sobre la app → Abrir**, y confirma en el diálogo que
   aparece. Solo hace falta hacerlo una vez.
4. Si eliges en **"Intensidad de ventiladores (solo con cargador)"** una
   opción distinta de "Por defecto", PlugPilot registra un pequeño helper
   privilegiado (`PlugPilotHelper`) que habla con el SMC. macOS te pedirá
   aprobarlo en **Ajustes del Sistema → General → Ítems de inicio** (busca
   PlugPilot en la sección de helpers / "Permitir en segundo plano").
   Apruébalo ahí para que el control de ventiladores surta efecto.

## Compilar desde el código

```bash
./build.sh        # swift build -c release + monta PlugPilot.app + firma ad-hoc
open PlugPilot.app
```

Nunca uses `swift build` a secas como paso final: no actualiza el `.app` de
la raíz del repo, que es lo que realmente se ejecuta. No hay suite de tests
automatizada; la verificación es manual.

Para generar un zip distribuible (hace lo mismo que `./build.sh` y además
comprime el bundle usando la versión de `Info.plist`):

```bash
./release.sh
```

## Seguridad

PlugPilot escribe en registros de hardware gestionados por `AppleSMC`, y
macOS solo permite esas escrituras desde un proceso **root**. Esa es toda la
razón de ser de `PlugPilotHelper`: un daemon privilegiado mínimo, instalado
vía `SMAppService.daemon` y al que se habla por XPC, cuyo único trabajo es
aplicar peticiones de modo/objetivo de ventilador.

Puntos relevantes si estás decidiendo si confiar en él:

- **Superficie mínima.** El helper acepta exactamente un tipo de petición:
  fijar el modo y la RPM objetivo de un ventilador dado (más un ping sin
  efecto). No ejecuta comandos arbitrarios, no lee ficheros ni expone
  ninguna otra capacidad.
- **Las RPM siempre se acotan.** Antes de escribir, el helper lee el mínimo
  de fábrica (`F#Mn`) y el máximo (`F#Mx`) de ese ventilador directamente
  del SMC en cada petición, y acota el objetivo entre ambos. Si alguna clave
  no se puede leer, no escribe nada y devuelve un estado de error — nunca
  inventa un mínimo. Forzar un ventilador más rápido que su mínimo de
  fábrica es seguro; más lento es justo lo que se evita.
- **Válvula térmica.** Las RPM forzadas solo se aplican mientras el estado
  térmico de `ProcessInfo` es `.nominal`. Si aumenta la presión térmica, el
  control vuelve automáticamente al SMC.
- **Salida por inactividad.** El proceso del helper sale a los 20 segundos
  de inactividad; no es un proceso residente persistente más allá de eso.
- **Limitación conocida: firma ad-hoc y recompilaciones.** El mecanismo de
  aprobación del daemon (Launch Constraint Requirements) fija un requisito
  de código al **hash** del binario del helper. Como los releases se firman
  ad-hoc (no con un Developer ID de pago), cada vez que recompilas desde el
  código el hash del helper cambia y la aprobación anterior deja de ser
  válida — `launchd` reportará "spawn failed" y las peticiones de
  ventilador se quedarán encoladas en silencio para siempre. Si pasa esto:
  reabre la app (se vuelve a registrar sola) y, si no basta, vuelve a
  aprobarlo en **Ajustes del Sistema → General → Ítems de inicio**. Es el
  comportamiento esperado dada la firma ad-hoc, no un bug que arreglar.

Si no necesitas control de ventiladores, simplemente deja el submenú de
intensidad en "Por defecto" — PlugPilot nunca registra ni lanza el helper a
menos que elijas otra opción.

## Licencia

GPL-3.0. Ver [LICENSE](LICENSE).
