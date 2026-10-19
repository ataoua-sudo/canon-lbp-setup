# canon-lbp-setup

Installer for Canon **LBP** (CAPT) laser printers on **Ubuntu 16.04 – 26.04**.
It installs the prerequisites, detects the printer over USB (or lets you pick the model), installs the
driver and creates the print queue.

**Supported models (35):** LBP-810, LBP1120, LBP1210, LBP2900, LBP3000, LBP3010, LBP3018, LBP3050, LBP3100,
LBP3108, LBP3150, LBP3200, LBP3210, LBP3250, LBP3300, LBP3310, LBP3500, LBP5000, LBP5050, LBP5100, LBP5300,
LBP6000, LBP6018, LBP6020, LBP6020B, LBP6200, LBP6300, LBP6300n, LBP6310, LBP7010C, LBP7018C, LBP7200C,
LBP7210C, LBP9100C, LBP9200C.

## Requirements

- Ubuntu 16.04 – 26.04, 64-bit (amd64) recommended; root access (`sudo`); internet access for packages.
- A USB cable (or the printer's IP address for network models).
- **Canon's CAPT driver archive** (v2.71, e.g. `linux-capt-drv-v271-uken.tar.gz`), downloaded from
  <https://asia.canon/en/support/0100459601>. Not needed for LBP2900 / LBP3000 when using the built-in
  open-source driver.

Everything else (CUPS, 32-bit libraries, build tools) is installed automatically.

## Installation

1. Download Canon's driver archive and put it **in the same folder as `canon-lbp-setup`**
   (`.tar.gz`, `.tgz`, `.tar.xz` or `.zip`; nothing is downloaded automatically):

   ```
   canon-lbp-setup/
   ├── canon-lbp-setup
   ├── lib/ ...
   └── linux-capt-drv-v271-uken.tar.gz
   ```

2. Run the installer:

   ```bash
   cd canon-lbp-setup
   sudo ./canon-lbp-setup
   ```

3. When asked, switch the printer **on** and connect the **USB cable**. The tool waits until the printer is
   detected (Enter = check now, `s` = choose the model manually, `q` = quit), then installs the driver
   and adds the printer.

4. Print a test page: `lp -d <PrinterName> /usr/share/cups/data/testprint`

## What it does

1. Installs prerequisites: CUPS and tools, the `usblp` module, i386 multiarch and 32-bit libraries.
2. Detects the printer from its USB identification and matches it to a model.
3. Chooses the driver: the built-in open-source driver for LBP2900 / LBP3000, Canon's driver for all others
   (and as an alternative for LBP3000).
4. Installs the driver, registers the print queue, creates a stable USB device name, and starts Canon's
   `ccpd` daemon as the `canon-ccpd` systemd service.
5. Checks the result (missing libraries, daemon, monitor process).

## Commands and options

```
sudo ./canon-lbp-setup [install|detect|list|doctor|fix|uninstall] [options]
```

| Command | Purpose |
|---|---|
| `install` (default) | full installation |
| `detect` | show the detected printer and the driver that would be used |
| `list` | list supported models |
| `doctor` | diagnose an installed Canon driver |
| `fix` | repair an installed Canon driver (restores the 32-bit `libxml2` the monitor needs, restarts `ccpd`) |
| `uninstall` | remove printers and drivers |

| Option | Meaning |
|---|---|
| `--model NAME` | skip detection, e.g. `--model LBP6020B` |
| `--driver auto\|canon\|open` | driver choice (`open`: LBP2900 / LBP3000 only) |
| `--net IP` | network printer (Canon driver) |
| `--name QUEUE` | print queue name (default: model name) |
| `--driver-file FILE` / `--driver-dir DIR` | use a driver archive / folder elsewhere |
| `--no-wait`, `--wait SECONDS` | disable / limit the wait for the printer (with `-y`) |
| `-y`, `--dry-run`, `--force` | no questions / show only / allow other OS |

## Troubleshooting

- Printer not detected: check power and cable, then `lsusb | grep 04a9`.
- Jobs hang or `ccpd` shows one process: `sudo ./canon-lbp-setup fix`, then `sudo ./canon-lbp-setup doctor`.
- Queue stopped after an error: `cupsenable <PrinterName>`; status window: `captstatusui -P <PrinterName>`.
- Logs: `journalctl -u canon-ccpd` and `/var/log/cups/error_log`.

## Notes

- Canon's driver is proprietary and is not included or downloaded by this tool.
- Tested offline (model detection, installation steps in dry-run, driver build). Real-printer behaviour on
  Ubuntu 26.04 may still need adjustment; LBP3000 support in the open-source driver is experimental.

## Layout

```
canon-lbp-setup   main script         lib/        modules
data/models.tsv   model → PPD table   open-driver/ built-in driver sources and PPDs
tests/            offline tests
```

## License

GPL-3.0 – see `COPYING`; authors of the open-source driver are listed in `open-driver/AUTHORS`.
