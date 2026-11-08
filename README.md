# Dell OptiPlex 7050 SFF — OpenCore EFI (macOS Ventura)

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
