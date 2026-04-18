#!/bin/bash

# Creates a NetworkManager bridge (br0) and attaches a physical interface as a slave,
# giving VMs direct LAN access via virt-manager.

set -euo pipefail

BRIDGE="br0"
PHYS_IF=""

usage() {
    cat <<EOF
Usage: sudo $0 [--remove] [--help]

  --remove   Tear down the bridge and restore the physical interface.
  --help     Show this help message.

This script creates a NetworkManager bridge interface named $BRIDGE and
adds a physical Ethernet interface as a bridge slave.

Note: Wi-Fi interfaces cannot be bridged in infrastructure mode (kernel limitation).
EOF
}

if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
    usage
    exit 0
fi

if [[ $EUID -ne 0 ]]; then
    echo "This script needs to be run as root: sudo $0"
    exit 1
fi

if ! command -v nmcli &>/dev/null; then
    echo "NetworkManager is not installed. Install it and try again."
    exit 1
fi

# Prompt the user to pick from NM-managed ethernet/wifi interfaces.
# Sets the global PHYS_IF. Exits if no interfaces found or selection is invalid.
select_interface() {
    local prompt="$1"
    mapfile -t IFACES < <(nmcli -g DEVICE,TYPE device status | awk -F: '$2 == "ethernet" || $2 == "wifi" {print $1}')

    if [[ ${#IFACES[@]} -eq 0 ]]; then
        echo "No ethernet or Wi-Fi interfaces found."
        exit 1
    fi

    if [[ ${#IFACES[@]} -eq 1 ]]; then
        PHYS_IF="${IFACES[0]}"
        read -rp "Interface: $PHYS_IF — confirm? [Y/n]: " CONFIRM
        if [[ ${CONFIRM:-Y} =~ ^[Nn] ]]; then echo "Aborted."; exit 1; fi
    else
        echo "Available interfaces:"
        nmcli -g DEVICE,TYPE,STATE device status | awk -F: '$2 == "ethernet" || $2 == "wifi" {printf "  %-15s %s\n", $1, $3}'
        read -rp "$prompt" PHYS_IF
        if ! printf '%s\n' "${IFACES[@]}" | grep -qx "$PHYS_IF"; then
            echo "Invalid interface: $PHYS_IF"
            exit 1
        fi
    fi
}

# Block Wi-Fi interfaces — bridging does not work in 802.11 infrastructure mode.
warn_if_wifi() {
    local iface_type
    iface_type=$(nmcli -g DEVICE,TYPE device status | awk -F: -v dev="$PHYS_IF" '$1 == dev {print $2}')
    if [[ "$iface_type" == "wifi" ]]; then
        echo "Error: $PHYS_IF is a Wi-Fi interface. Bridging does not work in infrastructure mode."
        echo "Use an Ethernet interface, or use NAT networking in virt-manager instead."
        exit 1
    fi
}

# Poll until an IPv4 address appears on an interface, printing dots for progress.
wait_for_ip() {
    local iface="$1"
    echo -n "Waiting for IP"
    for _ in $(seq 15); do
        ip addr show "$iface" | grep -q 'inet ' && { echo; return; }
        echo -n "."
        sleep 1
    done
    echo
    echo "Warning: No IPv4 on $iface yet"
}

# Tear down the bridge and restore a plain ethernet connection on the physical interface.
# Used both for --remove (user-initiated) and as an ERR trap (automatic rollback on failure).
# If PHYS_IF is already set (rollback case), skips the interface prompt.
restore_ethernet() {
    [[ -z "$PHYS_IF" ]] && select_interface "Enter physical interface to restore (e.g. enp4s0): "

    echo "Bringing down bridge..."
    nmcli con down "$BRIDGE" 2>/dev/null || true
    nmcli con delete "$BRIDGE" 2>/dev/null || true

    echo "Removing slave connection..."
    nmcli con down "bridge-slave-$PHYS_IF" 2>/dev/null || true
    nmcli con delete "bridge-slave-$PHYS_IF" 2>/dev/null || true

    echo "Restoring ethernet connection on $PHYS_IF..."
    # Only create a new connection if none exists — avoids clobbering an existing profile.
    nmcli con add type ethernet ifname "$PHYS_IF" con-name "$PHYS_IF" \
        ipv4.method auto ipv6.method auto \
        connection.autoconnect yes 2>/dev/null || true
    nmcli con up "$PHYS_IF" 2>/dev/null || true

    wait_for_ip "$PHYS_IF"
}

if [[ "${1:-}" == "--remove" ]]; then restore_ethernet; echo "Bridge removed. $PHYS_IF restored."; exit 0; fi

# Ensure NetworkManager is running before any nmcli calls.
if ! systemctl is-active --quiet NetworkManager; then
    echo "Starting NetworkManager..."
    systemctl enable --now NetworkManager
fi

select_interface "Enter physical interface (e.g. enp4s0): "
warn_if_wifi

# On error, restore_ethernet acts as a rollback since PHYS_IF is already set.
trap 'echo "Setup failed. Attempting to restore network on $PHYS_IF..."; restore_ethernet' ERR

# Remove all existing connections on this interface before creating the bridge to avoid IP conflicts.
# Loop handles multiple profiles (VLAN, VPN, etc.) — not just the first one found.
while IFS= read -r OLD_CON; do
    [[ -z "$OLD_CON" || "$OLD_CON" == "$BRIDGE" ]] && continue
    echo "Removing old connection: $OLD_CON..."
    nmcli con down "$OLD_CON" 2>/dev/null || true
    nmcli con delete "$OLD_CON" 2>/dev/null || true
done < <(nmcli -g NAME,DEVICE con show | awk -F: -v dev="$PHYS_IF" '$2 == dev {print $1}')

# Create bridge and slave connections; silently no-op if they already exist from a prior run.
nmcli con add type bridge ifname "$BRIDGE" con-name "$BRIDGE" stp no 2>/dev/null || true
nmcli con add type bridge-slave ifname "$PHYS_IF" master "$BRIDGE" con-name "bridge-slave-$PHYS_IF" 2>/dev/null || true

# Configure DHCP and autoconnect on the bridge.
nmcli con mod "$BRIDGE" \
    ipv4.method auto ipv6.method auto \
    connection.autoconnect yes \
    connection.autoconnect-slaves yes

# Bring up slave first — this creates the br0 kernel device.
# Then bring up the bridge master to configure IP on the now-existing device.
echo "Activating bridge $BRIDGE..."
nmcli con up "bridge-slave-$PHYS_IF"
nmcli con up "$BRIDGE"

wait_for_ip "$BRIDGE"
trap - ERR

echo "Bridge $BRIDGE is active and will persist after reboot."
echo "Verification:"
nmcli device status
ip addr show "$BRIDGE"

echo "Bridge ready! Configure VM in virt-manager with 'Bridge br0'."
