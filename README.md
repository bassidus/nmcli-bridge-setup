# bridge_setup

A small Bash helper script for setting up a NetworkManager bridge on CachyOS systems using `nmcli`.

## What it does

- Ensures `NetworkManager` is running.
- Lists available Ethernet interfaces with their connection state and prompts for a selection.
- Blocks Wi-Fi interfaces — bridging does not work in 802.11 infrastructure mode.
- Removes all existing connections on the selected interface before creating the bridge, to avoid IP conflicts.
- Creates a bridge interface named `br0` with STP disabled.
- Adds the selected interface as a bridge slave.
- Inherits the physical interface's MAC address so existing DHCP reservations on the router are preserved.
- Configures automatic IPv4/IPv6 addressing and enables autoconnect so the bridge persists after reboot.
- Brings up the bridge and verifies an IP address was assigned.
- Rolls back automatically if setup fails partway through, restoring network connectivity.
- Offers a `--remove` flag to tear down the bridge and restore a plain Ethernet connection.

## Requirements

- `bash`
- `nmcli` (NetworkManager CLI)
- `systemctl`
- Root privileges

## Usage

1. Make the script executable (if needed):

```bash
chmod +x bridge_setup.sh
```

2. Run the script as root:

```bash
sudo ./bridge_setup.sh
```

3. Follow the prompt and select the physical Ethernet interface (for example `enp4s0`).

4. After setup, configure your VM in `virt-manager` to use **Bridge br0**.

## Remove the bridge

To tear down the bridge and restore a plain Ethernet connection on the physical interface:

```bash
sudo ./bridge_setup.sh --remove
```

> **Note:** If a NetworkManager profile already exists for the physical interface, it will be reused. A new profile is only created if none is found.

## Disclaimer

This script is provided as-is. I do not take responsibility for any damage, data loss, or network disruption that may occur from using it. Test it carefully and make backups of your network configuration before running it in a production environment.

## License

This repository is licensed under the MIT License. See [LICENSE](LICENSE) for details.
