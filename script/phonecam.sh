#!/usr/bin/env bash
# PhoneCam — use an Android phone as a webcam and microphone over USB (Linux Mint).
# Video: scrcpy (phone camera) --v4l2-sink--> v4l2loopback node, /dev/video42 by default, listed by apps as "PhoneCam".
# Audio: scrcpy (phone mic, played locally) -> route_audio_to_mic moves that stream into the null sink PhoneMicSink ->
#        PhoneMic, a remap-source of PhoneMicSink.monitor, is what apps record. A remap-source rather than the monitor itself:
#        apps and mixers hide monitors or label them "Monitor of ...", but list a remapped source as an ordinary microphone.
# One scrcpy process per capture, tracked by a pidfile (PID + start time); the agent starts/stops them as the phone connects.
# shellcheck disable=SC2005  # deliberate: t() prints no trailing newline; echo supplies it
set -uo pipefail

PHONECAM_VERSION="1.1.0"

# ---- Language
# An exported PHONECAM_LANG (e.g. PHONECAM_LANG=en phonecam status) outranks phonecam.conf;
# a plain shell variable left behind by an earlier `source` does not.
PHONECAM_LANG_ENV=""
[[ "$(declare -p PHONECAM_LANG 2>/dev/null)" == "declare -x"* ]] && PHONECAM_LANG_ENV="$PHONECAM_LANG"
PHONECAM_LANG="${PHONECAM_LANG:-auto}"
CURRENT_LANG="en"
declare -A MSG_EN MSG_ES

# Message catalog: "KEY<TAB>English<TAB>Spanish" per line; both texts are printf formats with the same arguments.
load_messages() {
    local key en es
    while IFS=$'\t' read -r key en es; do
        [ -z "$key" ] && continue
        MSG_EN["$key"]="$en"
        MSG_ES["$key"]="$es"
    done <<'EOF'
CONF_MISSING	Configuration file %s not found; using defaults.	No existe %s, usando los valores por defecto.
CONF_INSTALL_FIRST	Run '%s install' if PhoneCam is not installed yet.	Ejecuta '%s install' si todavía no has instalado PhoneCam.
TOOLS_MISSING	Missing tools: %s.	Faltan herramientas: %s.
INSTALL_FIRST	Run '%s install' first.	Ejecuta '%s install' primero.
SCRCPY_UNAVAILABLE	'scrcpy' is not available in a compatible version (>= 2.3.1 required).	'scrcpy' no está disponible en una versión compatible (se necesita >= 2.3.1).
SCRCPY_MANUAL	Install it manually: https://github.com/Genymobile/scrcpy/blob/master/doc/linux.md	Instálalo manualmente: https://github.com/Genymobile/scrcpy/blob/master/doc/linux.md
NO_ADB_PHONE	No authorized phone was detected by ADB.	No se detecta ningún teléfono autorizado por ADB.
ADB_USB	   - Connect the phone by USB.	   - Conecta el móvil por USB.
ADB_DEBUG	   - Enable 'USB debugging' in Developer options.	   - Activa 'Depuración USB' en Opciones de desarrollador.
ADB_ACCEPT	   - Accept the authorization dialog shown on the phone.\n     (enable 'remember this computer' to avoid repeating it).	   - Acepta el diálogo de autorización que aparece en el teléfono.\n     (marca 'recordar en este equipo' para no repetirlo).
ADB_CHECK	   - Check with: adb devices	   - Comprueba con: adb devices
NO_DEVICE_CHOSEN	No device was selected.	No se ha seleccionado ningún dispositivo.
MULTI_DEVICE	Multiple devices are connected. Using the first one found: %s	Hay varios dispositivos conectados. Se usará el primero encontrado: %s
MULTI_DEVICE_CHOOSE	Multiple devices are connected. Choose the one to use:	Hay varios dispositivos conectados. Elige cuál usar:
SCRCPY_VERSION_FAIL	Could not run 'scrcpy --version' (exit code %s).	No se pudo ejecutar 'scrcpy --version' (código %s).
SCRCPY_VERSION_UNKNOWN	Could not determine the scrcpy version.	No se pudo determinar la versión de scrcpy.
SCRCPY_TOO_OLD	scrcpy %s is too old (>= 2.3.1 required by PhoneCam).	scrcpy %s es demasiado antiguo (se necesita >= 2.3.1 para PhoneCam).
SCRCPY_UPDATE	Update scrcpy: https://github.com/Genymobile/scrcpy/releases	Actualiza scrcpy: https://github.com/Genymobile/scrcpy/releases
DOWNLOADER_MISSING	'curl' or 'wget' is required to download scrcpy, but neither was found.	Se necesita 'curl' o 'wget' para descargar scrcpy y no se encontró ninguno.
INSTALL_CURL	Install 'curl' now? (requires sudo)	¿Instalar 'curl' ahora? (requiere sudo)
NO_STATIC_BUILD	There is no official static scrcpy build for your architecture (%s).	No existe una compilación estática oficial de scrcpy para tu arquitectura (%s).
SCRCPY_MANUAL_BUILD	Install it manually by following the instructions at: https://github.com/Genymobile/scrcpy/blob/master/doc/linux.md	Instálalo manualmente siguiendo: https://github.com/Genymobile/scrcpy/blob/master/doc/linux.md
CHECK_SCRCPY_GITHUB	Checking the latest scrcpy release on GitHub...	Consultando la última versión de scrcpy en GitHub...
SCRCPY_URL_FAIL	Could not obtain the scrcpy download URL (no connection, or GitHub is unreachable?).	No se pudo obtener la URL de descarga de scrcpy (¿sin conexión, o GitHub no está accesible?).
SCRCPY_LATEST	Download it manually from: https://github.com/Genymobile/scrcpy/releases/latest	Descárgalo manualmente desde: https://github.com/Genymobile/scrcpy/releases/latest
SCRCPY_DOWNLOADING	Downloading %s...	Descargando %s...
SCRCPY_DOWNLOAD_FAIL	scrcpy download failed.	La descarga de scrcpy ha fallado.
SCRCPY_EXTRACTING	Extracting scrcpy...	Extrayendo scrcpy...
SCRCPY_EXTRACT_FAIL	Could not extract the downloaded archive.	No se pudo extraer el archivo descargado.
SCRCPY_CHECKSUM_FAIL	Could not verify the SHA-256 checksum of the downloaded scrcpy archive.	No se pudo verificar la suma SHA-256 del archivo de scrcpy descargado.
SCRCPY_ARCHIVE_UNSAFE	The downloaded scrcpy archive contains unsupported or unsafe entries.	El archivo de scrcpy descargado contiene entradas no compatibles o inseguras.
SCRCPY_BINARY_MISSING	The downloaded package does not contain the expected 'scrcpy' executable.	El paquete descargado no contiene el ejecutable 'scrcpy' esperado.
SCRCPY_INSTALL_FAIL	Could not replace the existing scrcpy installation safely.	No se pudo sustituir de forma segura la instalación existente de scrcpy.
SCRCPY_INSTALLED	scrcpy installed in %s (linked as %s/scrcpy).	scrcpy instalado en %s (enlazado en %s/scrcpy).
SCRCPY_NOT_OPERATIONAL	Could not get 'scrcpy' to work after the download.	No se pudo hacer funcionar 'scrcpy' correctamente después de la descarga.
SCRCPY_TOO_OLD_WARN	The installed scrcpy version is too old (>= 2.3.1 required by PhoneCam).	La versión de scrcpy instalada es demasiado antigua (se necesita >= 2.3.1 para PhoneCam).
SCRCPY_NOT_FOUND	'scrcpy' was not found on this system.	No se ha encontrado 'scrcpy' en este sistema.
SCRCPY_AUTO_QUESTION	Download and install the latest official scrcpy version automatically?	¿Descargar e instalar automáticamente la última versión oficial de scrcpy?
SCRCPY_CANCELLED	scrcpy installation was cancelled by the user.	Instalación de scrcpy cancelada por el usuario.
SCRCPY_NO_PROMPT	There is no terminal or display to ask for confirmation, so scrcpy was not downloaded. Run '%s install' in a terminal, or install scrcpy manually.	No hay terminal ni pantalla donde pedir confirmación, así que no se ha descargado scrcpy. Ejecuta '%s install' en una terminal o instala scrcpy manualmente.
ANDROID_API_UNKNOWN	Could not determine the Android API level.	No se pudo determinar la API de Android.
ANDROID_CAMERA_REQUIRED	Camera capture requires Android 12+ (API 31); this device reports API %s.	La captura de cámara requiere Android 12+ (API 31); este dispositivo informa de la API %s.
ANDROID_AUDIO_REQUIRED	Microphone capture requires Android 11+ (API 30); this device reports API %s.	La captura de micrófono requiere Android 11+ (API 30); este dispositivo informa de la API %s.
AUDIO_SOURCE_UNSUPPORTED	Audio source '%s' needs scrcpy 3.2 or newer. Choose another one with '%s config'.	La fuente de audio '%s' necesita scrcpy 3.2 o posterior. Elige otra con '%s config'.
PHONE_SCREEN_OFF_FAIL	Could not turn the phone screen off. The capture will continue.	No se pudo apagar la pantalla del teléfono. La captura continuará.
PHONE_SCREEN_OFF_UNSUPPORTED	Could not determine how to turn the screen off on this Android version; the capture will continue.	No se pudo determinar cómo apagar la pantalla en esta versión de Android; la captura continuará.
ICON_INSTALL_FAIL	Could not install the PhoneCam icon. The launcher will use the system fallback icon.	No se pudo instalar el icono de PhoneCam. El lanzador usará el icono alternativo del sistema.
ICON_INSTALLED	Application icon installed.	Icono de la aplicación instalado.
WEBCAM_LOCK	Another process is already starting the webcam.	Otro proceso ya está iniciando la webcam.
MIC_LOCK	Another process is already starting the microphone.	Otro proceso ya está iniciando el micrófono.
GUI_SCRCPY_QUESTION	PhoneCam needs scrcpy (version 2.3.1 or newer) and it is not available.\n\nDownload and install the latest official version automatically now?\n(no sudo password required)	PhoneCam necesita scrcpy (versión 2.3.1 o superior) y no está disponible.\n\n¿Descargar e instalar automáticamente la última versión oficial ahora?\n(no requiere contraseña de sudo)
SCRCPY_PROGRESS	Downloading and installing scrcpy...	Descargando e instalando scrcpy...
V4L2_MISSING	%s does not exist. Is the v4l2loopback module loaded?	No existe %s. ¿Está cargado el módulo v4l2loopback?
V4L2_TEST	   Try: sudo modprobe v4l2loopback	   Prueba: sudo modprobe v4l2loopback
V4L2_REINSTALL	   or run again: %s install	   o vuelve a ejecutar: %s install
V4L2_MOK	   If you just installed it and Secure Boot is enabled,\n   you may need to reboot and enroll the MOK key.	   Si acabas de instalar y el equipo tiene Secure Boot activado,\n   puede que necesites reiniciar el equipo y registrar la clave MOK.
V4L2_PERMISSION	You do not have write permission for %s.	No tienes permiso de escritura en %s.
V4L2_GROUP	   You are missing the 'video' group: log out and back in after\n   running '%s install' (or reboot the computer).	   Te falta el grupo 'video': cierra sesión y vuelve a entrar tras\n   ejecutar '%s install' (o reinicia el equipo).
CREATE_SINK	Creating virtual audio sink '%s'...	Creando la salida de audio virtual '%s'...
CREATE_SINK_FAIL	Could not create the virtual audio sink '%s' (is PipeWire/PulseAudio running?).	No se pudo crear la salida de audio virtual '%s' (¿PipeWire/PulseAudio está en ejecución?).
CREATE_MIC	Creating virtual microphone '%s'...	Creando micrófono virtual '%s'...
CREATE_MIC_FAIL	Could not create virtual microphone '%s'.	No se pudo crear el micrófono virtual '%s'.
AUDIO_ROUTED	Phone audio routed to the virtual microphone.	Audio del teléfono enrutado al micrófono virtual.
AUDIO_ROUTE_FAIL	Could not route the audio automatically within %ss.	No se pudo enrutar el audio automáticamente en %ss.
AUDIO_ROUTE_MANUAL	You can route it manually with 'pavucontrol' (Playback tab -> move the scrcpy\n  audio stream to '%s').	Puedes enrutarlo manualmente con 'pavucontrol' (pestaña Reproducción -> mueve\n  el flujo de scrcpy a '%s').
WEBCAM_ALREADY	A webcam is already active (PID %s).	Ya hay una webcam activa (PID %s).
WEBCAM_START	Starting webcam (%s, %s, %sfps)...	Iniciando webcam (%s, %s, %sfps)...
SCRCPY_START_FAIL	scrcpy did not start correctly. Check %s.	scrcpy no arrancó correctamente. Revisa %s.
PROCESS_STATE_SAVE_FAIL	Could not record the capture process state safely; the capture was stopped.	No se pudo registrar de forma segura el estado del proceso de captura; se detuvo la captura.
WEBCAM_ACTIVE	Webcam is active at %s (PID %s).	Webcam activa en %s (PID %s).
WEBCAM_ACTIVE_TITLE	Webcam active	Webcam activa
WEBCAM_SELECT	Select it in your app as 'PhoneCam' / 'Dummy video device'.	Selecciónala en tu app como 'PhoneCam' / 'Dummy video device'.
MIC_ALREADY	The microphone is already active (PID %s).	El micrófono ya está activo (PID %s).
MIC_START	Starting microphone (%s, %s)...	Iniciando micrófono (%s, %s)...
MIC_ACTIVE	Microphone is active (PID %s). Select '%s' as the audio input.	Micrófono activo (PID %s). Selecciona '%s' como entrada de audio.
MIC_ACTIVE_TITLE	Microphone active	Micrófono activo
MIC_SELECT	Select '%s' in Discord/Zoom/Meet/Teams/OBS.	Selecciona '%s' en Discord/Zoom/Meet/Teams/OBS.
PHONECAM_STOPPED	PhoneCam has been stopped.	PhoneCam se ha detenido.
NO_PROCESS	No PhoneCam process was active.	No había ningún proceso de PhoneCam activo.
WEBCAM_STOPPED	Webcam has been stopped.	La webcam se ha detenido.
WEBCAM_NOT_ACTIVE	The webcam was not active.	La webcam no estaba activa.
MIC_STOPPED	Microphone has been stopped.	El micrófono se ha detenido.
MIC_NOT_ACTIVE	The microphone was not active.	El micrófono no estaba activo.
STATUS_TITLE	PhoneCam — current status	PhoneCam — estado actual
STATUS_CONNECTION	Connection	Conexión
ADB_NOT_INSTALLED	'adb' is not installed.	'adb' no está instalado.
STATUS_INSTALL_ADB	     → Run '%s install' to install it.	     → Ejecuta '%s install' para instalarlo.
PHONE_CONNECTED	Phone connected via ADB:	Teléfono conectado por ADB:
PHONE_NOT_AUTH	No authorized phone detected.	Ningún teléfono autorizado detectado.
STATUS_CONNECT_USB	     → Connect it by USB, enable 'USB debugging' in Developer options\n       and accept the phone's authorization prompt.	     → Conéctalo por USB, activa 'Depuración USB' en Opciones de\n       desarrollador y acepta el aviso de autorización del teléfono.
STATUS_CAPTURE	Capture	Captura
WEBCAM_ACTIVE_STATUS	Webcam ACTIVE (PID %s) → %s	Webcam ACTIVA (PID %s) → %s
WEBCAM_INACTIVE	Webcam inactive.	Webcam inactiva.
MIC_ACTIVE_STATUS	Microphone ACTIVE (PID %s) → %s	Micrófono ACTIVO (PID %s) → %s
MIC_INACTIVE	Microphone inactive.	Micrófono inactivo.
STATUS_VIRTUAL	Virtual devices	Dispositivos virtuales
V4L2_PRESENT	Virtual webcam %s is present.	Webcam virtual %s presente.
V4L2_ABSENT	Virtual webcam %s does not exist yet.	Webcam virtual %s no existe todavía.
V4L2_RETRY	     → Try 'sudo modprobe v4l2loopback' or repeat the installation.	     → Prueba 'sudo modprobe v4l2loopback' o repite la instalación.
PACTL_NOT_INSTALLED	'pactl' is not installed (pulseaudio-utils package).	'pactl' no está instalado (paquete pulseaudio-utils).
STATUS_INSTALL_PACTL	     → Run '%s install' to install it.	     → Ejecuta '%s install' para instalarlo.
MIC_PRESENT	Virtual microphone '%s' is present.	Micrófono virtual '%s' presente.
MIC_LAZY	Virtual microphone '%s' not created yet (created the first time you use the microphone).	Micrófono virtual '%s' aún no creado (se crea al usar el micrófono por primera vez).
CAMERA_LIST_FAIL	Could not get the phone's camera list.	No se pudo obtener la lista de cámaras del teléfono.
CAMERA_QUERY	Checking available cameras (this may take a few seconds)...	Consultando cámaras disponibles (puede tardar unos segundos)...
CAMERA_LIST_SHORT_FAIL	Could not get the camera list.	No se pudo obtener la lista de cámaras.
CAMERA_AUTO_ZENITY	Automatic: use the camera orientation from Settings	Automática: usa la orientación de la cámara definida en Configuración
CAMERA_LIST_TEXT	Cameras detected on the phone.\nChoose the one to use as the webcam (saved as default):	Cámaras detectadas en el teléfono.\nElige la que se usará como webcam (se guarda como predeterminada):
CHOOSE_CAMERA	Choose camera	Elegir cámara
CAMERA_COL_ID	ID	ID
CAMERA_COL_DETAIL	Details	Detalle
CAMERA_AUTO_SAVED	The automatic camera will be used according to the selected camera orientation.	Se usará la cámara automática según la orientación de cámara seleccionada.
CAMERA_AUTO_NOTIFY	The automatic camera selection will be used.	Se usará la selección automática de cámara.
CAMERA_SAVED	Camera %s saved as default.	Cámara %s guardada como predeterminada.
CAMERA_SAVED_NOTIFY	It will be used by default the next time you start the webcam.	Se usará por defecto la próxima vez que inicies la webcam.
CAMERA_ID_PROMPT	Camera ID to use ('auto' = automatic, empty = do not change): 	ID de cámara a usar ('auto' = automática, vacío = no cambiar): 
CAMERA_ID_INVALID	Invalid camera ID: it must be a number (see the list above) or 'auto'.	ID de cámara no válido: debe ser un número (mira la lista de arriba) o 'auto'.
CONFIG_SAVE_FAIL	Could not save '%s' to %s.	No se pudo guardar '%s' en %s.
EDITOR_MISSING	No editor was found. Edit the file manually: %s	No se encontró ningún editor. Edita manualmente: %s
CONFIG_PIPE_ERR	Configuration not saved: a field contains the '|' character, which is the form's internal separator.	Configuración no guardada: algún campo contiene el carácter '|', que es el separador interno del formulario.
CONFIG_PIPE_ERR_GUI	Nothing was saved: a field contains the '|' character (used internally as a separator), which shifts the remaining fields.	No se ha guardado nada: algún campo contiene el carácter '|' (usado internamente como separador), lo que descuadra el resto de los campos.
CONFIG_PIPE_FIX	Remove it and try again.	Quítalo y vuelve a intentarlo.
CONFIG_FORMAT_ERR	Configuration not saved: some values have an invalid format.	Configuración no guardada: algunos valores tienen un formato no válido.
CONFIG_FORMAT_FIX	Nothing was saved. Correct these fields and try again:\n\n%s	No se ha guardado nada. Corrige estos campos y vuelve a intentarlo:\n\n%s
CONFIG_SAVED	Configuration saved to %s.	Configuración guardada en %s.
CONFIG_UPDATED	Advanced configuration updated.	Configuración avanzada actualizada.
CONFIG_PARTIAL	Some values could not be saved; check the messages above.	Algunos valores no se han podido guardar; revisa los mensajes de arriba.
HELP_TITLE	How to connect the phone	Cómo conectar el teléfono
STATUS_CONNECTED	connected	conectado
STATUS_NOT_DETECTED	not detected	no detectado
MENU_NO_TTY	No interactive terminal is available, and no usable graphical interface (zenity) was found.	No hay una terminal interactiva disponible, ni una interfaz gráfica (zenity) utilizable.
MENU_TTY_HINT	Run '%s menu' from a terminal, or install zenity.	Ejecuta '%s menu' desde una terminal, o instala zenity.
MENU_TITLE	PhoneCam - choose an option:	PhoneCam - elige una opción:
INVALID_OPTION	Invalid option. Choose a number from the list.	Opción no válida, elige un número de la lista.
MENU_LANGUAGE	Change language	Cambiar idioma
MENU_EXIT	Exit	Salir
MENU_STATUS	View detailed status	Ver estado detallado
MENU_CONFIG	Advanced settings	Configuración avanzada
MENU_HELP	How to connect the phone	Cómo conectar el teléfono
MENU_CHOOSE_CAM	Choose camera	Elegir cámara
MENU_WEBCAM_START	▶  Start webcam only	▶  Iniciar solo webcam
MENU_WEBCAM_STOP	⏹  Stop webcam	⏹  Detener webcam
MENU_MIC_START	▶  Start microphone only	▶  Iniciar solo micrófono
MENU_MIC_STOP	⏹  Stop microphone	⏹  Detener micrófono
MENU_BOTH	▶▶  Start webcam + microphone	▶▶  Iniciar webcam + micrófono
MENU_STOP_ALL	⏹⏹  Stop everything	⏹⏹  Detener todo
MENU_NEED_USB	Requires USB connection and USB debugging	Requiere conexión USB y Depuración USB activada
MENU_STOP_WEBCAM_DESC	Already active: stops it and releases the camera	Ya está activa: la detiene y libera la cámara
MENU_STOP_MIC_DESC	Already active: stops it and releases the virtual microphone	Ya está activo: lo detiene y libera el micrófono virtual
MENU_STOP_ALL_DESC	Stops the webcam and the microphone and releases both devices	Detiene la webcam y el micrófono y libera ambos dispositivos
MENU_BOTH_DESC	Starts both together	Inicia ambos a la vez
MENU_CHOOSE_DESC	Useful with multiple phone cameras — phone must be connected	Útil si el teléfono tiene varias cámaras — el teléfono debe estar conectado
MENU_STATUS_DESC	Connection, active processes and virtual devices	Conexión, procesos activos y dispositivos virtuales
MENU_CONFIG_DESC	Form: video quality, audio codec, automatic mode...	Formulario: calidad de vídeo, códec de audio, modo automático...
MENU_HELP_DESC	Quick step-by-step guide, recommended on first use	Guía rápida paso a paso, recomendada la primera vez
MENU_EXIT_DESC	Closes this menu	Cierra este menú
PHONE_HEADER	<b>Phone as webcam / microphone</b>	<b>Teléfono como webcam / micrófono</b>
PHONE_LABEL	Phone:	Teléfono:
WEBCAM_LABEL	Webcam:	Webcam:
MIC_LABEL	Microphone:	Micrófono:
ACTIVE_F	✓ active	✓ activa
ACTIVE_M	✓ active	✓ activo
INACTIVE	inactive	inactivo
INACTIVE_F	inactive	inactiva
LANGUAGE_CURRENT	Language: %s (press L to switch)	Idioma: %s (pulsa L para cambiar)
LANGUAGE_CURRENT_GUI	Current language: %s	Idioma actual: %s
LANGUAGE_ENGLISH	English	Inglés
LANGUAGE_SPANISH	Spanish	Español
LANG_TOGGLE	Language changed to %s.	Idioma cambiado a %s.
COLUMN_SERIAL	Serial	Serie
COLUMN_MODE	Mode	Modo
COLUMN_ACTION	Action	Acción
COLUMN_DESCRIPTION	Description	Descripción
VALIDATE_SIZE	Resolution: use WIDTHxHEIGHT (e.g. 1920x1080) or 'max'.	Resolución: usa el formato ANCHOxALTO (p. ej., 1920x1080) o 'max'.
VALIDATE_FPS	Camera FPS: must be an integer.	FPS de cámara: debe ser un número entero.
VALIDATE_BITRATE	Audio bitrate: a number followed by K or M, e.g. 192K.	Bitrate de audio: un número seguido de K o M, p. ej. 192K.
CONNECTION_HELP	1) On the phone: Settings → About phone → tap 'Build number' 7 times to enable Developer options.\n2) Open Developer options and enable 'USB debugging'.\n3) Connect the phone to the PC with a USB data cable (not charge-only).\n4) Accept 'Allow USB debugging' on the phone and enable 'Remember this computer'.\n5) Return here and choose 'Start webcam only', 'Start microphone only' or 'Start webcam + microphone'.	1) En el teléfono: Ajustes → Acerca del teléfono → toca 7 veces sobre 'Número de compilación' para activar Opciones de desarrollador.\n2) Entra en Opciones de desarrollador y activa 'Depuración USB'.\n3) Conecta el teléfono al PC con un cable USB de datos (no solo de carga).\n4) Acepta en el teléfono el aviso 'Permitir depuración USB' y marca 'Recordar en este equipo' para no repetirlo cada vez.\n5) Vuelve aquí y elige 'Iniciar solo webcam', 'Iniciar solo micrófono' o 'Iniciar webcam + micrófono'.
GUI_ADB_MISSING	The 'adb' tool is missing.\n\nOpen a terminal and run:\n<tt>%s install</tt>	Falta la herramienta 'adb'.\n\nAbre una terminal y ejecuta:\n<tt>%s install</tt>
GUI_SCRCPY_PREP_FAIL	Could not prepare 'scrcpy' automatically.\n\nInstall it manually, then reopen PhoneCam:\nhttps://github.com/Genymobile/scrcpy/blob/master/doc/linux.md	No se pudo preparar 'scrcpy' automáticamente.\n\nInstálalo manualmente y vuelve a abrir PhoneCam:\nhttps://github.com/Genymobile/scrcpy/blob/master/doc/linux.md
STATUS_DIALOG	PhoneCam status	Estado de PhoneCam
PHONE_DETECTED	Phone detected (%s).\nWhat would you like to start now?	Teléfono detectado (%s).\n¿Qué quieres iniciar ahora?
AGENT_WEBCAM	Phone detected. Starting webcam...	Teléfono detectado. Iniciando la webcam...
AGENT_MIC	Phone detected. Starting microphone...	Teléfono detectado. Iniciando el micrófono...
AGENT_BOTH	Phone detected. Starting webcam + microphone...	Teléfono detectado. Iniciando la webcam + el micrófono...
AGENT_NO_ZENITY	Run 'phonecam menu' to choose a mode.	Ejecuta 'phonecam menu' para elegir un modo.
AGENT_ALREADY	Another PhoneCam agent is already running.	Ya hay otro agente de PhoneCam en ejecución.
AGENT_DISPLAY_FOUND	Graphical session found after %s s.	Sesión gráfica encontrada tras %s s.
AGENT_DISPLAY_MISSING	No graphical session after %s s: no tray icon or phone dialog. In a graphical terminal run: systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XAUTHORITY && systemctl --user restart phonecam-agent	No hay sesión gráfica tras %s s: no habrá icono de bandeja ni diálogo al conectar el teléfono. En un terminal gráfico ejecuta: systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XAUTHORITY && systemctl --user restart phonecam-agent
PHONE_CONNECTED_NOTIFY	Phone connected	Teléfono conectado
PHONE_DISCONNECTED	Phone disconnected. Stopping capture...	Teléfono desconectado. Deteniendo captura...
TRAY_OPEN	Open full menu	Abrir menú completo
TRAY_WEBCAM	Webcam only	Solo webcam
TRAY_MIC	Microphone only	Solo micrófono
TRAY_BOTH	Webcam + microphone	Webcam + micrófono
TRAY_STATUS	View status	Ver estado
TRAY_STOP	Stop everything	Detener todo
TRAY_CONFIG	Settings	Configuración
TRAY_NO_ACTION	Do nothing	No hacer nada
TRAY_EXIT	Exit	Salir
INSTALL_ROOT	Do not run this installer as root. 'sudo' will be requested only when needed.	No ejecutes este instalador como root. Se pedirá 'sudo' solo cuando haga falta.
INSTALL_TITLE	PhoneCam - installer (phone as webcam/microphone)	PhoneCam - instalador (teléfono como webcam/micrófono)
APT_UNAVAILABLE	This installer uses 'apt', which is not available on this system.	Este instalador usa 'apt' y no está disponible en este sistema.
APT_OS	PhoneCam is designed for Linux Mint / Ubuntu / Debian. On other distributions,\n  install the dependencies manually (adb, v4l2loopback, pipewire, zenity,\n  scrcpy >= 2.3.1) and run this script with 'source' to skip the installer, or\n  adapt this section to your package manager.	PhoneCam está pensado para Linux Mint / Ubuntu / Debian. En otras\n  distribuciones instala las dependencias a mano (adb, v4l2loopback, pipewire,\n  zenity, scrcpy >= 2.3.1) y ejecuta este script con 'source' para saltarte el\n  instalador, o adapta esta sección a tu gestor de paquetes.
INSTALL_QUESTION	Install system dependencies and configure PhoneCam now?	¿Instalar dependencias del sistema y configurar PhoneCam ahora?
INSTALL_CANCELLED	Installation cancelled.	Instalación cancelada.
INSTALLING_PACKAGES	Installing system dependencies (your sudo password will be requested)...	Instalando dependencias del sistema (se pedirá la contraseña de sudo)...
APT_UPDATE_FAIL	Could not run 'apt update'. Check your network connection and repositories.	No se pudo ejecutar 'apt update'. Revisa la conexión de red y los repositorios.
INSTALL_ABORT	Installation aborted.	Instalación abortada.
KERNEL_HEADERS_FALLBACK	linux-headers-%s was not found in the repositories; trying linux-headers-generic.	No se encontró linux-headers-%s en los repos; probando linux-headers-generic.
KERNEL_HEADERS_WARN	If the running kernel does not match the latest repository kernel,\n  v4l2loopback may not compile correctly until you reboot into the updated\n  kernel.	Si el kernel en ejecución no coincide con el más reciente del repositorio,\n  puede que v4l2loopback no compile bien hasta que reinicies con el kernel\n  actualizado.
APT_INSTALL_FAIL	One or more packages failed to install (see the apt messages above).	Falló la instalación de uno o más paquetes (ver mensajes de apt arriba).
PKGS_INSTALLED	Packages installed.	Paquetes instalados.
SCRCPY_PREP_INSTALL	Preparing scrcpy (version 2.3.1 or newer is required)...	Preparando scrcpy (se necesita la versión 2.3.1 o superior)...
SCRCPY_INSTALL_WARN	Could not install scrcpy automatically during installation.	No se pudo instalar scrcpy automáticamente durante la instalación.
SCRCPY_INSTALL_RETRY	You can try again later from the menu, or install it manually:	Puedes intentarlo de nuevo más tarde desde el menú, o instalarlo a mano:
SECURE_BOOT	Secure Boot is enabled on this computer.	Secure Boot está activado en este equipo.
MOK_WARN	If this is the first kernel module compiled through DKMS (v4l2loopback), a\n  blue 'MOK Management' screen may appear on the next boot: you will need to\n  enroll the new key so the kernel accepts the module. Follow the on-screen\n  instructions.	Si es la primera vez que se compila un módulo de kernel vía DKMS\n  (v4l2loopback), es posible que en el próximo arranque aparezca la pantalla\n  azul 'MOK Management': tendrás que enrolar la clave nueva para que el kernel\n  acepte cargar el módulo. Sigue las instrucciones en pantalla.
GROUP_ADDED	Added to group '%s'.	Añadido al grupo '%s'.
GROUP_ADD_FAIL	Could not add the user to group '%s'.	No se pudo añadir el usuario al grupo '%s'.
V4L2_SETUP	Configuring v4l2loopback (virtual webcam)...	Configurando v4l2loopback (webcam virtual)...
V4L2_BUSY	/dev/video%s is already in use by another device.	/dev/video%s ya está en uso por otro dispositivo.
V4L2_USE_INSTEAD	Using /dev/video%s instead.	Se usará /dev/video%s en su lugar.
V4L2_CONFIG_UPDATED	V4L2_DEVICE was updated in %s to match.	Se ha actualizado V4L2_DEVICE en %s para que coincida.
V4L2_CONFIG_UPDATE_FAIL	Could not update V4L2_DEVICE in %s: edit it manually and set /dev/video%s.	No se pudo actualizar V4L2_DEVICE en %s: edítalo a mano y pon /dev/video%s.
V4L2_NONE_FREE	No free /dev/video device was found near %s.	No se encontró ningún /dev/video libre cerca de %s.
V4L2_FREE_HINT	Free a device or adjust V4L2_NR_DEFAULT in the script and try again.	Libera algún dispositivo o ajusta V4L2_NR_DEFAULT en el script y vuelve a intentarlo.
V4L2_CONFIG_WRITE_FAIL	Could not write the v4l2loopback configuration to /etc (permissions, full disk, or another problem).	No se pudo escribir la configuración de v4l2loopback en /etc (¿permisos, disco lleno?).
V4L2_REBOOT_WARN	The webcam may work now, but it will not survive a reboot.	La webcam puede funcionar ahora, pero no sobrevivirá a un reinicio.
V4L2_RELOAD	v4l2loopback was already loaded; it will be reloaded with PhoneCam's configuration.	v4l2loopback ya estaba cargado; se recargará con la configuración de PhoneCam.
V4L2_UNLOAD_FAIL	Could not unload it (it may be in use). Reboot if anything fails.	No se pudo descargar (puede estar en uso). Reinicia si algo falla.
V4L2_LOAD_FAIL	Could not load v4l2loopback right now (you may need to reboot).	No se pudo cargar v4l2loopback ahora mismo (puede que necesites reiniciar).
V4L2_CREATED	Virtual webcam created at /dev/video%s	Webcam virtual creada en /dev/video%s
V4L2_NOT_YET	/dev/video%s does not appear yet. Reboot if it persists after installation.	/dev/video%s no aparece todavía. Reinicia el equipo si persiste tras la instalación.
INSTALLING_PHONECAM	Installing PhoneCam in %s...	Instalando PhoneCam en %s...
INSTALLED_COPY	The installed copy is already running; nothing to copy.	Ya se está ejecutando la copia instalada; no hace falta copiar.
INSTALL_COPY_FAIL	Could not copy the script to %s.	No se pudo copiar el script a %s.
INSTALL_FILE_WRITE_FAIL	Could not write '%s'. Check permissions and free space.	No se pudo escribir '%s'. Comprueba los permisos y el espacio libre.
SCRIPT_INSTALLED	Script installed.	Script instalado.
PATH_ADDED	~/.local/bin was added to PATH in ~/.profile (effective at the next login).	Se añadió ~/.local/bin al PATH en ~/.profile (aplica al iniciar sesión de nuevo).
PROFILE_ADDED	Added by the PhoneCam installer	Añadido por el instalador de PhoneCam
CONFIG_CREATED	Configuration created at %s	Configuración creada en %s
CONFIG_TEMPLATE	# =============================================================\n#  PhoneCam - configuration\n#  You can edit this file manually or with: phonecam config\n# =============================================================\n\n# ---------- Camera selection ----------\n# CAMERA_ID empty = use CAMERA_FACING to select automatically.\n# A camera selected from the menu ("Choose camera") is stored here and\n# its --camera-id takes priority over CAMERA_FACING.\nCAMERA_ID=""\nCAMERA_FACING="back"        # back | front | external\nCAMERA_SIZE=""              # empty = phone's maximum declared resolution\nCAMERA_FPS="30"\n\n# ---------- Video quality profile ----------\n# balanced -> H.264, high bitrate, minimum latency (recommended for video calls)\n# max      -> H.265, higher bitrate, better quality, slightly more decoder latency\nVIDEO_QUALITY_PROFILE="balanced"\nVIDEO_BITRATE_BALANCED="20M"\nVIDEO_BITRATE_MAX="30M"\n\n# ---------- Audio (phone microphone) ----------\nAUDIO_CODEC="opus"          # opus | aac | flac | raw\nAUDIO_BITRATE="192K"\nAUDIO_SOURCE="mic"          # mic | mic-unprocessed | mic-voice-communication | mic-voice-recognition | mic-camcorder (all but mic: scrcpy 3.2+)\n\n# ---------- Virtual video device (v4l2loopback) ----------\nV4L2_DEVICE="/dev/video%s"\n\n# ---------- Virtual audio devices (PipeWire / PulseAudio) ----------\nMIC_SINK_NAME="PhoneMicSink"\nMIC_SOURCE_NAME="PhoneMic"\n\n# ---------- Interface language ----------\n# auto -> use Spanish if the system locale is Spanish; English otherwise\n# en / es -> force that language\nPHONECAM_LANG="auto"\n\n# ---------- Auto-start when the USB phone connects ----------\n# ask -> ask which mode to start\n# webcam / mic / both -> start that mode automatically without asking\n# off -> do nothing automatically (manual use with "phonecam")\nAUTO_MODE="ask"\n\n# ---------- Phone behavior while in use ----------\nTURN_SCREEN_OFF="false"     # turn off the phone screen when capture starts\nKEEP_AWAKE="true"           # keep the phone awake while capturing	# =============================================================\n#  PhoneCam - configuración\n#  Puedes editar este archivo a mano o con: phonecam config\n# =============================================================\n\n# ---------- Selección de cámara ----------\n# CAMERA_ID vacío = se usa CAMERA_FACING para elegir automáticamente.\n# Si eliges una cámara desde el menú ("Elegir cámara"), se guarda aquí y\n# su --camera-id tiene prioridad sobre CAMERA_FACING.\nCAMERA_ID=""\nCAMERA_FACING="back"        # back | front | external\nCAMERA_SIZE=""              # vacío = resolución máxima declarada por el teléfono\nCAMERA_FPS="30"\n\n# ---------- Perfil de calidad de vídeo ----------\n# balanced -> H.264, bitrate alto, mínima latencia (recomendado para videollamadas)\n# max      -> H.265, mayor bitrate, mejor calidad, algo más de latencia de decodificación\nVIDEO_QUALITY_PROFILE="balanced"\nVIDEO_BITRATE_BALANCED="20M"\nVIDEO_BITRATE_MAX="30M"\n\n# ---------- Audio (micrófono del teléfono) ----------\nAUDIO_CODEC="opus"          # opus | aac | flac | raw\nAUDIO_BITRATE="192K"\nAUDIO_SOURCE="mic"          # mic | mic-unprocessed | mic-voice-communication | mic-voice-recognition | mic-camcorder (todas menos mic: scrcpy 3.2+)\n\n# ---------- Dispositivo de vídeo virtual (v4l2loopback) ----------\nV4L2_DEVICE="/dev/video%s"\n\n# ---------- Dispositivos de audio virtuales (PipeWire / PulseAudio) ----------\nMIC_SINK_NAME="PhoneMicSink"\nMIC_SOURCE_NAME="PhoneMic"\n\n# ---------- Idioma de la interfaz ----------\n# auto -> usa español si el locale del sistema es español; inglés en cualquier otro caso\n# en / es -> fuerza ese idioma\nPHONECAM_LANG="auto"\n\n# ---------- Autoarranque al conectar el USB ----------\n# ask -> pregunta qué modo iniciar\n# webcam / mic / both -> inicia ese modo automáticamente sin preguntar\n# off -> no hace nada automático (solo uso manual con "phonecam")\nAUTO_MODE="ask"\n\n# ---------- Comportamiento del teléfono mientras está en uso ----------\nTURN_SCREEN_OFF="false"     # apaga la pantalla del móvil al iniciar la captura\nKEEP_AWAKE="true"           # mantiene despierto el móvil mientras captura
CONFIG_EXISTS	An existing configuration was found; it was not overwritten.	Ya existe una configuración previa, no se sobrescribe.
DESKTOP_CREATED	Application launcher created.	Lanzador de aplicaciones creado.
AGENT_ENABLED	Automatic startup agent enabled (systemd --user).	Agente de autoarranque activado (systemd --user).
AGENT_ENABLE_FAIL	Could not enable the user service automatically.	No se pudo activar el servicio de usuario automáticamente.
AGENT_ENABLE_MANUAL	Run manually: systemctl --user enable --now phonecam-agent.service	Ejecútalo manualmente con: systemctl --user enable --now phonecam-agent.service
INSTALL_COMPLETE	Installation completed.	Instalación completada.
USAGE_LABEL	Usage:	Uso:
PHONE_LABEL_INSTALL	On the phone:	En el teléfono:
PHONE_STEPS	  1) Enable Developer options -> USB debugging.\n  2) Connect it by USB cable and accept the authorization dialog.\n  3) PhoneCam will detect it automatically when connected\n     (mode configured in %s -> AUTO_MODE).	  1) Activa Opciones de desarrollador -> Depuración USB.\n  2) Conéctalo por cable USB y acepta el diálogo de autorización.\n  3) Al conectarlo, PhoneCam lo detectará automáticamente\n     (modo configurado en %s -> AUTO_MODE).
RELOGIN_GROUPS	You were added to new groups (video/plugdev).	Se te añadió a nuevos grupos (video/plugdev).
RELOGIN_NEEDED	You must LOG OUT and back in (or reboot) for them to take effect.	Debes CERRAR SESIÓN y volver a entrar (o reiniciar) para que tengan efecto.
UNINSTALL_ROOT	Do not run this as root.	No ejecutes esto como root.
UNINSTALL_TMP_FAIL	Could not create a temporary file in /tmp.	No se pudo crear un archivo temporal en /tmp.
UNINSTALL_STOP	Stopping active processes...	Deteniendo procesos activos...
UNINSTALL_AGENT	Stopping the background agent...	Desactivando el agente en segundo plano...
UNINSTALL_SCRIPT	Removing installed script...	Eliminando script instalado...
UNINSTALL_DESKTOP	Removing application launcher...	Eliminando lanzador de aplicaciones...
UNINSTALL_SCRCPY	Removing scrcpy downloaded by PhoneCam...	Eliminando scrcpy descargado por PhoneCam...
UNINSTALL_MIC	Releasing virtual microphone (PipeWire/PulseAudio)...	Liberando el micrófono virtual (PipeWire/PulseAudio)...
UNINSTALL_LOGS	Removing temporary files and logs...	Eliminando archivos temporales y registros...
UNINSTALL_CONFIG_Q	Remove the configuration in %s too? [y/N]: 	¿Eliminar también la configuración en %s? [s/N]: 
CONFIG_REMOVED	Configuration removed.	Configuración eliminada.
REVERT_V4L2	To revert the v4l2loopback virtual webcam:	Para revertir la webcam virtual v4l2loopback:
KEEP_PACKAGES	System packages (v4l2loopback-dkms, pipewire...) were not uninstalled because\n  other applications may depend on them. You can remove them manually with apt\n  if you want.	Los paquetes del sistema (v4l2loopback-dkms, pipewire...) no se han\n  desinstalado porque otras aplicaciones pueden depender de ellos. Puedes\n  quitarlos manualmente con apt si quieres.
UNINSTALL_DONE	PhoneCam uninstalled.	PhoneCam desinstalado.
USAGE_TITLE	PhoneCam — use your Android as a webcam/microphone via USB (Linux Mint / Cinnamon)	PhoneCam — usa tu Android como webcam/micrófono por USB (Linux Mint / Cinnamon)
USAGE_INSTALL	Install system dependencies and leave "phonecam" ready\nfor use (use --yes to install without questions)	Instala dependencias del sistema y deja "phonecam" listo para usar\n(acepta --yes para instalar sin preguntas)
USAGE_UNINSTALL	Uninstall PhoneCam (does not touch system packages)	Desinstala PhoneCam (no toca los paquetes del sistema)
USAGE_MENU	Open the menu (graphical with zenity, text otherwise) [default]	Abre el menú (gráfico si hay zenity, texto si no) [por defecto]
USAGE_WEBCAM	Start only the phone camera as a webcam	Inicia solo la cámara del teléfono como webcam
USAGE_MIC	Start only the phone microphone	Inicia solo el micrófono del teléfono
USAGE_BOTH	Start camera + microphone together	Inicia cámara + micrófono a la vez
USAGE_STOP	Stop all PhoneCam processes	Detiene todos los procesos de PhoneCam
USAGE_STATUS	Show current status	Muestra el estado actual
USAGE_CAMERAS	List phone cameras	Lista las cámaras disponibles en el teléfono
USAGE_CHOOSE	Choose and save the default camera	Elige y guarda la cámara predeterminada
USAGE_CONFIG	Open the configuration file in an editor	Abre el archivo de configuración en un editor
USAGE_HELP	Quick guide: connect and authorize the phone	Guía rápida: cómo conectar y autorizar el teléfono
USAGE_VERSION	Show the installed version	Muestra la versión instalada
USAGE_AGENT	(internal, via systemd --user) background agent	(uso interno, vía systemd --user) agente en segundo plano
USAGE_LANG	Toggle interface language (English / Spanish)	Cambia el idioma de la interfaz (inglés / español)
UNKNOWN_COMMAND	Unknown command: %s	Comando desconocido: %s
USAGE_COMMAND	Usage: %s <command>	Uso: %s <comando>
INSTALL_ABORT_RESUME	Installation aborted: run '%s install' again once this is resolved.	Instalación abortada: vuelve a ejecutar '%s install' cuando esté resuelto.
DESKTOP_GENERIC	Android phone as webcam and microphone	Móvil Android como webcam y micrófono
DESKTOP_COMMENT	Use your Android as a webcam and/or microphone over USB	Usa tu Android como webcam y/o micrófono por USB
DESKTOP_DESCRIPTION	PhoneCam - USB detection agent and system tray	PhoneCam - agente de detección USB y bandeja del sistema
ADV_TITLE	PhoneCam — Advanced settings	PhoneCam — Configuración avanzada
ADV_TEXT	Adjust the settings you need and press OK to save them to %s.\nLeave a text field empty to leave that value unchanged.\nYou can also continue editing the file manually if you prefer.	Ajusta lo que necesites y pulsa Aceptar para guardarlos en %s.\nDeja un campo de texto vacío para no cambiar ese valor.\nTambién puedes seguir editando el archivo a mano si lo prefieres.
ADV_FACING	Camera orientation	Orientación de la cámara
ADV_FACING_LOCKED	 [ignored: fixed camera #%s; use 'Choose camera' -> '(auto)' to remove it]	 [ignorado: hay cámara fija #%s; usa 'Elegir cámara' -> '(auto)' para quitarla]
ADV_SIZE	Camera resolution (empty = unchanged; 'max' = maximum; e.g. 1920x1080; current: %s)	Resolución de cámara (vacío = sin cambios; 'max' = máxima; p. ej., 1920x1080; actual: %s)
ADV_MAX	maximum	máxima
ADV_FPS	Camera FPS (current: %s)	FPS de cámara (actual: %s)
ADV_PROFILE	Video quality profile	Perfil de calidad de vídeo
ADV_SOURCE	Audio source	Fuente de audio
ADV_CODEC	Audio codec	Códec de audio
ADV_BITRATE	Audio bitrate (current: %s)	Tasa de bits de audio (actual: %s)
ADV_AUTO	Automatic mode when the phone connects	Modo automático al conectar el teléfono
ADV_SCREEN	Turn off the phone screen when starting	Apagar la pantalla del teléfono al iniciar
ADV_AWAKE	Keep the phone awake	Mantener el teléfono despierto
EOF
}

# "es", "ES", "es_MX.UTF-8", "en-US"... -> "es" | "en"; nothing for any other value (auto, C, fr_FR...).
normalize_language() {
    case "${1,,}" in
        es|es[_.@-]*) echo "es" ;;
        en|en[_.@-]*) echo "en" ;;
    esac
}

detect_system_language() {
    local code
    code="$(normalize_language "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}")"
    echo "${code:-en}"
}

set_language_context() {
    local code
    code="$(normalize_language "${PHONECAM_LANG_ENV:-${PHONECAM_LANG:-auto}}")"
    CURRENT_LANG="${code:-$(detect_system_language)}"
}

t() {
    local key="$1" text
    shift
    if [ "$CURRENT_LANG" = "es" ]; then
        text="${MSG_ES[$key]:-${MSG_EN[$key]:-[$key]}}"
    else
        text="${MSG_EN[$key]:-[${key}]}"
    fi
    if [ "$#" -eq 0 ]; then
        printf '%b' "$text"
    else
        # shellcheck disable=SC2059  # catalog entries are the printf format
        printf -- "$text" "$@"
    fi
}

language_name() { if [ "$CURRENT_LANG" = "es" ]; then t LANGUAGE_SPANISH; else t LANGUAGE_ENGLISH; fi; }

toggle_language() {
    if [ "$CURRENT_LANG" = "es" ]; then
        set_config PHONECAM_LANG "en" || return 1
    else
        set_config PHONECAM_LANG "es" || return 1
    fi
    PHONECAM_LANG_ENV=""
    set_language_context
    info "$(t LANG_TOGGLE "$(language_name)")"
}

load_messages
set_language_context

# ---- Real script path
SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"

# ---- User installation/data paths
CONF_DIR="$HOME/.config/phonecam"
CONF_FILE="$CONF_DIR/phonecam.conf"
RUN_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache}/phonecam"
LOG_DIR="$HOME/.local/share/phonecam/logs"
BIN_DIR="$HOME/.local/bin"
INSTALLED_BIN="$BIN_DIR/phonecam"
SCRCPY_DIR="$HOME/.local/share/phonecam/scrcpy"
DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/phonecam.desktop"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SYSTEMD_SERVICE_FILE="$SYSTEMD_USER_DIR/phonecam-agent.service"
ICON_FILE="$HOME/.local/share/icons/hicolor/1024x1024/apps/phonecam.png"
ICON_SOURCE="$(dirname "$SELF_PATH")/../assets/phonecam-icon.png"

PID_WEBCAM="$RUN_DIR/webcam.pid"
PID_MIC="$RUN_DIR/mic.pid"
PID_ROUTE="$RUN_DIR/route.pid"
PID_AGENT="$RUN_DIR/agent.pid"
TRAY_PID=""

V4L2_NR_DEFAULT=42
V4L2_LABEL="PhoneCam"

# ---- Output helpers
use_color() { [ -t 1 ]; }

use_color_err() { [ -t 2 ]; }

# printf '%s': echo -e would expand backslashes a second time.
info()  { if use_color; then printf '\e[34mℹ\e[0m %s\n' "$*"; else echo "ℹ $*"; fi; }
ok()    { if use_color; then printf '\e[32m✓\e[0m %s\n' "$*"; else echo "✓ $*"; fi; }
warn()  { if use_color; then printf '\e[33m⚠\e[0m %s\n' "$*"; else echo "⚠ $*"; fi; }
err()   { if use_color_err; then printf '\e[31m✗\e[0m %s\n' "$*" >&2; else echo "✗ $*" >&2; fi; }
hdr()   { if use_color; then printf '\e[1m%s\e[0m\n' "$*"; else echo "$*"; fi; }

# ---- Atomic file replacement
# Mode of file $1 minus world-write; default $2 if unreadable.
existing_file_mode() {
    local mode
    mode="$(stat -L -c '%a' -- "$1" 2>/dev/null)"
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || { printf '%s\n' "${2:-644}"; return 0; }
    printf '%o\n' $((8#$mode & ~8#002))
}

# atomic_write_file DEST [MODE]: stdin goes to a private temp file beside DEST, synced (best effort) and renamed over it, so
# readers never see a partial file. A destination symlink is replaced, not followed.
atomic_write_file() {
    local dest="${1:-}" mode="${2:-644}"
    [ -n "$dest" ] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (
        dir="$(dirname -- "$dest")"
        base="$(basename -- "$dest")"
        mkdir -p -- "$dir" || exit 1
        tmp="$(mktemp -- "$dir/.$base.XXXXXX")" || exit 1
        trap 'rm -f -- "$tmp"' EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        cat > "$tmp" && chmod "$mode" "$tmp" || exit 1
        sync -- "$tmp" 2>/dev/null || :
        mv -fT -- "$tmp" "$dest" || exit 1
        sync -- "$dir" 2>/dev/null || :
    )
}

# atomic_write_file through sudo (root-owned temp file beside DEST).
sudo_atomic_write_file() {
    local dest="${1:-}" mode="${2:-644}"
    [ -n "$dest" ] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (
        dir="$(dirname -- "$dest")"
        base="$(basename -- "$dest")"
        [ -d "$dir" ] || exit 1
        tmp="$(sudo mktemp -- "$dir/.$base.XXXXXX")" || exit 1
        trap 'sudo rm -f -- "$tmp" 2>/dev/null' EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        sudo tee "$tmp" >/dev/null && sudo chmod "$mode" "$tmp" || exit 1
        sudo sync -- "$tmp" 2>/dev/null || :
        sudo mv -fT -- "$tmp" "$dest" || exit 1
        sudo sync -- "$dir" 2>/dev/null || :
    )
}

# atomic_append_file DEST: appends stdin to DEST under a lock, through a temp file renamed over it (no lost lines, no partial reads).
atomic_append_file() {
    local dest="${1:-}"
    [ -n "$dest" ] || return 1
    (
        dir="$(dirname -- "$dest")"
        base="$(basename -- "$dest")"
        mode=644
        mkdir -p -- "$dir" "$RUN_DIR" || exit 1
        exec 7>>"$RUN_DIR/append-$base.lock" || exit 1
        flock -x 7 || exit 1
        if [ -e "$dest" ] || [ -L "$dest" ]; then
            [ -f "$dest" ] || exit 1
            mode="$(existing_file_mode "$dest" 644)"
        fi
        tmp="$(mktemp -- "$dir/.$base.XXXXXX")" || exit 1
        trap 'rm -f -- "$tmp"' EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        { [ ! -f "$dest" ] || cat -- "$dest"; } > "$tmp" && cat >> "$tmp" && chmod "$mode" "$tmp" || exit 1
        sync -- "$tmp" 2>/dev/null || :
        mv -fT -- "$tmp" "$dest" || exit 1
        sync -- "$dir" 2>/dev/null || :
    )
}

NONINTERACTIVE=0
YES_RE='^(s|si|sí|sÍ|y|yes)$'   # sÍ is "SÍ" lowercased in a byte locale (C/POSIX), where ${var,,} cannot fold Í

ask_yn() {
    local prompt="$1" default="${2:-y}" reply hint yes=y
    if [ "$NONINTERACTIVE" -eq 1 ]; then
        [ "$default" = "y" ] && return 0 || return 1
    fi
    [ "$CURRENT_LANG" = "es" ] && yes=s
    if [ "$default" = "y" ]; then hint="${yes^^}/n"; else hint="$yes/N"; fi
    read -rp "$prompt [$hint]: " reply
    reply="${reply:-$default}"
    [[ "${reply,,}" =~ $YES_RE ]]
}

notify() {
    if command -v notify-send >/dev/null 2>&1; then
        timeout 2s notify-send -a "PhoneCam" "$1" "${2:-}" >/dev/null 2>&1 || true
    fi
    return 0
}

window_icon() {
    [ -r "$ICON_FILE" ] && printf '%s\n' "$ICON_FILE" || printf '%s\n' "camera-web"
}

have_gui() { command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; }

# zenity reads --text as Pango markup: a bare & or < in captured output would leave the dialog blank.
markup_escape() {
    local s="$1"
    s="${s//&/"&amp;"}"   # replacements are quoted: bash 5.2 turns an unquoted & into the matched text
    s="${s//</"&lt;"}"
    printf '%s' "${s//>/"&gt;"}"
}

gui_error() { zenity --error --title="PhoneCam" --window-icon="$(window_icon)" --width="$1" --text="$2" 2>/dev/null; }

# ---- Configuration
CAMERA_ID=""
CAMERA_FACING="back"
CAMERA_SIZE=""
CAMERA_FPS="30"
VIDEO_QUALITY_PROFILE="balanced"
VIDEO_BITRATE_BALANCED="20M"
VIDEO_BITRATE_MAX="30M"
AUDIO_CODEC="opus"
AUDIO_BITRATE="192K"
AUDIO_SOURCE="mic"
V4L2_DEVICE="/dev/video${V4L2_NR_DEFAULT}"
MIC_SINK_NAME="PhoneMicSink"
MIC_SOURCE_NAME="PhoneMic"
AUTO_MODE="ask"
TURN_SCREEN_OFF="false"
KEEP_AWAKE="true"

load_config() {
    mkdir -p "$CONF_DIR" "$RUN_DIR" "$LOG_DIR"
    if [ -f "$CONF_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONF_FILE"
    else
        warn "$(t CONF_MISSING "$CONF_FILE")"
        warn "$(t CONF_INSTALL_FIRST "$(basename "$SELF_PATH")")"
    fi
    set_language_context
}

load_language_preference() {
    if [ -f "$CONF_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONF_FILE"
    fi
    set_language_context
}

# ---- Dependency checks
require_tools() {
    local missing=() t
    for t in adb pactl; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        err "$(t TOOLS_MISSING "${missing[*]}")"
        err "$(t INSTALL_FIRST "$(basename "$SELF_PATH")")"
        return 1
    fi

    if ! ensure_scrcpy_installed; then
        err "$(t SCRCPY_UNAVAILABLE)"
        err "$(t SCRCPY_MANUAL)"
        return 1
    fi
    return 0
}

# ---- ADB device selection
# adb for at most $1 s, stdin empty (adb shell eats a caller's loop input), lock fds 6 (keep-awake) and 9 (start, settings)
# closed: an adb server started here would inherit them and hold the flocks.
adb_run() { local secs="$1"; shift; timeout "$secs" adb "$@" 6>&- 9>&- < /dev/null; }

adb_serial() {
    adb_run 10 start-server >/dev/null 2>&1
    local list count
    list=$(adb_run 10 devices | awk 'NR>1 && $2=="device" {print $1}')
    count=$(printf '%s\n' "$list" | grep -c . || true)

    if [ "$count" -eq 0 ]; then
        err "$(t NO_ADB_PHONE)"
        {
            echo "$(t ADB_USB)"
            echo "$(t ADB_DEBUG)"
            echo "$(t ADB_ACCEPT)"
            echo "$(t ADB_CHECK)"
        } >&2
        return 1
    elif [ "$count" -eq 1 ]; then
        printf '%s\n' "$list"
        return 0
    else
        if have_gui; then
            local chosen
            chosen=$(printf '%s\n' "$list" | zenity --list --title="PhoneCam" \
                --text="$(t MULTI_DEVICE_CHOOSE)" \
                --column="$(t COLUMN_SERIAL)" 2>/dev/null)
            [ -n "$chosen" ] && { echo "$chosen"; return 0; }
            warn "$(t NO_DEVICE_CHOSEN)" >&2
            return 1
        else
            local first
            first=$(printf '%s\n' "$list" | head -1)
            warn "$(t MULTI_DEVICE "$first")" >&2
            printf '%s\n' "$first"
            return 0
        fi
    fi
}

# ---- scrcpy version check (PhoneCam requires >= 2.3.1)
check_scrcpy_version() {
    local raw rc ver major minor patch
    raw=$(scrcpy --version 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        warn "$(t SCRCPY_VERSION_FAIL "$rc")"
        printf '%s\n' "$raw" | head -3 | while IFS= read -r line; do warn "  $line"; done
        return 1
    fi
    ver=$(printf '%s\n' "$raw" | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    if [ -z "$ver" ]; then
        warn "$(t SCRCPY_VERSION_UNKNOWN)"
        return 1
    fi
    IFS=. read -r major minor patch <<< "$ver"
    patch="${patch:-0}"
    major=$((10#$major))
    minor=$((10#$minor))
    patch=$((10#$patch))
    if [ "$major" -lt 2 ] || \
       { [ "$major" -eq 2 ] && [ "$minor" -lt 3 ]; } || \
       { [ "$major" -eq 2 ] && [ "$minor" -eq 3 ] && [ "$patch" -lt 1 ]; }; then
        err "$(t SCRCPY_TOO_OLD "$ver")"
        err "$(t SCRCPY_UPDATE)"
        return 1
    fi
    return 0
}

scrcpy_at_least() {
    local raw
    raw=$(scrcpy --version 2>&1) || return 1
    [[ "${raw%%$'\n'*}" =~ ([0-9]+)\.([0-9]+) ]] || return 1
    (( 10#${BASH_REMATCH[1]} > $1 || (10#${BASH_REMATCH[1]} == $1 && 10#${BASH_REMATCH[2]} >= $2) ))
}

# Every audio source except plain "mic" (mic-*, voice-*) arrived with scrcpy 3.2; older versions reject it.
audio_source_supported() {
    case "$1" in
        mic-*|voice-*) scrcpy_at_least 3 2 ;;
    esac
}

# ---- Automatic scrcpy installation (official static build)

fetch_to_stdout() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 60 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout=10 --tries=2 "$url"
    else
        return 127
    fi
}

fetch_to_file() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 2 --connect-timeout 10 --max-time 300 --progress-bar -o "$out" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --show-progress --timeout=10 --tries=2 -O "$out" "$url"
    else
        return 127
    fi
}

# Resolves the "latest" release tag from the releases page redirect, not api.github.com (60 unauthenticated requests/hour).
latest_scrcpy_tag() {
    local url="https://github.com/Genymobile/scrcpy/releases/latest" resolved tag
    if command -v curl >/dev/null 2>&1; then
        resolved="$(curl -fsS -o /dev/null -w '%{url_effective}' --connect-timeout 10 --max-time 15 -L "$url" 2>/dev/null)"
    elif command -v wget >/dev/null 2>&1; then
        resolved="$(wget -q --max-redirect=20 --server-response --timeout=10 -O /dev/null "$url" 2>&1 \
            | awk 'tolower($1) == "location:" { loc=$2 } END { print loc }')"
    else
        return 127
    fi
    tag="${resolved##*/releases/tag/}"
    [[ "$tag" =~ ^v[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
    printf '%s\n' "$tag"
}

# Accepts only a tarball whose entries all sit under one top-level directory, are plain files or directories
# (no links or special files) and have no absolute or ".." path. tar lists control characters and backslashes
# with a "\" escape (TAR_OPTIONS is unset so it cannot change that), so a name containing "\" is rejected.
validate_scrcpy_archive() {
    local archive="$1" member entry_type listing top_root top_name
    listing=$(env -u TAR_OPTIONS tar -tzf "$archive") || return 1
    top_root=""
    while IFS= read -r member; do
        case "$member" in
            ''|*\\*|/*|..|../*|*/../*|*/..) return 1 ;;
        esac
        case "$member" in
            */*)
                top_name="${member%%/*}"
                [ -n "$top_name" ] || return 1
                if [ -z "$top_root" ]; then
                    top_root="$top_name"
                elif [ "$top_name" != "$top_root" ]; then
                    return 1
                fi
                ;;
            *)
                return 1
                ;;
        esac
    done <<< "$listing"
    [ -n "$top_root" ] || return 1

    listing=$(env -u TAR_OPTIONS tar -tvzf "$archive") || return 1
    while IFS= read -r member; do
        entry_type="${member:0:1}"
        case "$entry_type" in
            -|d) ;;
            *) return 1 ;;
        esac
    done <<< "$listing"
    return 0
}

ensure_downloader() {
    command -v curl >/dev/null 2>&1 && return 0
    command -v wget >/dev/null 2>&1 && return 0
    warn "$(t DOWNLOADER_MISSING)"
    if [ "$NONINTERACTIVE" -eq 1 ] || { [ -t 0 ] && ask_yn "$(t INSTALL_CURL)" y; }; then
        sudo apt install -y curl && return 0
    fi
    return 1
}

# Callers check have_gui first.
run_with_zenity_progress() {
    local text="$1"; shift
    "$@" &
    local pid=$!
    ( while kill -0 "$pid" 2>/dev/null; do echo "#$text"; sleep 1; done ) \
        | zenity --progress --pulsate --auto-close --no-cancel \
            --title="PhoneCam" --window-icon="$(window_icon)" --width=380 \
            --text="$text" 2>/dev/null
    wait "$pid"
}

# SHA-256 of file $1 from a SHA256SUMS text on stdin. No {64}: mawk 1.3.4-20200120 (Mint 21) reads braces literally.
checksum_for_file() {
    awk -v file="$1" '{f=$2; sub(/^\*/, "", f); if (f == file && length($1) == 64 && $1 !~ /[^[:xdigit:]]/) {print $1; exit}}'
}

fetch_scrcpy_tree() {
    local url="$1" dir="$2" tarball="$2/scrcpy.tar.gz" expected
    info "$(t SCRCPY_DOWNLOADING "$(basename "$url")")"
    fetch_to_file "$url" "$tarball" || { err "$(t SCRCPY_DOWNLOAD_FAIL)"; return 1; }
    expected=$(fetch_to_stdout "${url%/*}/SHA256SUMS.txt" | checksum_for_file "$(basename "$url")")
    if ! command -v sha256sum >/dev/null 2>&1 || [ -z "$expected" ] || [ "$(sha256sum "$tarball" | awk '{print $1}')" != "$expected" ]; then
        err "$(t SCRCPY_CHECKSUM_FAIL)"
        return 1
    fi
    validate_scrcpy_archive "$tarball" || { err "$(t SCRCPY_ARCHIVE_UNSAFE)"; return 1; }
    info "$(t SCRCPY_EXTRACTING)"
    env -u TAR_OPTIONS tar --no-same-owner --no-same-permissions -xzf "$tarball" -C "$dir" || { err "$(t SCRCPY_EXTRACT_FAIL)"; return 1; }
}

# Installs scrcpy tree $1 as $SCRCPY_DIR plus its $BIN_DIR link, staged beside them under an exclusive lock; the old install
# is restored if a final rename fails, and the subshell's trap removes leftover staging.
install_scrcpy_tree() {
    local src="$1" parent
    parent="$(dirname "$SCRCPY_DIR")"
    mkdir -p "$parent" "$BIN_DIR" || return 1
    (
        staging="" link_stage="" backup=""
        trap 'rm -rf -- "$staging" "$link_stage" "$backup"' EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        exec 8>"$parent/.install.lock" && flock -x 8 || exit 1
        staging="$(mktemp -d "$parent/.scrcpy-new.XXXXXX")" || exit 1
        link_stage="$(mktemp -d "$BIN_DIR/.scrcpy-link.XXXXXX")" || exit 1
        cp -a "$src"/. "$staging"/ && chmod +x "$staging/scrcpy" && ln -s "$SCRCPY_DIR/scrcpy" "$link_stage/scrcpy" || exit 1
        if [ -e "$SCRCPY_DIR" ] || [ -L "$SCRCPY_DIR" ]; then
            backup="$(mktemp -d "$parent/.scrcpy-old.XXXXXX")" && mv -- "$SCRCPY_DIR" "$backup/old" || exit 1
        fi
        if ! { mv -- "$staging" "$SCRCPY_DIR" && mv -fT -- "$link_stage/scrcpy" "$BIN_DIR/scrcpy"; }; then
            rm -rf -- "$SCRCPY_DIR"
            [ -z "$backup" ] || mv -- "$backup/old" "$SCRCPY_DIR" 2>/dev/null
            exit 1
        fi
    )
}

download_scrcpy_release() {
    ensure_downloader || return 1

    local arch; arch="$(uname -m)"
    if [ "$arch" != "x86_64" ]; then
        err "$(t NO_STATIC_BUILD "$arch")"
        err "$(t SCRCPY_MANUAL_BUILD)"
        return 1
    fi

    info "$(t CHECK_SCRCPY_GITHUB)"
    local tag tarball_url
    tag=$(latest_scrcpy_tag) || tag=""

    if [ -z "$tag" ]; then
        err "$(t SCRCPY_URL_FAIL)"
        err "$(t SCRCPY_LATEST)"
        return 1
    fi
    tarball_url="https://github.com/Genymobile/scrcpy/releases/download/$tag/scrcpy-linux-x86_64-$tag.tar.gz"

    local tmp_dir src rc=1
    tmp_dir="$(mktemp -d)" || return 1
    if fetch_scrcpy_tree "$tarball_url" "$tmp_dir"; then
        src=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
        if [ -z "$src" ] || [ ! -x "$src/scrcpy" ]; then
            err "$(t SCRCPY_BINARY_MISSING)"
        elif install_scrcpy_tree "$src"; then
            rc=0
        else
            err "$(t SCRCPY_INSTALL_FAIL)"
        fi
    fi
    rm -rf -- "$tmp_dir"
    [ "$rc" -eq 0 ] || return 1

    if [ -x "$BIN_DIR/scrcpy" ]; then
        ok "$(t SCRCPY_INSTALLED "$SCRCPY_DIR" "$BIN_DIR")"
        return 0
    fi
    err "$(t SCRCPY_NOT_OPERATIONAL)"
    return 1
}

ensure_scrcpy_installed() {
    if command -v scrcpy >/dev/null 2>&1 && check_scrcpy_version >/dev/null 2>&1; then
        return 0
    fi

    if command -v scrcpy >/dev/null 2>&1; then
        warn "$(t SCRCPY_TOO_OLD_WARN)"
    else
        warn "$(t SCRCPY_NOT_FOUND)"
    fi

    if [ "$NONINTERACTIVE" -ne 1 ]; then
        if [ -t 0 ]; then
            ask_yn "$(t SCRCPY_AUTO_QUESTION)" y || {
                warn "$(t SCRCPY_CANCELLED)"
                return 1
            }
        elif have_gui; then
            zenity --question --title="PhoneCam" --window-icon="$(window_icon)" --width=460 \
                --text="$(t GUI_SCRCPY_QUESTION)" \
                2>/dev/null || { warn "$(t SCRCPY_CANCELLED)"; return 1; }
        else
            warn "$(t SCRCPY_NO_PROMPT "$(basename "$SELF_PATH")")"
            return 1
        fi
    fi

    local result
    if [ ! -t 1 ] && have_gui; then
        run_with_zenity_progress "$(t SCRCPY_PROGRESS)" download_scrcpy_release
        result=$?
    else
        download_scrcpy_release
        result=$?
    fi

    # PATH is set here: the progress dialog runs download_scrcpy_release in a background subshell.
    if [ "$result" -eq 0 ]; then
        [[ ":$PATH:" != *":$BIN_DIR:"* ]] && export PATH="$BIN_DIR:$PATH"
        hash -r 2>/dev/null || true
    fi
    return "$result"
}

# ---- v4l2loopback
# awk, not grep -q: its early exit SIGPIPEs lsmod, and under pipefail that reads as "not loaded".
v4l2loopback_loaded() { lsmod | awk '$1 == "v4l2loopback" { f = 1 } END { exit !f }'; }
# Test hook: tests override it so a real /dev/video42 cannot leak in.
v4l2_node_exists() { [ -e "$1" ]; }

ensure_v4l2_device() {
    if ! v4l2_node_exists "$V4L2_DEVICE"; then
        err "$(t V4L2_MISSING "$V4L2_DEVICE")"
        echo "$(t V4L2_TEST)"
        echo "$(t V4L2_REINSTALL "$(basename "$SELF_PATH")")"
        echo "$(t V4L2_MOK)"
        return 1
    fi
    if [ ! -w "$V4L2_DEVICE" ]; then
        err "$(t V4L2_PERMISSION "$V4L2_DEVICE")"
        echo "$(t V4L2_GROUP "$(basename "$SELF_PATH")")"
        return 1
    fi
    return 0
}

# ---- Virtual audio
# Creates PhoneMicSink and PhoneMic only if missing, so repeated starts stack no modules.
ensure_audio_devices() {
    if ! pactl list short sinks 2>/dev/null | awk -v n="$MIC_SINK_NAME" '$2 == n { found=1 } END { exit !found }'; then
        info "$(t CREATE_SINK "$MIC_SINK_NAME")"
        if ! pactl load-module module-null-sink \
            sink_name="$MIC_SINK_NAME" \
            sink_properties=device.description="$MIC_SINK_NAME" >/dev/null; then
            err "$(t CREATE_SINK_FAIL "$MIC_SINK_NAME")"
            return 1
        fi
    fi
    if ! pactl list short sources 2>/dev/null | awk -v n="$MIC_SOURCE_NAME" '$2 == n { found=1 } END { exit !found }'; then
        info "$(t CREATE_MIC "$MIC_SOURCE_NAME")"
        if ! pactl load-module module-remap-source \
            master="${MIC_SINK_NAME}.monitor" \
            source_name="$MIC_SOURCE_NAME" \
            source_properties=device.description="$MIC_SOURCE_NAME" >/dev/null; then
            err "$(t CREATE_MIC_FAIL "$MIC_SOURCE_NAME")"
            return 1
        fi
    fi
    return 0
}

# Polls up to 15 s for scrcpy's playback stream (by application.process.binary) and moves it into PhoneMicSink, else warns.
route_audio_to_mic() {
    local timeout=15 waited=0 id=""
    while [ "$waited" -lt "$timeout" ]; do
        # LC_ALL=C: pactl translates its headers (Spanish prints "Entrada del destino #N").
        id=$(LC_ALL=C pactl list sink-inputs 2>/dev/null | awk '
            /^Sink Input #/ {
                if (id != "" && binary == "scrcpy") found_id = id
                id=$0; sub(/^Sink Input #/,"",id); binary=""
            }
            /application\.process\.binary/ { gsub(/"/,""); binary=$NF }
            END {
                if (binary == "scrcpy") found_id = id
                if (found_id != "") print found_id
            }
        ')
        if [ -n "$id" ]; then
            if pactl move-sink-input "$id" "$MIC_SINK_NAME" >/dev/null 2>&1; then
                ok "$(t AUDIO_ROUTED)"
                cleanup_route_pidfile
                return 0
            fi
        fi
        sleep 1
        waited=$((waited+1))
    done
    warn "$(t AUDIO_ROUTE_FAIL "$timeout")"
    warn "$(t AUDIO_ROUTE_MANUAL "$MIC_SINK_NAME")"
    notify "$(t AUDIO_ROUTE_FAIL "$timeout")" "$(t AUDIO_ROUTE_MANUAL "$MIC_SINK_NAME")"
    cleanup_route_pidfile
    return 1
}

# Removes PID_ROUTE only if it records this helper. $BASHPID, not $$: it runs in a background subshell, and start_mic stored that PID.
cleanup_route_pidfile() {
    local current_pid="$BASHPID" stored_pid current_start stored_start
    [ -f "$PID_ROUTE" ] || return 0
    read -r stored_pid stored_start _ < "$PID_ROUTE" || return 0
    [ "$stored_pid" = "$current_pid" ] || return 0
    current_start="$(proc_start_time "$current_pid")" || return 0
    [ -z "$stored_start" ] || [ "$stored_start" = "$current_start" ] || return 0
    rm -f "$PID_ROUTE"
}

# ---- Android device state and capture parameters
android_api() {
    local serial="$1" api
    api="$(adb_run 5 -s "$serial" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r' | head -1)"
    [[ "$api" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$((10#$api))"
}

require_android_api() {
    local serial="$1" min_api="$2" api
    api="$(android_api "$serial")" || {
        warn "$(t ANDROID_API_UNKNOWN)"
        return 1
    }
    if [ "$api" -lt "$min_api" ]; then
        case "$min_api" in
            31) err "$(t ANDROID_CAMERA_REQUIRED "$api")" ;;
            30) err "$(t ANDROID_AUDIO_REQUIRED "$api")" ;;
            *) return 1 ;;
        esac
        return 1
    fi
    return 0
}

# Over ADB: scrcpy refuses --turn-screen-off/--stay-awake with control off, and both modes pass --no-control.
# Status: 0 screen off (or already off), 1 command failed, 2 screen state not recognized.
phone_screen_off() {
    local serial="$1" api wakefulness
    api="$(android_api "$serial")" || return 1
    if [ "$api" -ge 35 ]; then
        adb_run 5 -s "$serial" shell cmd display power-off 0 >/dev/null 2>&1
        return $?
    fi
    wakefulness="$(adb_run 5 -s "$serial" shell dumpsys power 2>/dev/null | awk -F= '/mWakefulness=/{print $2; exit}' | tr -d '\r')"
    case "$wakefulness" in
        Awake|Dreaming)
            adb_run 5 -s "$serial" shell input keyevent KEYCODE_POWER >/dev/null 2>&1
            return $?
            ;;
        Asleep|Dozing|Off)
            return 0
            ;;
        *)
            return 2
            ;;
    esac
}

video_bitrate() { [ "$VIDEO_QUALITY_PROFILE" = "max" ] && echo "$VIDEO_BITRATE_MAX" || echo "$VIDEO_BITRATE_BALANCED"; }
video_codec()   { [ "$VIDEO_QUALITY_PROFILE" = "max" ] && echo "h265" || echo "h264"; }

build_camera_args() {
    CAMERA_ARGS=()
    if [ -n "$CAMERA_ID" ]; then
        CAMERA_ARGS+=("--camera-id=$CAMERA_ID")
    else
        CAMERA_ARGS+=("--camera-facing=$CAMERA_FACING")
    fi
}

# Keep-awake over ADB, like scrcpy's --stay-awake: stay_on_while_plugged_in=7 (AC, USB and wireless).
phone_stay_awake_get() {
    local serial="$1" val
    val="$(adb_run 5 -s "$serial" shell settings get global stay_on_while_plugged_in 2>/dev/null | tr -d '\r')"
    [[ "$val" =~ ^[0-9]+$ ]] && printf '%s\n' "$val" || printf '0\n'
}

# keepawake.saved holds one "serial original-value" line per phone changed.
phone_keep_awake_start() {
    local serial="$1" f="$RUN_DIR/keepawake.saved" s
    mkdir -p -- "$RUN_DIR" || return 1
    (
        exec 6>"$RUN_DIR/keepawake.lock"
        flock -x 6
        [ -f "$f" ] && while read -r s _; do [ "$s" = "$serial" ] && exit 0; done < "$f"
        { cat -- "$f" 2>/dev/null; printf '%s %s\n' "$serial" "$(phone_stay_awake_get "$serial")"; } | atomic_write_file "$f" 600
    ) || return 1
    adb_run 5 -s "$serial" shell settings put global stay_on_while_plugged_in 7 >/dev/null 2>&1
}

# Restores each phone's original value once no capture runs; an unreachable phone keeps its value pending.
phone_keep_awake_stop() {
    local f="$RUN_DIR/keepawake.saved"
    mkdir -p -- "$RUN_DIR" || return 1
    (
        exec 6>"$RUN_DIR/keepawake.lock"
        flock -x 6
        { is_running "$PID_WEBCAM" || is_running "$PID_MIC"; } && exit 0
        [ -f "$f" ] || exit 0
        local s v left=""
        while read -r s v; do
            [ -n "$s" ] || continue
            adb_run 5 -s "$s" shell settings put global stay_on_while_plugged_in "${v:-0}" >/dev/null 2>&1 || left+="$s ${v:-0}"$'\n'
        done < "$f"
        if [ -n "$left" ]; then printf '%s' "$left" | atomic_write_file "$f" 600; else rm -f "$f"; fi
    )
}

# ---- Process / PID-file helpers
proc_start_time() {
    local pid="$1" stat
    local -a f
    [ -r "/proc/$pid/stat" ] || return 1
    stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
    [[ "$stat" == *') '* ]] || return 1
    # Drop "pid (comm) " (comm may hold spaces and ')'); f[19] is then starttime, field 22 of /proc/PID/stat.
    read -r -a f <<< "${stat##*) }"
    [[ "${f[19]:-}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${f[19]}"
}

pidfile_pid() {
    local pidfile="$1" pid
    [ -r "$pidfile" ] || return 1
    read -r pid _ < "$pidfile" || return 1
    printf '%s\n' "$pid"
}

write_pidfile() {
    local pidfile="$1" pid="$2" start
    start="$(proc_start_time "$pid")" || return 1
    printf '%s %s\n' "$pid" "$start" | atomic_write_file "$pidfile" 600
}

prepare_log_file() {
    atomic_write_file "$1" 600 </dev/null
}

pidfile_matches_process() {
    local pidfile="$1" expected_comm="${2:-}" pid stored_start current_start comm
    [ -f "$pidfile" ] || return 1
    read -r pid stored_start _ < "$pidfile" || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    grep -q '^State:[[:space:]]*Z' "/proc/$pid/status" 2>/dev/null && return 1
    [[ "$stored_start" =~ ^[0-9]+$ ]] || return 1
    current_start="$(proc_start_time "$pid")" || return 1
    [ "$stored_start" = "$current_start" ] || return 1
    if [ -n "$expected_comm" ]; then
        comm="$(cat "/proc/$pid/comm" 2>/dev/null)"
        [ "$comm" = "$expected_comm" ] || return 1
    fi
}

# A PhoneCam process has comm "bash" (interpreter or env shebang) or the script name cut to 15 chars (direct "#!/bin/bash").
pidfile_matches_script() {
    local name
    for name in bash "$(basename -- "$SELF_PATH")" "$(basename -- "$INSTALLED_BIN")"; do
        pidfile_matches_process "$1" "${name:0:15}" && return 0
    done
    return 1
}

is_running() {
    pidfile_matches_process "$1" scrcpy
}

wait_for_process() {
    local pidfile="$1" expected_comm="$2" attempts="${3:-20}" i
    for ((i=0; i<attempts; i++)); do
        pidfile_matches_process "$pidfile" "$expected_comm" && return 0
        pidfile_matches_process "$pidfile" || return 1   # dead or gone: waiting is pointless
        sleep 0.1
    done
    return 1
}

terminate_pid() {
    local pid="$1" timeout="${2:-3}" waited=0
    kill -0 "$pid" 2>/dev/null || return 0
    kill "$pid" 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
        waited=$((waited + 1))
        [ "$waited" -ge $((timeout * 5)) ] && { kill -9 "$pid" 2>/dev/null; break; }
        sleep 0.2
    done
    wait "$pid" 2>/dev/null || true
    return 0
}

# Stops the process pidfile $1 records if "$2 <file>" confirms it is ours; succeeds only then. The pidfile is renamed
# first (atomic): a capture started meanwhile writes its own pidfile, which this stop never touches.
stop_pidfile_process() {
    local pidfile="$1" matcher="$2" claim="$1.$BASHPID" pid rc=1
    mv -fT -- "$pidfile" "$claim" 2>/dev/null || return 1
    if "$matcher" "$claim" && pid="$(pidfile_pid "$claim")"; then
        terminate_pid "$pid"
        rc=0
    fi
    rm -f -- "$claim"
    return "$rc"
}

# ---- Capture start helpers
# register_capture PIDFILE PID LOG: saves job PID in PIDFILE, waits until it is named "scrcpy" and has survived
# PHONECAM_START_GRACE s (default 2): scrcpy reports a busy v4l2 device or rejected settings only after connecting.
# Failure: LOG tail shown, PID stopped, PIDFILE removed.
register_capture() {
    local pidfile="$1" pid="$2" logfile="$3" grace="${PHONECAM_START_GRACE:-2}" i line
    [[ "$grace" =~ ^[0-9]{1,3}$ ]] && grace=$((10#$grace)) || grace=2
    if write_pidfile "$pidfile" "$pid"; then
        if wait_for_process "$pidfile" scrcpy 20; then
            for ((i = 0; i < grace * 5; i++)); do
                sleep 0.2
                pidfile_matches_process "$pidfile" scrcpy || break
            done
            ((i == grace * 5)) && return 0
        fi
        [ -f "$pidfile" ] || return 1   # a stop took it: stay silent
    elif proc_start_time "$pid" >/dev/null; then   # still there, so it is the pidfile that failed
        terminate_pid "$pid" 1
        rm -f "$pidfile"
        err "$(t PROCESS_STATE_SAVE_FAIL)"
        return 1
    fi   # otherwise scrcpy died before its state could be read: report it like any failed start
    err "$(t SCRCPY_START_FAIL "$logfile")"
    tail -n 2 -- "$logfile" 2>/dev/null | while IFS= read -r line; do warn "  $line"; done
    pidfile_matches_process "$pidfile" && terminate_pid "$pid" 1
    rm -f "$pidfile"
    return 1
}

# 9>&- stops the job inheriting the start lock (fd 9), which it would hold while running.
launch_capture() {
    local pidfile="$1" logfile="$2" serial="$3"
    shift 3
    nohup scrcpy -s "$serial" "$@" 9>&- < /dev/null >> "$logfile" 2>&1 &
    register_capture "$pidfile" "$!" "$logfile"
}

# Neither setting is fatal: always returns 0.
apply_phone_settings() {
    local serial="$1" rc=0
    if [ "$TURN_SCREEN_OFF" = "true" ]; then
        phone_screen_off "$serial" || rc=$?
        case "$rc" in
            0) ;;
            2) warn "$(t PHONE_SCREEN_OFF_UNSUPPORTED)" ;;
            *) warn "$(t PHONE_SCREEN_OFF_FAIL)" ;;
        esac
    fi
    [ "$KEEP_AWAKE" = "true" ] && phone_keep_awake_start "$serial"
    return 0
}

# ---- Webcam mode
start_webcam() {
    local serial="${1:-}"
    if is_running "$PID_WEBCAM"; then
        warn "$(t WEBCAM_ALREADY "$(pidfile_pid "$PID_WEBCAM")")"
        return 0
    fi

    (
        flock -n 9 || { warn "$(t WEBCAM_LOCK)"; exit 1; }
        is_running "$PID_WEBCAM" && exit 0

        require_tools || exit 1
        ensure_v4l2_device || exit 1
        [ -n "$serial" ] || serial=$(adb_serial) || exit 1
        require_android_api "$serial" 31 || exit 1

        build_camera_args
        local size_arg=()
        [ -n "$CAMERA_SIZE" ] && size_arg=(--camera-size="$CAMERA_SIZE")

        info "$(t WEBCAM_START "$(video_codec)" "$(video_bitrate)" "$CAMERA_FPS")"
        if ! prepare_log_file "$LOG_DIR/webcam.log"; then
            err "$(t PROCESS_STATE_SAVE_FAIL)"
            exit 1
        fi
        launch_capture "$PID_WEBCAM" "$LOG_DIR/webcam.log" "$serial" \
            --video-source=camera \
            "${CAMERA_ARGS[@]}" \
            "${size_arg[@]}" \
            --camera-fps="$CAMERA_FPS" \
            --video-codec="$(video_codec)" \
            --video-bit-rate="$(video_bitrate)" \
            --v4l2-sink="$V4L2_DEVICE" \
            --no-playback \
            --no-audio \
            --no-control || exit 1
        apply_phone_settings "$serial"
        ok "$(t WEBCAM_ACTIVE "$V4L2_DEVICE" "$(pidfile_pid "$PID_WEBCAM")")"
        notify "$(t WEBCAM_ACTIVE_TITLE)" "$(t WEBCAM_SELECT)"
    ) 9>"$RUN_DIR/webcam.lock"
}

# ---- Microphone mode
start_mic() {
    local serial="${1:-}"
    if is_running "$PID_MIC"; then
        warn "$(t MIC_ALREADY "$(pidfile_pid "$PID_MIC")")"
        return 0
    fi

    (
        flock -n 9 || { warn "$(t MIC_LOCK)"; exit 1; }
        is_running "$PID_MIC" && exit 0

        require_tools || exit 1
        if ! audio_source_supported "$AUDIO_SOURCE"; then
            err "$(t AUDIO_SOURCE_UNSUPPORTED "$AUDIO_SOURCE" "$(basename "$SELF_PATH")")"
            err "$(t SCRCPY_UPDATE)"
            exit 1
        fi
        [ -n "$serial" ] || serial=$(adb_serial) || exit 1
        require_android_api "$serial" 30 || exit 1
        ensure_audio_devices || exit 1

        info "$(t MIC_START "$AUDIO_CODEC" "$AUDIO_BITRATE")"
        if ! prepare_log_file "$LOG_DIR/mic.log"; then
            err "$(t PROCESS_STATE_SAVE_FAIL)"
            exit 1
        fi
        # scrcpy >= 2.5 opens an icon-only window for --no-video unless --no-window (new in 2.5) is given; older versions open none.
        local window_arg=()
        scrcpy_at_least 2 5 && window_arg=(--no-window)
        launch_capture "$PID_MIC" "$LOG_DIR/mic.log" "$serial" \
            "${window_arg[@]}" \
            --no-video \
            --no-control \
            --require-audio \
            --audio-source="$AUDIO_SOURCE" \
            --audio-codec="$AUDIO_CODEC" \
            --audio-bit-rate="$AUDIO_BITRATE" || exit 1
        local capture_pid; capture_pid="$(pidfile_pid "$PID_MIC")"

        ( route_audio_to_mic ) 9>&- < /dev/null >> "$LOG_DIR/mic.log" 2>&1 &
        local route_pid=$!
        if ! write_pidfile "$PID_ROUTE" "$route_pid" && proc_start_time "$route_pid" >/dev/null; then   # a helper already gone has nothing to record
            terminate_pid "$route_pid" 1
            terminate_pid "$capture_pid" 1
            rm -f "$PID_ROUTE" "$PID_MIC"
            err "$(t PROCESS_STATE_SAVE_FAIL)"
            exit 1
        fi

        apply_phone_settings "$serial"
        ok "$(t MIC_ACTIVE "$capture_pid" "$MIC_SOURCE_NAME")"
        notify "$(t MIC_ACTIVE_TITLE)" "$(t MIC_SELECT "$MIC_SOURCE_NAME")"
    ) 9>"$RUN_DIR/mic.lock"
}

# ---- Combined webcam + microphone mode
# The phone is chosen once: each start would otherwise ask again and could pick another phone.
start_both() {
    local rc=0 serial="${1:-}"
    if ! { is_running "$PID_WEBCAM" && is_running "$PID_MIC"; }; then
        require_tools && { [ -n "$serial" ] || serial=$(adb_serial); } || return 1
    fi
    start_webcam "$serial" || rc=1
    start_mic "$serial" || rc=1
    return "$rc"
}

# ---- Stop
stop_all() {
    local stopped=0
    stop_pidfile_process "$PID_ROUTE" pidfile_matches_script && stopped=1
    stop_pidfile_process "$PID_WEBCAM" is_running && stopped=1
    stop_pidfile_process "$PID_MIC" is_running && stopped=1
    phone_keep_awake_stop

    if [ "$stopped" -eq 1 ]; then
        ok "$(t PHONECAM_STOPPED)"
        notify "$(t PHONECAM_STOPPED)"
    else
        info "$(t NO_PROCESS)"
    fi
}

stop_webcam_only() {
    local was_running=0
    stop_pidfile_process "$PID_WEBCAM" is_running && was_running=1
    phone_keep_awake_stop
    if [ "$was_running" -eq 1 ]; then
        ok "$(t WEBCAM_STOPPED)"
        notify "$(t WEBCAM_STOPPED)"
    else
        info "$(t WEBCAM_NOT_ACTIVE)"
    fi
}

stop_mic_only() {
    local stopped=0
    mkdir -p -- "$RUN_DIR" || return 1
    stop_pidfile_process "$PID_ROUTE" pidfile_matches_script || :
    stop_pidfile_process "$PID_MIC" is_running && stopped=1
    phone_keep_awake_stop
    if [ "$stopped" -eq 1 ]; then
        ok "$(t MIC_STOPPED)"
        notify "$(t MIC_STOPPED)"
    else
        info "$(t MIC_NOT_ACTIVE)"
    fi
}

# ---- Status
status() {
    hdr "$(t STATUS_TITLE)"
    echo

    hdr "$(t STATUS_CONNECTION)"
    if ! command -v adb >/dev/null 2>&1; then
        err "$(t ADB_NOT_INSTALLED)"
        echo "$(t STATUS_INSTALL_ADB "$(basename "$SELF_PATH")")"
    else
        local adb_out
        adb_out=$(adb_run 10 devices 2>/dev/null)
        if printf '%s\n' "$adb_out" | awk 'NR>1 && $2=="device"' | grep -q .; then
            ok "$(t PHONE_CONNECTED)"
            printf '%s\n' "$adb_out" | awk 'NR>1 && $2=="device" {print "     - "$1}'
        else
            warn "$(t PHONE_NOT_AUTH)"
            echo "$(t STATUS_CONNECT_USB)"
        fi
    fi
    echo

    hdr "$(t STATUS_CAPTURE)"
    if is_running "$PID_WEBCAM"; then
        ok "$(t WEBCAM_ACTIVE_STATUS "$(pidfile_pid "$PID_WEBCAM")" "$V4L2_DEVICE")"
    else
        info "$(t WEBCAM_INACTIVE)"
    fi
    if is_running "$PID_MIC"; then
        ok "$(t MIC_ACTIVE_STATUS "$(pidfile_pid "$PID_MIC")" "$MIC_SOURCE_NAME")"
    else
        info "$(t MIC_INACTIVE)"
    fi
    echo

    hdr "$(t STATUS_VIRTUAL)"
    if v4l2_node_exists "$V4L2_DEVICE"; then
        ok "$(t V4L2_PRESENT "$V4L2_DEVICE")"
    else
        warn "$(t V4L2_ABSENT "$V4L2_DEVICE")"
        echo "$(t V4L2_RETRY)"
    fi
    if ! command -v pactl >/dev/null 2>&1; then
        err "$(t PACTL_NOT_INSTALLED)"
        echo "$(t STATUS_INSTALL_PACTL "$(basename "$SELF_PATH")")"
    elif pactl list short sources 2>/dev/null | awk -v n="$MIC_SOURCE_NAME" '$2 == n { found=1 } END { exit !found }'; then
        ok "$(t MIC_PRESENT "$MIC_SOURCE_NAME")"
    else
        info "$(t MIC_LAZY "$MIC_SOURCE_NAME")"
    fi
}

# ---- List / choose phone camera
# Time-limited like every adb call: the menu waits on it.
phone_camera_list() {
    timeout 30 scrcpy -s "$1" --list-cameras 2>&1 | grep -- '--camera-id'
}

list_cameras() {
    require_tools || return 1
    local serial; serial=$(adb_serial) || return 1
    local raw; raw=$(phone_camera_list "$serial")
    if [ -z "$raw" ]; then
        err "$(t CAMERA_LIST_FAIL)"
        return 1
    fi
    printf '%s\n' "$raw"
}

choose_camera_gui() {
    require_tools || return 1
    local serial; serial=$(adb_serial) || return 1
    info "$(t CAMERA_QUERY)"
    local raw; raw=$(phone_camera_list "$serial")
    if [ -z "$raw" ]; then
        err "$(t CAMERA_LIST_SHORT_FAIL)"
        return 1
    fi

    if have_gui; then
        local rows=("(auto)" "$(t CAMERA_AUTO_ZENITY)") line id desc
        while IFS= read -r line; do
            id=$(echo "$line" | grep -oE 'camera-id=[0-9]+' | cut -d= -f2)
            desc=$(echo "$line" | sed -E 's/--camera-id=[0-9]+ *//')
            rows+=("$id" "$desc")
        done <<< "$raw"
        local chosen
        chosen=$(zenity --list --title="$(t CHOOSE_CAMERA)" --window-icon="$(window_icon)" \
            --width=560 --height=320 \
            --text="$(t CAMERA_LIST_TEXT)" \
            --column="$(t CAMERA_COL_ID)" --column="$(t CAMERA_COL_DETAIL)" "${rows[@]}" 2>/dev/null)
        if [ "$chosen" = "(auto)" ]; then
            set_config CAMERA_ID "" && {
                ok "$(t CAMERA_AUTO_SAVED)"
                notify "$(t CHOOSE_CAMERA)" "$(t CAMERA_AUTO_NOTIFY)"
            }
        elif [ -n "$chosen" ]; then
            set_config CAMERA_ID "$chosen" && {
                ok "$(t CAMERA_SAVED "$chosen")"
                notify "$(t CHOOSE_CAMERA)" "$(t CAMERA_SAVED_NOTIFY)"
            }
        fi
    else
        local chosen
        echo "$raw"
        read -rp "$(t CAMERA_ID_PROMPT)" chosen
        if [ -z "$chosen" ]; then
            :
        elif [ "$chosen" = "auto" ]; then
            set_config CAMERA_ID "" && ok "$(t CAMERA_AUTO_SAVED)"
        elif [[ ! "$chosen" =~ ^[0-9]+$ ]]; then
            err "$(t CAMERA_ID_INVALID)"
        else
            set_config CAMERA_ID "$chosen" && ok "$(t CAMERA_SAVED "$chosen")"
        fi
    fi
}

# ---- Configuration editor
set_config() {
    local key="$1" value="$2"
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    mkdir -p "$CONF_DIR" || return 1
    if ! (
        exec 9>>"$CONF_FILE.lock" && flock -x 9 || exit 1
        if [ ! -f "$CONF_FILE" ]; then   # first write: commented template, in the language being set
            [ "$key" = PHONECAM_LANG ] && { PHONECAM_LANG_ENV=""; PHONECAM_LANG="$value"; set_language_context; }
            write_default_config "$V4L2_NR_DEFAULT" || exit 1
        fi
        comment=""
        escaped="${value//\'/\'\\\'\'}"
        mode="$(existing_file_mode "$CONF_FILE" 600)"
        old_line=$(grep -m1 "^${key}=" "$CONF_FILE" || :)
        comment_re=$'["\047]([[:space:]]+#.*)$'
        [[ "$old_line" =~ $comment_re ]] && comment="${BASH_REMATCH[1]}"
        new_line="${key}='${escaped}'${comment}"
        content="$(PHONECAM_SET_LINE="$new_line" awk -v k="$key" \
            'index($0, k "=") == 1 { print ENVIRON["PHONECAM_SET_LINE"]; done=1; next } { print } END { if (!done) print ENVIRON["PHONECAM_SET_LINE"] }' \
            "$CONF_FILE")" || exit 1
        printf '%s\n' "$content" | atomic_write_file "$CONF_FILE" "$mode"
    ); then
        err "$(t CONFIG_SAVE_FAIL "$key" "$CONF_FILE")"
        return 1
    fi
    printf -v "$key" '%s' "$value"
}

edit_config() {
    if [ -t 0 ] && [ -n "${VISUAL:-}${EDITOR:-}" ]; then
        local editor_cmd="${VISUAL:-$EDITOR}"
        local -a editor_arr
        read -ra editor_arr <<< "$editor_cmd"
        if [ "${#editor_arr[@]}" -gt 0 ] && command -v "${editor_arr[0]}" >/dev/null 2>&1; then
            "${editor_arr[@]}" "$CONF_FILE"
            return
        fi
    fi

    local gui_editor
    for gui_editor in xed gnome-text-editor gedit kate; do
        if command -v "$gui_editor" >/dev/null 2>&1; then
            "$gui_editor" "$CONF_FILE" >/dev/null 2>&1 &
            return
        fi
    done
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$CONF_FILE" >/dev/null 2>&1 &
    elif [ -t 0 ] && command -v "${EDITOR:-nano}" >/dev/null 2>&1; then
        "${EDITOR:-nano}" "$CONF_FILE"
    else
        echo "$(t EDITOR_MISSING "$CONF_FILE")"
        notify "PhoneCam" "$(t EDITOR_MISSING "$CONF_FILE")"
    fi
}

combo_with_current() {
    local current="$1"; shift
    local out="$current" opt
    for opt in "$@"; do
        [ "$opt" = "$current" ] && continue
        out="$out|$opt"
    done
    printf '%s' "$out"
}

# ---- Advanced settings: graphical form
advanced_settings_gui() {
    if ! have_gui; then
        edit_config
        return
    fi

    local result rc facing_label size_label fps_label profile_label source_label codec_label bitrate_label auto_label screen_label awake_label
    local -a audio_sources=(mic)
    scrcpy_at_least 3 2 && audio_sources+=(mic-unprocessed mic-voice-communication mic-voice-recognition mic-camcorder)
    facing_label="$(t ADV_FACING)"
    [ -n "$CAMERA_ID" ] && facing_label+="$(t ADV_FACING_LOCKED "$CAMERA_ID")"
    size_label="$(t ADV_SIZE "${CAMERA_SIZE:-$(t ADV_MAX)}")"
    fps_label="$(t ADV_FPS "$CAMERA_FPS")"
    profile_label="$(t ADV_PROFILE)"
    source_label="$(t ADV_SOURCE)"
    codec_label="$(t ADV_CODEC)"
    bitrate_label="$(t ADV_BITRATE "$AUDIO_BITRATE")"
    auto_label="$(t ADV_AUTO)"
    screen_label="$(t ADV_SCREEN)"
    awake_label="$(t ADV_AWAKE)"

    result=$(zenity --forms --title="$(t ADV_TITLE)" \
        --window-icon="$(window_icon)" --width=560 \
        --text="$(t ADV_TEXT "$CONF_FILE")" \
        --separator="|" \
        --add-combo="$facing_label" \
        --combo-values="$(combo_with_current "$CAMERA_FACING" back front external)" \
        --add-entry="$size_label" \
        --add-entry="$fps_label" \
        --add-combo="$profile_label" \
        --combo-values="$(combo_with_current "$VIDEO_QUALITY_PROFILE" balanced max)" \
        --add-combo="$source_label" \
        --combo-values="$(combo_with_current "$AUDIO_SOURCE" "${audio_sources[@]}")" \
        --add-combo="$codec_label" \
        --combo-values="$(combo_with_current "$AUDIO_CODEC" opus aac flac raw)" \
        --add-entry="$bitrate_label" \
        --add-combo="$auto_label" \
        --combo-values="$(combo_with_current "$AUTO_MODE" ask webcam mic both off)" \
        --add-combo="$screen_label" \
        --combo-values="$(combo_with_current "$TURN_SCREEN_OFF" false true)" \
        --add-combo="$awake_label" \
        --combo-values="$(combo_with_current "$KEEP_AWAKE" true false)" \
        2>/dev/null)
    rc=$?

    if [ "$rc" -ne 0 ] || [ -z "$result" ]; then
        return 0
    fi

    local -a f
    IFS='|' read -r -a f <<< "${result}|__END__"
    if [ "${#f[@]}" -ne 11 ] || [ "${f[10]}" != "__END__" ]; then
        err "$(t CONFIG_PIPE_ERR)"
        gui_error 460 "$(t CONFIG_PIPE_ERR_GUI)\\n\\n$(t CONFIG_PIPE_FIX)"
        return 1
    fi
    local f_facing="${f[0]}" f_size="${f[1]}" f_fps="${f[2]}" f_profile="${f[3]}" f_asource="${f[4]}" f_codec="${f[5]}" f_abitrate="${f[6]}" f_auto="${f[7]}" f_screenoff="${f[8]}" f_awake="${f[9]}"

    local -a field_errors=()
    mapfile -t field_errors < <(validate_advanced_fields "$f_size" "$f_fps" "$f_abitrate")
    if [ "${#field_errors[@]}" -gt 0 ]; then
        local msg; msg=$(printf '%s\n' "${field_errors[@]}")
        err "$(t CONFIG_FORMAT_ERR)"
        gui_error 460 "$(t CONFIG_FORMAT_FIX "$(markup_escape "$msg")")"
        return 1
    fi

    local save_ok=1
    [ -n "$f_facing" ]    && { set_config CAMERA_FACING "$f_facing" || save_ok=0; }
    if [ -n "$f_size" ]; then
        [ "$f_size" = "max" ] && f_size=""
        set_config CAMERA_SIZE "$f_size" || save_ok=0
    fi
    [ -n "$f_fps" ]       && { set_config CAMERA_FPS "$f_fps" || save_ok=0; }
    [ -n "$f_profile" ]   && { set_config VIDEO_QUALITY_PROFILE "$f_profile" || save_ok=0; }
    [ -n "$f_asource" ]   && { set_config AUDIO_SOURCE "$f_asource" || save_ok=0; }
    [ -n "$f_codec" ]     && { set_config AUDIO_CODEC "$f_codec" || save_ok=0; }
    [ -n "$f_abitrate" ]  && { set_config AUDIO_BITRATE "$f_abitrate" || save_ok=0; }
    [ -n "$f_auto" ]      && { set_config AUTO_MODE "$f_auto" || save_ok=0; }
    [ -n "$f_screenoff" ] && { set_config TURN_SCREEN_OFF "$f_screenoff" || save_ok=0; }
    [ -n "$f_awake" ]     && { set_config KEEP_AWAKE "$f_awake" || save_ok=0; }

    if [ "$save_ok" -eq 1 ]; then
        ok "$(t CONFIG_SAVED "$CONF_FILE")"
        notify "PhoneCam" "$(t CONFIG_UPDATED)"
    else
        warn "$(t CONFIG_PARTIAL)"
    fi
}

validate_advanced_fields() {
    local size="$1" fps="$2" abitrate="$3" errors=()
    [ -n "$size" ] && [ "$size" != "max" ] && [[ ! "$size" =~ ^[0-9]+x[0-9]+$ ]] && errors+=("$(t VALIDATE_SIZE)")
    [ -n "$fps" ] && [[ ! "$fps" =~ ^[0-9]+$ ]] && errors+=("$(t VALIDATE_FPS)")
    [ -n "$abitrate" ] && [[ ! "$abitrate" =~ ^[0-9]+[KkMm]$ ]] && errors+=("$(t VALIDATE_BITRATE)")
    [ "${#errors[@]}" -gt 0 ] && printf '%s\n' "${errors[@]}"
    return 0
}

open_config_editor() {
    if have_gui; then
        advanced_settings_gui
    else
        edit_config
    fi
}

# ---- Connection help
show_connection_help() {
    if have_gui; then
        zenity --info --title="$(t HELP_TITLE)" --window-icon="$(window_icon)" \
            --width=480 --text="$(t CONNECTION_HELP)" 2>/dev/null
    else
        echo
        echo "$(t CONNECTION_HELP)"
        echo
    fi
}

# ---- Graphical (Zenity) / terminal menu
phone_status_short() {
    if adb_run 5 devices 2>/dev/null | awk 'NR>1 && $2=="device"' | grep -q .; then
        echo "connected"
    else
        echo "not_detected"
    fi
}

# Runs a command with stdin /dev/null (ask_yn takes its default); output reaches an error dialog only on failure.
run_gui_action() {
    local out rc
    out=$("$@" 2>&1 </dev/null)
    rc=$?
    if [ "$rc" -ne 0 ] && [ -n "$out" ]; then
        gui_error 480 "$(markup_escape "$out")"
    fi
    return "$rc"
}

gui_menu() {
    if ! have_gui; then
        cli_menu
        return
    fi

    if ! command -v adb >/dev/null 2>&1; then
        gui_error 440 "$(t GUI_ADB_MISSING "$(basename "$SELF_PATH")")"
        return 1
    fi

    if ! ensure_scrcpy_installed; then
        gui_error 460 "$(t GUI_SCRCPY_PREP_FAIL)"
        return 1
    fi

    while true; do
        local phone webcam_on=0 mic_on=0 phone_icon="✗"
        phone=$(phone_status_short)
        is_running "$PID_WEBCAM" && webcam_on=1
        is_running "$PID_MIC" && mic_on=1
        local phone_txt
        phone_txt="$(t STATUS_NOT_DETECTED)"
        [ "$phone" = "connected" ] && { phone_icon="✓"; phone_txt="$(t STATUS_CONNECTED)"; }

        local header
        header="$(t PHONE_HEADER)"$'\n'
        header+="📱 $(t PHONE_LABEL) ${phone_icon} ${phone_txt}    🎥 $(t WEBCAM_LABEL) $([ "$webcam_on" -eq 1 ] && echo "$(t ACTIVE_F)" || echo "$(t INACTIVE_F)")    🎙️ $(t MIC_LABEL) $([ "$mic_on" -eq 1 ] && echo "$(t ACTIVE_M)" || echo "$(t INACTIVE)")"

        local rows=()
        if [ "$webcam_on" -eq 1 ]; then
            rows+=("webcam_stop" "$(t MENU_WEBCAM_STOP)" "$(t MENU_STOP_WEBCAM_DESC)")
        else
            rows+=("webcam_start" "$(t MENU_WEBCAM_START)" "$(t MENU_NEED_USB)")
        fi
        if [ "$mic_on" -eq 1 ]; then
            rows+=("mic_stop" "$(t MENU_MIC_STOP)" "$(t MENU_STOP_MIC_DESC)")
        else
            rows+=("mic_start" "$(t MENU_MIC_START)" "$(t MENU_NEED_USB)")
        fi
        if [ "$webcam_on" -eq 0 ] || [ "$mic_on" -eq 0 ]; then
            rows+=("both_start" "$(t MENU_BOTH)" "$(t MENU_BOTH_DESC)")
        fi
        if [ "$webcam_on" -eq 1 ] || [ "$mic_on" -eq 1 ]; then
            rows+=("stop_all" "$(t MENU_STOP_ALL)" "$(t MENU_STOP_ALL_DESC)")
        fi
        rows+=("choose_cam" "🎯  $(t MENU_CHOOSE_CAM)" "$(t MENU_CHOOSE_DESC)")
        rows+=("status" "📊  $(t MENU_STATUS)" "$(t MENU_STATUS_DESC)")
        rows+=("config" "⚙️  $(t MENU_CONFIG)" "$(t MENU_CONFIG_DESC)")
        rows+=("help" "❓  $(t MENU_HELP)" "$(t MENU_HELP_DESC)")
        rows+=("language" "🌐  $(t MENU_LANGUAGE)" "$(t LANGUAGE_CURRENT_GUI "$(language_name)")")
        rows+=("exit" "🚪  $(t MENU_EXIT)" "$(t MENU_EXIT_DESC)")

        local choice
        choice=$(zenity --list --title="PhoneCam" --window-icon="$(window_icon)" \
            --width=720 --height=500 \
            --text="$header" \
            --column="key" --column="$(t COLUMN_ACTION)" --column="$(t COLUMN_DESCRIPTION)" \
            --hide-column=1 --print-column=1 \
            "${rows[@]}" 2>/dev/null)

        [ -f "$CONF_FILE" ] && load_config   # run_gui_action works in a subshell: re-read what it saved
        case "$choice" in
            webcam_start) run_gui_action start_webcam ;;
            webcam_stop)  run_gui_action stop_webcam_only ;;
            mic_start)    run_gui_action start_mic ;;
            mic_stop)     run_gui_action stop_mic_only ;;
            both_start)   run_gui_action start_both ;;
            stop_all)     run_gui_action stop_all ;;
            choose_cam)   run_gui_action choose_camera_gui ;;
            status)       status | zenity --text-info --title="$(t STATUS_DIALOG)" --window-icon="$(window_icon)" --width=560 --height=440 2>/dev/null ;;
            config)       run_gui_action advanced_settings_gui ;;
            help)         show_connection_help ;;
            language)     toggle_language ;;
            exit|"")      break ;;
            *) : ;;
        esac
    done
}

cli_menu() {
    if [ ! -t 0 ]; then
        status
        echo
        warn "$(t MENU_NO_TTY)"
        warn "$(t MENU_TTY_HINT "$(basename "$SELF_PATH")")"
        return 1
    fi

    while true; do
        local webcam_on=0 mic_on=0
        is_running "$PID_WEBCAM" && webcam_on=1
        is_running "$PID_MIC" && mic_on=1

        echo
        status
        echo

        local opt_webcam opt_mic
        opt_webcam="$(t MENU_WEBCAM_START)  ($(t MENU_NEED_USB))"
        [ "$webcam_on" -eq 1 ] && opt_webcam="$(t MENU_WEBCAM_STOP)  ($(t MENU_STOP_WEBCAM_DESC))"
        opt_mic="$(t MENU_MIC_START)  ($(t MENU_NEED_USB))"
        [ "$mic_on" -eq 1 ] && opt_mic="$(t MENU_MIC_STOP)  ($(t MENU_STOP_MIC_DESC))"

        echo "$(t MENU_TITLE)"
        echo "$(t LANGUAGE_CURRENT "$(language_name)")"
        echo "  L) $(t MENU_LANGUAGE)"
        echo

        local opt
        select opt in \
            "$opt_webcam" \
            "$opt_mic" \
            "$(t MENU_BOTH)" \
            "$(t MENU_CHOOSE_CAM)  ($(t MENU_CHOOSE_DESC))" \
            "$(t MENU_STATUS)" \
            "$(t MENU_STOP_ALL)" \
            "$(t MENU_HELP)  ($(t MENU_HELP_DESC))" \
            "$(t MENU_EXIT)"; do
            case "$REPLY" in
                1) if [ "$webcam_on" -eq 1 ]; then stop_webcam_only; else start_webcam; fi; break ;;
                2) if [ "$mic_on" -eq 1 ]; then stop_mic_only; else start_mic; fi; break ;;
                3) start_both; break ;;
                4) choose_camera_gui; break ;;
                5) break ;;
                6) stop_all; break ;;
                7) show_connection_help; break ;;
                8) return 0 ;;
                [lL]) toggle_language; break ;;
                *) echo "$(t INVALID_OPTION)"; break ;;
            esac
        done || { echo; return 0; }
    done
}

# ---- Background agent (systemd --user)
# Like run_gui_action, but failures become a notification.
run_agent_action() {
    local out rc
    out=$("$@" 2>&1 </dev/null)
    rc=$?
    if [ "$rc" -ne 0 ] && [ -n "$out" ]; then
        notify "PhoneCam" "$out"
    fi
    return "$rc"
}

# Phone to follow: $1 while it stays connected (a second phone sorting first is no unplug), else the first one.
agent_current_device() {
    adb_run 10 devices 2>/dev/null | awk -v keep="${1:-}" 'NR>1 && $2=="device" { if ($1 == keep) hit = 1; if (first == "") first = $1 } END { print hit ? keep : first }'
}

agent_handle_new_device() {
    local serial="$1"
    case "$AUTO_MODE" in
        webcam) notify "PhoneCam" "$(t AGENT_WEBCAM)"; run_agent_action start_webcam "$serial" ;;
        mic)    notify "PhoneCam" "$(t AGENT_MIC)"; run_agent_action start_mic "$serial" ;;
        both)   notify "PhoneCam" "$(t AGENT_BOTH)"; run_agent_action start_both "$serial" ;;
        off)    : ;;
        ask|*)
            if have_gui; then
                (
                  flock -n 9 || exit 0
                  local choice
                  choice=$(zenity --list --title="$(t PHONE_CONNECTED_NOTIFY)" --window-icon="$(window_icon)" \
                      --width=420 --height=280 \
                      --text="$(t PHONE_DETECTED "$serial")" \
                      --column="key" --column="$(t COLUMN_MODE)" --hide-column=1 --print-column=1 \
                      webcam "$(t TRAY_WEBCAM)" \
                      mic "$(t TRAY_MIC)" \
                      both "$(t TRAY_BOTH)" \
                      off "$(t TRAY_NO_ACTION)" \
                      2>/dev/null)
                  case "$choice" in
                      webcam) run_agent_action start_webcam "$serial" ;;
                      mic)    run_agent_action start_mic "$serial" ;;
                      both)   run_agent_action start_both "$serial" ;;
                      off|*) : ;;
                  esac
                ) 9>"$RUN_DIR/ask.lock" &
            else
                notify "$(t PHONE_CONNECTED_NOTIFY)" "$(t AGENT_NO_ZENITY)"
            fi
            ;;
    esac
}

agent_handle_removed_device() {
    if is_running "$PID_WEBCAM" || is_running "$PID_MIC"; then
        notify "PhoneCam" "$(t PHONE_DISCONNECTED)"
    fi
    stop_all >/dev/null 2>&1
}

agent_watcher_loop() {
    local last="" dev miss=0
    while true; do
        dev=$(agent_current_device "$last")
        # one empty answer (adb restarting, timeout) is not an unplug: stop_all would cut a healthy capture
        if [ -z "$dev" ] && [ -n "$last" ] && [ "$miss" -eq 0 ]; then miss=1; sleep 2 & wait $!; continue; fi
        miss=0
        if [ "$dev" != "$last" ]; then
            [ -n "$last" ] && agent_handle_removed_device
            if [ -n "$dev" ]; then
                load_config
                agent_handle_new_device "$dev"
            fi
        fi
        # restores keep-awake left by an unplug mid-capture
        [ -n "$dev" ] && [ -f "$RUN_DIR/keepawake.saved" ] && phone_keep_awake_stop
        last="$dev"
        sleep 2 & wait $!
    done
}

agent_tray_icon() {
    command -v yad >/dev/null 2>&1 || return 0
    local self="$INSTALLED_BIN"
    [ -x "$self" ] || self="$SELF_PATH"
    local self_q menu
    self_q=$(printf '%q' "$self")
    # yad (g_spawn_command_line_async) splits words like a shell but never invokes one, so "|" and "||" arrive as
    # literal arguments: anything needing a pipe or fallback goes through a hidden subcommand (tray-status, tray-exit).
    menu="$(t TRAY_OPEN)!$self_q menu"
    menu+=";;$(t TRAY_WEBCAM)!$self_q webcam"
    menu+=";;$(t TRAY_MIC)!$self_q mic"
    menu+=";;$(t TRAY_BOTH)!$self_q both"
    menu+=";;$(t TRAY_STATUS)!$self_q tray-status"
    menu+=";;$(t TRAY_STOP)!$self_q stop"
    menu+=";;$(t TRAY_CONFIG)!$self_q config"
    menu+=";;$(t TRAY_EXIT)!$self_q tray-exit"

    yad --notification \
        --image="$(window_icon)" \
        --text="PhoneCam" \
        --separator=";;" \
        --menu="$menu" \
        --no-middle &
    TRAY_PID=$!
}

# systemd kills yad together with the unit, but an agent started by hand must stop its tray icon itself.
agent_tray_stop() {
    if [ -n "$TRAY_PID" ] && [ -d "/proc/$TRAY_PID" ]; then kill "$TRAY_PID" 2>/dev/null || true; fi
    TRAY_PID=""
}

# `systemctl stop` returns 0 for a loaded-but-inactive unit, so an agent started
# outside systemd must be stopped through its pidfile regardless of that result.
agent_stop() {
    local rc=0 pid
    systemctl --user stop phonecam-agent.service 2>/dev/null || rc=$?
    if pidfile_matches_script "$PID_AGENT"; then
        pid="$(pidfile_pid "$PID_AGENT")" && kill "$pid" 2>/dev/null && rc=0
        for _ in $(seq 120); do pidfile_matches_process "$PID_AGENT" || break; sleep 0.1; done   # slot taken until it exits (a running adb defers TERM, <= 10 s)
    fi
    return "$rc"
}

# trap '' ignores HUP, INT and TERM, and the commands run below inherit that: systemd also signals
# processes forked during shutdown, and those signals must not kill the cleanup.
agent_cleanup() {
    trap '' HUP INT TERM
    trap - EXIT
    agent_tray_stop
    if [ "$(pidfile_pid "$PID_AGENT" 2>/dev/null)" = "$BASHPID" ]; then rm -f "$PID_AGENT"; fi
}

# Claim the single-agent slot under a short-lived lock (fd 5 lives only in this
# subshell, so no child inherits it). Exit 2 = another live agent owns it.
agent_claim() {
    local me="$BASHPID"
    mkdir -p -- "$RUN_DIR" || return 1
    (
        exec 5>>"$RUN_DIR/agent.lock" && flock -x 5 || exit 1
        if pidfile_matches_process "$PID_AGENT" && [ "$(pidfile_pid "$PID_AGENT")" != "$me" ]; then exit 2; fi
        write_pidfile "$PID_AGENT" "$me" || exit 1
    )
}

# WantedBy=default.target can start the agent before the desktop exports DISPLAY/WAYLAND_DISPLAY to the user manager, and a
# running process never sees variables added later. Polls the manager for them up to PHONECAM_DISPLAY_WAIT s (default 120;
# 0 = never look). Nothing to wait for if no user manager answers.
agent_wait_display() {
    local limit="${PHONECAM_DISPLAY_WAIT:-120}" waited=0 env_out line
    [[ "$limit" =~ ^[0-9]{1,4}$ ]] || limit=120
    [ "$limit" -gt 0 ] && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || return 0
    while :; do
        env_out="$(timeout 5 systemctl --user show-environment 2>/dev/null)" || return 1
        while IFS= read -r line; do
            [[ "$line" =~ ^(DISPLAY|WAYLAND_DISPLAY|XAUTHORITY)=[A-Za-z0-9_./:@+-]+$ ]] && export "$line"
        done <<< "$env_out"
        if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
            info "$(t AGENT_DISPLAY_FOUND "$waited")"
            return 0
        fi
        [ "$waited" -lt "$limit" ] || break
        sleep 1 & wait $!
        waited=$((waited + 1))
    done
    warn "$(t AGENT_DISPLAY_MISSING "$limit")"
    return 1
}

run_agent() {
    local rc=0
    agent_claim || rc=$?
    case "$rc" in
        0) ;;
        2) info "$(t AGENT_ALREADY)"; return 0 ;;   # 0 so systemd does not restart-loop
        *) return 1 ;;
    esac
    trap 'exit 0' HUP INT TERM
    trap agent_cleanup EXIT
    agent_wait_display
    agent_tray_icon
    agent_watcher_loop
}

# ---- Installation
# The icon rides in this file as "#@" comment lines (PNG in base64, never executed); printed only if it ends in IEND.
icon_payload() {
    local data
    data="$(sed -n 's/^#@//p' -- "$SELF_PATH" 2>/dev/null)"
    [ "$(base64 -d <<<"$data" 2>/dev/null | tail -c 8 | od -An -tx1 | tr -d ' \n')" = 49454e44ae426082 ] && printf '%s\n' "$data"
}

install_app_icon() {
    local payload
    mkdir -p -- "$(dirname -- "$ICON_FILE")" || return 1
    if [ -f "$ICON_SOURCE" ]; then
        atomic_write_file "$ICON_FILE" 644 < "$ICON_SOURCE" || return 1
    elif [ -f "$ICON_FILE" ]; then
        return 0
    elif payload="$(icon_payload)"; then
        base64 -d <<<"$payload" | atomic_write_file "$ICON_FILE" 644 || return 1
    else
        return 1
    fi
    return 0
}

write_default_config() {
    local v4l2_nr="$1"
    t CONFIG_TEMPLATE "$v4l2_nr" | atomic_write_file "$CONF_FILE" 600
}

cmd_install() {
    if [ "$EUID" -eq 0 ]; then
        err "$(t INSTALL_ROOT)"
        exit 1
    fi

    echo "=============================================="
    echo "   $(t INSTALL_TITLE)"
    echo "=============================================="
    echo
    if ! command -v apt >/dev/null 2>&1; then
        err "$(t APT_UNAVAILABLE)"
        err "$(t APT_OS)"
        exit 1
    fi

    ask_yn "$(t INSTALL_QUESTION)" y || {
        info "$(t INSTALL_CANCELLED)"
        exit 0
    }

    # ---- 1. System packages
    info "$(t INSTALLING_PACKAGES)"
    if ! sudo apt update -y; then
        err "$(t APT_UPDATE_FAIL)"
        err "$(t INSTALL_ABORT)"
        exit 1
    fi

    local pkgs="curl v4l2loopback-dkms v4l-utils pipewire pipewire-pulse wireplumber pulseaudio-utils zenity yad libnotify-bin"

    if apt-cache show adb >/dev/null 2>&1; then
        pkgs="$pkgs adb"
    else
        pkgs="$pkgs android-tools-adb"
    fi

    local kver; kver="$(uname -r)"
    if apt-cache show "linux-headers-$kver" >/dev/null 2>&1; then
        pkgs="$pkgs linux-headers-$kver"
    else
        warn "$(t KERNEL_HEADERS_FALLBACK "$kver")"
        warn "$(t KERNEL_HEADERS_WARN)"
        pkgs="$pkgs linux-headers-generic"
    fi

    # shellcheck disable=SC2086  # deliberate: $pkgs is a space-separated package list
    if ! sudo apt install -y $pkgs; then
        err "$(t APT_INSTALL_FAIL)"
        err "$(t INSTALL_ABORT_RESUME "$(basename "$SELF_PATH")")"
        exit 1
    fi
    ok "$(t PKGS_INSTALLED)"

    # ---- 2. scrcpy (official build) if missing or too old
    info "$(t SCRCPY_PREP_INSTALL)"
    if ! ensure_scrcpy_installed; then
        warn "$(t SCRCPY_INSTALL_WARN)"
        warn "$(t SCRCPY_INSTALL_RETRY)"
        warn "  https://github.com/Genymobile/scrcpy/blob/master/doc/linux.md"
    fi

    # ---- 3. Secure Boot: v4l2loopback-dkms needs signing / MOK
    if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
        warn "$(t SECURE_BOOT)"
        warn "$(t MOK_WARN)"
    fi

    # ---- 4. User groups (/dev/video* and ADB access)
    local need_relogin=0 grp me; me="$(id -un)"
    for grp in video plugdev; do
        if getent group "$grp" >/dev/null 2>&1; then
            if ! id -nG "$me" | grep -qw "$grp"; then
                if sudo usermod -aG "$grp" "$me"; then
                    need_relogin=1
                    info "$(t GROUP_ADDED "$grp")"
                else
                    err "$(t GROUP_ADD_FAIL "$grp")"
                fi
            fi
        fi
    done

    # ---- 5. Persistent v4l2loopback
    info "$(t V4L2_SETUP)"
    local v4l2_nr="$V4L2_NR_DEFAULT"

    if [ -f "$CONF_FILE" ]; then
        local saved_line
        saved_line=$(grep '^V4L2_DEVICE=' "$CONF_FILE" 2>/dev/null | tail -1 || true)
        [[ "$saved_line" =~ /dev/video([0-9]+) ]] && v4l2_nr="${BASH_REMATCH[1]}"
    fi

    if v4l2_node_exists "/dev/video$v4l2_nr" && ! v4l2loopback_loaded; then
        warn "$(t V4L2_BUSY "$v4l2_nr")"
        local candidate found=0
        for candidate in $(seq $((v4l2_nr + 1)) $((v4l2_nr + 20))); do
            if ! v4l2_node_exists "/dev/video$candidate"; then
                v4l2_nr="$candidate"; found=1
                break
            fi
        done
        if [ "$found" -eq 1 ]; then
            warn "$(t V4L2_USE_INSTEAD "$v4l2_nr")"
            if [ -f "$CONF_FILE" ]; then
                if set_config V4L2_DEVICE "/dev/video$v4l2_nr"; then
                    warn "$(t V4L2_CONFIG_UPDATED "$CONF_FILE")"
                else
                    err "$(t V4L2_CONFIG_UPDATE_FAIL "$CONF_FILE" "$v4l2_nr")"
                fi
            fi
        else
            err "$(t V4L2_NONE_FREE "/dev/video$v4l2_nr")"
            err "$(t V4L2_FREE_HINT)"
            exit 1
        fi
    fi

    # exclusive_caps=1 (also in the modprobe below): the node announces OUTPUT only while idle, CAPTURE only once scrcpy writes, so Chrome/WebRTC accept it.
    local v4l2_conf_ok=1
    sudo_atomic_write_file /etc/modprobe.d/phonecam-v4l2loopback.conf 644 <<EOF || v4l2_conf_ok=0
options v4l2loopback video_nr=$v4l2_nr card_label="$V4L2_LABEL" exclusive_caps=1
EOF
    printf '%s\n' "v4l2loopback" | sudo_atomic_write_file /etc/modules-load.d/phonecam-v4l2loopback.conf 644 || v4l2_conf_ok=0
    if [ "$v4l2_conf_ok" -eq 0 ]; then
        err "$(t V4L2_CONFIG_WRITE_FAIL)"
        warn "$(t V4L2_REBOOT_WARN)"
    fi

    if v4l2loopback_loaded; then
        warn "$(t V4L2_RELOAD)"
        sudo modprobe -r v4l2loopback 2>/dev/null || warn "$(t V4L2_UNLOAD_FAIL)"
    fi
    sudo modprobe v4l2loopback video_nr="$v4l2_nr" card_label="$V4L2_LABEL" exclusive_caps=1 || \
        warn "$(t V4L2_LOAD_FAIL)"

    if v4l2_node_exists "/dev/video$v4l2_nr"; then
        ok "$(t V4L2_CREATED "$v4l2_nr")"
    else
        warn "$(t V4L2_NOT_YET "$v4l2_nr")"
    fi

    # ---- 6. Install this script as "phonecam" in ~/.local/bin
    info "$(t INSTALLING_PHONECAM "$INSTALLED_BIN")"
    mkdir -p "$BIN_DIR"
    if [ "$SELF_PATH" -ef "$INSTALLED_BIN" ]; then
        info "$(t INSTALLED_COPY)"
    elif ! atomic_write_file "$INSTALLED_BIN" 755 < "$SELF_PATH"; then
        err "$(t INSTALL_COPY_FAIL "$INSTALLED_BIN")"
        exit 1
    fi
    ok "$(t SCRIPT_INSTALLED)"

    if [[ ":$PATH:" != *":$BIN_DIR:"* ]] && ! grep -q '.local/bin' "$HOME/.profile" 2>/dev/null; then
        if ! { printf '\n# %s\n' "$(t PROFILE_ADDED)"; cat <<'EOF'
if [ -d "$HOME/.local/bin" ] ; then
    PATH="$HOME/.local/bin:$PATH"
fi
EOF
        } | atomic_append_file "$HOME/.profile"
        then
            err "$(t INSTALL_FILE_WRITE_FAIL "$HOME/.profile")"
            exit 1
        fi
        warn "$(t PATH_ADDED)"
    fi

    # ---- 7. Configuration
    mkdir -p "$CONF_DIR"
    if [ ! -f "$CONF_FILE" ]; then
        if ! write_default_config "$v4l2_nr"; then
            err "$(t INSTALL_FILE_WRITE_FAIL "$CONF_FILE")"
            exit 1
        fi
        ok "$(t CONFIG_CREATED "$CONF_FILE")"
    else
        info "$(t CONFIG_EXISTS)"
    fi

    # ---- 8. Application icon and launcher
    if install_app_icon; then
        ok "$(t ICON_INSTALLED)"
    else
        warn "$(t ICON_INSTALL_FAIL)"
    fi
    local desktop_icon
    desktop_icon="$(window_icon)"
    mkdir -p "$DESKTOP_DIR"
    if ! atomic_write_file "$DESKTOP_FILE" 644 <<EOF
[Desktop Entry]
Type=Application
Name=PhoneCam
GenericName=$(t "DESKTOP_GENERIC")
GenericName[en]=${MSG_EN[DESKTOP_GENERIC]}
GenericName[es]=${MSG_ES[DESKTOP_GENERIC]}
Comment=$(t "DESKTOP_COMMENT")
Comment[en]=${MSG_EN[DESKTOP_COMMENT]}
Comment[es]=${MSG_ES[DESKTOP_COMMENT]}
Exec="$INSTALLED_BIN" menu
Icon=$desktop_icon
TryExec=$INSTALLED_BIN
Terminal=false
Categories=AudioVideo;Video;
StartupNotify=false
EOF
    then
        err "$(t INSTALL_FILE_WRITE_FAIL "$DESKTOP_FILE")"
        exit 1
    fi
    ok "$(t DESKTOP_CREATED)"

    # ---- 9. User systemd service (autostart + tray)
    # default.target on purpose: not every desktop starts graphical-session.target, so the agent waits for DISPLAY itself.
    mkdir -p "$SYSTEMD_USER_DIR"
    if ! atomic_write_file "$SYSTEMD_SERVICE_FILE" 644 <<EOF
[Unit]
Description=$(t "DESKTOP_DESCRIPTION")
After=graphical-session.target

[Service]
Type=simple
ExecStart="$INSTALLED_BIN" agent
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
    then
        err "$(t INSTALL_FILE_WRITE_FAIL "$SYSTEMD_SERVICE_FILE")"
        exit 1
    fi
    systemctl --user daemon-reload
    agent_stop >/dev/null 2>&1 || true   # enable --now leaves a running agent on the old code
    if systemctl --user enable --now phonecam-agent.service 2>/dev/null; then
        ok "$(t AGENT_ENABLED)"
    else
        warn "$(t AGENT_ENABLE_FAIL)"
        warn "$(t AGENT_ENABLE_MANUAL)"
    fi

    echo
    echo "=============================================="
    ok "$(t INSTALL_COMPLETE)"
    echo "=============================================="
    echo "$(t USAGE_LABEL)"
    echo "  phonecam menu      -> $(t USAGE_MENU)"
    echo "  phonecam webcam    -> $(t USAGE_WEBCAM)"
    echo "  phonecam mic       -> $(t USAGE_MIC)"
    echo "  phonecam both      -> $(t USAGE_BOTH)"
    echo "  phonecam status    -> $(t USAGE_STATUS)"
    echo
    echo "$(t PHONE_LABEL_INSTALL)"
    echo "$(t PHONE_STEPS "$CONF_FILE")"
    echo

    if [ "$need_relogin" -eq 1 ]; then
        warn "$(t RELOGIN_GROUPS)"
        warn "$(t RELOGIN_NEEDED)"
    fi
}

# ---- Uninstallation
cmd_uninstall() {
    if [ "$EUID" -eq 0 ]; then
        err "$(t UNINSTALL_ROOT)"
        exit 1
    fi

    if [ "$SELF_PATH" = "$INSTALLED_BIN" ] && [ -z "${PHONECAM_UNINSTALL_TMP:-}" ]; then
        local tmp
        tmp="$(mktemp /tmp/phonecam-uninstall.XXXXXX.sh)" || { err "$(t UNINSTALL_TMP_FAIL)"; exit 1; }
        cp "$INSTALLED_BIN" "$tmp"
        # Re-run from a temp copy (uninstall deletes the script bash may still be reading), via bash so /tmp may be noexec.
        PHONECAM_UNINSTALL_TMP="$tmp" exec bash "$tmp" uninstall
    fi

    echo "$(t UNINSTALL_STOP)"
    stop_all >/dev/null 2>&1 || true

    echo "$(t UNINSTALL_AGENT)"
    agent_stop >/dev/null 2>&1 || true   # disable --now misses a hand-started agent
    systemctl --user disable --now phonecam-agent.service 2>/dev/null || true
    rm -f "$SYSTEMD_SERVICE_FILE"
    systemctl --user daemon-reload 2>/dev/null || true

    echo "$(t UNINSTALL_SCRIPT)"
    rm -f "$INSTALLED_BIN"

    echo "$(t UNINSTALL_DESKTOP)"
    rm -f "$DESKTOP_FILE"
    rm -f "$ICON_FILE"
    rmdir --ignore-fail-on-non-empty "$(dirname -- "$ICON_FILE")" 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty "$(dirname -- "$(dirname -- "$ICON_FILE")")" 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty "$(dirname -- "$(dirname -- "$(dirname -- "$ICON_FILE")")")" 2>/dev/null || true

    if [ -d "$SCRCPY_DIR" ]; then
        echo "$(t UNINSTALL_SCRCPY)"
        if [ -L "$BIN_DIR/scrcpy" ]; then
            case "$(readlink -f "$BIN_DIR/scrcpy" 2>/dev/null)" in
                "$SCRCPY_DIR"/*) rm -f "$BIN_DIR/scrcpy" ;;
            esac
        fi
        rm -rf "$SCRCPY_DIR"
    fi

    echo "$(t UNINSTALL_MIC)"
    # Exact key=value token match: "PhoneMicSink" must not also match "PhoneMicSinkOther".
    pactl list short modules 2>/dev/null \
        | awk -v s="$MIC_SINK_NAME" -v m="$MIC_SOURCE_NAME" '
            function arg(key, want,   i, tok) {
                for (i = 3; i <= NF; i++) {
                    tok = $i
                    if (index(tok, key "=") != 1) continue
                    tok = substr(tok, length(key) + 2)
                    sub(/^[\"\047]/, "", tok); sub(/[\"\047]$/, "", tok)
                    if (tok == want) return 1
                }
                return 0
            }
            $2 == "module-null-sink" && arg("sink_name", s) { print $1; next }
            $2 == "module-remap-source" && arg("source_name", m) { print $1 }' \
        | while read -r modid; do pactl unload-module "$modid" 2>/dev/null; done

    echo "$(t UNINSTALL_LOGS)"
    rm -rf "$RUN_DIR" "$LOG_DIR"
    rm -f "$(dirname -- "$SCRCPY_DIR")/.install.lock"
    rmdir --ignore-fail-on-non-empty "$HOME/.local/share/phonecam" 2>/dev/null || true

    local del_conf=""
    read -rp "$(t UNINSTALL_CONFIG_Q "$CONF_DIR")" del_conf
    if [[ "${del_conf,,}" =~ $YES_RE ]]; then
        rm -rf "$CONF_DIR"
        ok "$(t CONFIG_REMOVED)"
    fi

    echo
    info "$(t REVERT_V4L2)"
    echo "   sudo rm -f /etc/modprobe.d/phonecam-v4l2loopback.conf"
    echo "   sudo rm -f /etc/modules-load.d/phonecam-v4l2loopback.conf"
    echo "   sudo modprobe -r v4l2loopback"
    echo
    info "$(t KEEP_PACKAGES)"

    ok "$(t UNINSTALL_DONE)"

    if [ -n "${PHONECAM_UNINSTALL_TMP:-}" ]; then
        rm -f "$PHONECAM_UNINSTALL_TMP"
    fi
}

# ---- Usage and entry point
# Column layout lives here, not in the catalog: translators only supply the description.
usage_row() { local pad; printf -v pad '%18s' ''; printf '  %-15s %s\n' "$1" "${2//$'\n'/$'\n'$pad}"; }

usage() {
    printf '%s\n\n%s\n\n' "$(t USAGE_TITLE)" "$(t USAGE_COMMAND "$(basename "$SELF_PATH")")"
    usage_row install "$(t USAGE_INSTALL)"
    usage_row uninstall "$(t USAGE_UNINSTALL)"
    usage_row menu "$(t USAGE_MENU)"
    usage_row webcam "$(t USAGE_WEBCAM)"
    usage_row mic "$(t USAGE_MIC)"
    usage_row both "$(t USAGE_BOTH)"
    usage_row stop "$(t USAGE_STOP)"
    usage_row status "$(t USAGE_STATUS)"
    usage_row cameras "$(t USAGE_CAMERAS)"
    usage_row choose-cam "$(t USAGE_CHOOSE)"
    usage_row config "$(t USAGE_CONFIG)"
    usage_row help-connection "$(t USAGE_HELP)"
    usage_row version "$(t USAGE_VERSION)"
    usage_row 'l|lang' "$(t USAGE_LANG)"
    usage_row agent "$(t USAGE_AGENT)"
}

main() {
    local cmd="${1:-menu}"
    case "$cmd" in
        install)
            load_language_preference
            [ "${2:-}" = "--yes" ] && NONINTERACTIVE=1
            cmd_install
            ;;
        uninstall) load_config; cmd_uninstall ;;
        menu)       load_config; gui_menu ;;
        webcam)     load_config; start_webcam ;;
        mic)        load_config; start_mic ;;
        both)       load_config; start_both ;;
        stop)       load_config; stop_all ;;
        status)     load_config; status ;;
        cameras)    load_config; list_cameras ;;
        choose-cam) load_config; choose_camera_gui ;;
        config)     load_config; open_config_editor ;;
        l|lang|language) load_config; toggle_language ;;
        help-connection|ayuda|help-conexion) load_config; show_connection_help ;;
        agent)      load_config; run_agent ;;
        tray-status) load_config; status | yad --text-info --title="$(t STATUS_DIALOG)" --window-icon="$(window_icon)" --width=480 --height=360 2>/dev/null ;;
        tray-exit)  agent_stop ;;
        version|--version) echo "PhoneCam $PHONECAM_VERSION" ;;
        -h|--help|help) load_language_preference; usage ;;
        *) load_language_preference; err "$(t UNKNOWN_COMMAND "$cmd")"; usage; exit 1 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi

# ---- Icon (PNG, base64)
#@iVBORw0KGgoAAAANSUhEUgAABAAAAAQACAYAAAB/HSuDAAIAZ0lEQVR42uyYT04UQRyF36uhh0hM
#@iIwsNFFEE2JEg9EVC41bDuAV3LlQL8ApNPEe7r3A7MCVqAlEDUoQ/4zo0P25mIUbomO6erpnrO8C
#@1fV+r6rrPSuRSAzF6t0HJz7vt+eRO4H+aReeJzBPaHVUFB1LcwruGLcRU4KTkiR7RlJbA2YlyXZb
#@MKNhsf6IbVWGVS9u9trIjdk3MJa6QzNmDox8baDyfUO1M0dU5jeIb1ggut+AqHsHRQUR8Z5RHBz3
#@zgKq8lz8c+HR6w2U9zsl/4U+Rhv7i+FIGlCgA8vfJXq2PxUFPVtfCdoTfJS9F2jt5ervKnj30PnO
#@wbMn++mVmkgMj5MEiYS0tnZ/+vXPbKElLpqpRcyi0UJwuFBIZx00J5hRHfivoT+F/xT+jwUYK92h
#@GTMHJrJ4gOpmjqjM7xDfsEB0rwMl9l5DCeBSXiqH4xeXQON0R5S2KzTsnqFM+B+Aos+8J3lb4p3l
#@beQ3OflWFqa2+of9lx+eP36fXrqJRCoAEv8jN+9lV07NXfVRvuKWl0SxKGtB8nlbZ4RCI0Po8YE/
#@hf8U/v8JYKx0h3pnDmhkeHTrQamZxy8BXDYEOdb31hhCawijVimgmWcNiKR7s0oXaNA9Q5nw/xvE
#@KP9r34At2y/ssJHnxWbb2cbO6uwrra8X6YGcSAVAIjEBXLr98FyWaSWjdR1xzfKyrCWkTJI8JiHU
#@tjQghf8U/qMBjI3uUO/MgYkrHqC6mSMq8ztENKxL6B01hNZQAlhRgJjnnFjaN053ROzSpX6/Uyb8
#@D0A04az1hDcV6FLQbYXQfbv7Y0Pdp/30kk6kAiCRaDBLdx5dng6+lcs3bC0L/WLvzIPtqq4z//3O
#@e5KAGNPwnmRMx0M7HpCegNi44qYw0ns2RgOl2N0V7BTd7nQ71QrSg9hCkmV6KL92qrvpTtmJgyse
#@M3gom5hUquKhDA4Q4hAH7DiBSlIZqjL9EaeMcAZDEgbdu5JUQm4pCF3Q2fusdc5dn+r+qdpv77P3
#@Ofv3rbXX3go6u/WERy4Cnmg74T/hv88p6B6R0IoRaOvQ9DDv4xb1TQDaQhA1TBdvCK0/9ymb+WBW
#@8qiHhTI4zWKZLmaB5ru1gP/yJkDpDKNHJd0vuAcb/8qxMXc/+Avv+3rutlNpAKRSjmf1/+Sx076L
#@0fhS5ppLZXqV0MbiEx0H6P9HJfwn/HcvqsJnYBjyLrLom3lQuwlTnUwTMxxMF98sG7OSc87BBKDb
#@9WUWLPVe5pN1QZ1xNiFZiW+q9cXw+SNhXzbZL+uxudsfuPOmP8gdeSoNgFSqkl6+64aNjz/y2GVj
#@cSmNLpHpFcCGqhOczqE/4T/h3084AGioImQOty3Qoi2HWgsOZ6Cnr0Nr028fE8A/BdzBAHCa72YW
#@6D3jZAAwZXxqrkE0kYcJQN2xBf3JWPaLMt051uO3P3jbh/4sd+ypNABSqVPV8tr8BfN/tTwaze2a
#@gysMLXUawKcz6E/4T/gPMe7+EOoARfTrhgUzc6q1EOwM9JMoNv5cN7NA893BBHCc72bBUu9lYTIu
#@zKzeGkSSHAwAv2wPM3Qf0q02Hn/ugbOO3qtbbhnlhj6VBkAqdRK9/DUHX/D4qNnNnHYaWpb0bJcJ
#@TXXoT/jXRBC772YJ/9U252gih6iYd9V3/3F3MAGwUvA/kUXLuHAA7WnC5W/zf8dMqt47jXtN2C1m
#@dpVfg/itETOLkWVj9k0Tt9HoM+O/HX/+768gfDh3+qk0AFKpq66au/DBF79y3Ixeb+PRbmgulIRw
#@nMg4gP+A4R9mJ/JvNhD497/33GFjXGwcXMe8/nV7bmnQ09ehxc+4MDMfwwtHcwJJ8j5m42QAUH+8
#@zYqYXWXXIKVMMk8ToXgdnUck7kb2eTs2/6kH7njvNxICUmkApGZGy8trpz3IQ7ul5o2SdgudWWIm
#@ogLCAfoHAP+Qaf8+d67HG3czc2g73ribmXPWQfxCiyYrBf8TWfSMCwcTAMcMBYrM8QLj7mAC4ACq
#@7cyu9muw1DOX1TV8/AstHhPcaRp/asTcz/35F276VtJBKg2A1CAj/ecffcFlTcObMF0FWtBEg4J/
#@YGAAPBHkmf/Ssqh997+OqQ4k0WWb5pV14FB1vm4atIlTXFSRINTBBMD5mIK8M4ycDAC6HWuzEuvc
#@2q9Byjx0k4Uw2sw6KaL7qEm/IPSz69Y9fsvXP/uhv0loSKUBkOp1Eb/NfOuKRnNvkrQHdHbpGUig
#@2Q8MBoAhC/5VhH9/U4Cu4dvCPHMzD/PBfA0X/6rzJ5WpBXi0SEX2PuZiZg6ZLg4GgGuNDQcTAMd0
#@dVqPcQv4L/vQTeZg+PgWWkT6izF8ojmmD3/j9vf9ZoJEKg2AVG90/srh7fOy7zPp9cA5NWYfQWY+
#@MAgAhqz27wD/PhtpPPtgIZ65mYfxYF2ZDb28ZcFkDuvQv9CjmcO5+8FkAfiPu1mcjAsrM8Yt4H+i
#@zrMAqPeczXzmG+hXhT4yN//4zZkVkEoDIBVSz3/1vrPPnH/W1U2jfSYt1Zp5BJn1QK9XHE1e9dcO
#@/v1lPR53MwvxzM2G2W8z6+UtCyYLvw7NLPhVg1Pa7r8JUGHc/U0Xk4XJbjKzFvDvYABQ/1mbuc63
#@bwlutmPHPnD09g/8RhJHKg2AlLsuXLnhVSM7dg3YmwSnS9KQ4R/o5WqDvOe/Lvz7y3o67mbm/8yt
#@a+PBen3swKzeOjdZvXXoAKE+Nw3Ey9ox3wKb9U0ASo2zf3aTmbWA/xomgH+2h1mM+Wbia2ajD/EY
#@n8wrBVOl1OQQpJ6ONl/2tudesHLof25dOfSHY47dQ6P/XBP+CQD/QK/gH574Jfw7wL+LmPx6Ne6A
#@AFURMYtbAqotGiq/X+qsc0T4dQiksRztT6PfnUOE6TecbA3mfsK3bbuYpvmgTuNPN+669kf/1e7V
#@FySVpDIDIFVVSysHd0CzirTTpHW1ZxsBZjrQl7v282PtA//xhfdNAw5ROfeK96X6Gv/YgVnZdW6i
#@ZUTU/5YH/5sGZiYLwP+KRwpG3mUhjjaZKJflUm5c/KPvFmO+mY7TMdDPaNz88AO33XR/kkoqMwBS
#@ZXTx3nVLKweu3rJy6GvQ3CppzyzAPxAe/kGChP+E/+l9Z/JzHPcO1x5t11Wptv3fM4CAAMeLhrcO
#@gbDvOFAxIVRCZBT4pEIUaRvar0Eg9xP9aHveTP/BGN+3cdfq3YtX7N+TAd1UZgCkTlkvftV1zz7t
#@tA0/YOgHafj2rmYZzjMcUBVRK9Kf8J/w36bvxeV/9RoOBe8cIpEOxbCqziUTLSKivjJZyPluFrSP
#@Vf4m/+sdzYr1y6WuiYl2N4rUzwLwj76b/3wzTdX9Y7P3fPPRTZ/UXWvHkmhSmQGQmqoLLn/Hi7Ys
#@X3/ThjM2/Kk1+v+zAv9AWPgHCRL+E/7r1dcgdKYLAhyzbLpa5/Ta4ITykX/EzIVOgBZtO2QBeIly
#@8xkYXAQa2q9BIPcTAdtGU3VRAx/dePrR31vYsf/a8/bsPSPpJpUZAKkT6mXLb3/lvEYHge8xab74
#@ZhGXiedfjItSkf6E/4T/7sbdSrftWwG8fjYA1fsYuOp8u8ijidKRXv+rLf1vGohfD6D0uPtf71g/
#@C4A6GUwmpo8LzmkfSCYLke1h1uHfQJHhPDq28bvPfPRv3/vHd/30I0k8qTQAUlpaOXypZO+S9Jpy
#@UBwf/gFVF6cK/Qn/Cf9xxt1Ktu1QBMyh6J0TkDiYAFQDj/gmAHWNFTNr+8zjHwVwGPf2pouDAdBq
#@nQcx4Kz9WjNZAHO1w2MAFB/SP5bsfx098+jHdcstoySgVBoAM6il5cPfadI7wV4via7hH6cZDYRb
#@TSBJCf/ThKgC/ybLN/jTlJVo2/+ue4dq0LWBxMEEoBp4xDcB0ER1TYBgt1sUBu5Tat/JAKDFWLue
#@e2+5Bik0vlYow0jmYK46GABU9VR+d2z2f795yaZPaG1tnESUSgNgJs74H7lgdGz8ruPBf/jwD6gz
#@4QD9PYN/RMTI/0CikfVlDm2Hex5IZu5HHpxSYtvBhwmvZ+1YaNE/08Us3nEHKzzu/qZL4WsBqXN8
#@yUT3z9wKZHvIYkTfzf/dbmon4LfMRu86euv7b0k6yiKAqcFG/A+8eMvKoZ+00eg3wN7gAf84wD8Q
#@Cv5hNuCfKf96Cv8n7h9P+g3euuWJHwohhFD36xxUXUDVYlxAp9lNJjwLv/Wu0CJQ7JlDRUM9b/Ap
#@pPp9MpHHCAfQNu0NiK1mfHrjjv1fXtyxfyVJKTMAUgPS5m2HXwK21jR6k0lznXxgcJxcxNukgOqL
#@Pm9Q4sO/f/G1+BsV6/G1bP5nQv2PPJhZxXoDJeC/1lqKv9ZNFuxqyw6PAlBtzKsXvrMw597bwL9D
#@FgBT14NT9L1yMUBaDGeR+c5nGprrH/jCTX+Q9JQZAKme6vmv3nf25pWD72HOfotGV88Q/IeJwsKw
#@4B+Y/CDhnzJjCAwiSkEgF5mqz9xvrdNQe31XmW/QFv6dzUcczVHK9hUCfluKtF/4WkDiZNO1FWTk
#@P2LbQLBxt+8e2+h3Fnbuf+/id7/lzCSpzABI9UprzeZtD/8X5nQj0qIm6hz+iXkncP1+o+6EW2Q/
#@4T9+8Tf3vlvcbICq5979r5zziExNX4dmDmfu24rW4+iQ9VBgntJx1D3U7RYF+xXk3PvYWsN//SwA
#@WrzXHeprmMXI6rI638ivG7rhm1/48Y9LsmSrzABIBdbW1x583dblh+9v5vSRhH8Hpx4H+C8f3U/4
#@nyZcsi16GSFBEjHrA1Q99w79LmoKlIT/mb3RBBh8JBQo3ySO5jWOJjh1MppMCDLyX7ptqJjV5b9/
#@Pg/TRxd37L9r047rLkrCSgMgFVAXXnHo3ywtH/yUjfmioa2SNCvwT4Mr/DP5dSuqAX/Cf+CCUDQI
#@CLA57aUR4L05LNl+9XkAlID/yunn8Yu/AUWfeSlBgmAXbYNvv03EM3xo33dEzrd/EjX/I9o2ZvTr
#@izv3fezcXddtTOJKAyAVQC+6/MhZm5ev/5Fjj+t3Bd/rslHCZ5MPuDqnNBLIRxQF/oT/fkYjWzxP
#@340K/tkAHRpt/a5+DhQHDyg/7kDotQ4UaxsIGAlFJUQw0wUI811DFDDg0vApHX2HwewnpvAhbx7Z
#@6HcWd+y7RmtryYtpAKS8tGXb4becPh79fkPzNqT10+GvPvzXl3+BHpBoAn8spwNiwn8vP9aOBg+a
#@ooEaAaiAWmQIEQOAgeJRR6gBoRkRbAUvSFKA1Pt4pktdSER51d+Mtw30ou8mLQjev3jPN760uHPf
#@y5LE0gBIdaitrzn8HUvLB29nzn5Cpk0O0SE3+Ae84H+yiad3EJjwPxj4dzB/UDvFNwIipQJPRCwA
#@BkqAR+1oZOj5DoQ0fCBBsC8ZF4jWaxBK1VnwJw5EH6+LriI6bZ9LJe5b3Ll/TVddtT7JLA2AVFWt
#@NUvbDq/a2O4TvNb3bKRLyr9bhASCbVKmg17C//Dhv74ZQLfdJEo2AC6RwImICcBA8XUIDmfufYt7
#@BjV8gqXeO5gutQUZ+c86D5I0GLPrNEnvXHxo41cXr9h3cTJaGgCpClpaOXLR0vLD96qx9wk9yxf+
#@XaL+Lh9riJsuBgjIy0kT/uuYAfh1Gbe26QgCqxs+LvUGTGQEWtMFhIMhSBDsS40JRGv4J8p7BrUW
#@IjNNfPt+oRru2bhj9cYX77puQxJbGgCpErp477qlbQf/h41HX5H0SiHNGPxHcer9xFOCW8J/wn8J
#@MyAskED3bSOE6MhgdIjEloGh4lf94Vp0L68ZdCnA15EHCcQxOMnIf8S2AQdjt7zwa3/esCN/aaOv
#@LexefVXCWxoAqRY6f/nQ8tKZZ/22Gn4ItH6G4N/t3nOIBv9PGouE/4T/umZAQ6h+gwTdt41QF4Kq
#@2R416w0UvuffwQRwBUECXDMYut7BAG86iAX/EMRoIzNNis0x/xtVlhjbryzuXH33eXv2npEklwZA
#@6hnokksOnL5l+fD759Adkr0kyn3ISGJY6ZHTIQP/+94lJfwn/Htkm4TqN3TRtpcJUN3YqVVvoBD8
#@O5kA/uZuwEhoMCBSGQGDOm6ByMj/031X4wnfzkONPDQn2fWPHZv/tU07rrsoqS4NgJSm64LLj1zw
#@0Ia5ryC7RqYmEvxrgPAPEsSLwgrNrpAEU36NgPK/xvkWBeQnHAtM0mK9Vm4bIYTfow+cBm0iVMG9
#@+Cng/cj2gFjjTpxxjzLfi8E/ZLZHSUEGEzRpe/O4Gd27sGvfEa2tJV+mAZB6CvEPFf7Hj4/uNWmr
#@JM0S/AMCAt7L63AOGw1YU+C+QYIwd+gA034zc/c4ECZCAhJ02vZQTICS8F+to5D3f5+KgMxu6knG
#@BaiAmuFE/inRFIMwHoAh1RbZgLhx470P3Lq4Y+9zE/XSAEhpoqXlw+cubT906z9V+D992PDvH50B
#@B/h3MD2CQn67cY+Z9t/eHEB+4tT76j/uEpRs2z8bAEkEP3tuonrBPSje78hXuQZc57HGHbVQp7Ul
#@8qq/rPPgP+4EG3eTXqdm/r6NO1d3J/WlAZCStHnl0JXC7he6QpJmCf6BTuEfh+CyT7/9QX+Kegb/
#@xc2BAVUgj5ECDsXaHn42ABJQHDyAoBA6EQ2DhyEgQXBKxkWUfkP7NYhoPebgcHyzYhaAf6ZJrrWn
#@0CbDPrewe/9787rANABmVhfvWTvjHwr9NabPyrRpBuG/W8bD9cU5PWpKP2H/BEr4f0YV94dRbwBw
#@j4pB63U+fBOAdt8PE50X3IOifQ+71oBwRz0gVuo9gd7vQEb+S7afdR6OEzDUTBcw/eBfavTlxd2r
#@L00aTANgprRl2zte/shDf30fsmskEQn+cYD/4FBQH4xQRE2D/YT/su0XrC0w2/MdyrbtfySgkGj3
#@HTHhFoGGIUSBpwsICEMOhpPDne9+z7w9/CNKGW3+V1sylEwTf+OD2KbLK2T2tYWd+/5jUmEaADOh
#@pW2H/xOM7n7ier9o8K948F//bDCdg9BE9AL4E/592j9FQyCPuYAEnbVd3wRwhiETLSLQ1b9PWYHc
#@4biDV9+JddwiI/8B1xpiEP0Ghv6Oexbw8cVdqx/UVVetT0JMA2CYWl6b37xy8D1q7KPCzpg1+Ac6
#@hH/XlKn2L21/4E/4j1sd2OHcfaH1gNcUL9K2vwnglH5uomQ0MKPAUwSEO+4Awyt2CAR65u3hHwiR
#@7QHktZoDMl2ADtq2vYsPL96ZtwSkATA4bX3tW5+zxR66ozEOSNIMwn9nhcCgN2egncSJqtQk/Hcl
#@qhUXDB+NBJyLMg3NBKiffm6i5bgT2tyFsLeK5DvuJCJQ34GM/KOywqHtgV5nSm/WOZeqmf+1c3au
#@XpLUmAbAIHT+yuHtNlp3H7At4T9iFXCHKui4QP+kYZTwX1P+tw3ETc0Ep/PXXZ5sQQj/aUS797WJ
#@kGe/Ify5ez9Rr38wONMl/LEqE52nvkOf53vpscC938AsHW06r8G+tLBr35GkxzQA+n7ef7UZ64uS
#@zk34rwXgDh+sNiBDx8A/aTDh30HeqfdA2HvPAZ+2HTZupUXdYyaF4N/JBGAwGT75jjuJKNu2e6YL
#@DCfyD6i1yNoegfYTXbY9j7hxcee+j337VQdOT5JMA6BXuuSSA6cvbT/0MTX2PrD1swb/QEfw38t7
#@z+uD/0QJ/1kYSeB01SB111P81Mz6JgAV5pupHzUmwOfcffxzyA5ZADzjfuVxi0z7r942wr3f4D/u
#@9PGZw5sfefjRu8/dec0LkyrTAOiFXvqaA//6W+vn7hF6syTNIPx3lHqfG4UTpPcn/OcmaVok1iH6
#@3rERQMnsofhXzlEY/qeoBITmufseF72DOH0H+Yk6RfhMBEh9L2LuZvS7kIBZzXp4xTGaezftuvbS
#@pMs0AEJraeXIRetGza8KXZjwXyv1vjj814cTqkN/wn/Cf9Doe/y1Bg4psYVFBfgHokDo9GdHVuF2
#@EY5HZAoyEZCR/5BR4GGk/cMwMgldhDaNGd+xuHvf1UmZaQAEhf+DOzQefUnwvIT/E4iQ90DXBySq
#@Jf0m/OcmqWT0PVQaNND5Bg3q9h2oGhWjAngAVeZbSdEM/9w9EKroHUgi36/lxneyBiFG6jsM49w9
#@IvcTkuj3Wtsg8YnF3fvXkjbTAAilpVcf3IvxWaFnJ/zXSM3sFP6DwRCa/JTwL03EU/waSUz7Jfw7
#@1Lho9bf4Hy2KX3WeFuDRIgLtXn0danzPsghZfKOvaBZARv6r3LKQ0W+HejJD3Msg6Z0LV+7/CV28
#@d12SZxoA3mLL9sP/W/N80KR1swb/QAfwP5MfrCmUOkD455n+WrRdos3hVyB3AHDPoqITQb/fM7QA
#@j4IR6PpjENLUjn8OGAhlugAzXWvBRJU6C4hhgGAzlG9qXilaot+Y3rLxOfOfP/vyvWclgqYB4KLl
#@5bXTtmw/eDPYf5OkWYT/+tHIgRYhm06kA02PlEASTAHrwP1mSuaBgwYA4A4QWijriJgATIWCf0Do
#@aCTk8Z56cy9+31F7ARn510QwjOKaiDxGKImBvONMet38+vm7z96z9/lJo2kAdKqLlw8uHuWvbwfe
#@WGgRJfy3SPnv/5VESGIwm1M48U+SbNBn/msfN/AHcKBF24X/BpzfocQGMSpU+wemtO1b6wGqG06u
#@QsQ0XeJnXORVf302fIgw13EfdyANzokJsHVuNH/P4p7VVySVpgHQ0Xn/tz7/ETVfltmlBc+EJvy3
#@+LtbjLsz/CP1O01vAvjNdOPGZrngH6qY9eAE4chNNPgaqfSj8BwV1uEEQj1TwB1MABRCiFDjDnGg
#@gCDPHGgN/zTOcwXHqxZxXDc4B+WQg3p7veNzNbK7Nl157Y6k0zQAquqCy9/xIs3P/5JkL0n4jwz/
#@DtW4cQP/DqOhT/4d33bCf4vjBH0sjORYmKjL9qfM9+CF55iyDoOYAFl0z1v+GUYZ+Q/3Xcs6D0Nr
#@n+GN+5ljs89s3L36xqTUNACqaOmyg1tGo9EvS7ww4b/P8O99sMqh/ULAf7wS/kXN+gL92SQBAhzS
#@Ex2MgKafhecoug7j33cPNbNN/IUINecgzvuVIM8caA3/4DBXooIgQaLf/kUms67Jk2TrTfbJjVfu
#@//6k1TQAiur8bQcu0FxzJ2bnJfw/hQh5/3Z9SMAF/CeiC+BP+PcvONiPjzUQve3QKbFAlUioCQcI
#@dQZBSj5zMvLfgYCM/Ad85tCF2eRonOFcm4u83rGA5sz04cXd+65Pak0DoFDk/+3f1czN3SXZcxL+
#@A23Q4p9Zql8BjrLQP1HCf8j2kdQ4tB/uiI3/WgdVFVAc/ulBUTog6k0ys5UFQFdjHReGALUV8Azh
#@P2+3iN420Pu+M9xnjsS7N+5avTHpNQ2AVlra/vYVNePbMZ2T8J/wf5xwAf+JKAn9Cf99rIo8+bn2
#@u74RgEe7/htzoGTkv08mQOQ7sIdvAiA/UQi8M/J/nBBexTXL9p3cT0gSkIbPSWTYkYVdqz8miSTZ
#@NACesTZvf+vrjNFnhc7Mq/76B/+AA/x3RGOUgP6E/+F8MCubARRJa6/Qtv8mCSSICUMmOpvGiKC3
#@PJTNbgIy7X+IGRfUed4mBOR3bUqGj4tphtwE/QdwIPR8A7tucdfqB7S2llybBsAzgf8D/042/znE
#@txWOTCX8M8RzyHT4VmsD/Qn/A4P/+mYAxc+3V2jb33wAh1TkFuswtAmAo1GOeidE/4sdUv4bTu8j
#@/7WLAfYUQglhavd+P8EM7KMM7V34ytGP6+K965Js0wCYqs0r1++WNTc3DesT/ktGoOvDP+AC/52J
#@U4H+hP+ZTpXDYaNVAspxeK8FPgMNFC/4R/AINBC1xkVG/k8iyFTkgAX/ss7DwPYTQI7701uDVy88
#@Z/7TaQKkAXBSbd52cBvGpxP++/fRADp+eeEG/9OhP+E/4b9lVgCO175Rtb3eXmcKFF+HqKwQYc/d
#@Q8xvuv+4O/aLumOMg+FjokrqO7h/WwaTaYIIYHDmXqYy/E/ahjcsnLv+Zi2vzSfmpwHwJL1s+e2v
#@bBo+I4ud9q+Ef2f4dzi8xdPJqkj4zw9moawANEUVswHopL2qfQefoqYmQkw1RNj3OwRc57iOexVB
#@Rv5DwrcYRp0H/J85MPP7CSA8/E9k/37h245+Kk2ANACO09Ly4e9sbHSbmc6C2EBCwv8/C3CA/47F
#@ycA/4T/hv3BWAHIR0GlkCOhtGjRQdh1WeJ8gBr/WgEG+44BBHbego3vPTVS/1QPyu5b7iXJ7d4Yd
#@+T+RvufvTYCPZGHANAAkSS9dPni+2fg2xDlQGoBJ+B/EJgU3+K+f5h8f/oEuf94pij7C+e1P9ynI
#@QG8LzwFT1qF/Sioi5Ll7iFYJ2yELAFUXZOQ/IoQSIJAB+Btdwn3OQZouncH/RN+38NWjH04TYMYN
#@gPP/7dteOD/WFyU2SQn/Cf8nhn8XUSDaHx/+TwjfcNzPC0Sn/Yb5sUYS/ptDYBCZB1A3Am1iAFEx
#@BxOgyWhkrbGOuJeiTOX31vAPDGLOQYD5jv9aA2YewIF48D9dbznnqw9+QBKJ/TNoAHzHtuuf12yY
#@+0XB8yQJEv4T/qVJ2zjCfxnw94f/qTDddyA50W8YTj2TX+wiYPEzD6DK2fOC8O+QBYBL2r3/WWDq
#@/12IMO8ZyMi/kKS8ZeFfCsi0/wBtM8jI/3Qh+6+LV66+J7F/xgyAl192w8YNNHdIvDDhPyr8O0UF
#@wfXNTdNiHD3gfzoUD+BjXdkYIHi/kYRfJBIYRFoqlId/oEW/HUyASftZhbtfGRd57/mArvpDJABL
#@QvS+70Cm/Z9i2ya9bWH36v9J9J8RA2B5ee20R5rHfl7SSyQJsuBfH+C/E4G8BPHTUk1MA9106p++
#@MdC/jzWSiAwj8TOMoAj8F4hAO5gA0c7dS4JgqcAMz3ShcX3mRQW0hn9gEN+1EAWzGYLRlmf+HeB/
#@InTDwpXX/vfE/+EbAHzDHvopxCU1JjKQV/31Ef7BC/4nTRMf/uG4X6bptRQgJv/6028k0Xnb5eYd
#@vlkHUAr+677bQWXFsK/gAsq0Td50kGn/LdcmztFvf2PXq5isn/AbNho84b+A7IfOufLa708DYMDa
#@vP3Q/0N872ThxoV/Ev67gH9n8I9/Rg+QaATkGb3K4vh/8fuND9wAvd+cQnnwAKa07ft+R4Rc5zBQ
#@g1EEO27hX2uB9uBRJNsDyMrvQdpG9L7vNGTkv51A9sGFPde+IQ2AAWrLtkM/gHQ44T/h3xP+IXZh
#@JOCJX97zH8cQ8O53pfTmv2PvbH89u6o6/v2cOzOtnULbeaBteFAq0JkOLSgKhNAnKIUynSoko5iA
#@WpWBeUo77RQqEhyESAwJaDVBDJCYGBKQ+IKEmPhH+G8QwMgLCVBm5m7fkPxoczu/e+/e56y1z/l+
#@m1/6btbd++yzz/6stfZaK02SDUCurC5oX/APSP2uIVJ+1yBZNJA87zpgCE145x9c5FGSRP/nCbDD
#@Jwz+V9rQZvnmgeNn3mEHwIx09IELDwme6wFI6OQlho5bgIEEAeCfcuPeKq3f8K8ZZgcQcAgLvdaU
#@Pw0aKsCjAkLDDqftnQA+GKfu+b4S5Ki1QLO6G/1/1xC+ZlIrJGDxGRdAPPzX69cQ3z30vtN32gEw
#@Ax2578Ldgza+I5V9q4UasHkFwT/QFfyPrCDwz7Zxbwn9hv8+HQK5xo0ksvVizl2EDNq3+gOazjvM
#@PzIFydJxybPHAY78J80u6r/IY/y4EYsHcHqN/LfXQW0M/3n4/WduswOgY73hXRdeOWj4Xim6KTv8
#@y/A/Q/jP9dEAxPAC6Df8z8cZkGvcSGLyDgvdFp6Dde9hfFQK2o0dMeM2WLkigogA2xNnAaAdiZm0
#@+gPf+Q/8xjUVOO0/Gv5XNvXaTfivm3//yZvtAOhQ9zx8cf+ezeF7glf3ACQY/gPC8AHmCIB+EKuI
#@oOE/QGFZAWhRArqNhEI7+JeW1YMbmOdd3Hoo8HWLCvCoz7LJn/6OcFePBmMHXGgxEv7b6+6Ny5e/
#@rZOX9tkB0JkuP1++psKbxipYAhj+88N/GvBfjT0kImr4X5gQAoTQ0gRI9HnlAFrCf0AWAPXwEV/0
#@LhoI2o8duep8Bfyn/q5B/LxD/88csXgAp9I2EAv/7fWegz/94dclYQdAJzp2/1NPIT5k+Df8rxRs
#@iomj/ZLhP9R+rsrriEWNHRDQ2ZWDVvAf5ATAhbhGEdX2U123gBxOPqrh38XfUtnG8w448t9a8OGD
#@J859yg6ADnTX/c/cW7TxhbEWMuA7/wHwXxeKDzbFpNF+w7/hXyv17AjI72QEmsJ/fQQ6yAlAXeSt
#@SrQfJ7Se9/g9DmEIDYn8509/R3Ryfp03gIMdPkXke+alfO7A8XMn7QBIrKP3Pnm7tPktqeyTVoKc
#@GwhqKsN/nqj/SkwC/ob/F9eeQ0Iv+C1DVHQQ6F3EQBjQBP7rC0IFOQFwFe4QW/R7xQZyFFqkAv5z
#@7XHx6x36f9cQzrgw/G9lHyjfuOX95+62AyCj3nJqr4aN70jcHtAKKhz+AcN/jqj/SkSAf//wT8Vv
#@Zb/Vv9uRaNxBYEZjB9KmnxcxmYMR5hoFnjgLgIA5p37eEQaSqsi/i7+lto3nHWhjkgoWmRP8r3Tj
#@QPnubY+cP2wHQDId3f+y5xDv0IsEhn/Df4AZAsC/F/ivAO6QeV/zywfAC3MEUPX+hKafF1EDobGi
#@7baLyBcRxFebRou+Uz9uIAD+I9LflxH9Bhb/roEj/2mfOfqNKxub/6GTl/bZAZBER+976o+Bj+tF
#@goSLyfDfJfxDBfy3K+zXF/xXQHN31w5Y/SByj4lwBCwhQtIeSIoIgVCg4dgDnADhxbAC19zg6xat
#@wYM26y187BA/7zCH7zlV9sFZNvOD/5WK9M6DP/vRP9sBkEDHHnjmzTB8ZcyFDDQEouX15QW6LvYH
#@8b1x88N/FejP7oMJL/5NYXthjgByFnMFmr+HkOo6W4DiUu9hrgWE46Pv4FZ/15xPAuC3dwjF1y2i
#@bQN9w/96PX7wxJkzdgAE6p6HL+4vpXxb0g16kRj6g//4KEVf8D+2IAb+gYTwvwZy5Q/mjuaL1raX
#@4AiIg+D6iGD9ewhRDsb1YwcX4prMPo3nuP/WZ9Xwj7vYpLHNgOc9eG/Hkf/1KvzDwRPn3mUHQJCu
#@PF+ek/T6JW7cgOF/pXgTNAX/pPC/FcD6kFQ/lwHrrWdHAH204AKa9/kHNRWQsgo4onXqfYp5BwyC
#@M231B8wliFMlcOvgagDHaf8djH2PSvn2LSeeeI0dABPr2P0XTkg83svHGsO/4b8C/CvhvzGkGv7F
#@eBknkHfcgEJF1JjqoaCIscfte8hzjvyreRZAirvvMFV3i/yt/oDw9Y5Y/LuG8FnG8L8dHRzKlX/X
#@yUv77ACY7t7/bZva+LokRoyQGP4XBf8Vkdh68A+H//Ugavif0jasfhkrgAMB9vuswg00hX8IGHuA
#@EImuejQNLHiPSxj5x2n/86kbhec92jaQHf5b6a2HfvajL9gBMI3YLOVfkQ6vf5jxqaH4zn8v8L9z
#@UQ3+YfC/HjgN/0lsr57NkK8IGOBrVWs0RuQf8o4d5nvVAyLet4mzAJg+Kwii4D9Tcc30Z5n6v8G1
#@FrZtG2Iduzjyv20V6cLB42c+aAfAyDp679PPID28dWQq6rDQY5VYw38U/EsKgf/10G/4z2s78JkR
#@0F8/sBI30Bz+gRHmPW8Pbmi03sVca/h4j2tsG6iGfxKMHQifd8TC0v7bzwHgs0xW+G8vBF+/9fjp
#@O+wAGElvfPfFezTos91sIInhHwz/MB38AyHwv37chv/8tgMdOATXB0AhAppH/oHm44b5r3fEdI59
#@AuY8eN4RKdpqwjxa/QH+rmWwjefd8D/p2G++Mgzfet0j56+zA6CxHnjg0vWbVza/ibh+zKqZgOF/
#@GfC/RlHVgevhfz0sGv7nZbvi2YY5uvJHhxDNwQPaAwnkLEIGfs9Hz7jA+2tF0c3ZAgnMor2jzxO9
#@22ZY1lWPot/58Z7NL9oB0Fg/KD/5kjQcSw//7WX47xT+gTD43xoMDf992Q5s00hwtwCUQojmUUcg
#@NZAACe4CT5wFQOjnyZXfE0X+STB2YAbXXHznH4jcZ6qvs+HI/85VdP7A8XMn7QBoVvX/k+9E+lgv
#@iwm1E2D47xT+JYXB/woCDf9LtQ2xUVigs77n9fBZRGhWV//rPcAJ0HvbN+ZTaBHSpP0v/v43YgYR
#@6Dr7CJ8nDP87FpRvHHrs9J12ADRI/Ve5+jVJw9Ja8wCZNxDD/xYCwuAfVj/J8G/bq3UPAbYDMqsi
#@nQBF1ERnqgU5nbvgbDrvcdNF/gFXnZcE/T9zMIAb/ruc9xtLGb6pU6f22gFQoR/oJ5eKdGcvi4mk
#@Cxna2ga6gX+YDv4lTQ3/iaG/+Zob87eAvrwSRNmuOZjndwIUUREBztnRBAhIB54wCwDFiobzTKvK
#@7/GFFiE+8s8ci6qiyQVu9Wf4X+y8//ah7+/9tB0Au079f+bNFC6sJjQg+h8E/4DhP/qfpRZuRrYN
#@cwL/FYwPawB9HF3D9uo3l8gQRNmmYuzxQrTu8x8rQgtxdS8wFCSJ/G/zio0zONs43Nznf6qaKhDr
#@YKQS/oHF7nFF+tSBE6ffbgfAjnVpKGXzq1LZJ7RG8fAvw/9S4T/gUC51TP7XhmsUJyr+9k6jMxCz
#@vwHdgiCiKfwDMfsegbBMKydM1L+T8LtKi/pF9OLkc7X/7b5zaLlqMH6EHW2O/O/W9h40/Nvhk2du
#@tANgBzp67/9dlHirGJUZc6eMoUoZ/scGweZiPbAV0TPsJ1/v7ceZP0IhQVgBtG5VRNqCquBU5KkE
#@hoLWtiEe/lEjsexuKqhOYAA3/Hc977+5+fPh7+wA2KbufujZO9jQZ3JUag1K/UfVAsN/V/1pWTem
#@APhfBARPMh/pxw0SdJUe2eeiYZp9BfIV42JQqug9Yl7XLRo8c0Qvaf/pHYxA9981hAsI27bhv8p2
#@OX340bPvtwNgG7r6i8v/IrG/AvACFtN84V+S4T8I/mEN/OeBfn8wd+YQSDTuAEcAFdk0wSqrIURB
#@YNfvGnnAxJ0ORhIwi7R/1KnYzZnI3YNeSohQ5y5UjHukOgBF+Lu2fdtswtde9oGzB+0AuIbuuv/i
#@4xp4d6hnlpB1lxb+AcP/qPC/HsKKyBjlt7e8wvaaeQwfN0xrH+gE/lcieV0RaHrNZZYkhXBEMKFt
#@CID/hAJ6f9fi23Tjd82R/2jb5fbrrugrdgC8hF73tvMvF+ULuoYg9oHmvw9r+B8jKgeEpWEXkQX6
#@/cEcv8Vhuru4MKOq87SC/5VIvt6gnX2g8pkvLAuAgJRxEhRaRALCI/+AAhS3Rsk5BgyChn/Pu4p0
#@8uBj5z5sB8AW2nP9vksSt/bSioqE8A+G/36AZP04ioiGfm/cLUUWh0uAIyBLZw1awf9KNJ53wO/a
#@hEJ4j0toG+Ij/8wg9R2c9m/bhv8Utkt57hWPPXGrHQBa6eh9z7we6WxY9J+wtbcM+JcM/y9hG/LA
#@P+D7WmOJQEcMwe8bgeuwMjJbKsyssTNZNBii03EXlQUQX/md0efVrf7SpMC71d8UaxMR2k0ForOL
#@sFO7je1brmxe+Xs7AF6gzS8D+0I2UhQmBpYBQ2D430GBniIiov0G8MS2AQHh4wYJZtAGi1bwvxLt
#@n3mzsUPmOhPxQnifaWwbCIL/dNcAnGWjOgF+1xz5n8W8gz506NEzJ+wAkHTkvgsPM3A8R0Gq9SIh
#@/EO7QQCLhX9gEviHePgHBHjjHlsEOmwI8+nFQ3Dl31e0O5H4kAQBRXQDACtMSJCk1gL9769FpOiw
#@gFPfhXDav+Hfz7yRCvzT4ZNnbly2A+DkyY1h4EuaQECmxWT4zwf/4W2wipgq2u+Newa2AQERttdn
#@A9BJJWwq4L/CdvjYAyJy+bMA3M70V4Vw2n+FMp1fwXf+bdvwn8j2a8rzfHbRDoC7fvjrZ6XhmK4h
#@yAP/qIFoCZuG/17gH+LgHxDgjXtKEVi7geBaHKRqBbVetIV/Eo8d5ttWM0yMeGbpv6hpAPx3fQ3A
#@jo/2Y49vhSoJCM0uAgz/iWyXoicPnDj99kU6AF7zztO3FPQZL6bdC3znvw/4rzjw1IOhN+6F2Aai
#@6oqsHFz0WAyrfeSfvGNvfxWAyL09DNTy7zO0MEF45B/i5xxHv+sB2DWzuo78ozoBnvcXahg0fFWn
#@Tu1dnANg/54bPod0cNLoP4FrgbbACWmL3hn+fymGGPhHCLDXdnG2gx0/SBDWxrVO0PyZ4/U+pW1f
#@bUpqGwhP+wfUsaIcbY4CG/497yOqSPcc+v6+J5RAw5Rt/wZxaokH8zZKDP9g+JfEUHHgqQF/MZuN
#@G9j5b0BQ/ZtNFW5gcvvQ25UHRotQkLSLDcSn3tfXssl79x2SOLvQteRWfwGKedcM/7Zt+M857+Wz
#@N50499rFOAAK5VKR9k72AUVVItligma2Df8zgH+EELk27nrIb2+7/u/q8oMFCJjUPlNlA9D2jwdS
#@H1KAJGsuZeTd7UxHECIc/hn67/CA8HoLzfKpd54hQmt7gOF/hrZv2JD+cREOgDc88PSRDfQHGl+p
#@4B9IB/+A4b+hYFr4R4h+Nu4KyK+1PapjoJu7iYCASe1D5qgYu98jCF6aBO6xZG8tmePuO8zN4dMe
#@fIpwBLqzrLIa4XkPtQ1UwT+e91EE5fgtJ849MnsHwB6VzxdpzwQfTm8ghv9J4V9MCv/ZD0kVsN/t
#@vfuAtPuKFPqJ7EPGCDSNe93HXAWIT71v7+CuX2/4cPqrwmn/kgQYwHHav23HRf4Bz/tL2B4oX4os
#@CDhoZL3x3RfvEcMHenmgJCtOBG4Rs3T4R7wE/BuCs603Vr+U4wYmsw+ZDsZU3rmPX6oIH4xHFqLa
#@Psxj3hHh8A/9rzmE3zWP3Xf+/cy3sn3kwPf3np2tA2DzSvm8ioa1H0y3C6mA/96j/4b/NeCf6mO9
#@KrpnILmG2joDiGoVWQ9DEO3kIyAFO7cqpm0aRzfBVd+ZQfE34scNdJ/2D/6udZ+9iufd8J/TNuiv
#@b3vk/OHZOQCO3f/07woe7eWB0jAyVS/D/8LhP1URMkCA+/LWz2GacQMCJrEPAYfD0PB9/iwA8AFt
#@K4H3uHbrLR7+gcUDCcSeIelt3tsXAozNpmMw/Oe1ffPlvVf/ZnYOgAKfWzfl4IIpWwmajdvw30Aw
#@Dfwj0sA/IMAbN6pQpTOAYOCJ9B1SOwYiMsr6vwpADDBDE0dbigcFAdcIZ3rnH2YA4KIWwJ32b9th
#@kX887yPb5qOvePT8m2bjALjrwYtvk/RwL732melCBhSv/uFfmgT+M1W898ZdZ7s+Ck+As6fjdqZA
#@08g/oJZC+QTNikwaSDLaJh7+ge6fOXi9eexO+3eB9tFsb1wdNr88nwyATf2tJOb7QAOi/5HwD4b/
#@keAfEQ7/gAB/rIMBHIgcd4X9TNlNNO1BnVGImXbWiKr83n5+YR57HCIg8t9WgL9rhn/Dv+c9s+0H
#@Dz525oOaUMNo0X/0rilAEJAk9yntJvXf8L+jwxWjQ6fbtCSzDQgRXeQx6k5qlWAIcOz2fRUAmnWY
#@MJA0tg0sIO1/vcDfFiDyPa+3r1j7GgL3WyTA8G/b657bF1/3yPnrunYAlM3yiQW2AAs4GPeY+m/4
#@lyREGPwDLowUYLtijUSMfXonAKoUIb2/6035gNYa9oDqsSPmUWiRePiH/oEEas3iyL9t71pQBf/u
#@2tSBbaQ7frz36ke7dQDc/dCzdwzwWC9FcohdTPnhHwz/zeE/Br4BgXsSV9iOdAQEFH+bxgkA7dP+
#@gcpnvpCrALTd5gEDSWPbQPi4ETXfQt9Ddtq/bcdG/l0nrRvb/NWtD1/c36UD4MqVy08VaY/T9MLG
#@bfg3/G8F/t6442znzwqgYv3UitqthsbtvxZyFYC4m17x3S0WVmuBFGn/VQJ/Wwz/tt1r2j/gZ749
#@3Xblup+d684BcMdDn7wJ9BGtEeRYTCRaTNDGNuCPRhz814MbzcHfH8wstuOhL3UrKtAuRAMIDHIC
#@zHS9A9W2YT7vOvS8x7X7FiIW+m1p2k++1skXaz86wwjDv89xHdhGz950/PQtXTkAbrhy9ZwKL1/S
#@AwVmupBJ2/8b6A7+tyXiwD9/lk2LX8C4E2cDxF8vqt0rCKgAnrPlHaKJbXA0MqNtIHzciMpvYf/P
#@HAxDCx57dRAHMPzb9nZ0895heLIfB8BbTu0tlNNB7fbaiy57MRv+Fwz/QJ+VuNeDezPBFj+tfizJ
#@EUDAOmsGoWi98hchg3kekoCgyu/tnztiHodTYiL/Uh4ABwwkHnu3tqEO/gHPeye2Czx16wc+/oou
#@HAB37b/pI6Xwyl5645I0JTYe/mX47xP+I557PYAPEiiVUJ9OAUTKNdc+BTx+rQNjZj2EthQFA0lr
#@27CEtP/1QgZww79t9xr5x/M+kW0kdOPlqxuf6MIBAJtP+IHO4X4gClCf8B8PYvXRWKYE/p3YtlNg
#@NEcAaqVRa0xA2z+eAUmZx14vRKKaKlTbBlWLgcBCi/Nab4itv4Vubblt24jQ4pagWPuqE2D4Fy+y
#@7Y4mM4N/SRJw9sAHz78qtQPg2INPv7fAPVojyAGCzGwhA+ngHxYL/xXjjk3Dbg/8FbbTK78zADFZ
#@e8ltichNMridH30VvQNHIyuUt8sCAZH/mQUTwMGrrsdOrSkM/478jwv/K12vq5ufTu0AKJs66we6
#@c8E8xw1N7Rv+k1/3gNWv3nb/zgASZgPEV36v3UtoCGK0Hneq1HtEotR3VCuof+6AD6fKAf/IAG74
#@X65twPBv22vgfyXEnx34vTOvTukAOHrvk7cD7+ul4j5JK2HH3/0ma5cFw3/rfuy0hf72tp0dEBKl
#@z5qaCakLyQKzPKiAgaSupkt7AeHwj3Dav2177EGRf/AzXwT8r7R3KBtPpXQADMPwF0Xaa6/tzgTz
#@HDcY/seC/yaiJfQb/ncwb3GioltA7TqlEXiwjIMxqImANOMGIrLKfNWjzfz4zv8ItZsQofU1QFUC
#@DIKdpv0Dnvcu4H+lQjn1shOnDmVzACDxp708UILSd/JX4cbwnxT+gaZrrh76Df81Ld8g/C7wJE4A
#@oBn819/zDMgCwH3Ps40dcItFBcB/RgAHA0mgfVQnBgz/EULC8B8xoTdct7HvXCoHwJH7LrynwB2u
#@HrkzMWRayLjWQmL4byZqotaG/12J4KwAYttxIdqDB3m/K0Cq1HuEgaSxEL7z30DIAO53LdA21dl0
#@Lvi3SwF+13bhTSlF5w+fPHNjGgfAMHBK2xB485z7SwTt7ANqJ8O/2A34G/6rREWGxej2J7wSINqD
#@B9nftXpBgO3s3Xvo99uyUpL9lbp3EOE7/4Z/296lABf8M/zvUBy4+vzw5ykcAL/1yF8eLuJRrVOS
#@onskabcHmRYys4d/6Av+AQFhICoZ/qPGDRJMbj/CCVD/HpJwvZGvzSDCQNJYCEf+DSQCVQlRNW7A
#@MLbQtH/wvC8M/iVJDFzUyUv7wh0AP//pLx5HXKc1Ai+m1raBROM2/LeE/6ZiJ9Bp+M8x7oBCi0mc
#@AEWk6aYSfzDP1VYTprlu4fNEwB3oIPhHVAK4U5FrBLHFPTGEhkX+Ac97T/C/+t+rDl753z8KdwAg
#@Pd7LAyVJuz2IGvwE0f96M4b/lmK7kGn4z3xAg1b2468EINrCPwHXqjo8qCAc+ddKgFssbqEiHIG2
#@7W7GDhj+vd6XAv8rbZZndenSEOYAOPLgM/cLjkz0sfZi0krALD8agOF/0uJzhv9exg2T2p/cCVBE
#@gAu7j8MpZG59ttzq64j+9xmc9m/bCx47hv/djh2vt6nhfyV05NB//8+jYQ6AQeVPKqqvV6jfdnuQ
#@ady5DqfAIgv+AZONfQX+hv/Oxr3++ZG2Svc0af8s0MFK4PNEktxFJ9o24Dv/wbbB8L8NObPKkf8X
#@CDD87xj+VyrDcC7GAfDApT2llBParnDPylYCeoH/MDH0A//NRQX4Z1zv2/2PXf+6O6RAbSQ23gmA
#@aAD/wTVWqPh3Or73jltRNRO44B8iFMCB0P0dEbrHgOE/yjbgtH/D/47gf6Xy0KHHnrhzcgfAUX7y
#@XsShgMJMHXvqnS72UgIM/+PB/zRiFNCfwnaFYyAexBgC+5639z37atN2RPSzdEZdxXymO5xCnW3A
#@ULA9uXDzFsIF/yrOzl7vi4P/ldBG+VjAKaz8YS9peoRX3M8WlUItBIb/zPAPAfBfAfuj2653DKQ9
#@oEF/ToAiKtpgxXZaiS9q6ms2roTd4HvitP//Z+/sei05rjL8PvvMjL/Gzngc2xEJzhAFy2YcsOWQ
#@CDSSx0aQ2AoZBBqIBJbgxhJSkIkcIXE3PwCJH8Ad3CBxzw/hmj8AF0iM8YfwzF5IDlLNOeq9q7tX
#@dVdV7/VulXzkOeesU9XV3fWstWpV2N5A34Eo+DdTQMz37uA/ycz+4sXf+/lT6zkA3vzgMmPO/icq
#@MsdLY0UR8N9otkkG9ntKvSe1HXKoR4dPsetnosC9VsEJsJFCtgh5RdRaKCZw2Q74D9vRd4+Ign9x
#@r/UF/0lc++LJL36ymgPg5jNX35Xp2ai4P942azhDUFKN6D91q0FD0UJjXcI/tAP/pM9WXxqOOgJ9
#@F6QCiu83pjSQsNU5F5H/RwVxxOJ00VwUFuG0XzUS6rcv4mSNTm0jThb+iflWDf7Tz9hPV3MAPNzv
#@/qSX8+6Jh9ejCvgfKUSP8L+ucED/Rs8jBiruh13BEYRvPpvwFMOqJmBzGW0IeUVUo+4wDRoNCSIC
#@fcq2IcY9Iv9huyv4T+Zef+7Oh99f3AFw8+bdK7udvbdS6mUcEZPGwt/vtqIUAf8bgX/SJ14ayzkD
#@6hcIwjevTcy//6g8V5CAZuYcaDMCYnEqCSLtP4BkGUWx7rbhHzjZ+Q4E/M+H/6Sd/eXiDoCHz730
#@IxnXTuUmBuLhpSRQR/thtw//UAn+E/jHAs3hDFjHvvzCN7+tZo4hW9lSdmJZALRbCds/lrHnPwA8
#@xv1R20Tkf7Yg5vvJwn/ST75296+eX9QBgPTHvRQho4HJBK2kJ7JR7+Epw3+dcUcIES8NhzNgbfuw
#@MDdAUfhHNLkwBio5lk8sCwCtLsBpu3/4p3IUGOG0XzcaCQH/Q4qM4Uj7D/hfCP6THvvfB7zvcADk
#@0//Z6b1TOZoHiJtogRRFIOC/M/hHCBAiXhprOwIod//CugUuTbjGqJgiQlJBnWa6dHzZgYj8d2wb
#@Edtma9nmdOEfYvtm1/CftJwD4OFz37gt8XQ8QNazDcTLOmP7lKr9gwQrg7+I+3whAavvgYYifV8l
#@7R+hYqL0lof6mV3QyDaAuNedYxlp/2G7vn2IcZ8rRET+A/7rwH/S68/e+el3FnEAmM7e7eWC0sBk
#@glYmMvIK2ioUA0XTjXuB/1WFiJeGQ25HABXOHS9U28NE7IeNyP8ksaP3glQB/3GvTbAdNbNiz/82
#@+k7Af3X4N/1Cu93Zny7iADhj/4M1qt4DcSxQVIkN+K8E/4iAf1RFgIBV7MNCfacU/FfIAmDd+xyo
#@lPpevj80UWMjnC6AC/6h7vZNhNN+vFsuKgJ37cM/EGupgP/58J++/jPdvXtW1AFw89aHL4ndKzGZ
#@KhVGot4fDZH2v3n4T+AfLw3kUF9HzkHZvlsREKvkBECTBMR8j7439ydZRP5dtgF5BDHuEfmPtP8p
#@toGAfy/8p2/++nMPvv5WUQfA/uzSjyTRxWRq4CaCWKA9KqCIbSgH/4iA/wT+sVBo7F4DBGhpQRkn
#@n3megVTeX03fqe9QZr71f8qC/5oD9eoABPwHDIkY95kCThb+Ie61gP9fyLD3izoAkH4oHAsRr4gj
#@iWoMGrtmb+L68J/UM/x3++CGKa1fRxsgoOn5Zr2l41LGPhCLpFon07Y55wL+A/6r2gZi3OfaJiL/
#@Ybtj+E9f/tEv/f4HT2qkLumYbt+7JD5+Kx5e4wQR+X9UQBHb0Cb8A93BP6L5BzesCAZIZm3fa4DM
#@bFHbpHFwwv/I38n0eWuyjS1U/Nc2jXOk/Qf8H5gMlJpLM59VxH3euv107WPcp8p6uOb5ezauef/w
#@L0lPf3bp8R9L+md3BsCvcf8tiWd6uKDEIuX/RUsQWh/+kwL+RYNp0JmI/QrzDSr9DThOC6h8FJRV
#@eEQhtuDgrCdcffGL7RfDwmmIiPy7BG4YiiDOTAEnC/+EczXgvyr8JwHvF8kA2NvZuzssHl519oR2
#@Pe5AUwX/ECcL/4juFmj1YUTnZLaE/UreenxRIJscVYrj7k5hgYYk67nv6f6KtP+Y7/OzceI5M//5
#@EZH/7q45SBbwXx/+k373mbs/u37/X/7+v1wZADvtf7BG6jvQ/8OL8BiXtg0B/1uAf0it3+09qfV9
#@rKbvWWaeZyOl53N9AU1E36FMReb+90HHnv9YT/RrG0VtkVOEfyDGPeDfB/9Jl8/2+/dcWwDeePdv
#@nxfc7OGCEhO52ACC3AK2ddRfUsC/G5j7v9cgtRXt+7cE4ANKa6SoKCIi/83ZjiMWSwnvu3CHPIKY
#@73GMbH/jDkTkf5xiK90m4T8JszsuB8Dnn35+a8BMHMe03MMrHiADixATzex7BwL+R8HxqSzQ6p82
#@AKzSd4viawcFFIq+9x/9pvt73X8tgFOO/PvHTwT8R98j7X9C3yGuecD/o+KHN/783uOzHQC2O7ul
#@EYKYTNBCv2mi+jrQceS/f/hHCFEJgk95oZAZAyoAqNM2jIB/s+NN6WvS1+6GJdvNNvVnG6n7vsP2
#@rrmdn+8BoQFDi9iHEwZBIvIf8N83/Cdx9b8/vv/O7CKAO9lvSzQffWcTLyziJlYSlIF/xKnB/6rX
#@HOKFdRSczW3fX7wMbxVD5v8smaKAW1Ea/ziOKdn3jmUsTo85ws2OVVBz3LMRfQdkZhH5z4mDYxeR
#@/576nq5bwH838J+3g+3vSPrXyRkAt2/fe9xMb8S+oS17jCtF/1FGjcB/UsD/BUHA/+hx2mlpHY7e
#@Kn3tAQ9gge09fiFiz/8FsavfdwKG+k37NxvT4vl+xDbEfD9F+CfGPeC/BfhPuqN793aTHQD/efbJ
#@bwKPxWTqJWWK7Yw7VLBd4VzgDuEfJIiXxmiRGbcyC/JFjjM1sWBhz20WBAQ2Md/ZQBQY6hayBeQR
#@XviHJdc12S0PQADJTCFOt+8R+Y+1VMC/B/6T0IvX/+3+96bXANjbyP3/EX332gY20XegmT3/iCbh
#@H3qG/3hplMiygUmwP3tbFVA06miSBDLpeEMy5ZuQTBtrBfokcNsWtfvubwKf7Yj8L68Fn2WIeLfM
#@tA8ECHYI/0C3407Af0vwn8zy8M50B4DZb3URfXdHCYiXRjEw9cM/NDXuAf+SIOC/tH0YXCQvVlvE
#@JrS9mA9TOJxKDiHiqL/G+k6Me5zzn3EKLGkbouDfKdoGIvIftgP+07tkhgMAfT8mU8GXDJt0zzVZ
#@7R9RpN/AScM/SBD3+VJRMWQCOZWPhAqKggcccClgkjbfsn0HuX8faKLt8g1U034J28t+WOb37qW5
#@tnt4xvodAmgVAScL/xCR/4D/gP+u4T/p1Wt/+NE3R58C8PLtj16ReCEm0/K2gRaikW4BbviHiPy3
#@A/9xnxexb6acYNy3mjPDx8xG3Ie2RsX78qcCICFkZvFucYyrz/7KlalxzC2vfRw/P8EBhySbYNs0
#@dDKAlX2/oILKPC/p892S5l6sn7uDf5DMvLb7n3NUOUUn4L8Y/Ced7R68JekfRzkALku3bIUjwIB4
#@eLlFRP6VhCgEwJxkwT+Ie81t38wFwqYZwlwwYmLuCzsiJA7w23oqMpIs3undpf2bbPgEUFbddnPe
#@+I54t1TQKR1naiKueUT+NwL/SWa8kxwAmS0Ae+nNHi4o/uh7vDQKCHDDP6iEmoN/CPgvJeBw2yEY
#@3wrLddyepZYZQxtuWJlFj81oKpTJXcg+a1a/07K/H+G07W+ImvZPxrYZK9ou83y34c9yRXTNUjsB
#@GEIECAb8h+2A//nwn/TO6BoAwHdiMuUFPttA9b5D75H/JISEvAr4r3uvTYd2ytiYJZu6os6vxUGC
#@kat2pvkLEIfAY7owQTkqAcf+b3fr17Z/TGPca9o2yW17mmY4C9Bo2cCn6Ds91Q6IyP9GbdMx/NPz
#@uO8I+N8Q/Cfxy8/f/dm3R20BMNmriHh4NW+bTaT9QzvjDpxU2j90nnHBYpksh1MYzSbO9zGyefv5
#@TBNlAsnMZJ4EbYqlezrsV0m/L7//O/87Ngsk/q0mK9UBkHn//oXT/s3zkMgbNO873+ad2sGELQJQ
#@9tojyVRPFLlvHH2PyL9DMe4B/63AvyTp4Z63Jf37UQfAzVsfvmTiekym8BiPEeCA/3ICmhp3CPhf
#@/Hqx3ty2oYgTHja38fCyH9N30ySxm78yZjnoBsksnu8Z230BuCTrfdyt1p7/6eb9FGwj+k7+0YPT
#@IcDMegFFT++JwqLd2U7XrR78++dcXPOA/zLwn/S2pH84vgXg8tnrPaS/U/msUOgf/qF+2j+oGQEB
#@/8sXB6oA//5jqrj4t5PJrM3865T0XFDScDrwLPAAqoy7mc1vGvV9DjsO2wMtzSFn0/yfRTXth+2h
#@ZqYjNts/xSa/FWHaI8rSJ9n2PbMjiOO0DRH5DwCfJgL+m4P/JPsdSeRqAPxGTOQ14Bv5RPW+Aw74
#@LyegJvxXUFfwX774HquB/+H+CB/05xfKw3u5KbLomQfKKgPdOUG8Wx4VO2JxejrV/ms4PRx9zzsG
#@gEkOAcNRO8DrCEBFBTHfA/5j3AP+q8F/Enrh+t2PXj3qADDxWkym8BiXjvxvUiybVYHoGf4d0O+y
#@veKiEUnkoH8a8Kc2mLUP8yPse9MghAMlr3krz7hmHE7maTh/vhH7ctoWVAUxoOWj/vzKZz2UugOO
#@/2+GtwqYzNu3WMetbBvoF/7jiPKA/23B/5di//DtXAbAazGZptqOKPCcBQ80E/0P+B8rHODvFTXA
#@P4/2CCFloD8L/FNSMydH2E04x91WbbCdyu+g6lXnwWcfVHvc1/tQ/ncKyaQ1r3npZ2wmg8DvEMg+
#@QtPH84zvah2HiPVzRP4nCQL+A/6H/9cefe+gA+DmzbtXxO7brae/UzkyBF4QYwtpqRH5P6eAf0BA
#@b2M+Hvwz/4IQYjT0j9Rg6j1MXvTkIDUDJHOeb3HCRCnbQDjVu7Xtj/zji7wv3XePU2D4OWPjnAFj
#@BIN/a0T+A/5j3BuzDQT8F4f/JMR3DzoA9i/eeE1mV5QRxEQWqih6TfvvP/pPhYyxTuB/MbFu1D8P
#@/pba4FoWYcxdiF/cdz/uuubPGM8yAsKRt126mSAKz0XfH20q3VaZ72ZIVnmrB5nz+ZFDTqfA8HNs
#@6ayANN82DIJAt+tnOoZ/glsi8t8S/Ce98tUf/83Tgw4A2z/89ZhM29/zD7HnP6kt+Ed0Bf9Ad/Dv
#@B//8D6S7wKYBfz4yNZjafV4JPI4BtuxIJgBV0t5TQ8UExH7YQve6NL+R+x4yPw8dR/5zjoc6zcx0
#@8GOpQXmnQH7cLbWRWQGTxLgMMCDWsBH5P5lxBwL+twb/SbuHV754fdABsGP3cjxAKtjuDIABJ/x3
#@GP1HDm0P/gEBvd1rq4C/ZBeuKUehf1Aco4YcNFh2v/GAmiw8J+LdUkrgtt9irQV/HQQWcWo59vwv
#@3gYgeKAlHXMUON6147cLDD/7HFsDGHRMxHMm4D/GPeB/g/CfhO2+eyADwG5sG4L9e0KhMrhC99X+
#@QX2JCn1pHP4XFxWi/lm6z+7tP/zTloX+9I2Mgv202OUieDAa19LflDICKHR2PVKRFHBbq2lpGzrc
#@NGJohPOS1I1C17ft9Wn49vwDrayjpjgfsuNk6eMF8NTyDqiZjoB8ocPSgn5hDDqGUHYB/wH/Af/n
#@hMDeHHQA6Ew3lFNlAIaI/HsEkfbf4nVHBPwn201E/QeULehnqSXbdqBIoHQg9X3GIhvJJO1FAvup
#@539T/joDTWyxAarf56C6UWBv1Xv/p75tS23OR5ZvZlqkzgIlay1Q6iDLcU6Bc2K6wxahC5riCJhj
#@O2AsIv/V+g7ENQ/4Lw7/kmRiOANgJ73kjIAHBG6874AD/jtL/8cB2huDf6Ax+Pcv5GxO1D8f7c9G
#@sjiU0qrcAjoTNRu/eF0TQmNxuqF6MkCMu9cRTmXvP9Myc45orFPgosNnfs0Aab4jANMkmcVzJuA/
#@xn2iCPhvEv6T7OVrf/DX1847AN784LKMrwUER7+XjPxDXPfebANN95uhjx2pqbAs+I9KXb1Ycd+Y
#@DPxD92Fun3LG8ZA5FWBmgXhJ7mgoKrIloftq/0jOMajbd5y2kaqecmBH2t5Ue5tJ+eKaufHOOwWy
#@Ds6RcjgCUja4w2a1dzqi5+OiA/7DdsB/C/CfxKUruzfOOQBeuXb1V0w6Cwg+3O/+9//3n/YPrJQO
#@XCn6j6df24V/Dn9yqaPpc6EiedLi4D+wNs5EpvKL7YPFxiBT9Tu1XAr2cGmzGc0i/VwmkxynLLRT
#@dE8dA4lcApqO/OfrTNjRdkwwyuC4uiaWdwb4HQEFTwwwCxg7tcg/xLgH/G8N/iWkvXj9nAPgTPat
#@rcM/cNKRf/D1HYg9/18q4L+oyAJ/mb3+A2ZJ2xsKgv/4xS4gxEjYv9gkMwYAf2S9bvJmkIqcxY5w
#@F39DhXcjWJ1m3iC2fE3II591unB6dFztP2//oPIOgnleCGY/H/2OANKXSa5sgICxSPtvftwh4D/g
#@n8NdNPvVcw6A/YPdt1qHYIi0/54j/9C4E4hV+xHwL0kMQ/9EzdnrP2wfBDjBf2y6a1okZ4oDDq6r
#@96aDgA9Dv8oy8O04/qwTECR1vNPmT383q9QasS1H8xb8Q/La9J6y4Mn0mF4nAF3s+1RnwHwwZ3R9
#@gGnrBrOuABzoFgQJ+I/If8B/OfhP/Xj5fA2AHTeWvqBARIA3AP+1BGzmuiNizz9Z6PfD/zFI53C6
#@PyBgKvjnF7AJCoburCPAn+lXAvwLEfPx8D1BM/cnyw+x8rfaQtR5DlJvK1vVxx0LJH5USvtnag+w
#@Y5CdcSpktvKkfxm+V8kA+zhnwDlrox0B5J7R7myAAMGI/Mc1X8A2EPC/EPwnJQfAJUlCupEzAAHA
#@vaY/QBz1V+K6Q1tzDjqCf78dP/xf7Hui+8HvBCSz/O+zTDTJBmzLBr4FmexoT8zQo3ri8Su6+uQT
#@X/73iSce0xOPPabLl850ttsN/t3mGGuvTCa3zDnfTV5VHocKQ+iZCyxh32HbKo9fs1eeoz/z+RcP
#@9ODBQ33y2ef6n08/0/1PP9XHn3ymvZlsYDGNWf5FdfB77Pz5pumXjjnMX7JDNi39rA05h2zaljMI
#@EAz4P8hcFtc8Iv8twX/SN158/+dP/cc//d0nl/Sl7JsSUfDvgGDD2Q84qif1nv6PVhfihODfb8MP
#@/zb0Zs5/t9ng3262HwP+mbTUi99i5+aHaX/xf+srTz+lF776rJ5/7pqev35N169d1Veevqorly8p
#@FPo/9s69N47zusPPb3a55PJOiTdJJCWRtESJ1P1KqbZl2Y5sKRe7jtMmQNsUbdMAAQr0v36joh+h
#@CIr+kaItUqBpc2/SNGjsJrZjJ7GRiy4WT6GF4QFHM5pdLcndpX4P8Frr9e6+3hE58z7nnPeMMTvN
#@h/fv896vPuDnv3yft9/7FT95++e8+c67/Pb2HQIAAaCIzSc8qclgQJAi0rdHycI6d67i4ILaDQKU
#@J88ielPGJIiw/DvospPyH5b/7ZD/FN39LUvAN6sABPtI2LVIctl/G5l/0Vkk+eTZw2X/kgC2Xf6j
#@7BmVZ/2LPz9t3Bcb0Zr4E6BC6U+J9PnJiTEOzs0yv2+K/bN7GR6s2ziMMV1DtVJhZu9EY6wtw0c0
#@AgL//cZPaYw33+LuvXub1TtX9svkPYAoDgSIfCJarQZIm7SiZoMAXk9Y/nfN3JKIiM5l/sPyvz3y
#@n6IkjnwcAAgxKboXyXv+W8dl/4UCqs78DAqBaBupw/LfefFvXf4pkf8S8QcezhhFqfhnvD435dQg
#@ScTC3DRHDs9zaGGWseEhG4YxpueYmhhrjPWTx7h/f4MfvvlTvvmDH/PdH/+E23fu5lcHAEjNBQKy
#@FQFJQDx6q4GAoLAaoM0tAQHIEtpN8p+KrI+7y/4t/5sQEkcAquuv/3X9/fdUtwD7u+edbCX5731r
#@sPy3R1vynxKZR83LfxAPLzA2Noo/PwBlxT8gnauR3V87cqgh/vV6v+3BGLNrqFQSVg7OPRiNLQPf
#@+dH/8vXv/JD/+b+fERHpOqNQ+Clo7pe+NgIkSB+0XA3w+EEAlX12+wgRhOXfmX/Lv+V/S94TwVMA
#@1Xfe1mR/lW1FkiWwYw0AO5D579b+CWrvO3T+e/SU/Heg7D/Ipf2sf15H/6LeAOlHKgBl30N/rcrq
#@0cOcPLbE1J4x2qGSJAzVa43PrPVV6e+rUq1WSBLZPowxW0GjAeCH9ze4c/dDfnfnLr+7fY879z5s
#@ecvAqSOLD0ajd8A//+f3+Lfv/YC79z7MqwoorwgQQGxqjiqKqwHKewMU9wXIRbkBBovgw1l4y//j
#@leFb/i3/2/WeIwDVWrUyBeHs9zYhyWX/HUTSrjl5SrSOOnCse1z+y8U/myECSWxsxKbMVPb1Y8OD
#@nDlxhFPHFqnV+miFJBF7RocYH6kz9mAM1xmu9zPQ32c7McbsNA1x/+A3t/ng17d57/3f8Iv3f9P4
#@92aEb+/4KJ969hLPXzrNv37r+/zTf3yX396+TXrq1aMDAQIQKZn+AK1UA7TeF6Cs54Dl35l/z235
#@7z75T1kAqCbJxlRsqEw8drP8+7v7Vn/bh0Bdtj9Q0pMk/+Ul/+Xl/ul7suL/8dOBBBECBelro7Gf
#@//L5VdaOHG46M59ITE4MM7t39MGfD+TfWX1jTLfQqDiaHB9ujMW5yY+CAvd55xcf8NZ7H/Czdz/g
#@d7fv8igGB/q5fuEUV08d52vf+A5f+/dvc+fDe0A8HAgg03AvSJ/L9gdothpAzfQFSDOyQSCpmcaA
#@FkHLv+e2/HeX/KdMA6pGMMlmnAF2wz/L/5bebq99JMt/G/K/pVl/iE3in3/bpGCoPsD6+dVGqX8l
#@SZraL7t/coz52YmG+FerFVuGMaaHggIV5mYmGgPg3V/9mjfe+iVvvP1Lbt+5RxH9tT5euHSa9RMr
#@fPXr3+Dr3/ovNiJAQWQ7r6aPs4GAomqA9rYEiBRBEIgOBAHUVjm55b9VJIiw/LeIgLD8d7P8g6iN
#@feFvxpPkPpMW4N2J1J78S+r0/v+eP3kK0R4u+29a/mOL5T8i854AIn06v1dAQ+QvnD7Gn33+FmdW
#@nyqV/6mJYS6dOMxnrp1i/dTig8Wz5d8Y0+s0qgPOrMzzyWdOcOXUYiOwKVHI0OAAr1xb568+/xkW
#@D8xAQCr4heflgvN/wKZ/BoWUXxvK+wJkiXAW2Jl/z2357zb5b1C9c28mua/YSxcjPcHyL/Vu5l90
#@FoGkXXHylLZmbkm7W/7VivwHEJtK/oMoLPeHSJ/OvJeAUBAEc/um+eLrL3Ht8qlGVquIaiVheWGa
#@l6+u8tyFoxzct+fBczYGY8yuI5Eagc1nzj3FS1dWOXxg8pFbmmYnJ/iL127y6vV1an3V7Hm6OBAQ
#@ZJ/LvLTlIEDmYctBAItgG/IvJw4t/5b/LZd/APVptkqivYSjWF2YHbX8u+keYPkHCFKkHPlP8uVf
#@QGzEY5f8R2G5f7ogRVDr62tI/6njS6X7Zo8enGZpfurBY5uBMeaJYmRogAurB1lb3s/3f/wWP3rz
#@52xsBFkEXFpbYXl+P3/31a/xk5+9A5Etw8+W8QcNoqA3QIAUQAt9AVTUHLD57QCSiPD62Zn/ndy9
#@YPm3/Bc/vXF/YybhPns73ADNEmr535XHXYh2kVz2j0Afj6LMfxRm/pV5v9RCyX9RuX8q/8ztm+SL
#@r994pPz3VSusLu/n1tNrrCzuo6+vSoCHh4fHkzgadzA5vTLPy1fXOLR/LxK57B0b5cuv3eTGlXNU
#@kgpEedUW8MhqAAggyq9D2rJKAMu/5d+Zf8t/h+U/RUpmqqponHDmPw/J8v+4c6sTkqlN73fAZxuO
#@haQd3/0SJWX/WaKZPZ1KHzeb9c8GDZSIq+dWuXz2OJIKj9fS3CTHl/fT74y/McZsYrBe48LaoUZV
#@1De+/0bjdoJZEonnzp1k5eAcf/v3/8jbv3g/PR8rABAqqAbIirzSRH/hRSQgEZtpvxIAqfcSGYII
#@y7/l3/Lf+/KfskHMJLHBgOXfmf82RC87t/fdbxHSk5H5TwU8zdSX5Giyi7qW5D8IgHQ+Aqk1+a/X
#@a3zu5jOsn1tFUmEDrBfXj3Hm2ILl3xhjKGbP2BDXL65w9thCYT+UfZN7+Mrrn+bY4fnCczOQW8kl
#@lTZzTREQUXK7WG+btfwXI8u/5b/r5D9F0kyCogbFSL128nIWGEBy2X8n5xbqiu8tqRfkPxX/QqJc
#@/kub/RWX/AcBCgREpO/JKzedmRznj1+7wcLcLHlUqxXOrCxw7fxRxobqrvX18PDwKB8IWJqb4sXL
#@xxsB1KJbBv7JrRe4dvbEo87TLTUIhCi6rpYEAVreCmD5d+bf8p+LAFAiy/82yz+ICE0lQv2OXHbh
#@/JL3/D/BP3NSB+S/A4hAaqXjf6vyT7H8ZxduARBIBZmlCBb2T/GHn77O6PBgwX7VIV68dIzl+Skk
#@Z/WMMaZVhgf7GwHU00fnc+8WIImXr17gCzeeo6+aFDR2zWbxAygJAogmCTK0HwQQhQhZ/mkdSZZ/
#@Z/4t/3mBFqgnRNQsYi77fyzU4VJzbY/4Sv5534lAggTQovzTovxHS/K/+RBrczbp6PICn711jVqt
#@L/cYrS7tb9zSb3iw3yt4Y4xpAwmeWpjm+YvHGB2uk8epI4t86dWbjNTrzZ7zi4MAhXJeuB2gnaaA
#@zvw782/5t/x3RP4bRAwkiBq5eA90Z0rAe1/+9aQ33UOW/2LScv+IrZF/oHhh1or8ZxeP6f/n6bWn
#@+NQL61QqSe6t/Z4+s8zxxX3IaX9jjNkyxkfqPH9xhQPT4+SxMDvNVz73KfaMDJdVfRVfbBSZUEAu
#@rQQBnDyz/Pes/Euy/O9O+U8RA4lCfc78O/MPKZJ83Ds4t9T23F0rolLLt0Uql/+IduS/tHz06sU1
#@Xnz6HJJyF6cvXj7GzN5Rr9SNMWYbqFYS1k8usXJ4ljwmRkf481dvMjE8DJkeLqV9AZS7HaDsmtp+
#@ECDC8m/5d+bf8r+j8p+igSQS+i1iln8fd8+dRdL2y3959r91+Ydy+Q8g4tHyD1y5sMaVc2vkMTUx
#@0tinOjhQ8wrdGGO2EQlOLB/g0onDVJIkp//KCF/+7K3Gn2WB3Y9RQJDTE6BkO0B5EKAcARG7fj0h
#@yfJv+bf8d5X8A4qBJCJqlqGHkXr4u8vy36nsu1DHv7ek7pV/aE3+Vfza4gVamfxn5ijIEp1eXS6S
#@/0Y56tNnl+mrVrwyN8aYHWJhdg/Pnj9Cf62aU5E1zJd+/yZ7x4Yp3tqVCf5SEAQAoL0gQBDl1/QI
#@Z/4t/2QRsvxb/tuX/2IGEkGNQtqWIUvojs/9ZMu/pB6Plu++aLVESkRr8p/afon8R1vyn3390aV5
#@nv+9c+SxODfJ+slFKkni1bgxxuwY6d1Wnj1XHAT4y9c+ycTocPH5XtnrQxuVACUEbvhn+Xfm3/Lf
#@RfIvEAwkEdSc+bf8d48Ayz9zmbl7OfuvljMdxfLPNsl/tsvzwtwMN6+v5x6Ho4dmOHfsoJv9GWNM
#@BxkbrnPt3FEG+vty/tsQf/qZG9T7axBAlGwPK6sEiNiapoAinwi2E0mWf8u/5d/yD6JBwECSSH2W
#@/y6bX+pZ+Zf33fuCVVL2X5L9L5T/2E75/4jpyXFeufF7VCpJbub/5FMHgPDw8PDw6PAYHe7n2rmn
#@qOcEAWYmxvmjl6+TVJL0PK+gQexEEMDd/i3/ln/Lf5fJf0o9Cag4E+rMvysu2p9baGuEWXQMSdsj
#@/xHk0Jr8wzbKfzBQr/HKS89Q6+vL3fN/dmXeaTdjjOkiRoYGuHb+CPWcZqxLCwd49dqVjJS3EQTI
#@t/ryIICauiuA5b/bvrvkBJLlf3fJf0o1cSbU8u/j3j0Cjjoo72JHiTz5T2nldn9tyz8St55bZ3R4
#@MLfb/6UTh1z2b4wxXcjwYD/PFDRlvbh6lOfOnwICiPaCANnrCdFcUBtQc0EAy78rOC3/lv9tlP+U
#@BIqRLP+Pg1DPyr+k3j3ukk/cHZm79ex/5M7f3L5/SR8PGgMkbRoAQkgqlf8Arp5f4/DCvtz7/F89
#@7YZ/xhjTzYwODbB+8jCJRJYbVy6wtnQIoK0gQEo0J+/K7Qfgsn+vpSz/lv+Oyj+IxL9Ezvz7uHvu
#@rQpcSbRIgEpqAzLSn5uNSZ8gMpUCkhCAyJX/A7OTXD67SpZaX5UrpxZ9qz9jjOkBZvaOcvbYPFkE
#@fPaFZ5gYHSkJAmQJspVnEU1m8LXp85snwvLvdZzl3/K/rfIPkPiXyPLfLcddifx3vrvmLs/+i5TI
#@f51IKZH//JkiCIAIBEgCggD6a1VuPX8FSUCKJC6fPMxQvd+ramOM6REOH5hk5dAsWer9NT7/iWtU
#@EpUHAaK4Ai17/SmXkSBDM1sBLP8fIa+lLP+W/y2Xf4Cka7OR8i/xY71IDrr04txSB5r3CaCD2X8F
#@UFz6LwnxMBHFT0QEWflP/xTZ/9lnL59hbGSILMcXZ5neM+I+2x4eHh49NlaX97N/epwsh/bPcP3i
#@GYAWgwCCiCb7AQS5hMv+vYZ8MuRflv+ul/8AEv8SOfPv494+Qr5otJL91+NEEyLvcan8R2YzZhAA
#@zO+b5tTxZbJMjg+zcnjWqTRjjOlBJLiwepCheo0sL1w4w9KBfRTbRUGjWFR+LVLZrQFbqgKw/Hst
#@5cy/5X9b5B8g8S+R5d/HHST/vLWD1Kr8F2f/kbKf0ey+//w5A7LyX5G48exFslSrFS6sHXTHf2OM
#@6WH6GufyQ7nbu/7gE9eo12r5mfugOAgQFPcDUOZBhO/z77WU5d/y32Xyn5JY/h+eX7L8Pw7yydNz
#@NzV/8X595co/zct/umgrlH8Izp08ysT4CFlOLO/3vn9jjOlp0mqu4znVXOMjQ7x05fzm60yUN+3L
#@BgGKtwIIYGeqAMS2I1n+Lf+W/90h/ymJhcSZfx/3Xs++q625hXam9L+kql8SUXIZaLHpX678Dw4M
#@cCmn6//esSEW56a8ajbGmF3CyuI+pvaMkOXyiWPMz05n5bykH0CWAEFkX1P4viBL4IZ/XsdZ/i3/
#@OyX/KYnl3/Lv497ZuaXe/t5SK/Pni7skgGZL/5tu+peVfwKunF+jv9ZHNohy9vgCrvw3xpjd1w8g
#@eztXSbzy3FUUfEQ02RQwIHIq2tTCRTdongjLv9eQLc8tWf4t/xSfbgSJ5b/L5pYs/7SOJF80ihAd
#@JUQ+0dKaqLV9/wgI0ObSzbHhQU6sLJFlcW6SseG6V8vGGLPLGByosbq0jyzz05NcXFvJBp2bagqY
#@JSIveK0mGwK64Z/XUs78W/53Tv4BEsu/M/8+7p5728r/BbAt2f/y0n9BxObSzkvn16hUErLNoo4v
#@7fMq2RhjdilL81OMj9TJ8vLVCwzWB0pEPYMAIqeBbe41rH0iLP9ex1n+Lf9bJv8AieXf8u/j3h5C
#@Pfu9hWgHqWz+9rL/ETlPlJb+A3r4NaPDQ6wdWSTLkYPT9PdVvUI2u543fvou//Av3/5/9s7tJcog
#@jMPPfLtuhRUd3IqspbKDUkoYYZdd9S/2BxRBQYlQgZV0ulARvCkvshtBzbVyPZSRWbzhd+HSuO7u
#@5+ep4ffAIOjCi7MwM8+878xwp+cNt+89i9vdnrf0DbxnfOqrOkgEi3OOq62nK1QH7OFWVycGVS8F
#@NKzWbIUZPptWBeBwkn/FlvxL/lPKf5lI8r97YtsOy79zToOnYm9qlsJSZv99ya+GVZzUymc6Ozta
#@iSIHlMk1ZDlfOKbVsQia2YVFHvYO0v1iiJGP48zOL7L8+0/cSvPfGRkdp/v5EI96B5lbWFSHiWBf
#@BTjTfBSP+BjAof2NQPX7AHDUeBoQrMr8lQ6T/Cu25F/yn0L+t2kDwOEk/0nkX5l/xQ7qO0+V/U98
#@8d/qR50Ba0v/c7kGOlorZP8LeRoyGTDU1IJsk8USD572MzldohYT0yXur3y2WFLfqQXZ2lua8S8E
#@zGYy3LzWgcH69wG4FJJe97OAuvBPaynJv+R/6+UfHJGERPKvwfP/je3c7t1oswTDvrfoSnzxH2b/
#@yL+fi7ly6Ry5XIO36Iv07J8IPvP/+NUwS7+WqZP4s09eDzP37Yc6UATHnlyWC4U8Pl1X2jjY2Fhh
#@EwB/bqldBWDrVgHoqT+t4yT/kv8dl3+ASPIv+dfgqdipMasS35K8+5/84j8HOD+4gZV/drS14HPm
#@ZBM5nf0XAfNyYCQW+qT8XFqmr/+dOlAEyYXC8bVVANmVKoB2wHvX35XnEg9vE2ALqgAcfjzJv2JL
#@/iX/qeUfIJL8S/53Q3znnAbuAL7zbcn++/JvAJVL/w04eeIoTUcO4dNyqkkrYREq8aV+E9MzbJD4
#@yMBEcUYdKUIjlv/zp4/hc6O9jQP79rKKA1/wzYyq1K4CUOZfaynJv+R/R+UfIJL8S/41eCr2RnCu
#@Ht23FGf/k/zflUv/MeLyf5/84f0caNyrlbAIlg9jRdIyOlZUR4pAqwDyZLMZb2MgS1d7GwDmADNv
#@sqn3KID396oYPuaMdTGT/Cu25F/yn1j+fSJJqORfg6di70D89Nn/suVXLv0Hogguni3gc7ZZ2X8R
#@NlNfSqTl0+eSOlKEg/8CzKk8PtcvX8LhY57g14NhBrg6Jd6U+dc6TvIv+d86+feJJCSSfw2eaZD8
#@+1jVX9oWZ/8BypsDf9k7sxa3kjMMP1Xad7XUstTqZdo2xiFxLiYXJg6EIQkxWSAwgbkI+QP5/8mQ
#@3MTvIDCIrjnS2dRjLe8DhZuz+OMcdVfVc75Pdb66u6HX6wBbGo3IejH1DNicNf/5/n/U5d/f/9c3
#@0pwtr+8XpF8/nI1HvL5fg4QSWS9WBVBl4JTlP5xf7BAs/5b/45H/lGgJtfy747b8V44vsRs9T/af
#@vOz/dt+bl/ek3FxPaDSi34jldsbtMIQQfC/dzrZ1Oy2W83HGGwF+9nRkkkg2UBRpx1iXEvYsBpgi
#@Wf4d2/Jv+S8l/ynREmr5d+dp+f9p4qv2MSnZC/9teXy4IeVu6ey/OX+Ggy51Gfa9ToY5b17ezkl5
#@9+qRfrezM/sPlFsLIJAQQPKCf2c+h5Qs/5b/45R/AkRLqOXfHbfl/1DxVWCjdhwg7Rs5BYGt4Etp
#@9j9Jzoj51ZjJcABsiTGwnI096zVnz3oxoy7rFzPfSHPWrK4ndNst0lcCfv329U9TBRD2vRLQC/45
#@tuXf8n94+QeIllDL/zHEl2T5P7HPXKJm+X8+kjLLIyFkZf+fxH68X5Mynww3kzvPes3Z8+blirq8
#@eVz5RpqzJobAw82MlJ+/egTYXQWgKlUAKaIykuXfsS3/lv9K8g8QLaGWf3eelv9K8aVa5f+Sshf/
#@kzJil8n+A4jb1YKU5XzkGa+5CO5X19yt5lTldjnbnO8bac6eh9WMlFfrG9rNxu4qACpUAaCcFeLk
#@sn/Htvxb/p9d/gGiJdTy787zdOVf0tHcdxV997/EFu2/tgCg0tl/gNubBSmLqR8AmMvhDx/e0eu0
#@KUu30+L3H37pG2gugsmoR6/z468BvL5bA1RdC2Dn8QQAFTIo4QX/HNvyb/mvL/8p0RJq+XfH7cz/
#@qXzm2dn/9EcxHg4Z9nvAlkaMTMd9z3bNxTAe9vnLN19vhL6U/P/1m18xHflvxVwOy/mElLePD4DY
#@UnItAOWNawEkKiNZ/i3/ln/LPwmFzonPlw2U5f/ErluSO27Lf0782uX/Kdnl/yF9tZ9Qkv3f19ss
#@rq9I2ch/jMEzXXNRrJczvvvTB26Xc/K4W8757s+/Yb304n/mslhdj0h5+9UdaDtQqWQVQDZiP3LZ
#@v2Nb/i3/zyr/ANHZSMu/O+56SDrZ6xY6SHxVOkbZ9y7su6dKng+k+8QnBV7Mp6RMhz3Pcs1FMh0P
#@+PvH93z7x/e8e/PAbDKk1WywaZufN9s2+779+N6Zf3ORvJiNCSEAW66nE2bjUV4VwB603R+UvZ8A
#@Uu7XAITKyr+TGZZ/y7/lf+fGaAm1/Lvjdua/anyJhJyJkVQhtlD6X+9Y/E8EQCzmM1ImIz8AMJfN
#@3WrO7379C/75t9/yr3983LTNz5ttXvDPXDKfH4YNSHlYvShQBaDiyQABiJJY/h3b8m/5P5j8A0RL
#@qOXfHbfl//niK3e39GnHJErZp+9Y/E8EEADMpkNSxoOuZ7nGGGMymY0HpNwurwHKVwFITzP/AiGK
#@IQojWf4t/5Z/y3/pc6Il9LjkX5Lve6h2304VidP6zCXKopwtQuwm/9V/IjzZPx4NSRn0O57hGmOM
#@yeRq3CPldrEASKoAslDFMVW7x1U58+/Yln/Lf335zyJa/p35d8ftzH+d+J9UMIEhVYgtlPO6QSVH
#@d9stOu1W+gaAzXbPcI0xxmQyGfZIWVxNckxc5ZM4Ss8L5CPLv+W/MJLl3/K//5xoCbX8u+M+7Xsu
#@iToIcRhU+nAFbbMqnxsUffc/QCA9fjQckNLvtT27NcYYsyWjSixdCHAyGtJuNst9DSCk+5Uz3qrW
#@eCo5mWH5d+bf8l/unGgJTQggWf6roFP+zP3QoxYSGaj0tUsqUf4fkNKJFfR7HVI67aZnt8YYY3bS
#@iJF+t0U6TF1NRoCAAosBhsMOpOEIyv4ly7/l3/J/6vKfEi3/zvy747b8H3QmIJ6g5Ly8SZKk6n+H
#@Er1ul5ROy+X/xhhj9tPrtkkZ9frFshyhTlVeIAvJZf+Wf8u/5f+w8k+AeKwSKln+KyF3nl8itqST
#@ln9JVEHPkiUQ0ueWUf4vhTTyk9jdbouUdqvhma0xxpiE/IfFo0EvY9G+5N+Qt/aNqP86QFn+Lf+W
#@f8t/bfkHiM5AO/N/LLElXezvm1Rf4L8sKnftAiUTKUk7rkuZ8ytJmfGbjSYpzUb0zNYYY0xC/tfF
#@et1OMs5kLUWj/LFQeesAhMwTQpH5qOS5u+X/KORflv+jl3+AaAm1/Du2y/4PhXTgaxdIQhL/V7Hg
#@jRhJCTEgyc3Nzc3NbWeLMZDSbDR2+3048EN5iRTpcsv+Zfl35t/yf3D5B4j7zpEsYyJQFiHL/xeI
#@LcnyfzRVBEoyJD+wd267betQFFxkz/n/P/b0oQYC60bZlEIpmQGKAoqlHSahyOHmJU/YfTth9i4C
#@Ao8Aq++pPwvZ/lqKqS0REZnQbj/+/+9PXuH1f/jsCFzmN7T7ozjtX/lX/pX/LvlPSqovEDP/Ewn0
#@xX3T2MAlNgCETOCNQTJ21UPyNRgQCBBIgCy5vv4vIiItalm4VmuYSn/ZWhTA1sj2Gp7zr/wr/8r/
#@t8h/klQrsfJv7H+QPoCucsO9ZgGwpyxl341AO0Zz0AB7ryIi0sE5TQw0BsFXA6D8j4oNyr/y//Pk
#@/0n9wdlQ5d/1Wk77Hwidox6w8RKFlZmYDgKIiMhJ7XlZM3qSbLVHZv6Nrfwr/6Pl/4tqJb6e/AO+
#@PI09bBkA0Kn6rJSd3Y97rHasyBeY9xcRkXFTASBkSudxgDDrj0LagH0p5V/5V/6T0r6nWonN/F8p
#@NmCjcWOmayMhb8NbX8efu4iIfI/8s3+QoAcmEtYDwb6U8q/8K//fNwBAUP5HlBsz4J/Gpj9+V7nh
#@5icClHmBYO99hJTVr21DcC6AiIicNqh9EGyJeVmQfxTwXyb/BOVf+T9U/qdUK/Gy/IOZf2Pf83dO
#@uFzZYT0bASQkpCxOi4Qd6/9L3AhQRES+gfP2AWBXm4p9KTP/yr/y35T/Lary77T/KeB0sZGx4Rpl
#@B1a/KZZi0y4Xj+WCkvL5D6a4BkBERE4COvYB6Jv2f//+DPYhlX/lf4D8t6hXrkgwSv77AVx/rvwP
#@i0/IEQCHlx02DumHt47+Q98XEZGTAfqX97PyABbkH6f9K/9j5B9Q/m8v/22qmX8l+Gjg3iPGdMYG
#@flGDSbJb2L+Az+oh09jTq+AyABERudRpAe3+KM32HBRw5d/Mv/LfL/8pSVX+rwlg5v8OAl5yCtAT
#@//xZAO3YbR4k8GFKpbzeBkq/iIicCYdvBPg4uj8BCvgTQPlX/pX/lY/VNID7vkAAM/9O+08S93no
#@BDg0NpNnA3kFj/oTEZELQwKTaW3sFlFSOkQW+1Jm/n+c/EOU/7Pl/0k18/9DJRjlf2Rs4BJlJ4w7
#@YhGyBBudJEgCG4/Azf5FRGQgdH+Mt9tzFHDl38y/8n+I/CclVflfB36vBAMZx3gB5wJ/63Cjukba
#@kDzC7CLMH8XsIknZDulBgCIiMmp5P9kB3Gq3f1D+P5F/UP6V/+vKf5LUsysSwcz/iLLffyPA2zca
#@wID4J9bB0lcm3vwUkECApOx4kvsAiIhIB8e3Zaz0R0u7SQez72b+lX/l/1j5f1LN/J8H4Jp/G40u
#@4Jj4hMPK/oBzOkysXCgJsPLvYf5fRETOBQ4+55/5YyEtwL6U8q/8K/8d8v+kXr0Sw+/N/APK/8By
#@8xLbgY/53yb5y965vVpRhnH4N0P/h3WRSQR1IUJBCVoJhqRpFJWHzBQPiBhZogmpZeebCqOMLoKy
#@c5lnENO0NDUlSa0LCbTw2M3eGp7WE60WZKy996w1M2vN6ffIeyMu3/3N2jPzPd/7HVqBVHIHzf8r
#@qkMNAUII6DchDofD4XAMENHQtpWD+xNxcmP5j/WZGpZ/y/8A8t8gdOW/xBJMteUfSDl3Nj8DWR5g
#@FLTfNlKTf1f2jTHGZECSgQBo7o8ywIC6sPy78u/Kv+W/O/LfICy7/AOugGckr5A4v4/6Szk/ItXc
#@QAoDF/SbG4u/McaYgu4IAE3T/rsKwvJv+bf8W/6bCF35t/y73Z1dbwckbjvkerPDpjaSaCiAFq5j
#@4O3/jTHG5OskgK4uI8SV/07lBst/jIuL5T9v8p9sAACqK/9gCS5yuwEPfLQ7CyCIdxNALV0Pp7W/
#@R/hmMcYY0yFQu6Cgf3kDC7gr/678W/6zkf8GoSv/nW034IdnHIKsBT5/1XdQaiA68p3XUN8QY+Ah
#@Vt8LTwUwxhiTPtDSawkF3vBPEsLyb/m3/Gci/9GEXZFgUTX5z+Tc9eTylP4abPCMB0kC2mx7BoMA
#@QUpHHCFRI6oRMXPjvQEknT//l7Zt36k3V67SEwsWa9yEibpj5D26ZejtGnzjUF13/c0Oh8ORSgy5
#@aZiG3TpCI0fdq4mTp+v5F17VF1+u1fHjf3hQoE6UhCG6ORMBXEAqsPwjWf4t/wnlP5prilEFloKg
#@X+nw5m/OHSnfQRB4v4M+QChQkJL8owZR920DWnmgt7gWgNJPDDh16rTWrNuoTZu26MBPB3X58mX3
#@tY0xHefChQs6/U+cOaujR3/Tju92Sw2G3DBYd44YrvH3jdG1gwZVZLY/fb64UKAg4t9F0PTiBNyP
#@q1zln2Tyj+Xf8h/9ubAK0/4By38hc5drGQCQynWHLn7nkOg+BAni9LXwzn4Nvt+1R1Mfn63bht+t
#@51a8or0/7rf8G2NywZFfftUbK9/RyFFj68+pb3fuquQWAOA+ZJ5yA572b/m3/A/wudBr/qNz4wd3
#@IsAbHabddkgvN0IRxLgPowcCvI3/gNSrbBMemKyHJk3T1m07dOVKzRfFGJNLarVa/Tk16dEZ9WfW
#@wZ8Pqewk748S/erLsIAF7r9WTf4By38F5F8KFLYswXjDv7gA2VbAEwo4ovCDHkBeZgHkc7RcdKXT
#@A/Vobjfp/G6DCs/JE6c0Z96TmjhluvbtP2CzMMYUbtbS2PEPa+Hipeo9d07lBdGvhNH9d1LgkwYs
#@/678W/6j5V+SQlf+PWWrCLkBlQUglesOac90QVGQxn0YSOB6f198vXaj7ho9TuvWb/bFMMYUekbA
#@6o8/0+gx9+uHPftKXvnn6o2T3Y+ruPwjy3+czwCW/27If4Owi2ePW/794M40N6CkQL7aDunmRsS4
#@D+Pnhv+if6jEJluLlizT3PlPqae31/ZgjCkFx47/Xl8SsOq991Vwkq/5R5JwP64FcOXflX/Lf2fk
#@v0FYlAdIDct/lrkRSgJ4zX/T8Y65nWVDe/JPOrlBQhIoGlQaenp6NWXaLH2w+lPbgjGmdFy5Uqtv
#@YLrg6SW6dOmSignxB8GJ+9718k3Lf3vyD5Z/y3+E/DcIqzLtH0gmwFnnByWC4j+4AeUByNsxh50Z
#@8EEMcB/S0XZDU5SSM2f/1IOPPKZdu/faEowxpeaTz7/SzDnzdfHiRRUVWnmv4QKS5d+Vf8t/TuW/
#@Qeg1/354Vik3IjdtB5QW0Jnrjkhp2n9yoDlQ8yABFKfyP3nqTB06fMRmYIypBFu2bteM2fPqy56K
#@BpEShvtxZZB/sPxb/ssr/w1CtQFY/v3wjA8luuYQN38GgwCBElFL8u0G8RuBKPWa/+mz5urQ4cOS
#@cDgcjsrEN9t2aP6CRarVaiWS//SBVt625HXjZlf+Kyb/WP6LIf8NQnURhOW/wPKPyLzdQOLciNJ+
#@5xAnd/R9iOhuu0m3M0HO4tnlL3ravzGmsqzfsFkvv/a6kPIVka8j9yE97d/y78p/geW/QVikaf+Q
#@hsAWWMAhWW6ybzeU54UF6eQHctl2FETsC5DBdUd9Q7GO+vvwI2/4Z4ypNm+9/a7WrN2gCAor39CB
#@/D5mMBKgsPKPsPxb/tOX/+wHAIpd+SdhfvCDOw2APO6Om9Emj81AKvIf+9ohumfm0JwrUG45eeKU
#@Fi9Z6p6/McZIembJMh07dlzlBf0LBTs22ZV/V/4t/6WU/wah5d8C3g4IT1W7Cshn26Gz9yGNP5KP
#@d2yH5SteUk9Pr5cBOxwOB6o/D+fNX1g/KvB/eNq9p/1b/rsq/wjLf0XkX4H+Zu/8XqKIwjD8zvz/
#@FFkQBl10E4UUUihk1E0lqyZqSiDU2mX5iwpSF9aewIthIV139xxnzpl9HzgXXiyfZ3bPmfN838eM
#@Ssv/lG2eND9vSOOaIxJ+zWF4bLj5dYjwWhuRD8sdLSwuOQtijDEDbGxu6fGTOaUP9ccrJruZI7K9
#@p5Kx/IMr/5b/1OV/wg4AUBDAVMs/oBAAZ4wlAcnMG5J5zsN/wI3I/9jPBkDkL/+B3Jm575O+McZc
#@wq3bd3V0dOwL4cq/K/+Wf8v/KBRhnylzq/xDs69dwxu3EJnPO76YQrpzh3o6cIDx11etVQoaG53O
#@qtbWN9zx6+Hh4XHJ+Pnrt2buzTb9n1j+Lf+W/wbkH2T5r1H+Jal02/8Ubp40P29QMEArv3MgemwI
#@W4fxEwFktNbCmX34yNUsY4wZwtO55/rxfd8XIvOHRgP5yj9kK//gyr/lf/TPlJZ/t79PAqI1GWNE
#@lPigaADR5w4B67CGjgBaKv8H+wd6/27Zh1pjjBlCr9fTg2lJloIr/678u+3f8l+3/FeUlv/xITA+
#@4I07kjAjWpvwAaLHBgkG1mENAFXgaIutUDbMv1xU//zcp3tjjLmGuWfzOj09U+6ARgTLv+Xf8m/5
#@r0P+wxMAECb/gEKAqyZpAR8ZfNMYBBElPuTR7fGXQk0AVGPiH23BlT9mhFJj6fVbn+qNMeZ6Ll4L
#@+GrpjdoImZylIF/5B7KVf0S28o/lPxf5ryhd+c8zPtD43ClQKBB+zYEGv/MGkgBFnHUIahSgGlHX
#@GkqGPycn2tza8aneGGNGZP7Fgp/279iu/Lvyb/mPL/8VpeW/mfiAN+7EYiOixYc65h6+DkFJAEgw
#@PClQKDvW1zfV7/d9ojfGmBFZWf2os7NefqV90jjPICz/ln/Lv+Vfwygt/5NBGzZP2iP/gGKASHLu
#@QGz5rwAJlB5oIBmAGPg7F7Z3Pvs0b4wxo3Mh/52VNSULpHyeyVr+yVj+IV/5Byz/UyT/hCQAIFQ6
#@UAgoDCDjzTOd1neEQoF2dntA3NjAjSbhIKP2SBDVkAAByU2iu/fNp3ljjBmTrU/bSgbcRenKvyv/
#@lv+WyH9wB0Dhtv9QgObnTo43jbq6AMLnDnHnDsSS/zy6AQrFg/pHt+sEgDHGjMvu7pcm9uwoMMXy
#@D+Qr/2D5t/y3Xf4rSst/gIw5axuxC6C9CR+IGxsIlf88ugEKZc/h4bFP8sYYMyZfu3t+4J9ju/Jf
#@6B9757YbN46GwY/Cvv+r7mYx2YsE6FpgMCYac3DcTYoHqcrgZHIR05RsWfUfyC9QAvvKP6D8j5P/
#@ynFn+Qfsfd9q3UOrAJZeO3Duz2FJSILy38Rv33/zTV5E5EX+/Z9vyv+EuUH5N/Nv5v/q8p+SHE39
#@343SATRmQvd/cAPT5q7QMPeZVQAlU6GQXsDIlod2+U+uV+nChPH9+/98kxcReZFv3/474Zm9v/wT
#@bpv5B7aVfxLlX/kfJv9JyWHZvyVbe8y9/xGL0H9u4Ez5r5AEM/8v8/PnT9/kRURe5MePH2b+ndvM
#@/wbyj/K/nfwnyaH8t83PgLmHCC+fzT24CqCkGaDLdSeMDQKU99YKnCb/z5AE5f8FcDgcDsfr45by
#@D9xW/lH+zfwr/6fL/wfH7vIPs3csbQcwYrxcwGdCEKCkiQfjrjtJUP5FREQqcN+qA+C2mX/YV/4B
#@5f8+8l85WgX4kTYAy/77ZIEvs26YvcnjhCBASROkTDlakiQo/yIiIiZSLPs386/8ryz/laOxHNie
#@fzOheYbgPg+D5yalYXPNzoXuyr+IiMiG+yfdWP5B+Vf+7yD/lUP5T4DpQgIYMX4CZp2yMLIKoLv8
#@V4D5u+0r/yIiooAPgYKZ/xtm/mFf+X+A8j9W/itHu/zP7xsCs8BJArTPzeAqgNJwXyfs80Does+h
#@u/xXgOktNnwM5V9ERJT/fwSw7P9N+Qcs+zfzr/x/Uf5rAABokn/C7Y/6w36ta97zAd/v0F/+nwGW
#@uO58DF8TRUTkYvIPvse9CzfO/BOUf+V/lPxXDnv+Px7cZAqlOfrbqf97cBVAGVvdAVym5YGU948K
#@LFkCeBpGBERExLJ/57bsfyv5R/nfTf4rx1XkH+Y/wPDBvfTcQJ1/xc0OoUX+2wNd8wMCBgZERET5
#@321u4LbyD5b9K//byH/lWEX+AR/cSYDBcw+uAih5GVjznhO6zw1nyf8v9wbYIzCQP/1JEp7/bouB
#@iIgYeHgFuHHmH26b+QeU/3vJf+X4lXgyUIbml2FzicADsMx1J3SZG9Zs9SB0v+dwnvw/gyl2ERGR
#@7RNIhPuW/ceyfzP/yv+rHFfq+Yf5D26uVC7GFTf8GxUEaK96gNPkvwIYCDgTHA6Hw/HGaGDDo4vB
#@nv83vxjCbeUflH/lv+RlSsmxkvwD9mslAS616R1hkX0eJgQBSpp40Ov7zUCAiIiIPf9ryT9m/m+Z
#@+QeU/0nynyRHT/knbH/sG+CD+xn8ZT37aEnghLltCxAREfFdpm1uwLL/N+WfxLJ/5X+0/P81AABs
#@f9QfDJn/xRs1RcQWO/aN5TaqAVbb76BC2/GOTQABfEkSERG5eOYf7Pl/V/7hvpl/lP8d5b9yNG80
#@1r8UefrDE/CXxsJVANCw9gFBgM7yXwGGfr8BAXxBExER5X/RuQlu+GfZv5l/5f8r8l85ess/YbWy
#@/ynQJxPbvG4gc9jnlAVgmXXSIuUlpwB8DPfi+/LwOEIRkTs8tyFNAG74N0v+4bbyDyj/95P/yvFn
#@+YcLyDdu1tIdtmgF2LrlgQ02eQQCmJ0RERHxHXKq/BPelv9snvkHM//K/8vyXzkGlP2Pl8T52fd5
#@lPts7AYjvufGfE5aPn/JcICPofyLiIgo/y/LP5My/7HsX/m/p/xXjpwABR+eSUg7wDrrJg2M2udh
#@vyAAeR8yWcJLQgghwyn2AIiI2APQc9xL/qFtbqAh839v+adwW/kHlP858l85OvQzLdnzD0Ztb1MF
#@UFLZLQhAp3sO8wWcjw/N9wkcDofDYQT1bwHaBDzY8z9J/sHMv5n/7eS/cqwqwEDb/FOz74OrAErG
#@wWKiXfug9gsCsHOrR8mnEM4LCBT13+FwONT/+YBl/7vKP2DZ/5vyj/K/q/xXjjOzgfN73838r1wF
#@AHRa+15BgHb5n7JJX2uWwgoBERER5b/LF0Ow5/9N+YeY+b+l/LcHAPY46m949n1wFUDJHNj5F+b8
#@IMCD89cNBFj2ulM/6v+74Z+IiCj/N5F/3PDPsn/lv7f8twcAYHX59qi/dwAu2+oBWZ165CaMue7A
#@Nt/vfPZRrBoQERHlf5X2ScAN/ybJPyj/yv/78p+UHCf3AU9/eMIa2XfSDnDJoAfQOP8erQCk5BkY
#@d6wmsH2wi08+Uv8bt98XEZHToVnASQsEe/43lX/CbTP/BOV/svynJIdl//ebG9j8nu8XBCDl/a+1
#@9FsH4M+aiIiI75DK/5vyD5b9m/nfVf6/sAcA9HyATMy+c6WSLTKFMvQ+L3fPCb3lvwLjKy4A5V9E
#@RMTAw3byT2iSf8Ce/zflH+V/Z/mvHCc/QC5zBBjQPDep7HbE4RCApSWU0Fv+K5DA+KALcAf59yAr
#@EZE/8CDVT4eZ/wHyjz3/0+QfMPN/X/mvHKc/QOx97z43kB4Al271gP5zE7rL/zMwp8oGMPMvIiLy
#@FZj7HkeYekw2YM//JPkHy/6V//Yg3dEgJFtJAbTPDaQVjBh/CtB1fui/dsIZ8l8hcwACKP8iIiJm
#@/s8p+y/3ln+CPf/K/yz5rxxD5Dv48Ow8N3DVsvvuEgr97znhDPmvc0MC8/aZAJR/ERER31+V/yfA
#@Df/elX+I8j9X/ivH14Rg/gMMWEIEgbSCQY/hmx1C/7UTTpH/Z2Bqq8nHUP5FRESU/+nyT2iSf8AN
#@/8z831X+K4dH/a0+95AqgFvcc+g/N+Es+a/A/OsOBFD+RUTk1sDcCk5C4+/zNvkHmkQe7PnfVf5R
#@/neX/8ox6qWc0DH7Pl+GWsGgx4DNDsccbUnI4+TrDgnMv+9AHVt9z3kGgIiIZwB8NkxeWfZ/cfkH
#@zPwr/79zfF2+zQKvuG5gQIBm2tp3KD+vmX/C6XPDOmsHPoaZfxEREeVf+T9R/sGyf+W/z8/pMVS+
#@w2UenkBaoZ+IDdtnYX7FRTvQVf67Hs2TDKwGKOkG8DyUfxERUf6V/67/hsnyD23yT7DnX/mfKf+V
#@Y60S8EHijaX3693zCUGAdvmfGuiCBNa878DzUP5FRGQy89sISRuEreUfWuWfJvkH7PmfJP+A8j9b
#@/islx2vyrQT3hvQB6LJu4DaBD+gu/xXCsHXD+tcdCBBCgGCDvIiImPkfOje0SQUwJ/Nvz/90+cfM
#@/2XkPyU5Gh5e06KXQFqBqaX38ymp7NJ3D3SfGxrkf6FIPSSw14sKJIHwNALuYuVwOBwO5d+yf+W/
#@o/wDlv0r//XfHB71Nx8YWwWw8z0Hus8N3eW/Qghh2HWHBLbfX6OOQIAaLCAEEkICgQR4+jtGABwO
#@h8MIgFUHyv9S8k9okn+w51/5b5b/yjFDVglLiCCkGWC1IMDMnvtBve9MOWufhi+eQkYCCRhoExER
#@qczcuBnSAkH5b5B/QpP8gz3/yv/28l85zPwbMW4Q7Zm7znefG86R/5R5Ry1CQvxZExERufP7K7RJ
#@BdAk/9Aq/1j2r/wr/w3y3xwAgKs8uC9bBbBp2f/8lgc4Rf4rhBCGX3dIQPkXERExeWXZv/L/9Xlo
#@lH9A+Z8u/4tUAAATssCz1nOfnvv51719bjhH/p8hDL7vgwMBxQ35bGEVEbnGMxvs+Vf+95V/wMy/
#@8p9nDqO2CaRyoQ0BJ/fc718qB+XUuQnT1g4JmCERERH5JWXuexRB+d9Y/kma5B8s+1f++/6bI28C
#@G1UBlAwByEoQMon51710+uI5d92EEKZdd/gYyr+IiMgVWw6gTSqAJvknrfJPk/wDTSIP9vwr/5eQ
#@/8rhw/OiVQAlXQGWljGgu/xXOH/dhEWqHhRwERERj/oz8++Gf8r/FeW/BgAuWwVQMhwg7fQTMWDG
#@pntTALrLf4Xz100IYYFMwccw8y8iItICoPwr/7eVf0D5X0f+K/8ycpoKJKVcb91ASpeF1c+1qAi+
#@tta3mrjK+esmpKQs8bIAqZSi/IusBo9HHjwCj/D4feTx+OPvIYHA058hD0ig/mAfpSQpKaUk5enP
#@lJRy5DiO/J+9c/uN4yzD+PPOzq6dOE5d222TnkLPh6gobdM4TdsoqgoFCSEQElwgEDdccYHEVcUf
#@0FsQQpWQAPWi4qRKRRxU6EXFXTlJ0JZAEapEURto08SHtdfew8zD+htltLvd/Tqeb9ffjP0+yqt4
#@7Z3jzre7v+d9v3ckieSxmJ/15KtUu/C5RriJVPjfz/BP0gn+qZn/8sO/uwFgh2Z3qHRfh38gsQDc
#@pM+t6O1x8l9PAovsJoBMrn+DQArUawHg4HuaeOx2L9ppX7X3RRqg70YHcSdCHHcj6gYjA/vOYmII
#@5JAxAYKggjTCbgRhYhiIGgQq1V7I/BN0gn/SFf7pBP8knUCedIN/gk7wT2jZv8L/+JcJ9c3TAboL
#@mwn1UAUg5ap6cNp5IpEMLurBCBB4EdkD4EWvnNG78qnKIBJRHCHqtBFHHRNRFIGMC119EG0H2hiU
#@SIBKpYKgEpqohFVUggogWrajyib62KbC/wdBnpr595r5p8K/wv/4x3ZAEg7SrvdXJJPZFzrPPZ9s
#@PwD/8O96vFKaa5tgYU0Xsje07F+lsouIog5azU1sNerYWLuM+ur75v/uY/P7TqcNMi5z5YI5Btsx
#@Rp22Xgoqnf9vaz+kc/617F/hX+F/AmM7gEV+mgH6hwKyWEBCFhOGSHqGUNfrSty3TS8mVwnOe09o
#@6l2lQmRguIHG+irWVgZAOOrk/gy8ugbcfghYWgA+dVTw5WPAN+4Enr5P8O0Tgu+fFDy3JPjZGcFv
#@zibP6dWJOeDlc+Zv5jnPLZllzLLddZh1felYstypeeC2Q2abuUQOGB/1ZaytXDTnpHtu1BBQadn/
#@WCUg3OCfpML/PoZ/OsI/SYX/AsK//yaA/ud/u0scmrm5ShzK90s/59/1mGV82yYA2WUTgICIlOaL
#@Cjn8Z9E5/6o9qjiK0Om0EHWj086fza8FgpsOEscOAjcflO7/xM0zgo/MAIs1oBpgQGIZsIL/NGL0
#@6vQCcGRaRoxGjlxfOwYutoC3NraD3fVKN4h/N4C3G4JWTGQSiU67aSKdOlCtIgxrJoJKRS8mlcJ/
#@Xqig38w/6Qr/dIJ/kk4gT7rBP0En+Cfd4J+EZv4V/oeO03AsUCgWBnKAU9/dz0Vctz3BhoDit+ki
#@xGFdXo0Pd/i3f0btemnh7p1/mWBjQSIRAQ57Vxadw6oqR5a/026h3doC4wg71dFp4PhVwL2zguNz
#@wK0zye+CvjEe5B2vBsrfqPdTwSePBvZsEzFMxni4fjqJhxekzyyICfx3S/DmBvD3lW7UifOr27/L
#@OHWg1TQBwDQXDGvT3aihUqnqRaYqV/m/6K3+NPPvM/NPhX+F/6GnIix3FtgBcP0dt7sJIPAr8XC+
#@x2Z8BJPctsUJK7kRIJ4helgFAdOfex4rdKt2uXFf1Ea7ZTLYO+rKvzAF3D8HHD8sCfQfJuZrkuuL
#@pSCb/lkXtHr2sSLAnbOwSzIaWxRcUSDADQeSOLvIdCWXW8T5NcH5xBTAX1aAS01YFccRWlsbJoIg
#@QKU6jWpiBmhDQVXB5Z5AAiQ3IJAK/87wT53zr/C/5+DfKBxf9n2XqwBkt4DbddtpFYBnEHOH9vKb
#@LmKBZadtWwaCFyNAm+6pVJPN9Jssf6fVzFzaP1cFTs4DS/OCUwvAHYfQI7F+0ZUxjdfXV9Gnxekd
#@rJzZvztyuDFgDI7HFtENpgv8ax344yXgD5eJP10GVts2MyBG3Gyg3Q2RAGFtCtXaNCqhVgaotOx/
#@3IBA0jP8QzP/Cv8K/xOq6gnLmfl3B9yyHjcJiC8TQBzW5x/+8++rONR+l90IEADQ+/yrVIxjtFub
#@BvzjKMo0d39pnjizKDg1T9w1KwgERrlh3/Et6/WVGL26ZzZzYVP2Jw4+VWymgDFCukF88ZggJvBG
#@nV1DQPDKJXZNgdG9BMgY7eamiaBS2TYCunEAEgR6saq8i3TNBJS/7J/0C/8kneCfdIN/gk7wT7rB
#@P0kn+Kcj/JNU+C8m/BuF7gNxl6sAxEfZvfO23asABKm8mABSZrdc8h+7wE3pgPBqBCiAq1Q5RNI0
#@8Uuy/S0AhE0HAmBpQfDxI8DHrgNmQkGiIOtns+UP7gbBqyvo09lrdpj4YU6TgLCbApR06sC9h6Ub
#@xFduEWzGwCvvAy/9D3j5PWC9M7rhYnNzw0SlWjNmQFid1hkCqtJm/gn6BATN/GvmXzP/5Yd/q8Ic
#@QORP4gC3riZAAAc5mgACo/J23PcJ0eLfbCKMPBsBRiKimX+Vqlf27LIpO7eX9huQNtD/6CJQC4BE
#@4gT8MuZxWW+bjv19+sT1geWOpjm+xzKjMUAYid0QMIbK49cm0YqJP18W/O494rfvAhebGKqo3TIh
#@QR3V2kHUprQqQLX/yv5JALLP4Z8K/17hnwr/fuHfrrBAIGoHM4EHFW3bHqoABKnKZwJI/v0VGHk4
#@Bl9VATrW9D4ACv5xhObWJjrNLRC0lvefWQA+fT3wxBEglB1Cv1geTuh72Wtr/VfjVAVYmMox9Gh5
#@KNmMAWYwBDjwZHPOF9kNwVP3AL+/BPziAvHSu8BWNOy1pGkc2G42EFZrqE3P6C0FVR66/5ez2z9J
#@J/gnNfOvmX+Ff7/wb1eYGd7EC+f4v+WdOAC3axWAIJUXEyB9WEYTQPLsr2XRklcD2KsCNPOv2vdN
#@/VrNTdPUz6bbDiXQ/7kbTcf+7NAv+b8fyZjG5mvLRK9uOCCwKH9Tbqb/2ZehzRCwmwGBIDUDvtkB
#@XrxAPP82cH5t+Htdu9U0UalWTUVAWJ3Si15VWFOboJb9O8I/SSf4J8cB/ywt/NMR/kkq/HuFf+cK
#@AP+lyxJIebORdhPAw7YdILhUJoA4ufaSLu/BCPBpBiTHrpl/1X6RuWd/a3MDUdTBKM2GwGduAD7b
#@jbsP54N+2UlSSCbzXeFvq0Sv7pvL//5MANhpg3AOLCI2QyC7GXA4BL5wcxL/WCVeeAf4+YXh/QKi
#@dhub3ahUQtQOzCCs1nQQqPZct39S5/z7zvzTEf5JN5AnqZl/hX+LBKEjCNo5rcy3vBNLxr1Qc+4B
#@EQ/bL6wJIMgtcdhnt2PxLxlaGaCZf9Wezfg3Nxumwd8ImXvYf/6mbbAUA5mJxAH6HYBfAIGbXltB
#@n564TpyGLGSH5oAAktUQyGkG3HNVEl+/C/jVO8Szb5m+B4Myhs/m+qq5feDU9AwqVb2NoGpMIh0H
#@rH9AIKnwr2X/jvBPhX8p9p08gqLPfSe5J7ORBMe2bXIy++WuCb6GnAz8Ax6uOxYzS0HySmjmX7Vn
#@wH9zfQ2N+spI+L93Fnj6PsGLZwVfvXUb/gWAieSfpI8S9f05jb4HfU8VpAEZPiZkMDBCMjxkIC5s
#@ARe3+hc7d1QggkyBoWHZJclxnEiV+ZymDweeMFMRY9z8+lHBdx8ATsyNvh4a6ytXrgcdIKqiZ/5L
#@UfZPKPzrnH+F/wKPbbsBQNAf1wj8Qah4hG0pSha4jCaATAKA92eTSbsZoPCvKiH4m4yvAb1Ou4lB
#@BbKdEQeeWxI8/4iYkv8wocp+qM4FqDYQzgL7FrjPyOWvLxO9mqkKpiuWBTP5DBaTIIMpYDUEkPNc
#@DzwhEMHj1wp+dFq2X1vzGgcywgiorxpzKO50dMCovH2uEdQ5/44gT9IJ/kmFf4X/vQ3/ECAoA5CQ
#@HCuEusNQAT80CCMPGXC/oiv8ZwLffQn/9nOShsK/TdTwGYxjbDXW0agvm/n+w/TwAvDThwXfuV/w
#@wNXop81RMJoBRGUYEGcAYTvoD0iyxasr6NMtM8OfCtlZpLIZA5mMD8s5sBsv9tcl/cG8tuY1fuGM
#@4MkjQ3fJmEMb9WVsbayBcaxjyG+UTgQLYNa7AQJJLft3hH+CTvBPusE/SSf4pyP8k1T4Lzb8GwW2
#@55ATqQLQ24/1iODYtk16yIB7rgKgC6TLjvZd4d9ybgZC4V/lW6br+8basrmX/yjw/8lpwQ8eEhw/
#@jOFl/qMy0JbyfjvsZsjsw0QmyBdkiCEGwEMLGaYO4MPD/kdLFYTdGPmgLNMEMr9WEBN3zALfOiH4
#@8WnBuWvkw64dHUgq35/npcr8k1r2r5l/hf+Cw79RUGggmXwVgP959zIu13hib76FNQHosm7Jte8K
#@/66mgMCPCJDc5dDOhj4URR2T8d9qrIGMMSAzH/yHJxPw/+jcIPhnyyob2cr7s2a3+1a5Q8jPmKWP
#@CJxfJnr15I0Cu7KtW2SH5sDgr+xmgP28IlW2qoD+HTOv/TMPJtM+Ts0DgyJjbG0m1SNRp60Dy4O8
#@vGfTY8NqUMv+Ff4V/hX+Jw3/RsFuZIFZaBjyXXZf1GMvdj8AuqxbnL+QKPznEKGgrJqcknL/NQNs
#@6W39Bsrev/dgMh/89GJO8LfP6bfDqQk78GfPsmfgdUnizTrRiPr7HZycB0QyBvrCsuEcxzJkfy0m
#@i6VnQG4jwEwNePaU4JkHgGMzIwyl9ZXEUIpjHWgqh95JkwUEUuGfhBP8k27wT1DhX+G/6PBvFBQS
#@SCZfBVAwEPNQBeBw3n1XPdBlf2VsJobC/wR6LZDmAVKzAAQ4yjwAgJ6fjQioobDv1GmZudumdHtQ
#@ByvA124HXngEeOwaG/jby/wFsEO/2LL8qSyQnLGUHpk69af66zL6tFATWGQH/AwmAbJXM9iPc9jf
#@BHYzwHb+7UYAzl0r+OUjgqfuFsyEI6YF1C+jpdMCVHu02z9Jzfx7zvyTbvBPwgn+6Qj/JBX+SwD/
#@wP/ZOxdoO8oqz/93nZvcvENCEklIAgTIgzdJIPKyBbHVUXTU9jmiPARRULQV2hlb6WnXrMZZs2zb
#@GV9tq+17RhwfLdg+BkEa2xckgK22bauojQSSkNd9nVf9p1N3pVbVSZ3tV/XVOV+dc7//Wd+63JM6
#@rzpVdfnt/d97A0G/ssB0bsPuDXDTyi7mIAjg2v4udp+XfS31MIJWD//VeG3vJJiBYkhMjh/AZLbd
#@P6rx/sqFgutPEswOAgPwN6ztV0HUPMuvw74C+KrSj3toH1I6eREgkmspMptSgIL7QgwCLxCDXgGG
#@gYCRQPDK44E7LhI8dxUgGdeY+uQYJse9G8DDP0oVwYG3/ZMe/n3m38N/xeE/VuCBZPheW7dCOQQs
#@sQt60Ob9Sk/B0x9zvuGfl5Os/xOZY/02LhJ84tzpGu+Vc9MEqIO/ApiKxV8MxwRKvkZ52coJ7A/u
#@RUoXPEmQU/rrqe/VvMGhGI75E6VEQAvQ6IGA9AuvGBXceobg4+cC6xd2nxbQatT9iejhHySdZ/4J
#@X/NP0sO/h38P/8oudBYAYGkj71hOBpp9dgGI6zEyLq3vdp+ZFu+3j03vPIB7+PfqscgQkxPZWf85
#@NeCmDcBt5wFbl8ZEp4CfAv5Q7hOzbLOgEPDr4J3Drj8ZAj8/QCT1nNUKyOsrW0pZglVAwKD5osV3
#@pweCIkl0DH3+fMGb1wOjNe049G4An/m3kfvMP8kZb/sn7OCfoId/D/8Vgn9dQd+t90MKJKTFa/ej
#@FEBcWa3tAx+EhQR9bTRH0gO4h3+vHqndamD8wBOZmdczFyOCtStPENREqfOPAdIGHpVsvwL9KvCb
#@We/1enyk10/2Eq0QsUYCYO18i8b/kqMsIWt7o3n/5vtVLII4ZseGYEQEV68TfP48wemLu/efaDf9
#@pAAP/8VEYOC7/ZPe9m8L/6Qd/JO0gn9awj9JD/9Vg3/3DoDqQijJoYchOqu3tg980JVNz94N4OHf
#@Bx+8SlRjagITY/s7z+MoM/um9cCnnixYNx+mdv9YgnywKFq2X4d+HZBz1tWLAb3v2IuUVs0FIFYr
#@JcnZr0BM5/2bOysiSd6gDmIZlwWcuACHJkhEx9rsQI6YQDExvg/1qXF/os4w+CfpPPNP+lF/3vbv
#@M/8e/vM8ThA4sd5XrwN55WruCZY8ogb9l9h9brr+Y12O88DDv5eXreV/bH8mXG1YCHx2G3DNuo6s
#@PwDJ1QBOB389259zTGC8zOzxYpiil4xbZ/3/aUsEljflPeiBARTYH5Jn/9t/r/pxg+gYi461284H
#@Tl/ULUi1zzcI9Kq47T8tkgMP/wSt4J/08O/hf+bAPwEEfakBl+FvvqbPEHUUBBDLiQWOxu0RBHs/
#@cq6fDYI8/Pvgg1chy39zutlaq4GkagLccNIhEBNsXKTY/W3B3zIDDeQFfh32pdtNssH8oSeQ0h+s
#@FGsHgEiu4ECsvAEBwMKBYf0962UBJy8APn2eROMla5JxzI7tRbvV8CewlyIpMBK5mnP+SZ/5J2gF
#@/6SHfw//fYP/SIEz25RzCO0dpJHlwQhBy/3uIAhgHfgQUD9GHHzn9s4Dkh7+Pfx7GapZn8TE+P4j
#@sqlLZwMf3CJ43UnAyDSVmdn97cFfzzZLTujXgT9f9j3jZZ6oA78d72gAuIqFuD+tfC4EPSCQMxgg
#@iivD2ulhWhYQ9waIxkt+ZKtg+Sg6SwKicpWGLwkYapF0nvknve3f2/4BklbwT0v4J+nhf1Dg3yYA
#@QNIDiYehnozbI6R4oEgcz44X4/4A/nj38O+lBD2nxvdjanIMIJHUOUuBL14guGAZ8mf97cE/lpLt
#@N4d+HZ5zW+w7a/B3PEEkNW8EWDAaFMv6Zy0Uci0YzPvX9qvynVmXfBRzA5x79PQxef7ROEL1qYno
#@WCboT2wvpWu8u8x/SNpChXP4J+lr/n3m38N/DviH2DkA7GGoYp3XSVay5p5gyRCK0kWybPiPRavP
#@3Scol0Kv6eF/6EW/ciyGbUwe3Idms3HEYfbqEwQfPUewfNQg669AnzX4a9l+c+gvlCnXm+yl9dBe
#@IqGo+78I9AVVepPCYs4GPRig7OvyAgHK8xm6AZbOFnxo63RJQCBIKjqWJw7uQ8i2P8fzLV/z7872
#@bw4V5MBn/kk7+Cfo4d/D/wDBv2UJAMmhBBKSlay5J1iy/b0nTe9s4L94sEgc2/nsgw8e/n3wYcYr
#@bLeiBmrtdgtJLZm2/OOPNwA1EUTSs/7mdn9jYDR4PhhAvwL8OuwrDC7Z64E9SGnzssDonBLThSwZ
#@BAUktcyDAaaTGsy/V/OyAFGPuUi1REnAstGMY/tgdGz7E31IRNI5IJBO4d/b/kvK/JN28E/Sw7+H
#@f0P47+UYQHEyom5GjF0jWLL9vfzPTrJs+C9wgXU/XtJBc02HyW0P/152ah3OknbU+29aKNFs/4uW
#@Z1j+9ay/Xt9tEECwAk8dcPVRgWIK+nqPnQc7SgCecaxxA0AzqYEB83n/+r6yD8SY2/mVwJHiBugs
#@Cdh2NPB/nhw1pzyiL8Dkwf1oNn1zQD9DECDoPPNPcuDhn6S3/VvCPy1BnqSH/8GB/1hBJaz3PctA
#@u4dAsrdBAPsMdPkgRtIC/nWxP9MlHEyYyOkGkKo73T38e5k3+5scPwAiracsE3xiG7ByDgBI8ay/
#@ud0/Vi7wRyxzkIUG8QroG9rwfz0G7Gt07M9jTPlfz/wjXqaBAWWbvG4JmNTzF2vuJ6nfbdwAgpVz
#@gU9tA562Iqu/xQE0pib8iT/I4oy2/SuJt8HL/JO+5t9n/mcU/McKfBOy3jc6ZMVhiCz/tUlawL8u
#@Wn3u6pe5kIzXQAMws5aHfy/Eqk+MYWpyHJ26+gTB+7cA80dEgX8F2Gzs/kbgr0JrwSZ3OjBDbcSX
#@1gMd2f+jRoGRWhnt//VAAUwDGijUL6HYzH9YlAWoASU9CDCvJvirswVXHi/ZzQEn/YQAP+ffAuTp
#@bf9VyPwTtAJ50sO/h/++wn+soCrWe/qZ68YiWPrrkz3peG8B/4qkf85zkorTxcHry3D3xYtED//D
#@L2Jq4iAajSkkNSLAOzYBb94ABJn1/tmWf/Osf7kz4/VMtQ795sCf9XAd3B/YQyR18iJlcwMnALQF
#@01n/+cckwnBfi/WIRyM3QO7jMRDBTRuBd54mmBVkOV8OAvQTAmYa/BN0nvknOfDwT3LG2/5Jevj3
#@8K/Bf1cFPvNfZgbYZSmAvcg+zNq3h/+U2D8Qdxv0IUFwhjbP18oMDAIIvod1pUQSU+MH0WzUkdTi
#@WcCHtwpeepwo9f6a5d8s6w+UC/56rXoB8BXT8XrdV2cDwCevqBkSf+7XMhtXKAUCIXpvhXIDAQZu
#@AL0kQO8L8MLVwMfOESyZLR29L+qYnDjoYwCxqn/dJukcEEj3mX+SA5/5J73tn5YgT9LD/wDCv30A
#@QMrNurN0+7m9SCqv7TgIQA5E0IVkyfDvKAgAgqTbucF08R58t3+vkkRG9f6djdBWzQE+++SogVoB
#@y38MeeZZf3vwz4bdYoCrd8kXBbwzVoPAj/cRSV221sb1XyA4IDCYclBgXyFWSYGAnG4AAaRgScDm
#@JcAntwHHzD2yAebk+H4fMpwhtn8WAgTf7b+K3f4J+pp/D/8Vhn9dATmcmX+SDl578IMAZM/G3ZUE
#@/46CAOIw8CJqnwAP/14DITLExNh+tFtNJHX8/ENgJNFPM/gvkPXXLN0W4J8G3oJZbahArZN6xt0/
#@3QfU24hVE+DUpTmy/Zmr28sbBwbMJiDAdOa/9v3YdfmH5HUDmAcB1s0HPr1NcNx8JBWdExMH94MM
#@/YWiwiKHo+EfQQ//Fcj8kx7+Pfy7gX9AEJQJJGWI1kBQffs3iUqLLH+/E9LzOfuMVl8BvDLBLpIe
#@/r2FtbIrDCP475yDHo1K+9Q2wcq5kgn/YgH/YtrUrSj4ZwCtPfQbgr50r89/cE+IpJbPRQnSAgUm
#@gYFyggGxxOL70oJA5R572RMC5gg+ea5g/UIkFZ0bE2MHEIahv2YAoG/4lynSfeafpHP4JznjR/2R
#@tIJ/evifsfAflwCQ1bLes7S6e1a05r76pQBkqfBfHFbF6vixlziEbyk8PcDDv1dlRIaRxTlst5HU
#@6YuAj54DLJ0tGRClWPYVy79a66+BujFIWgBq8n5TIIbx+L142x17kNKpSwCRkha6SPL0MVDKBWAR
#@YDH6/vTn03sDKCUBSklB1msvG5XI9XLWUUgpbLcwObYfDH05wDDCP0Fv+69I5p/0o/6sQZ708D+Y
#@8B8pGBzbv0M4Fu25hrcfAFki/KfV8zn7RAkSh/tfSpke4OHfy61ITI0dCf/nLAU+tk1w1CzJAH41
#@26qDu1mtvw6PgJmVHDkt6qJk+Yt00E+veNsdu4mknrpSyuWceBWaZKC7AwT5SizMAgF640eLmf/6
#@8akf1wtHBH9zjuD8o5FSGLYxOe7LAaomkkMx55+kt/3DHv4JWsE/6W3/Hv6dwH+swBhIpb8gxOoH
#@HoY/CCB275EQd3P2bW2E4hC6pfwxgvRtpr1cNPyLbP9p+L9kBfDhrcC8WgL+tWZ/FrZrLeuvZ40R
#@S6Bkp3X4TL8vKFl+ZayeDtrpjQ+2gF8eRErPPSGwy/obdQk0cAtItHR3gOKKUPe78v9sihtAPz7y
#@lqPoj8061qNz4P1bgIuXyxFOgKmxA74x4FDa/lEYEAj3mX+SzuGf5Ayx/av7wMO/h//C8A8BgkrP
#@uy8LBMkya79nRhBA7N4jIX2csqCLg5R9Fyga8mCAoIfyRaz9FIGo239HzX+U7Xz3WcDsIADQYd23
#@BqwCI9xg0UBOyzobgKxifY8XlMx6FnA/sJsIiVijNWDFnHLL/7ODAwZuAe0z6GUCyvdi0cgReUdJ
#@2geoIknqcdG58J6zgT9YLlk9AfyFpALXbJYCCHRu+yfpM/8ACG/7pyX8k/TwP7jwHykwaP7mEEId
#@grGozzVwVjX7wEfp8K9Ec8sX3WXfK2l9J5lc3vbvuwCWthgS9bEDnd3+ozFo790sKfiHMfwr9mzN
#@8m9Y628/S17P9ovpmEAxgH10z6531v+vnp/1HPqCwYqlNyZMSwymI+j7r6zvyag3AAocc+ZBgPS2
#@swLBX54FnLsUKYWtJibHDoCh7wJYMfXd9k/6mv+qNPwj6Ef9efgfVPiPFaigJ+4hlDNgzCBZoSCA
#@2L1PQoq/X+kHiymSnsJ2pftrEPHNw79XcZGoTxxEq9VAQlGzs7/eKpHl2Rj+Y/gqno0VBQRl+lYu
#@+AtMpgXoln4j2M+21D+4h0jqzKPFdGxfLDFZeYICai8D8+7+kAKBAIvvXyxcJ/Hz5AgCzInKAeLG
#@gKkRgfXJA4Av4xpY2z+BoWj4R9I5/JMceNs/6eHfw78r+FcCAENSd++g8dwQBAHE6n1azvnvn7OC
#@jr53ktGq+rnG9M3Dv5ex6lPjMfwnR/19cEse+FeAy25Em54Btgf/SGLcNFC3yuuwn50t72wA+Iw1
#@KqinJTmWFhTQSxt0F4TuCrAPBBR1AxQ4DgWA5AwCzKtJFCg7bRFSajUbh84tf4EZ2My/e/gn6TP/
#@AMjBt/2TtIJ/evifyfCvBwDoAEB1IOkTFIvbpnt0WQ4gMBZZNvz3v3s9lah8nwIBAxNoY/rm4d8r
#@U42pCTQbU0hq/cLpUX+L4m7/5vAfy6LeP3/W3xL8M+A3E3oV4FdgXwXyR8aBnRPpp3rmmiAJ3+YL
#@2UsPFihBAdOZ/6orwCIQUMQNYNEXIN7APAgQ/1wwIvjQVsHJC5BUdG416pP+QuNM4gz+SW/7r0rD
#@PwIz3vZPwsP/4MJ/rKCa2UgHQQCxfq4hK3nQRZYF/277LBDuRBAkB85lwyNvHv5nuFrNQ3AygaTW
#@zgM+srVj1F+Z8J97JrsAMM36WwCnPrNeh35o4/L0pnwPddj/588C5syCSWG/mdVACRJAeb9KQ0SL
#@/Wf6vSjPp4x/zHt82QcB0o9ZMlvwkXMEa+ZJR5Bt/NC55i84A5T5JzgUc/5JOId/kgPf7Z/0tn8P
#@/07hP1agdH53kIF2JHHddM8aSp2M2yPLgn/HQQBGy0KuXQ/u4TsdDODhezz8D7viGuVxJHXULES2
#@/6NHUS78S/a25mCXcw48FMA0svkX63Yfr2zYz3zQ/buQ0omLBCJiMf5PIEqQICMwoAQwTKcjWM78
#@z4JvQzeAeaAoG+wh5QYBlo0CH97KKBiQ1NTk+KFzzl94qqyK1fyT9Jl/AOTgd/sn6eHfw38pgb2g
#@X+PHzN9zn10AMvDdz52N2yMEZI/t5+QA9WGwdz2Qw1Vzz86bEARA0M+xGoIVzSufOACSqdFz/2uz
#@4Pj5ACAlwL/N6LXoZp31B8xqzfUZ9eYgHC+lBkCQBvztHQ6AbStgr3wBAsVEYD7mTx/1Z1CiYeQG
#@sDlulGOm1CCAYO08wXvPnj6nYpGYnDiAsN30YwAqTv0EraGCdG/7JzmDbP+qm2Pgbf+0hH+SHv4H
#@Bv51BTqQVA+AWTKcwGm/A4f9AOzh3zyDbt9rYXjcAOLk81Yx2JV0DBjffB/s6ohsY3J8P0imvuI/
#@PzUa+ZeGf1jAv0W9P/I0ChQTW3kGqJra1EWBfhPgF+naSC8k8NBuIqn/sE4AsR0DmDdAoAUEDIIB
#@kqO8AgkZlAUUmPlfoC+AfRAg/RjBliXAX5wmCKQjCDB+EAxDfyGqlKRy3f5JDkXmn+Sg2v5jkd72
#@7+G/GvAPCAJIX7KiVe5+7iYIIM6aApYI/2mRVp97+N0AUnhW/zDBv718kKACIiYOxPAf603rgctW
#@yZHwL72AfwXeDWu549/N7f66C0ADUejQrwO/3rn/X/cTY03EEhFc8KTAmOOVMn4tSJApPSBgNfNf
#@z/7r+18BeYtjyeLYNX+M4JkrgSuOR0pkiPGxfYC/4lVSBK2hgvQN/8rK/JODYPvXRdDDv4f/0s7t
#@YBCBgOXWX1d61CChyMG4PUKKg7NAUTWDAGR1+kyQ9PBfVN7AWnLH/0kQRFKbFgpevc4B/NtkbaWY
#@3R9Zz6OAZ7wU6BfowA+lW//9u5FS1HtBSlzQ5vwbz/tPlwyYz/zX93/RsgCxcZP0LwjwaB246ofE
#@R3+FI0UeOhd9AVVZq3KZf/fwT9I5/JN0nvknOPDd/unh38N/YqMABiKrV3fP8mCk8g3Y2JvGcxbw
#@b9st1gEMOwgE9PKzk/Tw7+VE7VYrcxzZTw8Sn/mNADCEIAtwsq3bhgKIyuOtRgRGKzPTH9+vA7+S
#@qt/RYf/fcFSZ/K+UB0jGWxKYfKbkk/Rh5r/ynVv0k7ANAkAJAuysA1f+IMTT7grxvT1KMK4+6ZsC
#@+oZ/mSLhR/1VpOEfOfi2f5Ie/ocD/p04ANwadKU/mWWSFXQ92H1mQopb6MVBc0nHgYB+Ndck6eHf
#@q28iQ0xNHkQ33frTBKyIfkxIXmASFf6VkWzGln/d7m8O/nq2X8v0K8CvNdi7/3EiqYtWS8kRAGX8
#@v0lAIOvfMoIB9jP/1bIA85IA474AmY4CcwdMxrmxc2oa/C/+VhL8VUXnJENfClCVmn+WABUhve2/
#@LPgnB9b2H29G0tv+PfyXem4HMBRZPSBghWGEZOmvT0eBD0IKAzOk9/u53yIrN+Hh8PLw79VTTU2M
#@pRqP1QQptQi86YEQv57Qs6QiBeAfGvwrNdpKfbea9VfgMj+YSnTLAf3GHfUn28A/7yWSeuG6st3/
#@ygZqQCBnMCB+kN3Mf5i6AQyPFRElCGB+zKrugV114NpD4H9niO/uRpaikYDXnwS8b3P63GNI1CfH
#@/AXKQsNm+ydpDQgEncM/SeeZf4IDa/s/LHr49/DfcVdgBz7u6+7pYOScy1GD7FHX+WzZz/kn+wLA
#@1XMDCJyIJKIb6eHfq1Q1M6zG150I3LhekNT+JvDa+0OMtxzAv2bnts/6x9JBNLu2H2IA/SrwZ4P3
#@P+0hmiFizQqAdYuD0iIAklwwf1/xyhMMyOgVYDzz39INoJcE9CwIEIH/NT8IcdE3Q9yzC2AX8L/h
#@ZME3/uBQACDAxSsE165DSq1WA83GlL9QOYZ/gtbwT/rM/xDY/uNNyMHv9k/Sw//QwL9FCUDV6u5Z
#@buf1ypc8sAcgRrJk+FdgecjcAGSFAFgynQEe/r2s1G63j6j737JEcN2JgtesEzxlOVL61Rjwxu1E
#@m4DAAv6hw38MgznhHzDM+osGkSr4K4CrQL8C1t2s9/ftIpJaOU+QJTFbukR3JgigBwQk98x/NRCg
#@T2gwdAOgwKhJiZYSBFCPvxj8X/29EBd+I8Q9j+vg/82nHgJ/wYKR+IWi389dipTqUxNot1v+guXg
#@j9wwNPxLQyuHAv7JAbX9p90c3vbv4b/0wF5Qvv25SjDkGCTFHZhCLD63PfxnqI9uALgKBFT3eCeZ
#@Wj2R+H7SnWsYRAJTEwdTx83iWcB/PwOoiQAAPrQ1wHHzkNK9u4n3/IyJ7LwG9bkb/uUDNtg2gdNm
#@zWeCf7bFXYV+BZwVUt+xCymdsVwZ3WewRFtQehMU+0z6qD90CQQoTRstmkAWmfmfuzHgzkngin8M
#@ccHXu4P/0tmCt2wU3HmJ4Ib1SfCPfyAQwV+cIdG5GItEfWIMpJ8DYLEsAIHW8E/awz/Jocj8k3Se
#@+adwUG3/sejh38N/xl2BAyDpgwtg+Gug2btZ+yXBv6MggDhsNikWbgdbSeG+AT7z76WqUZ8AwzaS
#@eudpgpVz09/9584PML+GlD78C+K239CoBAClwr9W75+RNRYlcGAEnJKARr0zPXIDst5pf3tHA8BL
#@Vidp3G6l34DytIhVJMCR3kgLBCS/kJJm/ovSF6DEIECU8b/quyEu+kaI73Sx+h81G3j9BsE3LxFc
#@c5Ikzqfs82TlHODPTxUkFYZtNOsT/sI1QN3+4ef8D5vtPxY5GLZ/vSSFHv6HA/7tAwBkNevu6WDe
#@vMtRg+wBiBHS83nzZH/+MBN9dAOIxcQAB/CtuAM8/HslrP+tqPY/qZesEVz6JACQFDQtmg185rwA
#@NUFK7/wx8cDeLqCfhiV7+I/BLrfFO/uxuuW8o8a/GPjr0K+P1ts9BTx8kEjqeetGOja2AP/4viBr
#@G31koR4MMA8EaD0C7Gf+6yUi8WOLBwEerwOvvJc47+9D3PNYd6v/mzcJ7r40wOsPZ/yNegkInn4M
#@8KLV0hG0m0K73fYXMEXDOuefoDUgkBwK+CcH0vbvu/17+O8l/Ns7AMghsP3rsoQhB0EAe/jvhMIe
#@ZqD7aH8HHVrvo+XgtUsLCHj4n6Eij+wsvmoOcNNGAJBM+/6GxcC7zkzfX28D1/8wxM6pju17Af82
#@Td6Uxyp2/3zgL/Eq2CRPUmv7LqQ0bwRYMlcDemUZb6dsY9rkUNknRoEApSxAcQNYNInMFQSIgzNX
#@fifE+V89lPFn14z/Gw5Z/S8VXHeyYN6I4fnQcSzevDFyAyQ0fe6SfjSgIgcJGR3+SZ/5PyySzjP/
#@BJ3DP0kP/x7+e3JuB1WpPVfkEiwLQrCDIIA9/Bd/v9LTufoWr98HN4D077O6HzMYLw//M0DNxiTC
#@jizin50mmFcDgO5N/C47NsCV6wRA2v583feJyXZW0z9D+Edu+Lev8c62+ytAajiyDqbQn87Cd/6+
#@YxeR1HGLAwPAD7KWAfgHgCjOAGT8bhIMgGblN+jyL0pZgG2PCPMgQKw9dcEV3wmx7Y4Q334MKvjf
#@9YcB3rBBsHCW9hpqw8xI80eispzU+wjbrUPnsL+QVdT2z4ra/kkOhe2fdJ/5J91n/unh38N/LwIA
#@ynVi5gUBxGG3egFYMvybRyAdf1/icCqDOA16OBWRCgj4TNPQKIaHyEac1AtXAxcu6/hjK9n/n/An
#@pwg2L0VKPzlA3LyDgAFUZcK/WMG/Pu9dqQPPzPoDxWfVR0uB/hzZ9/s76v+3rAigA7zNvwuAQHlP
#@2lKCAVJ4P8aSxEYWM/+tggB76sCr7m3jnK+08e2d3cH/xkNW/z8McONGwcKRPAExrR+A4PxlwHNX
#@IaXG1BRCPxWg5yJoDf+kPfyTHIqaf5IW8O9t/2Vm/gl6+B9C+AcEQWnwJqiUyMp33C/9tVk+/Ovv
#@Vxx/X2IBr6ADALcIBFSswaXuFPDBgcFVbB9OHaDLR4GbNkg3639mQOAzFwQ4Zi5S+trviA/8C3OU
#@AIjSJLCsGm7FMq5k/S2ANeM+BaaRDeIUwY6OAMBz1tXygr359jAICuifIdsZAIuAiuIGUEo6Sush
#@IQLsPgT+97Sx9e9+P/h/+xlB9HPhLBifR7EMSgHedorgSR2lAFOT44C/BvdPAlX0Df8GouEfQefw
#@T9Lb/j389+w8DSpkRa40KJDsQcf98iGU5cJ/zqhsH6FYSspig477TMRrQODfqozABwkGQM2MBmK3
#@nAosmpWRnVcgPgDwhacEGK0hpff8M/HNRxXIsWkSqDwmt/Vbz/rHMgZ/42x/bKdXIfvh/cCeqY4J
#@AGtHsiz6hVb69ZX71YBAAMDIFZDXWRFLcQNYlYLoQYDpspb/dHeIrV9u424F/N9ymuDeZwW48ZQI
#@/JXj3eS8UksBouaBb9skQGcpQLPuL2w9Ekuw/RP28E/SGhBIDgX8k+4z/6T7zD89/Hv4VzYIUFD6
#@yTbkpQDOpw3or017+Nffrzh2b0gv7HtOAFwPgMy00ZZkXFqAjuBA5y0dwGHi5gMJNmJI1Du6/l+2
#@UnDJCoFu/c+ElMg58LfnCyS+EwgJvPm+ED/bT+hNzqRn8A9D+BeYZf0BI/DPuEOBfh3Mcf+uMA2b
#@cwQjtY5afxGbpfQGSD638fvu7nSIZBgIMHUDAEZBAOQLAkQZ/8u/3cbWL7XxD4+xK/i/8VTBPc+q
#@4fqNgvkjJlBv2CRTLwWIJnQ8a6UgqfrUBBj6a6Mb6fAP+Mx/UiS97R8ASeeZf5Ie/ocP/mMF5QDB
#@jAoCuJw2YPzatIB/VdIfpwbZVwhV4NFF0714DQv8u39tuliDOPM/ZReOsv5v3QRD63/238utSwXv
#@OA0pTbSBa78H7G3QrOM/FBCyhX+JVqblH2KQ9dey09DAP2PlKAXY/liIpNYvURr2FVnQ4R7Q79M/
#@j0EgAHn2t1bbL8rMf6MgQDzO7+V3hdj8xTbuflTL+Af4x2fX8MZTAiyaHR/LVk3+IkmOUoBNiPoL
#@xCLRqE9g4EQXqzejp8uH/3LH9pH0c/5jgKMf9ecz/8MK/7ECkIMGBO6DAOBAwBBLh/9+lms4gGAt
#@ECDujl3Cw79XzxXZ/puNOpK64STBktlIS0xAJr3t5esEL1wrSOrfJojrvgc0QxX+87gAzLO5otWD
#@i+4SMMpIZ1n9g2yghuQoBegeADhv1awuz19gDCD0jD+gfw7d+q89f5AuDSiw77PBXpR5+uqxE43z
#@u/zuNrZ8oY17dhJESrH1/nWbAtz7nBpef4pg/iztmM6V/Td7nCClpbOB60+SjqkeU2j7hoB9/+NE
#@6KLP/JcK/6T7zD/pHv7p4d/DP/QNAvvrngMXgEuJ9fvr67g9lg7/sfpWu032HwQJVgqAycPLw79X
#@b9TomPl/4gLgpWsAQDJAI3/H8ndtFpy8WJDUfXuItz/ANCihp/AfSYzq/WMA1bPQyqg6FXwRaKUA
#@Klg3CfxodxtJPX/97Hg76bbiW5Ba8f2SsVR4N3/P5vsgXt3dF1Jg5n+8seYeSYP/Nf8Q4uwvtHHX
#@75AN/rOmwf/7z6vhrWcIFs3KWdKiuGjylwKkj+WXHwesX9h5jo/7C11uKVli8bb/MuGfpHPbP0Hn
#@mX+SzjP/JD38DzH8Q4AgN7kLFA15KYDAVk7G7dEa/h0Ha8QN/BIEhRXstn94efivvpOUg7Ays4Nv
#@3SQYCQRATuu/4hT40lMFi2cjpc89THzql8wCIt0GXQD+RYF/KdwrIM366V9yWOHFfJsf7yYmW4hV
#@C4AzV9QgEkCUGvx4Gf5bOqAQpIMEaqY/9+fV91nn/oXNzH/RJkBE4P/qe0Kc9X/b+OpviJBIKp67
#@f/0p0+D/n8+aBn/oTphYema/lFKASCMi+JONgoSic7zVrA/KdcnNq/Z0zn9aLGf6jjUgkBwK2z/p
#@R/1527+Hf9PzNMhFyAKHcj1v3hp8nY3bIwREQYljx4Y4H+/oprmc5O0X4OHf17AWXUSjo/HfM44B
#@Ljga0zKAEoHZtnMC4O8uDjAiSOm/Pkh893E1Q6o3SUMsc7cAtHr/otlmBXr1zLmJZT4G7x2PtZHU
#@8nkqjBcYA6i+125OA8PPobxX7T5IEVeG3hcAkWLwv/ruEGd+/veD/w+fPw3+i2cpgTFlrGXufgDK
#@eadte97RiJoCJlU/PBaQMFy+h4ot/Ftoxtj+SQ5Fwz/SPfzTw7+Hf4PzNLC4ADlwAbieN+8gCGAP
#@/2kW6SGIkewDCLrIfvc5ECC2zQM9gHv+N14R/DMMcVhzA+CmjSm7dLbS8GK87Zr5wAefHCCpVgi8
#@7ntt/HpMy4gqwQWxg/9YpuMBRbX7m0Ot/t9pyE7Y5e/vCACctqyWepz9KMCgy/Ppn00QdA8GwLg5
#@oOHoQIPeAHpfgBj8L7+TOP22ruAfuVZuOjPA9hfU8F/OjsHf8FjM2w9AOYUk77aCmzdKahQno4Df
#@lOf/3BKjPlCEmWgBCGWO7SM5oxv+JUXQeeafoPPMP0kP/8ML/7ECIzoWh433BCAcBgHETfabZInw
#@nxZ7P++9LxBMOgDwXgcCpOxJAj7z79VdZIhGvY6krjxBsGqOceO/WJJj20tWAW8+VZDUvgZw1b1t
#@HGwpANVD+BdD+I+kZf2hg60O3ZnQH69uAYCLj5ujZewLLmUEYOaUAC0YoGxrmv3PdgPEyjvzf3cd
#@uOquEGd8ro1v/lsIdsn433BqgO//xxredLpg4Ww1IGXe5E8ZqamXAhhvG2v1XOCq45FSFABg6C+A
#@+eRr/isM/6S3/Xvbv4f/POdpoFGVeyBw3Hlf3Ga/SVrBvyZCkTh2bkhe0HX0nU/fKg/AZHJ5+PdC
#@rGZ9KnU1WDYKXH1igcZ/maCjw9ANGwVP6bAn/+IgcMN3Q4QqRJnDPwzgXwVJ3fKfAbLQAVYMsv3Q
#@LfRjLeDnT3Q0ANw42h3gUXAEIGxGAKaXQHUFGO4zZLoBxOD7Qgf4X/mtNk7/3y3c8Wsi7Ab+pwXY
#@/kc1vG2zYPFoOcejFGzyF29TsCHg1esER48iIaJZr/sLYKG/UbT+g0YLQChzbB/JSsA/yaGY80+6
#@h396+Pfwb3h3AE3isubecT8AsYZeZ+P2aDOeRhyXb8jgNXnk9G1gAJhMLg//M1UMQ7QaU0jq2nWC
#@uYElgJhuK8AnLqph9TxBUnfvJP7Hj4hIUijjGkuKwr9ML93yn9zICPh18DfMjG9/tJ2C1tERwcoF
#@Na2O3zQQYD8CUA8GKOUBeV0AAGBQEpD471114IpvtXHaZxXwn4Vp8H9RDX+6WaI5/kBuR4qSrs9Z
#@ClBSAG5eDbj6eEFSreYkGHoXQA/kM/+DY/uPRdB55p+E88w/SQ//Qw7/egCABKRqNfd9LAUQW+h1
#@12yQEOSQcjA7CAJIGWDrAEJtAwECp2IqKODhf6ao0ZgCgVgr5wAvXkMgw56s/n2VHGUCGQD01acH
#@UcY1qff9NMQXf0M1sKDfZwH/uuVfBWgd+FXw1xvkper/W0hq9ULFkq/N+UeA6WUSIAhyjABUAgbK
#@51b2ncnq+n3umgJedQj8P9PCHQ93B//Xnx5gx4tqePuWaFJF4njIe/wV7AcgOez9ovFA1k/By9YC
#@x8xBLBJoNCb9hTCXaG37p4f/lEhawz/p3vZPeNu/h//BgX9AEHR9EOm45t5BEMC1/V0sntNi1B/t
#@P7d9XwBBSXJQ924TCJDq1TSSncvD/7ApZIh2s46kXnMiMDtr7F+uxn+5m5tFsPWFS2qoBUjp5h+E
#@2LGH5jXW/YJ/iNlPyQP+5uMCt+9sIamzjpmlPEYZ96fcZ+BE0Lc3/Gzm0wNMf8Y/psH/zjZO/XQL
#@d/wqG/wXTIM/HnjxCN6+NcDi2VKg4aRdP4BYynMbNwRU4hOjNeDaE5BSu9lAyLa/ICpyUPPfl7F9
#@BH3mP7EvhqHmnx7+PfznOE+DatYBOwgCuLa/i91zEtIvaC5/n0ivbO5uIZSJ26DAv74//aSBYVFz
#@ajJ1Ph47F3j+sbFfWoeZHGPIYJD5hAAbjwLeva2Weo16G7j63hA7JywAzBL+JRP+kQNI8wOvbr0X
#@3L+ziaSecdJcs8Z9OrDr20GU+y2CBMp+UX6qJQER+P+/Nk75VAu3K+D/hjMCPPCSEbzjnGA644/M
#@EYH2AahCpQDxLyWej4I/WiNYMzddA96qT/kLooEIWsM/fea/dPgnh6PhH0nnmX+SHv5nBvxHCtQH
#@kQ5q7h0FAQYGxKjB/+AFAaQf9e7uIZTTtwGDf11k1vLwX3WFbKPVbCCpG04SzAqgfz1SoEY5B/A8
#@fy1w5XpBUrsmgavuaWOynafjf3nwjzT8K03/9Pvl0ILVWMBo7RwjHj0Ypj7Ls0/KaABY9hhAEUP4
#@txv7F90K7uNddcHLv97Gpk92Bf+opv/mzQEefOkI3n4E+CtBAJgcf8V7YQhEK7cxf17RL7kjAXDd
#@iUip2fAugMpm/u3H9ikNpt3DP8mBafin1+67t/3TZ/49/Oc8TwPlQb0OAgwNDOmw29tmg4T0C5jL
#@LwkQaHJQ6uEgEDCETfdIZfn/d6xc5//j5gPPXgUAYlDPX6BLuZjbmP/s7ABblgmS+tFe4E3fDUFB
#@LPMMrEBQHvzr2X9k3i/IAFYUm5N/36Otjtp1wbzZtRjaez0GUB8BGABS4HPhSKgX830cgf8rv97C
#@po/X8bWHw65d/W88M8COl4xEAYDFo0qZR3y3GJcAAMWnYejnhdnzmvcNEDz3WGDdAiREtPxEgJ7D
#@P7s+xmf+XcI/hX7Un4f/mQT/sYJB7gBOsOSO+30OAoglREMcTElwPebQHkwhcC6S8eqXKnOuZwQG
#@4vuQvp8+YlCuSLQaDST12hOBEcO/qWJlSzabf/75SwKsmIOUbv8N8b4fhxnvwa5JoA7/prXoWsd7
#@ZfsCpQDbO+z/Jy4ZiZ+jb2MAYdEfQH8O88kIkdX/EPg3sOljk7j9l+3u4H9WgB+9fATvODfAUXMU
#@m7zh8aPX7FuVAliV24ghH9XkyIkAzUbdX2wdZP4VlT+2T5LP4R7+SVrDPzkcc/5JOod/kh7+hx7+
#@0wog/aVBsvzO6/Yw5CAIILASIT2Gx740f+s/BEtVwNLBPhjQQF8cIFAWfMDASM1GOvv/pDnAs44R
#@m+x/WmI/ymykBnztWTWM1pDSux4kvvFInsZrojgETOAfSvZZzejrdn8pXgpw/6MNJLVtzWgR4Lbc
#@Nijd+p9e+r6MwP/v69j00XHc/otW167+N55dw0OvGMEt59aS4J+zyZ9YNvlTYN3G3m/pArhsVXoi
#@AEA0m74XQK/+oNHX/Fdyzj9Ba/gn3Wf+Q5/59/Bf4DwNHNBg2VlYy9FrDoIAJcD/YQ1cEECQJQcA
#@XN1AAEkP/17li0Szo/P/K9YCswK77L95mYCYglDkAPjsJQJJbBASuOHeNn66lxDJ1/TPHv71jHX8
#@mop93c4FIAgp2PFoE0ldtmGued0/kku5XwF+w3+3zP5nB1SeOGT1v2MSm/7mAG7/RVMB/1l46PJR
#@3LJtBEvmBIDS2M8M6sW4yZ/Adoa/GIC9vQtgJABesuZIFwB9BLVqNf+xSFrDP8lKwH9IWoM8OdCZ
#@/1gkve3fw7+TIF0AF5LywYugBZD0MQhgD//dwLH6QQBxmAkXi74HboMBHv69SlGr1QTDEIc1rwa8
#@eK0oc/81qC8ANpIPbM5dHuC/bUFK4y3giruJPVPM2/RP2V6FfzM3QMqujt/fwK5AQ8CfP9HGwUay
#@AaDg/LXzMgA8MBsDiGgZjgEMsgIMuvUfxtCvNvnbUxdcfsc41v/1Ph38N8/GQ6+ai1vOG8GS0Y73
#@p4C8WnuvNwU0n3phek6JcaDM3AWQ+VPwsrXRNSAWwxDtVsNfKG3/oPk5/w4y/27gnxyOmn8CHv5n
#@FvxHCnpIgkMw+qxade+EQFHPgwCkk0kH9hKL77tawQAP/15W9v+kXrgaWDhSHCbSAGRbJpC92as2
#@BHjecUjpt+PE1d8mGu1ssBHEylsCoMC/CqzmWX8Un5l/X4f9f9ncAEFg7iYwHwOoPKeF9T/vrP89
#@U4LLbz+I9R98Arf/a6ML+Atu3HII/BfglvNnx+Cf2azR5FjQoDsDzPXGfaWcA3rfAIug3aJZwPOO
#@7bxG+DKA7hJnjyHo4T8hwh7+CQ5Fwz/6zL+H/4LnadDXdLAgIQcuAKlG9ptk2fBf7ZIAcVgXLxaB
#@jmoHAzz8exmr3WohbLdwWCMCXH68ZHU6jyXoU/YfOtB84MIa1h8lSOr7jxO33Eez+ekwbfwmXeBf
#@v08AFW510DUH5O0d9v8Ny2cBIvkz81K0xj8wgH9lwWwf7K0TV3zlANZ/YDdu/3k2+C+cLXjLuXPw
#@0JULccsFc7BkbtZzIev5lYaQdsdS+inLb5YpYnNuZk/IeOXxgkAQK2y3Ebaa/oJZigSsUOafZCXg
#@n2RFMv/u4Z+kc9s/SQ//Mwv+YwUoIqtMpKMggDixwOsXY3v4r34QQOyBt7DEgePBTTDAw78PPKhq
#@dTT4uvQYYPVcfQQZxCL7X+Z4MwG++sxodFtKf/uzEB//WZht/ZcsCNOcDQLAAv7jBYPsPwo1BNz+
#@yBSSuvD4uTrYIy/8K4EEZZui1v/0Ag40iGvv2I+T378LX/6XeteM/2vOmoP7rliMt513CPwDFfjT
#@98X36135FUeARSmAxbhMCxeA/tw4bh5wyQqk1Gz6MgBd/QUEkj7zXzL8E7CGf9KP+vPwP5DwHyvo
#@77XQURBAHNbBix3cEmIDzm5LAsRhl3xxVPrgPhjg4b+L6GBVQuQRtb0vX2ObTdRg2nTsn3kH9Hkj
#@hyYDBBgJkNKf/oC4d2fBpn+Zc/7FoBQg2exPg30o8+vz9QCYagM/2dVEUs87ZeHvr/1HYDEGMMiE
#@fnvrf/q+vVPEFV/eixPe+xhu+8kU2iGO0IJDGf9tc/Gja5bg1ovnY8X8IC69ED3rrzg8ABGLpoC5
#@m/zlBXvJ3+SvwH0vWyMdbiEHIwGH55od711aAUK5UEGyEvBP0hr+yapk/t3DPz38e/i3OE8DKzKq
#@cP01wdKBhCwfhkhawr8+4qTXIvsHgrQ85oY/EBBnDJLLw/8MV6vVAIlYa+cBW5YKACmeSZQiwGHx
#@nAIcv1DwsafWkFQzBK6+u42HD2p1/wr8K6CowT9EaQxovLRgQJD6+eBjDTTaBOIu7oKNy2fH2+dp
#@yCfZS5smUND6H3R/HxAcqBPXfuUJnPw/H8WXfzbVPeO/eR7uv/povO3CBVFX/ww3hRIEUAM7eY+X
#@tAo3+UO59n6xce4InrwMWDNPUn/rms26v3C6y/zHIukz/xW0/ZP28E/SeeafpIf/GQr/gCDoKREL
#@nIrCAWk2yLLhP5aTIIA4nJkvcOx8qB4Ek0wuD/99FZ2vZr2OpF5wrEB0sDCX5Mv+i02ZAICnrwZu
#@PkuQ1L468Io72zjYBCAGgIZO+EcHNBrAv1b334OGgNt/10BSKxeOqI+TrBXdur/n+CYdS4X9/Nn/
#@afDfg3V/9Qhu+/EE2mEX8N8yH9uvWY5bn7YIK+bXlP1sEASAKN+3AtOxDEsBUNzeL8YugGIJRs1s
#@89yVSKkdBQDoeg0s/LNC3f5JVgL+SVrDP2kP/wQHPvMPAegz/x7+Lc/TALYiHTTccwcFZM+a3pUM
#@//0PApB9gzHnde9kvBRVNuA0rGMGfQ1ArERTr7CFw6oJcNkqqKP/YFQ/XPA+o6ykDkZ/fGaAp64K
#@kNTP9xHX3tVGSAXklKJsJWNsBv+wdANAB+ftj9SR1OkrR1N2fJEgCfoGI/06lr59R2Ag6FJ2oDsP
#@DkwR1355N9b95W9x2z+N6+D/mmNw66WLsWJBTdm3WhBAd3So9J6zFAA5j19Inr4Bhe7LdW4Dghes
#@AWqCWO12G2G77WsAzFU6IBD0mf+Bbfini6Sv+ffw7/w8DWAnBw333GfAyV59dpYN/7E4feuD/bzv
#@de+uIdQ964n1fkwun/kfIjUbaXC8cJlg5VzbDuI9zP7DLAjx2acL1swXJHXnI8S7toeG1n8FuBVw
#@NID/9ILWGBDGTfLu6wgAXHry/ATwGz2H2ax/CYyeKx0Q0DP+Y03i2i89jnXv/vW/g/9Yd/DfuhDb
#@X7sKtz59CVYsCJR9owQBtECO8j4tSgHyNwQs3wVgPclj5Rxg21Kk1PJlAIX+ENF9zX8sEh7+U++N
#@1vBPDkfDP5Ie/mcm/JccACAdNNxzmwEnewBiEJAsEYb66AYQd/P0CYIknEjKDwT8f/bOBFiSur7j
#@31/P9eYde1+WLqgxBkSNFRMXiVcZxJJKKeARMSYYk4BVnqAptdAYE0tJjNEklZSVEsWoZXEj96lA
#@sAzoAsshCCzssjfL7r7dt/ve4810fxMaXld3v57//mf+3f2fmf1/q/41r2f+Pb3T1/bnd9qGYJLp
#@4eB/AMWM4n+nvtDAy2jT+4/kOp4AN7+zgrEqEvrWhgCXbgxS369R8T+alx06Lh0hUvGeEvr1CwLu
#@mw2weTJ5HE95xWKdCv7mbQChsT6yDQH7Z4kPX7oLR//T47j4/s7gf/YJS7Dhoy/EeSctRRTqDy3g
#@zzTeSI/HOFqt11SAaK6NKADz9979IkkZAFog6W6kahUCCASHyvNP0hj+yX7x/NuHfzrPv4N/M/gP
#@5eVKxNIv/eYtGAFygP95GXhh7RgBxGKuvCSApz9y7qMxPBBMMjkQvjr472P5fjtxjJbUgLesYpfF
#@/wy9//kbCiItbQBXnVxFxUtee5+6I8DdT7PD80UiD1zLOyxp0DRIBdAeSHr/SURqVgXLEjnxikr/
#@6Ar+Db/Tg4jgUIs487Kd+K2vP4bLH5xC0Mnj/7pFWP/Rtfjbty7F8rFqxnbQoxFAINpRHok0ECWs
#@qw1U+YM9YBAF0PU8wYmrgaV1RCIDBH7b3Ui7AAQaAELe65B0nv+c4Z80h3+SLuzfwb8N+C/QACCw
#@mxAtdrzfZK7wnwauwmCIoI0WjyUYHkoCUzFKDxiavHuSnYaDf8vyU/28T34BUPcEOjL3LhrBino7
#@Mc/rK5cD//qGSmLubBv4s5t87DiESBnAl+UFTheK04P/AgsDigju3jqLuI5eVo/maoE5DAwQei0A
#@o+J+H754O47+2iO4+L4D2R7/uodP/eFSbPjki3He21di9UT1cPvA0AiAdKpFh2PfSw//+HerrgsD
#@YDe+JvVV84CT1kjqHtJyN9KSAYHkUOX8kzSGf9Ic/gn2ieffPvyTdPB/5MJ/JI/kwBbciyR2vd+k
#@GfwrVGTFe/O6AGKxcr5ApRIh1IIhQAaz2CC54D0H/4X2/m8hrpNWiykwlGY8ELW3MrHOn7xMcMax
#@grh2TQMfvLGNaV8R+p8B8MltZAFjqGKjAZDM7b9n+yzi+v21o/Ewf71WgOgW/vVbAB5sAWdesg0v
#@+drDuOyBA51z/NctwfpPvARfOnFF2uNv7vVH9jGWZMG/jHV1UwEUYB9N7KEtINBX1+TbVqVbiLYA
#@uDQAnZ1KdCkpDipIOs9/H4b9kzCGfzrPv4P/tKS3dTzj0Gkp1uVLFgFj7Iu8d0L6ouI9wXIgmNYg
#@tH8K7s0P124vdnwAYqGxABkpB7ER+xyxZYDugRV+4MfP+zC09/eWoYzw/96/Dyqp26x9/YQKXrtS
#@ENeGPcA5twep0P80DGaDoegWBpQ8CgMiCf6puXdvm0FcJx+zqHeAh2o9fQNCVNzvkq04+iu/xkUb
#@9ncAfw9nHb8Ud3/qZfjHk1dj9Xg1Y//A0OuvLvgnSkMPFq4D0ez33/2zqcDCtaU9T/C65QvTAPy2
#@7yDfEBB0RXKoqv2TNIZ/0hz+CRrDPznQnv9IJB38O/gP5eUKBGUbAcQIegsIPzeBf7VIFgti4GB0
#@eRAT0GRfATDnh6u47zz/OaudCv//o1VAVcy99faLBApEkKlr/riCVU1BXBc/FuDfNgQprhMNL7Ck
#@Uwa6gH/lvI6vkvH+pskWdh/yEdeJLx8HoAH8StD3UqPz/ENtYtO+Odz55DSueeggzr9zD959wRM4
#@+h8exEX3TnYE/0++cQU2fPpZ8H9BFOovWmkQ0GuPqMzzVxX8y14nlKh7+KufucVykT/zqIKqAG9e
#@mY4CmHM3VKgBgbCf8z8vks7zH9Mwhf3Tef4d/JvDfyTPvPCcJSOAlAm9+tsmzeBfv3eoJSOA5NVD
#@3wIImhgCpKR2xw7Ahwv+aWf47ZQBYLXm81Yp3n+FDNIEqhXgZ6dW0Kggob+/K8D1m6kL+wsr/ned
#@CgClQSA9JBzZn61P5f8vbnqo1yqH99BD3epvpg3smGrj3u0zuO7h/fjxPZP41m1P4bNXbcVHLtqM
#@U85/DOu++RCO+eoDeOEX78Nrvv4Q3v7tR/GnP3gcn/7JNtzyyFRH8P/EG1diw2deji+/fQ1WjNe0
#@f68a+KEb+p/+O1pd1ygQLcemm4f3q1RgFIDiNS5JGAuTE8JUIsLG6F9JIa2ah6rPP0lj+CfN4Z+g
#@MfwT5vBP0hX8c/BvG/4TqqYvWBHp24dyEhCxDSTa/05z+E9LomNUuBFAIMV7wKm4bxW+bQJAX57v
#@BEKJg/+cRRwJCvw2GBDzGq0Axy8ThYey5MNtEKIsAqXWjAKXnOzhnVcHIBEqIHDmLW3ccJqHY5eJ
#@MvxbNAoDAugyGgAd50nHcHhkhv//9oomIJJFoCHUT860sWuqhR0HWtj1/2PnVAv7pv3ovckZHzv2
#@z+HArA9TpcH/L49fgY+/cQVWjlcR7XwCEAIUQMLl6FUEYLQcvpG5TqiO8zK6EKXWi84nAoyOPeOf
#@Jf9GapnxP9XP32RsQ/N/Kn939Fq40pvJ/vcJ3rCC4T1j2kcoBkHYUaRSqaJ8cYha/RW/Dknn+S/C
#@88+BDvuPRNLBv4P/DAOArhFAuib2voYCghDtG4jJTzeHf/UxKni/SNGGHQsQqne+WxPV98Gynhjt
#@SFztqV7VThX/e8tKQaNiOfy/xCKBJ6zx8NV1wOf/N8C8DraAD1zbws3vbWD5iMLrK6paAYpQdBX8
#@i3TI948Df7YB4FdbZxBXrSL4yo07sWOqhT0Hfew+1MKuqTZ2H2zjmXYAW1o+XsWZJ6zAyokakIRb
#@hQiBZBsBQimMABFxZ0E7U0Afn6cD+/Flxp//k2CfBvr0qhio9yI1KsCbVgLX70SkoN1CpVJ1N9eC
#@AIFUzBkcz38kEi7sP5mWYQz/dJ5/B/+G8J+WVzh8k5Yq7tsPfSfzhv9ye94TNCVP87QAKbXHvW34
#@V26f88N5/p0U8tutVP6/5q61UKCsqCKBZ73aw6kv9RDX5iniz6+bw1zA5ORUcIR+rQBo5KFnh7VL
#@Zsg7EsttAg9sn0Fcv9h0EP/8s1340a/24vqH92P9lmlsnZwrFP5FBOJ5qFQqqFZrqNbq8FIw+OS+
#@Obzr/I3YNeVDHdaP1LJAOs4VjfoL0M3tT0+PpFgusMifjWtN//p56yok5PuuHSBEH8rMAaH7dUgO
#@leefNId/gsbwTw605z8SSQf/Dv5jEnilVJ3PtdWgBSOAGIJtLvBvp+c9haVWVSetgmC0T+3Dv2Zq
#@uYN/p7hIBIGf2J3rVlC3+r+xpLD3JFoQzd9x/tsqOGaZJAF6R4Bzf95aAImikRMeSdAVmKYNAgK9
#@woA/Wr8Ph1pBQVAPePIs1FdDqK/VGqg3RtAYGcXIyBiaoxMYHVuMsfElGB1fEv49MroIjeY4Gs99
#@Hq4T18ann8Ep392IvTN+9Bt0C/5JAvh7MbQg0uGOo6Q/Uy9rAHb6cynoWjCVfqrN61cIJGEA8AG6
#@kKy4mBMgkBz0nP/073Ge/5zhn87z7+Bf8l/HK63qfC6tBi0YAQRGIgRkoTBURr/70o0AhEWJgXHF
#@AgQzPhz8H9Fq+23E9fIJYFldioF4W8YB7c8FN59Wx+KGIK7z72/jew+00oB+eG+wSJeFAVXwr67U
#@v3V/G1+8bge6kUAgXgXePNTXn4f6xmgI7hHUTzwL9UvRHH8W6ifCz+ojo6jVm6jWGqg87+EXz1M9
#@ZIbrVGt1xPXQzhm86zsbMTkbACJ6A5JlBOix4J/GcUyvp142OBf7+ZpSa3kdeNk4Emq7KIB+y/mP
#@RHCocv5Jc/in0Bj+SXP4J+kK/jn47zf4D+WVWnXeqPq6BSNADvA/L7JgCCRLCHcjSpEk0gLKlZhG
#@WdiHYM4PB+BHfPj/umUGYJBTSLL5q3TbnSACydEqcMu7a6h6grg+d/sc7tjmxzah8BybFgaM4F+V
#@HpBcPvvyrYlCfQLAq1ZRrTdCUK8/B/UhwDfHF2F0YgnCMbYIzXmob4RQH65TrdYiqM/xQg+NC9Vq
#@HXHdv30a77tgIw7NBeo2f0ngj+8jzX0KjWOl6AqgnQ4gPVTbF+Nz3/yaMzEeRPeOSEG77W6wz4s5
#@AQLJAcz5V/4e5/nPkG34J+Hg38E/AFHWAOjTHGgLRgBz+FfkuRfW677w/U7opgTYj/awn25hH8AJ
#@gK7NIGhjWOoAENe65SZgr6O+7WseAd9LF1fww3ckIbUVEB+6dhqbDgQ64K/IDReoUwEkE/7Vof97
#@cdMjBxBTCPPN5sSzwB169WvPQX0Ywu9JBQKBFYmEkQCVSg1x3bX5EE7/78cx2wYg2b9ZbQTQ6PUP
#@0ffyS1fL8fX7/1w3by+YqXXLBXH5QRtJufu2Xc9/FK04VNX+SXP4J2gM8qQ5/JM0hn86z7+D/4LW
#@8aCemz/0kAVU3M8fSAgawb9KZHEwRLIUGCNYMoCHoyQItWAIEEsPVS7sf2geYINU/n9VgD/IbP+n
#@kFUQyZon2sYJSYaIJz446cUVnP3aOuLaO0u8/8pDmJpjfLqqTWA49IFUAOjAP6Lv2TnVxrnXbENM
#@oee/Um+AQF8OiKA+Og4vZQS4/bEpfOD7G/GMz4yUB6iNAAkI1zW4qDo4LFwWxefJ92K1APTP7W7q
#@bvTh9Sl43XKgInHjoo+AtAzi9sWcCv6R7BUqXKs/5/l38O/g33gdTz3XkhFADL7Sct47Ib3/eyXX
#@QnYl5J4TBEsG8CIMPkadAwYbgsXig5c4q0KeClLh/69YBIxX89xz5YUiq99TQVUa4iQaX3x9HW9e
#@W0Vcj+wN8JEbDiFg117izO2l50lGKgAUBoHP/GQLJmeSof+NxthAZECPNMfgeRXE9dNHD+CsCzfD
#@J5Sh/8gI/ZcMwNeNwjBfVm0v+kjxbGkh9Sbnu+JENbyHpO4xrg6ALc+/2kFnH/5JGsM/aQ7/BI1B
#@njSHf5LG8M8c4J+kg38H/5nyFHPtGAHE5Cvt5r0TYqvivfkxk0LbKPaxwceiwaWPve9MD8fofS9f
#@Ef6vASHmXQLMwcf8e9UAh0tPaWLthIe4rt3Ywtd+Ma3ZFk4//1ySQHtY+L/wnr24+sH9iKs2Mgrx
#@PAyERNAIIwEqiOuK+/bhY5dsRoBOwN85z1/06zB0dfz0owAS27RwXudd5V9jm6o0AL/tcv9zAASC
#@zvPvPP/O8+/g3xr8E4CXPdeCESA3GCsChmgO/2qLZ2EiWQ4Eo3wAJsNhAUINogIGOO+eitEP8E/I
#@EZwEEIX/R/rdJciQbbA3CP9XvCqAL2EY8CC47fQJjNWQ0DfunMGlv3kGgEY9ACWQIlpMLqjh/+lD
#@bZx79XbEFbboq9UBcGCGiIQFCNNGix+v34tPXLoF1DACJP9O/NnlMVF/rp6jMiAoXg3SACxff5l6
#@9WIkFAR+mefTUHr+SeZS8I9k38A/SWP4Jxz8x8Uc4J+kg38H/x3OLcCzDiPkQMAQwWLAQ4ovckfS
#@GMbMUwKKTHkoqMuCuTFgGODfHHPLgH8XUgCmvHPHLco1/18tMfdAmr+ngL3Yx0tGgOveuwgVL3n+
#@fuyGKazf1Ya6HoByWeGlVqcCnHPFFjx9qIV5yfPF9QZRIoKR5jg88RDXD3/5ND5/9VZ16L86t787
#@Lz96iAJIL0Tbj0Zx569+vQCF8q0DcFw6BcD3caSKpYX9w3n+e4R/gsYgT5rDP0nn+Xfw38/wH8rr
#@8iAORAE0sphtE8wb/iORFoC0MBijBQjNq8tCsVEB9uHfsh+cmSP9WVeii/4PPXMEIi1vAKtHcjw1
#@FDnImbLR41z0C7q9alUF/3nSOEQQabYNfPCKSeyYolH+uGgUBozD5WX37cOV908irlp9JPSiD6rE
#@89AYG4ekjADfvuMpnHfzDoXXPzu3X0T3OBhGAWicS6X09VdLXQdA8rsGX9AEltbjaxEMApfz3yMg
#@EMwHKsi+gX+SxvBPOs9/3vBP0sG/g/8s+I/kxRbsGAGkCPotDgQJGsC//XZ36pt17tEAlrzvSiuu
#@NZEEQVdxX0PkwoFMo4FkGhGGX2rP3HET0u2poPY+moO6upifcR/1TMhOQ19i+vuOreNDr2oirp0H
#@A3zg8r2YabEbT3IkyfhMFQ2wZ7qNz165JRX6Xwl79w+6RDyMjI5DRBDXeTftwDdv3XU4r7/mvoUa
#@2KE3R5BO2dBIC9B7VacBoLDrS7HN9Hy1XjHBlLGx7Syu3f1n66r9l5DzT9AY5Elz+CdpDP90nn8H
#@/8XBfyQPvSnn6ucWjABiCrdSVLu7omUCoebbkrIhso8AWBZEBTj4d2H/xRgAFlPv2Sx6LchDqYQj
#@E6+/Cvr1owH+5cQxvHZNDXHdu6uNs2/c360XufP87BZ1UdX/3QfbifD5miL0fyAjAZrjCwD6y9dt
#@w3/8z1MZaRHa+1M/r19y8frH1zU5Z7UNCQLkHGHT23V43OJ0sVHfsX0PUEEyF6gg2TfwT9IY/knn
#@+Xdh/w7+S4T/SJ61nvNiTL/W2u0RUmjROzIcpUBopDKiAcSiNxmWJYdNEXDw7+DfJAUg1QJQ6bGM
#@JIXk/5eZEqCekAY/icHfvK4/fQlWjXqI68IHZ/Dvdx1Mb0wFltmh/9IBJEVw7a8P4PIN+xBT6Pn3
#@vAqGSV6lEtYESB+gL1yzFd+/aw8gHQw3kp0KoAb9rkk8+h5ReP0jSQ+Q34/XmLoGQfpe4uoAzEvs
#@QgVJ5/nP/D00BnnSHP5JGsM/cwB5kg7+Hfwr4R8QeHZvohaMAJIfeBAsEMRK6XdfnhdaIkOAnfPN
#@Zni4dF0vwMF/3vBPG8NWBMB8/24BJEfYN8//1wd7g/B/jWiAxLpVT3DbGctRryYn/d2t+3H9xtnk
#@9+mnBSi92XunfZx92WbE5XlV1GoNRBo2I8Do2IKgv3MufxKXbdin9vLrh/tre/3Vyfyq7+utG0Ba
#@UnQdAPNrMTqHj83oBFCaaGPkD/8khy7sn6Ax/JPO8+88/w7+bcA/AHgwFGkAwWUbASR38Oi66qj9
#@fvcWjABiLwUBUliERcHHnfHh4N/AuzDsYhAkHkUW18LiXUZSA4w5YKihSQyq/x9uxSwoBNaMebj0
#@PUsT+eoBgb/+yR48vLt1WMAU/TaBoT535VbsmmohUlj1vxm+Dqu8ShX1VE0APyDOunATrntoUrvN
#@n+hCvdpgkJ3rrz7hDLoBqGpapObn2+bPWC9qAmNVIBIJks7zXzL8k3Se/4x1CJqDPIcH/kk6+Hfw
#@r4J/gxQAE4AUY/K11m6PkN7b3wmMRBbOTMWFoYv2Pit42xYMAVJINwHn+Xfwn1C6KvdRozAsAJgb
#@7BdYoTzN5Lrh/51p7Q1r6/jSmyYQ18E54v0X7cae6aBDiHn3bQJv+M0BXHTPHsRVqzVCL/mwq1Kp
#@hjUO4g+9LZ8444ebcNMjU3r7UR/qo2VNr79+GkD0VQV32si9Hkdv1/FRzeQMBr7LuzqCC/6RNIZ/
#@crg8/ySM4Z/O8+/gvyT4jwwApRgBxJh8rbXbI0RzHgvsdV8KhBYYfl6yIUAMigWWuX3z6AAH/0e4
#@AqYNANIlcBTl2c8d9tXbEGTAXnfRAJ88fhzvOqaJuDbvb+OvrtiNdsBM0JQuCtEdmA1wzmVPLgiP
#@r9UbOFJUrdbQSBU6nGsHOOMHj+PnTxxM7TetKIBivP6SXlDUGJAi6gAUESnQm0HuqLF0J4DA3Xh1
#@oILMBSpIOM9/dgSuC/t38O/gXx/+CzEAqOFRjMnXWrs9Qnqvei8W+tznGH5uJLHYmUBM9q9F+Dc3
#@CDjPP1wEwFGjhEKWQEJfIt16RCUaesCvnnvBKctwzIoa4rr1iVmce9PeXkLNE/rcVVuwbXIuMaEe
#@ecSPHFWqtfB3xzXdCvD+Cx7H3Vunu92/Jl7/1FzRnqsf8aJ9eG0a7tJSRhWRzgCg2GlD3eqPpDH8
#@k/3j+SfN4Z+kMfwzB5An6eDfwb/2Ol4BMJL/gzlZXrs9c69j4RXvyVIgNOfc85KiASTPHvQDlncv
#@C6IDHPwfAQroI661o9IdMBgUHTOGfWX+v4ZE+Q9RhP+rIfKWM1Zh8Uhy8n/98gC+d/eB9Oa1vf+3
#@PnoQP16fCv1v2Kn6TzC6yRGEDVVr9QVGgKlnfJz6ncdw3/aZw0cB6BkIDNIAFHOVVK9TByCXSAH9
#@opyGBr21zXQngMDBP9RvkcwFKkgOEfznF/ZP0Hn+neffwb8W/GfLY0EeSfswZAbShFiA57TMQ8Ls
#@Fnks2RAgAGAx6kL6uc1gNBz8D5noM+WtM+oAUJjxQETvO82fDyNIVK+sCCMfrXv46V+sQdUTxPXZ
#@65/GHZtn9ToNSBJsP37JJpDJHvnV2kgpEUJB4MP32/BbLSDwsXhiDCtXLHl2hH8j8MPPfL8dzgVZ
#@nhGg0URc+2d9nPbdx/HIU7P6ffn1IV9/LhJzNZ55zYFbCoF4804AR4/S1QCw4PkfxrB/sn9y/glz
#@+CdpDP/MAeRJOvh38K+9ThQBwEHoPU4WlP+tBI/BMwJIYSHmpR9zggZdFko1BNiHf30NhEGAQ9FR
#@qhSFwJYyAOioxDSB3NsEqvP/czIOvHRpHT94zyoASBasu2gHNu2bW/gViloAX7h6G7akQv8bzbFi
#@I//JEOgrInjNK38Hp5/2Dpx7zpn4xlf+Bv/H3nlAyVHd6f77357pSQqjRBKKJgiLIEBkiyQQMkEL
#@tlljEwzeBfywDevnXeNn3tqsE9iLgcVrg7EBAw9jDAusEUaIIJAJhiWaJECgiAhKSJrRpK76nk4d
#@q05Nne5STd9bfbt77tfnHqm6um91V+ip3z/+5F+/gR//338Kxk+++w1c8YN/CdZ94ZTZ2GfqbhBB
#@8F6QyFoN+aYgEiKqNZ19OPnGd7B0XS/iof1RSeaQH6p0ioDpNn/mw/u1tXObxOuO1GcXQKPtlfWh
#@gmTVwD9J257/UASd5995/h38p4f/5BQAZhCKbFwZQSipA//2jQBkpSCYVgCYoE34T04PsA//2iJZ
#@bDjPfw2I7N8CsDUHjG7SKjimJ/2K4yl6racDs1BSFB7jzFc0GmD2ri246NB2RLWuy8Npv1uFTT0s
#@PndsceHiTbjlf9YgqsZ8dqH/JAJ4HzakBZ85YSZ+dMnXcfGF/4Dzv/T3+MLnTsTJxx+L2cccjmOO
#@ODQYs2cejlNOOBZf3LLu/LM/H7x2y3u2vPdoDG1rCeYikaka8y2BISCqVRv6cPIN72LVxmgbRpRq
#@/5fW659w/ONzI7mWxADPVdHrzKEvKX/1Ds1Ai0L8D6Hz/FuA/1ou+EdWT7V/Uh/+SWrDPw2APEkH
#@/w7+B3ydKuNeN8kYfjOCUDKzSuMVgSlWtuBcxWGMYEZdFnTPmRqDf33DgIP/Kg6VGNNcfriwWPc0
#@JoO+IK5EqA8XZFs3tJIMdJcePQIzJrYgqjdX9+J/3bMKPgGgNEh29hEX3r0cjIf+55szigbxoYQ4
#@fuZhuPTir+HcM0/FySfOwqEH7ofJE8dj2NAhUEohpuC5oUOHBK857KD9cfIJs/CPZ5yK7118AWYf
#@fRgUmHXl9yAVoKGxCVEtXdeDY659C8vW9yafjHGDgOYxFyAxxSPyZHpmEsuROSG/lMdYo5sEUZF0
#@ZQCMQ0V1VvsnadvzH4qg8/w7z7+DfwNGOmUUJKVC8MssQFAAZg9TmUhSWFft13kwbwgQ2JVoFA3U
#@lcCaWPrh4N9CBEBUIxuRTtWZa2zkGkif/58eFO89fSeMG96IqOa+0YHLF6wumou+Vd/903tYurYH
#@EQUt8ERgXL5XwJiR7fjfF5yFL5/+2cDLP3WPXdHclMdA1dLchD0/uRuOP/ZI/MPpn9ky55kYPWJY
#@sI0slW9uCeoC9I8EKGDavy/C0dcuxqsf9pqA/FApUwQMwZz12hxa32FEnvE0AAf/MRE0AhUk667V
#@H1k9ff5Jffgn6eDfwX8twn8olTmQVMIIIAY/PCsDztns98qCKKFr1LC/bf39bmH/V3HKASOPhKXB
#@A//MdtAnohqZ14ELG8YDXcNBwloxZxxQOeCxc8ehrVEQ1b8/vgZ3vbKh6DzPLOvATX9Zg4gCD7dS
#@DcbPA8/zMGn8WHzzq2fhxOOOwoH77xNAvKaCOQ6aPi2Y85+/djYmjhsLr+Blek7nm1qRixkBCOCF
#@lV2Y8Z9vYfrVb2PB4o7Q4CIJUSDakC8lFzRA3hbE611rI/MxAPJpIyHfvmRwFfwjYdvzH4pgXXn+
#@aQDkSTj4d/BflpFOGQknF0th8KRJ+LdvBDC23ysKoRZyxi1vWzRaCdYd/OtHEfhASYNB+Jwkxh3E
#@TAvEYJEfjwDICxIl2u3G7KcJJOdl63v8BUU1si2HP50zHjnV/zr/+j3v4YX3uvrNs7lAfOUPy+GT
#@0dD/INc9C8//5PFj8fXzTscxRxwWQLppTRy/czD3heefjknjd8o8EqCpqaXk7+riNT045eZl2O3y
#@t3DLCx+nLe6oHRGQXG/Ceni/fntOGVgEAEgXghURSSNQQbJePP+hSPue/xBIqQ//JJ3n38F/TcM/
#@IFDaOeVi2ftNZkTQyDwlIHsIrXzLOQD1bQgQncKBDv5d2L9hkYk36aGkGjz+hrz9MqCboLQe/1RQ
#@uPdOTbjihO37vaCrjzj9tmVYtbEQPv/9eauwJB7639QKEfM5/2NGj8T5Z38OMw6eHvw/IwVzH37I
#@AfjKOadi1Mj2YNs2/z5+1FnAhfe+j/GXvYWfPL4GPlMZe/R7/EvCjaqZ8H4NGb7ekyIASBf2/zcR
#@puAfVQX/JG17/kMRrKucfxoAeYIO/h38l22kU1qF5aRKvN9kRn8hq9QIIAOGT3MS2yBucftisouA
#@g38H//oimRwBIMheNmBGH/RiHuP0YeFnT2/HOVtGVO9vLODs25ehp+Dj2eWd+PXTRUL/cw3GbT85
#@JTj7C3+HQw7YF9uNGYVQGRoBDp4+Ded88eRg2yQykU/23+6QBoxvz6OYNnb7uHzBWoy9bDG+ef9H
#@6C74ZRxfDcOQHYjPXpIcAUD67gfY9fnf5nvI6vD8AwDpCv45+Hfwv1WqbP6VKvN+kxk2Tq8iYJUM
#@OihaiPaoOUOAZNlS0MF/ym27IgCxQfgJN+maIcUaXnsjXCQ6f8glcYoU6QCJ9xhXzdkB++7Ugqie
#@Xb4ZF969EhfctRyeT2yVEoXGpmbjx973+zDrqINx4H57BSH6ldKkCeNwwJZtzjz8wOAzADQ//AKi
#@OnhCG1761hTcftZE7De2BcXU3efjxuc2YNxlS3DmnR9gdZef8kZRkHyGiNbNnr6dy8I1nCICALTQ
#@lb8KRRq6zSSrCv5J2vb8h6Kwajz/JLXhnwbgn6SDfwf/WkY6VRb/SpV6v0lTRFOddQHEBHBWMvSd
#@9WEIEGQucutw8O88/wOQT0Q1vFEshfzrSxK2L+a8cca8vvPPm4gxbQ2I6o6X1mPx6h5E1djcAoFh
#@kWgfNhTHHf0p7DV1Ciqtvbdsc/YxMzB86JBMcs382Hk9cVQTlCh8esowPHrBLph37iTM3n0oiqlA
#@Yu6iTuz+s6U49sZVeGN1b0I0iD7kx5U8vSWJ/nuHN9K1AYyLcJ7/RFi27/nfKtJ5/h38O/iPStVd
#@HjKpMYFtCGQFtq8bfj7IDAFix6MQDACkg3+n0iKIqJqUzg60DxrZu0sFgJm878acYOFXJyPfIIgq
#@HvqfyzXAtDzfw9GHH4TdPjEpqNRfabW2NGO3yRNx9IyDgs9iWozNOSlsbyFhRMDvzxyPP18wGaft
#@MxwNShAXATy3qgeHXv8+9v3le1iwpFv7+Ouft7WaEiBoiu9jcQYAU1BBsqrgn2RVeP4hAMGqyfkn
#@qQ3/NAD/JB38O/jXNtIppBTN/wHKLvSdtAT/+iJZqfDzdBILx9uCIaCajV3k1uHg3ymuOJTWLGCY
#@nUN0gp7Tr99xWCP+6+xJEBHEpUQh32QezkmisaEBB++/Nz4xeQJsaZdPTMTB0/cOPgvITGsATBzV
#@XLR2w147NuO6z+6E5y+ahPMPGoHWosYYYunHBXzm9x9h92tW4bZXujRuMAV6ql0DXT5H1wQgItLY
#@zq9L+Cete/5Dkc7z7+DfwX/5EQACsJZC30lD8G8ZUiVrT3Ol895ZVYYAkjUV6UJGRy3BPxz8V+Au
#@NK/q0vNvtqCAmKsHAAhmTGrDpbN2QFy5fD6Tk5rwsecnd8X4cTuhuSkPW2ppbgo+wyenfAI+CJMi
#@PUQ1eVQ+8SZ/Qnsel396O7z8jUn49pEjMaIlV6JzgIev3b8O4676AD/680b4vi6kWLlerCivBFGJ
#@SwEwAxVgnYT9m2/1R6Bqqv2T1IZ/Ovh38G8f/kOpAXsjayn0ndSFf6siaM+SLRY88XaNATWZd09W
#@f5tBOrKvmBoFFZVYWKfxLo2b1uR1Fx0xBgdPbENUzKhNHn1iyi4TseP2Y2BbO2w3BlN2mQT6NGuY
#@jsyXU4Kxw/OpjDej2xpw8RGj8MpFE3DZcaOx87AGFFNHr48rnu7E2P/4EP80f1PQOUDnfLJ/LWSv
#@vBBRUZzdVUNVCf8kjcA/ad3zH4qsL88/SQf/Dv6NXKcq/aQWjACiDx4ka7kFT8UgmSwVsjXIDAFg
#@TUdBk/Hhwv4HVQ2AHAYusdCz3LoFwjxifevo7RGVVygAIIzLJyZPGIdRI0fAtrYbPRKfmDQOMGns
#@oI+odh6eD+otDERteYWvHDgcL3x1HK6dMwZ7jGlEMXUXiJv/uhnjrlmLM/+4EWu7LRJ4phHl+szT
#@qMQVAQRAuoJ/yTID/wSrps8/SW34p/P8O/i3DP9xqXSTWjACiDnwIFlj8G8vd571AN/6RpdwVBv8
#@6xsFHPzXk4TxMN0a2tViYSJNScI2Z0weghGtDf36pPueD9PK5RRGjx6BIW2tsK22tlaMHjUCqkHB
#@lPx4AcDR+RQ3VUVXB4aD0/Zqw1Pn7YQHztwes3dpQTEVfGLu2z3Y7dq1OOmuDXj340JlzjmpnUsy
#@n6OrAWgMKhLu6yzBP0kjUEFY9/yHIusr55+kg38H/8aMdGrbk1owAoh58CBZI/Bv0VMuUWC0BN/g
#@YNzvFRUZ7zTg4L9eIgDybp/GJJlOGYfNT+8xDFEVCr3Gj/ewYUPQ1toCpRRsSykVfJZhQ4aAzCYa
#@cFJQAFC0D/PB45pw+6mj8dg52+PzU1uQU1K0+OATKwqY/tuNOPjWTXh8ecFdQuFviyAqCjHYRGPw
#@X4bnHxY8/5bgn6Btz38oktrwT+f5d/BfVfCfFAEgFj3GApDUBI9EmKsp+I+LZIW2ba/qPBE8qm2/
#@h0NDVd5pID4c/NealNuvGcdQJ2vOXsMRlef1GY/4aGrKo6GhAVWi4LM0N+chwkwiACaOzBs9zPts
#@34jrThyJ5/5xDM7frw0tjcXva95c5+GUezqx5w0duOutPgx25QT9RQwqkfUb9k/Scti/+feQ9VXt
#@n6SDfwf/Rq9TZeLGh5kACTXAw2arvexBkGSFq85X6ntbMASInboF9uG/zPSBvw2ytuCfIEgLA8h0
#@xG9Men2H9TZ11C5DMTRSiIE+4XkFg8e8OkWTw49FAIxsRhaa2N6Ay2cOw8vnjcG3D21De7NCMa3q
#@9HHeg90Yf30nfvxMDwarenz0k0Cy/n2z9JtNhMoAKkjWZc4/aQbkCdr2/Ici6Vr9OfivS/gHBCq2
#@0l7uuOiBLiEW6g0MHgglg2EHQrMyBIixVoJ1AP/6tQV89tsnzvNfCVEQVZ/vEnPTi8b/oDU1KMze
#@Y3iRYoBmRBF09/SiEM5pXcFn6enuBSkwIZ+GIwCYvHJMq8LFh7bh1fNG4rKj2jB2qCrROYC44rkC
#@xv6qC994vA/dBQwq9flwXQBQfwX/SNaL5z+Uz+rx/NMA/JN08O/g3/h1qqq/7zk14N94vYFqhNAK
#@Gx4sGj0QPCxsX8MYULXwnz1KkYyM/l54BCOyHg5cTVQB7PXdXXl/seJTztkzuzQAAbBxYwc6N3fB
#@933Ylu/7wWfZ0NEBkWy6AEwc1QSAmR/mtkbBV/ZtwQvntOPa44ZgyqgciqnLI25+vYAJN/TirPkF
#@rO/GoFCPxxgbieP7AQICybqEf9IMyBO06fmPz+M8/w7+6xX+AymTUEALee+EaNcbsCax2EpPdD2/
#@Fo0eCB4Wtq9lDKh/+Ne/zosOlFpGfBl/W8agkUBiYbpEKbFu2ZwWPjJLvmDm7sPQ1qgiPOsHee2m
#@5Hk+Vq9Zh87OzbCtjo7O4LOY6nZA3weJUKPaGjCsOYfkw0yjZ0E+JzhtjzyeOmMofjenFQftmCvh
#@ESfmvutj11v6MGeuh6UbiQGLtXNJ9lAQlbPZ6sA/XKu/DN5DAGT15PzTAPyTdPDv4D+T61SZhgJW
#@MO+dEFP1BmoRxqx3OiDtfm8ieNiH4HRQ6+DfybwE+hEABFh+BLVdUXcdjX+51kaFmVOGxdIA+oxW
#@elyybCVWr10H21q9dj3eWboCIgomRPqIalLo/c/wBEnIVpo9sREPnNqGR09rw+d3b0BOiocbP7GK
#@2O8OD0f8VwHPf8SqzmBhmad2b9y4KO6HvZb7/JM0AhWkGZAnWBWef4iApPP8O/ivV/gPpUjWDBSQ
#@NAz/oeqo5zsrHPoeDMsQShBVH3ofNQY4+HcyJas1AGh/nXmQZ2yhjHVz9mpHVH6fwTQApfD6W+/i
#@/Q9Xw7be//AjLHp7CaDEVEpBLP+/CcmHkinX6Z3Z08YoXHtsM549vRXn7dWA5gYU1avrgFl/9LD/
#@HQXcv8y3cC1kpx6XXlQGIMTvy8R5/jOEf7J6qv3TAPyTdPDv4D+z61RlBb/MLPychuDfkhFAkLWs
#@hJ+TwbD7vRE8qhD+EyMDHPw7GUsB6KXUXjg/s32fPihywOs+vUc7mhsl4iX24XseTEhB8Oobi7Fs
#@xSp0dffAkoJtr1j5Pl5b9I65UMIiEQBJ0RvJ6/QNO3FNGi64fEYjXj69GRdPz2F4XlBMyzYBX3rY
#@x6RbCrjsBc/09WJF8QgAcREAKeEfVQf/BI1ABWk77N98qz+SzvPv4L+e4T+UyhJ+mUn+t4CkhT77
#@tQD/9jsdkMGw+70jDwvb1819d/DvlFoUiVUqtwMW+qLZOajtT02/nkR8fVte4ahdhyMq31QxQBEU
#@PA/PPP9XvLtkOWxp8TtL8dRzLwefBYZg0C9aADAuAsziWKY3HIxpBS6e3oBXzmjEZYflsGMbiqqj
#@D7jyJQaGgEue8f9WSZ81eZltLrjf+IEDgoP/bYE8QSPwT1ZPn38agH+SDv4d/GcaoaOyhl+ahf/y
#@P6tkWFSveoHIWoV1sjpuEigWK8yLdt0AB/9xOeNDPykRRLW+l5YBo0LvZbkFDVjmuoF7lU/asx1R
#@FQzWAcipHB5d+AzefGeJlSiAzV3dwbYXLHw2+CymRC8WATAyn2DksX/8hzQC509VePG0HH55ZA67
#@tQuKqbMA/Pp1HxNu9fDlBT7Wd9eegW5tjzgLwAABgaQr+Jf6Pfbhn6Tz/Dv4r3f4D6Uq4QGnGfiv
#@eNE7krUPJGKv0CEBkLAnMdM5wH6Hh3A4+HfwnxiGu7ZXaizEOH30dnpRYwNMER7ORAANBokTprYj
#@39CvG0AwjEgEH2/qwLxHnsBfX30DldZfX1uEeQ8/EbT/i3nPzEYAjGwOIywGdNyImFhGKkdU3Gbn
#@gM/vKnjyczn8v1kKB2wvKKaCT9y/jPjkHzx85kEPKzpqxzD3cV88BUC5EKxk+K+6nH+SRqCCNAPy
#@BGE/7N8syNMA/JN08O/gP3MjnapUGDypCf/JgGShz37NwH98X1UevmnBECCJ6QG1XOQxOhz8V72Y
#@7YhHAPTRXJExvSrj+hxCfcinVrpAAnMyAUiJQMObFWZMHhKLAug1duyVyuGhx57Csy+8gqXLV6JS
#@enfp8i3bfBkPL/xL8BkAGhp+9KQLaijsMCyHQEzy+BMEtOsBxMUyjANKgNnjFR44KYf7T8xh1jgF
#@QfHOAU99ABxwt4eZ93l4cU3S9Hau4bjW9QqiUpL575sL+3ee/22em4QZ+CfpPP8O/gcN/ENCA4B1
#@I4Bun/9MYYhkLcN/XBUuPGfBECBl1AnQlv02gwSd5x+DOwJgXV/1t+nTn8Og15epcvvLjgiYs9eI
#@WB2AgsFjD/g+cdPv7sHT//MiPvxoLTJW0PP/6edexo2/uxc+adL5H3yXqMaPaIISSeHx1zy++tEg
#@Rec4aHvBbccqLDwlh7N2V2jKCYrp9fXA8Q94OOQeDw+trN5rd32vawOYViSqDv5JGoEK0hTIs148
#@/6FoAP5JOPh38J85/IcRANVqBCDEQtE77X1RS4XnLG07GNlINLoH1EeqR3w4+B9EBoD1vRmAOC33
#@LI8vUC/v23zYP0qGqZ84tR0NSiIGAA+kb7Ql4Jp1H+O6m/6AJ555LgD0rPTR6rV4/Klncf1v78C6
#@dRuglIJJ0fcQ1eRRzSXTKwCYTAfQrwfA0oElU0YIrjhU4flTc/iXaQpDG1FUyzqALz3mYZ+7fNz6
#@tm835L94BIBLAYhKBhP8V2e1f9IM/JOsEs+/g38H/5nDfygFCyK14T8Z1CVTb2tNw39cJC1u2zII
#@akQF1NIxJxkfDv7rRukMAKGoW1+PeiBPmBdjUKfnMR4w5IOl5iFGteVwyKQhiMor9MGkVC6HJcvf
#@w1XX3oL5C57AkmUrMgn7f/jxp/Dz62/bsq1VwTZNi348/z8f7seEfZ7SOKAb0RHfDgas7VqAf56m
#@8NLf5/CDAxV2aEVRre4mvv0ssfudHr7/go9eP+01Rr3UGyJR6/voAgA0AKEewv5JM/BP0LDn3z78
#@0wD8kw7+HfxnDv/hgrLVFo/Ug//0hU7Mi2Q9wH8cEC1tOxj2QFAjKqDGj3l8uJz/WiwBkGAASAHk
#@9iMCWJYxQaOnf5keZBaDrWBs88P/XSwNwOsrGD8PlMph+Yr38bNf3IT7HnwMf3nupaBSv4Fq/8Fc
#@c+cvwE9/fiOWLHsv2BYI44MkopoUbQHI0n88GF9JjQiOgZxsTH++xjsHnLuH4JlTFK75lMIuw0u3
#@ELx+EbHbnR7OfcLHxl7da1LvWlvfK+gvVWclAPThn2TVwT/JuoR/0nrYfyg6z7+D/xqD/zACwJ4R
#@wDj8h7JgBKgiENSCQkvbDkb1Fd2LPGoD/vWPv0+A/Ybz/FetRGJhukCfbwfi9UGeGuSiDflFxIF5
#@jVnk9UTQDSCay+77XujtNh0JsHbdRlz1y5txw6134YGHH8crr71ZVpvALe8J3vunhx7Db265E1f+
#@4lasX78xC89/dL/EIwCKRVVoHjs944D+dcTwPU05wamTBY+flMPNRynsP7pU5wBg3gpir3s8nPGY
#@jw+6AND0dZysHg/Y4CIAtgX/ruBfsqou559k1YT9Ew7+HfxXDv5DA4BdI4Bp+LdgBKg/ELS47WBU
#@JQgy8qiPY57eAEdGRr9lB/+2awCIknDZI/B+N9KLBiqNV8iowKLPMOEpBoNZQH5cLD3vjsMaMH18
#@G6Ly/AKykCgFn4J5jz6F7132C/zm1rtw79z5ePKZ5/Hu0hXYtKkDvu8jpuC5jRs34Z0ly4PX3nPf
#@fFx/65249PJf4MEFT4OQYO5M5cciAEbmU4b/w7hxgMWMA9z2+ccyDGVKgFk7C+6brXDvLIVjx0rJ
#@zgELPyAO/KOH2fM9vLJOs0MHkVqruvsfHhHlfohjqkb4J2EEKkgz8E/QCPyT1j3/oeg8/w7+axD+
#@QwOAfSOAKfi3YgSoTxAkg2EHxFLCpcCaKKExoG7hP72hLc1w8J+VRHKIakVXGSBvGOKpH94fh6dy
#@87IT8siTIB8aXv9iaQDtsToAhUyDQnK5HDo6N+Pu+x/Bd354DS6/+je49sbbcdtd9+HuufMx75GF
#@eOixJ7FlBJECd983P1h33U23b3ntr3HJj67Bvfc/io7OrmAuEWQswqff7zuMG9FU6jgNDPiJEq9N
#@rN9Qfr2J8N+Bn/cHbif47ZEKDx2v8NlJgkaFonr9Y+DEhz3M+JOHR1chnVj+6uWbiahEifP8Iwqk
#@rEb4d55/kRRsYL/gH+ng38F/peBfowggyUzAg8y24n1mkhCW69ITStJiukOVhqBLQmRAfcO/hlIa
#@CaLLKPEvUZZoYVRC8VZpKzoJbTEdtOiDR5nbYUowIzQqyScbBFgcHou8l4EBQKR/O8Ds27FKAO8k
#@8fLrb+GOe+fhRz/7Fb75rz/Fty79GS754dX4zg+uxsX/diW++d2f4sdXXr/lNQ/i5dfeBsngvRrk
#@r3VfsdOwRrQ0xI9DEY97MvBrdXAAUxqaqH8+x7VHu+A/DlH480kKX95N0JorAeadwJef9DD9Ph+3
#@L8kuMmflZkFUSnLQUH38ZofwX99h/6QZ+KfQCPyT1j3/oeg8/w7+aw7+NbsAkMwEPAY8rWiBrHkQ
#@JG3Cf12nO5DBqP6K+wgfDv6z/O5xgwBj58lgkihEtbJLwh2kDSQ0BxGkuTmZEeSnf20RuEwAw53b
#@85g2thVR+YU+VEQiUKKgVA65hkaI5LBhUyc+Wr0eq9es3/L/zRAJ1gWvUUpVPMHbj3cAGNVc2tDD
#@2AKZAPzZGwdoMOWFscl2bhX82/4Kz52cw6X7qaCTQDGt6SG+87yPPf/bx5Wv+fAN1+ZYEYsAgFKu
#@+0qg6oR/kg7+UzOM3VZ/pIN/B/8Vhf9QSg8IzYMHmXn184x7wLJuc6BJgiBsiqid3HMifDj4d8pM
#@SsUiADYzM4gH9duNJeckcyBzpYb88DNTwyBQjAOJkl7/+PKcPdsRVcHrs4gvAkgwIIB9xQ0AIxqT
#@AZ8EE45POcAfTj0g40CyGF9i9L/pNbQRQSTAkycoXHWQwqShKKrOAvCfi4Cp/+3jkheBroKZGhwr
#@u9BPyvUADOSD1Qj/Luwf2YM8neffwX9twn8opRX6DmYAHtnnfpOsSN91fVVn6Lv9lAcL3l4xVkDQ
#@wb/L+TcrlYuH61Y+vJ+6cyVHCiRDE8ORDPmMjDIMAnEwTAWgpdsB+p4H0nfnLwCffrwFYML+1T1W
#@8fkYHalfGxcT6gBQv8FF2DngsxMEj87O4YbDFKaNLF21//dLfew918cXn/DxfrdeAc+4AUCUcp5/
#@sq6r/ZNm4J+gEfgnzcA/Sdue/1Ckg38H/1bgP5DSPoFBDfCwl/tNMnMgIVln8F+dKQ9kMGoGQtn/
#@4eDfSUtKFKJa3kXd8H79TgBEomgi5J/bgnwM0CBAoAyvMsFUUQCTR+UxdccWROV5nqucTsDzCrEW
#@gI3J3n/N45Ye+JH8WuqnBHCgaQIAlADH7CS4d2YOdx2pMHPH0p0DnlkDzJjn46QFPl7/uDzD3crN
#@cc4SF/ZfhfBP0hD8O89/ImA7z7+D/9qF/1DKCAiCGuCRLNJ2uzu97ZOsR/iPRzvY2n72hgCpaHtB
#@B//O+FBWK0BA+oUBf9SNkmJZ1fsNtRyjWaNAMuQTAPXSAFKBZvrlOVPbNeoA1J0C8O/p6gBjKQDN
#@DSphP6YGfM3w/4SWj8wA9llea87powW/OUzwx5kKJ4wT5ARF9cZG4OSFPo5/jHh2rZ/6c33QDWz2
#@YgkkogZ3qz+yBuDfftg/ASPwT5qBf5K2Pf+hSAf/Dv6twH8oZQwEQdPwH4rMtN1dxkASQnIdwL8F
#@Q4DoVJuvPQhl9EE6+HdKJaUUonqzAxpKDF82HykwwDoATEgBCGXc6x9bSaaIAijeDQDxCAASg0wB
#@8Pf2dKG3e3PRNIhH3t4EIK33Pw74pqMBEs611OcpE855Myk5e7YDPz9Q8MgswemTBc254n8b395I
#@nPEU8KmHfNy9EtvUG5sYyzga3PBPsh7D/kOR1ez5tw//dJ5/B/91AP8QQJk8gQlqwr9+n0x9QLeQ
#@dlAT8G/BECCmugfULoSSjA4H/+WKVkbFpHI5RLVoI811AkAxzyRNRgqkrwOQHFGQtkJ/MtRrAWa4
#@XNQQMGW7Juw6prnfiz2vb1CF+xf6egKvv5cQ/fDkux2lajWEywaPZfpOA6HSn5uk9vWQvigngfFt
#@gu/vI3hituCiKYL2PIopiBL6Py/52G+ej6vf9OGX6ADw5gZBVKJyqJhoZaSHf5iCf2hBBcmqK/hH
#@0Aj8k7bD/s23+iMd/Dv4twr/gZTxvHfQNPyHIivZi9h+2oF9+K+fqAcygw4T9g0CDv6ditYBeHOj
#@JMMKzBcCpHZNgWQx8bmUaQCJMBcqAfRLAyVjy2Bsv3NrMcDhiIfBDwIFho7erg709faASNaSdb1F
#@DSnktrotoIzjymCkC/9PP3UoS9fYiLzg61MEC49T+OE+ggltpTsHXLcY2Heej++9CvR46Ke3Opj4
#@W1P/qt8+/3GR9Qn/JI3AP53n38F/ncA/IFCZeIFBw/BvyQggmUJczcG//ne1D4JkOOoCQknGh4P/
#@Qai4V25RB5NvXmm2EGByTYH02yTKei6N1z/+XHpPcXw5Vbh/6XVzpg5HVH5gACDqVaSP3u6uYPj0
#@Ede+Y1sx99xdkI+Elvd5xMurura9P6Fx/FgkbYSpogG0ztnk69B8PY7WHHDaRMH8mQq/Okiwd3vp
#@zgF/WO5j+nwfF75IrO1FoEWbEqKNBpEIViX8kzQE/67gX4ae/1Ckg38H//bhHwAayIRrSXR/LFVm
#@Vd9FsoUqUVIReBORGoJ/fcOKiFQNCJIIJVI/EEqyH/yLOPivd8Xzcpd1Al0+0KJK/6GTEisogBCA
#@hC8MX59urvSv7yoAvT7C+6wuD+jxufXMDaCk2w/P4eDf7gLR7SG8d+z2iB5PABAQQZcXrA/fEMwR
#@LAu2ThQ8V5Bwkq4Cg+ciy+Ec4Tx9RLfHcLmrj+gpEFsVzFFAqO6CH3zWqDZ0eyARVbDc292NxnwT
#@RKn6qu5f6AlC/kkgrpGtDfjWzB1w3iGjoABMG9uMZ5dvxlbd/sJ67HP8DuEyyykKiHSvYdwotK1o
#@AA7kX24T7InSon6djfBu7OjtBUdtJ3h+HXH9YmDBh0RcBQIPfUA8vGVMawdWbE6oNzJYRF2QtwD/
#@lvr8EzQC/6QZ+CdpBP7pPP8O/usH/gM1lARqMVFsjBCIxu+iJSOAxIA1eyNAPcC/viFAYE1EyA91
#@IyK5OrCIOPivGwlEVFhQzSNw/TtEW67/fcymAsDIvt9cIDwKtqrX5/9n79xi5arKOP7/9uyZOde2
#@p8fSHkrPacuhWFqQS4hpi0KkBHkQL4lykQcSbm/gA1JMQPuqkogPisaYkHjBGB9QCIkaFQKCQaEn
#@KgGxRQKCBNpa23PmPvtvu+NZmVnuWeyZvfesOdP1T1b2XjNrZt9m73N+3/et70M5UH0EJBYbaNNi
#@HQgIpXIA1JqiLmeNRKkBJRI4XndX6P3C45vlOjwvh5yfh3+yQWRFH0+jWo30+Pue4KZLp/Hlq2ew
#@djSnAHvPlok2A8BT/yip90jdc99jH4mjAZJ7/TOb/x+/0sYlawXfuRT4yzHB9w4xBP4gwihx4Bja
#@JOKddg/t5Jw/+FBBWoB/C55/2/BPOvh38G8d/pV8DajTg3+1TkhPO2rJCCAGQM8aij0ZZhAzGwIE
#@9iSGqIAVDP9m6YncLNR4FgB08JeWxPPAZqD63z2EmCeYCbEF7kKmpCBoIqg10ahX4Hl55PInW85f
#@UeH+9WqlY16DXVsm8MC1m7BjZgRog3pg9+YxfOMpKL12pKrDfHflF4FY4/m+4f6Mkf0/yWuG8P+M
#@c2ycvwb45sWCN0qC7x8iHn0rjITpKMl57ia16/lXIpkR/NsP+yfTgX8SvcG/q/Pv4H944V/JM9ws
#@qYEHwaxLvqUjSZq4L3nUgRWJ5TnsIKxJ4uQLGD74Nx83OzXn+R/MNNYOwFeYJGydRYZe9LBMXqV8
#@AvVaBQyaADiQjWBotKiWlyLhf/2kj4eu24wnbt8WCf8AsWtuDH6LEbzaIF49XFVDQxnzASTy/pvD
#@/dlr9n/GAXuDMoo00PZhdhTYv1Pwm8s93HG2YFXesPFhf6ZZSPhnAf5TL/VHcCjhnyn9T0M6+Hfw
#@bxf+dflR5fZE0gYPFQmQERCo/c4CSLKPBBCDZ7wfokUoE4vHLQnyBQwB/CeJ3KAeLgt1/Rz8W5Kf
#@81FrNlak70wEyLW8QiEKgjYVfECkpe8BrQ5JH4LRfHsky0Re0KqJosAXqq2PFTwUc8tdQTEnWF3w
#@AIHa2LrxcIDqT415GMl76jOT+ZNtTH0J8r6HDZN+2BeRcLlxdQF+bvk71BJLjQCPvXQcP37hKJ55
#@bQkBCV0MiEZQQ6Neg5oikPcH5UYKgb9erYIdwv1v2bUO9109g8mCB4A6/Kv1iYJg54YiFt6uYFk/
#@evE49l81bYJ7nRW76tMcMaAbBroEcGtgbzA6mL9/ugjctU1w21bBT98kHvhb+9SAXM53D1oLnv+s
#@AIEY5oR/dJ5/B/8O/tWKyQAgOkxnFHIMQAw/TCtGAIFBGcO5WDA4wJidq3+SzM5xxhBsyxAw+KX+
#@SN2DRi3DMAG6kPEs5Pl5SK0CAkrnTABjvkABsC/wJFD98byHQku/6Asmc1DyBJguCtCShG9tEfCX
#@xwiwKieYKATq/7ui52HdaPs9MjsBqO/QlhBA1FIfJx3GGT6rIFtr+P++aH302lfrABC1DQWUbckV
#@x30P11+4BtdfNIU3jtXxyAv/xiMvHsXrR6swTxFAOEXAL+RDo4C9cP9qx3D/PVsn8fVPbsJ5G5Y9
#@/ugE/2q5Z/N4mwHgd4cWsX/vWhPs60aBlPqG7ZmT+SUHe2P4v2H+f4qTdMZywOXrgK+9ohnp/Lx7
#@0Fou9UcSAkkHEJgOVBBMBf7JdOCfSAf+mVrOMgf/Dv7twb/ZACAGmE4OHuZoAIGSFSOAcWzGcC4w
#@aIiiAewfe1YGpzaJDAH8WzH4KBCAWgXb/ssm1br2evtnycEKHWWfz6/kfLAFyK7bJLhxTgdpT4Nw
#@zwDjcaHdM44nIioLEBDV71SBgCAlYpyh8gCpdq7jM02vbsDo9wEN3LXv079b7ZjaD/3YBeq7tNdm
#@V+ex78r12Ld3PRbequDh5w/jZwtHsVgNoIuEShwoIvByPvx8oS9VBAigWa+ebHWQhK4Nq/L4yjVn
#@hUYNkVbo19bByDwA33r2CJb198N1A+ybQN5wE8bz/ivF8P4nDf/XxlmIHIioXPDMYT3HiA8IQAf/
#@NuE/NUBgdvBvP+Efk8M/HPw7+B9O+FfyTGPI1OFfiWCGJef64QVmH8PPaYdcaN37vqLmnpPLzcH/
#@oG2fVlr/pdfofvYIEaFMQcT+azq4JfIKtxMj0QWQQq0TjALh6CWBC88cwYOf3oSD912Ahz+/BR/f
#@vgY5rzMUNBv1cP59rbwUroPMLNy/VlpCo1YDtW3kc4I79pyBP969AzdcPAVRxxPvmAFi9+wIWg+z
#@3Ajw5rG6AfYNNfvTqRYw0L91s2IbHSL1nGYAyOVyp8dz28G/lbB/Mh34J5kK/NOF/Tv4H074V/KS
#@wDQhiYCAYMYwliWQ6HCaedTBcBgCpB/n2j6EksvNwb+b898/6XN0/3AEaASZhyIbxyVfEmC3mdLZ
#@3TxwwgCEseafG4wAiGEEiAbkkbzgU+evwU9u3oo/37sT+6/ZiC3TRUMVgTALP6rlRdSq5RDY0xCD
#@ALVKGfWTjQyg67KzJ/D0Xdvx1WvPwmTRMxyTeSrAmlEP289oP74fHDjW4Zwi5rXS+wC7yhdAs5HM
#@/JtNsEx6z/VusKsHwPNHiVZ5bv6/LfgftIR/SgQHBf4HMts/6eDfwf/g3tseYohMHf6VCCJLkdkD
#@Ccm+wRBJWBEHAgR7z0gvsO99dvDvlH0pwLZpM6UmsPAfZuDJtxghEO99HQhj9I1A+L6gqcQI+Iw0
#@AnTXNq7y8YUr1uPAPTvw5J3bcfOH12GimEOUSCBoNE4Be2gMaNRUkr6ur1mjXkW1UkIQYUyYWZXH
#@Q9dtweO3b8MH148AZPcNbDs3e+ZG0arfHqzo59cM++br2OVvggl+i4N8T5l14Fj47FASTyCeKwGY
#@Dvz3AC9kaoBAZgX/9uv8k0wF/uk8/w7+hxf+lTzEFJk2/FsyAkhW22AiGBr6aACBpj6eB4E9iSGk
#@0cG/UwbSPXXPHU5ejsz+NACqDuMdR1dh30SMsdpNbA79VwMNRgAFszGW7e3CjaN48DObcPD+D+Hh
#@m7biinNWQQSRYsCwgkC1FH+KgAr3L4fh/oA53D8C6uMutXNCQDcAvPJeFfr1NFcBMF9Hxp8WENP7
#@r79Pq+H/yasEEL8/rHn/Pef9z8Lzbx/+7Wf7J4cT/kkH/w7+Bxf+IYCHLkSmBf+WjAACTX0EUrFj
#@dLBvCLB93gcbgNnaHPw7ZZAH4Ml3pRuI6DFxGWOOQ8/j4nteeysLx/bPxkg2hxhgGg3yjARlGKA/
#@+rURH+EUgUdvncfCvp2496oZzK2NMUWgtBgug2YzOty/XEK9Ug7XdX10fhLPnAr3/8RZmCiIYR/j
#@HSO1sbvnRtpYYKlOvLvYMBpazNdKW3RdNjA+hDP2PWTjXot//zz1HvRninuwurB/JYKD4vl3pf4c
#@/Dv47wH+AYHXrdeRzBKGiMwkMOx7xmAuFuDXgiHA/rx7qmYf/lNIeuTg3xkeUjAAvHyCeLNEdBJX
#@4mvxjAXm0G4a+mSMhH+xQ/9Vax1HRrxvhGfz+txUAffuncHCPTvw+O3n4sZLpjFe8Dpn8m/UUauU
#@wsiARr2KgIQK9w+a0HXm6lPh/pvxi1vnce4ZRfM+qaWpAYyIBvjAqIf56Txa9cOFE8bzbU4M2G3C
#@R9WPBfXkUNxTSq8vAa+eQJtybv5/nL8zqUMFydQAgRy8Ov9kOvBPMhX4Z0rwTzr4d/A/0PBvmgJg
#@Bg8yw6zvYIYP675lae87hJK0PMl90ObdWzSMSDb5AwIH/wm3zb43GxLxoBsBfvmOYRqAhbKFvXkw
#@CTKtKIBoSGTihH+Rn+s0TgNgw2cMoK03AXHZ1jF8+3NzePX+C8Ll7i2TnacIMAjD/Gulxchw/6Lv
#@4e6Prcef7j4PN1w0FXN/zF5//dj1c/oRbRrArw+W9HFdJwakoUxgMu9/0tJ/FtL4GO6x8FmhTykS
#@QTYalme2nDbwTzAl+Heefwf/Dv5twX/8JICQvpbaIwiCmUIBOXwQShL2DQGDBYIkVVvBAKzuQbY2
#@B/+D7/mnnZbz/HaAegdKNNFBn0KTlbKPAui6zB/Vei8J/8JuVx5xhi1GFEBkC6LGqP54XnDjxWvx
#@xB3zOPDF87Bv7wbMThUQV5fPT+LpO7fhvqtmMOaLtq2gp31m2Myf2zVbRKteeq+hw38XiQEBxioT
#@mKX336Tsw//1pS62PSsisv8TFpoL+88aEJLDv/2wf5KpwD9Tgn/Swb+D/4GGfyUvyXxjZhz+TTBT
#@KCD7B6F9lDKgWBVhR5KRgcQ+/Jv5Uv63dADuBMDz82jVX48Db1cGvIZ/elEAOhxFwx+7qf3PLrz+
#@McaZPeJxvf9GINfb5qkCvnTlBizcsx2P3TYfJu8bz3uRJ3DjqXD/z87h57ecjW3rigaDg2GdhmM0
#@LoHLZkfQqhPVAEfKTX2cYR8MsG/MFRD120nP+w8Odvj/P8vAyy783zr8k0wNEEj7Yf+6iMGCfzj4
#@d/B/+sC/kpf0JiWzLbVHMOs6nelLLMCnhRKL5u1bsOJLBqUE7cN/4koDdJ7/004i0lYNgAB+9a9w
#@zUKCsiyS/BmjAHRp8Pdf9s4DWLKrvPP/73Z4gwISKBEktAZs4yDbiy0UMC7XWvYmisWGWi8sUGwZ
#@GZOXaC1LYcwa42UJZTBhwUsRjRAgsAJCCJGFBEgajcIgaUZp8ozizGjevHnz3v3vVi86dfvM7e+d
#@e8+99/Tr+f5d53V4N3Tf1P37YslCPZikB4nVQ/8RHBbvpwSQgUDtD90g4LZBBuBZTz4SH3n+k0YF
#@/Xw9+9cejWvf8Ct4wb881gN+ZUB/jfThH2q6w+OOzPALj+mjqC+um18J/kvz/ulNo6SBKFdMxfvf
#@UJHA9IU2icu3E/TqiYjYRRYw+M/BxPDf3jy0sH+D/9mH/3ADACFT02qPYAtQ0FJdAEmYqy+JowFE
#@OTOZYN0dGAPSw39EJLrB/4xJ99x9cyfbazPWaZE/euwWBGoBXmBvHeGh/2GvAcF98UmCUADbA/PK
#@05H4wHd34bKf7UZRv3rSGnzuRf8Cj+rDMyAo61KmIzwAV4a/zZ55yhyK+vrG/QBZKRWAZYUB9eiP
#@IMMS4T9mA2kC6c/JK3ZiTL1sYBfSxuAfMwT/6av9k5wq+CcM/g3+pxv+fWVh4JG+1R7B1qGA7NYD
#@3agkcVqABFNoehDU98sswH98irrB/2qU2rt73UPAjoWuID7GU6mvx/0pW2ZAeoGbP6DgH5vz+tfo
#@+V9uCNCBPA/yzv/gjofxrm/tQEGjjgGXv/zJisc/L1mnAv6R2+DsU/w6AIuT4L/8PaiFAf3HK4Xp
#@ayH9BKidFzHe+u6MB9v3Azft9lOJLPz/MM75b7zVH2kF/wz+Df4Twr9uACBkalvtEWwfiNgZkCiw
#@uXq7LAAdGwKk1XaCswj/8cYBA/BVIckEWdYb258Xb2O3aQCN1wJQ4CwkvaAc+DSYjTACuOfVByYV
#@zssDwFw3CuzccxDnXrAJyznHHHNfeumpOHqY1Vmmm4dUwL/iOPtJQxS1+wCxZ2E5FP5VI0W5QSiw
#@8J9yLDeZ+w90G/5/0bbx9yGZhf93CRUEGwMEsjn4Jzh1ff5JNgL/bAj+SYN/g/9phH9dWYPw70Qm
#@KHAnUNRySoCkq9yfvstCLGEmWHeMMWD24T9o/UTAMM9/cvW8YoAXbgU4jUX+agEWPbipkQrgHqtF
#@49xy6hkBlJZ4FQv/kQSrdwZwrx1cyvGSL2zCjr1LKOpt55yEs085wk0bUGBQeV/q5wneNqc+uoeT
#@/99AYbd9ef1+6PAPMGgf1wn9LwNrVjFQTW2RQAL46laiqH7Pwv8N/puDf7Ix+DfPv8G/wX8Q/OvK
#@moH/7tvsEWwfxtht+HllSeJuAdKkqzl23R0aA8DDGP477oJn8B9dB6DoxbtnH3D9g7WAIb5gWbyx
#@ILxugNYVINg77ENqRMG/Wr3+dUOAG6HLYI63X74DP940j6J+7xeOxBufdRzAPDiFYHRjEPhHbZuz
#@T55DURdvWIReByCoMKD/uOLxo4B+JNQTscX/6hkCfvoAUDwsRICehf8XZWH/CeC/zXnYEPyTBv8G
#@/9MK/7oykg3BfyIjgKBN6Z9BEvbxl8RtA6WtmPPVkXtOsjgM/lsUK0Qd6PnoCUZqiUB6PRR14RYW
#@KSfkPn0UgJJ/TaqpACHEFgSObDP0H4pBIiD0n4Xwe6J8+kvW78XHrnkART3miAxffvETdQ8/cw/4
#@85VSAXQDCyqkAZzSR1E37Tqo1gFgmCEnxKKkh/4rdSiSe//dn9B7jq4JRWXZABBBAq3Oa7bEpM2y
#@MUAgm4N/gsnD/n2RNPg3+Df4j4N/p4wQkDGt9pL22lfAteWUAEFbSph7PrqlB0G6MWXwH5QqYPBv
#@KojJR99LA7h8B7BvKbZ4WDtRAOFt1iJSATBSSc/40iJxnhGgjYJ/dXr+6/PRGxvvW8QrvroNJJz6
#@IrjiZadi2BMAhLvRG8q6o98z9PvfPWWIou7fn2P+4HIQ/Ov7E2PzExGh/0FtKtvy/scX83x4Cbhi
#@Bwp6xPvP1GO1ev4N/kVJSUgM/4BY2L/B/2EG/3oKQKvVz8nZ6HdPdp57ngLE9O0pKfhpiuFfNwYY
#@/JvhIbmyrAeRzD2fXwa+vh2RxQDreCojlkkF0GJSAXSPsW4EYFMF/xSPv+KZD20BuG8xx4u+uAV7
#@D+SAk+BDf/w4POWxgwLkK+8jeJ3KZ6gRBfCUYzM87qgMRX311sXC/Ar8qxEd8aH/QJW2fxHdL9TX
#@4ov/XbKN2J/DSSRD1uvZhbNl+Ac5k2H/8fDf7jwEG4F/0uDf4H/1wj9FkKGgNsPPydnod090K5Jd
#@wpC+PQVpxVUHob4nzeDfokkTyMvn9Qp+xbcVC44C0JdZFYwIMDgVQIG6IFAkQKh9+vWidqhX+C+6
#@BWCON126A7fuWkRRz//1o/CfTjtKNy4gj2gFGFEQ0IvOOOvkAYq6eOMBtwxCgX/FsKPAf1jov5sm
#@1NClT4tg73/zbTsv3AL/WmHX7EpKDwhkc/BPMEXYvyqSTcG/ef4N/g3+RQAAWZfh52TrvfY76HXv
#@PkdXUgrPdWYImBIvcAK6kra6CgAgDf7N85/EAHDDQ8Bte+EpwpMYBh36MisXBNRTAQgNwAI6A6hG
#@gJJ2cwyt8g8d+lmlHoAeIfCPP9mN89eN7+hTj+3jE39yEsDQTgLe0N5H3YKAnGwgeeYT+ihq7Y7l
#@wrYPgH+94r9ugAoN/Vdgn8HnVwjAx7X+83XLHuDmPSjIiv91UfCP5MzDP9kI/E9l2D9p8G/wv6rh
#@f6RMsbapHzB9r/30ve7JNIXnOpcoERbJQLADQ4B0sGCyOAz+Df4blB7W++m7qXgzmwzvJ8CIUGZ1
#@Wt1goM/nT0+AEUYA1Av514E5PPTfB/drtyzgv3/zPhS1pi+48txTguDfDSiQX/l9V6+HcPYTByjq
#@3vkci7kC/6GpAI0dS+GF/8LPA0akCYRHzXzmrtJ0IbtgGvxPDfyTbAT+KTT4N/g3+C8oC85BF8Qo
#@Hp5lKnvd+9zWkeGB6EwSsF1TgyDdWF3w7+tQkDD4NzUYBTBEUZdsB3YsBEBDY1EAmpcyPGJATxvg
#@BINEUFqAAvw6rLKrwn8Iixx4cH4Jf/aVnVhcJor67PMfh+PmJBD+K3ry0U5BwKcdn+GEI2Rsd1+y
#@4YA6r54KEJwi4kR/RoYcqxHnQJT3P2w5OxeAb+wkiuoNrPe/Kol24sxkzr+iWPi3gn8G/wb/zcK/
#@UxZwAibssx8PBQQ7ueCTSarOJ/iy68gQIDFJg6sK/vVJyOIw+DfVVq/Xg2SZe76UA+dvot7OjB1F
#@AZRATVwqQHBRQH/eQCOA95x+cUAl3L9WDYBwz3ye5zj3q/di0+4lFPXaM4/BOU+Zg+v3j58PuqEb
#@BhCSIpDXrAEwOS1ASJzxeK+GxYYlZV8o0QA+/KsQ31DoP/1ld+T9p9767/P3AAdzOEmWodez8P/V
#@0uefbA7+KWwM/snpC/sn2Aj8kwb/Bv+rHv6dstBWJW2JbB8KCHYAJAqjtWp4YAIYa9kQIC22Epx+
#@+NdF+sPg3xSsfm+Aos7fDMwvRxT5CwUb1AAbf9oAg0FMUUDdCKADrFtncDRAZAg984n//5/ffwhX
#@3rkfRf32E+bw139wbOGi6M3nhhYVEPp/ZdRsnXj2yX0Ude2OJWVZGvxHFP1TgF4J/a9uKEOwoaxu
#@kcDROf/lLfQihMz732bBPxIG/xVAnmRT8G+ef4N/g/8SZWFvNJERQNCYCHZY+b1bGCIJpgRB3RCQ
#@HgTpxuqG/3CjgMG/qVTZYDD2w23PQeBrW/SWgIwO7w8HoXDPbAjAsbDsCCOA4mmeBJ2sFPIfHfrv
#@IPw7d+3H+360B0UdNcxw0QtPqNiWUBt5fCoAw7cPQZz9+B6K2jlP5FT2UQz804N/aNMHRZrEGb5Y
#@OmGEoYD4yhbgoYNwEhH0emYACFRS+AdnM+xfh//0Yf+kwb/B/0zAv1OWMPdc954LIhQJqdLU50nT
#@ci5K0uo2Tg+CBMAZgv9wo4DBvwkCoN/ve8UAgWVGRAFEFDfzRQaDlr4y6q+FGwHcqJzTz9FQpo8E
#@bv+1LbuXcO7XHsByTjyiTIBL//OJOGIgABk+4LcWrAryeVQUgL/9fv34DMfMjfcXv/yupYBtGwL/
#@NY4faEAfYkiLKJYZ6f3PCXzuHsD3/otdixN4/tPm/BNoDP7J6av2T9Dg3+Df4H+Csjq5522KbB8K
#@iO5giOwMhuINAZLA2JIKBOnGzMC/LjUX2eD/MCsGKCLu+eb9xJU7I6IAYtqbuWnDl4uQIn9aUcBw
#@I0BYfjn0Xv/UIwa812q0AARx4GCOl1x4H+7fv4yi3n3OMfiNk/oAWWPkk8EeNVsBgvo2IEojKDIh
#@zvSiAL5y+1JAnYYQ+FeK/nnTVQL6gIiXWu0yI73/V+wANs+zwHMW/t/sF1aL8M/Zh3+SVvDP4N/g
#@vz34d8qUD5jGCCCd8Eg5nEqb3NU9DJEJATzcEJDeA003Zhf+9fVrIGDwP2MSEfgtAf9hI5GzhfD+
#@QE+nvlwdvlixKGC8EcAH1pVfJwkiJvRff37et3Zj7Y6DKOrfPHUN/vzpRzowV0a9vH6w8VSA0W3C
#@tjz7CRmK+slO73NFwb+S91/1+NPD+cML/6H5NIGcwEfvJIrKegOIuf+hKz0gkKsp7D89/BNsBP5J
#@g3+D/1mAf90AUPVETZAz1SKcCjylrnXQYTSAdLatpz/8nG7MOvyHi9SGwf8qVN9rCbjxYeCyHVSi
#@AOqFJYNNpQJE1AOINALQMwLoUQD6PUmw4Vz782/ej0+tm0dRJx2V4fPPfYy3LMUQoE6npQPEpALo
#@28W/P8szAGx7mBP2CcBo+I/I+48J/VcgP/58JC7dTty+F2Pqm/e/pnRAIDm1rf4INgb/ZKKwfx3+
#@zfNv8G/wH2wAEFRVy4Xnuut8RiE8Jap1kMAQIOhULNymPvecbhy28B9vIIAf+mw/FFPLtfwaoKgP
#@bQCWFO9j5fB+RPT7RwSARRsBFEgMgv0awKs81sb6XYt44zd3o6hBBlz5ouORiQb4OfTXYvL8tc9T
#@0yAC4reOFxw1gFNO4HtbvHnh7hqG/zaO1bCaAuFpAnoUzjKBj97hpwP1IVlmF8Rmv1Mbh39y9uGf
#@xNSF/ZMG/wb/Mwf/TtlqKDxHoj2J4qGe5loH8fsrMYBHbPMUAOxA1uA/et1kwFCAquji8/N/aQaG
#@UPWHQxS1aR64eKtHKEpYMlCjLWDFVABGFPlr3ggQf/zqAKzk3sMDdhAPH8jx0ot3Y35pPJ/7o//2
#@aDzxKJn8ntzIR0NpAajk/ivRAcgn/18Hf3Xb9YU4/aQMRZ1/+xLANuA/vkggK4b+k9Xy+X0Ret//
#@C7cAd+9DQYLeYGgXwkYlYPXvYoP/BuGfoMG/wb/Bf8C5nTVYeK7lfvedwFB3QCpJecXlWiaRqOkB
#@0w/ALA6Dfwv7X721APziXx/eSBzMKxb5Q4O5z75Yo2+7U5wRwH/splVTAnSo1T3h4bn2zIlXfmMP
#@NjywjKJe/Otr8LynrfG88yrgB0ynAH1wKoAG/uHbza8D8OPtOYDCJCX7LgL+naqnnACoHPrfUgtN
#@YHROf+JOeqH/fWRi3n9FHQCCLnKGc/6dpEn4t7B/g3+D/8BzO0tQdC6i3303QEKwWwBmyv60TAqC
#@8YaA9BBKCkiANPg3+F9d6g/GC4BtWwAu3MICEMUBSLhnP6LInzK9Uw0jgHus1wXwBqBDf0BIfEAK
#@wQevncfFGxZR1NOO7+Pv//CoIrh7QB/bBrB+T39CBf/AbQY88/EY0+Z9ANX9VQv+nZo+HhkcKRBv
#@gGNhxgs2A1v2+8Y/8/43n7bKaQz7937XxsM/2RzIE5y6av+kwb/B/0zD/0hZssrz0k1/fX3dCWBU
#@tM+V7kuL5NSAIAu3qYd/iJIOb/Bv8D/dEsmQ9fso6mN3AvPLoYDeSP/ziHoAAdAVbAQoWU8ASFaq
#@BYCwon98ZOBQAL9q8yL+5qr9KOrIPnD5nx6teurj2wDqrQD9QeQFj782bbgx4OknAEf04bScA9fs
#@zIP2GQPgP/y4isn7jymCGTqt0+hc/vghlf/7kMwuzs1IGod/wOC/KvwTNPg3+Df4r3BuZ2henVSd
#@JzsBkm4h1AFkAhhr2xAg7bQRTA//uuj2qcH/4ShO/xh5AgVw2rnwSLgwAwqWxRU3Cw+H7sYIANUI
#@oKYEVATbsMe+MWDXvhwv+8Y+LOUcO80u+JOj8OiBlIbxx7cBVFsB6tCPuLaA/hhmwNNPFBR1we1h
#@8I9O4D/+WNeLZVadlvjoRuDeAxjv+z8YTv+1aRWF/ZPNAgKZAP5Thv3Hw7+F/Rv8G/xXPLcztCSS
#@rUMBObsQSiaAsbYMAdJo94BVA/8QrVi+wb9ZAKZjCASZFw78qbuBTfMMbEPmQ1S8V5RU6wCUAx5i
#@jADeerzHblo9JaC69x9KgT1vuqXlHC+9dB92PEwUdd5Za3D24/uKx143AujT6hEF9EbI53DrQI0o
#@AADPfLygqKu254fun4lGmlrwr0ejQM//Z3S0i/8ew6e9ex74zD30Kv8PIBCYBaCxulEJ4D9Nzj/Z
#@HPyTTBD2r4s0+Df4n3n4d8pIdtd6Ttpqq9cdhCpKme6gS6a1w0OsQWb64T+8e57Bf5vrZqIBcFUM
#@vxbAgWXgPbei+Cmcwvv9h0COd68Cjz49GWAE0AoDKssITQkg/SdV2vvp0/z1VQdw9bYlFPW7J/fw
#@5tPnQJdnn4MK2LsR9D8f9HMQHvArRoeqn1ffZnAPzzpJUNTde8Pz/Yly+Gco/GvHa9zxHR76H1x3
#@g/i79cDBHE4ijxj7uBpGsjWHe/6nG/4Jzjz8EzTPv8G/wX+NczvrohAcybahQAcoSQCfja07EhCl
#@MUPO1IEgC7dphP/4dvoG/xZ10J36Xkuwb+8Cvn8vlIKAEe37Yjyk/nqqgptiBAioC6B6m+E910E3
#@VwB4/H9fv3MJH1m7iKKOXSP48n84shSyOWm4W+4NgpgwT9VIBpakICB0G3gD7mWn3zlRMNcT93wp
#@B264Nyjf34P/Bo8hxkS4RLQTVAr/fWcX8f37/Mr/Q7tMKkoLCOngP33Yf3r4z2nwb/A/e/CvKeuk
#@Grx0U22e7AwKIjzQqVIeOjYECDoVC7dphf94o4ABuMF/S3KFwXoo6m9/RizmhFMNzz4jeqO3YwTQ
#@c7f1ugCBtQFKDQG5dx8WMn/nQ8t45RULIODUy4BvPv9RGEoe0LavahvA+FaAemSAtvwcPvj7235N
#@H/jN4zGm8zcur5Tvr+Tvtwz/4TUunFgzUgCFtn/vuQ1Fjc7trN+3C11DXzRks4BATi/8k83BP8mm
#@wv4N/g3+Df4jzu3MA7xV33KO7NwD3SmQpAdB3RCQHgTdflkV8B8fJWAAvrIshzVUg8EARW2aBz57
#@tyONZlIB0AAwIcKLq/T8JwPqAmjRACXbgCy7gIeFws8fJF5y2QHsWRw/0d/3+0M89RiBnvMfBv06
#@pEe2AgQrfmY/8qJ8e/t1AH64PSDfnwBLDUCR0SNowKCFRkL/3Z9P3UXcs88/t4dWQ6WhHACCUwL/
#@yjwzDv8ELezf4N/gP+LczuCpneJv3RsBiO5EMBEIJoAxxRAwbRDKwi0h/Hd2vJPFYZ5/U3VJ1hsV
#@CSvqIxuBe+Y94qiWChAfMq1PH28ECK0LEBANUJ4WoBgCFK/6m7+3iPX35yjqeU/N8JKn9fWifXDh
#@9XEDSitA7bneVlAHf3//lGzjsx4nKOrOPQzO9wei4F+D+fiUlpqh/8UZNu8H/ved8Ar/9SFZZhe4
#@TkIx08I/QYP/CvBPGvwb/M8q/OvKEhR/c8tvGwrIzkPQOwcSMjUQuf051SDIwm1W4N9JNCORFRs0
#@VVO/Pxj7EtmfA2+9kcipeSt1qNGLpqn/a8cIoMyn1AUIigbQDQHhrQP/z00H8YXbllHUKUcJPvGH
#@A4BKq7+oFoAVl4lyo0F4KgAABoI/3R2ecaJgkMFpcRm4/SEl31+B+MbhP+J4r3leudlzAm+9EZgv
#@HjYi6PeHdmHrAv4lOfzPcM6/k8G/wb/BfwPndgZFZPNV77tMOUCCHuwk03iAmR7GSLoxzSDIwm02
#@4V8XOWkY/JsAiMAvCLj2IeD8TYGpAL5iIgJ8wqllBChfj14JviwlQDMihBsCyl8bh//rd+V429U5
#@iprrAd96/tBBdnjF/VwzBIRPDyVKoGIqgA/5Tgzbrkf2gdOOExT1T7fnfsi/vn+V4ykY/hXQD4hg
#@afg8Ij53D3Ddgzy0uKfYBTPBd1KLBf/ah3+yOfgn2Rj8E7Swf4N/g/8GDHtZ40ArCYFZtPWgKyWC
#@YA/iupQk3AbSWPHAmYb/eOOAAfjhpF6vj8wrCPi+26ikAlTOcQ6fvgiMdY0A0PvC+7AJhkYDVDcE
#@+K/5XPzgQo4/u2IZB5aJoj79h32cMKeCeAjYR/w/3PCge/v9bVZvO57ptQP83rbczURo+1Q/Bog6
#@8O9Px4o1LxA4vR76/8ENRFFZ1kevZ4X/GhHZKCAQjfb5N/ivCP+kwb/B/+EL/4AgaxTSJaHXXEIv
#@asmjAWYr6kESGkOknTSOHJhl+I83DqiGAvP8z4r6wzkA46kAb7+ZYK0if5HTu2eNGAHq9fxXogHg
#@P9cB1n/Nvb6cAy//do579hJFvfq0DH/0JASE4ucBVf7zCSMoJUB5D/5zBfr9baRvNyeyWAcAY7pj
#@L2rl+xMR8K/UrmjJIBYe+g9Bf2ih/02IbDMEIB7+CbYP/+nD/g3+Df4N/htM6ckag1lJ6DUXBIuc
#@sWgASfhZJcF26KjPP+FuBv/VDW36UIuhG/xPi6QkFeCnDwBfuAcAGFXkL76VWrgRgBEwyFIodS8q
#@xf4UoPVeY+G1967N8a3NRFG/dbzgnWdlABDhfW96OsX6FwL91LcJArbrWSdl6AmcFpZGxQDdvIww
#@+rAC/Me3sIyYXgv9Hw4hFvo/fSl4cGoZ/tPn/JNsDP4JWti/wb/Bf4PndtaIR1sQrAQpB7MbDSAJ
#@jB7R251uTCv8++L4zeC/XZXzBcofw/8f7Tdpk+r1D00FeP/txF0POyLxQKntIn9sJodbA0FWqfJP
#@sI4hoCQq4MqtxP+6PkdRRw2Ai56d+eztpFbo14FeHwgoJggP+KtAvx4VEdAVgDh6QPzKYwRFnb9R
#@ACgh/wr8x9eQYCtFAvUIGuKOvRb636IShP2ng39y9uGfMPg3+Df4B4AsGmQlISwLFM14NIAkNHpI
#@gu2RAP4DjBgG/1bw77BLBZhfBv7rDcT+XAGYGh7+kZoyAkDP7WcJ2IVFAyhpAW6d1Q0BW/cSf/Gd
#@HDnhlAnwz/+ujyP7gqKIibzuVBP8tQXri4UnBfqrgn95a79HogAwpu9uy1f0+vuGIuq1Apxi4R+a
#@UYp18v6BA8vAm26khf4nkyQo+Oc04/DvZPBv8G/w30JUTxYFbpIQlqW1/K7pNwRIQqOHpNge6eFf
#@f+9uGIBP7bqZZMyCRA4Fig0PA+9eTwBsIqe5Rn4/G8/x1iHPf66nBZAoSC98t7BM/Jdv53hggSjq
#@r07v4TdPcBCrHlpEQG2OwEFtYBLsV4d++q9r4D9O6W62s7xCgBt2s96+jUoXYMU6AU3VzCDeuZ64
#@bS9mOPSfKUYrqf5ks/BPsAP4T5/zT9DC/g3+Df5bSOnJItu+dQHLHUEoOhfJVECUvu2bDtPp4T/+
#@MxiAm+d/lroCjEZRX94CfG0rADC+yJ8G5SuBF4OBLdwIwMlV/qmkBZQaArSuAQDedg1x/b1EUeec
#@LHjVaeLlx3ujGrfEo48O+26A4dAP73UnloO/v+3PPGn8MjG/BGyf9/dhMPyHG5QIHf6hH3/xRQKJ
#@S7cTX92KMWU9C/1PGfafHv7T9/knOZXwTxr8G/wb/BeVxV0EExgBpM31THk0gCT8zJJou6SH/6ai
#@AwzADf5XtXrDOUiWoai/WT/KQY4vCqjXEtCNAMp66vX8B6jUBihZhm4IACcC7lfuzPGpW3MUdeKj
#@BJ//o57H0BpYl0cAIHqU5/aHvy8d+nUDiZtJbRH4mDnBLx3r1QG4I58cARJTJFLp81/p2GV80b+7
#@Hwb+6uZDI3UGwzm7UE0V/BP+cQP6+F4wdLEm/JMOEKp6tkiDf4N/g//Zh/94A4By0ncAhGDili+p
#@Ux4SGT8EyUQoAJ0S/uMNAgbgBv+rSgJgMJgb97guA29YR8znflHAtEaA+J7/JfOjVs9/NzG99IBb
#@HyTe+MMcRfUz4Irn9JBB8bSrLv3Gg6eVBarAHw79hdfpLTRke5/ppQF8eysBBqZzBB0rKeHfn5dY
#@WAZev248718EGAzX2EUqJfwTnqbf809OZdi/Vfs3+Df4bxj+4w0AkrzdnbeOBECcLuUhyedOD4Ll
#@AB0P/+lF0h8G4Ab/Uy3JslEkgF8P4J03M7SquRNR1QigARLD87mjowGqGwL8f+5dBF767WXsWxr/
#@jv/ws3p4/BFKYT0l9J4Nk78O+jrwh0O/H+ZfffueeQLG9LOHqnv99eMjEP5ZA/41EiwvHDjy/Pt5
#@/73BKDrHLlCtSgAyfNIEBf9Swj/JxuCfQGPwTxr8G/wb/McZAGR62t2RRFdiOjBMCkQkQCSUBG2j
#@BPDfTaQLORoG/6ZVUQ/gom3Ax+9ApaKAYGiedHhhQCK6CJwyf4QhwIPh1121jDv3YEwveGqGP36y
#@hLXWA/RwfTQ4fIgPAH4P+pXcfj/Mv7phxY8A2HcQuG/R38exRSD144s1j2VULPr3sY3Axdtpef8J
#@lLraP8EGAcHg3+Df4H+24b8pA4Ak7HkvsQAYv24CYLrw93RfYqn6q0stL3oK+O/C2GWdBpqQ9QBo
#@vR7ABzcS39yhFAVsEJzIcA8tG+v5D0ApWAcdXN08H1tPXHI3UdAoj/0DzxT9ehtalR/tH8hU2hF6
#@8t4vA7z9/vbTt/9Ja4BfOBpj+tIGrmzgYZXuEQRaPob1eYjLtgP/sJHwI3L6ZXn/1gOg3mjsd1ND
#@UEEW4J+gf1CLoI6IRuHfwv4N/g3+pxD+4w0Agloi2QkUkOwMSAiACYCoc2+wJEyLkEZC6mcA/iul
#@Dhj8m7qvBzCcG/uSygmcdxOx7qEERgAf5IsE2VDPfyrPtVZ/xcmu3UW867ocRa3pAxf968xbKUFS
#@NQjo7f7rgw39QW+oC/WnpU/1eqtAKNtficDw2wF+a3sOMDTkP+JY6gj+b94NvO0meqAjGAzX2OVz
#@2r6/ffhnR55/MuiHGzG9Of8EG4N/0uDf4N/gX1PW4g/zzqqfk+wUSJgMwInWJQnrI0gr+fUzAv+6
#@SJYNg39TaxLJMPSMAAvLwGvXEtv3K50BIo0A8V7b8GgAPS3Ah0k9NWDXPHDu93IczMcP/386R3Ds
#@mtJ8et0gwGokz8ABb6hiAPBr0O9PRsXwoqSonXGCoKj1DwoY7PWPiyaJh3+94v+OBeA1a4n9OQoS
#@DAZrIGIX0GkS6RFo2rB/Zf30Rj2oIGnwb/Bv8L8K4R8QZOwGxtqGgs49oQTAhLnvrUgSFEpsv89/
#@IBDPJgSTnDQM/jsRZ3qMQpAHQxR17wHgVWuBfctKZ4BIIwCj87a1aIA6aQF6z/9lAq++Ksf2eYzp
#@1adlOPvErEJFfXrtBamBfLR0wwFBrAT8GvQrYf5QtmfJa2edKChqzyKw50CI1z++ngQbg39/fo7O
#@oVdcR+xcwJj6gwGynsz89WWaRLBO2L8O/5xQDIIMSGVkRcBWlB7+Lezf4N/gv0P4dxEA7KTfPLvy
#@hHYKJEyb+54axnRDQHr4V4E4gaa1xaI/DP5Nwer1euj1Byjq1j3E69fSebubNAK4aet4clkOl/E9
#@//VQ9XevJb7vFW878yTgrb8lZSCsGARUo4BiIFBGKOBrsK8Avw79/vZUUiuUKIsnHAGcfISMTXDh
#@3bnu9feXw+qRI+4xm4Z/YDEnXnc9cdteH/776PWt6N80KRz+GQwVBKsDggbldKNF+E+f808a/Bv8
#@G/yHpOdk3vd0297ICChoGY4l1scXKWn1s3a03d2YEvjXRbibtdvzRHKlYb/6TOMeSQ9Kfngf8IYb
#@iCWyWSMAAnL73eNqYMcGev77y/vmFuIjt+Qo6pg54Ivn9HSvOAJ7/NMNpU9fxUGWv6zAfvn71aFf
#@337h6RXEyKAypm9s9fdnqKGoxvGFZuF/mcRf3gj86H6MKRsZ24Z2wUkovdI83YuVw/45Af7JAiDQ
#@nynoTTI8Uq3zPv8EDf4N/g3+E9TmyPz/sasWd7MTdeDEdCCoQFkiACdATi/8QyYaA6zdXqBIhg7z
#@/M++RqkAmWQo6spdGBUvyzkG3/FGgIi6AAQVeG+y5z9w917gNVflIODUy4CL/0gwELfs0F7/eqS0
#@hvSsOFA+9BWVrVeD/tAw/7D94NcBuOVBBu9TgrXz/ePhf/w+J3HejcDlOzz4H6XbzNmFZhokrPGb
#@kA4qSDbp+VcomGBlqNBTMUga/Bv8G/yvavj3DQCigWyLcL46ow50O2o6EExW/E03BEwx/OuRAQb/
#@TR6XYOG+bHgpGmPPAYAWmTDtnQHmDm0PeNE24O03051PDDYC6N5S1urn7oCv9Z7/+5eAl/8gx96D
#@GNO7fkfw1GOygH7/YY55IDKtutYyFNhXgN+D/sAw/7DtfqZXB2D3IvDwwWaOBdQ4DlkB/unmId65
#@HrjUSxcRkVG7P6v5N1V9/ku9/wSrhf2THq7T9/z7B2HJen3JaBASdq7rUOEmJPNHHlurP4N/g//V
#@Cf9Omfdi90YAgVPaqIMEhgBJ8JkTgSDpRmr4rySO3azdnuX8m1SJYDAClQxFXbgV+LufEahoBACV
#@nv8h7d0qe32jDQFuvPWnOW5+kCjq2admePEvZsH9/t1yg40Cdb33Fe0A6grKaxb4YrC3Pyzy4tQj
#@gccdMb6oizax9v5nSLE/LYKlIvwDxPtuAy7YTIxJMgzmrOL/1MF/zorRoAIwIuc/WFIvF1PqONMI
#@SL2cTwobg3/S4N/g3+C/anpOBkna7q5Lr12SUGSmASLdECBIJ/27KT38hxsEDMAN/lcWD78hEAyG
#@Q/jA8tl7gA9vgGIEqNXzX2/1xjoe4HhDwOc2EhfcSRT1xCMFH3umBwGqZ1zJvQ8/zuLbAAbDvr8M
#@vaMAAr39QHjthWccLyjqG1tysK7Xv9Yx56atDP8f2kB88i76nv9Rq02BlOwHawKQQiRA6mSlQ4Uy
#@M8MBgfTm9QG7nIyhFwmsCxUsDoN/g3+D/+mFf6dsStrddWoEIJiAAVICkTMEJAZB/Ys0PfxHRQcY
#@gE81/NsP2C4lkmEwPNRr+eE7iPffVgiTDSwMiAhvbFiVfwYbAkDdEHDLA8Q71uYoajDK+8/Glssa
#@ofKAAvRwo91ThyrsV0ptoObtDwd/t6wzTsCYbnrQwU2Z11/pElAn6iQc/umF/b/3NuCjd0yKphEz
#@oHY4wr06EuDwoev3V8n7L7JiqxON71kHKhSWJ6lAhbrjyuDfwv4N/g3+08G/UzZF7e46bT9GMs13
#@WVoYS5cnLRHdA1LAf7xBwADcIlYPa4kIBoM5+AfCP95FvPMWjBUGZEOApc+rGBE0QER4j/qHFoE/
#@/yGxsIQxffx3ezhxjRJur3nXWRiBOfxscgQCEjXgR3nKAlRvfzD4u5fOOCFDUfcfIBaXvf1a8/hg
#@QwYqegX/3nEz4Hv+AcFwMEqlsQvJ1EhATs6XJSdABaGK8MOhpJIlgmNUR7BKyIJgRTEvWuN0qNDf
#@KxvP+ScN/g3+Df7rduXIUEHsrv1YB0CSAIYlaDvO3meXdloJEjL9ffbFGQQM/k2HnSTLMBgeagT4
#@4uZRpfPyFoFU4SrcQ8tAD2/pMli5539O4HVX59i0jyjqZb8kOOcJABnW71/3rKuQ3r6orF8DfupF
#@C91DZZuAKxcNfMrRwHFzGNOlWwkAlTs/jMRanSectON6KSfefCPwpS3EuOTnxTQN/qdKDPwXqTA8
#@AfrRqFQAQTm43JrFvcwqP65Ei/FVPP9qxL9e8I/IizMa/Bv8G/x3D/9OGSqKnYEgO/RAs3sAB8Ak
#@MNaxIUBic+2i4D+tRI0QMPg3HRbKsmyUx+x/AV6ynXjt9cDCMhVPaXhPdqrAVrEnfHhagFve399C
#@fNur3v5rxwJvf3qmecH1/vgI9MK7aVsewdEHevFBatEP2uvU6wcIgNO9doBf38zgbg+kblCidhx6
#@j7XIlsU8xxvWEZf51f4Fo3MlM8//lIrlrwRF/FH/BSjiTRdiYZKSd8BQqFDeT8Wwf7qhwD8nzWjw
#@b/Bv8N8d/DtlEWlZrUMBycaBJH3kQceGAInvGpC+37wbqwz+dfHQm8F/rMRSWKdxIMtK85m/ey/x
#@yuuJ+WUCYKPt/jhpegX4WMcQQOAHO4kPrs9R1JF94Mt/0IMPxToQh1Tn14r2dXQwh9QfYNBndFK6
#@BlTqFnDG8RjTugeoVPj34T3+2NPn5ehYP/da4Fs7MSaBoD98FJBlds0YjWkXS+CfACTAaEDQBwSy
#@oqdNoLcG5ASoCGkRosB/aK4rS+Bfx1TL+Tf4N/hvH/6dMkSIXXiBY8FUul2fvv6ODQHS9PZOD2I5
#@BSRAziaE8tCbwb9FHsxMYcD+cA38L8Rr7gdeeA2xbQGlRgBEgJh7HgJ/NQ0BW+eB115DLBNOmQBf
#@/P0ejuihqMrGAFZu2xdZ3V/x/ldtK0g0AP3Kvpm0f844DmO6dwFYWlaMQMoxUxf+MQH+dywAL7mG
#@+OkDJefG3Jy1+ptGlR8A7iUf/glCE5HDTUIqgKBFAZTisztfJk4ok/KK1A4DhfnYUrirgMWJRUtL
#@MPg3+Df4j4V/QJAhUuzMC8wugSAZBLPRWgspDC/d9fkn3ZhpCOWhN4N/g//VWxhwuAZ+fvPte4EX
#@XE3cuFs3Augh/UrP/5DaADUMAQeXgdf8OMcDB4ii3nJahtMeq1ynlH7/YX3+q7tOGTaqzlz+8oQF
#@sxL0K/tCMcz88jGCY4fjk125nSDDcv2p1Asg63ajINbtBv7j1cT6vWWGMSv4N4Wq3+efHq2Sk6GC
#@k/qdrljJuuS9sOQ4pZtN+wTuHMi9k03giWqEgf+Q3skflvPvZjD4N/g3+G8B/gEgS9DrvhsoFUQo
#@PQQzDQzp2yA9/OtpAjh8IJT+TQiCBv9lshDWqewO4Oc533sAeOlPiG9sBwCW5ParEB8eDYCmev4T
#@/2PdMq67jyjqWSdl+ItflkqAG54/74Z+3DFqxK8LCvBXgf7Sba9HZAiA3/GiAC7ZIvr+RIDXXzUe
#@aLUCiK9v4+jYvu/AofUxBub5Xz3XbQIEA6GCMY6loPAlTjhxxNX4mwQVfh6A//5E5X3lnz78K7No
#@8A9/Bgv7N/g3+G8O/kfKVmOve5KdAgnJBEAUW2shgfElCfz7RnE3DsuK+yy/meffNF0SQW9uDbJe
#@D0UtLANvXEd8eKM7bmvVBSBCogHiDAEXbyI+4/VuP35O8OlnSWGWUPCtaBBAYBg/YkZg+gCqAb8O
#@/QHe/oDijM84XlDUdQ/k/nLDvf618/0BgvjEncRbbgIOLKOo0bHfG66xi9hq9vxLeds+6vCv/24n
#@g77sqMzjzpHy1lOlQE0S+pvTzn3x0wVGN12ekVSCfocb/Bv8G/zHwb97mLVygRS0LpIpADgBkAQa
#@Arrb7m5ME/zrxQOt3R4n3wz+Tcl2X38wh15/AP969+GNwF+uAw4ss1ZKAKhCm24ICChAd/tu4Lzr
#@iaL6AnzlXwkEVELfVWNAuEHAB/x2XKie9GKEOvCHQ7/u7Q8z3Jx+nKCoXQvAsr++UK9/vZD/0bH7
#@5huAD9wO5MSYev0++oM5u4StIrG0kr9M8NrLmFeCbj6O36kpAv7yFM9/6TIEFAZ48lkCFW6GqgX/
#@RmLVVn/QJyc9IwNo8G/wb/AfAf/REQB6GlRnMJoCgJMACUPTLbrd/lMJ//oPUGu3VxT1m8G/qU2N
#@DAD9wRAigN8m8IXXAPfMB9QFYESV/zLwUyB9fhl41U9yzC+NH47vPT3Dk45QPNV6Hrx+veLKgE9t
#@oOJgUDHBcpXNg/D6B7q3Pyxi41ePBY7qwykncNUuFfzDuwRwZfi/ex54wY+Br+8gxiTyc6PX0E78
#@1SwpQDmJ0k6A9D3h9ACBcL+jVur3zzJY16yVDirKv8vpnzu578F3RgxvphoF/+iGkvOvvLeSicRN
#@aPBv8G/wXxn+2zAASJI+9w5CO1SEB7yVdIt0EmcImFr41w0C1m6vZr0B/2bwb6qtrNdHb7AG/r79
#@2V7ieVeNcqjVugBEZJV/HQrH9OZriY17MKbnnSp4zsnBIKtXwmd4j3+wlWTqAClGB2X9SgeEMMMJ
#@VfB36gN4+mMFRX1tU67WgAj3+uv5/lfsAP70R8Stew6F/8FgiKzXsxN+lYkTvfQSFi9Aeq3+uNLa
#@HMj74SZUe2R6hglPZYYA5pwAFfSGBAEyoYcmsfgPwWTRJ1u1KKHBv8G/wX8Y/Dtlbf8oZwIInQkP
#@eHi71XQSJT0gAfzHGwMM/mPWzZo3gAb/JowKog3X+NXQRx73N90IvOMWYDHPAaBeNEBcWsBofHIj
#@cdlWoqgnHw2857cFI1X2auvRAQwJx2fYACOgXgF9FfbV7VEtWmJF7vHWd/ohdQAEerh/jNcfo2Pz
#@b9cTr7uB2LuEcbnuFwb/q1cCiBbmSndPPgLCnAwIHId9wod+8Q9Idx5MzCPyoYJUv6tz5oW3EZxP
#@NLFFIEEV5FnSklATKYBeJ8BfkcG/wb/Bvw7/TlkX7e7YLYSm8ICng7FUFcclyDgy9fCvh94a/He2
#@3dUbPEAgSHeMuZ1Fuh9eVsd6lQ4RGVVFL/OSXrCZeOHVwOb53NFYYEE3vZp7oCFg7YPAe24hiprr
#@AV/6vawEHsOMAbpBIMAoQASLqAz1uhgA+wrwB0M/FWOt0iLwGccRRW3fz9rHhF4vgNi2QLzkx8Dn
#@NsHX6Fgejir92/Wg8kgvHSpI777EKy2YNM1kIwAPXQcnWqLoe/6DPBwsGBso2rUoDCoIqO0ByRJG
#@V+YhpWbfcRr8G/wb/OvwP1IWDc0Skb8eK9Hhs3WJss7O1p0g7UIiigYmgv94g4DBv8nUkUY1Afr9
#@of8FO+qh/vwfAZe7VoGVwvmdyGqGgPsWgFf/JMfBfPyU+ORZKPScr1HkTgdj3SigQD0aHgwtQMig
#@z1W7SGJRercA4LRjBUf04LRM4Or7ctXrz8qtI4nLtgHP/SFx4+5Dfxv2/399C7uArnJJWX5I8d6J
#@Xoi7KG0kymane6q3+6PeHY8EqBYXUaGChVvJBUcJxS8p1leS86/XCvDhXylFoE9k8G/wb/CvzJdF
#@ec4FlcUOgET5TLNhfJDujS1OEp0yEQP/SUVrM2gydaas38NgOOd/0Y7Cq1+/jnj9DcSDiwyOBkDN
#@nv95Drzxuhw792NM5/5ihjOOzzRPtW4MCPeU60YBth53oqygxntG5c4IeptAlu/zgQC/+ViM6eIt
#@ou53VPD67zlInHcj8cYbiYeXMCYRQW8wh6zftxN5VsSVnhMcuxaJUrRv0r2486iI4k6lJ4MAgkq9
#@Rlk88UhoKk/WG18uwQmh+KLk/CuZDGBYmQUqE4mbyODf4N/gv0SZAmjtgWACD3SjkkTrdetOFHUh
#@jbcSXDXwD1kpXcDg32RqWiKC4dya0pSAy3cAz7mKuGKnFg0Q3/P//bcSV92LMT39scBbflXLVa9o
#@DGA9b7q7uQW0P0i31npRC6wI/dAjKIjJsH66VwjwJ/fT28/1vP7fu5ejY++ibWUh/xlGaSxZZifw
#@LIoeuLNsAlnZYkBtGVJ0tiv5KgKIfxDrJxdzH8b1HzP+xH5aPknVEOkkARZLSEl9AehiSM4/Df4N
#@/g3+PWW1POfSkDe1QyAhmQSISCaHMQLglIJgzqDjLYFiWw0a/JtMjaYEDAbwv3zvPwC8bi3x324k
#@9i4RAMsrtdc0BFy5Hfj4BqKoRw+Bz56duUXp1epr9sMPD7F3g93cgkIFGA78OvQHefsn79dneAaA
#@rfNSqfYDS7z+b1kHvOI6YNdCWcj/EP3BnF08Z1qTC+uBDhDAsoPJB3j6i6V/IZocykQAEpgT42bz
#@pg1JFeDk3wS5kirAGpX7mft1AoK8+FqhQH+dBv8G/wb/0LsAdNbrnt0BSbxXXhKsN73RpZM+/yTd
#@mJV+82RxGPybTJGtAkdt1EQy+PrnbcC//wFx5S7nUQtPC5jQTnvLPHDeDTkIOGUCfO6sDMNsZQ80
#@qvb7r1hkj4nqTRbFwCKFehqVDv26t1+PwPiNY4G5HpyWSFz/EEAEh/u7Bz+4D3juVcQl2wlfkmUj
#@8M/6VuW/tv4ve1fPGlUQRc/d7Ic2ithoZWuTQsTKHyCIYGFlZaeFWIm1IBbWQv6AbbARxB+g2yRB
#@CEhUTBGiEI1RWDBhwybvCMsyDNfZ631seFn2zYEhvLeZmeXt7LDn3jvnTD2YqNxXPvoSLRyJ+4ju
#@EI2pxmcsVqkYdUxiRX+Z7MhZGEtYwgpJAKSPCxA0jgqEMb3K/aqwwYh+lrce0wNn8p/Jf+3JPyBo
#@lCKuUpGvvXudV0jIpZJ5Kwu6cCrIv/2cCAKYHRJM6pbJf0aGE4FotTptzDVb0At1Zx948J54tAps
#@95k4FuDP/vcPgfsrRG8AxHg8L7h4CiDcWWm/379rf7DE+SbXVKfZLLFBZxDUUfUA/3PV9/W8Q/I/
#@f1oQ49W3AgCca4P40ScergL3VojvfSjIcC222h1ILvmvZSUAUSTvgwllfKZ8/rU2QCD+al9i5P1M
#@gH6lTBbprLodlUSA/7iA6EuXrRJp6gRYN2yhQPsfMvnP5L+u5F9VABioyuueVZNQ8piIIKua2x8I
#@qJ782xD1rGaUBJPZaSAjwwFFuppotdsQEWi83iKuvyUW1olBQVeWV5PHJx+Ijz0ixrXzgtsXBKGj
#@N1PtPw+vUd6qj3Yj7QazlbYYDPDrHngrK2ybwBhXzgIxlnbEVR1yQOLFBnDjHfFmi2OCUR3MZaG/
#@mQdTqX+qsv8YVMZ4hM7ka5//WFBPjaGmFkNt1FLPFAI07UiMzL+R/Q9jqpHE+MGj59E6Abbgn5/E
#@6z4awkz+M/mvH/kfoTFtXvd0rNlKybjM2tzG3jo15N8UDpw5Emz/kM7kPyNDIUHABDH2DoGFdeBm
#@l+j+ov9YAIHFTeLlVyLGuZPA88uiSLj/rHpoEwjkqfmsdsRwBg4wAeFXr5fRViDsKmgtBLi5x/+W
#@+y//LnCrSzz7ROweQGOU9W9DJG+atQG1nX8xItYyrrQ/vlbrU6KBmEhKUY1BEBLFBJzRryD65/Ym
#@tW30SJBFMvNP9R7sKib++8jEkZ6iAHSQeN3H9nbM5D+T/9qRfwjQKOt1XwVoLv4KqwFkZue2k0dT
#@Rf7NYEAtFPfJVMvkPyMjlGB30mRsYxe4u8yhcNvPfQKgKQC31iOerhExWg1g8WoDiG+XVau3M9uq
#@g+dcvQ3ySJsBn14BSj8Lv7sCaOugXToz/AwDBgXwuZcu998elfvfWQK+/Em7UrQ6JzDXbOZNs8ZV
#@AGSwuRtT2q+uCUjSXiL8jV5iYoxwKF7vC6YHaXibbjsSUVp5jJqd+cdf9s49Vo7qvuOf35nZ+7Sv
#@H9jYAZuHHUqMk/J+NbQUKGrTUDVKS1uIBGkkkqr9o1LzRyNFqqiUtJFaKSWlpKRUbVFQBCWkqUAR
#@4hEChIdrHIeHDcYPfP3GNte+1/e9M7/uHa1Go6PZ41nvvbt7956v/dPMPWd2Z/Y1Op/f+f3Oryrr
#@cfmnRADQ2LFOgGN1v+ILBYrV7VyU0MO/h/8FA/8A5kxnYpshVZon+7XJgji3+37ZbvDvdgZ0JPzX
#@P8j38O+18CRiEjALc9YGUODJalrAg7tgLMp3BAxPwV9ugckIsvrO5YaV3XWW+VOgzjB3pb6V9W3D
#@stlRwTQCipYxrCc9wsk2QIFyfgo9BjYOQFY/OqBZ8E++E9/dSfIdscL9LUdTj5/1X4jS7FazoJuB
#@+LzjFazdvNl2hfxQfjs03r4JZR9mw7panspCuYdqpQuQmhKTbcif+a+Z92Odzjpt2uGSOtbzKwjy
#@Cgguefj38N/p8J8qdB/vBi8RaZoTQKTJnl7Fen2dfG73/RJA2g7+3ZEUItKB8N+440zEw79X58qE
#@IV1hQHm6TByVyWq0DPe9rzy8V/jiBcrdFesyAirEwNffitk3Dln98XmG31yVvRHaDGBHyeWMBWw+
#@kMxGC5S0VvIlBdbKaoa0jmZ1NDmeJ7dPa79mtdquWi5sPZG28spxBaAcww/3Kw/sgqOT5MoEAWHY
#@5e+VC1liRQEIYM+uS7ZRQSWF2xUDfaxduYTzVy5j7VkDnD3Qz/LFvSxb1Mvy/oot6qFUMizp7QFI
#@7mF9XSUAxqammSpHgHBidIJyFPPR6ETFxpPt0MgER0bG2Hd8hMHjJ5PtsZFxEPvitcZgwHZsiBUB
#@AIqCSu33AwFxDNot+tZax+S2Z/et/noHqeI6XrLX6eHfw39Hwz9A6D6+DZwA1v11ziVNfn3udIvm
#@nV+KjfGkFfDfuDPAl9uzASXHgy5C50pBVf1AdkFICEslNAyJpqeI45ishqaUb++ARwfhnnXK7Wvh
#@e7vh2SOQ1cWL4d6NNdbfEgCHM8CCU5EakCp25GzxFFYUZC7vMdrgIVqgWet0YqrDseB47iuXw0O7
#@SbV3FH5yEO7bqQyOkSsRISh1Yfzq/i1Si+7Z6vJCCVADbFX52PIBLlmzkk+et4pL1q5iQ2V/3epl
#@CcyfqSqPTR+/tK8b3EqdBrs/PMn2A8d558CxxLZV9g+dOAVIbW+luDyWSioVst1IXpi+PbiwugTk
#@tI4AA7akBqSrfS51g5a6gDR9rId/D/8dBf9uB4Cc0Q26M6IBpIWvT1r4/gqFZfFjC+C/8UGEiPhy
#@e1Jw0G21+ehXr/kiESHs6iYulylHZewv+MEJ+Ntt8IN9yi4r37s/gEeuMyj2uNeGb9sZkD9eUXU5
#@AxwRArgpW4XTS+u4Z8+lk0CLOicbme3PP++VS4VAlEhJNBXDV99UciVCEIR+dX+vnJlnUBRRobs7
#@4LILzuGai9Zy7cVrZrbJTH+rZDsNPrlmRWK3czFVJZEBm3Yf5PWdhyvbQ2wdPMrkdASqIHkQDUps
#@EaqgYkFyups/Qsz2qwIiabO4Zv7tdsmFdOsxOceJuKlbcFQJEA//Hv47Dv4BwgaApLOiAaSFjg5p
#@oaNFGneUS/vCv9shICCIh/86pFpgFk+9wyCVDzpouUwQ0lWxKJomKpextWMEshLge1cJfQFkI1/d
#@Y15HikC644zEdYOt5O6CUpd0lj0A7pn9xoDfndbgBn97pyeANX2wd9R9WzRBiSAMAPG/XS9sh+Kn
#@zl/NLZd+nFsuu4gr159LdylgPmnF4l5+99L1iQFMliM27z7Mc9v2VmyQt/cfR1WtkoS2Q0AtcLY9
#@pFjthrQ7tvsks+eY+Vd1wGBOZIZiRTU4QT6/WyDT6eHfw39HwT9A6D5ogUQDSEscHa2PuJDZZxxp
#@V/i3JTWjAzz8z5ryFvypjzucjOB526sOBTNwZ0KiKCKKyzUJdHEJNg8pFy6CpaV0UOse87qcATlp
#@Ak4QFpCi4CvkSmYZ8LXuDncev3uWvzj0u8+hDE3B4/uUH+yHw+OOShJBgAlCv8CfF1kFRli9tJt7
#@fvsy/vFPb+bspf10krrDgE//yrmJ/c3nfo0jJ0d5dtsgP9m6u7LdmzgIsjH7ioJYKQEKkN+WLZGo
#@KiDUzKlK9xCwZ/nEOfuXD+rqihhItw6nAXanh38P/x0D/wCh46CFEQ0gLXR0SAudLcKcKEYAkLaG
#@/8JrB3j496UGvTpJIgRhiCFIUgOiqIyt4WmSNQK+u0u57WPwhfPh4sVW7qsA1OMMsCDVNc5R0KLj
#@DW2TwBM37LuBvyHoz9/ZPqw8sheeOmxVdchb4C8o+VAlL7I8sGppNxes6OGcs3ooBQIsZSFo1ZJ+
#@vnD9hsTGp8o8/fYeHn3tPZ7fPuMMUIBMukBOvr0K2MCOkGyMOlMDSGQyTVptEtyzf5IP+eJyBBhS
#@FewCPPx7+O8Y+AcIrYOa6QRofTSAtDDiQUjV9GtoQp1/hVQyHyE0PzrAw7+Hf68OkFTLupkgpDw9
#@gSrYmojg8f0zpskq8n+4Rrl1NfSadKDbgDPA5RCoE5YFpOWQ3wDwNwz9VEv5wTOHST6zN4YKrA9R
#@6vYz/l6pShLRaya5Ym1IaJax0NXbFfK5Ky5KbGh0gkc37eDhn7/NtoPHsRcSdDsCFCRtc3hGxYoI
#@KLBQoJhiuftqA6nVj7vL8iZ4+PfwP+/hHyBsQq51e0YDSAtfpzThvW4N/LvXCpiPEOp2CHj4LyLx
#@sfle7ZvXW+rqBVXKUaZ0oKXNH2nF4N53lBtXwu1r4PoVINTvDEBBcDkE6hxLKShtJM1s6gL++qEf
#@4O1heHwfPHlQGYvc4z2RgCAMEfEr+3uBAL1mir5gipKU/RtSQ8v6e/izm341sf/bc5j/evkdnnjj
#@/aTaAIi1yqkhe2NSLPC3nAM1IwLESg3Im/m32py5+2oBnKtKgOIO0UI8/Hv4n9fwD0KIpYUQDdDS
#@qAeBJjldWgv/tgS0lUwqTaku4OHfz/x7zUeJEIYlqFhUdQSoam5UwNOHZ0xZ3Qu3rRZuXxuztk+g
#@gDPA7RBwL6CNNjAWbFRuOG/8MQpQHPoPjcOTh5TH9wv7xhSXRAwmMARB6G9IXomMKP1mkr5gEuO9
#@03Xp6gtXJ/b3t9/AI6++xz8/u4UDQyOAYEO55kYFWH/nAnm2LadiQO4iga7FU6Rq1FklwJF7JQDi
#@4d/D/7yEf4BQFUQ6yQlgOwI6FsCLX0fr4d+9cOB8hlC3Q8DD/4KX+rdgnikIgsTiOE6cARrH5Onw
#@ODy0R/n3PXDFMrh1FdyySjm3F7czwO0QcNf4FydEF5LM5TdV3U3uRjf07x+H547AM0eUXwyB4r5q
#@YwwmCGe2/vfolYb5z4B/TzCN+O9CQ1rc051EBHzp1zfy+OYd3P/cVrYdSNMD0NOmByggoBaEi3Wc
#@nRaAILngoqBOwCtWJaD+CgEe/j38zzv4BwgtWJ5Tafrzba4jQKQjAbz4dQgI0jbw7/DRdhSEKmqV
#@xBMP/15e7SwbIE0XqkocRcRxlOzbUuCNIa0YfOtd2LBYuPls+K3Vml08sL5a/1IbnKXh+20D0gJd
#@DQC/3fPesFaAX3j+KLw7rIVSOowJMEHg8/u9yIL/omCCHjNNSxRH6Klj6MnD6PCRih1Fx4ZgYhgd
#@r9jECExNwOQoABpPw/QEChD0IEFIou5+pKsHehYjiS2B/mWYgZXIwGpkySpk8UowAc1SVxhw53Ub
#@uOPaDTy5dRd/99TrbDv4kSNMX6sbYwE/YHIoXcHO61c7JUBcucBSuEqAu0KAz/n38N858A8Q5sDy
#@nAOBok13AiAgHQHgjZe7E5F2gH93VEDnrbifCw8i4uHfOx682lhSrRwQEBLHceIMUJ0xcrV9RCsG
#@/7KLJDXglrPhN1Yqly+F7sDtEAAQF01LMdAWZlc6aw4CN/BPRPCLE/DiUeX5I8K+cetgR26/CSvm
#@c/u9MgolZnEw3lTw15Gj6NFdxMf3osc+ID66Bz15COK4rpwYpdpenkDLkGjyFHrahT8MsvRjmJUX
#@Ys5eh6y4oLJdnzgG5lIi8HuXr+ezl63jR2/s5FtPbWLHkaEajgABFLJh9qKg5DsLENLjUKtsoNau
#@rSrGnb+fNjVSIUA9/Hv4n3fwj0AIMOdOAGlxNIBYr61FAN76WWDHtbQW/t3OgE6EULdTwC/45xcb
#@9GrbqAADlIjjqBoZEFNDSX76f35AYqGQRARcf5Zw3VnK1cuhZKwcAIdToDCJC2iLs1m0YA5ApCTO
#@klePKa8dhy0nsmX79PSOmSDEBMZ7/rzIyiTgP0GfmWJOpTHx0d3ooXeJD24jPrQ9menHlnIm8F//
#@qp8KEKFD+4lmbMdLUJUsWoE5dyPmnA0k27PXgRhmW0aEP7hqpnrAx/n+q9v5xv++xocjYwD5If+2
#@IwCwj0kb7fQByYkGSCXWoN+Rv6+AFK0Q4Gf+PfzPf/hXIHSEzTcBhpoQDeAoITrnkhauhSB1pSm0
#@E/y7nQGdAv/1OwX8zL+f+fdqIxkTJKaqaBwTxVGyraWywjvDM6Y8tAf6Arh6uXDNcuVTS5VLBiRp
#@A4dTgFpj0+alubuZ3t0xFsG2k8qbJ2HTcWHzkCZtRSXGEJgACQzif/Re2FL6g6lk1l+YG+nEMLr/
#@LaLBrcQfbEJHh0DT3hbDv9Z+2Mgxyu++ADMGSO8A5rxLCc67gmD9Nciis5hNBUa4+9OXcPvVF/Gd
#@Z7bw7ae3MFGOSSnarvOP2uUArZx+Ky3AKJBTKUDEgnstWCWgjgoBAjU6PPx7+J8P8G+nAMwBKEuL
#@1wYQLDXRESAtLI8oDaxX0F7w73YGLCAIVVXyJCIe/v3Mv1eLUwQkCDAVAyWO4zRVwKEEfH92VCtG
#@VcrKbtg4IGxcomwYUK5cJiwpYY+EirG3tDb+fyyC7cPwzknYNqyJ82PPKMQ5sOQO7zcYEyAV82n9
#@XjWUhPkPhOMExMy29NRx4p2vEL//EvGRHajGpGp/+E+kVr+ODxO9+1JiiMGc8wnCi28kuPiGWXUG
#@9HWV+Npnr+WPrvkEX3vsJZ5+ey8p4EvuGgFZGM/vF0Alf20AO3rAXSWg3goBlmMit8PDv4f/tod/
#@gLC+2vqNAkETowEEh5qZ8tBkR4DMDmSKSLvBv9sZsEBnoFW1JgCLiJ/59zUAvJoqSUA1qJgJSxBF
#@xBqjccVUAbeOTsILR7VipOXK1vTC+X1V65eKKef1Kef0CqEA7vjTOf0GlxUOjMPgaMXG4INRZe8Y
#@yf7+cYj1DB0qxmAkgMAg/vfkhTvcf8lc5PlPjRHNAP97P0vC+6lCv8J8hH/39WlEfOAdpirG8/+K
#@WbOR8JKbCTbciHT1Mxtat3IJj/3FbTyx+X3++r9fTtIC0gG4DfppuL/Vn+6n4J/ZBzBWuUBxVAlo
#@sEKAOtKbRTz8e/hva/gHMEUhWbVJEFr919wZ8MRaBiSqmlhLYMh9TW0L/7Y0/Rx96Lv1GeaZh38v
#@rzmWABIEBGGJsKt7xpJ9Y4qvUB8rCUy/dAy+Pwjf3K58ebPyOy/CFc8on3lJuXuT8tVfwje3KQ/s
#@hEcHNSmXt2WIBMgHx2NOTCsnKzYZx4DmWNKXHDM0nTyGD07pzHMkz/XoYPLcyTn+6pfKXZuoXIOS
#@XENl+5U3NLm2Rwbh5WPJNafwX3Tlfvt9ksD4n7jXaWf9V5ZGZhX+9cOdlH/6AJP/8aVkGx94u7Ph
#@H7UGUjHxvreYevo+xu//EyZ//A2iD7YwW/r8VRex+d47+eINlyAiYA/cNEvWWP2aWLqb3VdJ/1bs
#@6AHAbkskRT+jQrVYNe1WD/8e/tsT/h0RAI3Pljv6mxINIODWHKYFyKyVDmwbGIoVQBGReQNiNt+K
#@+NlvW6qKSyLi4d/Law5SBZix1EEXo1F0Ro65cgx7R0kMFLC2taf7CA30BaSh+uXYOq7AczTyPiRm
#@AsQYX67Pq24Fyaz/GN2mzKwoKiez/dHWH6PH9tiDiYUD/7bKk0TvvUj07ouYVesJr/o84YabIAhp
#@REt6u7nvzpv4/cvX8+cPP8ehk2PZlfsz+7Vy7O3Zf8k0F6oSMCsVAuxLQbA7PPx7+G9L+Acw9YND
#@Mxd/S/41HQpU22L2veUwpEjebPK8AzFVqubhv6hU1W0kWw//Xl4OFZr5LnUls96l7h7Cyn4SJTDH
#@YFyOYXiaxMpxE15jGBKUSpS6qzP8pS5fq9/rjGf9V5RGZgf+J08RbfkhUw/fQ/nZf/Lwn/9EieIj
#@u5h66h8Ye/Aupl9/DJ0cpVHdvOE8fv71O7jt0nX24oD5M/hqOyEVVKxogExf2qVklDmPLQWp9bkJ
#@oK5S43ny8O/hvy3hH8A0AFTNWwANbTIU1AmMMqcQ1kr4d1+XYGk+OQM8/M/G+VX1TK2pr12bbT5f
#@2Yv6JcZggtQpQFh1CoRhCTNjQXXWXNrKkZFetwnD5FqTa+7uqcJ+CROEGBN4753XGd+3EWUgGGdZ
#@OIpBaUjT40RbnmDy4S9TfuVhdPQjAA//dqNitybVBKZ++m+M338HUy881LAj4KxFPTzylc/w4F23
#@0t8d5gzAs/t2n9ROCRAAzXRpfnoBnL7eqgqQ36fWZeSkF3j49/DfdvAPENKArIobcyl3pQCZ+3By
#@kZbAmJ0a0Dr4tyWORQMdau9UAQ//zY50QTXzdwabNd2i1S2iVP+o/k8fn9168PbqGAmAMQAEAARk
#@pXFMei/WpCEzAabEgKDWeFlrD6I0uysYqn8IyQZMdV9AQYzxH5LXnCuUmOXhqWTbMPi/+STlLf+T
#@zP5X5eG/CPxb749OjzP92qOUt/4/e+cCJUdV5vHfrZ6emSTDI4RAQlYJEMAQMKKRN4K8H5FXBHmK
#@qCjLBl1QUBBhURcU1Cy6KCJRYGNAHhoVgi8UBQQ96ws9LEFQ9gAqaCBAkplMT/d/lzljn8491ZWq
#@6Z66Pd3f757vTM90V6puzcCp373fvd9yinucQPENx0Cxl9Fy4h47MnfrLTj1S8t5/LlVNVbtPOHA
#@k3x/SUB8lQABDgfKWiEgw27/Apyt+Tf5b335B0fUpM3XckMoByEKnfWQPPMeXv4Trm0cI9WGyb/1
#@3TBaP2NgpEzeyAx8kcIrUSxS6O6m2P2P5QUjMbLUoPp9NXop1nxu+JjubgqvRHH43yQqvBKFkU0M
#@I5N/I8+U/wblX5RX3MvgkrMYenCJyX8D8u+jgZcZvHcxa689naHf3AWVMqNl9vTJ/OTDxw/vDYCT
#@9/DtvU7aIJC4JQEuoR9KKTspiqwo9ocm/yb/LSX/AFHzUoHJDY00HLkjhRcSISQFkv/0a8fHO1Jt
#@mPyb/BtGu+AYCfsPzGhJCoUCGxUG2KyxlP/huv2l2z/M0A8XoTWrAEz+G5V/H4FWr2Td3Yvov3Eh
#@5ad+x2jp6+3mxncfxmXH7EUhqk3xl2c49fYKEMi7Z2kqBEipU/gF4JTxYUUm/yb/LSP/AFEzH8ol
#@8sOBRlqYknMts/46oPx3zmAADqTaMPk3+TcMwzCaTd+kSXx98WeHBwBGiwZeGpb+0u0fovLsoyBM
#@/sdA/v3rq/z1Dwx87TzW3fkp1P8SMDq3+9eDd+Xmsw5nUncRkPfwLf+88a8Vf52qeZVuhk/ehn8p
#@ywP6OJn8m/yHlv8qUfNrj4OUrxQIBRCSkCKYLNrh5b/Nlgi4NBkCJv8m/4ZhGEYjTNtyc+685Ysc
#@uN+ejJbK4w9QWnoO5RU/ASom/znJfxWJoYd/QP8XT2fo13cxWg6dM5MffHABMzbtiz+vAJRQJaBe
#@hQDqVwgQPvEb/vnn8anr+jL5N/kPIv8+0dg8lOcvRBpp4UQwqAz5oh1A/ts0K8CNdsmAyb/Jv2EY
#@hpGWnWdvzz3fvIG5O7+G0aA1z1O66+OUvncV6n8RkMl/HvLvI6pZGOvu/iwDX/8IWv08o2HOjCnD
#@gwBztpoCyJd5/yE8ZYUAed3wpFzCRwic0pcHTHZ9k3+T/6Dyj4OIzP3LKkT5SoFQDkKS80CAG7Vo
#@B5P/8IMB4SVU8sPkPxxWB9AwDKNV2WeP13P3bdex1fQtGA2VP/6c0i3vp/LkLwFM/sPJv/+C8hMP
#@0f/ldzP02AOMhhmT+/juecey13bTk1P/5S8V8PspcDWvUf3uSBk3/MtaN1wm/yb/geQ/axlA13C5
#@wMZwDZQMbBTXQOnARnHNLyEYXv59ApQUDNR3CXycM/mv4kycDcMwOojhdP8l115Jb28PmRkaZOih
#@myj/9k4Ak/8Wkv8qgsraFxm47RK6XnsIPYe9D1ecQBY2ntDNNxa+hVOuW849jzwNzkvxdzVG5NaX
#@D++H3ucERAhwMSUC5Ry42PKA9coR2m7/Jv8tL/8AkaRchEACKQchafayAJdDn/NNvQ8g/9mvdaR1
#@hABLNQFIlvZvGIZhtD/zD92fpdd9ZlTyrxeeYvDW80z+W1z+BVWGHv4e/V/5FyornyIrE7q7uPms
#@Izly7syY1H+oorgKAd7mgTGL+hX79yE80t1/R5qagSb/Jv9B5B8gApCU20O5lL8UCAUVEql1ZEg4
#@L+2+tdPPVdM6SYCluDD5NwzDMNqDBUcdylf/83K6u7vISuWJBxm87QL0wtMm/y0u//4HK39/kv7F
#@ZzO04n6y0tNV4KYzD+O4N8yKT/1HMX3xXsvLBMDvppBXIjBTCr+D9MYmk3+T/3zl398EUFKuadBS
#@rlKQXSJdDn0OIP8xWQHjJv1cNa1TBViKC5N/23jAwsLCYvzE/EP349rPXEpXVxeZUIWhB2+i9N0r
#@odRv8j/O5L/63uAaBm6/lMEfXw+qkIWuKOK60w/iyNfO9ETen+FPqBCgOpsEJpYIdADJ99wllQe0
#@tH+T/3Dy7xPVFULHmCMFkOCRFkpIpFD9dhteHoDGz477VJvNfgNSXJj8m/9bWFhYtFa8eZ/duf5z
#@l2eX/6EBSnd/ivKvvgHI5H+cyn8VicEHlg4PBFAaIAvFQsQN7zqUQ+ZsDQhQfHlAqV6d/9gSgQJU
#@b+ZfIj3KIPIy+Tf5z1X+AaJ0KfM5C7HDI8eBANd2/c605l8SksaVCIpqs9lvDykpTP4NwzCM/Nh9
#@3lyWXHcVPd1FsqC1qxhcdjGVP/0cwOR/3Mq/j4aXAvTfdO5wGccsdI8sB9hn1lbeyeX1XbHX7X9e
#@ta/rzfxL8TfCpSwPWPe5Xyb/Jv+5yT9A1CoiKIWRAqGgQiKBFFr+62YFjDsR1PrNZr+TcCBtKEz+
#@DcMwjObU+b/9xquZOGFC5s3+SrdfgJ593OS/veS/+qX850fp/8pCKs8/TRYmFF/ZGPAIdpq+mXei
#@mOUAqtNvgfCXC4DSzvw7+eZLIrK0f5P/sPIPjiiNCOZDuB3QhZAT4UUshPwHrtXvGFNEtZn8j/L8
#@UpYw+TcMwzDWZ9qWm3PL4kX0TZpEFvT3P1H65sXo5edM/ttT/qtUVv2F/hveR+XZJzKXCLxj4VvY
#@atM+cJ78q87suhQzDSjvfYdI/tvCJVo9kOWhSCb/Jv+5yD9AlOYASbkKiRREhsKUnnPxshVe/nPI
#@CnDkimqbk8l/jssOGAmlGVAA/GMle4A2DMMYhwxL/61fvZoZW21JFvTcE5S+dQnqf9Hkv03l30dr
#@XqD/xvdTfuYRsrDVppO45azDmdRdBDz5l6uzHEAIwCmm7w7klQesRQKXujSgbfhn8t9S8g8QpTuA
#@3GeBJZACyFCeAwEujUSFkP8csgJceAHW+s3kv8XP7Q8S4H0vkfzsknPYmIVhGJ1OoVAYLvW3y047
#@kIXKnx8ZXvOvgZdN/ttZ/n0kNLCagSXnU37qYbIw91VT+co7DybCAZ78x5QIFMS8Ry31BwEcIG1I
#@JsDHbWipgEz+Tf7HXP4BIrLPAucoBWHXIQu1UAp2DvKf12CAszKDJv+GYRhGu3PJh87moDfvRRYq
#@zz5G6c6PQ6nf5L/D5J8RtG4N/UsvpPzMo2ThsJ1n8pH5bwQBuDrLAUASOK8jXknBuoMALtHqiUcZ
#@RF4m/yb/TZd/n6gB6ctZgoMIydgIoWtoBjS8/Cf/XbSFhGr9ZvJv8m8YhmFk4IiD9+OcM08jC1r5
#@JKXvfMzkv4PlH0CMDAJ87YOU//IHsvCBQ+dx1Ou2BckX/PU3/JN8i023Dl8p+uq/dP43I8jS/k3+
#@85F/n4gGyDsFXAIpiJC0lAhKIAWQ/+xZAW0joUJ+M/k3+TcMwzBi2GHWNnzpPy7DOZdtt/9vXQrr
#@Vpv8d7b8V1H/avqXXkBl5VOZ3PKaUw9g1hab4g8CKKlEIOBnC/hr/hVfNo0UZFwqIJN/k/8xk38c
#@RE2SvQBrgYOKYEAZ8u9DEPnPPhiA2k5CtX4z+Tf5NwzD6HgmTZzIki9dmWnHf61dRek7H7cN/0z+
#@8a9Pq5+n/2vnozUvZKoMsOQ9hzOhu6t6DiGvE0roq/cZ5y8FSO4HqM4svmzDP5P/4PIPEDVR9HKX
#@Ail8vfnwEuqQQGr9GWhJ1WhHCZXfnEz+beDBMAyjo7ji0vPYfruZpGZokKHlV1ipP5P/utdXeeEv
#@9C/9ECoNkJbZ0ydz+XF7AyCpTolA/1r8n3uz8VLKmX//OBff0+Qqgib/Jv/Nlv8qUa5rwN1YlRwL
#@PgscSv4TKge0ivw3vHmgVRowAW8CsjoAhmEYY8z8Q/fntLcdTWpUofSDz1B5doXJv8l/4vWVn1nB
#@wG2XQaVMWt657xyOeO024OIk35E8CCBw/vW4hC6L5AdC2+3f5D+4/FeJGAMkBao9Hk5INNICyX/8
#@/SAwLvOeAW0vwIpvJv82828YhjGumT5tKld/8mKyMPTQEip//LnJv8l/8vUJAIYe+xnr7v0qWfj8
#@KfszbeOJ3sOxAymhE3HvueTSgABqYImwYqsKmPyb/DdF/n2iXHaEd+SGFFYKNNJCyr///ylp/MiY
#@pGp0koQK+c0E3DAMwxgXOOf4wqf/jc0mb0JaKk88SPlX3zT5N/lPI/8jiMH7/ouhFfeTls37JvCF
#@Uw4E1Qhpvf0APG+pvieXWBowuc6/Ejocd4yPTP5N/huWf58oDyHOD096HcGQE0JB5T95eUDri6Ck
#@anSiACu+mfzbwINhGEZLceoJR7H/PruRFq16htKPPg/I5N/kH5Th9ycxcMcnqPztSdJy0JxXcdLu
#@O4A/8y/vK95XP4U/1TOYvGM8ZGn/Jv8B5N8jynPzt1xxQWe/fYkLKP8+Y3xf3FiXFjQBVlxzMvk3
#@DMMwcmeLqVP42EXvJzWlfkp3XQ6Da03+Tf6zyH8VrVtL/62XoMEB0nLFgn2Y2tcLsOFBACnF9QkA
#@xVq9gDRr/hUnDjHI5N/kv2nyD44ozwdzSUGkQAovJBpp4eQ/h6wAl3NpQckktOb8Sm4m/4ZhGEbT
#@ufKy89l0k41Iy9B9i9GqZ0z+Tf5Bo//9VZ57knXf/wJp2WxSL59csA9I8YMADg9HcqYAIFEVOwlw
#@Ke+zzfyb/IeTf4AIAcrtwTzYzu8SSOGFRCMtsPw3//44giAJEaC84Dis86/kZgJuGIZhZOKwA/fl
#@6CMOJC2VPz5E+X9+aPJv8t+I/Fcp/fcyhlY8QFqOf+P2HDzn1aC4Nf+CWpFXnXMroc6/lGbtfkK2
#@QMKhTib/Jv9NkH9/CYDy3/m9iYRPf3eNVA0IKv+NZwU4wuHqZgeY/GdE6ZrN/GdAFhYWFm0axe4u
#@PvHRc0mL1jzP0I+vMfk3+W+K/INAon/ZFejllaTl0yfsS09XAaSYzgtw8VkCfp9dbT8dIsU9cqKK
#@bObf5D+A/MfuASBAOUqwhKQAUhA89d2XrvDyn/0etbwISqoNk/8mISegGn6r905T+21DABYWFhZh
#@4+x3nsx2M19FWobuvQYNvGzyX0euXW8f0YydKex0MF27Hk3X646m8JoDiLbYDqKCyX/MDwRozYv0
#@f/vTpGWbzTfhzP12rp35j9/tXyL+Jslfv+9XBcj4MJN0P3z5l8m/yX9D8p+8CaByluAAZd9aLfVd
#@Iy20/CdnBbS6/KceEDD5D3BuNdqc8BvE/qxFPNzSgw3DaE+22HwKH1h4BmkpP/ZTKk/+0uTf+yaa
#@OoviwefSe/YdTLjwZ/S+9xZ6TlxE97H/Tvdxl9Nz8ufpPefbTLz4F8Ovu+bOh6jL5N/7p14pC1j6
#@/Y9Iy0VH7MaWG08ACfDkX8n9ye5KAkc8spl/k//85T+5CoAA5V72LZyAqzVETIhKgHMHKLEYVIAl
#@1YbJv53bMAzDSMklF5zNRn19pEEDL1G+73qT/5pvopnz6Dl9Mb0Ll1Hc911E03YEF1GXYi+F2QfQ
#@89ZPMfH8eyjueSoUukz+axhYfjXqf4k09PUWuejI3Wqu2Zd/AcTsFSCv1F+VuCyAhDr/2vBogANk
#@8m/y33z5x0HEhsg3BdwTsrzPDVJYIRHOywhoTQmVqtEWIiipNkz+7dyGYRhGDDvO2oaTFswnLeX7
#@F6OBl0z+EW7SZHreehW9Z9xAYdvdGQ2ub3O6j7yICQuXEc3Y2eR/BK1eycDd15CW0/aazaypm3ib
#@9yWUBPREvl5VgPjnl4SZM2Wd+ZfJv8l/Q/IPEJEGJf2BjqmQBVz7Hkb+fTTSWllCpZBVFnIZEDD5
#@H1fnthUAhmEYY8WF576XQqFAGip/fZTyip+a/COiV+9K71l3UNjlcJpBNHVbJrz3Zop7nNKx8u93
#@qPSb5ZT/92HS0BVFXHjEbvXkP6a0f9I9Vr2rTVfnXzUvfPmXzfyb/DdX/gEisqAgNd8Dr30PIv8+
#@tWugW1rGpGq0lYRK8sME3Gb+DcMwOorZO27HUYcfQCpUYei+LwOVjpf/wo770/v263Ebb0FTiQp0
#@z//I/8dF4FxHyz8AEgN3fw5UIQ0L5s1i5xlTvH4IfCGX/Hua0Df5FQLqdEwNrPmXyb/Jf0PHRGRF
#@5IufDeDabd179g3/NNJyxTVw39pUQiXVhgm4yb9hGEZb89EP/jNRFJGG8qP3oOceN/nfdk963rYI
#@ij2MFcU9T6P7yAs7Wf6rlJ95lNJvvk8aIue44PB5IMX0R95Xh4f3EfkT91nT/usjm/k3+W9U/hsd
#@AHABBwIQkgKvew8r/xBgIMA1q4pAe0uoJD9MwA3DMIy2YM7s7Tn8oP1IRamf8kNLbM3/lK3pPnER
#@FIp4jMkgQNe8BR0p/z4DP7wWlfpJw9Gv246dttqsvvyrKgFev/2vxM/8SwmdVAMb/snk3+R/1MdE
#@DUmBAOUvJJKCypAEUgj5DzAQ4HIoKdjGAizJD5N/G3gwDMMYd5xz5mm4lBJQfvhOtGZVR8s/UYGe
#@46/C9fSRFz1v+SjRP+3ScfLvoxf/RumhO1J77cID51JFMXX+qZF/H9XPFhAJKCntX7bm3+S/SfLf
#@6ACAC7gswNUVq8Ap4CCFk38f1bTxIGNSNTpKQiX5YQLervIvCwsLi/Ef07ecynHzDyEVg2sZ+tWy
#@ji/117X7KUTTdyJXunroPWnR8NdOk3//+tbdtxStW0Majp+3A9M2mQjy1/y7+PNJ/gx+FW/mPzkL
#@wAEo3YZ/Mvk3+W/eMVHTHswFKHcpCLj+2hfZPOU/h6wAR65INUEHSag/KICQqmHybxiGYQTnrDNO
#@pLu7izQM/fpbsG51R8s/3RMovulMQuAmz6C499s7Wv4BtPZFBh+8jTT0dBV4z5t2WV/+8eVfACDv
#@q6utHOBIuOMZ6/wrxcy/TP5N/kd1TNT0B3MFkQJPmEJuehdA/jNnBbS+CErVyIFWLrGoemHybxiG
#@YYw5kyZO5B0nLyAFw+Jf/u23O1v+ga7XvxU3cTKhKO53Jm7Cph0n/z6D99+cOgvgXfvOYWJ1kMvV
#@Kw+Y9SEu/rWTd4xSepTN/Jv8N+eYaEwezAUojBRIapFN78LIf/asgNYXQaka7Sz/mZEUFyb/hmEY
#@RtNYcNQhbLJxH2ko//67MLi2o+UfQdfrjyMkrndjuvY5o+Pk30cDqyn9YhlpmDypl2N33S5B/onf
#@J0DefRBJWQBW59/kP7j8A0Rj+mAuQCEEXEgKLiQSSIHlPzkrYNyJoFQbHSb/2QcGbL8BwzAMoyFO
#@P/lYUlEpU/7d8o6XfzdlJtGW2xOa4rzjICp0lvz7CNb97FYoD5GGd+w9x7tfdbIAXAZZlqgSs7Fg
#@8iCNUsi/TP5N/jMfE+XyYK5QAi4kBReSihxSa8qQRtp4FUGJkTD5b2C/AT9M/g3DMIzh0n9vmDuH
#@NJRX/AStXtnR8g9Q2HY3WgG30VQKr57b0fIPovLS3yj97h7SsPu205g9bXKi/FeRvNk+JWcBuMwP
#@QPHyL5v5N/lv/Jgo3edyygZwYyo8Yc6N82S1NSVUNW28CrBUGyb/DW6umSVM/g3DMNqQ0086hpR4
#@a/87U/4BommvoVUozNqrk+W/evi6B24mLafvvVOM6Hsz/5mzKeV9MOXvwJESmfyb/Gd6MxLK98Fc
#@AaTAk5oA8h8jqi0roWkGAqzMoG26N6oBA0h4T0ICIXvqNgzDCMvwrv8nHHMEaag8uwL9/U8dL/8A
#@bsrWtArRtB07Xv4Byn9+jPLTj5CGt71xR4pRBAjkOZI8mVf1Wr0sAGKWCzgEIGWQJEcsspl/k//R
#@yz8OIiD/FHABCllyTkHk30eARDhcwxUErMygyf+YnDt+cEAxyxcACf0fe2cCbVlZ3fnfPnd6NU8U
#@VBVzAQIFMohM2kAAEQXERnFs7URtjRpsGzFLkk5it0lsbYyJrqQdo5jEGIzD0qUm7RBBAqJGw6Qg
#@cwlYQBUUNbzpTv8ktd6663rWfed99917zzn33v07a69333DeGW7xOL+99/d9QOvrnj9wHMfpmfPO
#@fg6rV60ghOad33T5n8OWrCQvRKs2jKn8xxBUf/RVQli3fIJzjj4QBNBB7LGELoAEkZcAX+ff5T97
#@+QeI4i3gqSIyoiULmck/BpCnJe9SSAbkdJlByQXcx/w7juM47Vx28QUEUZumcd9NLv8ACEoT5IbK
#@cpd/AUDttm+j6iQhvOSUI2ntbIn3rkMXACCSl+qX5r9JJsC6FiYZLv8u/0HyDxDFf04ofSlQliIo
#@JKUu/8mV6nzLmNq2UZFQqT1cwF3+HcdxxpeJSpmLnn8WITTu+R7Upl3+EQCGkRvMXP7nUHWS2u3f
#@IYRLTthMqWixY8fNUCAB8a5itT52Qv2a8E9e+Xf571r+W0QJgpeuFAhQdkIiCUkpy38GiQAbyCoC
#@IyehUjxcwIfh2MLIF/Lw8PAYujj/nOewYvlyQmj+/AaX/5hcZ4uP+Z/v/Gq3fZMQVi+tcP4xh7Tt
#@awnnam0XZh3utQKuQ2CAvO3f5X/w8g8QkYBQ+lIgQJnPfp6R/McZnvXu1baNqoRK7eECviDmrQbl
#@ctlLiY7jDB0XX3gOIWhyJ81f/szl3+U/9/IPUH/gX9GeJwnhohMORwvKv2Lnp/B7LCWM+VeHlwqQ
#@f7n8u/wHfMuIAsUu/Wd05WISshTkf/TWu1fbNsoSKsXD5T/Px1YGsWLFSjcJx3GGCjPjvLPOIITm
#@vTeCmi7/Iq+4/LfTbFK787uEcMFxhxARgeYRfdEBhVQagT5N+Cev/Lv8dy//ABFhZDP5mwBlKySS
#@kJSh/McZrgq0TMxtYyGhUlsAkgv4oBFGXlm1epXbhOM4Q8UzjzuaDQesD0wA/LPLf/wyXP7zKf8C
#@IHgegANXL+fYjWsQIvm8BTbPCgHSPJ0CMO9sgfK2f5f/wco/QLSIym76UiBAaQlJeCJAWA4q0HkW
#@wbSWFcz3Ov9SPFz++4VyPtng5iOOdJtwHGeouOCc5xCCpnfRfPwel/88yz8u//FP67+4A03tIoTn
#@bTmk3UE6dwEYINEtspAx0fGXcvl3+e9Z/gEiFoFQNlIgQNkKiSQkBcp/2lXn4RFBtW2jKf/JSJ3C
#@5X+glX+lH0cd9Qy3CcdxhorzAxMAza0/QWq6/Lv851/+22nWqd/7g+AEgHX8RZp/QnOUcB2BQwXU
#@S+VfLv8u/wt+MRr47O9G/1G2QiIMSUjKnYhJIA2XCCq2jbr8d58YcPlPlH8jtxz/zBPdJhzHGRoq
#@lRKnnHR8aALA5Z/45cvlP8/yjwCo3/MDQjh98wbKRUMINN85WuBQC4EEBmCdJwNE3bf9yyv/Lv8B
#@8h8jojeym/ldgDKR/04dAbmTUKkVQyeCattGWf57Twy4/GPkmlNPP51KueJW4TjOUHDyCcfvSwIs
#@iJo0H77V5d/lf+jkH0Htnu8HvV9LSkVOOGg9poTKv5R0jT1O+KcO8i9v+3f570n+ASL6hMhIggUo
#@E/nvlAjIoYSmmAiwFFYUGAv5D0cCAVKncPnPmiVLlnDKqae5VTiOMxScfsoJhNDc/gCa3uXy7/I/
#@dPIPoD1P0XjsPkI444iNAChE/uOvJVpYwDUnVf7lY/5d/nuQ/xjFfssagJllN8tplOF4YwMpq3vQ
#@3cojZsMngkK0Y1jbsX3Ju05IJGLm6/wPmksufRE333Sjm4XjOLnnjFNPJAT98i6Xf5f/YZT/Fo2H
#@bqew8SgW4ozNG/nz79yKqU2QBZgAo0XS1xEtQZHALLZL+9fUslVFi53wT4C5/Lv8z0tEvzEQyk6G
#@BCgL+e/YEZBbN5JAGm4vE3Ob5PK/SKSQ8Mp/Lzz/BRexYuVKNwvHcXLPqScHdgBsu8vl3+V/aOUf
#@oL71NoCABMAGALCE+yZ1Ovde1/mPXVTSdXvl3+V/jkBnjegnFpezDAVYgNKX/ziSWjEwrB8CONxF
#@WUnt4fI/yDkIghMHLv8AlcoEl774MjcLx3FyzaaN+7PfujWBCYC7Xf4lco7Lf8Jl1h+6jRD2X7mU
#@DauWxs7HAoYBAMZC98An/HP5T1n++90BYIlV2uxkSIBSkP9wSc2pCKYw63x2CQGX/0w7TcKD2OdN
#@Ga3PAQQI1DEpkd9nste94Y2Uy2U3DMdxcstxxxxJCNqzHe3d7vLv8j+08g+iufMxmrueIIQtm9YB
#@hqnt/OMXr/ZjCmy+RIESr19mbefvY/5d/vsv/wBRWlIglK2QKC35D5fT/M86n8Kxs0kIuPz7hH+p
#@csCGDbzk8pe5YTiOk1uOP/YZgRMA3ufyPx9y+R8G+UcA0Pjlzwnh+AP36/DvS8yLATJA4e+RFKv8
#@9yr/cvl3+Z/3R6I0pUBzW2ZCIkApyH8aiQAjBVJaci77hIAL+FjIvzKNt1zxNlasWonAw8PDI3ex
#@5eijCEE7HnL5Dzu/7HH57yT/LRrb7iOELRvXxZ5OEoYBmBZVnZRZl1VMQfs+8sq/y3/ofkYkKXUp
#@0NyWmZAIUIryHy6jw7Lk3MghqT1c/vMy278xMqxdu463vf1KLzM6jpNLthx9BCHoyV+4/Lv8D738
#@AzQeu58QjjtwLa2zU8J9tXkMND5GMT50wIwEfMI/l/++yj9A1CY/qUuB5rbMhESAUpT/cBHNuQjG
#@OwNGPyEgfKWB1FsVjZHj5a94FSeeeJKbhuM4ueOwQw8MHALwoMu/y//Qyz9AMzABsHn9yg7yr7j8
#@J59zHAkwZEYi8jH/Lv/9lf/4EIDMKtBC2QqJQEpR/sMFNMciOD7JAMxXGvAx//2hUCjw/g98kGXL
#@lnu/sYeHR25iv7VrWLZ0aYD9N9CubS7/wyL/uPwnnV9jx1Zo1lmIFRMV1iytdPAWg7j8K/zfhyzp
#@Xskn/HP5H4j8A0Q5qECHdwPYgMVDgHIlYjmtQI9RMsAI7xKQXP5d/hfkoIMP5g/+13u83Og4Tm44
#@9KBNwSsA0Gy6/A+N/OPyL+anXqe5azshHLrfSoQAgRLO2eY7ISWs8x+CXP5d/nuQ/8BJACVlIgWa
#@21KW/+Q5AixXFeiMRXCMkgFG10jqFC7/Lv+0c/GLXsTr3/gmtw7HcXLBIQcHJgB2P+7y7/I/GvIv
#@AdB8ahshHLp2BS0Pp/1I1vm6NX8iQGaAEpwrufIffo9w+Xf5pxNRgMxkJAVCKF35jyOyxxLel9SP
#@PTLJgCwmeoyHy3+K8q8cxtvfcRXPf8EL3Twcx8mcQw7cGJoAcPlPPD+X/2GSf4DmzkcJ4dB1K2lH
#@LfkX3SAzgN7W+ZdX/l3+Q+W/M1GwjEtkgUzZyD+AxewhbSxYKlM49hglAyzF4R3xQC7/Y0IURbz3
#@mmv4T2ef7QOQPTw8Mo399lsTmAB4wuXf5X9U5L+rDoD1KyZoYfPIv5JXCpAZC6LYzmYgb/t3+e9N
#@/uNEhP/CzNrPNbelLP8xUk4E2KJkcuhEUKI9ssdyM9QjHi7/I0ilXOFDf/ERzjn3XC9BOo6TFfsm
#@AQxBUztd/hMFWy7/OZf/ONr7FCGsW76krTBp2IK/W/HKf9L98Qn/XP5Tk3+AaJjazzW3pS7/cdSK
#@PMlYXB6HUoDFXPhye0nvbTx8nf8hplwu86cf/n9c9tKX+c1wHCcT1q5dTRAze1z+F5R/kR/k8k/y
#@+TUndxHC2mUTgICYyCcecx73kFjc4H25/Lv8B8p/MlGP7eeZyJDmtvTlP4WuAOt7i/nQCrDaw5fb
#@S0RSUnjlP+eUyiXe897/wzuv/l0KhYLfEMdxUmXtmlWEoOldLv8LVf6r0+QFVWdc/pPOT6CpbhIA
#@tuD7H/9cRgICdeqy7qHyL5d/l3+SMYh6lIJMlz7T3JaC/KeTCDAGwchMPCfmwuW/X/MNxL/m8p8x
#@v/661/PJz/w1Bx50kN8Mx3FSY83qlYSgmb0u/wny15onIS9M73L5V/L7p6mnAxMAS+a5CM17PJnR
#@NaH7iDnklX+X/67kHyDq49JnmcmQ5rYU5D/cUvMvgkMtwGoPl/++HVtSaLj8D4hnn3oaX/rq17n8
#@Fa8kiiK/IY7jDJxlS5YQxOyky3+C/CNoPHYPeaG5Y6vLP8nvn6b3EMLScjG2ezKKl+Mlwp/N5GP+
#@Xf4HJv8Coj4KSeZjzzW39Sb/GSQCjCwYqVnn1R4u/6kcW1Ln4Fe7C5oisetAkj99x1i6bBnvfs8f
#@cd0Xv8xpZ57pN8RxnIFSKpUIol5z+U+QfwGNB24hLzS23e3yT/L7p3qNEMrFIgsi9aHyr6D7EC7/
#@cvl3+add/sGIBjT2PFMZUmuz7EVMgIZm1vmREWC1h8t/7sf8S5oLkARJyYX277f2ZSSTCcdsOY6/
#@vPav+cS1n/mPlQK8I8BxnIFQqZQJQY2ay3+C/AM0HvyX1rjyrGnc932X/4Xev3qVECrFqO13x44h
#@wtv+pfC2f3nl3+W///IPECXsn043gA1OPITyI0NqxbC0gI+UAKs9XP59wr8h44wzn8uff/QTfO3/
#@f5s3X/E2jj52i98Ux3HS7wBo1l3+UfLl1mep3/pVsqb5xP00H7/P5X+h968R2gFQSFjnH0Ax+ReJ
#@N1rytn+X/0zkHyDCUhlznrb8x7sB8iViIluMGCkmAywf1672cPkfffnXaMTBBx/Cb13xdr7w5a/y
#@zX/6Hu+75oO87g1v5MznPJfDNx/Bfvutp1KuuM04jtMV5VKRIBq1sZF/W7qa4ikvpfz8Kymd8Rps
#@zUELyz8CoPq9T0Jthiyp/cuXguU/Wnsw5bN+ncrF76R02suxZWvGQ/4B1WqBHQCFhOea/kz4JxGC
#@y7/Lf0/yD1AkJSRhZqnJfxy1Lt9yI6EoA0Gy3od1mNkQy394TsZc/r3yn2M2btrExZsu5eIXXeo3
#@w3GcnigUdhPA2Mh/8cRLKL/43VhlOcxRvvhqajd8nOq3PwzSvPIPoKcfo/rPn6F87m+SBZrZS+3m
#@zy0s/2ZUXnAllfPfAlGhbf/fZ+bvf4/aT74y0vKPQEYPCDBkHc7FbGH5F2CAAPPKv8t/CvKfZgIg
#@LpEWWWryH0fWSgTkR8aUkqwZMVJIBuRf/sOnTXH5d/l3HMcZQSTDTCxIVIRmdaTlv3DEmVRe9n6w
#@KHbtBUrnvgXNTlK74ZOI5POr3fAJSqe9DFu2lrSp/tPH0PSuBSv/5XPfROWCK4hjE8tZ8poPor07
#@qN9z0+jKP2DFEiHM1hsd1J/kyr8A65AYaO2Dt/27/Kcu/wARaWODmaxLXd5IzW25kzEBGh4RlNSK
#@4ZT/cBQPl3/akRu/4zjOUCIjCIuKIz/mv3zhO8Ai5qN03luhvHTB89PMHmb+7reh2SBF9o37r97w
#@yQXl3ypLqVzwtqQ3m8ol7xph+Z+jUCSE6lwCwBKW+gsoJ/VX/uXy7/IfJv9xIgkk0sE6ymPq8g8Z
#@JAJsMbY5XCIoqRUjJv/hSQGXf8dxHGfIkAijUBpp+beJFUSbjiMJKy8lOuSkoPNr3Hsj1W/9GalR
#@n2X6s1dCvZoo/wCFQ0/GKktJonDQ8diSlaMr/wgrlgM7AJrxSn7n9z+xIGaLkAADU49L/cnl3+W/
#@cwfAwBIB4UuApSr/cdS25UrG1Iphaj9vX7Jt7GbcFyAD0Rbe9j9IfNiB4zhOGi0AxdJoz/Y/sSJI
#@0mxiefD5Vb/7ceq3fYOBoybTn72K5qM/C5ntvyX2iZjNXetIyn/r33QI1XodAEnQ64R/0uIq/wrc
#@R175d/lPJiKGlOms8ynLfwpdAdZvsxy+seeSWjHOy+0pHi7/Lv+O4zg5oGkEYZXlo73UX6NOEMVy
#@+PlJzFz3Tuq3f4OB0Wwwc93V1G//h/Cl/koThKB6dVTlPzwRAkxVa78q8lLScXuY7dt8zL/Lfz/k
#@PzwBMJBuAFtUG3kK8p9CIsBS6DsfsrHnktpj7Jfb03zh8t/3a5eHh4eHR8doyghiYsVor/M/s5cQ
#@bOma7s6vUWfmb99B9fqP0280vYvpT72J2o++GC7/InxywtnJUZX/1nKPITy5d5pF4BP+ufxnIf/h
#@CYCBJAKs5/HkWcl/74kAIx0EaIgFWGIufLm9EGF1+ffKv+M4Tl8JTwDYkhWjK/+AqpNB6/dHqzcE
#@nF8MNal+4xpmPv1GtHs7/aBx781MffBS6ndd3438t65hITQ7iarTIyv/CKJlqwjhqckZaKFFyL/C
#@158yaCGXf5f//so/BhEBSNkuOSepB/nPIBFgpI8ADbeISWoPX24vNDFgba+zl3/PBjiO4wwZDYwQ
#@rLJyVOW/9aK5+3EWwvbbHC7/sfP7D1mf+sCF+7oBVJtmMTS3/Zzpz/wWUx99Lc2nHula/gGiA45k
#@IfT0YyMt/wC2dFVgB8Bsl8e3cOFHXvl3+U9N/gEiApFAyu4ZXBJNpXDs8ERAXiU0BRtM7z2fC5d/
#@wo+tpBhK+Y8f0Nz1Hcdx+kizaQSxbPVIyz+AntzKQhQO3NK1/LfTnNnD7DeuYfKPz2L2a+9DM3tY
#@kHqV2o++wNRHX8Pkn1xM/fZ/BFiU/GO2b4b/hWhuf2Ck5R/Alq8lhJ1T06m0/Usu/y7/g5V/MCK6
#@RAIpi+q7tUlhPuRbc1uuJVSAhl+AJbWHy38Px1Z4ZC//Zl7odxzHGTANRYQQrdx/pOUfoPnYPSyE
#@rTyAaN2hi5J/QQtN7tq3Zn/jF7exEPUHfsDMde+ice/3QVq8/APR+s3Y8nUsRGPbPSMt/wCFtRsI
#@YfueaR/z7/I/EvIPELFIpHTlP0au1psXQiaE8iuCasVICLCk9qUGXf4HhOaiibVeywbUYWDe5e84
#@jpMFdRlAiPiOtPwjaDz6U0IoHH129/IfeH7J10RP8g9QPPbXCGBfYmKU5R9EtPYgQtj65O4uH1BE
#@EHL5d/lPV/4BInpAAikF+Q9Ybz5TLKErIHURTDEZYGSLzdsh4PKf4Zh/BQRYwM8s4vv+HO84jtM1
#@dSJCsFUbRlr+BTQe+jEhFJ/5gqGUf4DSyRezIBL1B3880vIPEK3ZGJgA2OOVf5f/kZB/gCJ9QAAC
#@M/qKwm9kS/rMLBcyJgSAYfkWQUELGyr5T0QS7ZiZy38ex/ybgUQQ5obvOI4zCBrNiBBsxXogAhoj
#@Kf8A2v0EzSfuI9r/SJIoHHYK0brDaO54aPDyT//kP9pwFIVDTw5o/78b7dkx0vJPVCRavT8hbN2x
#@m3kxXP5d/nMt/3GK/a3CAoBZavIfI+VEgBEjxUSAESOVZED+5T88IeDyH/TfoPpzbAPkk/s7juPk
#@kYYMAQbJRAVs9Ua085HRk/8Won739ZSTEwBgRum5/5XZr7wn1/Ifp3zWbxBC/c5vj7b8CwrrD4Go
#@wELsmZll59QMYN1X/gWYy7/Lf7byH6c4CCGRwCxN+c8gEWB0hVDbrpZ/ERS0sCGW//CEgMt/+hP+
#@eeXfcRwnJ9SaBcpRg4WI1h9OY+cjIyv/APU7/oHy2f+NhSidejnV734U7X5i8fKv9OQ/WrWB8mmX
#@E0Lt1q+PtPwDFDYeRQj3P7GLX8X63/YvwFz+Xf4HL/8Axf4LSbwbIAX5TzsRYCQw4K4AI300rPIf
#@jiTimJnLv1feHcdxxiQBEAUmAA6jcc+NIyv/AM2H76T5+L1EBxxFIqUJyhe8ndkv/s8U5J+e5B+J
#@ykVXQbHMQjQe/dm/x10jLf8AhU1HEcJPH33Sx/y7/I+M/AMUexeS0ERACvKfRiLASGAgXQH5klBl
#@dD5G6kgiXoE2s/GSf/VQse+1dG+AvDvAcRwnDarNAsuosRC2/vCRlP/4y9oPrqNy6e8FdAG8lPqP
#@/p7G1n/tQf41cPkvHHHavnMNoXrTZ0dZ/rtPAGx7khj9l39z+Xf5T0f+AYppCUk8EdC7/GeQCDAS
#@GEhXQE4r0OklA7K/9qBOAa/8D/raDZALv+M4zqCoKSKEaP0RIy//APUff4nyBf8dW7KSRCyi8vL3
#@M/2hF6Pq9MDknx7k3yaWs+RV1wRV4zS5k9oPvzjy8g9Q2PiM7jsAjO4wAAO88u/yn538xymmJyTx
#@REAv8p9BIsBIg3hXQA7lP7VkQI6vPSgp4PLfy7XLTd9xHCdNqqErAazcH1uxHu3ePrLyD6DZSWo3
#@/xXl868Imheh8tI/YvpzVw1O/lmc/GPGxCveR7TfoYQwe/1four0yMt/tGZj8AoAdzyyPbmKiXnb
#@v8t/ruU/TpSVkEjZyX9c3iTlUkKFkGn4xp6rFWO73J6kTjGi8h/vXPHZ/h3HcYaNhiIaMkKINm0Z
#@QfmPI2o3fhpN7iSE4smXUj7vLfmSf6By4dspnXwJIWjPDqrXf2rk5R+guPlEQnh89zRP7J4CfMy/
#@y/9oyD8GUZYC3JQhZSoEcWHLpYSqbRu6sedqD19uT1KnGFr5d+t3HMcZHWabhdAEwMjLP4Cm91D9
#@5ocIpXLhlZTOeFX38q/ByH/57N+g8oL/QSgzX/8Amp0ccfkXIIqHnUQIt9z/6GAn/DOXf5f/NOU/
#@1gEgiY7Y4MVDAik/E79Jyq2Eam4bWh8Tc+HL7bUjCZGQGMiR/Md3MMvqvlvHnRtNEUc+msBxHGdB
#@ZhtFQogO3DLq8t/6UPvhdTQfuYMgzJi47H9TPucNmct/5XlvYeKydxNK48EfU/3+daMp/3EExc0n
#@E8ItDzwWXw/bK/8u/0Mt/2BEHeQ3VfkHOicCjCxpyVheJVRt29AKsFoxZvIffmxJ88UojfnvK41G
#@gzhNNf3J3nEcp18dAPtvxpauHmn5b9FsMPP5q6E+SxBmVC75HSYu/2MoltOX/1KFJa/+AJVL3hWc
#@oVd1mqm//W1QY8TlXyCIVq6jsOEIQrj5vkcJp/cJ/8xc/l3+Byv/AFFCNTIF+U/wQpEd1lHAcitD
#@mtuGWoDV9lEu/yFIWijGTv4BavU6cZqNJpI8PDw8PBJitmlIxoJYROHQk0ZW/uM0H7+X2a//X7qh
#@dPorWHrFF4g2PKNP8s/CS/1tOoZlV36F0mmX0w0zX/5Dmo/fNxbyD1A8+rlBpj1dq3PHIzsAwCxA
#@rAysS7lu3w9z+Xf5H7j8A0QJP9h38RXWpXyDRLrYgsKVkQwNpCsgvyKo9nD579ecA021fQ0hKbsL
#@tsHclMnZWeLUGg0v7TmO45CMZOFdAIedNrryH0eidtNfUb/t63RD4cAt+4S8ctE7scoyWoh+su93
#@T7zoapZd9bV9SYBuqP7wi1Rv+puxkX+A0rFnEsIt922jWm9CHLNFrPNvi2v7N5d/l//+yj9AFHK9
#@klKXf8ggEWBdSVUKx04hGTAsVWC1h8t/P9v+JXUTg7t2s778mj2Tk8Sp1TwB4DiOE8J0o0AIhcNP
#@AYvGQv6ZY+bzv0Pj4dvpikKJ8nlvZtnv3kD5/LdiS1aTbLPh2LI1VC64guW/fyPl898MhSJAV+P+
#@p6+7euQn/EO0UFSg9IwzCOFbd22FdoxuJdLH/Lv8507+AaIuq98pyX8GiQBbdHU19yKotm1Y5D88
#@IeDy34P8D2zoQWvr/L2B3rA9U9PEqdbq/lTvOI4TlAAoEoItXUW06ZixkX8A1aaZ/vSbaG5/cHGy
#@/sKrWP4HNzHx6j+heNz5UKrQNaUJisc/jyWv/TNWvPtmKhddte93d0tj2z1Mfux1UJsd+Qn/2l8W
#@Dz8JW7aKEL5150MBFX2j9doCH2Escvl3+c9M/gGiHqrfKch/ComAPgtR/kWwtY3O+G/Fw+W/b/Jv
#@NrClLZEgKYEgAfHvgZjnZwBJ7Hh6N+qQAJAvBeA4jrMg1WZEQxEhFI8+Z3zkHwDQ3ieZ+thrY0mA
#@7gS+dMp/ZsnrP86KP/wJS9/6OaL1h0My+35m2RXXsfK9t7L0DZ+g9KwXQ2mCRbBvvP/kX7waTT09
#@PpV/AKBy8vMJ4dGde7lr21NgCeeLgQU8P6lPlX8L3M9c/l3+k/eJeqx+91n+M0gE2KCWEcy/hGpu
#@G0kJVnu4/Oej2yP+wgZyI2ers+zeO0k7kpip1vzJ3nEcp5/DAI45GywaffmPH2vXY0x95NU0Hv0Z
#@PVGaoHDE6URrD4Jk9v1M4YjToFihFxq/uJ29H3oZ2v3EGFX+54gKlE44jxC+2Vb9N2IkTtlvCSce
#@Iv9x07eA/Yzkyr+5/Lv8007Uh+p3n+Q/g0SADXzytaGoQKttG0UJhlgiQC7/o33txvadO4kzNT3r
#@T/WO4zgBTNWLwW3t0YHHjZX8txR4z3amP/JK6j/9DsNC7bZ/ZPLDL0d7nxybCf8ELUpHPptoxTpC
#@+NrtDwDGHAmvuxXrfs6d5G3/Lv+L2yfqo+z2IP8ZJAKMVJDUinxWoFNJBuTv2hUPl//BXruBsSjM
#@rOshC1u3PeEJAMdxnEUy3SzQxAihuOW8cZP/FpqdYvraN1O9+W9AIrdIVL93LVOf+k1UnRpL+UdQ
#@ftaFhPD01CzfvesX81fXLVAkLVbFjwzC8TH/Lv8D2yfqt+w2lb0MSSDlT0IlIZQj+U85GWC+0sBQ
#@yr8ZIRjW+7Vb6P9Ik3v+Hn78ceLsnZzxp3rHcZwAJAvuAihuORcrLx0P+Y8j9iVAyqe/AszILWaU
#@n/tfKB3/vLGVfysvoXzSBYTw1VvvpVpvdnj+iDo1AsTeexFewfel/lz++y7/GSQAsIXb343UkEDK
#@n4RKasWwtGArto3FjPuKh1f+c4fZ3AfDoMVD2x7rsDrADI1G05/sHcdxApgMTABQWkLh6LPGUv5t
#@6WomXnkNFErknkKJJa/5033nPA4T/sXfv/IpL8QqywjhCz+6t0Ph35ABZoQXTawraTULEXlz+Xf5
#@T9gn5QSAMGLkpvVdAimXEppOIsBSWFpwXGbcV6dw+e/pD5L1+YQNduzazfand0E7Erv2TPlTveM4
#@TgAzzQJNGSEUT3zh2Mk/QPGZF2JLVjIk7DvX0okXjcWEf/H3r3LmZYSwY88037vnEZKH7ydJfvzr
#@Fiig5pV/l/9U5B+DaBDyH0dSLoREAilvEjrgrgBLdWnB8V1uT7FgHOTfEr6cPXc9+BAxPAHgOI4T
#@iGTsrZcIIdp0LNEBR4yV/ANE+x/OsBEdsHmsKv8AxYOPpXjIcYTwdz+4m3pDMIdh3UukRcyLWbjI
#@m7n8u/z3Xf7BiAYi/3GsJbg5EMH0EgE9LrGYVwEOTwYYWZGPY6tT+Gz/Pf5BT+6AM2tLAGwlztN7
#@Jv2p3nEcJ5C99SKhFJ/9krGSfxCa3s2woaldY1X5B5j4tdcSyrU3/bT9oaIlTKLLKr5BOJaQILAe
#@5wkwl3+Xf+Idt1EK8t9Orsa+S63IQIYG0hWQKxFUbBsj+U9GncKX+gOgj9fz860PU280aKdWqzM9
#@46sBOI7jhFBtFphtFgiheOx5sHL92Mg/QOOu6xk26j/77thU/gGi1QcET/53y/2/5O5tT8Zm++8g
#@5tbpyJaw+pG17e8T/rn8Zyv/AFE68p//se8SSDmU0PD7lXsRVNs2RvIfjuYLX+c/8aDWefWAaq3G
#@/Y/8kjg7du7xp3rHcZxA9tRKBFEoUHrWi8dG/gEaj/6U2g+/wLBQveXzNB6+Y2wq/wAT57waCkVC
#@uPbGOzuO2xdzWFKbvsX263KJZFvss4+5/Lv8dz3XViRAKch/6okA63nlgOxlKLwrYOhEUL+6ufx3
#@mRyQALVekCkWev3W4Y+XBf3NtYSWuKRdb7/3/o4JAEn+VO84zr+xdyZAcl3lvf/9b/fsI9mWxGJb
#@tjFeH2AwvGDzjAN52LzHw++RheWFGCcBsgBJCEmlyAKpygKBkIpJKk5C4SxAitjgBLCxHQwkMWAs
#@20m8yArYsiVZ1q7RaDbNTM/08iWZorrap27fPj09031n9P2mTvWo+3bf7itp5vzOtxwngtlKX3wz
#@wEuvQQMj61r+w8dKf/dBFu/5DNSq5JZalcVvfor5m39t3Uf+w6aHA//jR4hhYrbEFx58IpirxDYA
#@FAAoXkjDcgFphSL/cvl3+c+Q/zADwLog/11bCBABXVwIEAFdXAwQvUW+zWA3sLRzm7Ucq4K6VRKQ
#@lYKnpsf+63cfSy0DmJz2XgCO4zgxGDAT1wxwSf77Xv4jJ438A1Ats/DF3+bEh19F6bPvo3TLB5qM
#@36D0+dZj4R+up/zALf81lr5fuv9z/zV+nflw3Nw4fi11zH36vcz81iuZv+U3oVpe15H/kMHXXIcG
#@R4nhk9/YztxilUZhEsJaWr0yGvcpUuQV0SxQgDzt3+W/Y/kHKKb9v1KX5T+UWgBJOUm9p46UXwm1
#@hp+ykta8BDcuAgi5/GfIfzRmRCF1/7MLMAFGFJGHzs6XeOSJJ/nvF19EI2PHpzntlFGf2TuO40Qw
#@Xe5jY7GMZLSieNkbKf/rl7DSzHqW/wDDJg+x+OBtYAQsT67D92edvb81HvlvX/41ciqDr3orMSxU
#@qtx49yMg6mTX/4fyr1ghzY7iGyCv+Xf5X3n5D0kykmy6Lf+dZwSI1SQ7kCq6T/4bLcYTnx3g8r+K
#@547PJki7D4RW8EKJVNTen7dt30HI5MwcC+UKBj58+PDho8WoWMJspUgM6h+h7/I3n1TyD2Dg8t/D
#@yH/I0FVvRwMjxHDTfY9xeGY+OwiitCZ/MfIpkNJEPj7qL5d/l//O5D+kGCUcXZD/iIyAHKXeA4CU
#@SwkNr13W9VurWw0GWVdy+e8mahKKN0t7txA+ZgTfW3BceHzDrSztsWAu0Pgc4/E9+xifmmbzKRup
#@Y8bRY5NsPX2Lh/Ycx3EimKr0MdpXJoa+7/thlrIAToy7/Lv8dzXyD5Cc8hwGrnwLMdTMuOEfHyJE
#@qVX/CsR8mXv2J20KdnisXP5d/iPkP4OEFhjCei9DuWx8ZwZGD1E3thTMf+q9YeGXy/9KI63C+QUi
#@GiU0py78aRl1xv0pWQBHx6eoVKs+q3ccx4ncEnCu2kcUfYP0/8A7XP5d/rse+cdg+A2/iPoHieFL
#@//ZEfeu/9IbFIWouWlL2HEfp0UMtM+0/+/yA5PLv8p9KEtvwzwDrnQyFIpsrCTWrj+6hFWkeuLbl
#@P75swOW/G59dy38RtUq1U9pjIkQCS3mdb2/fQblSoZFqtcaRsUmf1TuO40QysdhHLMUXvZbk9Itd
#@/l3+V6/bf4hB8ZxL6H/Z64ihWjM+fPv9IKXOPQxAanz8e6MdgRb1oWyzzJZ/edq/y3+E/MeRZMl/
#@y/4AoruEEovlTIa6tBCgLmwruBblP35BwOW/l59dBKjDN9C6tm7qxCzffvhRQo4cm6RSrfms3nEc
#@Jy4LILoXAEoYeO17QHL5d/nvSuQfieE3vR8kYrjlgcd5/PDxyABFkhrdz+78n4Bi/V1BzwB5zb/L
#@f5vyH08xVv5DTD32EqX0COgWanf3gDyJWHTPgHXdcd8wQoRc/nv92SUwAyy92394hwCr32bdydcf
#@+Bdeeekl9BWLhFkAZz53k8/sHcdxIpgoDzBSrBBDcuYLKL7oairbv+by7/K/4jX/4YEDl/8gxbNf
#@RAyVWo3fu/0+6s+X1YVdKGOrv4wU/5hMRrUS2fA4l3+X/1j5jyfpdKs/A6wnQtKjzvdablP13IpY
#@fGaA1reEGhZ+ufxrhQ6SaA+B6rcNGMtlcuYE2x7ZkZIFMEGl4r0AHMdxYijXEmYq/cTSf9W70chp
#@Lv8u/6sX+QeSjZsY/qFfIpZP3bOD3cemQAJlpP+jjMZ9oo6UrlfKtn8JMOK3+pPLv8t/Z/KPRNKJ
#@/EMPFgIUJa45k9AOegXkp9xiNa5t/j+7jODL5b8FQp2fRwQEmT4ZW+pIzdPqvvbAv4SN/5ayAPYd
#@Gvd9vnz48OEjckws9FNDxKChjfRf/W6Xf5f/1aj5r38z/MZfR0MbiWFyrsTv3rqt5YKEUHrjPtEE
#@gbQMsRZ1EkVOlJLgjy7/Lv9EB+SSTuU/xABbj13vRQarnBUgeos6vrbrqtmgpX+5/Hd4IgFYs7Q3
#@ddwHAGBieoZ7U3YEOHZ8ihOz8x7acxzHiaBqYnKhn1iKL3wNhfNf4fLv8p9Gx/Lff8lr6L/0amL5
#@yB33Mz5bCgUsSP9XEKIPow0t6v+l+CxKaRX2+ZfLv8t/02zcpD35j8fy1/U+p3X39ZFT+Y9eaFl/
#@8t95CcH6kn9p5UoG1OSJyXI63WYcIxFy57e2MVcqEbL3wBhm5jN7x3GcCKYrfZRrCbEMXPMraPg0
#@l3+X/xWN/Gv0NIbf8gFi2Xn4OJ/850cAMrr/C6RA8kNhU/M0/yRV2ILbwNyVNofxmn+X/5WXf4Ck
#@A/nvXjaAVrSuPcd192C2dqPAZtY41rH8x2PNv7zhX/QPbIGIIK4M4MT8HF/+xrcJmSstcHR8ymf1
#@zrI5dHScbz/wKHd8/V5uveseH50P7vynbdz/0HeYnD7h/8Byhpk4vjBALBo5jf7X/5LLv8v/ikX+
#@kRi99ndINm4mlvd//huUq7XgtQSAGsRegaC13spPoHayF5OgsiACufy7/Hcu/wBJN4TAAMuPkMQL
#@qugJZmCAWR5FsAtlGDo5BNgwao1llQJbJ/IvBCHSipxbCr9Ju83mnoe2s+/wYUIOHBmnXK74zN5p
#@m+/sfIoHHvouxyamfGvJFaRcrnL46HG+ed8j7D805hckZ8xVi/HbAgLFC19J30uvcfn3yH/n8g8M
#@Xvmj9L3g+4nl5vse4+v/vrcxop/yvSBRRhp/mBmgdLFTpG0moo4UV+KInin/cvl3+W8vezfppgwZ
#@YL2XsVBQ8yqhnTcOzN2iS32clPIfYij13JY11mXkXyAAofisgI7KAEzGTV/5R2pmhA0Bdz192EsB
#@nLYj/0/s2e8XYhUxMx569Ammpmf9YuSM8YVBaiZi6X/te0i2PM/l3yP/Hcl/4YzzGXrD+4hl/MQ8
#@v/r5u5tG50UCgIkUFByutPr9UPzT75ci5y6dpP3L5d/lHySakfRCCAywfG55l0MJ7fJigHybwd7I
#@fzyWNXr22Ze5zZ9if9Bp+T/3LLxDYPD0kcPc+8ijhMzMznNobMJn9U40u5866BehC9SsxuO7n/YL
#@kTOq7ZYC9A0y+ObfQf0jLv8nl/yvWORfQxsYfefHUf8AkSzJ//hsKRB2o1HiTQJAQXQ/VcyVNG/4
#@p1DCQ+0Sarfhnzzt3+WfeCSySHoqgYDlbds3DDPLuYSu0kKAfJvB/Mp/PBYx6qiH11NtHqTllAFk
#@LzLc9o17mJieSSkFOO67AjhZhLtL+EXoEse8T0cuman0MV8pEEuyaSsDb/hVkFz+Pe2/LflHCaPX
#@fYjClrOI5a5H9yyl/0NYs6/srv5qJm/KFP+AyHmJWmuawJDLv8t/NhKtSPIQhTXA8hUF7r6MqtNd
#@BNZN87ewXMDlf6UJeg7EjDpSx30AsqWczssAFL894FypxKduu5OwFACzpVKASrXqM3unJUkivwhd
#@wvDynLwytjBI1UQsxYuupP+Kt7r8e9p/vPwDQ//rp+h74auJZWxmjvd85qsgNYn+g6SG6H+r5n8J
#@QIs0/bAsoOE1lDWnUvtp/3L5d/lvf56ehFHYXmICy1cKeHdEVF3YUjDv8h/fP8Dlvwef3aKG0u9v
#@em6lraqvShlAnUSED+zav5+v3HsfIYvlCk/tP4K3A3BasWXTqX4RusSpp4z6RcgpVUs4VhqkHfp/
#@4B0UL77S5d8j/zHvb2mv/6H/8y5iMYOf+/TXODI1lxL9TwAFzp3d/C/9cbWc14RSp1Xt9i+Xf5f/
#@liTBm8xF+rsBlj8ZCgQ03xJqVh9rU/7jFwRc/vP42ZWxgGCtB9Z4rKg/Fpa/GBjCaDyu8c+Nb0Y0
#@nqNx4eIr99zH7v0HCJmYmmX/kWMY+PDRdFz4/LNJlLgBdoHzzjnT/83leMxWi0yX+4hGCYM/+AEK
#@Z77Q5d8j/5nvr3jOCxm59kOghFg+effD3Ll9dxD9D5weATSP/iulpl+AwhciILhfGbImNRd5gan+
#@mKf9u/ynI9EOCcF5ep/+3uWFAC1bQNdQw736WJ977ZuFw+W/GWItklFjJwRg8b8bw2aAAFWr8Ve3
#@3sHsfImQw0cnGPO6YyeDUzaOcOklFyAvBVhVLnj+WTznWZv8QuSc8cVBFmsFoukbYPAtv0ty6uku
#@/97wL/X9JVu2suFnbkD9g8SyY/8YH/z7bwGk1v43RvFNqdH99BKAJF38s/sLKFLIBfJ9/l3+20Si
#@XRJEM3pQg93lhQCtmHjmX8TCxYD1LaHhgoDLf6fnX/E+AFkr5UEX3swPYRBKffhaatEMUNQbuf3t
#@nV/FgJCnD44xPTPnM3unKVtPfxavuvwlPPfZm+krFv2CrBCFQsKWzadw+ctewH+74By/IOQfMzhS
#@GqRGPBo5jcFrP4ZGNrn8u/w/U/43bmbDu/4MjZ5GLFNzC/zYn9/O/GIVQrkHUDvRf0Eo51K6uKl1
#@jb5oxjLS/uXy7/Iv2kdoy9XvMSKRlBshUV5kKP4a5VoEJSJZP80GJbn8LxczmmPBjbV4voGF3xsA
#@1nisWeoxmAUTouDx4H7DION1//cVl/OGV1+ZKiIXn7eVocEBn+E7juO0YLhQ4blD87RD7ege5j/9
#@i9j8tMu/yz8a2sDGn7+RwtaLicUMrv3z27jt4V1BVD+M/oNQPfovGo8DECgBAVK4kJASaAjOkdp3
#@SCgl/T+tvMBaCqVS7pLLv8t/CwSCZBlR1V4LSedZAepK5Dmn8h9RJrAu5T+qdMDlPw/nFdSxJveT
#@UQaAmjYbtMwsAIHgrnvvZ9sjOwipVmvs3HOQhYWyz+wdx3FaMFctMlnupx2SZ5/L0HXXo8FRl/+T
#@vOGfBkfZ8O5P1OU/lo/cvo0l+SdN/tuJ/qtZ9KhVBmPTzERBSCD/nvbv8r/68g+QANVlSm4uhMQA
#@y5cMhddpzYmgWX2sE/nvqJ+Ay3+XywAabyVALVa9BYQ1dknKcQgBQk17AYAAuOmur7Jzz15CyuUK
#@j+/eT2lh0Wf3juM4LTi+MLC0ENAOyXPPZ/CtvwcDIy7/J1PDv1D+33XDUuO/drj94Sf56O33Qyhk
#@Fjbya1X7Hy4YKCLtP3gdRcyflLLPf6wwy+Xf5X958g9Ui0AJGFmu4AJI6rmQGACgXNbdGwgwkLTG
#@Ou6vxL+5tS3AZkaIJI/8rxgCZUxsrMlxAkyAAUIYZoCyz1F/SiON94mlaP+NX7qNX/7xH+P0zZtp
#@ZHFpEeAAF517BoOD/T7DdxzHac5SP4AzhuYZSKrEUjjrxUuZAPN/+35sdsrl/6RK+9/Ihnf/KcVz
#@LqEdHtp7hHfe+A/UzJ4p2IIwA0Bk7fufZNT6i1T7lppsYyxQ5LZ9ypJVRUT+5fLv8h8j/wALiaC0
#@QpHuXAiJAZZPCQ0jzGu04359rEP57yxToGa4/LezB61E/A9GZX3AlO68ArWXBRCu/M+VFvmzz31h
#@qTlgWibAY7sPMF/yTADHcZwszODw/ACVmmiHwhkXMfwTf4w2bHL5P0nS/pMNm9n43r9sW/73jk/z
#@pj/5IrPlCnUhV9JKuILofyDaScMx0Wn/zcVVrRr+ydP+Xf67Iv8AC4Xh57/8vcDGVW+EJ3qCyL+E
#@SloXIij16tz53+pP0kkd+Rcii1DAG5FaiH+DzCv2HAKhlgsX8wsltj+5i5dceD5DAwM0UqsZE1Mn
#@GB0Zor/Pu747juM0wxDz1SKjfRVEPBo5leKFV1B9YhtWOuHyv47T/gtbzmLDL9xI4TnnArTV8f+a
#@6/+OveMzQBjtV/jnZ0b/648HxyUCwvKAtABD0vB9s+aAYfM/ES4+GICyAigpixkiQC7/Lv8x8g/Y
#@dAJWWoXoaG6ExAQGWO4ktAtZAerRFoPm8h9iZmljbX92qTd/j2FdX/jLUC2zADLq8QieI45NTvHx
#@v7mZsckpQiqVKo/vOsD4xIzP8B3HcTJYrCUcnhukRnskm89i+Kc/SeHsF7v8r9O0/+I5L2bD+z69
#@tAjQDnOLZd58w608dnA8kJ6GAY3yn/q7PzwOFNH0T9GCrJQDA/kPyJB/XP5d/uPlPx0tJJAsrGKK
#@dK5E0ADLt4RGymH+U+/NGsdJLP/xf9/h6MJnz1cZQHwzwFRhj0qzaxR7U0RDQAmA49Mz/MlnP5e6
#@CGBm7Nl3hP2HxzHzSb7jOE4zSrUCR+aHMBOR1OvCh6+7nuKLrnL5X2dp//0vuYoNP38jyYZNtMNi
#@pbq03d+9T+wHqSEiH4iP0hv/ifAxgRQEEzICCwhEi60BSW/4Jy2/23/iaf8u/53IPxgsBhkAK4wI
#@ZCYfImiA5V9COxBB32Yw1/Lf+eJARJbNmi4DSMearA8o7X5ldOoNS/cCpNR0v/GZGf74szczNjFJ
#@GoePTvDkU4eoVms+y3ccx2nCfLXA0dIghmiLYh9Db/wg/a+6DiSX/7We9i8x9LqfZfTtf4D6B2iH
#@crXG2z7xZb62Y28g4IAsFP/sxn9SY81/RvRfoLBJIC0Qalbzj0KhTJFFxYi1y7/Lf/xcGhAsFIbO
#@e/lPCM7qloxJyl0UWGtIQiWtu6Z7ksv/an12SWu4DECgZlkAocFnZgFk3taPVuvuuqXFRR787k7O
#@23omp23cQMjCYpnJmVlGh4fo6yv4TN9xHCeFsiVUagnDxSqCeCSK576MwukXUH3iPqiUXf7XYNq/
#@hjaw4T/Ff+CKN4HUtvy/4y/u4MsP7Qoi70qv3UdIwgDUGP1PIKzxF1m1/8G5AFpF/4XCcoFEGEDm
#@AoCA6AaDLv8u/6H8t8D2F0bOvexaxLnrpvGdevh00VUkrcume5LLf7c/u6SelwHEZwGEC+OKzAIg
#@OC6tFCBJee1Q8hd5YMd3lxYAtj7n2al9AY5NTAMwOjKIJJ/tO47jpPQEKFcLjBSrSLRFsuVsii94
#@NdU9D2Kzky7/XUn7Z0Xkv3DG+Usp/8XnvZh2KZUrXPeJL2fIf3pKvlAo/6H4hw36wtdJaS7YagFA
#@iPA9gSnsMZCZdRDh+HL5d/knXv5BaG9h+LzvezPowl4KiaT8Segaq79WonXbdE9y+c9rtocQ7SBE
#@2yiiF0A7WQAiSAsES1m1R82eI2q1Gtt3Pkm5UuWi552NJEJmZueZ/s+xcWSIYtGzARzHcdIyARZq
#@BUb6Koj20PAp9L/09bA4T/XAd1z+yX/a/8Bl/4/Rd358abs/oO2Gf///hlv56o6nmss/tO76j9LF
#@XwJoEv1PQNHyX3+OQvlPKU1In6OQcgwgl3+X/wz5j2d3Yej5l10teGkehERSLmVIOZd/dHJtOSe5
#@/KMcnVuRswZBMI1q/hoyFFH/lp0FEN7XZNIVvgeBYRA+Tngs7Np/gH1HjnLJ+edRLBQIKZcrjE9M
#@U0gKDA8O4rkAjuM4z6RSSyhVi8taBKBQpHjB5UslAZXd/waLJZf//KX9LzX4G337xxi86idRoQ+g
#@7a3+fviPvsC3du5rkPVQ4tPlv1HmFco/Kd9DcJtQfzxJPS5lASBBaQ3/MqP/AmVInUghcfl3+QfR
#@JtpZGD3vslcA35+vFHDlUoZESP5FUNK6l1DJ5X8tnVuI9jBQg6CHCwlKa+1pgdB/D9kzb9MmA4Ck
#@9DKCcNVdcPT4xFI2wHlnncnGkRFCzGBqZo7pE3MMDfbT31f0Gb/jOE4DFRNzlSJDhQqFBKD9koD+
#@l7yO2rF91Mb3ufznSP77L/mfjP7sDRS3Xsxy2Ds+zTV/eAsPP32klfyHdf9B13+1V/MvAWHNf1zq
#@PwiF8p8R/U+9TzHCLJd/l//lPOc7CdiRHkpB593vRdcwwPIm//Gd5NethJqFw+U/z+duvxeAYs4d
#@Pie4tealAKJO9iKAggkB9WMPjY/zsb/+LHdtu5+aGWnMzpV4bNd+9uw/ysJixWf8juM436NSrbHn
#@0CR3bR/j+IkKy0Gjmxi+9qMMv+330cZnufz3dqu/paj/yNs+xOhPhSn/8Ty6b4zXfvQmHjs0HvwO
#@JlP+EdTlPww8SA3unLXtn4DgWEL5Tw8OCACay38dRab6u/y7/K+Y/AOMJ1bTkZxKQWtxFT3BABMY
#@PaLzPefXvYSahcPlvyPUUaOGznoHqFntvjLOH5wvddU9abKiTx01S/NTcB9QsSq33v0trv+bmxib
#@mKAJSyUBO3buZe/BMRYrVQx8+PDh46Qc5UqVg0eP8+hjT3Ho6HHm5ivcvWOcgxMLLJfihVcw+nOf
#@ou/S14Pk8t/tmn+JgVf8EKd84IsMvPz/slzueHgXV3/kJg5OnoBQvhOBRAPNt/xTkh71p2nqfyD/
#@iuvAr+DBRIH8RwqmBCHyff5d/ldM/sEY7ywDQHSD/O17rnCNtMtoRfeYX1fyH78o4PKfy3OHWQAJ
#@mQhFZwFIAEHqICnHZv5SDicDwfGC3QcO8uG//AzffPBhLOP/39j41NKkd+/+o5QWFj0E6PwHe+ce
#@I1V1BvDfd2dm313kVRCVCqxQfC2IhFabLkTFNG3aKFpjVZo2bSw0adOmaVOqmGjS1DS1/UdqmiYY
#@MYppk0aaGin4olKMUpHlJazLY4Fll32wy+7O7uzM3K+wIZPl5M6d5w6zs+eX3MzOcL975k4mzPmd
#@853vWCwThqGhYVpaO0b+D2xt7ybuuqNqAijvHzpH44k+VMkKqayl8v51VD/+VwKzb7HyX6C0/+Ds
#@G6n96UaqH34KqazNuq/23Jsf8fDzrzMQjQKJXXoM+fcp+uf3u414S54Y7STifFP/vQsQC2jKzpST
#@Q9ExsfJv5T/7GIcuxyXeXuRSYEprUcqQJo5Ct1+AwYASlVBV87Dy7992gbMABIOkM/Ves/TeMahn
#@hX/veKNqMAKOb1ziYTgaZfPW7fzx5dc41X6WZKjqyJaBB4600HSslZ7eflTV2oHFYik54nGXznN9
#@HG4+zYGmlpFBUFeVZHzY1MFTr7xL78AQ2RK4ZgHVP9hA5UPP4Fw108r/GMm/Uzud6oeeoPbnmwjO
#@qSdb+gYjPLLhddb/fQcumpn841P0L3XBv0Q7yScgjPMTOJh9EzXeY0pZFB+JFDvzb+U/j/IPqEun
#@EyXYPs6ExJDV4pMhTRzjTwRVdfQx4WagVcFVITEoAKha+S8o4rv+P4elAIKI4yP8eLSbKCaUIs57
#@duCzUyf53YubePXNbfSHw/gwUiSwuaWNxk+P09LaSd/AEHYswGKxjGfirkt3bx/NJ87QeOhixlM7
#@/eFB/IjG42zb08gTL23mT1veYcVv/sLBk2fJGhFCN6+g+iebqLh3DVI1ycp/nuRfaiZT9c2fMemJ
#@LZTfsQrEIVv2n+rgzmdeZsuez0Dwkn9vgRLMdf/GYIDnxIBX7QBD/sUj1ryGg9kFUbwQ0/aTPiV1
#@vJV/K/9ZxyigDl2B4WMfDVXNXboOCIxnIRGRopYhGdciWIDPeBzu8y9i5d+DnLMA/JHslwKIgBjf
#@Y0lVFFAArzi/YoXOZR0IBVra2tixZy+xWIzrZs4gFAySDNdVwoNDI7UCOrt7GYxEUVcJhQI4jmON
#@wmKxFC2uKv3hCN0952lt66LlTOdIZtNQJIqiKQsBvrf/AC+8sY3dTc0jAwEA3f2DvPzuHj5XWcGS
#@umuy7otIIETgC7dStuw+pKIGt/UwxIat/KMZr/mX8moqlj/C5773e0I3LEUCQXLh1f8e5OENWzh7
#@Puwr/96z92Ks+xdEZFScRwaAkSlgXtM/9R/PgsAJ+ffuY5jPPVYCSJqCKVb+rfxnKf+Jxz8LwLS7
#@154GZpWCkIhI0cuQlIAIisgEln9/RCa4/GsGVYXMbpck6/AoqBk4+m/jOqpGnAB6WXwiw0W92lHQ
#@RIwR59OOgdf7rqmooGHpbSy/bTHVlZUZfa/Ky8uoqaygqqqcyopyKspDBAMBax0Wi6XgRGNxIpFh
#@BodGDsJDEcKDkYwzNMORCO/tP8hbn+yjZ2DA7P2DkOCu+nm8sOZ+ZlxVTa7ocJjo7n8xvPMV4j3t
#@Vv7TkH+ndirldzxARcN3jDX+2dHZF2btxq280XgUYCzl34j3kX/v8402xSeTAPN8Q8hM+c+wICBi
#@5d/Kf9byD+Dg3iwA0+9eu0vhS6UkJCIyLiRUSkQERcTKfwpESlr+zc5M5oMA4jfjoEaoGuf4DAL4
#@yLiq+ou8f5z/+d7PE++xLBjizvpbaFiymBlTJpMtgUCAslBgJKsgGAoSECEQcC79m80YsFgsWa/Z
#@T2Qlua5LLB4nFrt4uESi0ZyXYp7s7GLHgUPsOniYoWgU0vzlmDm5hg2P38c9i+bl60aJ7ttOZOer
#@xFuP2LR/j9/h4HULqWh4lLLFKyEQJB9sbTzKmo1bOdsXzl3+jeeJuFTr/sXxlH//wn/iJf0+f0uS
#@rERArPxb+S+E/BsEZNalDIA1L4E8VopCIiLjQkKlhD53EbHynyEiJSD/uWQBiPp0fvzF2j8LQEAU
#@1FvmvWfzAQUkcd00BgEEIHlbifYuawAAQbhh9rV8pf5WFi2ouyjy1jwsFktJ0hsOs/uzY+w69CnH
#@z3ak/SOkHt3Y+5bdxHPf/zrTaqvIF/HTnzL84etE925DhwcmtPxLeRVl9SsoW/INQguWkS96wkMj
#@Rf427tiHooDkJP8AKk5q+U88Gu2IpJZ/MwYByZf8A0h64idi5d/Kf27yD4TdinIBmHbX2icRni4h
#@+c9dTIUrhtjPfWLIv4mUQL2BDLIATNR8LfelAMnj1BB5zzbNNrzb1lTvUdPtECoVZWXcOr+OJQvm
#@c+PcOTa932KxjHs6es+z/0QL/2s+xpHTZ3BVyQQ1N3JJIEyvrebZ767kwTtuwSD35QGN24nu/Tex
#@Y59APD4x5N8JEJq3hLLbv0bZopVIWSX5ZPOug/xq8zt09Q+CkJH8m1IvCAqQg/z7Zwf4p/4n4iD5
#@+UjyukFi5d/Kf+HlH+gNr1991aUlAD/+tqKvlYD85yKkRSmCUoJF90TEyn/eM13y1XaBswAk8TTj
#@AQD/QQBAANUMBgHEuGY6gwACqqgY92zEq3kbiXBNer9loRALZl/HwjnX88ULx8ypUxDrEhaLpcg5
#@1z9A0+kzNLW1c7DlJO09vQAgme6vrGiaMrKyvo5nV99L3dVTyTfa1010/9tEG98i1rIP3Fhpyb8T
#@IDhnEeWL7yFUfzdOzRTyzZEz3fxy89ts338cRAAFU+qRvM38+xf9M+Xf5zFr+Qdw/OTfv8K/eMqn
#@lX8r/9nIv8mx8PrVcy8NAPxoseJ8XOry7y+ixS+CUqLbvomIlf8CIFLgtlXxwVN+lTwsBUAAUPyK
#@/JmCL6gqGCKfdBDAbE4VxYj1SvtXAXMARFNVYBIAKsvLuX7W1cyZNZNrpk/j81OmXKwdYJcMWCyW
#@gmEW7+s430d7Tw+nOrs53dXNyY4uuvsH8vJbo2acmhdTRhMKOPxw5e2sW7WcSVUVjAUa7iXWvJtY
#@00fEDu/E7e0Yl/IvNZMJ1d1OcP4yQjc14NROHaMlHxH+8MYHPL/9YyLROIgAeAm21z7/6cu/ACJj
#@JP/O5eLo+Mj/qJgEnjsMWfm38n9F5B+B/wysX/1VAZix8hfVcTfcBwip7tNKaFHcu5TwlnMiYuW/
#@CNqWsSwIKGnuCqAAaQ8CGFKdySCAcb7/IICBAt6DAGqmJIx+1VP8zYsLqJLAGKAQESbV1DCpuora
#@6mpqLhyhgDMyWABQVVlRAt9pYdwjxpMCNqpF+TELyVG8KeZ6PoKSI1J839HwYASASDxGLBanf3CI
#@geEh+ociI7P84UgkxxuQFPKvYKLiHa4kmD6piicfXMFjDYsIBhzGDFXibc3Ej39C7EQjseN7cc+1
#@FaX8O5NnEpy7iOD19RcebyMwcx6IMFbEXJcXdzTyzD/ep6t/CCD17LqQlvwrgJ/8G68Z7aQr/97x
#@DiggGO/TV/7Nc8DjhBRb/ouVfyv/Wcm/iYqzafDJR1cLwGVbAQrZY/e6vyL3LiW+5ZyIWPkfl0s9
#@ANUUbWedBeDxbwL4FgX0jlVA/GLMWEmcZ4i7j/wb+NUQUON+jL/9O5Xiu8zCG/F/SbVAHQ9/NE9f
#@bkUL3skp/Civ4IfmrZMD+QhSFB9yk0sp8Po7GasPTnK4jIxxnGCQRYymP/PvJ8RCgrqZU/n1qgYe
#@+PKNOCIUArf3LPHWw8TbjhI/04Tb1ky88wTEYoWRfydIYNpsArPqLhzzCVw98ohz1QwKQdxV/vbB
#@IX77z50cPdsLYKb8+8t/7jP/PksHJP2ifwDiZCH/AoiVfyv/RSn/IIA+HV6/+qlRAwBr3kFkuZUh
#@QzzH2b3LBJBQEbHyP37a9p7BJsNBAPCfyUdAkhYINGTc2OdffCTeU/49Yox4Va/Omhoy7jcQIKAA
#@ZpymYfQCqr6fd+4ioviQd0HQXDosqqliim/mXzKPUSEtFJMr18lR1XRjCoDkW5ALP2Agku1IrdFO
#@ntqSbGb+M0RJmiEFAigLr53OulUNfGvpQkQoPG5sZGDA7W7DPXd6JEtA+7tx+3vQgR40/H/2zi3G
#@rqqM47//Huh1oHSgBWkh3A3FGpRoJT4IWHjyRRMTSWxFDRpQn3ilhMT4ZjDx0QdJ1KgvKi9eIkR5
#@EJMaRAXKtQJaClQotHQ602k783ecmJN2Ze+1L+fsPeecWV9yciZr72+tvc6cfbJ/3/UInpvFJ6bB
#@CzA/j+dmMKBV62AiA2VozSRavQ6t20C2/gL0v9fkFBNTHyCbupRs4+Lrgs2QTXS/RZtHnnyJ7zzy
#@BC++dTinej7hWAn8C0RL8E84lteGMDgmrBrwD6C89IAE/wn+lxP+QeIrx/fselg9A8Ad9/4Ac3eC
#@oY4NAV1NPf4dHhL8D+faBTAa9+IYl8wXgLxy6wFEjAAKQgBKjQCBTrQLQc3ohUC/kLed8zmIuDiY
#@ZKw9/5U1uvf808oDi0fP8x/e28nz30Cn+TWqFSNd/w8eBsAxGDGBuNQuGZ569SVTfP2Oj3HXrR9h
#@7apUO2UQcvL0PL/4yws89Nu9PP9GCP4GVA3+w2Mh/EsYNYX/mnn/WW/sTPgHECrI+89y4B8g5v0P
#@58g9L8F/gv+BwT+CDG6d3rPrcfUMALffex/w3QRDcZE0knvXigs/V4L/YVobE5HGUQBxz384p3My
#@BgyuYAQIdIrWM+HJPkMvX9cGQb4RRFVCRlXu6XYpJ4c69eHf7tDzH67ZVWcXLbvn3wQyEp5/cHch
#@bePv+ZfarA6bD9ZSq/ePB3afGlDMCLvUOvDunTctGQOmJtcmim8gx2bn+Mmf9vG93+3ljSPTgAAq
#@ev2Dav8l8O8gDaCn1yb8Y5Dy4R9AOakCKMF/gv+hhn+AhfnTV5548Muv9aa58PZvfFr4sQRDlQFz
#@ZPeuFQKhIfwrU4L/5RBVbgtY0wggUO/kikaASN/+Mj0ZHAd5AHBOGH6Bbm7Yv6vnSLssQr8ClNt9
#@wH97oOW8AdFERjrn30OV819Tx+4+hF/tw7+htl73nn+1AgjlOi3Bv6tGOClUKFAx61av4nM7tnHX
#@LTey49qtieoryN79B3n48X/wy7++yMzcaVAR+AOoCJbj8C8hBNA5/PekKfwDZBQDfgj/0WEl+E/w
#@P1D4B07PzG9dy4O3nu4Nbdz5tQ0TOuc9QAmG6omkkd27xh3+y+s8JPhvQeLe2kGkAigX4uPh+QIA
#@GeemEpRX+jfhcfdUA91qhQudu5/IvsD5D7rlufluO1fIAwME2xX1RCui5fX8m1oyXPAfRmaoc8//
#@+MO/RHXpSk/N4b/ckhmH+/C4XfsH8PotFy6lBnzhk9tTVEAgh6dn+dkT+5aq+r/w5jtAD8qrhfuH
#@UC4DKvT6h/AvCWD44B+BFMB/2e9LluA/wf9ywT/AqzN7dl0VDC+lAbwEXJtgqJlIGum9a8XAf1wk
#@pe97W2u7USpAZOKqRoBQCowAAA4NBsE44MCjb+fsUwrmjFxXeN0qMEI4BEVXMLaohvvcA/L8q3HI
#@rhmQaCQ8/832rU49/42/O41EQ+/5by4aE8+/livsP3T0OySMfLELfwZDnYks4+PXbOGzO67n8zdv
#@46Lz1jG+Eu/f/5u/7edXT77Io8++wqn5BXoQYoEi4B+FfwAGBP8C6A/+Q5AXIHBwPT2ROoB/ACX4
#@T/A/aPjH8h9n7999W54B4KfAnQn++xdJI793rTj4j4uk9H3vd20boA8jgHJD3ONGAAWt/qoYARSA
#@eLERwIAwtuiJHCncF15bLArClYpboaJ0gSB/164H8fZAHzxsF+gMBORHrtq/W3zIcUc5Y7ZbeMhp
#@Af47D51T1/AfF2m4w/7tejBiR9ZxhS4BKo24WnXOBLdtv5LPfPSD7PzwlWyZOp9xltffPcajz7zC
#@r5/azx+ee5WT8wv0RAIDUjn4h/ezMsC9Y0XvQviMMVEC/wJoD/4xSEV7CwA9K7vvM3IlS/Cf4L9F
#@+A9F/uHM/bu/2jscFgJM8D9YkTTye9eKhf+4SErf94prN08FiPeGjhsBQpAvNwIUL+68Pv8ByRkX
#@6kY8/qG4YEwCB3qKzasGMOimDx6R629a8G/YPf/1dNz39EOS829TICnnv7Go5gOmOwCEvlr95e/B
#@xgBqIdLErqHj3MOxwRsu28TO7Vcvvq5aqhkw6p0EZk6eWsrpf+zZ1/j90//k+YOHQQWRYwLIQAZU
#@kuef10u/1Osfgf9gjX7gH0AV4B8QFeFfeb/N4ZgS/Cf47xL+i+SBxRSAb+cYAO75FOjxBP/trC9p
#@bPauBP9xEUhK8D8wI4BAYAxUNQIoCBWtYgRQ4GEqO793cm9JEaYFOOwMUFy53yaQcJ3Is7+refFL
#@mU5NUjq66vPfUsG/Fjz/0b21tx+31TLOJiKde/4bSCfw373nXwBjUPCvwvdNDcJc7HK9cNBEdAzA
#@uRMZN15xKZ+4bgs3X3cZO67ZwuYN6xlmOXR0hr37D/Dnlw+y9+XX+fu/DnFq3kWQlwP50VD/gnD8
#@vPGgyv8Z41JWAvHLDP8AUkvwD6AE/wn+24J/bN85+8DunxOetumWeyd9LkeBLMF/u+tLGpu9K8F/
#@rb1LSik2NuXiHFB0pNC9owWkyo0ACh8WQyNA9YJ/gREgUC7HNrvstNCwUU0EuF7xPtvNHzzoEP41
#@HAX/3MYNo2Uq+GcPD8iHOhoB+KcF+O+iA4XUGvyX65g+pF5LVBwJEHDOBHED9CUbJ7lh62Y+dNlm
#@tm3dxA2L71dt3sB5a9d03KLvBK/85yj7DrzNvoPv8MyBQ0t/Hzp6PKzUn59ap+CEquAfvhvIann9
#@24L/ABRbhn8AlVX8T/Cf4L9b+AfI8LbpPbuf750apAE8B1yf4L+D9eNAmNoMjh38l4uklXOv2fXm
#@dlUjgAra71Vp9ZdzbXZgfiiBaEcNAWevr4gRwxFgV4W2WOFxOWYVHrw3Wl4Rnn9HJhlZz79NREYs
#@5180kGH1/LcKCM111NTz338bSbthWpMrFGBVBSOrg1NFqLBx/Rqu2LyRyy88n8sv2sDFG9YzNbn2
#@/691S++rz53gvDWrmci0FF2wfs0qAI6fOLlUgG9+wRw7McfcqXnenZ7l8PQM7x6fXfr7rSPHOXD4
#@ff79zvu89vYR3jt+ogDyw30pDkWKhPfHzkE5MB7k+ge6Qt17/jFkqgn/AKoC/8XHRIFkCf4T/LcG
#@/8DczPzWSRZbABYZAH4MfDHB//KsL2nsPncl+B+YSBqre608lzg4XmIE6I2IGi0Cdda4yTcCmLw+
#@/wI5fy92ZLsusGCEYyqpYh3q5vfENgs1adEAyfNfoOdGi3f6kFNbAhtQ8vx3Dv91dRxAhZoBgqM6
#@NeBF8Xtddb9wLr9P7Yph//Fiq5EwgGpRA4p9qOVRV3XFUv3fMsVC1Im0ucsZwxHjgABAVb3+FIM8
#@gIreM4B+C/4l+E/wv1LgH+Cpxfz/m6BAZdPOe75l6fsJ/pd3fUlj+7krwX+ra0sarX2XVhGvZATI
#@zfkvNwIo8MQ7cNI7YPLALa9c8I/n74d/nTWly/P3w+t0oIOb/BNr6qnJoSH2/Md13CTEusOCf80X
#@dP8XqXFu9dcW/NOB518Vp9Mw5PwXGDZiE9WBf0eXgXidgDj8R7sKxH5j4zqhhPAcl7j3PxQVQKxU
#@fK+rEJZDII94/WnmxVeWZxToCP4j908Z/AMowX+C/87gP5QfLRoAvgQFahfv/Ob2eS08neB/eNaX
#@NNafuxL8r+yUAzvyQ1jVCCBMRKdiDn4I+QZsl/WhLi/eZ0MYGu+YIQAcrWhd8ZDK9FSi5yHw/Hf/
#@kONyvSH2/Ddo26cRgH86hn8NO/zX1FGbBf/UJ/ybvsQFIO8adQIcmzh2PJygQv0M0UiM6htkVAb8
#@oYoisF8X/CNe/xyQrw3/AojpNgj7B5A6hH8BSvCf4L9t+Mfivtn7dz0ExapaTAN4E7g4wX8KAV+O
#@fSvBfzXRmLS1DGFZDdoDAhK4cotA/Ze98wvdLSvr+Of7zhkVTUjPb0abCamLjIgoMIQKSRnPOXMj
#@0c0hz+8MitHY+Z3CQgWn3xmdim6kpLwwkMLQLoogoqss8SJMAvsDdpPQhZaVaTAInt8xnTnf7mRY
#@7L2etd693/3+e56bc37vXs+79l57P/tdn/U863kKz//wPn6PrVPI4Gj//xDMO/AqjZy+ojKCor8S
#@vIZ1BdgzA0J5Rt4pz78XSK62zTwBxpHOju75Z0ue/9zzP3XBwLX77Z5LNqAAwhvFbs8TYDf2JQir
#@06hs3j0wluh/9yhYBPDwzVYL9AOUIF8Bf0DSgE4A/E3wL4Cl4b8Ci0r4T/jfKfgHofu+evcDT/wN
#@FOpFHoA/Ba4nDO12/5KOYtyV8H/wfUsa5dh4vztYhrFIejw61yu/zzZgADyUJ8DGRZWAsXOLS1E5
#@9mYBVnnM/aX+SjHzQ4W9955/FvD8L1Xn3zah6IDD/tnHUn/ugH/NdA+07bD/YJuTAg996xqoKw1K
#@mnFjZQGBPeEla1rEqP+dJgXAX4hizz8GVOYBeIGehsEfCRX99Hn9BShYMJgY9l/2AyAl/Cf8HwT8
#@A2i1evXd8xv/EywA3PpF0O8nDO3PtUs6+Os2AkB5zw+wb4G6ywMWEz9XONmFwRg8Ppk0rs4RsYuv
#@94jHyoVeXOd/XIwNqGd+6QVCdg4z4d90kF8e/m13TnJ2PIRfuxj2z1IJ//q/SktsFdBm4d8e0DGg
#@YFG1s9yfXJzwGPgTe/5LseswYtMqVi/EqYD91n3/CqC/1BsE/0q4vyBI+FfCf/+CAcBgP9uDfwAl
#@/Cf8bxf+wV+7ePqJh8O7ffL4rR/kef1rwtD+XrukQ4P/at/Ke77n8L9mSSeNe3kMLfvbS/3S81/1
#@4JsY5ONJ4sjEUKZ/27+pi4bPQQsn/GMznn9vDP7Z2UmOTSS5539QlKX+pupIE+E/zsIf7/lX+Xmg
#@F8C/y8WI+JTqK7OVQ4FYkwAm/lwase0SqD0CyGVYv3AB/oMQj0C0hf6XIA8x/GsFsMPwD6CE/4T/
#@heAfEJ+6uHPzCuXRkW0AXwYeTRja/2uXdIDwH4sSwPcE/nv2aQ6X+osXATRSm94D//iFOgNVAlTu
#@+x/rHuT42gzxh45n2XKlG/dDhXfd8y82Jtptz7/t5Sc5LAj/OhT4Z3Oef2nKM7rBsH9Nv2Sz5oJB
#@UFa1AvFh1IAqkQjBWnUodh/8z3pMaCUMQyH+IzYmhEAvgP4q+Bfgu2Lgc0DqiRYovyPhP+E/4X/k
#@mRT60N07p+9uXQD4BHAzYeiwrl3SAcN/LEoA32n4jydVZak/4kWAptmlsalIG8i7aB/ot4e12hPc
#@SQZU+apZy8JtzLnr6ZOcvYX/+/Y8kxxYcJJzwGH/HJDnX1rvejTB899PzMF7sjt5X5C0j3H4N63R
#@XbGd2pvx/Bf67Z5/KtAPKoC8DfwBVCYXbE34tyPwD6CE/4T/vYR/AIkn7p7f/OOmO//Q1dvvsP2H
#@CUOHe+2SjgD+Y1HC/7bgvy428YuwLTu+1RIpYDDAkOe/Xi6wDOG3aqUH3Ri/7U7Hl4Pi9e4IS1Vw
#@KJCJExZvbZKzdJ6A+PH3bOOvw4P/fjmusH/3ev41wbZFv5061LEppBP+7cbcew4iBgR4eIDHztH9
#@4VWeK7wfAa4cX4EIPP0vBH8AYQSKwL/oB0CAWrz+gFbRVoFp8C8BJPwn/B8F/APcf+CB7//mU2/9
#@YtPdf8Wbn3zNA7r0pYSh47l2SUcC/7Eon/dtwX/dU66mKVNR6q9oZeICaa5FGTgGcrs4ZHC0mbS3
#@1J8DiC/6WTjhXyzCzX15/z3/cac4zOiw5CSHw/b8s+Gwf2k6/LNAqb+pk2oNPa+KCo/GdmoK8QDv
#@qzzeD/9lOw+9XxVsLZiy0d/ref6lTjvXmEc9gH4wAgQAKwEQg38R/r+qgPRAtv9SJ4Z/AQYJJAwB
#@/Ael/sbIXgn/Cf/7Bf+I/7o4v/noYOvKNoAvAK9N+D++a5d0DPAfizLZ4HbgP2a/kMINqJ4Y0MMd
#@1OHcJZTHpf5MoeMRT5hr11PCfzAOVrvXzZ454V9/CH98WAeX7d92d7b/bhHp+V9wz//ynn/N9Mir
#@fww02/2pLMkKYVrFRZ6WuLiKgy0GLfAPuDeniucI+4/GvwLlhQkWtuiykYTUk0BQpQe/Bv5ldvwi
#@T0AlZ0B5TRIWwMzwL7W9u5Twn/C/Q/APCP7s7p2b1/sWAN5864NI7034Ty+wpCOG/1iUz9tmAQH3
#@rxRoeKLmQWe+ABddeuQ7Br1CcRlDG5eLDK7sw3cwLO7dv+8JHkWHOg56WQr+l/f8z5+139ud5GSp
#@P9i9sP/lE/4tACP9Of6MAY28ljys4xD6g4Vc4hP0AvAf20IAnKp4+Yf0hAo7jcGfMuy/nqNAaskT
#@0A3/QgCze/774R9ACf8J/1uBfwDbv3Lv6Sd+r+tJePjKL/3Ufe5/JuE/+y6iAxL+G0X5vM3nHbRp
#@lLBCgIsKAVXQtanO9NyqJyijAjQI/FEJq6jNdKiwq3peO9s/R+f5t13qHBj8k57/BeA/bKjOc3On
#@DqAitLpfpsCIayFFGBfNxsncdvC+C6Df/butCsXGJLWhNzoG0BL2Veu73NcvUA36y89UtK2Cf5An
#@gPK7C70VYJA2C/8SkPCf8L9H8F/Kff34xftP/7HvaXjmmdXJZ7/6n8CrE/6z7zGRlPBPvyjhv/9F
#@aANMqhDgoQoBBlTdS1pJBgVQ1a1Mwl1oVOpTI5CDqgeaaWWgPAUvV+pvv7P9l3CxNfhfRpSl/maF
#@f8/6gpZWc5f6W95OcaAzHIZvjCDM3O9W+LeD81PlvKI6/+60bREPcwnco8A/pFfActmg4qEvwL+a
#@7K/ME6DQ6z+20DAT/Asg4T/h/3DgH+5ePPfod/PMm57rfiJOrp79AfDzCf/Zd6tISvjPfAObAwS7
#@UccjqiXxx1UCKNQKb3wQIqqy8yhXQNFJeboemalqJBt1YHtx4qyE/6Jp4FGcB/7JbP9T4J/l4H+6
#@TAeEfh1pd+HfbrNTO4wWKBd/FbznvVauAA21je3UnviMxu8UpEbgp/DIG1YCOsEfgSKPv8qFhrGE
#@fzH8r8CV/f6d8J9h/wn/hwT/GH363p3TxwDWWQB4C/CXCf/Z97oiKeF/A33rmOC/FLtRx+X/Si9+
#@UCWgM0mgAXqy/bc5tNDYAdon7N5Atn836R0c/NvOSU6/pOcfLQX/m/f8SzMavINmjYAtwMH72lTy
#@sGiwdKuZF/6jFhoZ//7nZwUCBe+JQUhWDforIK8S/MfAWut6/Qv4H/X6p+c/4f/44L8U6zcvnj59
#@/1pP0/e98e0v+caLXvpV4OUJ/9n3HCIp4X/BvrWf8B+L3ahjPJZRXxUPUJiEz8Ee0Zayfe7aSOrB
#@K9P4V+GJN97p+Q+2WMzv+c89/wn/G8hloT0I+3dkp+5+V2EHbevwDx7eRibAAnXAv42ljS2Sasi2
#@pcAmpy4CrPiOrCrgHyYJDOrtq6D2Ev5jvcIOEv4T/g8c/gFJj989P/3k2r8uD109+3PDzyb8Z9+b
#@SPinlfKe70jf2rd9wXao4940zeVfVj2k3u6bk5YHHJXxd9dNNF7fA6dAx7sI/8wP//Yikxzv8SSn
#@fzAy2/8Cnv/gHB3ozAj/q/LLBOpxf3dk1FcQ9tSc8C+Gf3B5HXFKFruw01qnmmD7Qfh6115+an8X
#@+gJFAB3t+a+VGBQwqJPwn/Cf8D8u91986UWvfPZ917++9pvm8tVbbxP6o4T/7HuJbP+Sctz3tG8t
#@B/9NgGxKHbdUCRhOEkg9UaA9mgwqmPiOePHlAE7Xgwrb08L+OcCw//ExSc//Xuz5Jz3/qP+Qejz/
#@WsBOXeiEcF68WxWH/I82NaDq+8AYDV6PR/SEKeDf3pBtl5DcWzZQoBr0l5+tKjkl4q0CrIa+U+OL
#@BhAtGMwI/wJI+E/432f4B+lzF+enr5/0K/Pyx25ffvED/gpwKeE/+14627+kHPfjSvjXr2NH8D8G
#@1oH7JqrhbsJGas0KrWJSG/QTJ+6r6Lj9vpUa3u+wf9sEsiXPP+n5z7D/ysG5r60R/rVAWEVzPyaQ
#@GPwNqNLYIw3tztduWW3GC4ToCdQLogJVPP1RFYJVDP5l2H8c7g9Q6BTtCt1yYaIC/wKYGf4BlPCf
#@8I93KhGuf+Pizs0PTP6Fvnzt1l/Jupbwn33vQqk/STnuCf+Us7EY/qMs/wWMB7wdzCrjcoEeyxOg
#@YV1X4lYV5krYkOffHQ/Y8pMc2606GfY/qpMJ/wLZHvxrmm2XjbxLETp2/3omDvMLxN5+D+gZUNhn
#@uTBgKTinCbatMTtVsJitaYAc5wgo/m6sDKAygWEN9AUwAv8CGLu29Pwn/B8B/IPxT9y7c/Pvpy8A
#@XLl1U9InEv6z712s8y8px/0Y4b8UO4b/OBlUFIpfTvTiRQOP9BMntiraKUia5WkTD3vfEv5FNb0T
#@/vcN/knP/3az/Qc60vwwYk/UcWXhwMN2akcv9P4F3vLPdQIZNOP7QIp1pDY9afQ5iCsEAGgA6Mf0
#@BKLU64f/VWT76flP+D9M+AeevXjtgw9x/frzQctYXnX1PS97nouvAN+V8J9970Odf0l5z48J/gGP
#@eb1Ff5Z318A6CCsPFimCJF0dJQUB9c7m96HOfyymWRL+17PTzPa/APzHclB1/qcn5lRP2L/Gwven
#@w78dVJ5RY3EXz7Dnv2ucCzsNoH9MT1HYf6kTgv/gcQnctDAhgIT/hP+Ef0DmT+4+ffrW2bDg5Mqt
#@jyM9kfCffReyN3X+JeU9P2z4Lz08Ez2YfXvxbXcBQnyOLqISJpb6i4MPdtLzbzvSOQLP/7o6JPyn
#@578T/rVl+DdNIhUg7jDsP6732l/nvzxmiarY8wLMoGpQ619ViArAP64SUH4Wgz/AXPAf2XCG/Sf8
#@Hy78A0i87e756cdnmxa88srZ1ZX4ZMJ/9r2H8F8VSXnPDwf+ozJ68YZSRZ24Cgi2ywOhDnbfZlcB
#@7iL8RTz/sajsIVpESfhPz/8w/LNL8M/68C9tEf4rOtoC/DvSKUHelcowBg1u7YorBajUCcG/Dv/2
#@QrateKwV9auxknwVeA/KAyLivAUqhj6KTFgBRPv9K+dY4/uE/4T//YR/hOH+oxfnT/z3fHjwzDOr
#@k89+9d+BRxP+s+/9hv9YJOU932v4LyZf3YBgYneZS72oPODkrQJxMkOtkw5gQfgHAGOGJeGfUkTC
#@f3r+N+j5186E/ccl+1Rva1fgwABtJQKtuo6Kvobg324EmAVsTiuAzkWD1ZBXPfamS+XxYCFgVTQp
#@xrIL/gWQ8J/wf6zwD/BPF+enr2vS7NsGcPbbiHcn/Gffhwn/sUhK+N8X+C/FbgWEPsCWAabmCZiz
#@1F/bAoU3vee/Kwv/nnn+Sc9/wn/QYA8T/mkH7NSRjuPZuFxJ+BeVCFTQR3msBFbTJuvp9FeEKIC8
#@5Z5o7P8VMC51FL0rBKhYCxCuXpsG3iEJ/wn/Cf8IAMC/dXF+806s3SkPXTn7MYt/TvjPvo8L/mOR
#@lPC/i/Bfir0mILjxQtwEFbanexTtmQDBk+Hf9nYmOWTYf8L/HPDPke75F8AOLtJ5WMczpAW124fM
#@cdlYS5XjQ+L5w/7LDhUAb6vnXxH0DzRcEYN/if7ScKobac0EhgzpJfwn/B84/IOtN9y7c+MzG0GF
#@y1fPPi/4kYT/7Dvhv61vSQn/24f/ksDXhAo3OnDc7FG0PT9UeP5s/zYAOzTJyWz/W4V/0vO/n/A/
#@67jForl1PP6nAuCPE/6194WxFKqAI9uOCUOaAAfqGF+BxvQUVxUQMfiPbBdwFfxJ+E/4T/iP39XP
#@Xnz7kYd55k3PbWT6dHL19nvBH0z4z74T/qf3LSnhf2H4Lyd+/YMb6LnUcTNU2J4TKupicPmRveU6
#@/+Se/4T/hH8AbRD+vVSd/04dO9KZPwKgtFO7qR+zVqH/pX+D4/FU4Nnv3SoggBHwj+BfGgdxBWMi
#@gA74F0DCf8L/wcA/mI9d3Dl9x8aQ4ZE3PnnyrRdd+g/gJQn/2XfC/2b7lpTwPx/8hxn4+wHB4zoe
#@0nE3VNieDSpsIs9/j2TYf4b9J/zvvee/3041A/y7V8dutNOybaDnpgWDmRP+ea4SRoF9N7cPSgtq
#@ZKzjhQYNJSOECvwLYCL8r8YvU8RjAAn/Cf/7Bf+AVr5296mbf71RZDm5evYJ4GbCf8J/3vPt9y0p
#@4X8OQLAnAILrOg51gr7i+abjsP+E/4T/hP8jgn8B3oSdSpPgH7tJx7SIO1+YrthpDPOWwKZZ7IVt
#@Wz02EEB8BbArOhqu2T8M/1JndELo9U/4T/g/OvgH/vfi2498TxD+Px1bHr569pP34e8S/hP+857v
#@3ZaDhP9Iz54GCHH2/VKnqme7w9PnCfC/SNh/1vlP+N9g8r6Ef8rnc6VdtdNYx67bnQKd5qSubooC
#@sBS126pt95f6i7L9t7RTRW0crF0Ff0ooT/hP+E/4r+t99OL89J3z4EMcBfAPwOsS/hP+854fdrZ/
#@SUcC/5UwUq0LFY5BfpTvPTsgGLCd8J+TnPT8Z9j/rsJ/LDalnTqC8q5Fgw2E/dsbtm11PjcKIuZV
#@L6enAPoL5TLbf1y2TwGnBweKawvGIeE/fxf3Gf5Z3ddj33j6xqeXWQC4dvYLmI8mCCb857hnqb8e
#@PWm14/BfArtnggq3QYWh+6DYuuffdsJ/wn/C/6HCvyLd6aX+AumCeDe/Qh3mHLBoF3vrnv/YVlQf
#@S9VJWlF+gVrCv9AOVxVOT/hP+E/4H5CvXXz7kUeC8P/5MOKRtzz50m/936UvA69IEEz4z3FP+D8A
#@z3/9I3tGqHC7nlsmHs6w/8kTlgz7X36SQ8L/XDrSljz/m7RtV/T6wvFd2fNfWxCwxk7Fdds2FfEM
#@dqq6nSrQ68yIL4jL8FUT/gmHz4AaIV6xbSvhP+H/KOAf8Ecuzm/eXhQlLl87+13BuxIEE/5z3BP+
#@Dxb+S7E3ABXu13Gv598J/7nnPz3/6fnfjbB/r2WnocT90bxlwBLgPo6PdJj5/qhHSRH0V//HSoQi
#@DSYYdPjMiJjRBTAR/lcACf8J/wcC/3Df/PQ375z+7aI48dCVd/6AVw98AVDCWMJ/jnvC/4HBf6xj
#@bwgqPA0QvEnPvxP+E/4T/hP+QRvWcY+dmkK6s/17xE5th/2VOhhi8Zp2uoqHT5Gdqq2OhETcl8YJ
#@XODgfGL4V+P7IOE/4f+44B/rKxevvfS9XL/+/PxIEecC+BTwWMJYwn+Oe8L/8cB/KV4AKryZPf9O
#@z3/Cf4b9Hy/8a8fg3xU99cB1YKeB5z9s7pFxNP12Gqiq204rQB6oSm22LcWud4FbvfgK3svBeye2
#@HSX8J/wfFvwjJH/47q+dvmsrWHH52u2fEf6LhLGE/xz3hP9jgP+Y070wVDj3/Cf8FyeYnv+E/z32
#@/K/T1JGdmhbxOpn7u1U802+wqIkUt0EKbDuA/jEdgSEGeY3et4T/hP+E/0hntXr9xVM/97ltoYVO
#@rp39C/DDCWMJ/znuCf9HDf+lmEWgIoZ/J/wn/Cf8J/xPs1PNBP8mkulh/+56OU+s8++1bNtez061
#@9m9jrBjv+Vf8DhExrErRZ3E/8W9Vwn/C/+HCP3z+4vzGj24VLx56/OztNh9LGEv4z3FP+E/4rzSw
#@54aKhTz/TvhP+E/43wf41yF4/ifoyMM6pioW9IsaccIL/QZrsp2ioq/eCAIJd8Oi2q5Nzc9ywn/C
#@/6HDP5jbF3dufGS7iPG6Jx88OXnw38CvSRhL+M9xT/hP+Ffbx3bPxCNL/SX8b9m2Sfg/+rB/TbRt
#@T7NTR3pqU3Dk+Y87axcvYqexDYTh/PE5qgLbAsc6/dcmAQn/Cf8J/y+Qew+u/OjXnzp9duuYcXL1
#@7FcRH0oYS/jPcU/4T/hfc+JhJ/wn/Cf8J/zPAP/a4z3/7tNxj516OOzfNIrHbdtL2anbYUQK+4gT
#@/hFn1Bc41FPfb75a7VQACf8J/8cC/7Di4xdP3XjbTqDGq66+52XP6+KLwEnCWMJ/jnvCf8L/TBMP
#@O+E/4T9L/SX8H0vCv+ml/kwgk+r8Bw0DO/XM8wIptNNmulfrs6lx+FdHCT4RPwfx8YT/hP/jgn+B
#@V7zh3vtufGZncOPk2u1fB78/YSzhP8c94T/hf6GEf3bCf8J/wn/C/yHCfyxyxw/PkmH/pZ16w3a6
#@WsdOA+hXG4zECwb0f7Ui+Ez4T/g/TvgXX7j3vrf+EJJ3Bjle/tjtyy++5C8BL0sYS/jPcU/4T/jf
#@oYR/dsJ/wn/Cf8J/v51qZtv2JmHERGJEn7g+Bt4TO1Wko75zEzjsSMHhHjsVQMJ/wv/Rwj+AzHvu
#@nt/4nZ3DjsuP3/6w7F9OGEv4z3FP+E/4L+SQEv7ZCf8J/wn/24Z//T97d/tbZ13Hcfz9vVqYYIzL
#@uoHGEIzxHzCB+AhxD2Tr5kSRlbYgySYgbYdDGGFtQRuYAqKBgNtgeBcDQVJUEFmNUSQ88CZkYMw0
#@IC5CXJR1HYxtPb095+ejBbIMrp16zum5eX+SPthyrnyTc/XbX17f8/tdpwk/+U/kpAJn/nOUUNFt
#@/wCp2mtwWX1afq2InDP/UUafltsLAYH4F/8tj39gNjtt/pxjN105Xnf0WLpm4Nz2YnoFOE2MiX/f
#@d/Ev/gHwaf/if5Hwj/j3k//m2Paf8vq0/DP/+bWCBaROhnRRwd0CJ+I/yn8DMsq8JgDEv/gX/wBA
#@EKOTQz1ddcuP5av6HoK4SoyJf9938S/+xb/4F//iX/xXHCOJnJRx5j+vt1OVe5uUc11UFiNRbi/E
#@2/gvu7fL7dMAEP/iX/yf8M8sYuWxwZ5n65YgHZ+99iMxm71CcIYQFP++7+Jf/It/8S/+xX8j4D9q
#@1NupOhhJOfgv78x/flLDHM/Jvb35X/W3QFxFGUcSQPyLf/F/8mv2FIZ6z6t7AnWs6r83YLMQFP/e
#@c/Ev/sW/+PfMv/j3k/9T7+1UkT5NFevttLA+TTXu0zi1a/IvjPLxHwvp0wxA/It/8Z9zTUqpZ2r4
#@8p/WPYM+1HndivlScR/wASEo/r3n4l/8i3/xL/7Fv/hfOEYSOanoA//ykxqhT8v5e1c+/mOhfRpA
#@iH/xL/5P7ZrXCrMf/jgjK+cbgkIdq/q+GcSQEBT/3nPxL/7Fv/gX/+Jf/FcOIykP//lJ1e7tVOM+
#@jYqvwSn/97rc30nxL/7FfxnXJPja1FDvvQ3DoaWfvn5p+5K5fZCWCUHx7z0X/+Jf/It/8S/+xX91
#@MJLy8J/f26ne+7SGgMlOEVf591v8i3/xv/BrjrxvtnTOGyNXHGkoEq24qH84BduEoPi3tvgX/+Jf
#@/It/8S/+q4ORE/GfKtPbqUXwH2U/8O+93kvxL/7FfwWuSXDn1FDvYMOx6OyLtry/GIV9wNlCUPxb
#@W/yLf/Ev/sW/+Bf/VcB/3isq29upofCf/7tTPv5PrCf+xb/4r+w1c6mt9LGpm6/Y35A0Wr5q4HpI
#@9whB8W9t8S/+xb/4F//iX/xXGf/5Carf26nGGIkKnvnPf3K/+Bf/4r+a62LEjwuDPRuocNqpUZZm
#@2c43U3FzwEeFoPi3tvgX/+Jf/It/8S/+a43//N5Ole3TaKAz/wEp7zWE+Bf/4r8W+IcUpXRPwxNp
#@RWf/pSkxKgTFv7XFv/gX/+Jf/It/8V8P+M9PWmCfNhr+gxMi/sW/+F8c/APxq8JQz7qmYNLy1f3P
#@AhcKQfFvbfEv/sW/+Bf/4l/81zP+8/s0NRj+413wj/gX/+K/fvCfiPhkYbD7eaqQjBonMq4HikJQ
#@/Ftb/It/8S/+xb/4F/+Ni3+AOMlPBgTE2/9XffwH8J4/4l/8i//GwD+k+HkO/huPS8tX9e8iuFoI
#@in9ri3/xL/7Fv/gX/+K/dvj3e/7Fv/gX/3WMfyhFSp+YHO79K1VKxiKkLZVuIXFYCIp/a4t/8S/+
#@xb/4F//iX/yLf/Ev/sU/BDyWg//GHAAc+M0D48A2ISj+rS3+xb/4F//iX/yLf/Ev/sW/+G91/APF
#@jHQbVU7GImViYv4+4GUhKP6tLf7Fv/gX/+Jf/It/8S/+xb/4b2H8Azx8dKj3paYdALBn1xyl2CIE
#@xb+1xb/4F//iX/yLf/Ev/sW/+Bf/LYz/uWIxbm92QgHQsbrv10GsEoLi39riX/yLf/Ev/sW/+Bf/
#@4l/8i/8Wwz/AQ4WhnmuoQTIWOW3RPgBMCUHxL/7Fv/gX/+Jf/It/8S/+xb/4F/8thv+ZlLVtaypK
#@5e8C6N8acIcQFP/iX/yLf/Ev/sW/+Bf/4l/8i3/x3yL4J5HunBrqHaRGyaiDHJo+6zvAi0JQ/It/
#@8S/+xb/4F//iX/yLf/Ev/sV/K+Cf4MAZs6U7mpNU+bsAzg/4I9AmQsW/+Bf/4l/8i3/xL/7Fv/gX
#@/+Jf/Dcx/okUGyeHun/UpKzKT0dn/72R2CxCxb/4F//iX/yLf/Ev/sW/+Bf/4l/8Nyv+gRcLMy+f
#@x8hIiRomo47SXjxzGPiXCBX/4l/8i3/xL/7Fv/gX/+Jf/It/8d+k+KeU2Fxr/AMEdZYVnX2dKcVu
#@8S/+xb/4F//iX/yLf/Ev/sW/+Bf/4r/Z8B/w6ORgTy+LkIw6y8GxnWMQo+Jf/It/8S/+xb/4F//i
#@X/yLf/Ev/sV/M+EfmCoWS4MADgAAgMjSV4E3xb8AF//iX/yLf/Ev/sW/+Bf/4l/8i/8mwT+kdPf0
#@LZe/5gDgHTm4e8frKcVm8S/Axb/4F//iX/yLf/Ev/sW/+Bf/4r8p8A/7C6fNf7t1qFf+twKMBlwq
#@/gW4+Bf/4l/8i3/xL/7Fv/gX/+Jf/Dcw/kmJ9VNDPY8DuAPgJJnP0jXAfvEvwMW/+Bf/4l/8i3/x
#@L/7Fv/gX/+K/UfEPPH0c/w4A3iVvPb3zzVLERiCJfwEu/sW/+Bf/4l/8i3/xL/7Fv/gX/w2I/yMp
#@K14LAOARgJws7+zfCVwr/gW4+Bf/4l/8i3/xL/7Fv/gX/+Jf/DcQ/gH6CoM9DwC4A4D8nN4+fyPw
#@D/EvwMW/+Bf/4l/8i3/xL/7Fv/gX/+K/gfD/p8LMy7sAHACcYv7z1K4CWeoF5sS/ABf/4l/8i3/x
#@L/7Fv/gX/+Jf/Iv/BsD/TJbavszISAnAIwDlHwW4DbhV/Atw8S/+xb/4F//iX/yLf/Ev/sW/+K9j
#@/AN8vTDYczuAOwAWkInx+duBPeJfgIt/8S/+xb/4F//iX/yLf/Ev/sV/HeN/b2Gm7S4ABwALzZ5d
#@c1GiG3hL/Atw8S/+xb/4F//iX/yLf/Ev/sW/+K9D/JdS8BVGumYBADwCwMKzYs1AV0rpMfEvwMW/
#@+Bf/4l/8i3/xL/7Fv/gX/+K/ntbFRHx3arB7C4ADgIoNAfq3p0S/+Bf/4l/8i3/xL/7Fv/gX/+Jf
#@/It/8V8n6+Lewsz0+YxsmAbwCECF8sHUdgOwR/yLf/Ev/sW/+Bf/4l/8i3/xL/7Fv/ivg3VxOqKt
#@9zj+3QFQ4SxdM3Bue+IFSMvEv/gX/+Jf/It/8S/+xb/4F//iX/yL/0VbFyP6C1u7dwI4AKjeVwOu
#@A54EQvyLf/Ev/sW/+Bf/4l/8i3/xL/7Fv/hfhHVxrLD1srVEJAAAjwBUIRNjO55KcJ/4F//iX/yL
#@f/Ev/sW/+Bf/4l/8i3/xX/t1MRuPUmnDcfw7AKhyDo3P35QSfxD/4l/8i3/xL/7Fv/gX/+Jf/It/
#@8S/+a7guJqK0cXK49wCAA4BaZM+uuWIWvQGHxL+1xb/4F//iX/yLf/Ev/sW/+Bf/4r8W62LAfYWt
#@PU8DOACoYQ7v3v4aEZcQMSv+rS3+xb/4F//iX/yLf/Ev/sW/+Bf/VV4X/za5JBsEcACwCDm4e/tz
#@KaUbxb+1xb/4F//iX/yLf/Ev/sW/+Bf/4p/q9duxLGVd3NA15QBgEXNobMf3gAfFv7XFv/gX/+Jf
#@/It/8S/+xb/4F//ivwr9llJKG44Ndf0dwAHAImfiwPx1wO/Fv7XFv/gX/+Jf/It/8S/+xb/4F//i
#@v5L9lhJ3TQ31PA7gAKBOHgo4syTWQ9on/q0t/sW/+Bf/4l/8i3/xL/7Fv/gX/xXBP/HM1OzZtwI4
#@AKijHP3F9kOlVPoccET8W1v8i3/xL/7Fv/gX/+Jf/It/8S/+/89++3dbim5GVs7ToAmaPB2dfZ+P
#@iJ8Bmfi3tvgX/+Jf/It/8S/+xb/4F//iX/wvoN9mgAsKg93PA7gDoG4fCrjzCRIj4t/a4l/8i3/x
#@L/7Fv/gX/+Jf/It/8b/Aftt0HP8OAOo8E2M7thE8Iv6tLf7Fv/gX/+Jf/It/8S/+xb/4F/9l9Vvw
#@g8Jg9/cBHAA0RtLEmQc3Ar8V/9YW/+Jf/It/8S/+xb/4F//iX/yL/1O85s+F6alNAA4AGimjo7O0
#@T19C4gXxL/7Fv/gX/+Jf/It/8S/+xb/4F//iP+cFr0apdDEjG6YdADRgJn75w6PttK0GXhH/4l/8
#@i3/xL/7Fv/gX/+Jf/It/8S/+3+UFb2Ul1k0O9x4AcADQoHl97P6DWWrrBA6If/Ev/sW/+Bf/4l/8
#@i3/xL/7Fv/gX/ye8YC5K6YvHhrv3AjgAaPCMj92/L5VYR3BM/It/8S/+xb/4F//iX/yLf/Ev/sW/
#@+H/Hn8erJod7fkcTJmjhrFg9sCZl6UmgXfyLf/Ev/sW/+Bf/4l/8i3/xL/7Ff0vjH4JvFLZ23wbg
#@AKAJ07G27wpS9hMgxL/4F//iX/yLf/Ev/sW/+Bf/4l/8tyb+g/To5Nbuy4lIDgCaegiwaZiUtol/
#@8S/+xb/4F//iX/yLf/Ev/sW/+G89/CfimamZ6GSkaxbAAUCTp2PNwLcIBgW4+Bf/4l/8i3/xL/7F
#@v/gX/+Jf/LcO/oG9p88sueDwyBcOAzgAaJmdAAN3AjcLcPEv/sW/+Bf/4l/8i3/xL/7Fv/hvCfz/
#@k9LcpwrDX/ovgAOAFsuytf13B7FFgIt/8S/+xb/4F//iX/yLf/Ev/sV/M+M/9pcoXTA92PMqgAOA
#@1kx0rB3YDvQJcPEv/sW/+Bf/4l/8i3/xL/7Fv/hvSvyPt6XihUeHel8CcADQ2ollazc9GKSrBbj4
#@F//iX/yLf/Ev/sW/+Bf/4l/8NxH+g8NRzFZODnf9hRZLpvVPmvTGmQf6gEcEuPgX/+Jf/It/8S/+
#@xb/4F//iX/w3Cf7hCJE+8078uwPAAMD69W3LCmc9HNAtwMW/+Bf/4l/8i3/xL/7Fv/gX/+K/ofFf
#@KEV0Tm+97DkAAHcAmLczOlp84/W5K0npCQEu/sW/+Bf/4l/8i3/xL/7Fv/gX/w2L/+kgLj6OfwcA
#@5uTZs2vuUOGs9cAjAlz8i3/xL/7Fv/gX/+Jf/It/8S/+/8fe/cdGfddxHH+9v9cfAquMXiVmmck2
#@jTHxx8hCTDMkGcuMYW3BmvXo0UnG3DrXFgZEbHvAdiiLkjmE0XWTMH/A1JigEUZNXNRgDJHFhC2K
#@BrPEKW4hspZW29631+O+b/9T4gwD+ut+PJ9/X/9p8s0nj1c+972iw39Wrpbx3jW/0GXxFQC6UhZv
#@7Nwr10YADv7BP/gH/+Af/IN/8A/+wT/4B//Fce3fpObx3taXIS0DwLVmtY2du821FfyDf/AP/sE/
#@+Af/4B/8g3/wD/7Bf0Gfi/90t4YwteYklGUAuO7iDZ3dkr4O/sE/+Af/4B/8g3/wD/7BP/gH/+C/
#@IM/FYXdfGaaSryBY3gEwpYYGnt0teaekCPyDf/AP/sE/+Af/4B/8g3/wD/7Bf0Gdi/+wKLoL/HMD
#@YFqLN3TdL/l3JFWAf/AP/sE/+Af/4B/8g3/wD/7BP/if83PxXD6Wvyf75bbXESs3AKb5JkDfi3Ld
#@JykL/sE/+Af/4B/8g3/wD/7BP/gH/+B/Ds9F0xuR8ivAPwPAjDX0s2ePeuCrJI2Cf/AP/sE/+Af/
#@4B/8g3/wD/7BP/ifk3PxjPK5ZRO9bX9BqQwAM9rFl/pfjpS/U9I58A/+wT/4B//gH/yDf/AP/sE/
#@+Af/s3cuuuxXVdnq5Zltnz+PThkAZqXhgefPWC5XL+k0+Af/4B/8g3/wD/7BP/gH/+Af/IP/2Xje
#@/Hth1laOpJtHUCkvAZz13tfScUMU2g8lNYJ/8A/+wT/4B//gH/yDf/AP/sE/+J+R580l/0qmp3Wn
#@zByJMgDMXS0tsXi4eJ+kTvAP/sE/+Af/4B/8g3/wD/7BP/gH/9P6vE2a+0PjqeRh8MkAUDDVNnY9
#@ZvI9kgLwD/7BP/gH/+Af/IN/8A/+wT/4B/9Tft6GA/nnxnqTJxAn7wAoqC4e79vnZglJIfgH/+Af
#@/IN/8A/+wT/4B//gH/yD/yk8b6Y3gkDLwD83AAq6Rau6lgWR/0TSYvAP/sE/+Af/4B/8g3/wD/7B
#@P/gH/9f8vL0SVEyuGtu67gLC5AZAQTd8rO+klL9DslPgH/yDf/AP/sE/+Af/4B/8g3/wD/6v/m9c
#@OpypDlaAf24AFFUfWrmh+mLM95v8YfAP/sE/+Af/4B/8g3/wD/7BP/gH/1f8m6ybusOe1n1okgGg
#@aIs3dqyT7HlJ88A/+Af/4B/8g3/wD/7BP/gH/+Af/P/vB+xND7wl7G49hSD5CkBRN3S8/5B5tFzS
#@38A/+Af/4B/8g3/wD/7BP/gH/+Af/P/3Ayb/tUX5peCfGwAlVU1Te12VV/5I0t3gH/yDf/AP/sE/
#@+Af/4B/8g3/wX+b4d5PtH68d+ZIeeSSHGBkASq+70hXxmrd3ydUN/sE/+Af/4B/8g3/wD/7BP/gH
#@/+WIf5dG5f5gmEoeAYkMACVfvKHrfpk/J9MN4B/8g3/wD/7BP/gH/+Af/IN/8F8u+Jf0h5hHidHU
#@2rPIkHcAlEVDA30vXjL7hKTfgn/wD/7BP/gH/+Af/IN/8A/+wX8Z4N8lHchkF9SDf24AlO1XAure
#@O7jd3XdICsA/+Af/4B/8g3/wD/7BP/gH/+C/9PAfXJBFD2Z6kgMgkBsA5duJ9KXBY31pyT4t6S3w
#@D/7BP/gH/+Af/IN/8A/+wT/4Lyn8u/1c0eQS8M8NAHrnrwS8INMq8A/+wT/4B//gH/yDf/AP/sE/
#@+C9y/E+4WU/YveYZmTniYwCg/1O8sWOdzJ6TNB/8g3/wD/7BP/gH/+Af/IN/8A/+ixD/ZyzytvFt
#@a3+P8PgKAF2hoeP9h6LA6iX9EfyDf/AP/sE/+Af/4B/8g3/wD/6LCP+Ry57OLFi4FPxzA4CuoZtb
#@Ns/LZCd3mmuLpBj4B//gH/yDf/AP/sE/+Af/4B/8FzD+z3hgD4fdrafQHAMAXWeLGzfcnrfo25Lu
#@AP/gH/yDf/AP/sE/+Af/4B/8g/8Cw3/OpT3hgoVPaOO9WQTHAEBTrb29Mn6+couknZKqwT/4B//g
#@H/yDf/AP/sE/+Af/4L8AzsWTgcfax1KJP4E2BgCa5hY1fPFjQRB7QdInwT/4B//gH/yDf/AP/sE/
#@+Af/4H+OzsV/udnj4cTZ/UqnI6TGAEAzVTod1J0efMjd90haAP7BP/gH/+Af/IN/8A/+wT/4B/+z
#@eC4OeF6PhtuTfwdnDAA0S9Xd2/nhqMIPmtty8A/+wT/4B//gH/yDf/AP/sE/+J/hc/FNd20OU8kj
#@aIwBgObwNoDkT7pUB/7BP/gH/+Af/IN/8A/+wT/4B//TfC6Gcn8qM1mzW+mmDAhjAKA57sbPbrox
#@ls/tlKlDUgX4B//gH/yDf/AP/sE/+Af/4B/8T8O5eDySNkz0Jv+KuhgAqMCKN3V9ROZ7JX0G/IN/
#@8A/+wT/4B//gH/yDf/AP/q/reTOdjiJtmkglf4OyGACowKtb3dHkbs9IugX8g3/wD/7BP/gH/+Af
#@/IN/8A/+r/J5G3SzXeFtQZ8SiTyyKu4C/gXl0eDR/peqPfdRk31V0gT4B//gH/yDf/AP/sE/+Af/
#@4B/8X+FDWTftnh/Mvy3sad0H/rkBQEXawqauWyvMn5bUDP7BP/gH/+Af/IN/8A/+wT/4B/+XlZP0
#@XQ9iu8KexDn0xABAJVJt06P1ZsGTku4G/+Af/IN/8A/+wT/4B//gH/yXNf4jk358KR9ty+5oex0t
#@MQBQiRZfveEeefQ1SUvBP/gH/+Af/IN/8A/+wT/4B/9lg///wD/Ix3aM7kj8GR0xAFAZDQHu/g0z
#@3Q7+wT/4B//gH/yDf/AP/sE/+C9p/LukAZkez/QmX0VDDABUjrW0xOKT728zedqlW8E/+Af/4B/8
#@g3/wD/7BP/gH/yWFf5cM+DMAEF1We3tl3YWq9e56QtJN4B/8g3/wD/7BP/gH/+Af/IP/osZ/zmQ/
#@dbOnMr2tvwM8DABE7+jmls3zwsnceklbJH0Q/IN/8A/+wT/4B//gH/yDf/BfVPgfcbdvyWP7w+2J
#@txAOAwDRu5dOB3WvDjW4PCVZPfgH/+Af/IN/8A/+wT/4B//gv6Dxf17uB6pyk3tH0utHAA0xANB1
#@taj5sU8F7t2SN0gy8A/+wT/4B//gH/yDf/AP/sF/weD/NXP/5njuph8oveISeiEGAJqWFq3u+nhg
#@tlVSq6RK8A/+wT/4B//gH/yDf/AP/sH/nOB/0mRHzdQ/1ps8gVSIAYBmrNrVHR8ILLbJpS9IWgj+
#@wT/4B//gH/yDf/AP/sE/+J95/Lt0NnAdNKs4NJZKvI1MiAGAZq1bHnjgPaPDNQk332wKloB/8A/+
#@wT/4B//gH/yDf/AP/qf9jMua2TFZdGC8Z+0vZeZIhBgAaI5vBWy80wJ1SLpPUjX4B//gH/yDf/AP
#@/sE/+Af/4H9KZ9xrkh2syk18n5f6EQMAFWQ1zZ3xKgVtLltv0hLwD/7BP/gH/+Af/IN/8A/+wf9V
#@n3HnJR1REBzmt/v/3d7dtMZVhnEYv+4zSUpt2sQmaStRaE02VgVpEKSIaIrgC4ZWScCKha66Klao
#@IogwX0dFEBQM0pXGCgUVHSjYTbKo+JYxhnbSZCbz3O5d+FIoTTLX9REGDty/P8M55gBg26rRly8c
#@S7pnM+M0sF/8i3/xL/7Fv/gX/+Jf/It/8f+3gt9IPioR76+3r31JvV6UhDkA2PZtdrY2Ug49U7q1
#@MxF5ChgU/+Jf/It/8S/+xb/4F//iv4fxv5LJp0F8uDZ2Y55z5zqiwRwAbMc1OvP23uxbP5kRr5Kc
#@AAbEv/gX/+Jf/It/8S/+xb/47wH8r5B8HLX4oLVx3yW/2W8OANZTDZ+8MFxFPpsRLwV5ChgU/+Jf
#@/It/8S/+xb/4F//ifwfh/2rCJ1XhUqvb/wX1ubYKMAcA6/kOvn5xT6e1+XzCTAXPJYyJf/Ev/sW/
#@+Bf/4l/8i3/xv83w/0ckn1PLebKab717+lcvfXMAMPun6vVqpLHyeGa8SMQLkMeAEP/iX/yLf/Ev
#@/sW/+Bf/4n+L4b8Q8Q2F+azFZ7cm+64wN9f1oDcHALPb7MDMGwc7/TEdxAlgGvKI+Bf/4l/8i3/x
#@L/7Fv/gX/3fheWslXImMBar8eldt4PLKO3OrXuzmAGB2hxp65c0Ha5HTmfFURR5PYkL8i3/xL/7F
#@v/gX/+Jf/Iv/O/C8/UzwVZZciIzLa2X8O1/eZw4AZnexsdm3DpXsHE/iSeAJ4DFgt/gX/+Jf/It/
#@8S/+xb/4F////QfM3zPihwoaEN92s7uw/t6ZRa9tcwAw28o9Xe+7d2z1oYqYKiWnIpiCeBQYFP/i
#@X/yLf/Ev/sW/+Bf/PY//DeAq0IioGnTL9+Rmo1U/+4uHtDkAmO2MYmj24uEKjpLlESIfDuIoMAkM
#@iX/xL/7Fv/gX/+Jf/Iv/HYX/TSKuJ2UxMpaIWEr4sVbRuNkev+bf+M0BwKxHG5w9PzZQ9U9kMhmF
#@CYgjBOMQ45APAIPiX/yLf/Ev/sW/+Bf/4n/r4D/hRsAyyU9ZVYuRZTEilqJUS5vZXlzn8HWRb+YA
#@YPa/2//a+X20B+4vlLEqYjSTA1XESAajkYwmcQ+wF3IfVLsJ9pA5DAQBQADD4l/8i3/xL/7Fv/gX
#@/72K/4SbAR2gBLEKkOQtYB0A+JOIBDaIWCZpJjSB5YxczqTZV2iW/miudXY1qc+1vVLN/r2/ALve
#@ODK0omk7AAAAAElFTkSuQmCC
