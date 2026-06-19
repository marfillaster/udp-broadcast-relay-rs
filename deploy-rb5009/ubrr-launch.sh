#!/bin/sh
# Launch udp-broadcast-relay-rs (multi-port fork) inside the RouterOS toolbox
# container. Auto-discovers the container's non-loopback interfaces so it does
# not depend on eth0/eth1 naming, then relays SSDP (1900, multicast) and
# Wake-on-LAN (9, broadcast) in a single process.
chmod +x /scripts.d/ubrr 2>/dev/null
DEVS=""
for d in $(grep ':' /proc/net/dev | cut -d: -f1 | tr -d ' '); do
    [ "$d" = "lo" ] && continue
    DEVS="$DEVS --dev $d"
done
echo "ubrr launching with devs:$DEVS"
# info-level: log startup (ports/interfaces) but not per-packet forwards. Add
# -d (and drop RUST_LOG) for verbose packet tracing when debugging.
export RUST_LOG=info
exec /scripts.d/ubrr --id 1 $DEVS \
    --relay 1900:239.255.255.250 \
    --relay 9
