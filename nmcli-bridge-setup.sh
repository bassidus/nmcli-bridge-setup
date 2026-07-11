#!/bin/bash

# Toggles a NetworkManager bridge (br0) on a physical interface, giving VMs
# direct LAN access via virt-manager.
#
# Run once before starting a VM to bring the bridge up, run again to tear it
# down and restore the previous connection. The bridge never autoconnects,
# so a reboot always comes back on the normal ethernet connection.

set -euo pipefail

BRIDGE="br0"
PHYS_IF=""
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/nmcli-bridge-setup.state"

usage() {
    cat <<EOF
Usage: $0 [--help]

Toggles the bridge $BRIDGE:
  - If $BRIDGE does not exist: creates it, enslaves a physical Ethernet
    interface and activates it. Your existing connection profile is kept
    (only deactivated) and is restored on the next run.
  - If $BRIDGE exists: tears it down and reactivates the previous connection.

Run it before starting a VM, and again when you are done.

Note: Wi-Fi interfaces cannot be bridged in infrastructure mode (kernel limitation).
EOF
}

if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
    usage
    exit 0
fi

if ! command -v nmcli &>/dev/null; then
    echo "NetworkManager is not installed. Install it and try again."
    exit 1
fi

# Prompt the user to pick from NM-managed ethernet interfaces.
# Sets the global PHYS_IF. Exits if no interfaces found or selection is invalid.
select_interface() {
    mapfile -t IFACES < <(nmcli -g DEVICE,TYPE device status | awk -F: '$2 == "ethernet" {print $1}')

    if [[ ${#IFACES[@]} -eq 0 ]]; then
        echo "No Ethernet interfaces found."
        echo "(Wi-Fi cannot be bridged — use NAT networking in virt-manager instead.)"
        exit 1
    fi

    if [[ ${#IFACES[@]} -eq 1 ]]; then
        PHYS_IF="${IFACES[0]}"
        read -rp "Interface: $PHYS_IF — confirm? [Y/n]: " CONFIRM
        if [[ ${CONFIRM:-Y} =~ ^[Nn] ]]; then echo "Aborted."; exit 1; fi
    else
        echo "Available Ethernet interfaces:"
        nmcli -g DEVICE,TYPE,STATE device status | awk -F: '$2 == "ethernet" {printf "  %-15s %s\n", $1, $3}'
        read -rp "Enter physical interface (e.g. enp4s0): " PHYS_IF
        if ! printf '%s\n' "${IFACES[@]}" | grep -qx "$PHYS_IF"; then
            echo "Invalid interface: $PHYS_IF"
            exit 1
        fi
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

# Delete the bridge and slave profiles, then reactivate whatever connection was
# active before the bridge was brought up. Used both for the normal "toggle off"
# path and as an ERR trap (automatic rollback if setup fails halfway).
bridge_down() {
    # Derive the enslaved interface from the slave profile if PHYS_IF is unset.
    if [[ -z "$PHYS_IF" ]]; then
        PHYS_IF=$(nmcli -g NAME con show | sed -n "s/^bridge-slave-//p" | head -n1)
    fi

    echo "Bringing down bridge $BRIDGE..."
    nmcli con down "$BRIDGE" 2>/dev/null || true
    nmcli con delete "$BRIDGE" 2>/dev/null || true

    if [[ -n "$PHYS_IF" ]]; then
        nmcli con down "bridge-slave-$PHYS_IF" 2>/dev/null || true
        nmcli con delete "bridge-slave-$PHYS_IF" 2>/dev/null || true
    fi

    # Reactivate the connection that was active before the bridge, if we know it.
    local old_con=""
    [[ -f "$STATE_FILE" ]] && old_con=$(<"$STATE_FILE")
    rm -f "$STATE_FILE"

    if [[ -n "$old_con" ]] && nmcli con show "$old_con" &>/dev/null; then
        echo "Reactivating connection '$old_con'..."
        nmcli con up "$old_con"
    elif [[ -n "$PHYS_IF" ]]; then
        echo "Reconnecting $PHYS_IF..."
        nmcli device connect "$PHYS_IF" || true
    fi

    [[ -n "$PHYS_IF" ]] && wait_for_ip "$PHYS_IF"
}

# --- Toggle: if the bridge profile exists, tear it down and exit. ---
if nmcli con show "$BRIDGE" &>/dev/null; then
    bridge_down
    echo "Bridge removed. Normal networking restored."
    exit 0
fi

# --- Otherwise: bring the bridge up. ---

# nmcli permissions are handled by polkit, so root is normally not needed for
# a locally logged-in user — but NetworkManager must already be running.
if ! systemctl is-active --quiet NetworkManager; then
    echo "NetworkManager is not running. Start it and try again:"
    echo "  sudo systemctl start NetworkManager"
    exit 1
fi

select_interface

# Remember which connection is currently active on the interface so it can be
# restored when the bridge is toggled off.
ACTIVE_CON=$(nmcli -g GENERAL.CONNECTION device show "$PHYS_IF" 2>/dev/null || true)
if [[ -n "$ACTIVE_CON" ]]; then
    printf '%s\n' "$ACTIVE_CON" > "$STATE_FILE"
fi

# On error, bridge_down acts as a rollback since PHYS_IF is already set.
trap 'echo "Setup failed. Restoring network on $PHYS_IF..."; bridge_down' ERR

# autoconnect no: the bridge only exists while toggled on and never takes over
# the interface at boot. The original profile keeps its own autoconnect and
# wins again after a reboot or after toggling off.
nmcli con add type bridge ifname "$BRIDGE" con-name "$BRIDGE" \
    stp no \
    ipv4.method auto ipv6.method auto \
    connection.autoconnect no \
    connection.autoconnect-slaves yes
nmcli con add type bridge-slave ifname "$PHYS_IF" master "$BRIDGE" \
    con-name "bridge-slave-$PHYS_IF" \
    connection.autoconnect no

# Bring up slave first — this creates the br0 kernel device.
# Then bring up the bridge master to configure IP on the now-existing device.
echo "Activating bridge $BRIDGE..."
nmcli con up "bridge-slave-$PHYS_IF"
nmcli con up "$BRIDGE"

wait_for_ip "$BRIDGE"
trap - ERR

echo
echo "Bridge $BRIDGE is active. Configure the VM in virt-manager with 'Bridge br0'."
echo "Run this script again to remove the bridge and restore normal networking."
ip addr show "$BRIDGE"
