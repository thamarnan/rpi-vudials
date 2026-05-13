# VU-Server on Raspberry Pi

A one-shot installer that turns a fresh Raspberry Pi OS Lite install into a running [VU-Server](https://github.com/SasaKaranovic/VU-Server) — the API server for [VU dials](https://vudials.com) — that auto-starts on boot and restarts on failure.

---

## Quick install

After flashing **Raspberry Pi OS Lite (64-bit)** and SSHing in:

> 💡 **Plug in your VU Dials HUB *before* running the installer.** The script can run without it, but installing with the hub already connected means everything is ready in one shot — no service restart needed after the install finishes. If you install first and plug in later, just run `sudo systemctl restart vu-server` once the hub is connected.

```bash
sudo bash install-vu-server.sh
```

> ⚠️ Use **`bash`**, not `sh`. Pi OS's `/bin/sh` is `dash`, which doesn't speak the bash features the script relies on.

The script will pause and confirm the hub is detected before continuing. If you're running it non-interactively (e.g. `curl ... | sudo bash`), it will warn and continue without the hub, and you'll just need that one restart after plugging in.

When it finishes, it prints something like:

```
Web UI:     http://192.168.1.42:5340
Local:      http://localhost:5340
```

Open that URL in any browser on your LAN.

---

## What it installs

| Thing | Location |
|---|---|
| App source | `/opt/vu-server/app` |
| Python virtualenv | `/opt/vu-server/app/.venv` |
| systemd unit | `/etc/systemd/system/vu-server.service` |
| udev rule | `/etc/udev/rules.d/99-vu-dials.rules` |
| Update helper | `/usr/local/bin/vu-update` |
| Service user | `vu` (system account, member of `dialout`) |

The service is **enabled on boot** and **auto-restarts on failure** (5-second backoff).

---

## Viewing logs

VU-Server logs go to the systemd journal — there are no log files to hunt for.

**Tail logs live** (Ctrl+C to stop):
```bash
sudo journalctl -u vu-server -f
```

**Show the last 100 lines:**
```bash
sudo journalctl -u vu-server -n 100
```

**Show logs from this boot only:**
```bash
sudo journalctl -u vu-server -b
```

**Show logs since a specific time:**
```bash
sudo journalctl -u vu-server --since "1 hour ago"
sudo journalctl -u vu-server --since "2024-01-15 09:00"
```

**Show only errors:**
```bash
sudo journalctl -u vu-server -p err
```

### File-based log

In addition to the systemd journal, VU-Server writes its own log file. Due to a hardcoded path in the upstream code ([issue #20](https://github.com/SasaKaranovic/VU-Server/issues/20)), this lives at:

```
/home/vu/vudials.log
```

The installer creates `/home/vu` for exactly this reason. View it with:

```bash
sudo tail -f /home/vu/vudials.log
```

For most operational use, the journal is more convenient — but if you need to send the upstream maintainer a log for a bug report, this is the file they'll ask for.

---

## Service control

| Action | Command |
|---|---|
| Status | `sudo systemctl status vu-server` |
| Start | `sudo systemctl start vu-server` |
| Stop | `sudo systemctl stop vu-server` |
| Restart | `sudo systemctl restart vu-server` |
| Reload after config change | `sudo systemctl restart vu-server` |
| Disable auto-start on boot | `sudo systemctl disable vu-server` |
| Re-enable auto-start on boot | `sudo systemctl enable vu-server` |
| Is it enabled? | `systemctl is-enabled vu-server` |
| Is it running? | `systemctl is-active vu-server` |

---

## Updating to the latest version

```bash
sudo vu-update
```

This pulls the latest code from GitHub, refreshes the Python dependencies, and restarts the service. Your SQLite database and `config.yaml` are preserved.

---

## Configuration

Edit `/opt/vu-server/app/config.yaml`, then restart:

```bash
sudo nano /opt/vu-server/app/config.yaml
sudo systemctl restart vu-server
```

Things you might want to change:

- **`master_key`** — change from the default to anything random:
  ```bash
  openssl rand -base64 24
  ```
- **`port`** — defaults to `5340`
- **`hostname`** — set to `127.0.0.1` to make the server local-only, or `0.0.0.0` (default after install) for LAN access

---

## Troubleshooting

**Service won't start — check the logs first:**
```bash
sudo journalctl -u vu-server -n 50 --no-pager
```

**"Permission denied: /dev/ttyUSB0":**
The `vu` user needs to be in the `dialout` group (the installer does this). Verify:
```bash
groups vu
```
Should include `dialout`. If not:
```bash
sudo usermod -aG dialout vu
sudo systemctl restart vu-server
```

**Can't reach the web UI from another machine:**
Check the bind address in `config.yaml` — it must be `0.0.0.0`, not `localhost`. Then check the Pi's firewall (`sudo ufw status` if you installed ufw).

**Find the VU hub:**
```bash
ls -l /dev/ttyUSB* /dev/vu-hub 2>/dev/null
lsusb
```

**The dial isn't responding:**
Unplug and replug the USB hub, wait 5 seconds, then:
```bash
sudo systemctl restart vu-server
```

**Web UI returns "500 Internal Server Error" with `KeyError: 'Content-Type'`:**
This is a Tornado version incompatibility — VU-Server upstream doesn't pin a Tornado version, and Tornado 6.5+ made a breaking change. Fix:
```bash
sudo -u vu /opt/vu-server/app/.venv/bin/pip install "tornado<6.5"
sudo systemctl restart vu-server
```
The installer already does this for fresh installs; you'd only hit it on older installs or after running `vu-update` if upstream hasn't fixed `requirements.txt` yet.

---

## Uninstall

Run the uninstall script (see `uninstall-vu-server.sh` in this repo):

```bash
sudo bash uninstall-vu-server.sh
```

It will ask before deleting your data (the SQLite database and config). Pass `--purge` to skip the prompt and remove everything, or `--keep-data` to keep `/opt/vu-server` intact.

### Manual uninstall

If you'd rather do it yourself:

```bash
# 1. Stop and disable the service
sudo systemctl stop vu-server
sudo systemctl disable vu-server

# 2. Remove systemd unit
sudo rm /etc/systemd/system/vu-server.service
sudo systemctl daemon-reload

# 3. Remove udev rule
sudo rm /etc/udev/rules.d/99-vu-dials.rules
sudo udevadm control --reload-rules

# 4. Remove helper command
sudo rm /usr/local/bin/vu-update

# 5. Remove the application (this deletes your database and config!)
sudo rm -rf /opt/vu-server

# 6. Remove the service user
sudo userdel vu
```

---

## File reference

```
/opt/vu-server/
└── app/
    ├── server.py              # main application
    ├── config.yaml            # your configuration
    ├── *.db                   # SQLite database (dial settings, API keys)
    ├── .venv/                 # Python virtualenv
    └── ...                    # rest of the upstream repo
```

---

## License & credit

VU-Server itself is by [Sasa Karanovic](https://github.com/SasaKaranovic) — see the [upstream repository](https://github.com/SasaKaranovic/VU-Server) for its license. This installer is just glue around it.
