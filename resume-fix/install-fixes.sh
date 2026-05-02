#!/bin/bash
# install-fixes.sh — deploy the full MT7927 fix stack
#
# Runs the four pillars from Reynold Lariza's repo + Gemini's autosuspend
# fix + the resume-fix script v2. Idempotent — safe to re-run.
#
# Sources:
#   - github.com/reynold-lariza/CachyOS-ASUS-Pro-Art-X870E-WIFI-and-Bluetooth-fix
#   - github.com/jetm/mediatek-mt7927-dkms (upstream, currently v2.11)
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Run with sudo." >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== I. Modprobe PCI ID force ==="
install -m 0644 "${REPO_DIR}/resume-fix/modprobe-mt7925e.conf" /etc/modprobe.d/mt7925e.conf
echo "   -> /etc/modprobe.d/mt7925e.conf"

echo "=== II. Udev driver_override ==="
install -m 0644 "${REPO_DIR}/resume-fix/udev-99-mt7927.rules" /etc/udev/rules.d/99-mt7927.rules
echo "   -> /etc/udev/rules.d/99-mt7927.rules"

echo "=== III. SWIOTLB kernel cmdline (CRITICAL for BT firmware patch DMA) ==="
if grep -q 'swiotlb=' /etc/default/grub; then
    echo "   swiotlb already present in GRUB — skipping"
else
    cp -a /etc/default/grub /etc/default/grub.bak.$(date +%s)
    sed -i -E 's|^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"|GRUB_CMDLINE_LINUX_DEFAULT="\1 swiotlb=65535"|' /etc/default/grub
    echo "   added swiotlb=65535 to GRUB_CMDLINE_LINUX_DEFAULT"
fi

echo "=== IV. btusb autosuspend off ==="
install -m 0644 "${REPO_DIR}/resume-fix/modprobe-btusb.conf" /etc/modprobe.d/btusb.conf
echo "   -> /etc/modprobe.d/btusb.conf"

echo "=== V. Resume-fix script v2 (race-free at boot) ==="
install -m 0755 "${REPO_DIR}/resume-fix/mt7927-resume-fix.sh" /usr/local/bin/mt7927-resume-fix.sh
echo "   -> /usr/local/bin/mt7927-resume-fix.sh"
if [ -f "${REPO_DIR}/resume-fix/mt7927-resume-fix.service" ]; then
    install -m 0644 "${REPO_DIR}/resume-fix/mt7927-resume-fix.service" /etc/systemd/system/mt7927-resume-fix.service
    systemctl daemon-reload
    systemctl enable mt7927-resume-fix.service
    echo "   service enabled"
fi

echo "=== Reload udev + regenerate GRUB + rebuild initramfs for ALL kernels ==="
udevadm control --reload-rules
udevadm trigger --subsystem-match=pci 2>/dev/null || true
update-grub 2>&1 | tail -3
for k in /lib/modules/*/build; do
    kver=$(basename "$(dirname "$k")")
    update-initramfs -u -k "$kver" 2>&1 | tail -2 || true
done

echo ""
echo "=== DONE ==="
echo "Reboot to activate swiotlb=65535 (kernel cmdline change requires it)."
echo ""
echo "BIOS toggles still required (only you can do these — Del at POST):"
echo "  - Fast Boot: DISABLED  (Advanced -> Boot Configuration)"
echo "  - ErP Ready: Enable(S4+S5)  (Advanced -> APM Configuration)"
echo ""
echo "Verify after reboot:"
echo "  cat /proc/cmdline | grep swiotlb"
echo "  ip -br link | grep wlp"
echo "  lsusb | grep MediaTek"
echo "  bluetoothctl show"
