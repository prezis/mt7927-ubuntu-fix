# MediaTek MT7927 WiFi 7 + Bluetooth 5.4 on Ubuntu 24.04+

The MT7927 (combo chip: WiFi 7 PCIe `14c3:7927` + Bluetooth 5.4 USB `0489:e13a` / internal codename **MT6639**) is **not supported** by stock Ubuntu kernels through 6.17 as of May 2026. Stock `mt7925e` has the alias but doesn't bind reliably; stock `btusb` corrupts the BT chip at boot by sending a generic `HCI_Reset` it doesn't understand.

This repo provides a working DKMS package + firmware + a complete fix stack for both halves of the chip.

## Tested on

| Component | Details |
|-----------|---------|
| Chip | MediaTek MT7927 / MT6639 (Foxconn subsystem `105b:e124`) |
| Motherboard | ASUS ProArt X870E-CREATOR WIFI |
| BIOS | 2103 (Mar 9, 2026) |
| OS | Ubuntu 24.04.4 LTS (Noble Numbat) |
| Kernels verified | 6.17.0-19, -20, -22, -23 |

## Quick install (recommended)

```bash
git clone https://github.com/prezis/mt7927-ubuntu-fix.git
cd mt7927-ubuntu-fix

# 1. DKMS driver
sudo cp -r dkms/mediatek-mt7927-2.7 /usr/src/
sudo dkms install mediatek-mt7927/2.7

# 2. Firmware (extract from MediaTek/ASUS driver ZIP if needed)
sudo mkdir -p /lib/firmware/mediatek/mt7927 /lib/firmware/mediatek/mt6639
sudo cp firmware/mt7927/* /lib/firmware/mediatek/mt7927/
sudo cp firmware/mt6639/BT_RAM_CODE_MT6639_2_1_hdr.bin /lib/firmware/mediatek/mt6639/

# 3. Apply the 4-pillar fix stack (see "How it works" below)
sudo bash resume-fix/install-fixes.sh

# 4. BIOS toggles (mandatory — only you can do these, Del at POST):
#    - Fast Boot: DISABLED                 (Advanced -> Boot Configuration)
#    - ErP Ready: Enable(S4+S5)            (Advanced -> APM Configuration)

# 5. Reboot
sudo reboot
```

## How it works — three independent bugs in one chip

### Bug 1: Boot-time race in resume-fix (this repo, fixed in v2)

The original `mt7927-resume-fix.sh` issued `echo 1 > /sys/bus/pci/rescan` (async) followed immediately by `modprobe mt7925e`. The driver registered before PCI re-enumeration completed, so `pci_register_driver` found no matching device, and when the device finally enumerated nothing probed it. **Fixed in v2** with `udevadm settle` + readiness loops.

### Bug 2: WiFi auto-bind regression on kernel ≥ 6.17.0-23

Even with the patched DKMS module installed and signed, `mt7925e` does not auto-probe the `14c3:7927` device on first enumeration on -23. Two-pillar fix forces the binding:

* **`/etc/modprobe.d/mt7925e.conf`** — `install` hook writes the PCI ID into `new_id` on every modprobe
* **`/etc/udev/rules.d/99-mt7927.rules`** — udev `driver_override=mt7925e` for the matching PCI device

Both are belt-and-suspenders; only one is strictly needed but having both eliminates timing edge-cases.

### Bug 3: Bluetooth — three sub-issues

* **3a. Stock `btusb` corruption.** The kernel's stock `btusb` binds to `0489:e13a` by USB class code and sends a generic `HCI_Reset` (opcode `0x0c03`) to MT6639. The chip rejects with `EBUSY (-16)`, enters a corrupted state, and the patched btusb that loads later can't recover. *Mitigation:* DKMS-patched `btusb`/`btmtk` install to `/lib/modules/$kernel/updates/dkms/`, which depmod prefers over `/kernel/drivers/bluetooth/`. Kept correct here.
* **3b. SWIOTLB exhaustion (the "BT works for a few hours then dies" pattern).** The MT6639 firmware patch is 688 KB and uses DMA bounce buffers. Default `swiotlb=64MB` fragments after hours of uptime, the next firmware load fails partway through, the chip's MCU times out (`Bluetooth: hci0: wmt command timed out`) and gets stuck. *Fix:* `swiotlb=65535` kernel cmdline → 512 MB bounce buffer. (Source: [reynold-lariza/CachyOS-ASUS-Pro-Art-X870E-WIFI-and-Bluetooth-fix](https://github.com/reynold-lariza/CachyOS-ASUS-Pro-Art-X870E-WIFI-and-Bluetooth-fix), pillar IV.)
* **3c. USB autosuspend kills the chip.** `enable_autosuspend=Y` on `btusb` puts MT6639 to sleep after idle; chip never wakes back up. *Fix:* `/etc/modprobe.d/btusb.conf` with `options btusb enable_autosuspend=0`.

## Files

| Path | Purpose |
|------|---------|
| `dkms/mediatek-mt7927-2.7/` | DKMS source (snapshot from [jetm/mediatek-mt7927-dkms](https://github.com/jetm/mediatek-mt7927-dkms) at v2.4-era; jetm is now at v2.11) |
| `firmware/mt7927/` | WiFi firmware blobs (MT6639-internal naming) |
| `firmware/mt6639/` | BT firmware blob (`BT_RAM_CODE_MT6639_2_1_hdr.bin`, 688 KB, extracted from `mtkwlan.dat`) |
| `resume-fix/mt7927-resume-fix.sh` | Race-free PCI reset script (v2, May 2026) |
| `resume-fix/mt7927-resume-fix.service` | Systemd unit triggered on suspend/resume/boot |
| `resume-fix/modprobe-mt7925e.conf` | Pillar I: WiFi PCI ID force |
| `resume-fix/udev-99-mt7927.rules` | Pillar II: udev driver_override |
| `resume-fix/modprobe-btusb.conf` | Pillar IV: BT autosuspend off |
| `resume-fix/install-fixes.sh` | One-shot deployment script |

The kernel cmdline change (`swiotlb=65535`) is applied directly in `/etc/default/grub` by `install-fixes.sh` because GRUB cmdline is host-specific.

## BIOS notes (mandatory)

These are non-software requirements for stable BT on the ASUS ProArt X870E (and other boards using the same MT7927/MT6639 module):

* **Fast Boot: DISABLED** — Fast Boot skips USB controller initialization, leaving MT6639 in a half-powered state that the OS can't recover from
* **ErP Ready: Enable(S4+S5)** — without this, "shutdown" only puts the system in S5 with the +5VSB rail keeping MT6639 in a stuck reset state across reboots; Enable(S4+S5) cuts power to the chip, forcing a clean re-init on next boot
* **Secure Boot: keep enabled if it was working** — DKMS modules are signed against your MOK; just don't disable+re-enable Secure Boot without re-enrolling the key

## Verification after install

```bash
uname -r                              # 6.17.0-23-generic (or your current)
cat /proc/cmdline | grep swiotlb      # ...swiotlb=65535
ip -br link | grep wlp                # wlp9s0 UP, BROADCAST,MULTICAST,UP,LOWER_UP
lsusb | grep -i mediatek              # 0489:e13a Wireless_Device
ls /sys/class/bluetooth/              # hci0 directory exists
bluetoothctl show                     # Powered: yes
```

## Known issues / open questions

* **Suspend/resume is still flaky for WiFi**, hence the resume-fix service. The script v2 covers the boot-time path; suspend/resume should also work but report failures on issue tracker if you see them.
* **Live-stream BT pairing under heavy WiFi load** can desync (combo chip shares one antenna feed). Workaround: lower WiFi MCS or use 5/6 GHz to leave 2.4 GHz quiet for BT.
* **Kernel 7.0 prep** — jetm's upstream 2.11 includes a `kmalloc_obj` compat patch for kernel 7.0. If/when Ubuntu jumps to 7.x, upgrade to jetm/mediatek-mt7927-dkms 2.11+ from this fork.

## Upstream / credits

* **DKMS driver source** — originally [jetm/mediatek-mt7927-dkms](https://github.com/jetm/mediatek-mt7927-dkms), packaged at AUR as [`mediatek-mt7927-dkms`](https://aur.archlinux.org/packages/mediatek-mt7927-dkms). Javier Tia documented the [15-month BT journey](https://jetm.github.io/blog/posts/enabling-mt7927-bluetooth-on-linux/) and the [WiFi puzzle](https://jetm.github.io/blog/posts/mt7927-wifi-the-missing-piece/).
* **The 4-pillar fix structure** comes from [reynold-lariza/CachyOS-ASUS-Pro-Art-X870E-WIFI-and-Bluetooth-fix](https://github.com/reynold-lariza/CachyOS-ASUS-Pro-Art-X870E-WIFI-and-Bluetooth-fix), which adapted jetm's work for the same motherboard family.
* **Upstream kernel patches** — Sean Wang (MediaTek), Jean-François Marlière, clemenscodes — see `lkml.org` patch series tracked in `openwrt/mt76` issue [#927](https://github.com/openwrt/mt76/issues/927).
* **Kernel bugzilla** — [#221096](https://bugzilla.kernel.org/show_bug.cgi?id=221096).

This repo's purpose is to provide a **working Ubuntu 24.04 path** that doesn't require AUR / Arch / CachyOS, while keeping firmware extraction, DKMS, and config files version-pinned.

## License

Same as upstream [openwrt/mt76](https://github.com/openwrt/mt76) (Dual BSD/GPL) for driver patches; configs and shell scripts under MIT.
