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
- **Bluetooth is UNRESOLVED** — see section below.

## Bluetooth (unresolved)

The MT7927 is a combo chip: WiFi on PCIe, Bluetooth on USB. This repo only fixes the PCIe/WiFi half. The Bluetooth USB interface **does not reliably enumerate** on Linux as of kernel 6.17.0-20-generic.

### Symptoms

- `lsusb -t` shows **no** MediaTek device (VIDs `0e8d`, `0489`, or `13d3` all absent)
- `btusb` module loads but has `0` consumers (nothing binds)
- `rfkill list` shows only WiFi (`phy1`); no `hci0`
- `/sys/class/bluetooth/` is empty
- `bluetoothctl show` returns "No default controller available"
- WiFi works fine via PCIe the whole time

### Partial workaround (unreliable)

A **full AC cold power-cycle** (not `reboot` — actual `poweroff`, wait 20+ seconds, power back on) sometimes makes the BT USB interface enumerate. After that, `btusb` + in-tree `btmtk` bind and BT works. **But it stops working again after the next soft reboot / suspend / kernel event**, and the next cold cycle may or may not bring it back.

### Why this is hard

1. **`btmtk` driver has no MT7927 alias.** `modinfo btmtk` lists BT firmware for MT7925/7961/7922/7668/7663/7622 — no 7927 entry. btmtk only tries to bind if btusb successfully claims a USB interface first.
2. **No `BT_RAM_CODE_MT7927_*` firmware exists** in `linux-firmware` upstream or the MediaTek driver ZIP. The chip may be compatible with MT7925 BT firmware (the `/lib/firmware/mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin` file is present and loadable) — but we can't know without enumeration.
3. **The USB endpoint is gated by the chip's own power state machine.** WiFi coming up via PCIe does not wake the BT USB logic. After a Linux-initiated reboot (vs. full AC cycle), BT stays in a stuck reset state. This matches known MT792x-family behavior on other boards (e.g. reports on linux-mediatek-dev mailing list for MT7922).
4. **Our DKMS patches only touch mt76/mt7925e (WiFi).** They do not expose any hook to power-cycle the USB/BT rail. Adding a BT init sequence likely requires either:
   - a vendor-provided MT7927 BT initializer (not public), or
   - a kernel patch that adds MT7927 USB IDs to btusb and a chip-reset quirk.

### What to try (if you want to help debug)

```bash
# 1. Confirm your BT USB side never appears, even on cold boot:
watch -n 1 'lsusb | grep -iE "mediatek|0e8d|0489|13d3"'
# Then cold-cycle the PSU.

# 2. Check if ASUS BIOS has a separate BT toggle:
# Advanced → Onboard Devices Configuration → Bluetooth Controller
# Or: Advanced → AMD CBS → FCH USB Options

# 3. After a cold boot where BT DOES enumerate, capture:
sudo dmesg | grep -iE 'bluetooth|btusb|btmtk|usb.*new' > /tmp/bt-working.log
lsusb -v -d 0e8d: 2>/dev/null > /tmp/bt-working-lsusb.log  # or vendor that appears

# 4. After BT stops, before rebooting, capture the "dead" state:
sudo dmesg | grep -iE 'bluetooth|btusb|btmtk|usb' > /tmp/bt-dead.log
lsusb -t > /tmp/bt-dead-tree.log

# Attach all 4 files to issue #1 for upstream debugging.
```

Contributions (especially kernel patches or reverse-engineered BT init sequences) welcome — open an issue or PR.

## How it works

The DKMS package applies 13 patches to the mt76 driver that:
1. Add MT7927 PCI device ID
2. Add MT7927 firmware paths (uses MT6639 firmware internally)
3. Add chip-specific DMA, interrupt, and hardware init
4. Enable 320MHz (WiFi 7) bandwidth support
5. Enable low power support

## License

The mt76 driver patches are under the same license as the upstream [openwrt/mt76](https://github.com/openwrt/mt76) project (Dual BSD/GPL).
