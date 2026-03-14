# Nebra Indoor Gen 1 → TTN LoRaWAN Gateway

Repurposes a **Nebra Indoor Hotspot Gen 1** (the original CM3-based Helium miner) as a [LoRa Basics Station](https://github.com/lorabasics/basicstation) gateway connected to [The Things Network](https://www.thethingsnetwork.org/).

## Hardware

| Component | Details |
|-----------|---------|
| SBC | Raspberry Pi Compute Module 3 (CM3) |
| OS | Debian 13 Trixie (aarch64) |
| Concentrator | MaxIoT GL5712-UX |
| Baseband | Semtech SX1301 |
| RF front-end | 2× Semtech SX1257 |
| Frequency | US915 (902–928 MHz, FSB2 for TTN) |

## Prerequisites

- Nebra Indoor Hotspot Gen 1 (CM3-based, **not** the Rock Pi version)
- Fresh Raspberry Pi OS Lite (64-bit) flashed to the CM3's eMMC via `rpiboot`
- A TTN account with a registered gateway and LNS API key
- Internet connection on the device

## Quick Start

```bash
git clone https://github.com/YOURUSER/nebra-ttn-gateway.git
cd nebra-ttn-gateway
sudo bash setup.sh
```

The script will:
1. Prompt for your TTN API key and cluster
2. Install dependencies
3. Enable the SPI1 overlay in `config.txt`
4. Build `sx1301_softreset` (see [Why](#why-sx1301_softreset))
5. Clone and build LoRa Basics Station
6. Write all config files to `/opt/ttn-station/`
7. Install and enable the `ttn-station` systemd service

If SPI wasn't already enabled, it will offer to reboot automatically.

## TTN Console Setup

Before running the script, register your gateway in the [TTN Console](https://console.cloud.thethings.network):

1. **Find your Gateway EUI** — derived from the ethernet MAC address:
   ```bash
   python3 -c "
   mac = open('/sys/class/net/eth0/address').read().strip()
   p = mac.split(':')
   print((p[0]+p[1]+p[2]+'FFFE'+p[3]+p[4]+p[5]).upper())
   "
   ```

2. **Register the gateway:**
   - Gateway EUI: (from above)
   - Frequency plan: `United States 902-928 MHz, FSB 2 (used by TTN)`
   - ✅ Require authenticated connection

3. **Create an API key:**
   - Go to your gateway → API Keys → Add API Key
   - Grant right: **Link as Gateway to a Gateway Server for traffic exchange**
   - Copy the key — you cannot view it again

## Monitoring

```bash
# Live logs
journalctl -u ttn-station -f

# Service status
sudo systemctl status ttn-station

# Restart
sudo systemctl restart ttn-station
```

A healthy startup looks like:

```
After soft reset VERSION=0x67 (expect 0x67)
[RAL:INFO] Concentrator started (3s440ms)
[S2E:INFO] Configuring for region: US915 -- 923.0MHz..928.0MHz
```

## Repository Structure

```
nebra-ttn-gateway/
├── setup.sh                        # Interactive setup script
├── src/
│   └── sx1301_softreset.c          # SPI soft reset utility (see below)
├── config/
│   └── station.conf                # Basics Station hardware config
├── systemd/
│   └── ttn-station.service         # systemd unit file
└── README.md
```

The setup script writes the following to `/opt/ttn-station/`:

```
/opt/ttn-station/
├── sx1301_softreset    # compiled binary
├── start.sh            # startup wrapper
├── station.conf        # hardware config
├── tc.uri              # TTN server URI
├── tc.key              # API key (600 permissions)
└── tc.trust            # CA certificate
```

## Non-Obvious Hardware Quirks

These are undocumented issues discovered through debugging that are not covered in any existing guide:

### 1. SPI bus is `spidev1.2`, not `spidev0.0`

The GL5712 concentrator is wired to SPI bus 1, chip select 2. The kernel does not expose this by default. The `dtoverlay=spi1-3cs` overlay must be added to `config.txt`.

### 2. `LORAGW_SPI` env var, not `RADIODEV`

The SX1301 HAL (`loragw_spi.native.c`) reads the `LORAGW_SPI` environment variable to determine the SPI device path. The `RADIODEV` variable commonly referenced in documentation is silently ignored by this HAL. Since `sudo` strips environment variables, it must be set via `exec env` inside the startup script.

### 3. SPI speed must be 1 MHz

The HAL defaults to 8 MHz (`LORAGW_SPI_SPEED`). At 8 MHz, the SPI1 auxiliary bus on the CM3 produces unreliable reads (version register returns 0x00). Setting `LORAGW_SPI_SPEED=1000000` (1 MHz) resolves this. The SX1301 comfortably supports this speed.

### 4. SX1301 requires a SPI soft reset after every power-up

After power-up, the SX1301 returns `0x03` on the version register instead of the expected `0x67`. The HAL reads the version register immediately after opening SPI and fails with `FAIL TO CONNECT BOARD`. Writing `0x80` to register `0x00` (the SOFT_RESET bit) and waiting 200 ms causes the chip to initialise correctly. This is what `sx1301_softreset` does.

### 5. Build platform must be `rpi`, not `linuxpico`

The `linuxpico` platform uses the smtcpico HAL, which treats the device as a serial/UART port and calls `tcgetattr()` on the SPI device — this always fails. The `rpi` platform has the correct SPI HAL for the SX1301.

### 6. `setup.gmk` must be patched for aarch64

Debian 13 on the CM3 runs 64-bit aarch64, but basicstation's `setup.gmk` only lists `arm-linux-gnueabihf` as a valid native arch for the `rpi` platform. The setup script patches line 47 automatically.

### 7. The SSL drop on INFOS connection is normal

Basics Station connects to an INFOS endpoint first to receive the MUXS redirect URL. TTN closes this connection after responding — the `Recv failed: SSL` log entry is expected protocol behavior, not an authentication failure. The gateway connects to MUXS immediately after.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `/dev/spidev1.2` missing | SPI1 overlay not loaded | Check `dtoverlay=spi1-3cs` in `config.txt`, reboot |
| `FAIL TO CONNECT BOARD` | Soft reset not running | Run `/opt/ttn-station/sx1301_softreset` manually |
| Version register = `0x00` | Wrong SPI device | Verify `LORAGW_SPI=/dev/spidev1.2` |
| Version register = `0x03` | Chip not soft-reset | Power cycle, then run soft reset |
| SSL drop on every connect | Normal | Not an error — see quirk #7 above |
| `tc.key` auth failure | Wrong key format or rights | Re-create key in TTN console with traffic exchange right |
| Build fails `NO-TOOLCHAIN-FOUND` | aarch64 not patched | Check `setup.gmk` line 47 |

## License

MIT
