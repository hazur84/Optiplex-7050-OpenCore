# Dell OptiPlex 7050 SFF — OpenCore EFI (macOS Ventura)

[![Stars](https://img.shields.io/github/stars/hazur84/OptiPlex-7050-OpenCore?style=flat&logo=github)](https://github.com/hazur84/OptiPlex-7050-OpenCore/stargazers) [![Descargas](https://img.shields.io/github/downloads/hazur84/OptiPlex-7050-OpenCore/total?style=flat&logo=github&label=descargas)](https://github.com/hazur84/OptiPlex-7050-OpenCore/releases) [![OpenCore](https://img.shields.io/badge/OpenCore-1.0.8-blue?style=flat)](https://github.com/acidanthera/OpenCorePkg)

EFI de OpenCore para Dell OptiPlex 7050 SFF (Kaby Lake) con macOS Ventura 13.7.8.

> ⚠️ **Antes de usarla genera tu propio SMBIOS.** Los campos `MLB`, `ROM`, `SystemSerialNumber` y `SystemUUID` están vacíos a propósito (ver [SMBIOS](#smbios)).

## Hardware

| Componente | Modelo | Notas |
|---|---|---|
| CPU | Intel Core i7-7700 (Kaby Lake) | Gestión de energía nativa (SSDT-PLUG) |
| iGPU | Intel HD Graphics 630 | Salida de video (DisplayPort, 4K) |
| dGPU | AMD Radeon RX 550 (Lexa, `0x699F`) | Metal 3 (spoof a `0x67FF`) |
| Audio | Realtek ALC255 | AppleALC, `layout-id` 27 |
| Ethernet | Intel I219-LM | IntelMausi |
| Wi-Fi / BT | Broadcom BCM4360 (`14e4:43a0`) | Nativo |
| NVMe | KIOXIA | NVMeFix |
| USB | Controlador XHC 200 Series | Mapeado con USBMap.kext (15 puertos) |

Mapa USB y lista PCI en [`docs/`](docs).

## Software

| | Versión |
|---|---|
| OpenCore | 1.0.8 (RELEASE) |
| macOS | Ventura 13.7.8 |
| SMBIOS | iMac18,1 |

### Kexts

| Kext | Versión |
|---|---|
| Lilu | 1.7.2 |
| VirtualSMC + SMCProcessor + SMCSuperIO | 1.3.8 |
| WhateverGreen | 1.7.1 |
| AppleALC | 1.9.8 |
| IntelMausi | 1.0.8 |
| NVMeFix | 1.1.3 |
| USBMap | 2.0 (mapa propio del 7050 SFF) |

### ACPI

`SSDT-PLUG`, `SSDT-EC-USBX`, `SSDT-MCHC`

### Drivers UEFI

`OpenRuntime`, `HfsPlus`, `OpenCanopy`, `AudioDxe`, `ResetNvramEntry`

## Arranque

- Selector gráfico (OpenCanopy), timeout de 5 s.
- Solo se muestran los volúmenes de macOS (`ScanPolicy = 19858179`, APFS/HFS en discos internos y USB).
- Recovery y Reset NVRAM están ocultos (`HideAuxiliary`); pulsa **Espacio** en el selector para verlos.
- Sonido de arranque activado (`PlayChime = Enabled`).
- `LauncherOption = Full`: OpenCore se registra en la BIOS.
- Arranque en modo detallado (`-v`); quítalo de `boot-args` si prefieres el logo de Apple.
- SIP activado.

## SMBIOS

1. Descarga [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS) y genera un SMBIOS para **iMac18,1**.
2. En `config.plist → PlatformInfo → Generic`, rellena:
   - `SystemSerialNumber` → Serial
   - `MLB` → Board Serial
   - `SystemUUID` → SmUUID
   - `ROM` → la MAC de tu tarjeta de red, sin `:` (6 bytes)
3. Comprueba en [checkcoverage.apple.com](https://checkcoverage.apple.com) que el serial **no** sea válido.

## Ajustes de BIOS recomendados (Dell)

| Opción | Valor |
|---|---|
| Boot Sequence → Boot List Option | UEFI |
| Secure Boot | Desactivado |
| SATA Operation | AHCI |
| Intel SGX | Desactivado |
| Virtualization (VT-d) | Puede quedar activado (`DisableIoMapper` está activo) |
| Wake on LAN | Desactivado |

El OptiPlex 7050 tiene **CFG Lock** activo y no se puede quitar desde la BIOS, por eso están activados `AppleCpuPmCfgLock` y `AppleXcpmCfgLock`.

## Créditos

- [Acidanthera](https://github.com/acidanthera): OpenCore, Lilu, VirtualSMC, WhateverGreen, AppleALC, IntelMausi, NVMeFix
- [Dortania](https://dortania.github.io/OpenCore-Install-Guide/): guía de instalación
- [CorpNewt](https://github.com/corpnewt): GenSMBIOS

## Compatibilidad con macOS Sonoma (14) y Sequoia (15)

Esta EFI está probada en **macOS Ventura (13)**, pero también puede servir para **Sonoma** y **Sequoia**: el Intel HD 630 (Kaby Lake) y la AMD RX 550 (Polaris) siguen teniendo soporte de gráficos en ambas versiones.

Apple quitó el modelo **iMac18,1** de la lista de compatibles a partir de Sonoma. Para instalar o actualizar elige **una** de estas opciones:

1. **Opción recomendada:** conservar `iMac18,1` y añadir a `boot-args` la opción `revpatch=sbvmm`, para lo cual hace falta **RestrictEvents.kext**. Así Actualización de software ofrece Sonoma y Sequoia. Si el instalador sigue rechazando el equipo, añade también `-no_compat_check`.
2. Cambiar el SMBIOS a **iMac19,1** con GenSMBIOS. Genera seriales nuevos y no reutilices los de otro equipo.

Otros puntos a revisar:

- **Wi-Fi (Broadcom BCM4360):** Apple eliminó los drivers de Wi-Fi Broadcom a partir de Sonoma, así que el Wi-Fi deja de funcionar. Para recuperarlo hacen falta los parches de raíz de [OpenCore Legacy Patcher](https://github.com/dortania/OpenCore-Legacy-Patcher), con SIP parcialmente desactivado y AMFIPass.kext. El Ethernet (IntelMausi) y el Bluetooth siguen funcionando.
- **Kexts y OpenCore:** actualiza Lilu, WhateverGreen, AppleALC, VirtualSMC y OpenCore a sus últimas versiones antes de actualizar macOS.
- **Respaldo:** haz una copia de la EFI que funciona y pruébala desde una USB antes de cambiar la del disco.

> ⚠️ La configuración para Sonoma y Sequoia no se ha probado en este equipo. Si la pruebas, abre un *issue* para comentar el resultado.

## Historial de estrellas

[![Star History Chart](https://api.star-history.com/svg?repos=hazur84/OptiPlex-7050-OpenCore&type=Date)](https://star-history.com/#hazur84/OptiPlex-7050-OpenCore&Date)

Si esta EFI te sirvió, deja una ⭐ en el repositorio.

## Scripts

En [`scripts/`](scripts) hay dos herramientas para macOS (bash, sin dependencias). **Haz un respaldo de tu EFI antes de usarlas.**

### `mapear.sh`: reporte del equipo y mapa USB

Genera un reporte (PCI, gráficas, audio, kexts, ACPI), crea `USBMap.kext`, lo copia a la EFI desde la que arrancó OpenCore y ajusta el `config.plist` (activa USBMap, desactiva USBPorts y quita `XhciPortLimit`), con respaldo del config anterior.

1. Arranca con `XhciPortLimit = true` y sin otro mapa USB activo.
2. Ejecuta `bash scripts/mapear.sh` y elige **a** (automático, todos los puertos del ACPI) o **g** (guiado, probando cada puerto con una memoria USB 3.0 y otra USB 2.0).
3. Reinicia. Si algo falla, restaura `EFI/OC/config.plist.antes-usbmap-<fecha>`.

El reporte se guarda en `Reportes/<fecha>` junto al script y en `Reportes-OptiPlex/` de la EFI. No guarda seriales, UUID ni MAC; aun así, revísalo antes de compartirlo.

### `probar_layouts.sh`: elegir el layout de audio (ALC255)

Prueba uno por uno los `layout-id` de AppleALC: pone `alcid=N`, **reinicia solo**, mide si cargó AppleHDA y pasa al siguiente. Al final deja el mejor en el `config.plist` y restaura los `boot-args`.

    bash scripts/probar_layouts.sh            # empezar (rápido ≈ 25 min, completo ≈ 1 h)
    bash scripts/probar_layouts.sh estado     # ver cómo va
    bash scripts/probar_layouts.sh cancelar   # detener y dejar todo como estaba
    bash scripts/probar_layouts.sh fijar 27   # poner un layout a mano

Mientras corre instala un LaunchDaemon temporal (`/Library/LaunchDaemons/mx.optiplex.probarlayouts.plist`) que se borra al terminar. Para abortar desde el arranque: **Reset NVRAM** en el selector de OpenCore. En este equipo el mejor resultado fue el layout **27**.
