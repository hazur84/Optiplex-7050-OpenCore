#!/bin/bash
# =============================================================================
#  probar_layouts.sh — Dell OptiPlex 7050 (Realtek ALC255 + AppleALC 1.9.8)
#
#  Prueba, uno por uno, los layouts de AppleALC para el ALC255 y se queda con
#  el mejor. Cada layout exige reiniciar, así que el script lo hace solo:
#    pone alcid=N en boot-args → reinicia → al arrancar mide si cargó AppleHDA
#    y qué salidas/entradas aparecieron → anota → siguiente layout.
#  Al final escribe el mejor layout en el config.plist de la EFI, deja todo
#  como estaba (boot-args y config) y reinicia una última vez.
#
#  Uso (en la OptiPlex, en Terminal):
#    bash probar_layouts.sh            empieza la prueba (pide tu contraseña)
#    bash probar_layouts.sh estado     muestra cómo va
#    bash probar_layouts.sh cancelar   detiene todo y deja la EFI como estaba
#    bash probar_layouts.sh fijar 11   pone un layout a mano en la EFI
#
#  Para abortar desde el arranque: en el selector de OpenCore elige
#  «Reset NVRAM». El script lo detecta, se detiene y restaura todo.
# =============================================================================

VERSION="1.0 (7-nov-2026)"
G=7C436110-AB2A-4BBB-A880-FE41995C9F82
HDEF_PATH='PciRoot(0x0)/Pci(0x1f,0x3)'
# Layouts de AppleALC 1.9.8 para el ALC255 (0x10EC0255)
TODOS="3 11 12 13 15 16 17 18 20 21 22 23 27 28 29 30 31 37 66 69 71 80 82 86 89 96 99 100 255"
RAPIDOS="27 11 13 3 15 17 21 28 29 30 31 99"
# Si ningún layout carga AppleHDA, se prueban estas variantes:
VARIANTES="27:alcdelay=1000 11:alcdelay=1000 13:alcdelay=1000 27:alctcsel=1 11:alctcsel=1 13:alctcsel=1"

# --- Rutas (en modo simulado todo vive en una carpeta de prueba) ---
SIM="${PROBAR_SIM:-}"
if [ -n "$SIM" ]; then
  EST="$SIM/estado"; DAEMON="$SIM/LaunchDaemons/mx.optiplex.probarlayouts.plist"; SUDO=""
else
  EST="/Library/Application Support/ProbarLayouts"; DAEMON="/Library/LaunchDaemons/mx.optiplex.probarlayouts.plist"
  if [ "$(id -u)" = 0 ]; then SUDO=""; else SUDO="sudo"; fi
fi

pedir_sudo() { [ -z "$SUDO" ] || sudo -v; }
log() { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*" | $SUDO tee -a "$EST/log.txt" >/dev/null 2>&1; printf '  %s\n' "$*"; }

# --- NVRAM boot-args ---
leer_bootargs() {
  if [ -n "$SIM" ]; then cat "$SIM/nvram_boot_args" 2>/dev/null; else nvram boot-args 2>/dev/null | cut -f2-; fi
}
poner_bootargs() {
  if [ -n "$SIM" ]; then printf '%s' "$1" > "$SIM/nvram_boot_args"; else $SUDO nvram boot-args="$1"; fi
}
limpiar_args() { # quita alcid/alcdelay/alctcsel de una cadena de boot-args
  printf '%s' "$1" | tr ' ' '\n' | grep -vE '^(alcid|alcdelay|alctcsel)=' | paste -sd ' ' - ; }

reiniciar() {
  if [ -n "$SIM" ]; then echo "  [simulación] reinicio"; else sync; $SUDO shutdown -r now; fi
}

# --- EFI ---
uuid_de() { diskutil info "$1" 2>/dev/null | awk -F': +' '/Disk \/ Partition UUID/{print toupper($2)}'; }
montar_efi_uuid() { # $1 UUID de partición → imprime punto de montaje
  if [ -n "$SIM" ]; then echo "$SIM/efi"; return; fi
  local id
  for id in $(diskutil list | awk '/ EFI /{print $NF}'); do
    [ "$(uuid_de "$id")" = "$1" ] || continue
    $SUDO diskutil mount "$id" >/dev/null 2>&1
    diskutil info "$id" | awk -F': +' '/Mount Point/{print $2}'; return
  done
}
desmontar_efi() { [ -n "$SIM" ] || $SUDO diskutil unmount "$1" >/dev/null 2>&1; }

elegir_efi() { # imprime el UUID de la EFI desde la que arrancó OpenCore
  if [ -n "$SIM" ]; then echo "SIMULADA"; return; fi
  local bp guid id cand="" M
  bp=$(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path 2>/dev/null | cut -f2)
  guid=$(printf '%s' "$bp" | sed -n 's/.*GPT,\([0-9A-Fa-f-]\{36\}\).*/\1/p' | tr 'a-f' 'A-F')
  if [ -n "$guid" ]; then echo "$guid"; return; fi
  # Sin boot-path: la EFI de un disco interno que tenga OpenCore
  for id in $(diskutil list internal physical | awk '/ EFI /{print $NF}'); do
    $SUDO diskutil mount "$id" >/dev/null 2>&1
    M=$(diskutil info "$id" | awk -F': +' '/Mount Point/{print $2}')
    [ -n "$M" ] && [ -f "$M/EFI/OC/OpenCore.efi" ] && { cand=$id; break; }
  done
  if [ -z "$cand" ]; then
    echo "  No encontré la EFI de OpenCore. Particiones EFI:" >&2; diskutil list | grep -E '^/dev/| EFI ' >&2
    printf '  Escribe el identificador (ej. disk0s1): ' >&2; read -r cand
  fi
  [ -n "$cand" ] && uuid_de "$cand"
}

# base64 de 4 bytes little endian
b64_le() {
  local n=$1 t="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local b0=$(( n & 255 )) b1=$(( (n >> 8) & 255 )) b2=$(( (n >> 16) & 255 )) b3=$(( (n >> 24) & 255 ))
  local g=$(( (b0 << 16) | (b1 << 8) | b2 )) g2=$(( b3 << 16 ))
  printf '%s%s%s%s%s%s==' "${t:$(( (g >> 18) & 63 )):1}" "${t:$(( (g >> 12) & 63 )):1}" "${t:$(( (g >> 6) & 63 )):1}" \
    "${t:$(( g & 63 )):1}" "${t:$(( (g2 >> 18) & 63 )):1}" "${t:$(( (g2 >> 12) & 63 )):1}"
}

# --- Medición del audio interno (subárbol HDEF del IORegistry) ---
ioreg_texto() {
  if [ -n "$SIM" ]; then
    local t; t=$(cat "$EST/actual" 2>/dev/null)
    if [ -n "${PROBAR_OK:-}" ] && [ "$t" = "$PROBAR_OK" ]; then cat "$PROBAR_IOREG_OK"; else cat "$PROBAR_IOREG"; fi
  else ioreg -lw0 -p IOService; fi
}
subarbol_hdef() {
  awk '/\+-o / { i = index($0, "+-o "); d = int((i - 1) / 2)
                 if (dentro && d <= d0) exit
                 if (!dentro && $0 ~ /\+-o HDEF@/) { dentro = 1; d0 = d } }
       dentro { print }'
}
medir() { # imprime: puntaje|ctrl|codec|driver|salidas|entradas|nombres
  local T; T=$(mktemp /tmp/probar.XXXXXX)
  ioreg_texto | subarbol_hdef > "$T"
  local ctrl=0 codec=0 drv=0 outs ins sel nsel
  grep -E '\+-o AppleHDAController@' "$T" | grep -q ', registered' && ctrl=1
  grep -q '"IOHDACodecVendorID" = ' "$T" && codec=1
  grep -q '+-o AppleHDADriver' "$T" && drv=1
  outs=$(grep -c '+-o AppleHDAEngineOutput' "$T"); ins=$(grep -c '+-o AppleHDAEngineInput' "$T")
  sel=$(grep -o '"IOAudioSelectorControlSelectionDescription"="[^"]*"' "$T" | sed 's/.*="//; s/"$//' | sort -u | paste -sd ',' -)
  nsel=0; [ -n "$sel" ] && nsel=$(printf '%s' "$sel" | tr ',' '\n' | grep -c .)
  rm -f "$T"
  echo "$(( ctrl + codec + 10 * drv + 3 * outs + ins + 2 * nsel ))|$ctrl|$codec|$drv|$outs|$ins|${sel:--}"
}
esperar_audio() { # hasta 90 s a que cargue AppleHDA (sale antes si aparece)
  [ -n "$SIM" ] && return
  local n=0
  while [ $n -lt 18 ]; do
    ioreg -lw0 -p IOService | subarbol_hdef | grep -q '+-o AppleHDADriver' && { sleep 10; return; }
    sleep 5; n=$((n + 1))
  done
}

# --- Pruebas: cada línea "layout:extra" ---
prueba_args() { # "11:alcdelay=1000" → "alcid=11 alcdelay=1000"
  local l=${1%%:*} x=""; case "$1" in *:*) x=${1#*:};; esac
  echo "alcid=$l${x:+ $x}"
}
preparar_siguiente() { # pone boot-args para la prueba $1 y reinicia
  local i=$1 t base args
  t=$(sed -n "${i}p" "$EST/pruebas.txt")
  base=$(limpiar_args "$(cat "$EST/original-boot-args")")
  args="$base $(prueba_args "$t")"; args=${args# }
  printf '%s' "$i" | $SUDO tee "$EST/indice" >/dev/null
  printf '%s' "$t" | $SUDO tee "$EST/actual" >/dev/null
  printf '%s' "$args" | $SUDO tee "$EST/esperado" >/dev/null
  poner_bootargs "$args"
  local total; total=$(grep -c . "$EST/pruebas.txt")
  log "Prueba $i de $total: $(prueba_args "$t") → reinicio"
  reiniciar
}

tabla() {
  [ -f "$EST/resultados.tsv" ] || { echo "  (todavía no hay resultados)"; return; }
  printf '  %-26s %-7s %-7s %-6s %-7s %-8s %s\n' "prueba" "puntos" "AppleHDA" "codec" "salidas" "entradas" "puertos de audio"
  awk -F'\t' '{ printf "  %-26s %-7s %-7s %-6s %-7s %-8s %s\n", $1, $2, ($5==1?"sí":"no"), ($4==1?"sí":"no"), $6, $7, $8 }' "$EST/resultados.tsv"
}

# --- Final: restaurar y aplicar el mejor ---
finalizar() { # $1 motivo
  local mejor="" M cfg l x
  mejor=$(awk -F'\t' '$5==1 { if ($2 > b) { b = $2; m = $1 } } END { print m }' "$EST/resultados.tsv" 2>/dev/null)
  M=$(montar_efi_uuid "$(cat "$EST/efi_uuid")"); cfg="$M/EFI/OC/config.plist"
  if [ -n "$M" ] && [ -f "$cfg" ] && [ -f "$EST/config-original.plist" ]; then
    $SUDO cp "$EST/config-original.plist" "$cfg"
    if [ -n "$mejor" ]; then
      l=$(printf '%s' "$mejor" | sed -n 's/.*alcid=\([0-9]*\).*/\1/p')
      x=$(printf '%s' "$mejor" | tr ' ' '\n' | grep -E '^(alcdelay|alctcsel)=' | paste -sd ' ' -)
      $SUDO plutil -replace "DeviceProperties.Add.$HDEF_PATH.layout-id" -data "$(b64_le "$l")" "$cfg"
      if [ -n "$x" ]; then
        local ba; ba=$(plutil -extract "NVRAM.Add.$G.boot-args" raw -o - "$cfg")
        $SUDO plutil -replace "NVRAM.Add.$G.boot-args" -string "$ba $x" "$cfg"
      fi
      plutil -lint "$cfg" >/dev/null || $SUDO cp "$EST/config-original.plist" "$cfg"
    fi
    desmontar_efi "$M"
  else
    log "ATENCIÓN: no pude montar la EFI para restaurar; el respaldo está en $EST/config-original.plist"
  fi
  poner_bootargs "$(cat "$EST/original-boot-args")"
  $SUDO rm -f "$DAEMON"
  {
    echo "Prueba de layouts de audio — OptiPlex 7050 (ALC255) — $(date)"
    echo "Motivo de término: $1"; echo
    tabla
    echo
    if [ -n "$mejor" ]; then
      echo "MEJOR: $mejor  → quedó en el config.plist (layout-id = $l${x:+, boot-args + $x})."
      echo "Reinicia (lo hace solo) y prueba el sonido en Configuración del Sistema > Sonido."
      echo "Si otro de la lista suena mejor: bash probar_layouts.sh fijar <layout>"
    else
      echo "Ningún layout ni variante hizo cargar AppleHDA. El layout no es el problema:"
      echo "hace falta el volcado del codec (SysReport de OpenCore DEBUG) para seguir."
      echo "El config quedó como estaba antes de la prueba."
    fi
  } > "$EST/resultado.txt"
  local u; u=$(cat "$EST/usuario" 2>/dev/null)
  [ -n "$u" ] && [ -d "/Users/$u/Desktop" ] && $SUDO cp "$EST/resultado.txt" "/Users/$u/Desktop/Resultado-layouts-audio.txt" 2>/dev/null
  $SUDO cp "$EST/resultado.txt" "/Users/Shared/Resultado-layouts-audio.txt" 2>/dev/null
  printf 'terminado' | $SUDO tee "$EST/indice" >/dev/null
  log "Terminado ($1). Mejor: ${mejor:-ninguno}"
  [ -n "$mejor" ] && reiniciar
}

# =============================================================================
cmd_iniciar() {
  echo "probar_layouts.sh $VERSION"
  [ -f "$EST/indice" ] && [ "$(cat "$EST/indice")" != terminado ] && { echo "  Ya hay una prueba en curso. Usa: estado o cancelar"; exit 1; }
  if [ -z "$SIM" ]; then
    kextstat 2>/dev/null | grep -q AppleALC || { echo "  ALTO: AppleALC no está cargado"; exit 1; }
    ioreg -lw0 -p IOService | grep -q '+-o HDEF@' || { echo "  ALTO: no encuentro el audio HDEF"; exit 1; }
    if fdesetup isactive >/dev/null 2>&1; then
      echo "  OJO: FileVault está activo; en cada reinicio tendrás que escribir tu contraseña."
    fi
  fi
  local modo pruebas
  modo="${PROBAR_MODO:-}"
  if [ -z "$modo" ]; then
    echo; echo "  c = completo: los 29 layouts del ALC255 (≈ 1 hora, unos 2 min por reinicio)"
    echo "  r = rápido: 12 layouts comunes (≈ 25 min)"
    printf '  Elige c o r [c]: '; read -r modo
  fi
  case "$modo" in r|R) pruebas=$RAPIDOS;; *) pruebas=$TODOS;; esac
  echo "  Tu contraseña de esta Mac (no se ve al escribirla):"; pedir_sudo || exit 1
  $SUDO mkdir -p "$EST" "$(dirname "$DAEMON")"
  $SUDO rm -f "$EST/resultados.tsv" "$EST/resultado.txt" "$EST/fase2"
  local uuid M cfg i bp orig
  uuid=$(elegir_efi); [ -n "$uuid" ] || { echo "  ALTO: no sé qué EFI usar"; exit 1; }
  M=$(montar_efi_uuid "$uuid"); cfg="$M/EFI/OC/config.plist"
  [ -f "$cfg" ] || { echo "  ALTO: no encontré EFI/OC/config.plist"; exit 1; }
  printf '%s' "$uuid" | $SUDO tee "$EST/efi_uuid" >/dev/null
  $SUDO cp "$cfg" "$EST/config-original.plist"
  $SUDO cp "$cfg" "$(dirname "$cfg")/config.plist.antes-layouts-$(date +%Y%m%d-%H%M%S)"
  # boot-args fuera de NVRAM > Delete: así el alcid que ponemos sobrevive al reinicio
  i=0
  while bp=$(plutil -extract "NVRAM.Delete.$G.$i" raw -o - "$cfg" 2>/dev/null); do
    if [ "$bp" = boot-args ]; then $SUDO plutil -remove "NVRAM.Delete.$G.$i" "$cfg"; break; fi
    i=$((i + 1))
  done
  plutil -lint "$cfg" >/dev/null || { $SUDO cp "$EST/config-original.plist" "$cfg"; echo "  ALTO: no pude editar el config"; exit 1; }
  desmontar_efi "$M"
  orig=$(leer_bootargs); [ -n "$orig" ] || orig=$(plutil -extract "NVRAM.Add.$G.boot-args" raw -o - "$EST/config-original.plist")
  orig=$(limpiar_args "$orig")
  printf '%s' "$orig" | $SUDO tee "$EST/original-boot-args" >/dev/null
  printf '%s' "${SUDO_USER:-$(id -un)}" | $SUDO tee "$EST/usuario" >/dev/null
  printf '%s\n' $pruebas | $SUDO tee "$EST/pruebas.txt" >/dev/null
  # El script se copia al disco y un LaunchDaemon lo corre en cada arranque
  if [ -z "$SIM" ]; then
    $SUDO cp "$0" "$EST/probar_layouts.sh"
    $SUDO tee "$DAEMON" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>mx.optiplex.probarlayouts</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$EST/probar_layouts.sh</string><string>continuar</string></array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$EST/log.txt</string>
  <key>StandardErrorPath</key><string>$EST/log.txt</string>
</dict></plist>
EOF
    $SUDO chown root:wheel "$DAEMON"; $SUDO chmod 644 "$DAEMON"
  else
    : > "$DAEMON"
  fi
  echo
  echo "  Listo para empezar: $(grep -c . "$EST/pruebas.txt") pruebas. La Mac se reiniciará sola en cada una."
  echo "  No toques nada; al final verás Resultado-layouts-audio.txt en tu Escritorio."
  echo "  Para abortar: en el selector de OpenCore elige «Reset NVRAM»."
  if [ -z "$SIM" ]; then echo "  Primer reinicio en 15 segundos (Ctrl-C y luego 'cancelar' para no empezar)…"; sleep 15; fi
  preparar_siguiente 1
}

cmd_continuar() { # lo corre el LaunchDaemon en cada arranque
  [ -f "$EST/indice" ] || { $SUDO rm -f "$DAEMON"; exit 0; }
  local i actual esperado cur r total
  i=$(cat "$EST/indice"); [ "$i" = terminado ] && { $SUDO rm -f "$DAEMON"; exit 0; }
  actual=$(cat "$EST/actual"); esperado=$(cat "$EST/esperado"); cur=$(leer_bootargs)
  if [ "$cur" != "$esperado" ]; then
    log "boot-args no coinciden (esperaba «$esperado», hay «$cur»): ¿Reset NVRAM? Detengo la prueba."
    finalizar "abortado (boot-args cambiados; Reset NVRAM o la NVRAM no guardó)"; exit 0
  fi
  esperar_audio
  r=$(medir)
  printf '%s\t%s\n' "$(prueba_args "$actual")" "$(printf '%s' "$r" | tr '|' '\t')" | $SUDO tee -a "$EST/resultados.tsv" >/dev/null
  log "Resultado $(prueba_args "$actual"): $(printf '%s' "$r" | awk -F'|' '{print "puntos " $1 ", AppleHDA " ($4==1?"sí":"no") ", salidas " $5 ", " $7}')"
  total=$(grep -c . "$EST/pruebas.txt")
  if [ "$i" -ge "$total" ] && [ ! -f "$EST/fase2" ] && ! awk -F'\t' '$5==1{f=1} END{exit !f}' "$EST/resultados.tsv"; then
    log "Ningún layout cargó AppleHDA; agrego las variantes con alcdelay y alctcsel."
    printf '%s\n' $VARIANTES | $SUDO tee -a "$EST/pruebas.txt" >/dev/null; : | $SUDO tee "$EST/fase2" >/dev/null
    total=$(grep -c . "$EST/pruebas.txt")
  fi
  if [ "$i" -lt "$total" ]; then preparar_siguiente $((i + 1)); else finalizar "completo"; fi
}

cmd_estado() {
  [ -f "$EST/indice" ] || { echo "  No hay ninguna prueba."; exit 0; }
  echo "  Índice: $(cat "$EST/indice") de $(grep -c . "$EST/pruebas.txt")   prueba actual: $(cat "$EST/actual" 2>/dev/null)"
  tabla
  [ -f "$EST/resultado.txt" ] && { echo; cat "$EST/resultado.txt"; }
}

cmd_cancelar() {
  [ -f "$EST/indice" ] || { echo "  No hay ninguna prueba."; exit 0; }
  pedir_sudo || exit 1
  local M; M=$(montar_efi_uuid "$(cat "$EST/efi_uuid")")
  [ -n "$M" ] && [ -f "$EST/config-original.plist" ] && $SUDO cp "$EST/config-original.plist" "$M/EFI/OC/config.plist" && desmontar_efi "$M"
  poner_bootargs "$(cat "$EST/original-boot-args")"
  $SUDO rm -f "$DAEMON"; printf 'terminado' | $SUDO tee "$EST/indice" >/dev/null
  echo "  Cancelado: EFI y boot-args como estaban. Resultados parciales:"; tabla
}

cmd_fijar() { # $1 layout
  [ -n "${1:-}" ] || { echo "  Uso: fijar <layout>"; exit 1; }
  pedir_sudo || exit 1
  local uuid M cfg; uuid=$(elegir_efi); M=$(montar_efi_uuid "$uuid"); cfg="$M/EFI/OC/config.plist"
  [ -f "$cfg" ] || { echo "  ALTO: no encontré el config"; exit 1; }
  $SUDO cp "$cfg" "$cfg.antes-fijar-$(date +%Y%m%d-%H%M%S)"
  $SUDO plutil -replace "DeviceProperties.Add.$HDEF_PATH.layout-id" -data "$(b64_le "$1")" "$cfg"
  plutil -lint "$cfg" >/dev/null && echo "  layout-id = $1 en el config. Reinicia para probarlo."
  desmontar_efi "$M"
}

case "${1:-iniciar}" in
  iniciar) cmd_iniciar;;
  continuar) cmd_continuar;;
  estado) cmd_estado;;
  cancelar) cmd_cancelar;;
  fijar) cmd_fijar "${2:-}";;
  *) echo "Uso: bash probar_layouts.sh [iniciar|estado|cancelar|fijar N]";;
esac
