#!/bin/bash
set -e

NETWORK_SERVER="${NETWORK_SERVER:-ttn}"

case "$NETWORK_SERVER" in
    ttn)
        # The Things Network (default)
        : "${TTN_CLUSTER:?TTN_CLUSTER env var is required (e.g. nam1, eu1, au1)}"
        : "${TTN_API_KEY:?TTN_API_KEY env var is required (NNSXS.xxx...)}"

        echo "Configuring for The Things Network (cluster: ${TTN_CLUSTER})..."
        echo "wss://${TTN_CLUSTER}.cloud.thethings.network:8887" > /opt/ttn-station/tc.uri
        printf 'Authorization: Bearer %s\n' "${TTN_API_KEY}" > /opt/ttn-station/tc.key
        chmod 600 /opt/ttn-station/tc.key

        # Trust cert: use env var override or fetch Let's Encrypt ISRG Root X1
        if [ -n "${TTN_TRUST}" ]; then
            printf '%s\n' "${TTN_TRUST}" > /opt/ttn-station/tc.trust
        else
            curl -fsSL https://letsencrypt.org/certs/isrgrootx1.pem -o /opt/ttn-station/tc.trust
        fi
        ;;

    chirpstack)
        # ChirpStack (self-hosted)
        : "${CHIRPSTACK_URL:?CHIRPSTACK_URL env var is required (e.g. https://chirpstack.example.com)}"
        : "${CHIRPSTACK_API_TOKEN:?CHIRPSTACK_API_TOKEN env var is required}"

        echo "Configuring for ChirpStack (url: ${CHIRPSTACK_URL})..."

        # ChirpStack uses MQTT bridge; construct the connection URI
        # Format: mqtt://[host]:[port] (port defaults to 1883 for unencrypted MQTT)
        CHIRPSTACK_HOST=$(echo "${CHIRPSTACK_URL}" | sed 's|^https://||;s|^http://||;s|:.*||')
        CHIRPSTACK_MQTT_PORT="${CHIRPSTACK_MQTT_PORT:-1883}"

        echo "mqtt://${CHIRPSTACK_HOST}:${CHIRPSTACK_MQTT_PORT}" > /opt/ttn-station/tc.uri
        printf '%s\n' "${CHIRPSTACK_API_TOKEN}" > /opt/ttn-station/tc.key
        chmod 600 /opt/ttn-station/tc.key

        # Use ChirpStack's default CA or custom cert if provided
        if [ -n "${CHIRPSTACK_TRUST}" ]; then
            printf '%s\n' "${CHIRPSTACK_TRUST}" > /opt/ttn-station/tc.trust
        else
            # Most self-hosted ChirpStack instances use self-signed certs or Let's Encrypt
            curl -fsSL https://letsencrypt.org/certs/isrgrootx1.pem -o /opt/ttn-station/tc.trust || true
        fi
        ;;

    *)
        echo "Error: NETWORK_SERVER must be 'ttn' or 'chirpstack', got: ${NETWORK_SERVER}"
        exit 1
        ;;
esac

exec python3 /opt/ttn-station/start.sh
