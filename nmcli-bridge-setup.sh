#!/bin/bash
# Toggles a NetworkManager bridge (br0) that gives VMs direct LAN access:
# run once to bring the bridge up, run again to tear it down and restore the
# previous connection. The bridge never autoconnects, so a reboot always
# comes back on the normal connection.
set -euo pipefail

BRIDGE=br0
STATE="${XDG_RUNTIME_DIR:-/tmp}/nmcli-bridge-setup.state"

[[ "${1:-}" =~ ^(-h|--help)$ ]] && { echo "Usage: $0 — run once to create bridge $BRIDGE, run again to remove it."; exit 0; }

wait_for_ip() {
    echo -n "Waiting for IP"
    for _ in {1..15}; do
        ip addr show "$1" | grep -q 'inet ' && { echo; return; }
        echo -n "."; sleep 1
    done
    echo; echo "Warning: no IPv4 on $1 yet"
}

# Toggle off / rollback: delete the bridge profiles (deleting an active
# profile also deactivates it) and reactivate the previous connection.
bridge_down() {
    local iface old_con=""
    iface=$(nmcli -g NAME con show | sed -n 's/^bridge-slave-//p' | head -n1)
    echo "Bringing down bridge $BRIDGE..."
    nmcli con delete "$BRIDGE" 2>/dev/null || true
    [[ -z "$iface" ]] || nmcli con delete "bridge-slave-$iface" 2>/dev/null || true
    [[ ! -f "$STATE" ]] || { old_con=$(<"$STATE"); rm -f "$STATE"; }
    if [[ -n "$old_con" ]] && nmcli con show "$old_con" &>/dev/null; then
        echo "Reactivating '$old_con'..."
        nmcli con up "$old_con"
    elif [[ -n "$iface" ]]; then
        nmcli device connect "$iface" || true
    fi
    [[ -z "$iface" ]] || wait_for_ip "$iface"
}

if nmcli con show "$BRIDGE" &>/dev/null; then
    bridge_down
    echo "Bridge removed. Normal networking restored."
    exit 0
fi

systemctl is-active --quiet NetworkManager || { echo "NetworkManager is not running: sudo systemctl start NetworkManager"; exit 1; }

# Pick a physical Ethernet interface (Wi-Fi cannot be bridged).
mapfile -t IFACES < <(nmcli -g DEVICE,TYPE device status | awk -F: '$2 == "ethernet" {print $1}')
[[ ${#IFACES[@]} -gt 0 ]] || { echo "No Ethernet interfaces found."; exit 1; }
if [[ ${#IFACES[@]} -eq 1 ]]; then
    PHYS_IF=${IFACES[0]}
    read -rp "Interface: $PHYS_IF — confirm? [Y/n]: " C
    [[ ! ${C:-Y} =~ ^[Nn] ]] || { echo "Aborted."; exit 1; }
else
    printf '  %s\n' "${IFACES[@]}"
    read -rp "Enter physical interface: " PHYS_IF
    printf '%s\n' "${IFACES[@]}" | grep -qx "$PHYS_IF" || { echo "Invalid interface: $PHYS_IF"; exit 1; }
fi

# Remember the active connection so toggle-off can restore it.
ACTIVE_CON=$(nmcli -g GENERAL.CONNECTION device show "$PHYS_IF" 2>/dev/null || true)
[[ -z "$ACTIVE_CON" ]] || printf '%s\n' "$ACTIVE_CON" > "$STATE"

trap 'echo "Setup failed. Rolling back..."; bridge_down' ERR

# Manual down blocks the profile's autoconnect until it is manually
# reactivated — otherwise NM policy steals the interface back mid-activation.
[[ -z "$ACTIVE_CON" ]] || nmcli con down "$ACTIVE_CON"

# autoconnect no: the bridge only exists while toggled on; the original
# profile wins again after a reboot.
nmcli con add type bridge ifname "$BRIDGE" con-name "$BRIDGE" stp no \
    connection.autoconnect no connection.autoconnect-slaves yes
nmcli con add type bridge-slave ifname "$PHYS_IF" master "$BRIDGE" \
    con-name "bridge-slave-$PHYS_IF" connection.autoconnect no

# Slave first creates the br0 kernel device; then the master configures IP on it.
echo "Activating bridge $BRIDGE..."
nmcli con up "bridge-slave-$PHYS_IF"
nmcli con up "$BRIDGE"

wait_for_ip "$BRIDGE"
trap - ERR
echo "Bridge $BRIDGE is up. Use 'Bridge br0' in virt-manager. Run again to remove it."
