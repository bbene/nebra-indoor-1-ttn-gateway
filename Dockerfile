# Multi-stage Dockerfile for Nebra TTN Gateway
# Targets linux/arm64 (CM3 running 64-bit BalenaOS)

# ---- Stage 1: builder ----
FROM balenalib/raspberrypi3-64-debian:bookworm-build AS builder

RUN install_packages git build-essential libssl-dev

# Build basicstation (aarch64 variant)
WORKDIR /build/basicstation
RUN git clone https://github.com/lorabasics/basicstation.git .
# Patch arch: rpi Makefile targets armhf by default; patch for aarch64
RUN sed -i 's/ARCH.rpi = arm-linux-gnueabihf/ARCH.rpi = aarch64-linux-gnu/' setup.gmk
RUN make platform=rpi variant=std CC=gcc AR=ar LD=ld

# Build sx1301_softreset
COPY src/sx1301_softreset.c /build/
RUN gcc -O2 -o /build/sx1301_softreset /build/sx1301_softreset.c

# ---- Stage 2: runtime ----
FROM balenalib/raspberrypi3-64-debian:bookworm-run

RUN install_packages python3 python3-libgpiod ca-certificates curl

RUN mkdir -p /opt/ttn-station && chmod 1777 /var/tmp

# Binaries
COPY --from=builder /build/basicstation/build-rpi-std/bin/station /opt/ttn-station/station
COPY --from=builder /build/sx1301_softreset /opt/ttn-station/sx1301_softreset

# Config
COPY config/station.conf /opt/ttn-station/station.conf
COPY start.sh /opt/ttn-station/start.sh

# Fix STATION_BIN path to container path
RUN sed -i 's|STATION_BIN  = ".*"|STATION_BIN  = "/opt/ttn-station/station"|' /opt/ttn-station/start.sh

COPY docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /opt/ttn-station/sx1301_softreset /opt/ttn-station/station

CMD ["/entrypoint.sh"]
