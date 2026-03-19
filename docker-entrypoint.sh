#!/bin/bash
set -e

: "${TTN_CLUSTER:?TTN_CLUSTER env var is required (e.g. nam1, eu1, au1)}"
: "${TTN_API_KEY:?TTN_API_KEY env var is required (NNSXS.xxx...)}"

echo "wss://${TTN_CLUSTER}.cloud.thethings.network:8887" > /opt/ttn-station/tc.uri
printf 'Authorization: Bearer %s\n' "${TTN_API_KEY}" > /opt/ttn-station/tc.key
chmod 600 /opt/ttn-station/tc.key

# Trust cert: use env var override or fetch Let's Encrypt ISRG Root X1
if [ -n "${TTN_TRUST}" ]; then
    printf '%s\n' "${TTN_TRUST}" > /opt/ttn-station/tc.trust
else
    curl -fsSL https://letsencrypt.org/certs/isrgrootx1.pem -o /opt/ttn-station/tc.trust
fi

exec python3 /opt/ttn-station/start.sh
