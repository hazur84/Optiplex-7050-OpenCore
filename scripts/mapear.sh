#!/bin/bash
# =============================================================================
#  mapear.sh — Dell OptiPlex 7050 (Hackintosh, OpenCore 1.0.8, macOS Ventura)
#
#  Hace tres cosas en una sola corrida:
#    1. REPORTE automático del equipo: tablas ACPI (.aml), PCI, gráficas
#       (¿la RX 550 es Lexa o Baffin?), audio (codec para el chime), NVRAM,
#       kexts cargados y un volcado completo de ioreg.
#    2. MAPA USB guiado: conectas una memoria en cada puerto y el script
#       detecta solo qué líneas (HS = USB 2.0, SS = USB 3) usa cada puerto.
#    3. Genera USBMap.kext, lo copia a la EFI desde la que arrancó OpenCore y
#       ajusta el config.plist (activa USBMap, desactiva USBPorts, quita
#       XhciPortLimit). Antes guarda un respaldo del config.plist.
#
#  Dónde correrlo:
#    - Desde la USB del instalador: Utilidades > Terminal, y escribe
#        bash "/Volumes/Install macOS Ventura/OptiPlex/mapear.sh"
#    - O en macOS ya instalado (pedirá tu contraseña para tocar la EFI).
#
#  Requisito: arrancar con el config que trae XhciPortLimit = true y
#  USBPorts.kext desactivado, para que macOS vea todos los puertos.
# =============================================================================

VERSION="1.1 (8-nov-2026)"
MODELOS="iMac18,1 iMac18,2"          # los dos configs de esta EFI
LIMITE=15                             # macOS acepta 15 puertos por controlador
FECHA=$(date +%Y%m%d-%H%M%S)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Variables solo para pruebas (no las uses en la OptiPlex):
SIM="${MAPA_SIMULAR:-}"     # secuencia de eventos en vez de detectar puertos
FIXTURE="${MAPA_IOREG:-}"   # archivo con salida de: ioreg -r -c AppleUSBXHCI -w0 -d 3 -l
EFI_FORZADA="${MAPA_EFI:-}" # raíz de una EFI ya montada (carpeta que contiene EFI/OC)
NO_REPORTE="${MAPA_SIN_REPORTE:-}"

TMP=$(mktemp -d /tmp/mapear.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
if [ "$(id -u)" = 0 ]; then SUDO=""; else SUDO="sudo"; fi

linea() { printf '%s\n' "------------------------------------------------------------"; }
titulo() { echo; linea; printf '  %s\n' "$*"; linea; }
aviso() { printf '  >> %s\n' "$*"; }
beep() { printf '\a'; }

# -----------------------------------------------------------------------------
#  Lectura de puertos USB desde ioreg
#  Salida: C|ctrlId|ctrlClass   P|ctrlId|puerto|clase|hex|connector   D|ctrlId/puerto|dispositivo
# -----------------------------------------------------------------------------
ioreg_usb() {
  if [ -n "$FIXTURE" ]; then cat "$FIXTURE"; else ioreg -r -c AppleUSBXHCI -w0 -d 3 -l; fi
}

parse_usb() {
  awk '
  /\+-o / {
    i = index($0, "+-o "); d = int((i - 1) / 2)
    rest = substr($0, i + 4)
    c = index(rest, "  <class "); if (c == 0) next
    nm = substr(rest, 1, c - 1); cls = substr(rest, c + 9); sub(/,.*/, "", cls)
    base = nm; for (k = length(nm); k > 0; k--) if (substr(nm, k, 1) == "@") { base = substr(nm, 1, k - 1); break }
    if (d == 0) { ctrl = nm; obj = "ctrl"; print "C|" ctrl "|" cls }
    else if (d == 1) { port = base; obj = "port"; key = ctrl "/" port; n++; ord[n] = key; pc[key] = ctrl; pn[key] = port; pcls[key] = cls }
    else if (d == 2) { obj = "dev"; print "D|" ctrl "/" port "|" base }
    next
  }
  obj == "port" && /"port" = </ { if (match($0, /<[0-9a-fA-F]+>/)) phex[key] = tolower(substr($0, RSTART + 1, RLENGTH - 2)) }
  obj == "port" && /"UsbConnector" = / { v = $0; sub(/.*"UsbConnector" = /, "", v); pcon[key] = v + 0 }
  END { for (j = 1; j <= n; j++) { k = ord[j]; print "P|" pc[k] "|" pn[k] "|" pcls[k] "|" phex[k] "|" pcon[k] } }'
}

refrescar() { ioreg_usb | parse_usb > "$TMP/usb.txt"; }
ocupados() { grep '^D|' "$TMP/usb.txt" | cut -d'|' -f2 | sort -u; }

# datos de un puerto (clave ctrlId/puerto)
puerto_campo() { # $1 clave, $2 campo (3=nombre 4=clase 5=hex)
  local c=${1%%/*} p=${1#*/}
  awk -F'|' -v c="$c" -v p="$p" -v f="$2" '$1=="P" && $2==c && $3==p {print $f; exit}' "$TMP/usb.txt"
}
es_ss() { # 0 si la línea es USB 3 (SS)
  local cls nm; cls=$(puerto_campo "$1" 4); nm=$(puerto_campo "$1" 3)
  case "$cls" in *30*) return 0;; *20*) return 1;; esac
  case "$nm" in SS*|ss*|*-ss) return 0;; esac
  return 1
}
dispositivos_en() { grep "^D|$1|" "$TMP/usb.txt" | cut -d'|' -f3 | paste -sd ',' - ; }

# Nombre ACPI del controlador (para IONameMatch), p. ej. XHC
nombre_pci() { # $1 ctrlId (Nombre@loc)
  [ -n "$FIXTURE" ] && { echo "XHC"; return; }
  ioreg -w0 -p IOService | awk -v target="$1" '
    /\+-o / {
      i = index($0, "+-o "); d = int((i - 1) / 2); rest = substr($0, i + 4)
      c = index(rest, "  <class "); nm = substr(rest, 1, c - 1); cls = substr(rest, c + 9); sub(/,.*/, "", cls)
      N[d] = nm; K[d] = cls
      if (nm == target) { for (u = d - 1; u >= 0; u--) if (K[u] == "IOPCIDevice") { b = N[u]; sub(/@.*/, "", b); print b; exit } }
    }'
}

# base64 de 4 bytes dados en hex (8 caracteres) — sin depender de herramientas
b64_4() {
  local h=$1 t="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local b0=$((16#${h:0:2})) b1=$((16#${h:2:2})) b2=$((16#${h:4:2})) b3=$((16#${h:6:2}))
  local g=$(( (b0 << 16) | (b1 << 8) | b2 )) g2=$(( b3 << 16 ))
  printf '%s%s%s%s%s%s==' "${t:$(( (g >> 18) & 63 )):1}" "${t:$(( (g >> 12) & 63 )):1}" \
    "${t:$(( (g >> 6) & 63 )):1}" "${t:$(( g & 63 )):1}" "${t:$(( (g2 >> 18) & 63 )):1}" "${t:$(( (g2 >> 12) & 63 )):1}"
}
hex_a_num() { local h=$1; echo $(( 16#${h:6:2}${h:4:2}${h:2:2}${h:0:2} )); }   # little endian
num_a_hex() { printf '%02x%02x%02x%02x' $(( $1 & 255 )) $(( ($1 >> 8) & 255 )) $(( ($1 >> 16) & 255 )) $(( ($1 >> 24) & 255 )); }

# -----------------------------------------------------------------------------
#  1. Reporte del sistema
# -----------------------------------------------------------------------------
recolectar_reporte() {
  local R=$1; mkdir -p "$R/acpi" "$R/usb"
  titulo "1/3  Reporte automático del equipo"
  {
    echo "mapear.sh $VERSION — $(date)"
    sw_vers 2>/dev/null; uname -a
    echo "Modelo SMBIOS: $(sysctl -n hw.model 2>/dev/null)"
    echo "CPU: $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
    echo "RAM: $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )) GB"
    echo "OpenCore: $(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version 2>/dev/null | cut -f2)"
    echo "boot-path: $(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path 2>/dev/null | cut -f2)"
    echo "boot-args: $(nvram boot-args 2>/dev/null | cut -f2)"
  } > "$R/sistema.txt" 2>&1
  nvram -p 2>/dev/null | grep -E '^(boot-args|csr-active-config|SystemAudioVolume|SystemAudioVolumeDB|run-efi-updater|4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:)' > "$R/nvram.txt"
  { kextstat 2>/dev/null || kmutil showloaded 2>/dev/null; } | grep -v com.apple > "$R/kexts-de-terceros.txt"
  aviso "sistema, NVRAM y kexts: listo"

  ioreg -lw0 > "$TMP/ioreg-completo.txt" 2>/dev/null && aviso "ioreg analizado (no se guarda: contiene seriales y MAC)"
  ioreg -r -c IOPCIDevice -w0 -d 1 -l > "$R/pci-ioreg.txt" 2>/dev/null
  awk '
    /\+-o / { if (nm != "") print nm "\t" comp "\t" dbg "\t" model; i = index($0, "+-o "); rest = substr($0, i + 4); c = index(rest, "  <class "); nm = substr(rest, 1, c - 1); comp = ""; dbg = ""; model = "" }
    /"compatible" = / { v = $0; sub(/.*"compatible" = /, "", v); comp = v }
    /"pcidebug" = / { v = $0; sub(/.*"pcidebug" = /, "", v); dbg = v }
    /"model" = / { v = $0; sub(/.*"model" = /, "", v); model = v }
    END { if (nm != "") print nm "\t" comp "\t" dbg "\t" model }' "$R/pci-ioreg.txt" > "$R/pci.txt"
  aviso "dispositivos PCI: listo"

  # Gráficas: el device-id que se ve en macOS puede venir del config; el "compatible" trae el real
  {
    echo "== Gráficas =="
    grep -iE 'pci1002,|pci8086,59|pci8086,19' "$R/pci.txt"
    if grep -qi 'pci1002,699f' "$R/pci.txt"; then echo; echo "RX 550: chip LEXA (0x699F). Necesita el device-id 0x67FF que ya trae el config."
    elif grep -qi 'pci1002,67ff' "$R/pci.txt"; then echo; echo "RX 550: chip BAFFIN (0x67FF). Compatible de forma nativa."
    else echo; echo "RX 550: no la encontré en PCI (¿está bien insertada?)"; fi
    echo; echo "== Drivers de video cargados =="
    grep -oE 'AppleIntelKBLGraphics[A-Za-z]*|AppleIntelFramebuffer@[0-9]|AMDRadeonX4000[A-Za-z_]*|AMD9500Controller|AMDFramebuffer[A-Za-z]*' "$TMP/ioreg-completo.txt" | sort | uniq -c
  } > "$R/graficas.txt" 2>&1
  aviso "$(grep '^RX 550' "$R/graficas.txt")"

  # Audio: estado de AppleHDA y codecs (se leen del volcado completo; los no registrados no salen con -c)
  {
    echo "== Controlador de audio y codecs HDA =="
    grep -E '\+-o (HDEF|AppleHDAController|IOHDACodecDevice|AppleHDADriver|AppleHDACodec)' "$TMP/ioreg-completo.txt" | sed -e 's/^[ |]*+-o /  /' -e 's/, id 0x[0-9a-f]*//' -e 's/, busy.*//'
    echo; awk '/"IOHDACodecAddress" = /{x=$0;sub(/.*= /,"",x);a=x} /"IOHDACodecVendorID" = /{x=$0;sub(/.*= /,"",x);printf "  codec dirección %s  vendor 0x%08X\n", a, x+0}' "$TMP/ioreg-completo.txt"
    echo "  (Realtek ALC255 = 0x10EC0255; HDMI de Intel = 0x8086xxxx)"
    echo; echo "== layout-id =="; grep -m4 -E '"(alc-)?layout-id" = ' "$TMP/ioreg-completo.txt" | sed 's/^[ |]*//'
  } > "$R/audio.txt" 2>&1
  if grep -q 'AppleHDAController@.*!registered' "$TMP/ioreg-completo.txt"; then
    echo "  DIAGNÓSTICO: AppleHDA no terminó de cargar (controlador sin registrar). Prueba otro layout con alcid=XX en boot-args." >> "$R/audio.txt"
    aviso "audio: AppleHDA NO terminó de cargar (ver audio.txt)"
  elif grep -q 'AppleHDADriver' "$TMP/ioreg-completo.txt"; then aviso "audio: AppleHDA cargado"
  else aviso "audio: listo (ver audio.txt)"; fi

  # Tablas ACPI (.aml). Los .dsl se obtienen después con iasl en la Mac.
  if ioreg -a -r -c AppleACPIPlatformExpert -d 1 > "$TMP/acpi.xml" 2>/dev/null && \
     plutil -extract "0.ACPI Tables" xml1 -o "$TMP/tablas.xml" "$TMP/acpi.xml" 2>/dev/null; then
    local n=0 k
    for k in $(grep '<key>' "$TMP/tablas.xml" | sed -e 's/.*<key>//' -e 's/<\/key>.*//'); do
      if plutil -extract "0.ACPI Tables.$k" raw -o - "$TMP/acpi.xml" 2>/dev/null | base64 -D > "$R/acpi/$k.aml" 2>/dev/null; then n=$((n + 1)); fi
    done
    aviso "tablas ACPI: $n archivos .aml"
  else
    aviso "tablas ACPI: macOS Ventura ya no las publica en ioreg. Se sacan al arrancar con el SysReport de OpenCore"
    aviso "(versión DEBUG con Misc > Debug > SysReport = true; deja los .aml en la EFI, carpeta SysReport/ACPI)."
  fi
}

# -----------------------------------------------------------------------------
#  2. Mapa USB guiado
#  Cada puerto físico i: PT[i]=3|0|C|I  HS[i] SS[i] (claves ctrl/puerto)  ET[i]=etiqueta  BORRADO[i]
# -----------------------------------------------------------------------------
NP=0; PEND=""
nuevo_puerto() { NP=$((NP + 1)); PT[$NP]=$1; HS[$NP]=""; SS[$NP]=""; ET[$NP]=$2; BORRADO[$NP]=""; }
ya_usada() { local i; for ((i = 1; i <= NP; i++)); do [ -z "${BORRADO[$i]}" ] || continue; [ "${HS[$i]}" = "$1" ] || [ "${SS[$i]}" = "$1" ] && return 0; done; return 1; }
desc_tipo() { case "$1" in 3) echo "USB 3 tipo A";; 0) echo "USB 2.0";; C) echo "USB-C";; I) echo "interno";; esac; }
nom() { [ -n "$1" ] && puerto_campo "$1" 3 || echo "-"; }

resumen_puertos() {
  local i
  printf '  %-3s %-14s %-7s %-7s %s\n' "#" "tipo" "USB2" "USB3" "detectado con"
  for ((i = 1; i <= NP; i++)); do
    [ -z "${BORRADO[$i]}" ] || continue
    printf '  %-3s %-14s %-7s %-7s %s\n' "$i" "$(desc_tipo "${PT[$i]}")" "$(nom "${HS[$i]}")" "$(nom "${SS[$i]}")" "${ET[$i]}"
  done
}

evento_nuevo() { # $1 clave del puerto donde apareció un dispositivo
  local k=$1 dev; dev=$(dispositivos_en "$k"); [ -n "$dev" ] || dev="dispositivo"
  if ya_usada "$k"; then aviso "$(nom "$k") ya estaba registrado ($dev)"; return; fi
  beep
  if es_ss "$k"; then
    [ -n "$PEND" ] && aviso "Al puerto #$PEND le faltó la prueba USB 2.0; lo dejo solo con su línea USB 3."
    nuevo_puerto 3 "$dev"; SS[$NP]=$k; PEND=$NP
    aviso "USB 3 en $(nom "$k") → puerto #$NP. Ahora saca la memoria USB 3.0 y mete la USB 2.0 (o el mouse) en ESE MISMO puerto."
    aviso "(Si este puerto es el USB-C, pulsa c)"
  elif [ -n "$PEND" ]; then
    HS[$PEND]=$k; aviso "USB 2.0 en $(nom "$k") → puerto #$PEND completo ($(desc_tipo "${PT[$PEND]}")). Pasa al siguiente puerto con la memoria USB 3.0."
    PEND=""
  else
    nuevo_puerto 0 "$dev"; HS[$NP]=$k
    aviso "USB 2.0 en $(nom "$k") → puerto #$NP (solo USB 2.0). Pasa al siguiente puerto."
  fi
}

tecla() { # c = USB-C, i = interno, d = deshacer el último
  local u=$NP; while [ "$u" -gt 0 ] && [ -n "${BORRADO[$u]}" ]; do u=$((u - 1)); done
  [ "$u" -gt 0 ] || return
  case "$1" in
    c|C) PT[$u]=C; aviso "puerto #$u marcado como USB-C";;
    i|I) PT[$u]=I; aviso "puerto #$u marcado como interno";;
    d|D) BORRADO[$u]=1; [ "$PEND" = "$u" ] && PEND=""; aviso "puerto #$u borrado; vuelve a probarlo";;
  esac
}

mapear_usb() {
  titulo "2/3  Mapa USB"
  refrescar
  local nctrl nports; nctrl=$(grep -c '^C|' "$TMP/usb.txt"); nports=$(grep -c '^P|' "$TMP/usb.txt")
  echo "  Controladores USB: $nctrl   Líneas de puerto que ve macOS: $nports"
  if [ "$nports" -le "$LIMITE" ]; then
    aviso "macOS solo ve $nports líneas: parece que XhciPortLimit no está activo o hay otro mapa cargado."
    aviso "Arranca con el config que trae XhciPortLimit = true y USBPorts.kext desactivado."
    [ -n "$SIM" ] || { printf '  ¿Seguir de todos modos? (s/N) '; read -r r; [ "$r" = s ] || [ "$r" = S ] || exit 1; }
  fi

  # Lo que ya está conectado (teclado, mouse, Bluetooth interno…) entra solo
  local k dev
  for k in $(ocupados); do
    dev=$(dispositivos_en "$k")
    case "$dev" in
      *Bluetooth*|*BRCM*|*Broadcom*|*Wireless*|*Card*Reader*|*CardReader*|*Lector*) nuevo_puerto I "$dev (al inicio)";;
      *) if es_ss "$k"; then nuevo_puerto 3 "$dev (al inicio)"; else nuevo_puerto 0 "$dev (al inicio)"; fi;;
    esac
    if es_ss "$k"; then SS[$NP]=$k; else HS[$NP]=$k; fi
  done
  [ "$NP" -gt 0 ] && { echo; echo "  Ya conectado al empezar (se incluye solo):"; resumen_puertos; }

  cat <<'EOF'

  Necesitas una memoria USB 3.0 y otra USB 2.0 (o el mouse).
  Deja el teclado conectado (de preferencia en un puerto USB 2.0 negro de atrás).

  Para CADA puerto de la OptiPlex (frente y atrás, incluido el USB-C):
    1. Mete la memoria USB 3.0 y espera el pitido.
    2. Sácala y mete la USB 2.0 (o el mouse) en el mismo puerto; espera el pitido.
  Teclas: c = el último puerto es USB-C · i = es interno · d = deshacer el último · f = terminar
EOF
  echo
  local prev now key ev
  prev=$(ocupados)
  if [ -n "$SIM" ]; then
    for ev in $SIM; do
      case "$ev" in
        key:*) tecla "${ev#key:}";;
        *) evento_nuevo "$ev";;
      esac
    done
  else
    while true; do
      key=""; read -r -s -n 1 -t 1 key
      case "$key" in f|F) break;; c|C|i|I|d|D) tecla "$key";; esac
      refrescar; now=$(ocupados)
      printf '%s\n' "$prev" > "$TMP/prev.txt"
      # Primero las líneas USB 3 y luego las USB 2.0: un hub USB 3 aparece en las dos a la vez y así se emparejan
      nuevos=$(printf '%s\n' "$now" | grep -vxF -f "$TMP/prev.txt")
      for k in $nuevos; do es_ss "$k" && evento_nuevo "$k"; done
      for k in $nuevos; do es_ss "$k" || evento_nuevo "$k"; done
      prev=$now
    done
  fi
  echo; echo "  Puertos registrados:"; resumen_puertos
  # ¿Faltaron pruebas con la memoria USB 3?
  local ss_total ss_usadas=0 i
  ss_total=$(awk -F'|' '$1=="P" && $4 ~ /30/' "$TMP/usb.txt" | grep -c .)
  for ((i = 1; i <= NP; i++)); do [ -z "${BORRADO[$i]}" ] && [ -n "${SS[$i]}" ] && ss_usadas=$((ss_usadas + 1)); done
  if [ "$ss_usadas" -lt "$ss_total" ]; then
    aviso "OJO: registraste $ss_usadas de $ss_total líneas USB 3. Los puertos USB 3 sin probar con la memoria USB 3.0"
    aviso "funcionarán solo a velocidad USB 2.0. Puedes repetir el script o usar el modo automático (a)."
  fi
}

# Modo automático: todas las líneas que el ACPI le da a macOS, sin conectar nada.
# Si pasan de 15, primero quita las líneas USB 3 de los USB-C (siguen funcionando en USB 2.0).
mapa_automatico() {
  titulo "2/3  Mapa USB automático"
  refrescar
  local k cls con nm
  NP=0
  while IFS='|' read -r t c p cls hex con; do
    [ "$t" = P ] || continue
    k="$c/$p"
    case "$con" in 9|10) tipo=C;; *) tipo=3;; esac
    nuevo_puerto "$tipo" "automático (ACPI: UsbConnector $con)"
    if es_ss "$k"; then SS[$NP]=$k; else HS[$NP]=$k; fi
  done < "$TMP/usb.txt"
  local c n i
  for c in $(grep '^C|' "$TMP/usb.txt" | cut -d'|' -f2); do
    n=$(lineas_de "$c")
    for ((i = 1; i <= NP && n > LIMITE; i++)); do
      [ -z "${BORRADO[$i]}" ] && [ "${PT[$i]}" = C ] && [ -n "${SS[$i]}" ] && [ "${SS[$i]%%/*}" = "$c" ] || continue
      aviso "Quito $(nom "${SS[$i]}") (USB 3 del USB-C): el USB-C queda en USB 2.0"
      BORRADO[$i]=1; n=$((n - 1))
    done
  done
  echo; echo "  Líneas incluidas:"; resumen_puertos
}

# -----------------------------------------------------------------------------
#  Límite de 15 líneas por controlador
# -----------------------------------------------------------------------------
lineas_de() { # $1 ctrlId → número de líneas usadas
  local i n=0
  for ((i = 1; i <= NP; i++)); do
    [ -z "${BORRADO[$i]}" ] || continue
    [ "${HS[$i]%%/*}" = "$1" ] && n=$((n + 1))
    [ "${SS[$i]%%/*}" = "$1" ] && n=$((n + 1))
  done
  echo $n
}

ajustar_limite() {
  local c n i r
  for c in $(grep '^C|' "$TMP/usb.txt" | cut -d'|' -f2); do
    n=$(lineas_de "$c"); [ "$n" -le "$LIMITE" ] && continue
    aviso "$c usa $n líneas y el límite es $LIMITE."
    for ((i = 1; i <= NP && n > LIMITE; i++)); do   # primero: la línea USB 2.0 del USB-C
      [ -z "${BORRADO[$i]}" ] && [ "${PT[$i]}" = C ] && [ -n "${HS[$i]}" ] && [ -n "${SS[$i]}" ] && [ "${HS[$i]%%/*}" = "$c" ] || continue
      aviso "Quito $(nom "${HS[$i]}") (USB 2.0 del USB-C, puerto #$i): el USB-C sigue funcionando con aparatos USB 3."
      HS[$i]=""; n=$((n - 1))
    done
    while [ "$n" -gt "$LIMITE" ]; do
      resumen_puertos
      if [ -n "$SIM" ]; then r=$(for ((i = NP; i >= 1; i--)); do [ -z "${BORRADO[$i]}" ] && [ -n "${HS[$i]}" ] && [ -n "${SS[$i]}" ] && { echo $i; break; }; done)
      else printf '  ¿De qué puerto # quito la línea USB 2.0? (seguirá funcionando con USB 3) '; read -r r; fi
      if [ -n "$r" ] && [ -n "${HS[$r]:-}" ] && [ -z "${BORRADO[$r]}" ]; then aviso "Quito $(nom "${HS[$r]}") del puerto #$r"; HS[$r]=""; n=$((n - 1)); fi
    done
  done
}

# -----------------------------------------------------------------------------
#  3. USBMap.kext
# -----------------------------------------------------------------------------
conector() { case "$1" in 3) echo 3;; 0) echo 0;; C) echo 9;; I) echo 255;; esac; }
xml_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
hecho=""

generar_kext() { # $1 carpeta destino
  local K="$1/USBMap.kext" P="$1/USBMap.kext/Contents/Info.plist" c cls pci clase_merge m i lane hex max nn
  rm -rf "$K"; mkdir -p "$K/Contents"
  clase_merge=AppleUSBHostMergeProperties
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>English</string>
	<key>CFBundleGetInfoString</key>
	<string>Mapa USB generado por mapear.sh en la OptiPlex 7050 el $FECHA</string>
	<key>CFBundleIdentifier</key>
	<string>com.hazur84.optiplex7050.USBMap</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>USBMap</string>
	<key>CFBundlePackageType</key>
	<string>KEXT</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleSignature</key>
	<string>????</string>
	<key>CFBundleVersion</key>
	<string>1.0</string>
	<key>IOKitPersonalities</key>
	<dict>
EOF
    for c in $(grep '^C|' "$TMP/usb.txt" | cut -d'|' -f2); do
      [ "$(lineas_de "$c")" -gt 0 ] || continue
      cls=$(awk -F'|' -v c="$c" '$1=="C" && $2==c {print $3; exit}' "$TMP/usb.txt")
      pci=$(nombre_pci "$c"); [ -n "$pci" ] || pci=XHC
      max=0
      for ((i = 1; i <= NP; i++)); do
        [ -z "${BORRADO[$i]}" ] || continue
        for lane in "${HS[$i]}" "${SS[$i]}"; do
          [ -n "$lane" ] && [ "${lane%%/*}" = "$c" ] || continue
          nn=$(hex_a_num "$(puerto_campo "$lane" 5)"); [ "$nn" -gt "$max" ] && max=$nn
        done
      done
      for m in $MODELOS $(sysctl -n hw.model 2>/dev/null); do
        case " $hecho " in *" $m-$c "*) continue;; esac; hecho="$hecho $m-$c"
        cat <<EOF
		<key>$m-$pci</key>
		<dict>
			<key>CFBundleIdentifier</key>
			<string>com.apple.driver.$clase_merge</string>
			<key>IOClass</key>
			<string>$clase_merge</string>
			<key>IONameMatch</key>
			<string>$pci</string>
			<key>IOProbeScore</key>
			<integer>5000</integer>
			<key>IOProviderClass</key>
			<string>$cls</string>
			<key>IOProviderMergeProperties</key>
			<dict>
				<key>port-count</key>
				<data>$(b64_4 "$(num_a_hex "$max")")</data>
				<key>ports</key>
				<dict>
EOF
        for ((i = 1; i <= NP; i++)); do
          [ -z "${BORRADO[$i]}" ] || continue
          for lane in "${HS[$i]}" "${SS[$i]}"; do
            [ -n "$lane" ] && [ "${lane%%/*}" = "$c" ] || continue
            hex=$(puerto_campo "$lane" 5)
            cat <<EOF
					<key>$(puerto_campo "$lane" 3)</key>
					<dict>
						<key>UsbConnector</key>
						<integer>$(conector "${PT[$i]}")</integer>
						<key>comment</key>
						<string>Puerto #$i: $(desc_tipo "${PT[$i]}") — $(xml_esc "${ET[$i]}")</string>
						<key>port</key>
						<data>$(b64_4 "$hex")</data>
					</dict>
EOF
          done
        done
        cat <<EOF
				</dict>
			</dict>
			<key>model</key>
			<string>$m</string>
		</dict>
EOF
      done
    done
    cat <<'EOF'
	</dict>
	<key>OSBundleRequired</key>
	<string>Root</string>
</dict>
</plist>
EOF
  } > "$P"
  hecho=""
  plutil -lint "$P" >/dev/null || { aviso "ERROR: el Info.plist generado no es válido"; return 1; }
}

# -----------------------------------------------------------------------------
#  Instalación en la EFI desde la que arrancó OpenCore
# -----------------------------------------------------------------------------
encontrar_efi() { # imprime la raíz montada de la EFI
  if [ -n "$EFI_FORZADA" ]; then echo "$EFI_FORZADA"; return; fi
  local bp guid id mp cand=""
  bp=$(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path 2>/dev/null | cut -f2)
  guid=$(printf '%s' "$bp" | sed -n 's/.*GPT,\([0-9A-Fa-f-]\{36\}\).*/\1/p' | tr 'a-f' 'A-F')
  for id in $(diskutil list | awk '/ EFI /{print $NF}'); do
    if [ -n "$guid" ] && diskutil info "$id" | tr 'a-f' 'A-F' | grep -q "$guid"; then cand=$id; break; fi
  done
  if [ -z "$cand" ]; then
    echo "  No pude saber desde qué EFI arrancó OpenCore. Particiones EFI:" >&2
    diskutil list | grep -E '^/dev/| EFI ' >&2
    printf '  Escribe el identificador (ej. disk2s1): ' >&2; read -r cand
  fi
  [ -n "$cand" ] || return 1
  $SUDO diskutil mount "$cand" >/dev/null 2>&1
  mp=$(diskutil info "$cand" | awk -F': +' '/Mount Point/{print $2}')
  [ -n "$mp" ] && echo "$mp"
}

instalar_en_efi() { # $1 carpeta con USBMap.kext
  local M CFG n i bp
  M=$(encontrar_efi) || true
  if [ -z "$M" ] || [ ! -f "$M/EFI/OC/config.plist" ]; then aviso "No encontré EFI/OC/config.plist; el kext quedó en el reporte y lo copias a mano."; return 1; fi
  CFG="$M/EFI/OC/config.plist"
  aviso "EFI: $M"
  local SUDO=$SUDO; [ -w "$CFG" ] && [ -w "$M/EFI/OC/Kexts" ] && SUDO=""
  $SUDO cp "$CFG" "$CFG.antes-usbmap-$FECHA"
  $SUDO rm -rf "$M/EFI/OC/Kexts/USBMap.kext"
  $SUDO cp -RX "$1/USBMap.kext" "$M/EFI/OC/Kexts/" 2>/dev/null || $SUDO cp -R "$1/USBMap.kext" "$M/EFI/OC/Kexts/"
  $SUDO find "$M/EFI/OC/Kexts/USBMap.kext" -name '._*' -delete 2>/dev/null
  n=0; local hay=""
  while bp=$(plutil -extract "Kernel.Add.$n.BundlePath" raw -o - "$CFG" 2>/dev/null); do
    case "$bp" in
      USBPorts.kext|UTBMap.kext|USBToolBox.kext) $SUDO plutil -replace "Kernel.Add.$n.Enabled" -bool NO "$CFG"; aviso "desactivado $bp";;
      USBMap.kext) $SUDO plutil -replace "Kernel.Add.$n.Enabled" -bool YES "$CFG"; hay=1;;
    esac
    n=$((n + 1))
  done
  if [ -z "$hay" ]; then
    $SUDO plutil -insert "Kernel.Add.$n" -xml "<dict><key>Arch</key><string>Any</string><key>BundlePath</key><string>USBMap.kext</string><key>Comment</key><string>Mapa USB de esta OptiPlex ($FECHA)</string><key>Enabled</key><true/><key>ExecutablePath</key><string></string><key>MaxKernel</key><string></string><key>MinKernel</key><string></string><key>PlistPath</key><string>Contents/Info.plist</string></dict>" "$CFG"
  fi
  $SUDO plutil -replace Kernel.Quirks.XhciPortLimit -bool NO "$CFG"
  # Comprobar que de verdad quedó: USBMap activo, XhciPortLimit apagado, kext copiado
  local ok=1 j=0 b
  [ "$(plutil -extract Kernel.Quirks.XhciPortLimit raw -o - "$CFG" 2>/dev/null)" = false ] || ok=""
  [ -f "$M/EFI/OC/Kexts/USBMap.kext/Contents/Info.plist" ] || ok=""
  local activo=""
  while b=$(plutil -extract "Kernel.Add.$j.BundlePath" raw -o - "$CFG" 2>/dev/null); do
    [ "$b" = USBMap.kext ] && [ "$(plutil -extract "Kernel.Add.$j.Enabled" raw -o - "$CFG")" = true ] && activo=1
    j=$((j + 1))
  done
  [ -n "$activo" ] || ok=""
  if [ -n "$ok" ] && plutil -lint "$CFG" >/dev/null; then
    aviso "config.plist actualizado: USBMap.kext activo, XhciPortLimit = false (respaldo: config.plist.antes-usbmap-$FECHA)"
  else
    aviso "ERROR: no se pudo actualizar la EFI (¿permiso o contraseña?); dejo el config como estaba."
    [ -f "$CFG.antes-usbmap-$FECHA" ] && $SUDO cp "$CFG.antes-usbmap-$FECHA" "$CFG"
    return 1
  fi
  EFI_MONTADA="$M"
}

# -----------------------------------------------------------------------------
#  Principal
# -----------------------------------------------------------------------------
echo "mapear.sh $VERSION — Dell OptiPlex 7050"
# Carpeta del reporte: junto al script si se puede escribir; si no, en /tmp
REP="$SCRIPT_DIR/Reportes/$FECHA"
mkdir -p "$REP" 2>/dev/null && touch "$REP/.ok" 2>/dev/null || { REP="/tmp/Reporte-OptiPlex-$FECHA"; mkdir -p "$REP"; }
rm -f "$REP/.ok"

[ -n "$NO_REPORTE" ] || recolectar_reporte "$REP"
MODO="${MAPA_MODO:-}"
if [ -z "$MODO" ]; then
  echo
  echo "  ¿Cómo quieres el mapa USB?"
  echo "    a = automático: todos los puertos que reporta la tarjeta madre, sin conectar nada (recomendado)"
  echo "    g = guiado: pruebas cada puerto con una memoria USB 3.0 y otra USB 2.0"
  printf '  Elige a o g [a]: '; read -r MODO
fi
case "$MODO" in g|G) mapear_usb;; *) mapa_automatico;; esac
ajustar_limite

titulo "3/3  USBMap.kext y EFI"
mkdir -p "$REP/usb"
generar_kext "$REP/usb" || exit 1
{ echo "Mapa USB — $FECHA"; resumen_puertos; echo; cat "$TMP/usb.txt"; } > "$REP/usb/mapa.txt"
ioreg_usb | grep -viE 'serial' > "$REP/usb/ioreg-usb.txt"
for c in $(grep '^C|' "$TMP/usb.txt" | cut -d'|' -f2); do n=$(lineas_de "$c"); [ "$n" -gt 0 ] && aviso "$c: $n de $LIMITE líneas"; done
aviso "USBMap.kext generado en $REP/usb"

EFI_MONTADA=""
instalar_en_efi "$REP/usb"
if [ -n "$EFI_MONTADA" ]; then
  S2=$SUDO; [ -w "$EFI_MONTADA" ] && S2=""
  $S2 mkdir -p "$EFI_MONTADA/Reportes-OptiPlex" && $S2 cp -R "$REP" "$EFI_MONTADA/Reportes-OptiPlex/" 2>/dev/null && \
    aviso "Copia del reporte en la EFI: Reportes-OptiPlex/$FECHA"
fi

titulo "LISTO"
echo "  Reporte completo: $REP"
echo "  Reinicia la OptiPlex para usar el mapa USB nuevo."
echo "  Si algo falla, en OpenCore vuelve al config.plist.antes-usbmap-$FECHA (está en EFI/OC)."
