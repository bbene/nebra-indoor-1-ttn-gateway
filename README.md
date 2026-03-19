# Nebra Indoor Gen 1 → LoRaWAN Gateway

Repurposes a **Nebra Indoor Hotspot Gen 1** (the original CM3-based Helium miner) as a [LoRa Basics Station](https://github.com/lorabasics/basicstation) gateway. Supports [The Things Network](https://www.thethingsnetwork.org/) and [ChirpStack](https://www.chirpstack.io/).

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
- Internet connection on the device
- **One of:**
  - A [TTN account](https://www.thethingsnetwork.org/) with a registered gateway and LNS API key, **OR**
  - A [ChirpStack](https://www.chirpstack.io/) instance with API access and an API token

### For Bare-Metal Deployment

- Fresh Raspberry Pi OS Lite (64-bit) flashed to the CM3's eMMC via `rpiboot`

### For balena Deployment

- Device running [BalenaOS](https://www.balena.io/os/) with the CM3 SPI overlay enabled
- A [balena account](https://www.balena.io/) and fleet created
- `balena` CLI installed locally

## Quick Start

### Option 1: Bare-Metal (systemd)

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

### Option 2: Docker + balena (Recommended for OTA Updates)

Deploy via balena for reproducible builds, OTA updates, and remote management:

```bash
git clone https://github.com/YOURUSER/nebra-ttn-gateway.git
cd nebra-ttn-gateway
balena push <fleet-name>
```

Then set environment variables in the balena dashboard:

| Variable | Value | Scope |
|----------|-------|-------|
| `TTN_CLUSTER` | `nam1`, `eu1`, `au1`, etc. | Fleet |
| `TTN_API_KEY` | Your TTN API key (NNSXS...) | **Device** (per-device secret) |

Finally, enable SPI in balena device configuration:
- Set `BALENA_HOST_CONFIG_dtoverlay` = `spi1-3cs`

The container will:
- Build `basicstation` and `sx1301_softreset` from source at image build time
- Read TTN credentials from environment variables at startup
- Access `/dev/spidev1.2` (SPI) and `/dev/gpiochip0` (GPIO) from the host
- Run the Python launcher with full hardware control

## Network Server Setup

This gateway is compatible with **The Things Network (TTN)** and **ChirpStack**. Choose one:

### The Things Network (TTN)

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

### ChirpStack (Self-Hosted Alternative)

Use this setup with a self-hosted [ChirpStack](https://www.chirpstack.io/) network server instead of TTN:

#### Bare-Metal Setup

When running `setup.sh`, you'll be prompted for:
- **Network server choice:** Select ChirpStack
- **ChirpStack server URL:** e.g., `https://chirpstack.example.com` (your ChirpStack API endpoint)
- **ChirpStack API token:** Generate in ChirpStack admin panel → Gateways

The setup script will:
1. Register or update the gateway in ChirpStack via API
2. Write the ChirpStack connection details to `/opt/ttn-station/tc.uri` and `/opt/ttn-station/tc.key`
3. Configure Basics Station for ChirpStack's MQTT bridge

#### Docker + balena Setup

When deploying via balena, set these environment variables instead:

| Variable | Value | Scope |
|----------|-------|-------|
| `NETWORK_SERVER` | `chirpstack` | Fleet |
| `CHIRPSTACK_URL` | `https://chirpstack.example.com` | Fleet |
| `CHIRPSTACK_API_TOKEN` | Your ChirpStack API token | **Device** (per-device secret) |

The `docker-entrypoint.sh` will detect `NETWORK_SERVER=chirpstack` and configure the connection accordingly.

**Note:** ChirpStack's Basics Station integration requires the gateway to connect via MQTT. Ensure your ChirpStack instance has:
- MQTT broker running (usually integrated)
- Gateway bridge service enabled
- Network server configured to accept Basics Station gateways

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
├── setup.sh                        # Bare-metal setup script
├── start.sh                        # Python launcher (GPIO, LED, button)
├── src/
│   └── sx1301_softreset.c          # SPI soft reset utility (see below)
├── config/
│   └── station.conf                # Basics Station hardware config
├── systemd/
│   └── ttn-station.service         # systemd unit file (bare-metal)
├── Dockerfile                      # Multi-stage Docker build (balena)
├── docker-entrypoint.sh            # Credential initialization (balena)
├── docker-compose.yml              # Service config (local testing)
├── balena.yml                      # balena project metadata
├── .balenaignore                   # balena build artifact exclusion
└── README.md
```

### Bare-Metal Runtime

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

### Container Runtime (balena)

The Dockerfile creates the same structure inside the container at `/opt/ttn-station/`, with credentials written by `docker-entrypoint.sh` from environment variables at startup.

## Network Server Compatibility

The setup is designed to be **provider-agnostic**. Basics Station is a reference gateway implementation that connects to any LoRaWAN network server via standardized protocols:

- **TTN (Default):** Uses TTN's LNS API (WebSocket over TLS)
- **ChirpStack:** Uses MQTT bridge for native integration
- **Other servers:** Any server supporting Basics Station can be configured by:
  1. Modifying `docker-entrypoint.sh` to detect your server type
  2. Setting appropriate `tc.uri` (server endpoint) and `tc.key` (credentials)
  3. Adjusting `config/station.conf` if regional/frequency settings differ

To add support for another network server:
- Fork this repo
- Update `setup.sh` or `docker-entrypoint.sh` to handle your server's auth scheme
- Document the configuration in this README

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

## Using with ChirpStack

All the hardware bring-up work in this repo — the soft reset, `spidev1.2`, `LORAGW_SPI`, 1 MHz SPI speed, the aarch64 build patch — applies identically to ChirpStack. Only the server connection files need to change.

### Option A — Basics Station (recommended)

ChirpStack v4 includes a built-in Basics Station gateway bridge. This is the cleanest approach since the station binary and `station.conf` are already working.

**1. In ChirpStack, enable the Basics Station gateway backend** and note the endpoint — it will be something like:

```
wss://YOUR-CHIRPSTACK-HOST:3001
```

**2. Stop the TTN service:**
```bash
sudo systemctl stop ttn-station
```

**3. Replace `tc.uri`:**
```bash
echo "wss://YOUR-CHIRPSTACK-HOST:3001" > /opt/ttn-station/tc.uri
```

**4. Replace `tc.trust` with your ChirpStack server's CA cert:**
```bash
# If using a self-signed cert, copy it from your ChirpStack server:
scp user@chirpstack-host:/path/to/ca.crt /opt/ttn-station/tc.trust

# If using Let's Encrypt on ChirpStack:
curl -o /opt/ttn-station/tc.trust https://letsencrypt.org/certs/isrgrootx1.pem
```

**5. Replace `tc.key` with your ChirpStack gateway API key:**
```bash
printf "Authorization: Bearer YOUR-CHIRPSTACK-GATEWAY-KEY\n" > /opt/ttn-station/tc.key
```

**6. Restart:**
```bash
sudo systemctl start ttn-station
journalctl -u ttn-station -f
```

### Option B — Semtech UDP Packet Forwarder

If you prefer the older UDP forwarder (simpler, no TLS, works with ChirpStack v3 and v4):

**1. Install the packet forwarder dependencies:**
```bash
sudo apt install -y git build-essential
```

**2. Clone and build:**
```bash
git clone https://github.com/Lora-net/packet_forwarder.git
git clone https://github.com/Lora-net/lora_gateway.git
cd packet_forwarder
make
```

**3. Configure `global_conf.json`** with the US915 FSB2 channel plan and point `server_address` at your ChirpStack gateway bridge (default port 1700).

**4. The same hardware requirements still apply** — you must run `sx1301_softreset` before starting the packet forwarder, and set `LORAGW_SPI=/dev/spidev1.2` and `LORAGW_SPI_SPEED=1000000`.

A minimal wrapper script:
```bash
#!/bin/bash
/opt/ttn-station/sx1301_softreset || exit 1
sleep 0.5
exec env LORAGW_SPI=/dev/spidev1.2 \
         LORAGW_SPI_SPEED=1000000 \
         ./lora_pkt_fwd
```

### Switching back to TTN

```bash
echo "wss://nam1.cloud.thethings.network:8887" > /opt/ttn-station/tc.uri
curl -o /opt/ttn-station/tc.trust https://letsencrypt.org/certs/isrgrootx1.pem
printf "Authorization: Bearer NNSXS.YOUR-TTN-KEY\n" > /opt/ttn-station/tc.key
sudo systemctl restart ttn-station
```

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
