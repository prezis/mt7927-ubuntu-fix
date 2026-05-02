#!/bin/bash
# Fix MT7927 WiFi after suspend/resume or boot
# The chip often hangs (CHIPID=0xffff, MCU idle timeout, err -110)
#
# History:
#   v1 (2026-03-24): initial — modprobe -r → pci remove → pci rescan → modprobe
#                    BUG: rescan is async, modprobe ran before device re-enumerated,
#                    driver registered with no device, no probe ever fired.
#   v2 (2026-05-02): reorder + explicit udevadm settle + readiness loops.

set -u

PCI_ADDR=$(lspci -d 14c3:7927 -n 2>/dev/null | awk '{print $1}')

if [ -z "$PCI_ADDR" ]; then
    logger "mt7927-resume-fix: MT7927 device not found in lspci, triggering PCI rescan"
    echo 1 > /sys/bus/pci/rescan
    udevadm settle --timeout=10 2>/dev/null
    PCI_ADDR=$(lspci -d 14c3:7927 -n 2>/dev/null | awk '{print $1}')
    if [ -z "$PCI_ADDR" ]; then
        logger "mt7927-resume-fix: MT7927 still not found after rescan, giving up"
        exit 1
    fi
fi

FULL_ADDR="0000:${PCI_ADDR}"

# If a netdev is already present and not down, assume the chip is fine.
IFACE=$(ls "/sys/bus/pci/devices/${FULL_ADDR}/net/" 2>/dev/null | head -1)
if [ -n "$IFACE" ]; then
    STATE=$(cat "/sys/class/net/${IFACE}/operstate" 2>/dev/null)
    if [ "$STATE" != "down" ] && [ "$STATE" != "" ]; then
        logger "mt7927-resume-fix: WiFi interface ${IFACE} already in state '${STATE}', skipping reset"
        rfkill unblock wifi 2>/dev/null
        exit 0
    fi
fi

logger "mt7927-resume-fix: resetting WiFi chip at ${FULL_ADDR}..."

# 1. Unload the entire mt76 stack so the next modprobe is a fresh registration.
modprobe -r mt7925e mt7925_common mt792x_lib mt76_connac_lib mt76 2>/dev/null
sleep 1

# 2. Hot-remove the PCI device.
if [ -e "/sys/bus/pci/devices/${FULL_ADDR}/remove" ]; then
    echo 1 > "/sys/bus/pci/devices/${FULL_ADDR}/remove" 2>/dev/null
fi
sleep 2

# 3. Rescan and BLOCK until enumeration finishes.
echo 1 > /sys/bus/pci/rescan
udevadm settle --timeout=10 2>/dev/null

# 4. Wait until the device file is back (max 5 s).
for _ in 1 2 3 4 5; do
    [ -e "/sys/bus/pci/devices/${FULL_ADDR}" ] && break
    sleep 1
done
if [ ! -e "/sys/bus/pci/devices/${FULL_ADDR}" ]; then
    logger "mt7927-resume-fix: device did not return after rescan, giving up"
    exit 2
fi

# 5. Now load the driver. With the device already enumerated, pci_register_driver
#    matches the alias immediately and probe() fires on the right device.
modprobe mt7925e
udevadm settle --timeout=5 2>/dev/null

# 6. Wait for the netdev to appear (firmware load takes ~700 ms).
IFACE=""
for _ in 1 2 3 4 5 6 7 8; do
    IFACE=$(ls "/sys/bus/pci/devices/${FULL_ADDR}/net/" 2>/dev/null | head -1)
    [ -n "$IFACE" ] && break
    sleep 1
done

rfkill unblock wifi 2>/dev/null

if [ -n "$IFACE" ]; then
    logger "mt7927-resume-fix: done (iface=${IFACE})"
else
    logger "mt7927-resume-fix: WARN — driver loaded but no netdev appeared; check 'dmesg | grep mt79'"
    exit 3
fi
