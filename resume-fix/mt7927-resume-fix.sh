#!/bin/bash
# Fix MT7927 WiFi after suspend/resume or boot
# The chip often hangs (CHIPID=0xffff, MCU idle timeout)

PCI_ADDR=$(lspci -d 14c3:7927 -n 2>/dev/null | awk '{print $1}')

if [ -z "$PCI_ADDR" ]; then
    logger "mt7927-resume-fix: MT7927 device not found in lspci, triggering PCI rescan"
    echo 1 > /sys/bus/pci/rescan
    sleep 2
    PCI_ADDR=$(lspci -d 14c3:7927 -n 2>/dev/null | awk '{print $1}')
    if [ -z "$PCI_ADDR" ]; then
        logger "mt7927-resume-fix: MT7927 still not found after rescan, giving up"
        exit 1
    fi
fi

FULL_ADDR="0000:${PCI_ADDR}"

# Check if WiFi is already working (interface is UP or DORMANT)
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

modprobe -r mt7925e 2>/dev/null
sleep 1

echo 1 > "/sys/bus/pci/devices/${FULL_ADDR}/remove" 2>/dev/null
sleep 2
echo 1 > /sys/bus/pci/rescan

modprobe mt7925e
rfkill unblock wifi 2>/dev/null

logger "mt7927-resume-fix: done"
