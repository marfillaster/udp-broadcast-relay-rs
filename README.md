UDP Broadcast Relay, in Rust, for Linux / FreeBSD / macOS / pfSense
==========================

This program listens for packets on a specified UDP broadcast port. When
a packet is received, it sends that packet to all specified interfaces
but the one it came from as though it originated from the original
sender.

The primary purpose of this is to allow devices or game servers on separated
local networks (Ethernet, WLAN, VLAN) that use udp broadcasts to find each
other to do so.

This is a rewrite (technically fork) of [udp-broadcast-relay-redux](https://github.com/udp-redux/udp-broadcast-relay-redux)
in Rust for better cross compilation, better error messages, and better command-line handling. The behavior should be entirely
backwards compatible with existing `redux` configurations/installations.

This fork
---------

This is a further fork ([marfillaster/udp-broadcast-relay-rs](https://github.com/marfillaster/udp-broadcast-relay-rs))
that adds a repeatable multi-port `--relay` flag and documents a multi-homed,
cross-VLAN deployment for the **LG ThinQ** app and an **LG webOS TV** (see the
[LG ThinQ example](#lg-webos-tv-via-the-lg-thinq-app-across-vlans) below).

- `--relay PORT[:MCAST[,MCAST...]]` (repeatable) replaces the upstream single
  `--port` / `--multicast`. One process relays several ports at once — e.g.
  `--relay 1900:239.255.255.250 --relay 9` relays SSDP discovery **and** the
  Wake-on-LAN broadcast in a single instance. Translate any upstream example
  below as `--port P --multicast M` → `--relay P:M`.
- `deploy-rb5009/ubrr-launch.sh` is a launcher for running this inside a MikroTik
  RouterOS (RB5009) container: it auto-discovers the container's interfaces and
  relays ports 1900 + 9.

INSTALL
-------

    cargo build --release
    cp target/release/udp-broadcast-relay-rs /some/where

USAGE
-----

```
./udp-broadcast-relay-rs \
    -id id \
    --port <udp-port> \
    --dev eth0 \
    [--dev eth1...] \
    [--multicast 224.0.0.251] \
    [-s <spoof_source_ip>] \
    [-t <overridden_target_ip>]
```

- udp-broadcast-relay-rs must be run as root to be able to create a raw
  socket (necessary) to send packets as though they originated from the
  original sender.
- `id` must be unique number between instances. This is used to set the TTL of
  outgoing packets to determine if a packet is an echo and should be discarded.
- Multicast groups can be joined and relayed with
  `--multicast <group address>`.
- The source address for all packets can be modified with `-s <ip>`. This
  is unusual.
- A special source ip of `-s 1.1.1.1` can be used to set the source ip
  to the address of the outgoing interface.
- A special destination ip of `-t 255.255.255.255` can be used to set the
  overriden target ip to the broadcast address of the outgoing interface.
- `-f` will fork the application to the background.

EXAMPLE
-------

#### mDNS / Multicast DNS (Chromecast Discovery + Bonjour + More)
`./udp-broadcast-relay-rs --id 1 --port 5353 --dev eth0 --dev eth1 --multicast 224.0.0.251 -s 1.1.1.1`

(Chromecast requires broadcasts to originate from an address on its subnet)

#### SSDP (Roku Discovery + More)
`./udp-broadcast-relay-rs --id 1 --port 1900 --dev eth0 --dev eth1 --multicast 239.255.255.250`

(this fork: `./udp-broadcast-relay-rs --id 1 --dev eth0 --dev eth1 --relay 1900:239.255.255.250`)

#### LG webOS TV via the LG ThinQ app across VLANs

The LG **ThinQ** (and "LG TV Plus") mobile apps discover and control a webOS TV
over **SSDP** (UDP 1900 multicast) and wake it with **Wake-on-LAN** (UDP 9
broadcast). When the phone (controller LAN) and the TV sit on **different VLANs**,
none of that crosses the boundary. Run one relay multi-homed in both segments to
bridge it:

`./udp-broadcast-relay-rs --id 1 --dev <lan-iface> --dev <tv-vlan-iface> --relay 1900:239.255.255.250 --relay 9`

- `--relay 1900:239.255.255.250` carries SSDP discovery; `--relay 9` carries the
  WoL magic packet. One process, both ports.
- **Do not pass `-s`.** The original source IP **and port** must be preserved so
  the TV's reply can find its way back to the phone, and so relayed multicast
  advertisements keep the TV's real address.
- In practice the app discovers the TV from the TV's own multicast SSDP
  advertisements (`NOTIFY`) relayed back to the controller LAN; any unicast
  `M-SEARCH` reply returns to the phone via normal inter-VLAN routing.

Requirements / gotchas (learned the hard way):

- **Exactly one SSDP relay may touch these segments.** Two full multicast relays
  on the same VLANs create an amplification loop / packet storm. Run only one.
- **Inter-VLAN routing must allow the return path.** The TV's unicast reply
  (TV VLAN → controller LAN) is a *new* flow with no `RELATED` conntrack entry
  (the request was multicast), so strict firewalls drop it. Allow TV-VLAN →
  controller-LAN replies (see the firewall note below).
- **A flood can wedge the TV's SSDP responder.** If the TV stops appearing even
  while awake, **power-cycle it** (full unplug/replug, not standby) — webOS can
  silently stop answering SSDP after a multicast flood.
- **Wake needs the TV reachable in standby.** WoL only works if the TV keeps its
  NIC alive in standby ("Quick Start+ / Always Ready" + "Mobile TV On" on webOS).
  Over Wi-Fi this is unreliable; a wired connection on the TV VLAN is dependable.
  Verify the TV still answers `ping` while off.

##### MikroTik RouterOS (RB5009) deployment

A RouterOS container attaches to one `veth`, so give the relay one veth in each
segment and let it auto-discover them. `deploy-rb5009/ubrr-launch.sh` enumerates
the container's non-loopback interfaces and runs the relay on ports 1900 + 9.
Sketch (placeholder addresses — controller LAN `192.168.10.0/24`, TV VLAN
`192.168.30.0/24`):

```routeros
/interface/veth/add name=veth-relay-lan  address=192.168.10.9/24  gateway=192.168.10.1
/interface/veth/add name=veth-relay-vlan address=192.168.30.9/24  gateway=192.168.30.1
/interface/bridge/port/add bridge=bridge interface=veth-relay-lan  pvid=1
/interface/bridge/port/add bridge=bridge interface=veth-relay-vlan pvid=30
# add a container from a base/toolbox image with /scripts.d mounted, then:
#   cmd = sh /scripts.d/ubrr-launch.sh
```

Then add a firewall rule allowing the TV VLAN to reply to the controller LAN
(and, if the TV rejects off-subnet control, a `srcnat masquerade` from the
controller LAN to the TV's IP out the TV-VLAN interface).

#### Lifx Bulb Discovery
`./udp-broadcast-relay-rs --id 1 --port 56700 --dev eth0 --dev eth1`

#### Broadlink IR Emitter Discovery
`./udp-broadcast-relay-rs --id 1 --port 80 --dev eth0 --dev eth1`

#### Warcraft 3 Server Discovery
`./udp-broadcast-relay-rs --id 1 --port 6112 --dev eth0 --dev eth1`

#### Relaying broadcasts between two LANs joined by tun-based VPN
This example is from OpenWRT. Tun-based devices don't forward broadcast packets
 so temporarily rewriting the destination address (and then re-writing it back)
 is necessary.

Router 1 (source):

`./udp-broadcast-relay-rs --id 1 --port 6112 --dev br-lan --dev tun0 -t 10.66.2.13`

(where 10.66.2.13 is the IP of router 2 over the tun0 link)

Router 2 (target):

`./udp-broadcast-relay-rs --id 2 --port 6112 --dev br-lan --dev tun0 -t 255.255.255.255`

#### HDHomerun Discovery
`./udp-broadcast-relay-rs --id 1 --port 65001 --dev eth0 --dev eth1`

Note about firewall rules
---

If you are running udp-broadcast-relay-rs on a router, it can be an easy
way to relay broadcasts between VLANs. However, beware that these broadcasts
will not establish a RELATED firewall relationship between the source and
destination addresses.

This means if you have strict firewall rules, the recipient may not be able
to respond to the broadcaster. For instance, the SSDP protocol involves
sending a broadcast packet to port 1900 to discover devices on the network.
The devices then respond to the broadcast with a unicast packet back to the
original sender. You will need to make sure that your firewall rules allow
these response packets to make it back to the original sender.
