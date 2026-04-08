# proxmox-scripts

Personal Proxmox VE LXC installer scripts.

---

## Strix — IP Camera Stream Finder

> **Created by [eduard256](https://github.com/eduard256)** — all credit for Strix goes to them. This repo simply provides a Proxmox LXC installer wrapper. Please ⭐ the [original project](https://github.com/eduard256/Strix) if you find it useful!

[Strix](https://github.com/eduard256/Strix) automatically finds working RTSP/HTTP streams for IP cameras and generates ready-to-use Frigate/go2rtc configs. Tests 102K+ URL patterns in ~30 seconds across 67K+ camera models.

### Prerequisites

- Proxmox VE 8.x running on the host
- A configured Linux bridge (default: `vmbr0`) with internet access
- `local` storage for templates, `local-lvm` (or equivalent) for the container disk
- Internet access from the Proxmox host

### Install

> **Security note:** Always review scripts before running them as root.
> You can read this one at [ct/strix.sh](ct/strix.sh) and [ct/strix-install.sh](ct/strix-install.sh) before running.

Run this in your **Proxmox VE shell**:

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MichShav/proxmox-scripts/main/ct/strix.sh)"
```

**LXC defaults:**

| Setting    | Value                                |
|------------|--------------------------------------|
| OS         | Debian 12                            |
| CPU        | 2 cores                              |
| RAM        | 1024 MB                              |
| Disk       | 8 GB                                 |
| Privileged | Yes (required for Docker)            |
| Port       | `4567`                               |

After install, open: `http://<LXC-IP>:4567`

### How it works

The installer creates a privileged Debian 12 LXC, installs Docker inside it, and runs Strix as a Docker container — matching the [official install method](https://github.com/eduard256/Strix#quick-start-). No standalone binary is used.

### Update

Inside the Strix LXC:

```
strix-update
```

### Useful commands

```bash
# View logs
docker logs -f strix

# Restart Strix
docker restart strix

# Stop Strix
docker stop strix

# Start Strix
docker start strix

# Check container status
docker ps

# Enter the LXC from Proxmox host
pct exec <CT_ID> -- bash
```

### Troubleshooting

**Container won't start / bridge error:**
Make sure `vmbr0` (or your chosen bridge) exists. Check with `ip link show`. If you're on WiFi-only, you'll need a NAT bridge — see the [Proxmox wiki](https://pve.proxmox.com/wiki/Network_Configuration).

**Docker daemon not starting:**
The LXC must be **privileged** with `nesting=1,keyctl=1` features enabled. The installer sets this automatically.

**Strix not accessible from LAN:**
If using a NAT bridge (e.g. `10.10.10.x`), add a port forward on the Proxmox host:
```bash
iptables -t nat -A PREROUTING -i <your-interface> -p tcp --dport 4567 -j DNAT --to-destination <container-ip>:4567
iptables -A FORWARD -p tcp -d <container-ip> --dport 4567 -j ACCEPT
```
