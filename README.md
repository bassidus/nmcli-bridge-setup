# nmcli-bridge-toggle

A small Bash helper script that toggles a NetworkManager bridge (`br0`) on and off using `nmcli` — run it once before starting a VM to bring the bridge up, and again when you're done to restore normal networking.

## What it does

The script is a toggle:

**When no bridge exists (toggle on):**

- Checks that `NetworkManager` is running.
- Lists available Ethernet interfaces with their connection state and prompts for a selection (Wi-Fi is excluded — bridging does not work in 802.11 infrastructure mode).
- Remembers which connection is currently active on the interface, so it can be restored later. Your existing profile is kept untouched — only deactivated while the bridge is up.
- Creates a bridge named `br0` with STP disabled and adds the selected interface as a bridge slave.
- Configures automatic IPv4/IPv6 addressing with autoconnect **disabled** — the bridge never takes over the interface at boot, so a reboot always comes back on your normal connection.
- Brings up the bridge and verifies an IP address was assigned.
- Rolls back automatically if setup fails partway through, restoring network connectivity.

**When the bridge already exists (toggle off):**

- Deletes the bridge and slave profiles.
- Reactivates the connection that was active before the bridge was brought up.

## Requirements

- `bash`
- `nmcli` (NetworkManager CLI)
- `systemctl`

Root is normally **not** required: `nmcli` permissions go through polkit, and on most desktop systems a locally logged-in user in an active session may manage system connections without `sudo`. If polkit denies the operation on your system, run the script with `sudo` instead.

## Usage

1. Make the script executable (if needed):

```bash
chmod +x nmcli-bridge-toggle
```

2. Before starting your VM, run the script to bring the bridge up:

```bash
./nmcli-bridge-toggle
```

3. Follow the prompt and select the physical Ethernet interface (for example `enp4s0`).

4. Configure your VM in `virt-manager` to use **Bridge br0**.

5. When you're done with the VM, run the same command again to remove the bridge and restore your previous connection:

```bash
./nmcli-bridge-toggle
```

> **Note:** The previously active connection name is stored in `$XDG_RUNTIME_DIR/nmcli-bridge-toggle.state` (falling back to `/tmp`). Since that directory is cleared on reboot and the bridge never autoconnects, a reboot with the bridge still up simply brings the system back on the normal connection — though the leftover `br0` profiles will be deleted the next time the script runs.

## Disclaimer

This script is provided as-is. I do not take responsibility for any damage, data loss, or network disruption that may occur from using it. Test it carefully and make backups of your network configuration before running it in a production environment.

## License

This repository is licensed under the MIT License. See [LICENSE](LICENSE) for details.
