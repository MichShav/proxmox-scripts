# proxmox-scripts

Personal Proxmox VE LXC installer scripts.

-----

## Strix — IP Camera Stream Finder

> **Created by [eduard256](https://github.com/eduard256)** — all credit for Strix goes to them. This repo simply provides a Proxmox LXC installer wrapper. Please ⭐ the [original project](https://github.com/eduard256/Strix) if you find it useful!

[Strix](https://github.com/eduard256/Strix) automatically finds working RTSP/HTTP streams for IP cameras and generates ready-to-use Frigate/go2rtc configs. Tests 102K+ URL patterns in ~30 seconds across 67K+ camera models.

### Install

Run this in your **Proxmox VE shell**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MichShav/proxmox-scripts/main/ct/strix.sh)"
```

**LXC defaults:**

- OS: Debian 12
- CPU: 1 core
- RAM: 512 MB
- Disk: 4 GB
- Port: `4567`

After install, open: `http://<LXC-IP>:4567`

### Update

Inside the Strix LXC:

```bash
strix-update
```

### Useful commands

```bash
# View logs
journalctl -u strix -f

# Restart service
systemctl restart strix

# Edit config
nano /opt/strix/strix.yaml
```
