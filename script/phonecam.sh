#!/usr/bin/env bash
# =============================================================================
#  PhoneCam — todo-en-uno
#  Autor: Filonux
#
#  Usa tu Android como webcam y/o micrófono en Linux Mint 22.3 (Cinnamon) por
#  cable USB, vía scrcpy + v4l2loopback + PipeWire/PulseAudio. Sin APK, sin
#  Wi-Fi, sin nube.
#
#  El menú (gráfico con zenity, o de texto si no está disponible) muestra el
#  estado actual del teléfono/webcam/micrófono y cada opción indica qué
#  necesita el usuario antes de pulsarla.
#
#  Este único archivo contiene TODO lo que antes eran varios ficheros:
#  instalador, desinstalador, CLI (bin/phonecam), agente en segundo plano
#  (bin/phonecam-agent), plantilla de configuración, lanzador .desktop y
#  unidad systemd --user. "install" se copia a sí mismo a ~/.local/bin/phonecam
#  y genera el resto de piezas a partir de aquí.
#
#  Uso:
#    ./phonecam.sh install [--yes]   Instala dependencias y deja "phonecam"
#                                     disponible como comando del sistema.
#    phonecam menu                   Menú gráfico (o de texto si no hay zenity)
#    phonecam webcam | mic | both    Inicia cámara y/o micrófono
#    phonecam stop                   Detiene todo
#    phonecam status                 Estado actual
#    phonecam cameras | choose-cam   Listar / elegir cámara del teléfono
#    phonecam config                 Editar configuración
#    phonecam uninstall              Desinstala PhoneCam
#
#  Ejecuta "./phonecam.sh help" para el listado completo.
# =============================================================================
set -uo pipefail

PHONECAM_VERSION="1.0.0"

# ---------- Ruta real de este script (para que "install" pueda copiarse) -----
SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"

# ---------- Rutas de instalación / datos de usuario ----------
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

PID_WEBCAM="$RUN_DIR/webcam.pid"
PID_MIC="$RUN_DIR/mic.pid"
PID_ROUTE="$RUN_DIR/route.pid"
PID_AGENT="$RUN_DIR/agent.pid"

V4L2_NR_DEFAULT=42
V4L2_LABEL="PhoneCam"

# ---------- Colores / mensajes ----------
# Se recalcula en cada llamada (no una sola vez al arrancar) porque la salida
# de estas funciones puede acabar canalizada hacia zenity/yad --text-info
# dentro del propio menú: si el color se decidiera una sola vez, los códigos
# ANSI viajarían tal cual dentro del pipe y aparecerían como texto literal.
use_color() { [ -t 1 ]; }

use_color_err() { [ -t 2 ]; }

info()  { if use_color; then echo -e "\e[34mℹ\e[0m $*"; else echo "ℹ $*"; fi; }
ok()    { if use_color; then echo -e "\e[32m✓\e[0m $*"; else echo "✓ $*"; fi; }
warn()  { if use_color; then echo -e "\e[33m⚠\e[0m $*"; else echo "⚠ $*"; fi; }
# Mira fd 2 (no fd 1: err() escribe en stderr), para no colar códigos ANSI
# si algún día se redirige solo la salida de error a un archivo.
err()   { if use_color_err; then echo -e "\e[31m✗\e[0m $*" >&2; else echo "✗ $*" >&2; fi; }
hdr()   { if use_color; then echo -e "\e[1m$*\e[0m"; else echo "$*"; fi; }

# ask_yn "pregunta" default(y/n) -> usa NONINTERACTIVE si está a 1
NONINTERACTIVE=0
ask_yn() {
    local prompt="$1" default="${2:-y}" reply
    if [ "$NONINTERACTIVE" -eq 1 ]; then
        [ "$default" = "y" ] && return 0 || return 1
    fi
    read -rp "$prompt [$([ "$default" = "y" ] && echo "S/n" || echo "s/N")]: " reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^([sS]|[yY])$ ]]
}

notify() {
    # Notificación de escritorio si está disponible; si no, no hace nada más
    # (el mensaje ya se ha mostrado por terminal con info/ok/warn).
    command -v notify-send >/dev/null 2>&1 && notify-send -a "PhoneCam" "$1" "${2:-}"
    return 0
}

# ---------- Configuración (valores por defecto + carga de phonecam.conf) ----
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
        warn "No existe $CONF_FILE, usando valores por defecto."
        warn "Ejecuta '$(basename "$SELF_PATH") install' si todavía no has instalado PhoneCam."
    fi
}

# ---------- Comprobación de herramientas ----------
# IMPORTANTE: esta función NUNCA debe hacer "exit" (solo "return"). Se llama
# desde dentro del bucle del menú interactivo (gráfico y de texto); si aquí
# se terminara el proceso con "exit", el menú se cerraría de golpe en vez de
# mostrar el error y volver a la lista de opciones.
require_tools() {
    local missing=() t
    for t in adb pactl; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        err "Faltan herramientas: ${missing[*]}."
        err "Ejecuta '$(basename "$SELF_PATH") install' primero."
        return 1
    fi

    # scrcpy se gestiona aparte: si falta o es demasiado antiguo (el
    # paquete de los repositorios de Ubuntu/Mint suele estar muy
    # desactualizado), se ofrece descargar automáticamente el build oficial.
    if ! ensure_scrcpy_installed; then
        err "'scrcpy' no está disponible en una versión compatible (se necesita >= 2.2)."
        err "Instálalo manualmente: https://github.com/Genymobile/scrcpy/blob/master/doc/linux.md"
        return 1
    fi
    return 0
}

# ---------- Selección de dispositivo ADB ----------
adb_serial() {
    # timeout en ambas llamadas: si el servidor adb se queda colgado (primera
    # vez arrancando, dispositivo en mal estado, servidor bloqueado...), que
    # fallen con claridad en unos segundos en vez de dejar el menú congelado
    # sin explicación.
    timeout 10 adb start-server >/dev/null 2>&1
    local list count
    list=$(timeout 10 adb devices | awk 'NR>1 && $2=="device" {print $1}')
    count=$(printf '%s\n' "$list" | grep -c . || true)

    if [ "$count" -eq 0 ]; then
        err "No se detecta ningún teléfono autorizado por ADB."
        {
            echo "   - Conecta el móvil por USB."
            echo "   - Activa 'Depuración USB' en Opciones de desarrollador."
            echo "   - Acepta el diálogo de autorización que aparece en el teléfono"
            echo "     (marca 'recordar en este equipo' para no repetirlo)."
            echo "   - Comprueba con: adb devices"
        } >&2
        return 1
    elif [ "$count" -eq 1 ]; then
        printf '%s\n' "$list"
        return 0
    else
        if command -v zenity >/dev/null 2>&1; then
            local chosen
            chosen=$(printf '%s\n' "$list" | zenity --list --title="PhoneCam" \
                --text="Se han detectado varios dispositivos. Elige uno:" \
                --column="Serial" 2>/dev/null)
            [ -n "$chosen" ] && { echo "$chosen"; return 0; }
            warn "No se ha elegido ningún dispositivo." >&2
            return 1
        else
            # >&2: esta función se invoca como "serial=$(adb_serial)"; si el
            # aviso fuera a stdout (comportamiento normal de warn()) se
            # colaría dentro de $serial junto al serial real.
            warn "Hay varios dispositivos conectados. Usando el primero:" >&2
            printf '%s\n' "$list" | head -1
            return 0
        fi
    fi
}

# ---------- Comprobar versión mínima de scrcpy (>= 2.2 para modo cámara) -----
check_scrcpy_version() {
    local raw rc ver major minor
    raw=$(scrcpy --version 2>&1)
    rc=$?
    # Si el binario ni siquiera se ejecuta (p.ej. faltan bibliotecas del
    # sistema tras una descarga incompleta/corrupta), tratarlo como "no
    # disponible" en vez de asumir que está bien: si no, ensure_scrcpy_installed
    # daría por válido un scrcpy que luego fallará al arrancar la webcam/mic.
    if [ "$rc" -ne 0 ]; then
        warn "No se pudo ejecutar 'scrcpy --version' (código $rc)."
        printf '%s\n' "$raw" | head -3 | while IFS= read -r line; do warn "  $line"; done
        return 1
    fi
    ver=$(printf '%s\n' "$raw" | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    if [ -z "$ver" ]; then
        warn "No se pudo determinar la versión de scrcpy."
        return 0
    fi
    # "10#": fuerza base 10 al convertir a entero. Sin esto, un número con
    # cero a la izquierda (p.ej. "09") se interpretaría como octal inválido
    # y "[ -lt ]" abortaría con "value too great for base" en vez de dar
    # un error legible.
    major=$((10#$(echo "$ver" | cut -d. -f1)))
    minor=$((10#$(echo "$ver" | cut -d. -f2)))
    if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 2 ]; }; then
        err "scrcpy $ver es demasiado antiguo (se necesita >= 2.2 para el modo cámara)."
        err "Actualiza scrcpy: https://github.com/Genymobile/scrcpy/releases"
        return 1
    fi
    return 0
}

# =============================================================================
#  Instalación automática de scrcpy (build oficial estático)
#
#  El paquete "scrcpy" de los repositorios de Ubuntu/Linux Mint suele quedarse
#  muy atrás (a menudo en la serie 1.x), muy por debajo de la versión 2.2 que
#  PhoneCam necesita (tanto para cámara como para micrófono). Por eso
#  PhoneCam no depende de apt para scrcpy: descarga el build oficial estático
#  para Linux publicado en los "releases" de GitHub y lo deja enlazado en
#  ~/.local/bin, sin necesitar contraseña de sudo.
# =============================================================================

# Descarga usando curl o wget, lo que haya disponible.
fetch_to_stdout() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$url"
    else
        return 127
    fi
}

fetch_to_file() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 2 --progress-bar -o "$out" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --show-progress -O "$out" "$url"
    else
        return 127
    fi
}

ensure_downloader() {
    command -v curl >/dev/null 2>&1 && return 0
    command -v wget >/dev/null 2>&1 && return 0
    warn "Se necesita 'curl' o 'wget' para descargar scrcpy y no se encontró ninguno."
    if [ "$NONINTERACTIVE" -eq 1 ] || { [ -t 0 ] && ask_yn "¿Instalar 'curl' ahora? (requiere sudo)" y; }; then
        sudo apt install -y curl && return 0
    fi
    return 1
}

# Ejecuta un comando en segundo plano mostrando un diálogo de progreso
# indeterminado de zenity mientras dura. Devuelve el código de salida real
# del comando (no el de zenity).
run_with_zenity_progress() {
    local text="$1"; shift
    "$@" &
    local pid=$!
    ( while kill -0 "$pid" 2>/dev/null; do echo "#$text"; sleep 1; done ) \
        | zenity --progress --pulsate --auto-close --no-cancel \
            --title="PhoneCam" --window-icon="camera-web" --width=380 \
            --text="$text" 2>/dev/null
    wait "$pid"
}

download_scrcpy_release() {
    ensure_downloader || return 1

    local arch; arch="$(uname -m)"
    if [ "$arch" != "x86_64" ]; then
        err "No hay build oficial estático de scrcpy para tu arquitectura ($arch)."
        err "Instálalo manualmente siguiendo: https://github.com/Genymobile/scrcpy/blob/master/doc/linux.md"
        return 1
    fi

    info "Consultando la última versión de scrcpy en GitHub..."
    local api="https://api.github.com/repos/Genymobile/scrcpy/releases/latest"
    local meta tarball_url
    meta=$(fetch_to_stdout "$api") || meta=""
    tarball_url=$(printf '%s' "$meta" \
        | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*scrcpy-linux-x86_64[^"]*\.tar\.gz"' \
        | head -1 | grep -oE 'https://[^"]+')

    if [ -z "$tarball_url" ]; then
        err "No se pudo obtener la URL de descarga de scrcpy (¿sin conexión, o límite de la API de GitHub?)."
        err "Descárgalo manualmente desde: https://github.com/Genymobile/scrcpy/releases/latest"
        return 1
    fi

    local tmp_dir; tmp_dir="$(mktemp -d)" || return 1
    info "Descargando $(basename "$tarball_url")..."
    if ! fetch_to_file "$tarball_url" "$tmp_dir/scrcpy.tar.gz"; then
        err "La descarga de scrcpy ha fallado."
        rm -rf "$tmp_dir"
        return 1
    fi

    info "Extrayendo scrcpy..."
    if ! tar -xzf "$tmp_dir/scrcpy.tar.gz" -C "$tmp_dir"; then
        err "No se pudo extraer el archivo descargado."
        rm -rf "$tmp_dir"
        return 1
    fi

    local extracted_dir
    extracted_dir=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
    [ -z "$extracted_dir" ] && extracted_dir="$tmp_dir"

    if [ ! -x "$extracted_dir/scrcpy" ]; then
        err "El paquete descargado no contiene el ejecutable 'scrcpy' esperado."
        rm -rf "$tmp_dir"
        return 1
    fi

    mkdir -p "$SCRCPY_DIR" "$BIN_DIR"
    rm -rf "${SCRCPY_DIR:?}"/*
    cp -a "$extracted_dir"/. "$SCRCPY_DIR"/
    chmod +x "$SCRCPY_DIR/scrcpy"
    ln -sf "$SCRCPY_DIR/scrcpy" "$BIN_DIR/scrcpy"
    rm -rf "$tmp_dir"
    hash -r 2>/dev/null || true
    [[ ":$PATH:" != *":$BIN_DIR:"* ]] && export PATH="$BIN_DIR:$PATH"

    if [ -x "$BIN_DIR/scrcpy" ]; then
        ok "scrcpy instalado en $SCRCPY_DIR (enlazado en $BIN_DIR/scrcpy)."
        return 0
    fi
    err "No se pudo dejar 'scrcpy' operativo tras la descarga."
    return 1
}

# Punto de entrada único: comprueba si scrcpy está listo (presente y con
# versión suficiente) y, si no lo está, ofrece instalarlo automáticamente sin
# necesitar sudo. Se puede llamar sin miedo tantas veces como haga falta: si
# ya está todo en orden, no hace nada (comprobación rápida y silenciosa).
ensure_scrcpy_installed() {
    if command -v scrcpy >/dev/null 2>&1 && check_scrcpy_version >/dev/null 2>&1; then
        return 0
    fi

    if command -v scrcpy >/dev/null 2>&1; then
        warn "La versión de scrcpy instalada es demasiado antigua (se necesita >= 2.2 para cámara/micrófono)."
    else
        warn "No se ha encontrado 'scrcpy' en este sistema."
    fi

    if [ "$NONINTERACTIVE" -ne 1 ]; then
        if [ -t 0 ]; then
            ask_yn "¿Descargar e instalar automáticamente la última versión oficial de scrcpy?" y || {
                warn "Instalación de scrcpy cancelada por el usuario."
                return 1
            }
        elif command -v zenity >/dev/null 2>&1; then
            zenity --question --title="PhoneCam" --window-icon="camera-web" --width=460 \
                --text="PhoneCam necesita 'scrcpy' (versión 2.2 o superior) y no está disponible.\n\n¿Descargar e instalar automáticamente la última versión oficial ahora?\n(no requiere contraseña de sudo)" \
                2>/dev/null || { warn "Instalación de scrcpy cancelada por el usuario."; return 1; }
        fi
        # Si no hay terminal interactiva ni zenity (p.ej. el agente en
        # segundo plano arrancando sin interacción posible), se continúa
        # directamente: es mejor intentarlo que fallar en silencio sin dar
        # ninguna forma de arreglarlo.
    fi

    local result
    if [ ! -t 1 ] && command -v zenity >/dev/null 2>&1; then
        # run_with_zenity_progress lanza download_scrcpy_release en una
        # subshell ("&"): su "export PATH"/"hash -r" final solo afecta a esa
        # subshell y no llega a este proceso, por eso se repiten fuera abajo.
        run_with_zenity_progress "Descargando e instalando scrcpy..." download_scrcpy_release
        result=$?
    else
        download_scrcpy_release
        result=$?
    fi

    if [ "$result" -eq 0 ]; then
        [[ ":$PATH:" != *":$BIN_DIR:"* ]] && export PATH="$BIN_DIR:$PATH"
        hash -r 2>/dev/null || true
    fi
    return "$result"
}

# ---------- v4l2loopback ----------
ensure_v4l2_device() {
    if [ ! -e "$V4L2_DEVICE" ]; then
        err "No existe $V4L2_DEVICE. ¿Está cargado el módulo v4l2loopback?"
        echo "   Prueba: sudo modprobe v4l2loopback"
        echo "   o vuelve a ejecutar: $(basename "$SELF_PATH") install"
        echo "   Si acabas de instalar y el equipo tiene Secure Boot activado,"
        echo "   puede que necesites reiniciar y aceptar el enrolamiento MOK."
        return 1
    fi
    if [ ! -w "$V4L2_DEVICE" ]; then
        err "No tienes permiso de escritura en $V4L2_DEVICE."
        echo "   Te falta el grupo 'video': cierra sesión y vuelve a entrar tras"
        echo "   ejecutar '$(basename "$SELF_PATH") install' (o reinicia el equipo)."
        return 1
    fi
    return 0
}

# ---------- Audio virtual (PipeWire/PulseAudio, idempotente) ----------
ensure_audio_devices() {
    if ! pactl list short sinks 2>/dev/null | grep -qw "$MIC_SINK_NAME"; then
        info "Creando sink virtual '$MIC_SINK_NAME'..."
        if ! pactl load-module module-null-sink \
            sink_name="$MIC_SINK_NAME" \
            sink_properties=device.description="$MIC_SINK_NAME" >/dev/null; then
            err "No se pudo crear el sink virtual '$MIC_SINK_NAME' (¿PipeWire/PulseAudio en marcha?)."
            return 1
        fi
    fi
    if ! pactl list short sources 2>/dev/null | grep -qw "$MIC_SOURCE_NAME"; then
        info "Creando micrófono virtual '$MIC_SOURCE_NAME'..."
        if ! pactl load-module module-remap-source \
            master="${MIC_SINK_NAME}.monitor" \
            source_name="$MIC_SOURCE_NAME" \
            source_properties=device.description="$MIC_SOURCE_NAME" >/dev/null; then
            err "No se pudo crear el micrófono virtual '$MIC_SOURCE_NAME'."
            return 1
        fi
    fi
    return 0
}

# Mueve el stream de audio de scrcpy hacia el sink virtual, para que termine
# sonando en el "micrófono" PhoneMic. Se ejecuta en segundo plano porque el
# sink-input de scrcpy tarda un instante en aparecer tras arrancar.
route_audio_to_mic() {
    local timeout=15 waited=0 id=""
    while [ "$waited" -lt "$timeout" ]; do
        # Sin "exit": si hubiera un END, awk ejecuta igualmente el END tras un
        # "exit" del cuerpo principal, y el id/binary del match no se resetean
        # -> el mismo ID se imprimía dos veces si scrcpy no era el ÚLTIMO
        # sink-input de la lista, y ese "14\n14" hacía fallar move-sink-input.
        id=$(pactl list sink-inputs 2>/dev/null | awk '
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
                ok "Audio del teléfono enrutado al micrófono virtual."
                cleanup_route_pidfile
                return 0
            fi
        fi
        sleep 1
        waited=$((waited+1))
    done
    warn "No se pudo enrutar el audio automáticamente en ${timeout}s."
    warn "Puedes hacerlo a mano con 'pavucontrol' (pestaña Reproducción -> mover"
    warn "el stream de scrcpy a '$MIC_SINK_NAME')."
    cleanup_route_pidfile
    return 1
}

# Borra PID_ROUTE al terminar route_audio_to_mic, solo si el fichero sigue
# apuntando a este mismo proceso en segundo plano. Así el pidfile no se
# queda con un PID muerto una vez completado el enrutado (éxito o timeout),
# sin arriesgarse a borrar por encima el de un enrutado más reciente si el
# micrófono se paró y volvió a arrancar justo entonces.
cleanup_route_pidfile() {
    local stored
    stored=$(cat "$PID_ROUTE" 2>/dev/null)
    [ "$stored" = "$BASHPID" ] && rm -f "$PID_ROUTE"
}

video_bitrate() { [ "$VIDEO_QUALITY_PROFILE" = "max" ] && echo "$VIDEO_BITRATE_MAX" || echo "$VIDEO_BITRATE_BALANCED"; }
video_codec()   { [ "$VIDEO_QUALITY_PROFILE" = "max" ] && echo "h265" || echo "h264"; }

# Construyen arrays de argumentos (más robusto que devolver strings y
# depender del "word splitting" de una sustitución de comandos sin comillas).
build_camera_args() {
    CAMERA_ARGS=()
    if [ -n "$CAMERA_ID" ]; then
        CAMERA_ARGS+=("--camera-id=$CAMERA_ID")
    else
        CAMERA_ARGS+=("--camera-facing=$CAMERA_FACING")
    fi
}

build_extra_args() {
    EXTRA_ARGS=()
    [ "$TURN_SCREEN_OFF" = "true" ] && EXTRA_ARGS+=("--turn-screen-off")
    [ "$KEEP_AWAKE" = "true" ] && EXTRA_ARGS+=("--stay-awake")
}

is_running() {
    local pidfile="$1" pid
    [ -f "$pidfile" ] || return 1
    pid=$(cat "$pidfile" 2>/dev/null)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    # Un zombi (ya terminado, pendiente solo de que su padre lo recoja)
    # sigue respondiendo a "kill -0": sin este descarte, un scrcpy recién
    # matado podía seguir contando como "activo" durante ese margen.
    grep -q '^State:[[:space:]]*Z' "/proc/$pid/status" 2>/dev/null && return 1
    # Confirma que ese PID sigue siendo scrcpy y no otro proceso que el
    # sistema le haya reasignado tras un cierre brusco que dejara el
    # pidfile huérfano (p.ej. un corte de luz).
    [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = "scrcpy" ]
}

# Envía SIGTERM y espera (hasta "timeout" segundos, sondeando cada 0.2s) a
# que el proceso termine de verdad antes de devolver el control; si sigue
# vivo pasado ese plazo, insiste con SIGKILL. Sin esto, "detener" devolvía
# el control al instante aunque el proceso tardara en cerrarse, y un
# reinicio inmediato podía toparse con el dispositivo todavía ocupado.
terminate_pid() {
    local pid="$1" timeout="${2:-3}" waited=0
    kill -0 "$pid" 2>/dev/null || return 0
    kill "$pid" 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
        waited=$((waited + 1))
        [ "$waited" -ge $((timeout * 5)) ] && { kill -9 "$pid" 2>/dev/null; break; }
        sleep 0.2
    done
    # Por si acaso el PID resulta ser hijo directo de este shell, "wait" lo
    # recoge para no dejarlo zombi; si no lo es (el caso normal: el PID viene
    # de un pidfile, de otra invocación), falla en silencio sin problema.
    wait "$pid" 2>/dev/null
    return 0
}

# ---------- Modo: solo webcam ----------
start_webcam() {
    # Comprobar primero si ya hay una webcam activa: así, si el teléfono se
    # ha desconectado o el dispositivo v4l2 no está disponible mientras
    # scrcpy sigue vivo, el usuario ve "ya está activa" en vez de un error
    # de "dispositivo no encontrado" que no describe lo que está pasando.
    if is_running "$PID_WEBCAM"; then
        warn "Ya hay una webcam activa (PID $(cat "$PID_WEBCAM"))."
        return 0
    fi

    # flock no bloqueante: sin esto, dos invocaciones casi simultáneas
    # (p.ej. doble clic en el lanzador) pasan ambas el "is_running" de
    # arriba y acaban lanzando dos scrcpy contra el mismo /dev/video*.
    (
        flock -n 9 || { warn "La webcam ya se está iniciando en otro proceso."; exit 1; }
        is_running "$PID_WEBCAM" && exit 0

        require_tools || exit 1
        ensure_v4l2_device || exit 1
        local serial; serial=$(adb_serial) || exit 1

        build_camera_args
        build_extra_args
        local size_arg=()
        [ -n "$CAMERA_SIZE" ] && size_arg=(--camera-size="$CAMERA_SIZE")

        info "Iniciando webcam ($(video_codec), $(video_bitrate), ${CAMERA_FPS}fps)..."
        nohup scrcpy -s "$serial" \
            --video-source=camera \
            "${CAMERA_ARGS[@]}" \
            "${size_arg[@]}" \
            --camera-fps="$CAMERA_FPS" \
            --video-codec="$(video_codec)" \
            --video-bit-rate="$(video_bitrate)" \
            --v4l2-sink="$V4L2_DEVICE" \
            --no-playback \
            --no-audio \
            --no-control \
            "${EXTRA_ARGS[@]}" \
            < /dev/null > "$LOG_DIR/webcam.log" 2>&1 &
        echo $! > "$PID_WEBCAM"
        sleep 1
        if ! is_running "$PID_WEBCAM"; then
            err "scrcpy no arrancó correctamente. Revisa $LOG_DIR/webcam.log"
            rm -f "$PID_WEBCAM"
            exit 1
        fi
        ok "Webcam activa en $V4L2_DEVICE (PID $(cat "$PID_WEBCAM"))"
        notify "Webcam activa" "Selecciónala en tu app como 'PhoneCam' / 'Dummy video device'."
    ) 9>"$RUN_DIR/webcam.lock"
}

# ---------- Modo: solo micrófono ----------
start_mic() {
    # Mismo motivo que en start_webcam: comprobar el estado "ya activo"
    # antes de exigir el teléfono por ADB, para no confundir "ya está
    # activo" con "teléfono no detectado" si se ha desconectado.
    if is_running "$PID_MIC"; then
        warn "El micrófono ya está activo (PID $(cat "$PID_MIC"))."
        return 0
    fi

    # Mismo flock no bloqueante que start_webcam, y por el mismo motivo.
    (
        flock -n 9 || { warn "El micrófono ya se está iniciando en otro proceso."; exit 1; }
        is_running "$PID_MIC" && exit 0

        require_tools || exit 1
        local serial; serial=$(adb_serial) || exit 1
        ensure_audio_devices || exit 1

        build_extra_args

        info "Iniciando micrófono ($AUDIO_CODEC, $AUDIO_BITRATE)..."
        # --no-video es imprescindible aquí: sin él, scrcpy sigue capturando y
        # codificando la pantalla del teléfono aunque no se muestre ninguna
        # ventana (--no-window solo evita mostrarla), desperdiciando ancho de
        # banda/CPU y pidiendo permiso de captura de pantalla innecesariamente.
        nohup scrcpy -s "$serial" \
            --no-window \
            --no-video \
            --audio-source="$AUDIO_SOURCE" \
            --audio-codec="$AUDIO_CODEC" \
            --audio-bit-rate="$AUDIO_BITRATE" \
            "${EXTRA_ARGS[@]}" \
            < /dev/null > "$LOG_DIR/mic.log" 2>&1 &
        echo $! > "$PID_MIC"
        sleep 1
        if ! is_running "$PID_MIC"; then
            err "scrcpy no arrancó correctamente. Revisa $LOG_DIR/mic.log"
            rm -f "$PID_MIC"
            exit 1
        fi

        # Los descriptores se redirigen (no se heredan) para que este trabajo en
        # segundo plano no mantenga abierto el pipe cuando start_mic se invoca
        # dentro de un "$(...)" (run_gui_action/run_agent_action): si no, la
        # sustitución de comandos no vuelve hasta que termina route_audio_to_mic
        # (hasta 15s), congelando el menú/agente en cada arranque del micrófono.
        ( route_audio_to_mic ) < /dev/null >> "$LOG_DIR/mic.log" 2>&1 &
        echo $! > "$PID_ROUTE"

        ok "Micrófono activo (PID $(cat "$PID_MIC")). Selecciona '$MIC_SOURCE_NAME' como entrada de audio."
        notify "Micrófono activo" "Selecciona '$MIC_SOURCE_NAME' en Discord/Zoom/Meet/Teams/OBS."
    ) 9>"$RUN_DIR/mic.lock"
}

# ---------- Modo: webcam + micrófono ----------
# Se intentan los dos aunque uno falle (son independientes: si la webcam ya
# estaba activa pero el micrófono no, "iniciar los dos" debe dejar el
# micrófono en marcha igualmente). OJO: el código de salida debe reflejar si
# CUALQUIERA de los dos falló. Antes esta función no tenía "return" propio,
# así que devolvía el código de salida del ÚLTIMO comando ejecutado
# (start_mic): si start_webcam fallaba pero start_mic tenía éxito, la
# función entera "parecía" haber ido bien y run_gui_action no mostraba
# ningún error pese a que la webcam nunca llegó a arrancar.
start_both() {
    local rc=0
    start_webcam || rc=1
    start_mic || rc=1
    return "$rc"
}

# ---------- Detener ----------
stop_all() {
    local stopped=0 rpid
    # PID_WEBCAM/PID_MIC se validan con is_running() (comprueba
    # /proc/PID/comm), igual que stop_webcam_only()/stop_mic_only(), para no
    # enviar señales a un proceso ajeno si el pidfile quedó huérfano con un
    # PID que el sistema ha reasignado mientras tanto a otra cosa.
    if is_running "$PID_WEBCAM"; then
        terminate_pid "$(cat "$PID_WEBCAM")"
        stopped=1
    fi
    rm -f "$PID_WEBCAM"

    if is_running "$PID_MIC"; then
        terminate_pid "$(cat "$PID_MIC")"
        stopped=1
    fi
    rm -f "$PID_MIC"

    if [ -f "$PID_ROUTE" ]; then
        rpid=$(cat "$PID_ROUTE" 2>/dev/null)
        if [ -n "$rpid" ] && kill -0 "$rpid" 2>/dev/null; then
            terminate_pid "$rpid"
            stopped=1
        fi
        rm -f "$PID_ROUTE"
    fi

    if [ "$stopped" -eq 1 ]; then
        ok "PhoneCam detenido."
        notify "PhoneCam detenido"
    else
        info "No había ningún proceso de PhoneCam activo."
    fi
}

# ---------- Detener solo webcam / solo micrófono ----------
# Permiten que el menú ofrezca "Detener webcam" o "Detener micrófono" de
# forma independiente cuando solo uno de los dos está activo.
stop_webcam_only() {
    if is_running "$PID_WEBCAM"; then
        terminate_pid "$(cat "$PID_WEBCAM")"
        rm -f "$PID_WEBCAM"
        ok "Webcam detenida."
        notify "Webcam detenida"
    else
        info "La webcam no estaba activa."
    fi
}

stop_mic_only() {
    local stopped=0 rpid
    if is_running "$PID_MIC"; then
        terminate_pid "$(cat "$PID_MIC")"
        rm -f "$PID_MIC"
        stopped=1
    fi
    if [ -f "$PID_ROUTE" ]; then
        rpid=$(cat "$PID_ROUTE" 2>/dev/null)
        [ -n "$rpid" ] && terminate_pid "$rpid"
        rm -f "$PID_ROUTE"
    fi
    if [ "$stopped" -eq 1 ]; then
        ok "Micrófono detenido."
        notify "Micrófono detenido"
    else
        info "El micrófono no estaba activo."
    fi
}

# ---------- Estado ----------
# Pensado para leerse igual de bien en terminal que dentro de un diálogo
# zenity --text-info (por eso no depende del color, solo de los iconos
# ✓ / ✗ / ⚠ / ℹ definidos arriba), y para decir siempre qué hacer a
# continuación cuando algo no está listo.
status() {
    hdr "PhoneCam — estado actual"
    echo

    hdr "📱 Conexión"
    if ! command -v adb >/dev/null 2>&1; then
        err "'adb' no está instalado."
        echo "     → Ejecuta '$(basename "$SELF_PATH") install' para instalarlo."
    else
        # "timeout": mismo motivo que en adb_serial()/phone_status_short() — un
        # adb colgado no debe poder congelar "Ver estado detallado" en el menú
        # gráfico (aquí, además, se llama una sola vez y se reutiliza la salida,
        # en vez de invocar "adb devices" dos veces seguidas).
        local adb_out
        adb_out=$(timeout 10 adb devices 2>/dev/null)
        if printf '%s\n' "$adb_out" | awk 'NR>1 && $2=="device"' | grep -q .; then
            ok "Teléfono conectado por ADB:"
            printf '%s\n' "$adb_out" | awk 'NR>1 && $2=="device" {print "     - "$1}'
        else
            warn "Ningún teléfono autorizado detectado."
            echo "     → Conéctalo por USB, activa 'Depuración USB' en Opciones de"
            echo "       desarrollador y acepta el aviso de autorización del teléfono."
        fi
    fi
    echo

    hdr "🎥 Captura"
    if is_running "$PID_WEBCAM"; then
        ok "Webcam ACTIVA (PID $(cat "$PID_WEBCAM")) → $V4L2_DEVICE"
    else
        info "Webcam inactiva."
    fi
    if is_running "$PID_MIC"; then
        ok "Micrófono ACTIVO (PID $(cat "$PID_MIC")) → $MIC_SOURCE_NAME"
    else
        info "Micrófono inactivo."
    fi
    echo

    hdr "🧩 Dispositivos virtuales"
    if [ -e "$V4L2_DEVICE" ]; then
        ok "Webcam virtual $V4L2_DEVICE presente."
    else
        warn "Webcam virtual $V4L2_DEVICE no existe todavía."
        echo "     → Prueba 'sudo modprobe v4l2loopback' o repite la instalación."
    fi
    if ! command -v pactl >/dev/null 2>&1; then
        err "'pactl' no está instalado (paquete pulseaudio-utils)."
        echo "     → Ejecuta '$(basename "$SELF_PATH") install' para instalarlo."
    elif pactl list short sources 2>/dev/null | grep -qw "$MIC_SOURCE_NAME"; then
        ok "Micrófono virtual '$MIC_SOURCE_NAME' presente."
    else
        info "Micrófono virtual '$MIC_SOURCE_NAME' aún no creado (se crea al usar el micrófono por primera vez)."
    fi
}

# ---------- Listar / elegir cámara del teléfono ----------
# Líneas "--camera-id=N  (detalle)" reportadas por el teléfono. El "INFO:"
# de scrcpy solo aparece una vez, en la cabecera "List of cameras:", que no
# contiene "--camera-id" y por tanto ya queda fuera del grep. Compartida por
# list_cameras() y choose_camera_gui() para no duplicar el parseo.
phone_camera_list() {
    scrcpy -s "$1" --list-cameras 2>&1 | grep -- '--camera-id'
}

list_cameras() {
    require_tools || return 1
    local serial; serial=$(adb_serial) || return 1
    local raw; raw=$(phone_camera_list "$serial")
    if [ -z "$raw" ]; then
        err "No se pudo obtener la lista de cámaras del teléfono."
        return 1
    fi
    printf '%s\n' "$raw"
}

choose_camera_gui() {
    require_tools || return 1
    local serial; serial=$(adb_serial) || return 1
    info "Consultando cámaras disponibles (puede tardar unos segundos)..."
    local raw; raw=$(phone_camera_list "$serial")
    if [ -z "$raw" ]; then
        err "No se pudo obtener la lista de cámaras."
        return 1
    fi

    if command -v zenity >/dev/null 2>&1; then
        # Primera fila: permite volver a la selección automática por
        # CAMERA_FACING y limpiar un CAMERA_ID fijado antes (si no, una vez
        # elegida una cámara concreta no había forma de deshacerlo desde el menú).
        local rows=("(auto)" "Automática: usa 'Cámara (facing)' de Configuración") line id desc
        while IFS= read -r line; do
            id=$(echo "$line" | grep -oE 'camera-id=[0-9]+' | cut -d= -f2)
            desc=$(echo "$line" | sed -E 's/--camera-id=[0-9]+ *//')
            rows+=("$id" "$desc")
        done <<< "$raw"
        local chosen
        chosen=$(zenity --list --title="Elegir cámara" --window-icon="camera-web" \
            --width=560 --height=320 \
            --text="📷  Cámaras detectadas en el teléfono.\nElige la que se usará como webcam (se guarda como predeterminada):" \
            --column="ID" --column="Detalle" "${rows[@]}" 2>/dev/null)
        if [ "$chosen" = "(auto)" ]; then
            set_config CAMERA_ID "" && {
                ok "Se usará la cámara automática (según 'Cámara (facing)')."
                notify "Cámara" "Se usará la selección automática por 'facing'."
            }
        elif [ -n "$chosen" ]; then
            set_config CAMERA_ID "$chosen" && {
                ok "Cámara $chosen guardada como predeterminada."
                notify "Cámara guardada" "Se usará por defecto la próxima vez que inicies la webcam."
            }
        fi
    else
        local chosen
        echo "$raw"
        read -rp "ID de cámara a usar ('auto' = automática, vacío = no cambiar): " chosen
        if [ -z "$chosen" ]; then
            :
        elif [ "$chosen" = "auto" ]; then
            set_config CAMERA_ID "" && ok "Se usará la cámara automática (según 'Cámara (facing)')."
        elif [[ ! "$chosen" =~ ^[0-9]+$ ]]; then
            err "ID de cámara no válido: debe ser un número (mira la lista de arriba) o 'auto'."
        else
            set_config CAMERA_ID "$chosen" && ok "Cámara $chosen guardada como predeterminada."
        fi
    fi
}

# ---------- Editar configuración ----------
set_config() {
    local key="$1" value="$2" escaped comment=""
    # Se guarda entre comillas simples: así el valor se reconstruye tal cual
    # al hacer "source" (sin interpretar $, comillas dobles ni backticks) y
    # solo hace falta escapar las comillas simples que pudiera contener,
    # con el truco estándar de bash: cerrar comilla, comilla literal, reabrir.
    escaped="${value//\'/\'\\\'\'}"
    if grep -q "^${key}=" "$CONF_FILE" 2>/dev/null; then
        # Si la línea que se va a sustituir tenía un comentario al final
        # (p.ej. 'CAMERA_FACING="back"   # back | front | external'), se
        # conserva y se reengancha a la nueva línea: sin esto, guardar un
        # valor desde el formulario gráfico borraba silenciosamente la
        # documentación inline de esa clave en phonecam.conf. Heurística:
        # se toma como comentario el primer '#' precedido de un espacio, lo
        # que asume que el valor en sí no contiene "espacio + #" (cierto
        # para todos los valores que genera este script).
        local old_line
        old_line=$(grep "^${key}=" "$CONF_FILE" | head -1)
        [[ "$old_line" =~ [[:space:]](#.*)$ ]] && comment="  ${BASH_REMATCH[1]}"

        local tmp
        tmp="$(mktemp "${CONF_FILE}.XXXXXX")" || { err "No se pudo crear un archivo temporal para guardar la configuración."; return 1; }
        if ! { awk -v k="$key" -v line="${key}='${escaped}'${comment}" \
            '$0 ~ ("^" k "=") { print line; next } { print }' \
            "$CONF_FILE" > "$tmp" && mv "$tmp" "$CONF_FILE"; }; then
            rm -f "$tmp"
            err "No se pudo guardar '$key' en $CONF_FILE."
            return 1
        fi
    else
        printf '%s\n' "${key}='${escaped}'" >> "$CONF_FILE" || { err "No se pudo guardar '$key' en $CONF_FILE."; return 1; }
    fi
    # Refleja el cambio también en la variable de este mismo proceso: sin esto,
    # set_config solo tocaba el .conf en disco y una sesión ya abierta (el menú
    # interactivo, o el agente en segundo plano) seguía usando el valor viejo
    # cargado al arrancar, hasta cerrarla/reiniciarla.
    printf -v "$key" '%s' "$value"
}

edit_config() {
    # NOTA: esta función es ahora el ÚLTIMO recurso, solo para cuando ni
    # siquiera hay "zenity" instalado (ver open_config_editor()/
    # advanced_settings_gui() más abajo, que son la vía normal: un
    # formulario gráfico que se abre siempre en el acto). Se deja aquí
    # porque sigue siendo útil para quien prefiera editar el archivo de
    # texto a mano.
    #
    # Si hay una terminal real y $VISUAL/$EDITOR definidos, se respetan.
    # (Pueden incluir argumentos, p.ej. "code --wait" o "vim -u NONE", por
    # eso se trocean en un array en vez de tratarlos como un único ejecutable.)
    if [ -t 0 ] && [ -n "${VISUAL:-}${EDITOR:-}" ]; then
        local editor_cmd="${VISUAL:-$EDITOR}"
        local -a editor_arr
        read -ra editor_arr <<< "$editor_cmd"
        if [ "${#editor_arr[@]}" -gt 0 ] && command -v "${editor_arr[0]}" >/dev/null 2>&1; then
            "${editor_arr[@]}" "$CONF_FILE"
            return
        fi
    fi

    # Sin terminal (p.ej. lanzado desde el menú gráfico o la bandeja) o sin
    # $EDITOR definido: se prueba con editores gráficos habituales en
    # Cinnamon/Mint, y si no hay ninguno, con el abridor de archivos por
    # defecto del sistema.
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
        # Último recurso: sin terminal, sin editor gráfico y sin xdg-open,
        # un simple "echo" no lo vería nadie (mismo motivo que run_gui_action
        # más abajo). Muy improbable en Mint/Cinnamon (trae "xed" de serie),
        # pero si pasa, al menos que quede una notificación con la ruta.
        echo "Edita manualmente: $CONF_FILE"
        notify "PhoneCam" "No se encontró ningún editor. Edita manualmente: $CONF_FILE"
    fi
}

# Reordena una lista de opciones para que el valor actual aparezca primero
# (zenity preselecciona siempre el primer valor de un --combo-values). Si el
# valor actual no está entre las opciones válidas, se antepone igualmente en
# vez de perderlo en silencio: así el formulario nunca "corrige" a la fuerza
# un valor que el usuario haya puesto a mano en el .conf.
combo_with_current() {
    local current="$1"; shift
    local out="$current" opt
    for opt in "$@"; do
        [ "$opt" = "$current" ] && continue
        out="$out|$opt"
    done
    printf '%s' "$out"
}

# ---------- Configuración avanzada: formulario gráfico ----------
# Formulario zenity propio (en vez de delegar en edit_config/un editor
# externo): se dibuja siempre en el acto, sin depender de qué editor de
# texto haya instalado ni de si el proceso tiene una terminal detrás.
advanced_settings_gui() {
    if ! command -v zenity >/dev/null 2>&1; then
        edit_config
        return
    fi

    local result rc
    result=$(zenity --forms --title="PhoneCam — Configuración avanzada" \
        --window-icon="camera-web" --width=560 \
        --text="Ajusta lo que necesites y pulsa Aceptar para guardarlo en $CONF_FILE.\nDeja un campo de texto vacío para no tocar ese valor.\nTambién puedes seguir editando ese archivo a mano si lo prefieres." \
        --separator="|" \
        --add-combo="Cámara (facing)$([ -n "$CAMERA_ID" ] && echo " [ignorado: hay cámara fija #$CAMERA_ID; usa 'Elegir cámara' -> '(auto)' para quitarla]")" \
        --combo-values="$(combo_with_current "$CAMERA_FACING" back front external)" \
        --add-entry="Resolución de cámara (vacío = no tocar; 'max' = máxima; ej. 1920x1080; actual: ${CAMERA_SIZE:-máxima})" \
        --add-entry="FPS de cámara (actual: $CAMERA_FPS)" \
        --add-combo="Perfil de calidad de vídeo" \
        --combo-values="$(combo_with_current "$VIDEO_QUALITY_PROFILE" balanced max)" \
        --add-combo="Fuente de audio" \
        --combo-values="$(combo_with_current "$AUDIO_SOURCE" mic mic-unprocessed mic-voice-communication mic-camcorder)" \
        --add-combo="Códec de audio" \
        --combo-values="$(combo_with_current "$AUDIO_CODEC" opus aac flac raw)" \
        --add-entry="Bitrate de audio (actual: $AUDIO_BITRATE)" \
        --add-combo="Modo automático al conectar el móvil" \
        --combo-values="$(combo_with_current "$AUTO_MODE" ask webcam mic both off)" \
        --add-combo="Apagar pantalla del móvil al iniciar" \
        --combo-values="$(combo_with_current "$TURN_SCREEN_OFF" false true)" \
        --add-combo="Mantener el móvil despierto" \
        --combo-values="$(combo_with_current "$KEEP_AWAKE" true false)" \
        2>/dev/null)
    rc=$?

    # Cancelado o ventana cerrada: zenity no imprime nada y devuelve un
    # código distinto de 0. No es un error, simplemente no hay nada que
    # guardar.
    if [ "$rc" -ne 0 ] || [ -z "$result" ]; then
        return 0
    fi

    # Se parte a un array (no a variables sueltas con "read -r v1 v2 ..."):
    # si algún campo de texto libre (Resolución/FPS/Bitrate) contiene un '|'
    # literal (p.ej. pegado de otro sitio), un "read" con variables fijas
    # absorbería ese '|' de más y desplazaría en cascada TODOS los campos
    # siguientes sin dar ningún error (p.ej. el valor de "Modo automático"
    # se colaría en TURN_SCREEN_OFF, y KEEP_AWAKE terminaría guardado con un
    # '|' dentro) porque validate_advanced_fields solo revisa formato de
    # tres campos, no si el resto ha cuadrado. Con el array, un '|' de más
    # da un array de 11+ elementos en vez de 10, y lo detectamos aquí antes
    # de asignar nada.
    # El centinela final evita que "IFS='|' read -a" descarte un último
    # campo vacío (comportamiento real de bash: se comprobó en pruebas).
    local -a f
    IFS='|' read -r -a f <<< "${result}|__END__"
    if [ "${#f[@]}" -ne 11 ] || [ "${f[-1]}" != "__END__" ]; then
        err "Configuración no guardada: algún campo contiene el carácter '|', que es el separador interno del formulario."
        zenity --error --title="PhoneCam" --window-icon="camera-web" --width=460 \
            --text="No se ha guardado nada: algún campo contiene el carácter '|' (usado internamente como separador), lo que descuadra el resto de los campos.\n\nQuítalo y vuelve a intentarlo." 2>/dev/null
        return 1
    fi
    local f_facing="${f[0]}" f_size="${f[1]}" f_fps="${f[2]}" f_profile="${f[3]}" f_asource="${f[4]}" f_codec="${f[5]}" f_abitrate="${f[6]}" f_auto="${f[7]}" f_screenoff="${f[8]}" f_awake="${f[9]}"

    local -a field_errors=()
    mapfile -t field_errors < <(validate_advanced_fields "$f_size" "$f_fps" "$f_abitrate")
    if [ "${#field_errors[@]}" -gt 0 ]; then
        local msg; msg=$(printf '%s\n' "${field_errors[@]}")
        err "Configuración no guardada: hay valores con formato incorrecto."
        zenity --error --title="PhoneCam" --window-icon="camera-web" --width=460 \
            --text="No se ha guardado nada. Corrige estos campos y vuelve a intentarlo:\n\n$msg" 2>/dev/null
        return 1
    fi

    # save_ok rastrea si TODOS los set_config han ido bien: sin esto, si uno
    # fallaba (p.ej. disco lleno) su propio err() ya avisaba, pero a
    # continuación se imprimía igualmente "Configuración guardada", un
    # mensaje contradictorio justo debajo del error.
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
        ok "Configuración guardada en $CONF_FILE."
        notify "PhoneCam" "Configuración avanzada actualizada."
    else
        warn "Algunos valores no se han podido guardar; revisa los mensajes de arriba."
    fi
}

# Valida los campos con formato libre del formulario avanzado antes de
# guardarlos: sin esto, un valor mal escrito (p.ej. "1920-1080" o "30fps")
# se guardaba tal cual y el error solo aparecía después, al fallar scrcpy con
# un mensaje críptico. Vacío es válido en los tres campos (no se valida).
validate_advanced_fields() {
    local size="$1" fps="$2" abitrate="$3" errors=()
    [ -n "$size" ] && [ "$size" != "max" ] && [[ ! "$size" =~ ^[0-9]+x[0-9]+$ ]] && errors+=("Resolución: usa el formato ANCHOxALTO (ej. 1920x1080) o 'max'.")
    [ -n "$fps" ] && [[ ! "$fps" =~ ^[0-9]+$ ]] && errors+=("FPS de cámara: debe ser un número entero.")
    [ -n "$abitrate" ] && [[ ! "$abitrate" =~ ^[0-9]+[KkMm]$ ]] && errors+=("Bitrate de audio: un número seguido de K o M, ej. 192K.")
    # Con el array vacío, "printf ... "${errors[@]}"" igualmente imprime una
    # línea en blanco (comportamiento de printf, no bug de bash): sin este
    # guard, el formulario creía que SIEMPRE había un error y nunca guardaba.
    [ "${#errors[@]}" -gt 0 ] && printf '%s\n' "${errors[@]}"
    return 0
}

# Punto de entrada único para "editar configuración" (usado por el menú
# gráfico, por "phonecam config" y por el icono de bandeja): prioriza el
# formulario gráfico, siempre visible e inmediato, y solo recurre al editor
# de texto externo si zenity no está instalado en absoluto.
open_config_editor() {
    if command -v zenity >/dev/null 2>&1; then
        advanced_settings_gui
    else
        edit_config
    fi
}

# ---------- Ayuda: cómo conectar el teléfono ----------
# Texto reutilizado por el menú gráfico, el menú de texto y el comando
# "phonecam ayuda", para que la guía sea siempre la misma.
CONNECTION_HELP_TEXT="1) En el teléfono: Ajustes → Acerca del teléfono → toca 7 veces sobre\n   'Número de compilación' para activar Opciones de desarrollador.\n2) Entra en Opciones de desarrollador y activa 'Depuración USB'.\n3) Conecta el teléfono al PC con un cable USB de datos (no solo de carga).\n4) Acepta en el teléfono el aviso 'Permitir depuración USB' y marca\n   'Recordar en este equipo' para no repetirlo cada vez.\n5) Vuelve aquí y elige 'Iniciar solo webcam', 'Iniciar solo micrófono' o\n   'Iniciar webcam + micrófono'."

show_connection_help() {
    if command -v zenity >/dev/null 2>&1; then
        zenity --info --title="Cómo conectar el teléfono" --window-icon="camera-web" \
            --width=480 --text="$CONNECTION_HELP_TEXT" 2>/dev/null
    else
        echo
        echo -e "$CONNECTION_HELP_TEXT"
        echo
    fi
}

# Cadena corta de una palabra para la cabecera del menú. No bloqueante del
# todo: usa "timeout" por si adb tarda en arrancar el servidor la primera vez
# (en ese caso, basta con volver a abrir el menú una vez arrancado).
phone_status_short() {
    if timeout 5 adb devices 2>/dev/null | awk 'NR>1 && $2=="device"' | grep -q .; then
        echo "conectado"
    else
        echo "no detectado"
    fi
}

# Ejecuta una acción del menú gráfico y, si falla, muestra la salida en un
# zenity --error (sin esto, lanzado sin terminal visible, un fallo se
# imprimiría con err()/warn() en un sitio que nadie ve). Los éxitos no se
# muestran aquí porque cada función ya los notifica con notify-send.
run_gui_action() {
    local out rc
    out=$("$@" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] && [ -n "$out" ]; then
        zenity --error --title="PhoneCam" --window-icon="camera-web" --width=480 \
            --text="$out" 2>/dev/null
    fi
    return "$rc"
}

# ---------- Menú gráfico (zenity) / texto ----------
# El menú es "consciente del estado": el texto de cada fila cambia según si
# la webcam/el micrófono ya están activos, y siempre indica qué necesita el
# usuario antes de pulsar (para que el siguiente paso sea obvio).
gui_menu() {
    if ! command -v zenity >/dev/null 2>&1; then
        cli_menu
        return
    fi

    # "adb" sí requiere la instalación completa (paquete del sistema, grupos
    # de usuario, etc.), así que aquí se sigue remitiendo a "install". scrcpy,
    # en cambio, ahora se resuelve solo (ver ensure_scrcpy_installed): si
    # falta o está desactualizado, se ofrece descargarlo automáticamente en
    # vez de cerrar el menú con un error.
    if ! command -v adb >/dev/null 2>&1; then
        zenity --error --title="PhoneCam" --window-icon="camera-web" --width=440 \
            --text="Falta la herramienta 'adb'.\n\nAbre una terminal y ejecuta:\n<tt>$(basename "$SELF_PATH") install</tt>" \
            2>/dev/null
        return 1
    fi

    if ! ensure_scrcpy_installed; then
        zenity --error --title="PhoneCam" --window-icon="camera-web" --width=460 \
            --text="No se pudo preparar 'scrcpy' automáticamente.\n\nInstálalo manualmente y vuelve a abrir PhoneCam:\nhttps://github.com/Genymobile/scrcpy/blob/master/doc/linux.md" \
            2>/dev/null
        return 1
    fi

    # Bucle principal: tras ejecutar cualquier acción (incluidas las que solo
    # muestran información, como la ayuda de conexión o la configuración
    # avanzada) se vuelve a mostrar este mismo menú, en vez de terminar el
    # script. Solo se sale eligiendo "Salir" o cerrando la ventana del menú.
    while true; do
        local phone webcam_on=0 mic_on=0 phone_icon="✗" phone_txt="no detectado"
        phone=$(phone_status_short)
        is_running "$PID_WEBCAM" && webcam_on=1
        is_running "$PID_MIC" && mic_on=1
        if [ "$phone" = "conectado" ]; then
            phone_icon="✓"; phone_txt="conectado"
        fi

        local header
        header="<b>Móvil como webcam / micrófono</b>\n"
        header+="📱 Teléfono: ${phone_icon} ${phone_txt}    🎥 Webcam: $([ "$webcam_on" -eq 1 ] && echo "✓ activa" || echo "inactiva")    🎙️ Micrófono: $([ "$mic_on" -eq 1 ] && echo "✓ activo" || echo "inactivo")"

        # Filas: clave-oculta | Acción (con icono) | Qué hace / qué necesita antes
        local rows=()

        if [ "$webcam_on" -eq 1 ]; then
            rows+=("webcam_stop" "⏹  Detener webcam" "Ya está activa: la desconecta y libera la cámara")
        else
            rows+=("webcam_start" "▶  Iniciar solo webcam" "Necesita el móvil por USB con Depuración USB activada")
        fi

        if [ "$mic_on" -eq 1 ]; then
            rows+=("mic_stop" "⏹  Detener micrófono" "Ya está activo: libera el micrófono virtual")
        else
            rows+=("mic_start" "▶  Iniciar solo micrófono" "Necesita el móvil por USB con Depuración USB activada")
        fi

        if [ "$webcam_on" -eq 0 ] || [ "$mic_on" -eq 0 ]; then
            rows+=("both_start" "▶▶  Iniciar webcam + micrófono" "Arranca los dos a la vez en un solo paso")
        fi

        if [ "$webcam_on" -eq 1 ] || [ "$mic_on" -eq 1 ]; then
            rows+=("stop_all" "⏹⏹  Detener todo" "Corta la webcam y el micrófono si están activos")
        fi

        rows+=("choose_cam" "🎯  Elegir cámara" "Útil si el teléfono tiene varias (requiere conexión)")
        rows+=("status" "📊  Ver estado detallado" "Conexión, procesos activos y dispositivos virtuales")
        rows+=("config" "⚙️  Configuración avanzada" "Formulario: calidad de vídeo, códec de audio, modo automático...")
        rows+=("help" "❓  Cómo conectar el teléfono" "Guía rápida paso a paso (recomendado la primera vez)")
        rows+=("exit" "🚪  Salir" "Cierra este menú")

        local choice
        choice=$(zenity --list --title="PhoneCam" --window-icon="camera-web" \
            --width=720 --height=460 \
            --text="$header" \
            --column="clave" --column="Acción" --column="Qué hace / qué necesitas" \
            --hide-column=1 --print-column=1 \
            "${rows[@]}" 2>/dev/null)

        case "$choice" in
            webcam_start) run_gui_action start_webcam ;;
            webcam_stop)  run_gui_action stop_webcam_only ;;
            mic_start)    run_gui_action start_mic ;;
            mic_stop)     run_gui_action stop_mic_only ;;
            both_start)   run_gui_action start_both ;;
            stop_all)     run_gui_action stop_all ;;
            choose_cam)   run_gui_action choose_camera_gui ;;
            status)       status | zenity --text-info --title="Estado de PhoneCam" --window-icon="camera-web" --width=560 --height=440 2>/dev/null ;;
            config)       run_gui_action advanced_settings_gui ;;
            help)         show_connection_help ;;
            exit|"")      break ;;
            *) : ;;
        esac
    done
}

cli_menu() {
    # Sin entrada interactiva (p.ej. lanzado sin terminal y sin zenity
    # instalado) el "select" de abajo no podría leer nunca una opción real:
    # en vez de entrar en un bucle imposible, se informa y se sale.
    if [ ! -t 0 ]; then
        status
        echo
        warn "No hay una terminal interactiva disponible y 'zenity' no está instalado."
        warn "Ejecuta '$(basename "$SELF_PATH") menu' desde una terminal, o instala zenity."
        return 1
    fi

    # Bucle principal: tras cada acción se recalcula el estado y se vuelve a
    # mostrar el menú, en vez de terminar el script. Solo "Salir" termina.
    while true; do
        local webcam_on=0 mic_on=0
        is_running "$PID_WEBCAM" && webcam_on=1
        is_running "$PID_MIC" && mic_on=1

        echo
        status
        echo

        local opt_webcam="Iniciar solo webcam  (necesita teléfono con Depuración USB activada)"
        [ "$webcam_on" -eq 1 ] && opt_webcam="Detener webcam  (activa)"

        local opt_mic="Iniciar solo micrófono  (necesita teléfono con Depuración USB activada)"
        [ "$mic_on" -eq 1 ] && opt_mic="Detener micrófono  (activo)"

        echo "PhoneCam - elige una opción:"
        local opt
        select opt in \
            "$opt_webcam" \
            "$opt_mic" \
            "Iniciar webcam + micrófono" \
            "Elegir cámara  (si el teléfono tiene varias)" \
            "Ver estado detallado" \
            "Detener todo" \
            "Cómo conectar el teléfono  (ayuda)" \
            "Salir"; do
            case "$opt" in
                "$opt_webcam")
                    if [ "$webcam_on" -eq 1 ]; then stop_webcam_only; else start_webcam; fi
                    break ;;
                "$opt_mic")
                    if [ "$mic_on" -eq 1 ]; then stop_mic_only; else start_mic; fi
                    break ;;
                "Iniciar webcam + micrófono") start_both; break ;;
                "Elegir cámara"*) choose_camera_gui; break ;;
                # El estado ya se muestra siempre al principio de cada vuelta
                # del bucle (arriba); aquí solo hace falta volver a dibujar
                # el menú, para no imprimirlo dos veces seguidas.
                "Ver estado detallado") break ;;
                "Detener todo") stop_all; break ;;
                "Cómo conectar el teléfono"*) show_connection_help; break ;;
                "Salir") return 0 ;;
                *) echo "Opción no válida, elige un número de la lista."; break ;;
            esac
        done
    done
}

# =============================================================================
#  Agente en segundo plano (systemd --user). Se lanza con: phonecam agent
#   1) Detecta la conexión/desconexión del teléfono por USB (polling ADB local,
#      sin red) y arranca/detiene la captura según AUTO_MODE.
#   2) Si hay "yad" instalado, muestra un icono en la bandeja del sistema con
#      acceso rápido a los modos.
# =============================================================================
# Igual que run_gui_action, pero para el agente en segundo plano: aquí no
# tiene sentido abrir un zenity --error desde un proceso que el usuario no ha
# invocado a propósito (aparecería una ventana "de la nada"), así que el
# fallo se informa con una notificación de escritorio en vez de un diálogo.
# Sin esto, "Teléfono detectado. Iniciando webcam..." podía quedar como
# promesa incumplida y silenciosa si algo fallaba justo después (v4l2 no
# disponible, etc.): el agente no volvía a decir nada.
run_agent_action() {
    local out rc
    out=$("$@" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] && [ -n "$out" ]; then
        notify "PhoneCam" "$out"
    fi
    return "$rc"
}

agent_current_device() {
    # "timeout": este poll se repite cada 2s para siempre (agent_watcher_loop).
    # Sin protegerlo, un adb colgado no fallaría una sola vez: congelaría la
    # detección automática por USB indefinidamente, sin ningún error visible
    # (el agente corre sin terminal), hasta reiniciar el servicio a mano.
    timeout 10 adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1; exit}'
}

agent_handle_new_device() {
    local serial="$1"
    case "$AUTO_MODE" in
        webcam) notify "PhoneCam" "Teléfono detectado. Iniciando webcam..."; run_agent_action start_webcam ;;
        mic)    notify "PhoneCam" "Teléfono detectado. Iniciando micrófono..."; run_agent_action start_mic ;;
        both)   notify "PhoneCam" "Teléfono detectado. Iniciando webcam + micrófono..."; run_agent_action start_both ;;
        off)    : ;;
        ask|*)
            if command -v zenity >/dev/null 2>&1; then
                (
                  flock -n 9 || exit 0
                  local choice
                  choice=$(zenity --list --title="Teléfono conectado" --window-icon="camera-web" \
                      --width=420 --height=280 \
                      --text="📱  Teléfono detectado ($serial).\n¿Qué quieres iniciar ahora?" \
                      --column="Modo" \
                      "🎥  Solo webcam" "🎙️  Solo micrófono" "🎥🎙️  Webcam + micrófono" "No hacer nada" \
                      2>/dev/null)
                  case "$choice" in
                      "🎥  Solo webcam") run_agent_action start_webcam ;;
                      "🎙️  Solo micrófono") run_agent_action start_mic ;;
                      "🎥🎙️  Webcam + micrófono") run_agent_action start_both ;;
                      *) : ;;
                  esac
                ) 9>"$RUN_DIR/ask.lock" &
            else
                notify "Teléfono conectado" "Ejecuta 'phonecam menu' para elegir un modo."
            fi
            ;;
    esac
}

agent_handle_removed_device() {
    if is_running "$PID_WEBCAM" || is_running "$PID_MIC"; then
        notify "PhoneCam" "Teléfono desconectado. Deteniendo captura..."
    fi
    stop_all >/dev/null 2>&1
}

agent_watcher_loop() {
    local last="" dev
    while true; do
        dev=$(agent_current_device)
        if [ "$dev" != "$last" ]; then
            # Si había un dispositivo previo, se suelta primero su captura
            # tanto si ahora no hay ninguno (desconexión simple) como si ha
            # aparecido directamente OTRO serial distinto (cambio de teléfono
            # sin pasar por un hueco "ninguno" entre medias): en ambos casos
            # la webcam/mic en marcha seguían apuntando al ADB serial
            # anterior. Antes solo se comprobaba "dev vacío", así que un
            # cambio directo de teléfono se trataba como "dispositivo nuevo"
            # sin parar antes la captura del que se acababa de ir.
            [ -n "$last" ] && agent_handle_removed_device
            if [ -n "$dev" ]; then
                # El agente carga phonecam.conf una sola vez al arrancar (en
                # main(), antes de llamar a run_agent) y luego vive para
                # siempre como servicio systemd --user; sin recargarlo aquí,
                # un cambio hecho con 'phonecam config' o 'choose-cam' desde
                # otra terminal (AUTO_MODE, cámara, audio...) quedaría
                # invisible para el agente hasta reiniciar el servicio. Se
                # recarga justo antes de reaccionar a la conexión, no en cada
                # vuelta del bucle, para no repetir el "source" cada 2s sin
                # motivo.
                load_config
                agent_handle_new_device "$dev"
            fi
        fi
        last="$dev"
        sleep 2
    done
}

# NOTA: el separador por defecto entre elementos del menú de yad es "|", pero
# uno de nuestros comandos necesita un pipe real ("status | yad ..."). Por eso
# se redefine el separador a ";;" con --separator para no chocar.
agent_tray_icon() {
    command -v yad >/dev/null 2>&1 || return 0
    local self="$INSTALLED_BIN"
    [ -x "$self" ] || self="$SELF_PATH"
    local menu
    menu="🎛️  Abrir menú completo!bash -c '\"$self\" menu'"
    menu+=";;🎥  Solo webcam!bash -c '\"$self\" webcam'"
    menu+=";;🎙️  Solo micrófono!bash -c '\"$self\" mic'"
    menu+=";;🎥🎙️  Webcam + micrófono!bash -c '\"$self\" both'"
    menu+=";;📊  Ver estado!bash -c '\"$self\" status | yad --text-info --width=480 --height=360'"
    menu+=";;⏹  Detener todo!bash -c '\"$self\" stop'"
    menu+=";;⚙️  Configuración!bash -c '\"$self\" config'"
    # "Salir" debe detener el agente de verdad, no solo el icono: se pide a
    # systemd que lo pare (Restart=on-failure no reiniciará una parada así,
    # a diferencia de matar el proceso directamente). Si no está gestionado
    # por systemd (p.ej. lanzado a mano para pruebas), el kill de respaldo
    # usa el PID que run_agent() guarda en PID_AGENT.
    menu+=";;Salir!bash -c 'systemctl --user stop phonecam-agent.service 2>/dev/null || kill \"\$(cat \"$PID_AGENT\" 2>/dev/null)\" 2>/dev/null'"

    yad --notification \
        --image="camera-web" \
        --text="PhoneCam" \
        --separator=";;" \
        --menu="$menu" \
        --no-middle &
}

run_agent() {
    # "$BASHPID", no "$$": "$$" conserva el PID del shell padre si este
    # proceso se lanzara en segundo plano con "&" (p.ej. "phonecam agent &"
    # a mano en vez de vía systemd), dejando en PID_AGENT un PID ajeno que
    # el "Salir" del icono de bandeja mataría por error. "$BASHPID" siempre
    # es el PID real del proceso actual, se ejecute como se ejecute.
    echo "$BASHPID" > "$PID_AGENT" 2>/dev/null
    agent_tray_icon
    agent_watcher_loop
}

# =============================================================================
#  Instalación
# =============================================================================
write_default_config() {
    local v4l2_nr="$1"
    cat > "$CONF_FILE" <<EOF
# =============================================================
#  PhoneCam - configuración
#  Puedes editar este archivo a mano o con: phonecam config
# =============================================================

# ---------- Selección de cámara ----------
# CAMERA_ID vacío = se usa CAMERA_FACING para elegir automáticamente.
# Si eliges una cámara concreta desde el menú ("Elegir cámara"), su
# --camera-id se guarda aquí y tiene prioridad sobre CAMERA_FACING.
CAMERA_ID=""
CAMERA_FACING="back"        # back | front | external
CAMERA_SIZE=""              # vacío = resolución máxima declarada por el teléfono
CAMERA_FPS="30"

# ---------- Perfil de calidad de vídeo ----------
# balanced -> H.264, bitrate alto, mínima latencia (recomendado para videollamadas)
# max      -> H.265, mayor bitrate, mejor calidad, algo más de latencia de decodificación
VIDEO_QUALITY_PROFILE="balanced"
VIDEO_BITRATE_BALANCED="20M"
VIDEO_BITRATE_MAX="30M"

# ---------- Audio (micrófono del teléfono) ----------
AUDIO_CODEC="opus"          # opus | aac | flac | raw
AUDIO_BITRATE="192K"
AUDIO_SOURCE="mic"          # mic | mic-unprocessed | mic-voice-communication | mic-camcorder

# ---------- Dispositivo de vídeo virtual (v4l2loopback) ----------
V4L2_DEVICE="/dev/video${v4l2_nr}"

# ---------- Dispositivos de audio virtuales (PipeWire / PulseAudio) ----------
MIC_SINK_NAME="PhoneMicSink"
MIC_SOURCE_NAME="PhoneMic"

# ---------- Autoarranque al conectar el USB ----------
# ask    -> al detectar el teléfono, abre un menú preguntando el modo
# webcam / mic / both -> arranca ese modo automáticamente sin preguntar
# off    -> no hace nada automático (solo uso manual con "phonecam")
AUTO_MODE="ask"

# ---------- Comportamiento del teléfono mientras está en uso ----------
TURN_SCREEN_OFF="false"     # apaga la pantalla del móvil al iniciar la captura
KEEP_AWAKE="true"           # evita que el móvil se bloquee mientras esté conectado
EOF
}

cmd_install() {
    if [ "$EUID" -eq 0 ]; then
        err "No ejecutes este instalador como root. Se pedirá 'sudo' solo cuando haga falta."
        exit 1
    fi

    echo "=============================================="
    echo "   PhoneCam - instalador (móvil como webcam/mic)"
    echo "=============================================="
    echo
    if ! command -v apt >/dev/null 2>&1; then
        err "Este instalador usa 'apt' y no está disponible en este sistema."
        err "PhoneCam está pensado para Linux Mint / Ubuntu / Debian. En otras"
        err "distribuciones instala las dependencias a mano (adb, v4l2loopback,"
        err "pipewire, zenity, scrcpy >= 2.2) y ejecuta este script con 'source'"
        err "para saltarte el instalador, o adapta esta sección a tu gestor de paquetes."
        exit 1
    fi

    ask_yn "¿Instalar dependencias del sistema y configurar PhoneCam ahora?" y || {
        info "Instalación cancelada."
        exit 0
    }

    # ---------- 1. Paquetes del sistema ----------
    info "Instalando dependencias del sistema (se pedirá contraseña de sudo)..."
    if ! sudo apt update -y; then
        err "No se pudo ejecutar 'apt update'. Revisa tu conexión de red o los repositorios."
        err "Instalación abortada."
        exit 1
    fi

    # "scrcpy" NO se instala vía apt: en Ubuntu/Mint el paquete del repositorio
    # suele quedarse en la serie 1.x, muy por debajo de la 2.2 que necesita el
    # modo cámara. Se instala aparte (ver más abajo) desde el build oficial.
    local pkgs="curl v4l2loopback-dkms v4l-utils pipewire pipewire-pulse wireplumber pulseaudio-utils zenity yad libnotify-bin"

    # El paquete de adb cambia de nombre según la versión de repositorio.
    if apt-cache show adb >/dev/null 2>&1; then
        pkgs="$pkgs adb"
    else
        pkgs="$pkgs android-tools-adb"
    fi

    # Cabeceras del kernel en ejecución, necesarias para compilar v4l2loopback vía dkms.
    local kver; kver="$(uname -r)"
    if apt-cache show "linux-headers-$kver" >/dev/null 2>&1; then
        pkgs="$pkgs linux-headers-$kver"
    else
        warn "No se encontró linux-headers-$kver en los repos; probando linux-headers-generic."
        warn "Si el kernel en ejecución no coincide con el más reciente del repositorio,"
        warn "puede que v4l2loopback no compile bien hasta que reinicies con el kernel actualizado."
        pkgs="$pkgs linux-headers-generic"
    fi

    # shellcheck disable=SC2086
    if ! sudo apt install -y $pkgs; then
        err "Falló la instalación de uno o más paquetes (ver mensajes de apt arriba)."
        err "Instalación abortada: vuelve a ejecutar '$(basename "$SELF_PATH") install' cuando esté resuelto."
        exit 1
    fi
    ok "Paquetes instalados."

    # ---------- 2. Instalar/actualizar scrcpy (build oficial, no vía apt) ----------
    info "Preparando scrcpy (se necesita la versión 2.2 o superior)..."
    if ! ensure_scrcpy_installed; then
        warn "No se pudo instalar scrcpy automáticamente durante la instalación."
        warn "Puedes intentarlo de nuevo más tarde desde el menú, o instalarlo a mano:"
        warn "  https://github.com/Genymobile/scrcpy/blob/master/doc/linux.md"
    fi

    # ---------- 3. Secure Boot: v4l2loopback-dkms necesita firmarse / MOK ----------
    if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
        warn "Secure Boot está activado en este equipo."
        warn "Si es la primera vez que se compila un módulo de kernel vía DKMS"
        warn "(v4l2loopback), es posible que en el próximo arranque aparezca la"
        warn "pantalla azul 'MOK Management': tendrás que enrolar la clave nueva"
        warn "para que el kernel acepte cargar el módulo. Sigue las instrucciones en pantalla."
    fi

    # ---------- 4. Grupos de usuario (acceso a /dev/video* y a ADB por udev) ----------
    local need_relogin=0 grp me; me="$(id -un)"
    for grp in video plugdev; do
        if getent group "$grp" >/dev/null 2>&1; then
            if ! id -nG "$me" | grep -qw "$grp"; then
                if sudo usermod -aG "$grp" "$me"; then
                    need_relogin=1
                    info "Añadido al grupo '$grp'."
                else
                    err "No se pudo añadir el usuario al grupo '$grp'."
                fi
            fi
        fi
    done

    # ---------- 5. v4l2loopback persistente ----------
    info "Configurando v4l2loopback (webcam virtual)..."
    local v4l2_nr="$V4L2_NR_DEFAULT"

    # Reinstalación: reutiliza el número ya guardado en phonecam.conf en vez
    # de reiniciar la búsqueda en V4L2_NR_DEFAULT. Si no, /etc/modprobe.d
    # podía acabar con un video_nr distinto del que la configuración
    # existente (no se sobrescribe, ver paso 7) sigue usando.
    if [ -f "$CONF_FILE" ]; then
        local saved_line
        saved_line=$(grep '^V4L2_DEVICE=' "$CONF_FILE" 2>/dev/null | tail -1)
        [[ "$saved_line" =~ /dev/video([0-9]+) ]] && v4l2_nr="${BASH_REMATCH[1]}"
    fi

    # Si /dev/video42 ya existe y v4l2loopback todavía no está cargado, es
    # que otro dispositivo real (otra cámara, capturadora...) ya lo usa: hay
    # que elegir un número libre en vez de reutilizarlo a ciegas.
    if [ -e "/dev/video$v4l2_nr" ] && ! lsmod | grep -q '^v4l2loopback'; then
        warn "/dev/video$v4l2_nr ya está en uso por otro dispositivo."
        local candidate found=0
        for candidate in $(seq $((v4l2_nr + 1)) $((v4l2_nr + 20))); do
            if [ ! -e "/dev/video$candidate" ]; then
                v4l2_nr="$candidate"; found=1
                break
            fi
        done
        if [ "$found" -eq 1 ]; then
            warn "Se usará /dev/video$v4l2_nr en su lugar."
            # Si ya existía una configuración previa (reinstalación), el paso
            # 7 de más abajo NO la sobrescribe: sin esto, phonecam.conf se
            # quedaría con el V4L2_DEVICE viejo (el que ahora ocupa otro
            # dispositivo) mientras el módulo del kernel se configura con el
            # número nuevo, y "phonecam webcam" apuntaría al sitio equivocado.
            if [ -f "$CONF_FILE" ]; then
                if set_config V4L2_DEVICE "/dev/video$v4l2_nr"; then
                    warn "Se ha actualizado V4L2_DEVICE en $CONF_FILE para que coincida."
                else
                    err "No se pudo actualizar V4L2_DEVICE en $CONF_FILE: edítalo a mano y pon /dev/video$v4l2_nr."
                fi
            fi
        else
            err "No se encontró ningún /dev/video libre cerca de $v4l2_nr."
            err "Libera algún dispositivo o ajusta V4L2_NR_DEFAULT en el script y reinténtalo."
            exit 1
        fi
    fi

    local v4l2_conf_ok=1
    sudo tee /etc/modprobe.d/phonecam-v4l2loopback.conf >/dev/null <<EOF || v4l2_conf_ok=0
options v4l2loopback video_nr=$v4l2_nr card_label="$V4L2_LABEL" exclusive_caps=1
EOF
    echo "v4l2loopback" | sudo tee /etc/modules-load.d/phonecam-v4l2loopback.conf >/dev/null || v4l2_conf_ok=0
    if [ "$v4l2_conf_ok" -eq 0 ]; then
        err "No se pudo escribir la configuración de v4l2loopback en /etc (¿permisos, disco lleno?)."
        warn "La webcam puede funcionar ahora, pero no sobrevivirá a un reinicio."
    fi

    if lsmod | grep -q '^v4l2loopback'; then
        warn "v4l2loopback ya estaba cargado; se recargará con la configuración de PhoneCam."
        sudo modprobe -r v4l2loopback 2>/dev/null || warn "No se pudo descargar (puede estar en uso). Reinicia si algo falla."
    fi
    sudo modprobe v4l2loopback video_nr="$v4l2_nr" card_label="$V4L2_LABEL" exclusive_caps=1 || \
        warn "No se pudo cargar v4l2loopback ahora mismo (puede que necesites reiniciar)."

    if [ -e "/dev/video$v4l2_nr" ]; then
        ok "Webcam virtual creada en /dev/video$v4l2_nr"
    else
        warn "/dev/video$v4l2_nr no aparece todavía. Reinicia el equipo si persiste tras la instalación."
    fi

    # ---------- 6. Instalar este script como "phonecam" en ~/.local/bin ----------
    info "Instalando PhoneCam en $INSTALLED_BIN ..."
    mkdir -p "$BIN_DIR"
    # Si ya se está ejecutando la copia instalada (reinstalación/actualización),
    # "cp" sobre el mismo archivo fallaría ("son el mismo archivo"); en ese
    # caso no hay nada que copiar.
    if [ "$SELF_PATH" -ef "$INSTALLED_BIN" ]; then
        info "Ya se está ejecutando la copia instalada; no hace falta copiar."
    elif ! cp "$SELF_PATH" "$INSTALLED_BIN"; then
        err "No se pudo copiar el script a $INSTALLED_BIN."
        exit 1
    fi
    chmod +x "$INSTALLED_BIN"
    ok "Script instalado."

    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        [ -f "$HOME/.profile" ] || touch "$HOME/.profile"
        if ! grep -q '.local/bin' "$HOME/.profile"; then
            cat >> "$HOME/.profile" <<'EOF'

# Añadido por el instalador de PhoneCam
if [ -d "$HOME/.local/bin" ] ; then
    PATH="$HOME/.local/bin:$PATH"
fi
EOF
            warn "Se añadió ~/.local/bin al PATH en ~/.profile (aplica al iniciar sesión de nuevo)."
        fi
    fi

    # ---------- 7. Configuración ----------
    mkdir -p "$CONF_DIR"
    if [ ! -f "$CONF_FILE" ]; then
        write_default_config "$v4l2_nr"
        ok "Configuración creada en $CONF_FILE"
    else
        info "Ya existe una configuración previa, no se sobrescribe."
    fi

    # ---------- 8. Lanzador de aplicaciones ----------
    mkdir -p "$DESKTOP_DIR"
    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=PhoneCam
GenericName=Móvil como webcam y micrófono
Comment=Usa tu Android como webcam y/o micrófono por USB
Exec=$INSTALLED_BIN menu
Icon=camera-web
Terminal=false
Categories=AudioVideo;Video;
StartupNotify=false
EOF
    ok "Lanzador de aplicaciones creado."

    # ---------- 9. Servicio systemd de usuario (autoarranque + bandeja) ----------
    mkdir -p "$SYSTEMD_USER_DIR"
    cat > "$SYSTEMD_SERVICE_FILE" <<EOF
[Unit]
Description=PhoneCam - agente de detección USB y bandeja del sistema
After=graphical-session.target

[Service]
Type=simple
ExecStart=$INSTALLED_BIN agent
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    if systemctl --user enable --now phonecam-agent.service 2>/dev/null; then
        ok "Agente de autoarranque activado (systemd --user)."
    else
        warn "No se pudo activar el servicio de usuario automáticamente."
        warn "Ejecútalo manualmente con: systemctl --user enable --now phonecam-agent.service"
    fi

    echo
    echo "=============================================="
    ok "Instalación completada."
    echo "=============================================="
    echo "Uso:"
    echo "  phonecam menu     -> abre el menú gráfico"
    echo "  phonecam webcam   -> solo cámara"
    echo "  phonecam mic      -> solo micrófono"
    echo "  phonecam both     -> cámara + micrófono"
    echo "  phonecam status   -> ver estado"
    echo
    echo "En el teléfono:"
    echo "  1) Activa Opciones de desarrollador -> Depuración USB."
    echo "  2) Conéctalo por cable USB y acepta el diálogo de autorización."
    echo "  3) Al conectarlo, PhoneCam lo detectará automáticamente"
    echo "     (modo configurado en $CONF_FILE -> AUTO_MODE)."
    echo

    if [ "$need_relogin" -eq 1 ]; then
        warn "Se te añadió a nuevos grupos (video/plugdev)."
        warn "Debes CERRAR SESIÓN y volver a entrar (o reiniciar) para que tengan efecto."
    fi
}

# =============================================================================
#  Desinstalación
# =============================================================================
cmd_uninstall() {
    if [ "$EUID" -eq 0 ]; then
        err "No ejecutes esto como root."
        exit 1
    fi

    # Si estamos ejecutando la copia instalada (p.ej. "phonecam uninstall"),
    # nos relanzamos desde una copia temporal: así podemos borrar el binario
    # instalado con seguridad, sin tocar el archivo que bash está leyendo en
    # este mismo momento.
    if [ "$SELF_PATH" = "$INSTALLED_BIN" ] && [ -z "${PHONECAM_UNINSTALL_TMP:-}" ]; then
        local tmp
        tmp="$(mktemp /tmp/phonecam-uninstall.XXXXXX.sh)" || { err "No se pudo crear un archivo temporal en /tmp."; exit 1; }
        cp "$INSTALLED_BIN" "$tmp"
        chmod +x "$tmp"
        PHONECAM_UNINSTALL_TMP="$tmp" exec "$tmp" uninstall
    fi

    echo "Deteniendo procesos activos..."
    stop_all >/dev/null 2>&1 || true

    echo "Desactivando el agente en segundo plano..."
    systemctl --user disable --now phonecam-agent.service 2>/dev/null || true
    rm -f "$SYSTEMD_SERVICE_FILE"
    systemctl --user daemon-reload 2>/dev/null || true

    echo "Eliminando script instalado..."
    rm -f "$INSTALLED_BIN"

    echo "Eliminando lanzador de aplicaciones..."
    rm -f "$DESKTOP_FILE"

    if [ -d "$SCRCPY_DIR" ]; then
        echo "Eliminando scrcpy descargado por PhoneCam..."
        if [ -L "$BIN_DIR/scrcpy" ]; then
            case "$(readlink -f "$BIN_DIR/scrcpy" 2>/dev/null)" in
                "$SCRCPY_DIR"/*) rm -f "$BIN_DIR/scrcpy" ;;
            esac
        fi
        rm -rf "$SCRCPY_DIR"
    fi

    echo "Liberando el micrófono virtual (PipeWire/PulseAudio)..."
    pactl list short modules 2>/dev/null \
        | awk -v s="$MIC_SINK_NAME" -v m="$MIC_SOURCE_NAME" '$0 ~ s || $0 ~ m {print $1}' \
        | while read -r modid; do pactl unload-module "$modid" 2>/dev/null; done

    echo "Eliminando archivos temporales y registros..."
    rm -rf "$RUN_DIR" "$LOG_DIR"
    rmdir --ignore-fail-on-non-empty "$HOME/.local/share/phonecam" 2>/dev/null || true

    local del_conf=""
    read -rp "¿Eliminar también la configuración en $CONF_DIR? [s/N]: " del_conf
    if [[ "$del_conf" =~ ^[sS]$ ]]; then
        rm -rf "$CONF_DIR"
        ok "Configuración eliminada."
    fi

    echo
    info "Para revertir la webcam virtual v4l2loopback:"
    echo "   sudo rm -f /etc/modprobe.d/phonecam-v4l2loopback.conf"
    echo "   sudo rm -f /etc/modules-load.d/phonecam-v4l2loopback.conf"
    echo "   sudo modprobe -r v4l2loopback"
    echo
    info "Los paquetes del sistema (v4l2loopback-dkms, pipewire...) no se han"
    info "desinstalado porque otras aplicaciones pueden depender de ellos. Puedes"
    info "quitarlos manualmente con apt si quieres."

    ok "PhoneCam desinstalado."

    if [ -n "${PHONECAM_UNINSTALL_TMP:-}" ]; then
        rm -f "$PHONECAM_UNINSTALL_TMP"
    fi
}

# =============================================================================
#  Ayuda y punto de entrada
# =============================================================================
usage() {
    cat <<EOF
PhoneCam — usa tu Android como webcam/micrófono por USB (Linux Mint / Cinnamon)

Uso: $(basename "$SELF_PATH") <comando>

Comandos:
  install       Instala dependencias del sistema y deja "phonecam" listo para usar
                (acepta --yes para instalar sin preguntas)
  uninstall     Desinstala PhoneCam (no toca los paquetes del sistema)
  menu          Abre el menú (gráfico si hay zenity, texto si no) [por defecto]
  webcam        Inicia solo la cámara del teléfono como webcam
  mic           Inicia solo el micrófono del teléfono
  both          Inicia cámara + micrófono a la vez
  stop          Detiene todos los procesos de PhoneCam
  status        Muestra el estado actual
  cameras       Lista las cámaras disponibles en el teléfono
  choose-cam    Elige y guarda la cámara predeterminada
  config        Abre el archivo de configuración en un editor
  ayuda         Guía rápida: cómo conectar y autorizar el teléfono
  version       Muestra la versión instalada
  agent         (uso interno, vía systemd --user) agente en segundo plano
EOF
}

main() {
    local cmd="${1:-menu}"
    case "$cmd" in
        install)
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
        ayuda|help-conexion) load_config; show_connection_help ;;
        agent)      load_config; run_agent ;;
        version|--version) echo "PhoneCam $PHONECAM_VERSION" ;;
        -h|--help|help) usage ;;
        *) err "Comando desconocido: $cmd"; usage; exit 1 ;;
    esac
}

# Permite hacer "source" de este script (p. ej. para pruebas) sin disparar
# main() automáticamente.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
