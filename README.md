# MediaTek MT7927 WiFi on Linux (Ubuntu 24.04+)

The MT7927 (WiFi 7, PCI ID `14c3:7927`) is not supported by stock Ubuntu kernels as of 6.17. The `mt7925e` driver loads but doesn't bind — no PCI ID match, no firmware.

This repo provides a working DKMS package + firmware + a resume fix service.

## Tested on

| Component | Details |
|-----------|---------|
| Chip | MediaTek MT7927 (Foxconn subsystem `105b:e124`) |
| Motherboard | ASUS ProArt X870E-CREATOR WIFI |
| OS | Ubuntu 24.04.4 LTS (Noble Numbat) |
| Kernel | 6.17.0-19-generic |

## What's included

- **DKMS package** — patches the `mt76` driver (from openwrt/mt76) to add MT7927 support, compiles against your running kernel, auto-rebuilds on kernel updates
- **Firmware files** — extracted from MediaTek's driver package via `extract_firmware.py`
- **Resume fix service** — systemd service that resets the WiFi chip after suspend/resume (the MT7927 tends to hang with `MCU idle timeout` after wakeup)

## Install

### 1. Install DKMS driver

```bash
sudo cp -r dkms/mediatek-mt7927-2.7 /usr/src/
sudo dkms install mediatek-mt7927/2.7
```

### 2. Install firmware

```bash
sudo mkdir -p /lib/firmware/mediatek/mt7927
sudo cp firmware/mt7927/* /lib/firmware/mediatek/mt7927/
```

### 3. Load driver

```bash
sudo modprobe mt7925e
```

If the chip doesn't respond (check `dmesg` for `CHIPID=0xffff` or `MCU idle timeout`), do a PCI reset:

```bash
PCI_ADDR=$(lspci -d 14c3:7927 -n | awk '{print $1}')
sudo sh -c "echo 1 > /sys/bus/pci/devices/0000:${PCI_ADDR}/remove"
sleep 2
sudo sh -c "echo 1 > /sys/bus/pci/rescan"
sudo modprobe mt7925e
```

### 4. Install resume fix (recommended)

The MT7927 often hangs after suspend/resume. This service auto-resets it:

```bash
sudo cp resume-fix/mt7927-resume-fix.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/mt7927-resume-fix.sh
sudo cp resume-fix/mt7927-resume-fix.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable mt7927-resume-fix.service
```

## Extracting firmware yourself

If you have a MediaTek driver ZIP or `mtkwlan.dat`:

```bash
python3 dkms/mediatek-mt7927-2.7/extract_firmware.py <driver.zip or mtkwlan.dat> firmware/mt7927/
```

## Known issues

- After suspend/resume the chip may hang (`CHIPID=0xffff`, `MCU idle timeout`, error -110). The resume fix service handles this automatically.
- `mac_reset not supported` messages in dmesg are normal — the driver falls back to PCI reset.
- Bluetooth firmware (`BT_RAM_CODE_MT6639_2_1_hdr.bin`) is not included yet.

## How it works

The DKMS package applies 13 patches to the mt76 driver that:
1. Add MT7927 PCI device ID
2. Add MT7927 firmware paths (uses MT6639 firmware internally)
3. Add chip-specific DMA, interrupt, and hardware init
4. Enable 320MHz (WiFi 7) bandwidth support
5. Enable low power support

## License

The mt76 driver patches are under the same license as the upstream [openwrt/mt76](https://github.com/openwrt/mt76) project (Dual BSD/GPL).
