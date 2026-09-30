#!/usr/bin/python3
# -*- coding: utf-8 -*-
"""
vpnsplitd - split-tunnel daemon for Check Point Endpoint VPN in hub mode (macOS).

Runs as root under launchd (com.ravi.vpnsplitd). It watches the routing table through
`route -n monitor` and the user's config directory through kqueue, so it uses no CPU while idle.

  split mode (default): when Check Point installs its ~90 hub-mode routes on the utun interface,
                        back them up, delete them, and add only the routes listed in routes.conf.
  full mode:            put the original routes back from the session backup, so everything goes
                        through the VPN again (temporary, optionally with an expiry time).

Files (VPNSPLIT_HOME = the user's ~/vpn-split, set by the installer):
  $VPNSPLIT_HOME/config/routes.conf    entries that must go via the VPN (CIDR, IP or domain)
  $VPNSPLIT_HOME/config/control.json   {"mode": "split"|"full", "full_until": <epoch>|null}
  /usr/local/vpn-split/status.json     what the daemon sees and did (read by the menu bar app)
  /usr/local/vpn-split/applied.json    routes this daemon added (survives restarts)
  /usr/local/vpn-split/backups/<ts>/   per-session backups, same layout as vpn-split.sh
  /var/log/vpnsplitd.log               log (via launchd)

Usage:
  vpnsplitd.py                      run the daemon (root)
  vpnsplitd.py --once [--dry-run]   evaluate once and exit; --dry-run only prints route commands
  vpnsplitd.py --self-test          built-in unit checks, no root needed
  vpnsplitd.py --status             pretty-print status.json
"""
import ipaddress
import json
import os
import re
import select
import socket
import stat
import subprocess
import sys
import threading
import time
import urllib.request

VERSION = "1.5.0"

HOME = os.environ.get("VPNSPLIT_HOME") or os.path.expanduser("~/vpn-split")
CONF_DIR = os.path.join(HOME, "config")
ROUTES_FILE = os.path.join(CONF_DIR, "routes.conf")
CONTROL_FILE = os.path.join(CONF_DIR, "control.json")
STATE_DIR = os.environ.get("VPNSPLIT_STATE") or "/usr/local/vpn-split"
STATUS_FILE = os.path.join(STATE_DIR, "status.json")
APPLIED_FILE = os.path.join(STATE_DIR, "applied.json")
BACKUP_DIR = os.path.join(STATE_DIR, "backups")
RESOLVER_DIR = os.environ.get("VPNSPLIT_RESOLVER_DIR") or "/etc/resolver"
RESOLVER_MARK = "# managed by vpnsplitd"        # only files carrying this are ever touched
DNS_PORT_PREF = 53                              # try loopback :53 first (clean fallback), else a high port
DNS_PORT_ALT = 55353
WILDCARD_TTL = 3600                             # forget a discovered wildcard IP unseen this long

TILING_THRESHOLD = 10      # more routes than this on the tunnel = hub-mode tiling present
QUIET_SECS = 2.0           # wait for this much silence after routing events before acting
MAX_DEBOUNCE = 8.0         # ...but never wait longer than this in total
RESOLVE_EVERY = 300        # re-resolve domain entries (AWS ELB IPs rotate)
PUBLIC_IP_EVERY = 600      # refresh public IP while connected
SAFETY_POLL = 45           # re-check everything at least this often (hard deadline, noise cannot delay it)
# first one is an IP literal: works even when DNS is broken (which is exactly when we want to know)
PUBLIC_IP_URLS = ("https://1.1.1.1/cdn-cgi/trace", "https://ifconfig.me/ip", "https://api.ipify.org")

DRY = False
ONCE = False

HOSTNAME_RE = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}$", re.I)


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def sh(cmd):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)


# ----------------------------------------------------------------------------- routing table

class Route(object):
    __slots__ = ("dest", "gw", "flags", "netif")

    def __init__(self, dest, gw, flags, netif):
        self.dest, self.gw, self.flags, self.netif = dest, gw, flags, netif


def netstat_inet():
    out = sh(["netstat", "-rn", "-f", "inet"]).stdout
    routes = []
    for line in out.splitlines():
        p = line.split()
        if len(p) < 4 or p[0] in ("Destination", "Internet:", "Routing"):
            continue
        routes.append(Route(p[0], p[1], p[2], p[3]))
    return routes


def internet_default_present(routes):
    """Safety guard: is there a default route on a non-tunnel interface (the real internet path)?
    The daemon never touches it, but if it is ever missing we refuse to change anything at all."""
    for r in routes:
        if r.dest == "default" and not r.netif.startswith("utun") and r.netif != "lo0":
            try:
                ipaddress.ip_address(r.gw)            # "default link#19 bridge100" (Internet Sharing) is not an internet path
                return True
            except ValueError:
                continue
    return False


def find_azure(routes, exclude_if=None):
    """The Azure VPN Client's tunnel: a utun (not Check Point's) that carries a *scoped* default route
    (`default link#N UCSIg utunX`) and interface routes. Tailscale would look similar but uses 100.64/10,
    which we exclude by requiring an RFC1918 address on the interface."""
    cands = {r.netif for r in routes if r.dest == "default" and r.netif.startswith("utun") and r.gw.startswith("link#")}
    for ifn in sorted(cands):
        if ifn == exclude_if:
            continue
        out = sh(["ifconfig", ifn]).stdout
        m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", out)
        if m and ipaddress.ip_address(m.group(1)).is_private:
            return ifn, m.group(1)
    return None


def find_tunnel(routes):
    """Check Point's point-to-point link route: <gw> <local> UHr utunN. Returns (if, gw, local).
    Only a real peer pair qualifies (gateway != local, both private): Tailscale/WireGuard/Cisco-style
    tunnels carry a self-peer link route (same address twice) and must never be mistaken for Check Point."""
    for r in routes:
        if r.flags != "UHr" or not r.netif.startswith("utun") or r.dest == r.gw:
            continue
        try:
            a, b = ipaddress.ip_address(r.dest), ipaddress.ip_address(r.gw)
        except ValueError:
            continue
        if a.version == 4 and b.version == 4 and a.is_private and b.is_private:
            return r.netif, r.dest, r.gw
    return None


_DEST_RE = re.compile(r"^(\d{1,3})(?:\.(\d{1,3})){0,3}(?:/(\d{1,2}))?$")


def expand(dest, flags):
    """netstat abbreviates destinations (8/7, 11, 255.255.254, 10.0.188.2/31). Return (kind, target),
    or None for anything that is not a dotted IPv4 destination (e.g. 'default')."""
    if not _DEST_RE.match(dest):
        return None
    if "/" in dest:
        ip, plen = dest.split("/", 1)
        plen = int(plen)
    else:
        ip, plen = dest, None
    octets = ip.split(".")
    while len(octets) < 4:
        octets.append("0")
    if any(int(o) > 255 for o in octets) or (plen is not None and plen > 32):
        return None
    ip = ".".join(octets)
    if plen is None:
        if "H" in flags:
            return ("host", ip)
        a = int(octets[0])                      # classful default, same as netstat's abbreviation
        plen = 8 if a < 128 else 16 if a < 192 else 24
    return ("net", "%s/%d" % (ip, plen))


def lan_networks(routes):
    """Directly connected IPv4 networks on non-tunnel interfaces (e.g. 192.168.1.0/24 on en0)."""
    nets = []
    for r in routes:
        if r.netif.startswith("utun") or r.netif == "lo0" or not r.gw.startswith("link#"):
            continue
        if "/" in r.dest or r.dest.count(".") < 3:
            t = expand(r.dest, r.flags)
            if t:
                nets.append(ipaddress.ip_network(t[1], strict=False))
    return nets


def resolver_servers(scutil_out):
    """All IPv4 nameservers of the default resolver (block #1), in order."""
    servers = []
    seen_first = False
    for line in scutil_out.splitlines():
        s = line.strip()
        if s.startswith("resolver #"):
            if seen_first:
                break                                     # only the first (default) resolver block
            seen_first = True
            continue
        m = re.match(r"nameserver\[\d+\]\s*:\s*(\S+)", s)
        if not m:
            continue
        try:
            a = ipaddress.ip_address(m.group(1))
        except ValueError:
            continue
        if a.version == 4 and str(a) not in servers:
            servers.append(str(a))
    return servers


def parse_dns_servers(scutil_out, lan, exclude=()):
    """Nameservers of the default resolver that the VPN pushed: private, not on a local LAN, and not one
    of the resolvers that were already in use before the tunnel came up (`exclude`, the LAN baseline).
    The baseline matters in an office: its DNS server (e.g. 192.168.10.2) is off-subnet, so without it
    the LAN resolver looks VPN-pushed and would be routed into the tunnel, where it is unreachable."""
    return [a for a in resolver_servers(scutil_out)
            if ipaddress.ip_address(a).is_private and a not in exclude
            and not any(ipaddress.ip_address(a) in n for n in lan)]


def vpn_dns_servers(routes, exclude=()):
    return parse_dns_servers(sh(["scutil", "--dns"]).stdout, lan_networks(routes), exclude)


def lan_gateway(routes):
    """(gateway, interface) of the internet default route on a non-tunnel interface, or None."""
    for r in routes:
        if r.dest == "default" and not r.netif.startswith("utun") and r.netif != "lo0" and not r.gw.startswith("link#"):
            try:
                ipaddress.ip_address(r.gw)
                return (r.gw, r.netif)
            except ValueError:
                continue
    return None


def tiling_present(routes, ifn, applied):
    """Is Check Point's hub-mode tiling on the tunnel? Judge by content, never by count: our own
    routes (subnets >= /8, hosts) can legitimately number in the dozens once wildcards resolve.
    Tiling = routes we did not add, with very short prefixes (0/5, 8/7, 64/3, 128/2 ...) or lots of them."""
    foreign, short = 0, 0
    for r in routes:
        if r.netif != ifn or r.flags == "UHr" or r.dest == "default":
            continue
        t = expand(r.dest, r.flags)
        if t is None or t in applied:
            continue
        foreign += 1
        if t[0] == "net" and int(t[1].split("/")[1]) <= 7:
            short += 1
    return short >= 2 or foreign >= 8


def route_interface(target):
    """Interface the kernel would actually use for this destination (route -n get)."""
    dst = target.split("/")[0]
    out = sh(["route", "-n", "get", dst]).stdout
    m = re.search(r"interface:\s*(\S+)", out)
    return m.group(1) if m else None


_LAN_IF_RE = re.compile(r"^(en|bridge)\d+$")      # Wi-Fi/Ethernet/USB-Ethernet/Internet Sharing: where macOS parks leftovers


def dead_gateway_routes(routes):
    """Gateway routes on a LAN interface (en*/bridge*) whose gateway is NOT on that interface's own
    network. The kernel cannot deliver to such a gateway, so the route is a black hole. That is exactly
    what macOS leaves behind when a tunnel vanishes: e.g. `10.26/17 -> 10.0.202.181 on en0` (a Check
    Point gateway address, parked on Wi-Fi). Point-to-point VPN interfaces (ppp0, ipsec0, utun*) are
    never inspected: their gateways are peer addresses, not networks, and their routes are not ours.
    Returns [((kind, target), route)] for private destinations."""
    connected = {}
    for r in routes:
        if not _LAN_IF_RE.match(r.netif):
            continue
        t = expand(r.dest, r.flags)
        if not t:
            continue
        if r.gw.startswith("link#") and t[0] == "net":
            connected.setdefault(r.netif, []).append(ipaddress.ip_network(t[1], strict=False))
        elif "H" in r.flags and "G" not in r.flags:          # peer / own-address host route counts as on-link
            connected.setdefault(r.netif, []).append(ipaddress.ip_network(t[1] + "/32"))
    out = []
    for r in routes:
        if not _LAN_IF_RE.match(r.netif) or r.dest == "default" or "G" not in r.flags:
            continue
        try:
            gw = ipaddress.ip_address(r.gw)
        except ValueError:
            continue                                      # link#N / MAC address: an interface route
        if not gw.is_private or any(gw in n for n in connected.get(r.netif, [])):
            continue                                      # on-link gateway (LAN router, DHCP static route): fine
        t = expand(r.dest, r.flags)
        if t and ipaddress.ip_network(t[1] if "/" in t[1] else t[1] + "/32", strict=False).is_private:
            out.append((t, r))
    return out


def sweep_stale(targets, routes, keep_if=None, cmdlog=None, dead_gateways=True):
    """macOS can re-attach a gateway route to Wi-Fi/Ethernet when its tunnel disappears, leaving e.g.
    `10.26/17 -> 10.0.202.181 on en0` pointing at a dead VPN gateway. Delete any of OUR targets that sit
    on a non-tunnel interface (or on a tunnel other than keep_if), plus - when dead_gateways is set - any
    private route on a LAN interface whose gateway is unreachable there (dead_gateway_routes: a black
    hole whoever added it; DNS-server routes from an earlier session are the usual case). It runs
    while connected too: a leftover that is no longer in the config (e.g. a DNS server the VPN stopped
    pushing) would otherwise stay a black hole for as long as the session lasts.
    Returns how many routes were removed."""
    wanted = {t for t in targets}
    dead = {id(r) for _, r in dead_gateway_routes(routes)} if dead_gateways else set()
    n = 0
    for r in routes:
        if r.netif == keep_if or r.flags == "UHr" or r.dest == "default":
            continue
        if r.netif.startswith("utun") and keep_if is None:
            pass                                          # tunnel gone: its leftovers are stale too
        elif r.netif.startswith("utun"):
            continue                                      # another live tunnel's own routes: not ours to touch
        t = expand(r.dest, r.flags)
        if t and "G" in r.flags and (t in wanted or id(r) in dead):   # gateway routes only; never interface/LAN routes
            if route_op("delete", t[0], t[1], r.gw, cmdlog):
                log("removed stale route %s -> %s on %s" % (t[1], r.gw, r.netif))
                n += 1
    return n


def route_op(action, kind, target, gw, cmdlog=None, via_if=None):
    # Azure's tunnel has no gateway address: its routes are interface routes (-interface utunN)
    cmd = ["route", "-n", action, "-" + kind, target] + (["-interface", via_if] if via_if else [gw])
    line = " ".join(cmd)
    if cmdlog:
        cmdlog.write(line + "\n")
        cmdlog.flush()
    if DRY:
        print("+ " + line)
        return True
    r = sh(cmd)
    if r.returncode != 0:
        err = (r.stderr or r.stdout).strip().lower()
        if action == "add" and "exists" in err:
            return True
        if action == "delete" and "not in table" in err:
            return True
        log("route %s %s failed: %s" % (action, target, err))
        return False
    return True


# ----------------------------------------------------------------------------- config

VIAS = ("checkpoint", "azure")


class Entry(object):
    def __init__(self, raw, kind, enabled, comment, lineno, auto=False, via="checkpoint"):
        self.raw, self.kind, self.enabled, self.comment, self.lineno = raw, kind, enabled, comment, lineno
        self.auto = auto                                  # synthesized (VPN DNS), not from routes.conf
        self.via = via                                    # which tunnel carries it: checkpoint (default) or azure
        self.ips = []
        self.error = None if kind else "invalid entry"
        self.applied = False
        self.resolver = None                              # wildcard only: is its /etc/resolver file live

    def targets(self):
        if self.kind == "private":
            return private_targets(_CARVE)
        if self.kind in ("ip", "dns"):
            return [("host", self.raw)]
        if self.kind == "cidr":
            net = ipaddress.ip_network(self.raw, strict=False)
            if net.prefixlen == 32:
                return [("host", str(net.network_address))]
            return [("net", str(net))]
        if self.kind in ("domain", "wildcard"):
            return [("host", ip) for ip in self.ips]     # wildcard IPs come from the DNS forwarder
        return []

    @property
    def suffix(self):
        return self.raw[2:] if self.kind == "wildcard" else None

    def to_status(self):
        return {"raw": self.raw, "kind": self.kind, "enabled": self.enabled, "comment": self.comment,
                "ips": list(self.ips), "applied": self.applied, "error": self.error, "auto": self.auto,
                "resolver": self.resolver, "via": self.via}


def dns_entries(servers):
    return [Entry(ip, "dns", True, "DNS server pushed by the VPN (automatic)", 0, auto=True) for ip in servers]


PRIVATE_NETS = [ipaddress.ip_network("10.0.0.0/8"), ipaddress.ip_network("172.16.0.0/12"), ipaddress.ip_network("192.168.0.0/16")]
_CARVE = []                 # directly connected LAN networks, refreshed every evaluate; `private` routes around them


def private_targets(exclude):
    """The `private` entry: all RFC1918 space through the VPN, minus the networks this Mac is directly on
    (home Wi-Fi 192.168.1/24, office 10.20.96/20 ...), so LAN devices and the LAN gateway stay local.
    Split into the fewest more-specific subnets that avoid each excluded network."""
    out = []
    for base in PRIVATE_NETS:
        nets = [base]
        for ex in exclude:
            if ex.version != 4:
                continue
            new = []
            for n in nets:
                if n.subnet_of(ex):
                    continue                              # entirely local: drop
                if ex.subnet_of(n):
                    new.extend(n.address_exclude(ex))
                else:
                    new.append(n)
            nets = new
        out.extend(("net", str(n)) for n in sorted(nets))
    return out


def lan_carve(routes):
    return [n for n in lan_networks(routes) if n.is_private and n.prefixlen <= 30]


def classify(value):
    if value == "private":
        return "private"
    if value.startswith("*."):
        return "wildcard" if HOSTNAME_RE.match(value[2:]) else None
    try:
        if "/" in value:
            net = ipaddress.ip_network(value, strict=False)
            return "cidr" if net.version == 4 else None
        addr = ipaddress.ip_address(value)
        return "ip" if addr.version == 4 else None
    except ValueError:
        pass
    return "domain" if HOSTNAME_RE.match(value) else None


MIN_PREFIX = 8


def entry_error(value, kind):
    """Why an entry must not be routed, or None. Guards against hijacking everything into the tunnel
    (0.0.0.0/0, /1 ...) and against nonsense targets, since routes.conf is user-editable."""
    if kind is None:
        return "invalid entry"
    if kind in ("wildcard", "private"):
        return None
    if kind in ("cidr", "ip"):
        net = ipaddress.ip_network(value, strict=False)
        if net.prefixlen < MIN_PREFIX:
            return "prefix shorter than /%d not allowed" % MIN_PREFIX
        a = net.network_address
        if a.is_loopback or a.is_link_local or a.is_multicast or a.is_unspecified or a.is_reserved:
            return "loopback, link-local, multicast or reserved address"
    return None


def parse_routes(text):
    entries = []
    for lineno, raw in enumerate(text.splitlines(), 1):
        s = raw.strip()
        if not s:
            continue
        enabled = True
        if s.startswith("#"):
            body = s[1:].strip()
            if not body.lower().startswith("off "):
                continue                                  # plain comment
            enabled = False
            s = body[4:].strip()
        if "#" in s:
            value, comment = s.split("#", 1)
            value, comment = value.strip(), comment.strip()
        else:
            value, comment = s, ""
        if not value:
            continue
        value = value.lower()
        via, tokens = "checkpoint", value.split()
        if len(tokens) == 3 and tokens[1] == "via" and tokens[2] in VIAS:
            value, via = tokens[0], tokens[2]
        elif len(tokens) != 1:
            e = Entry(value[:60], None, enabled, comment, lineno)
            e.error = "invalid entry (use: <target> via azure|checkpoint)"
            entries.append(e)
            continue
        kind = classify(value)
        err = entry_error(value, kind)
        e = Entry(value if err is None or len(value) <= 60 else value[:60] + "…", kind if err is None else None,
                  enabled, comment, lineno, via=via)
        e.error = err
        entries.append(e)
    return entries


def read_user_file(path):
    """Read a file from the user's config dir as root, safely: never follow a symlink, only accept a
    regular file, and only if it is owned by the (non-root) owner of the config dir. Otherwise a user
    could point routes.conf at a root-only file and read it back through status.json."""
    dfd = os.open(CONF_DIR, os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY)
    try:
        dst = os.fstat(dfd)
        if dst.st_uid == 0 and os.geteuid() == 0:
            raise OSError("config dir %s is owned by root; it must belong to the user" % CONF_DIR)
        fd = os.open(os.path.basename(path), os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
    finally:
        os.close(dfd)
    try:
        fst = os.fstat(fd)
        if not stat.S_ISREG(fst.st_mode):
            raise OSError("%s is not a regular file" % path)
        if fst.st_uid != dst.st_uid:
            raise OSError("%s is owned by uid %d, expected %d" % (path, fst.st_uid, dst.st_uid))
        if fst.st_size > 1024 * 1024:
            raise OSError("%s is larger than 1 MB" % path)
    except OSError:
        os.close(fd)
        raise
    with os.fdopen(fd, "r", errors="replace") as f:
        return f.read()


def load_entries():
    try:
        return parse_routes(read_user_file(ROUTES_FILE)), None
    except OSError as e:
        return [], "routes.conf not readable: %s" % e


def read_control():
    """Returns (mode, full_until) as currently in effect. An expired full_until simply means split;
    nothing is ever written back into the user's directory (root must not write there)."""
    try:
        d = json.loads(read_user_file(CONTROL_FILE))
    except (OSError, ValueError):
        return "split", None
    if not isinstance(d, dict):
        return "split", None
    mode = d.get("mode") if d.get("mode") in ("split", "full") else "split"
    fu = d.get("full_until")
    fu = float(fu) if isinstance(fu, (int, float)) and not isinstance(fu, bool) else None
    if mode == "full" and fu is not None and time.time() >= fu:
        mode = "split"
    if mode == "split":
        fu = None
    return mode, fu


# domain -> {"ips": [...], "ts": when last resolved, "error": str|None, "busy": bool}
_dns = {}
_dns_lock = threading.Lock()


def _resolve_worker(names):
    for name in names:
        try:
            infos = socket.getaddrinfo(name, None, socket.AF_INET, socket.SOCK_STREAM)
            ips, err = sorted({i[4][0] for i in infos}), None
        except socket.gaierror as ex:
            ips, err = None, "DNS: %s" % (ex.strerror or ex)
        with _dns_lock:
            c = _dns.setdefault(name, {"ips": [], "ts": 0.0, "error": None, "busy": False})
            if ips is None:
                ips = c["ips"]                            # keep last known IPs on transient failure
            if set(ips) != set(c["ips"]):
                log("resolved %s -> %s" % (name, ", ".join(ips) or "(nothing)"))
            c.update(ips=ips, ts=time.time(), error=err, busy=False)
    try:
        os.write(_wake_w, b"d")
    except OSError:
        pass


def resolve_domains(entries, force=False):
    """Fill entries from the DNS cache; kick off a background lookup for stale/unknown names.
    getaddrinfo can block for 30 s when DNS is broken, so it never runs on the main thread."""
    now = time.time()
    todo = []
    with _dns_lock:
        for e in entries:
            if e.kind != "domain" or not e.enabled:
                continue
            c = _dns.setdefault(e.raw, {"ips": [], "ts": 0.0, "error": None, "busy": False})
            e.ips, e.error = list(c["ips"]), c["error"]
            if not c["ips"] and c["ts"] == 0.0:
                e.error = "resolving…"
            if (force or now - c["ts"] >= RESOLVE_EVERY) and not c["busy"]:
                c["busy"] = True
                todo.append(e.raw)
    if todo:
        if DRY or ONCE:
            _resolve_worker(todo)
            with _dns_lock:
                for e in entries:
                    if e.raw in _dns:
                        e.ips, e.error = list(_dns[e.raw]["ips"]), _dns[e.raw]["error"]
        else:
            threading.Thread(target=_resolve_worker, args=(todo,), daemon=True).start()


def next_resolve_due():
    with _dns_lock:
        idle = [c["ts"] for c in _dns.values() if not c["busy"]]
    return (min(idle) + RESOLVE_EVERY) if idle else None


# ----------------------------------------------------------------------------- state / backups

class State(object):
    def __init__(self):
        self.ifn = None
        self.gw = None
        self.since = 0.0                                  # when this tunnel connection was first seen
        self.backup = None
        self.applied = set()
        self.applied_az = set()                           # routes we placed on the Azure interface
        self.az_if = None
        self.lan_dns = []                                 # resolvers in use while NO tunnel was up (baseline)
        self.applied_lan = set()                          # (kind, target, gw): LAN DNS kept reachable in Full VPN

    def reset(self):
        az_if, applied_az, lan_dns = self.az_if, self.applied_az, self.lan_dns   # independent of Check Point's session
        self.__init__()
        self.az_if, self.applied_az, self.lan_dns = az_if, applied_az, lan_dns

    @classmethod
    def load(cls):
        st = cls()
        try:
            with open(APPLIED_FILE) as f:
                d = json.load(f)
            st.ifn, st.gw, st.backup = d.get("if"), d.get("gw"), d.get("backup")
            st.since = float(d.get("since") or 0.0)
            st.applied = {tuple(x) for x in d.get("routes", [])}
            st.applied_az = {tuple(x) for x in d.get("routes_az", [])}
            st.az_if = d.get("az_if")
            st.lan_dns = [str(x) for x in d.get("lan_dns", [])]
            st.applied_lan = {tuple(x) for x in d.get("routes_lan", [])}
        except (OSError, ValueError, TypeError):
            pass
        return st

    def save(self):
        if DRY:
            return
        tmp = APPLIED_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"if": self.ifn, "gw": self.gw, "since": self.since, "backup": self.backup,
                       "routes": sorted(self.applied), "routes_az": sorted(self.applied_az), "az_if": self.az_if,
                       "lan_dns": self.lan_dns, "routes_lan": sorted(self.applied_lan)}, f)
        os.replace(tmp, APPLIED_FILE)


def _write(path, text):
    with open(path, "w") as f:
        f.write(text)


def make_backup(ifn, gw, local):
    if DRY:
        return None
    bk = os.path.join(BACKUP_DIR, time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(bk, exist_ok=True)
    _write(os.path.join(bk, "netstat-rn.before.txt"), sh(["netstat", "-rn"]).stdout)
    _write(os.path.join(bk, "scutil-dns.before.txt"), sh(["scutil", "--dns"]).stdout)
    _write(os.path.join(bk, "ifconfig-%s.txt" % ifn), sh(["ifconfig", ifn]).stdout)
    _write(os.path.join(bk, "vpn-if.txt"), "%s %s %s\n" % (ifn, gw, local))
    for name in ("deleted_routes.txt", "added_routes.txt", "commands.log"):
        _write(os.path.join(bk, name), "")
    return bk


def _open_log(bk, name):
    if not bk:
        return None
    return open(os.path.join(bk, name), "a")


def backup_time(path):
    try:
        return time.mktime(time.strptime(os.path.basename(path), "%Y%m%d-%H%M%S"))
    except ValueError:
        return 0.0


def find_session_backup(gw, since):
    """Newest backup taken for THIS connection: same gateway and not older than the moment the tunnel
    came up. Gateways recycle across days and the tiling (with its carve-outs for the VPN server's
    own address) differs per connection, so an older backup must never be replayed."""
    if not os.path.isdir(BACKUP_DIR):
        return None
    best, best_n = None, -1
    for name in sorted(os.listdir(BACKUP_DIR), reverse=True):      # newest first; ties keep the newest
        p = os.path.join(BACKUP_DIR, name)
        if backup_time(p) < since - 5:
            continue
        try:
            with open(os.path.join(p, "vpn-if.txt")) as f:
                parts = f.read().split()
            n = sum(1 for _ in open(os.path.join(p, "deleted_routes.txt")))
        except OSError:
            continue
        if len(parts) >= 2 and parts[1] == gw and n > best_n:  # the real tiling is the biggest one
            best, best_n = p, n
    return best


def prune_backups(keep_newest=3, real_min=40):
    """Per gateway keep every backup that looks like a real tiling (>= real_min routes) plus the
    newest few; delete the rest. Real Check Point tilings seen so far are 90-91 routes; flapping junk was 10-24."""
    if not os.path.isdir(BACKUP_DIR):
        return 0
    import shutil
    groups = {}
    for name in sorted(os.listdir(BACKUP_DIR)):
        p = os.path.join(BACKUP_DIR, name)
        try:
            gw = open(os.path.join(p, "vpn-if.txt")).read().split()[1]
            n = sum(1 for _ in open(os.path.join(p, "deleted_routes.txt")))
        except (OSError, IndexError):
            continue
        groups.setdefault(gw, []).append((name, n))
    removed = 0
    for gw, items in groups.items():
        newest = {name for name, _ in items[-keep_newest:]}
        for name, n in items:
            if n >= real_min or name in newest:
                continue
            shutil.rmtree(os.path.join(BACKUP_DIR, name), ignore_errors=True)
            removed += 1
    if removed:
        log("pruned %d small/duplicate backups" % removed)
    return removed


def strip(ifn, gw, local, routes):
    """Delete every route on the tunnel except its link route. Returns backup dir."""
    bk = make_backup(ifn, gw, local)
    cmdlog, dellog = _open_log(bk, "commands.log"), _open_log(bk, "deleted_routes.txt")
    n = 0
    for r in routes:
        if r.netif != ifn or r.flags == "UHr":
            continue
        t = expand(r.dest, r.flags)
        if t is None:
            log("split: leaving non-IPv4 destination %r on %s alone" % (r.dest, ifn))
            continue
        kind, target = t
        if dellog:
            dellog.write("%s %s %s\n" % (kind, target, r.gw))
        if route_op("delete", kind, target, r.gw, cmdlog):
            n += 1
    for f in (cmdlog, dellog):
        if f:
            f.close()
    log("split: removed %d hub-mode routes from %s (backup %s)" % (n, ifn, bk or "none, dry run"))
    return bk


def split_if_conflict(t, other_present):
    """If the *other* tunnel announces exactly this network with the same prefix, the kernel keeps
    whichever was added first. Two more-specific halves always win, so use those instead."""
    if t[0] != "net" or t not in other_present:
        return [t]
    net = ipaddress.ip_network(t[1], strict=False)
    if net.prefixlen >= 32:
        return [t]
    return [("net", str(h)) if h.prefixlen < 32 else ("host", str(h.network_address)) for h in net.subnets(prefixlen_diff=1)]


def reconcile(ifn, gw, local, entries, st, routes, via="checkpoint", via_if=None, other_if=None):
    """Make the routes on one tunnel match the enabled entries for it. Returns True if anything changed.
    via='checkpoint' uses the gateway; via='azure' uses interface routes on via_if. Entries whose network the
    other tunnel also announces are split into two halves so this tunnel wins for them."""
    applied = st.applied if via == "checkpoint" else st.applied_az
    other_present = {t for t in (expand(r.dest, r.flags) for r in routes if other_if and r.netif == other_if and r.flags != "UHr") if t}
    desired = {}
    for e in entries:
        if e.enabled and e.kind and e.via == via:
            for t0 in e.targets():
                if local and t0[1].split("/")[0] == local:
                    continue
                for t in split_if_conflict(t0, other_present):
                    desired[t] = e
    present = {t for t in (expand(r.dest, r.flags) for r in routes if r.netif == ifn and r.flags != "UHr") if t}
    cmdlog = _open_log(st.backup, "commands.log") if via == "checkpoint" else None
    addlog = _open_log(st.backup, "added_routes.txt") if via == "checkpoint" else None
    changed = False
    if sweep_stale(desired.keys(), routes, keep_if=ifn, cmdlog=cmdlog):
        changed = True
        routes = netstat_inet()
        present = {t for t in (expand(r.dest, r.flags) for r in routes if r.netif == ifn and r.flags != "UHr") if t}
    for t in desired:
        if t in present:
            applied.add(t)
            continue
        ok = route_op("add", t[0], t[1], gw, cmdlog, via_if=via_if)
        if ok and not DRY and route_interface(t[1]) not in (ifn, None):
            # "File exists" on another interface: kernel refused ours. Remove the impostor and retry once.
            log("route %s landed on %s instead of %s; replacing" % (t[1], route_interface(t[1]), ifn))
            route_op("delete", t[0], t[1], gw, cmdlog)
            ok = route_op("add", t[0], t[1], gw, cmdlog, via_if=via_if)
        if ok:
            applied.add(t)
            changed = True
            if addlog:
                addlog.write("%s %s %s\n" % (t[0], t[1], gw))
    for t in sorted(applied - set(desired)):
        if t in present:
            route_op("delete", t[0], t[1], gw, cmdlog, via_if=via_if)
            changed = True
        applied.discard(t)
    for f in (cmdlog, addlog):
        if f:
            f.close()
    for e in entries:
        if e.via != via:
            continue
        ts = [t for t0 in e.targets() for t in split_if_conflict(t0, other_present)]
        e.applied = bool(ts) and all(t in applied for t in ts)
    if changed:
        log("routes via %s (%s) now: %s" % (ifn, via, ", ".join(t[1] for t in sorted(applied)) or "(none)"))
    return changed


def drop_lan_dns_routes(st):
    for k, t, g in sorted(st.applied_lan):
        route_op("delete", k, t, g)
    if st.applied_lan:
        log("removed %d office-DNS route(s) kept for Full VPN" % len(st.applied_lan))
    st.applied_lan = set()


def restore(ifn, gw, st, bk):
    cmdlog = _open_log(bk, "commands.log")
    for k, t in sorted(st.applied):
        route_op("delete", k, t, gw, cmdlog)
    st.applied = set()
    n = 0
    with open(os.path.join(bk, "deleted_routes.txt")) as f:
        for line in f:
            p = line.split()
            if len(p) >= 3 and route_op("add", p[0], p[1], p[2], cmdlog):
                n += 1
    if cmdlog:
        cmdlog.close()
    log("full VPN: restored %d routes on %s from %s" % (n, ifn, bk))


# ----------------------------------------------------------------------------- public ip / status

# shared with the fetch thread; every access goes through _pub_lock
_pub = {"ip": None, "ts": 0.0, "busy": False}
_pub_lock = threading.Lock()
_wake_r, _wake_w = os.pipe()          # background threads poke this to make the main loop re-run


def _fetch_public_ip():
    ip = None
    for url in PUBLIC_IP_URLS:
        try:
            body = urllib.request.urlopen(url, timeout=5).read().decode()
        except Exception:
            continue
        m = re.search(r"^ip=(\S+)$", body, re.M)
        ip = m.group(1) if m else body.strip()
        if ip and classify(ip) == "ip":
            break
        ip = None
    with _pub_lock:
        _pub["ip"] = ip or _pub["ip"]
        _pub["ts"] = time.time()
        _pub["busy"] = False
    try:
        os.write(_wake_w, b"p")
    except OSError:
        pass


def public_ip(force=False):
    """Cached public IP. Refreshes in a background thread so a slow/broken network never blocks
    the routing work; the main loop rewrites status.json when the thread finishes."""
    if DRY or ONCE:
        _fetch_public_ip()
    else:
        with _pub_lock:
            start = (force or time.time() - _pub["ts"] >= PUBLIC_IP_EVERY) and not _pub["busy"]
            if start:
                _pub["busy"] = True
        if start:
            threading.Thread(target=_fetch_public_ip, daemon=True).start()
    with _pub_lock:
        return _pub["ip"]


def public_ip_due():
    with _pub_lock:
        return None if _pub["busy"] else _pub["ts"] + PUBLIC_IP_EVERY


def write_status(doc):
    doc["ts"] = time.time()
    doc["daemon_version"] = VERSION
    if DRY:
        short = {k: v for k, v in doc.items() if k != "entries"}
        print("status:", json.dumps(short, indent=1, sort_keys=True))
        for e in doc.get("entries", []):
            print("  entry:", json.dumps(e, sort_keys=True))
        return
    tmp = STATUS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f)
    os.chmod(tmp, 0o644)
    os.replace(tmp, STATUS_FILE)


# ----------------------------------------------------------------------------- core

class Ctx(object):
    def __init__(self):
        self.entries, self.conf_error = load_entries()
        self.last_action = None


def evaluate(st, ctx, force_resolve=False):
    mode, fu = read_control()
    routes = netstat_inet()
    global _CARVE
    _CARVE = lan_carve(routes)
    tun = find_tunnel(routes)
    entries = ctx.entries
    note = ctx.conf_error
    base = {"mode": mode, "full_until": fu, "entries": [e.to_status() for e in entries],
            "last_action": ctx.last_action}

    # ---- Azure tunnel (independent of Check Point): entries tagged "via azure" ride its interface
    az = find_azure(routes, exclude_if=tun[0] if tun else None)
    wild_via = {e.suffix: e.via for e in entries if e.kind == "wildcard" and e.enabled}
    if az:
        az_if, az_addr = az
        if st.az_if != az_if:
            log("Azure VPN connected: %s (%s)" % (az_if, az_addr))
            st.az_if, st.applied_az = az_if, set()
        for e in entries:
            if e.kind == "wildcard":
                e.ips = sorted(_dynamic.get(e.suffix, {}))
        if reconcile(az_if, None, az_addr, entries + dynamic_entries(wild_via), st, routes,
                     via="azure", via_if=az_if, other_if=tun[0] if tun else None):
            ctx.last_action = "Azure routes updated " + time.strftime("%H:%M:%S")
        routes = netstat_inet()
    else:
        if st.az_if:
            log("Azure VPN disconnected (%s gone)" % st.az_if)
            for k, t in sorted(st.applied_az):
                route_op("delete", k, t, "", via_if=st.az_if)
            st.az_if, st.applied_az = None, set()
        for e in entries:
            if e.via == "azure" and e.enabled and e.kind:
                e.applied = False
                e.error = e.error or "Azure VPN not connected"

    if not tun:
        if st.gw:
            log("VPN disconnected (%s gone)" % st.ifn)
            ctx.last_action = "VPN disconnected"
            for k, t in sorted(st.applied):               # do not trust the kernel to have dropped them
                route_op("delete", k, t, st.gw)
            st.reset()
        drop_lan_dns_routes(st)
        # anything of ours still parked on a non-tunnel interface (from an earlier session) goes too
        scut = sh(["scutil", "--dns"]).stdout
        cfg_targets = {t for e in entries if e.enabled and e.kind for t in e.targets()}
        cfg_targets |= {("host", ip) for ip in parse_dns_servers(scut, lan_networks(routes))}
        if sweep_stale(cfg_targets, routes, keep_if=None):
            routes = netstat_inet()
        cur = resolver_servers(scut)
        if cur and cur != st.lan_dns:
            st.lan_dns = cur                              # what DNS looks like with no tunnel: the LAN baseline
        st.save()
        remove_all_resolvers()                            # let company domains resolve normally off-VPN
        forget_disabled_suffixes(set())
        for e in entries:
            if e.via != "azure":
                e.applied = False
        with _pub_lock:
            last_ip = _pub["ip"]
        base.update(vpn={"connected": False, "if": None, "gw": None, "local": None},
                    azure={"connected": bool(az), "if": az[0] if az else None, "local": az[1] if az else None},
                    tiling=False, route_count=0, public_ip=last_ip, note=note,
                    entries=[e.to_status() for e in entries])
        write_status(base)
        return

    if not internet_default_present(routes):
        log("SAFETY: no default route on a non-tunnel interface; not touching routes until it is back")
        base.update(vpn={"connected": True, "if": tun[0], "gw": tun[1], "local": tun[2]},
                    tiling=None, route_count=len([r for r in routes if r.netif == tun[0]]), public_ip=None,
                    note="No internet default route on Wi-Fi/Ethernet. A-Train is standing still. Toggle Wi-Fi off/on, or disconnect the VPN.",
                    entries=[e.to_status() for e in entries])
        write_status(base)
        return

    ifn, gw, local = tun
    if st.gw != gw or st.ifn != ifn:
        log("VPN connected: %s gateway %s local %s" % (ifn, gw, local))
        st.reset()
        st.ifn, st.gw, st.since = ifn, gw, time.time()
    tiling = tiling_present(routes, ifn, st.applied)
    changed = False

    # tell the DNS forwarder where to forward and which wildcard suffixes are live
    scut = sh(["scutil", "--dns"]).stdout                # before stripping, while scutil still shows them
    dns = parse_dns_servers(scut, lan_networks(routes), exclude=st.lan_dns)
    cur_dns = resolver_servers(scut)
    wildcard_suffixes = {e.suffix for e in entries if e.kind == "wildcard" and e.enabled}
    forget_disabled_suffixes(wildcard_suffixes)
    prune_dynamic()
    with _fwd_lock:
        # VPN DNS if pushed; otherwise the LAN resolvers (company names resolve publicly too); else last known
        upstream = dns or [a for a in cur_dns if a not in dns] or _fwd["upstream"]
        _fwd["upstream"] = upstream
        _fwd["suffixes"] = wildcard_suffixes
        fwd_port = _fwd["port"]
    live_suffixes = sync_resolvers(wildcard_suffixes, fwd_port, dns) if mode == "split" else set()
    if mode != "split":
        remove_all_resolvers()                            # in full mode everything is tunneled; step aside

    if mode == "split":
        if st.applied_lan:
            drop_lan_dns_routes(st)
            changed = True
        if tiling:
            st.backup = strip(ifn, gw, local, routes)
            st.applied = set()
            changed = True
            routes = netstat_inet()
            ctx.last_action = "split applied " + time.strftime("%H:%M:%S")
            if dns:
                log("DNS servers pushed by the VPN, kept reachable via tunnel: %s" % ", ".join(dns))
            else:
                log("the VPN pushed no DNS servers this session (resolvers: %s)" % (", ".join(cur_dns) or "none"))
        if not dns and wildcard_suffixes:
            note = ("The VPN pushed no DNS servers this session, so names that exist only on the office DNS "
                    "(%s) will not resolve. Disconnect and reconnect the VPN if you need them." % ", ".join(sorted(wildcard_suffixes)))
        resolve_domains(entries, force_resolve)
        for e in entries:
            if e.kind == "private":
                e.ips = [t[1] for t in e.targets()]
            if e.kind == "wildcard":
                e.ips = sorted(_dynamic.get(e.suffix, {}))
                e.resolver = e.suffix in live_suffixes
                e.error = None if e.resolver else ("resolver not installed" if fwd_port else "DNS forwarder not running")
        entries = entries + dns_entries(dns) + dynamic_entries(wild_via)
        if reconcile(ifn, gw, local, entries, st, routes, via="checkpoint", other_if=az[0] if az else None):
            changed = True
            if not tiling:
                ctx.last_action = "routes updated " + time.strftime("%H:%M:%S")
    else:
        for e in entries:
            if e.via != "azure":
                e.applied = False
        if not tiling:
            bk = find_session_backup(gw, st.since)         # largest backup of this connection
            if bk:
                restore(ifn, gw, st, bk)
                st.backup = bk
                changed = True
                ctx.last_action = "full VPN restored " + time.strftime("%H:%M:%S")
            else:
                note = ("Full VPN requested but no backup exists for this connection. "
                        "Disconnect and reconnect the VPN to get the full tunnel.")
        # Full VPN sends everything through the tunnel, including lookups to the office/home DNS server if
        # the VPN pushed none this session (seen 2026-09-27: resolver stayed 192.168.10.2, unreachable via
        # the gateway -> "no internet"). Keep those resolvers reachable over the LAN with host routes.
        lan_res = [a for a in cur_dns if a not in dns]
        lg = lan_gateway(routes)
        if lg and any(g != lg[0] for _, _, g in st.applied_lan):
            log("LAN gateway changed to %s; re-pinning office DNS" % lg[0])
            drop_lan_dns_routes(st)                       # old pins point at a gateway that is gone
            changed = True
        if not dns and lan_res and lg:
            for a in lan_res:
                key = ("host", a, lg[0])
                if key not in st.applied_lan and route_op("add", "host", a, lg[0]):
                    st.applied_lan.add(key)
                    changed = True
                    log("Full VPN: the VPN pushed no DNS servers; keeping DNS %s reachable via %s (%s)" % (a, lg[0], lg[1]))
            note = ("Full VPN: the VPN pushed no DNS servers this session, so your usual DNS (%s) stays on %s; "
                    "everything else goes through the VPN." % (", ".join(lan_res), lg[1]))

    if changed and st.backup and not DRY:
        _write(os.path.join(st.backup, "netstat-rn.after.txt"), sh(["netstat", "-rn"]).stdout)
    st.save()
    routes = netstat_inet()
    count = len([r for r in routes if r.netif == ifn])
    base.update(vpn={"connected": True, "if": ifn, "gw": gw, "local": local},
                azure={"connected": bool(az), "if": az[0] if az else None, "local": az[1] if az else None},
                tiling=tiling_present(routes, ifn, st.applied), route_count=count,
                public_ip=public_ip(force=changed), note=note,
                entries=[e.to_status() for e in entries], last_action=ctx.last_action)
    write_status(base)


# ----------------------------------------------------------------------------- watching

class ConfigWatcher(object):
    """kqueue on the config dir + files (editors save via rename, so watch the dir too)."""
    FFLAGS = (select.KQ_NOTE_WRITE | select.KQ_NOTE_DELETE | select.KQ_NOTE_RENAME |
              select.KQ_NOTE_ATTRIB | select.KQ_NOTE_EXTEND)

    def __init__(self):
        self.kq = select.kqueue()
        self.fds = []
        self.sig = None
        self.rearm()

    def fileno(self):
        return self.kq.fileno()

    def signature(self):
        sig = []
        for p in (ROUTES_FILE, CONTROL_FILE):
            try:
                s = os.stat(p)
                sig.append((s.st_ino, s.st_mtime_ns, s.st_size))
            except OSError:
                sig.append(None)
        return tuple(sig)

    def rearm(self):
        for fd in self.fds:
            try:
                os.close(fd)
            except OSError:
                pass
        self.fds = []
        evs = []
        for p in (CONF_DIR, ROUTES_FILE, CONTROL_FILE):
            try:
                fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)
            except OSError:
                continue
            self.fds.append(fd)
            evs.append(select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                                     flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR, fflags=self.FFLAGS))
        if evs:
            self.kq.control(evs, 0, 0)
        self.sig = self.signature()

    def changed(self):
        """Drain events, re-arm on the (possibly new) files, report whether content changed."""
        try:
            self.kq.control(None, 64, 0)
        except OSError:
            pass
        old = self.sig
        self.rearm()
        return self.sig != old


def relevant(data):
    return b"RTM_ADD" in data or b"RTM_DELETE" in data or b"RTM_CHANGE" in data


def drain_events(fd, quiet=QUIET_SECS, max_wait=MAX_DEBOUNCE):
    """After a relevant routing event, keep reading until `quiet` seconds pass with no *relevant*
    event, or `max_wait` seconds in total. Noise (RTM_MISS / RTM_GET, which flow continuously in
    full-VPN mode) must not extend the wait, or we would never come back."""
    start = time.time()
    quiet_until = start + quiet
    while True:
        now = time.time()
        wait = min(quiet_until, start + max_wait) - now
        if wait <= 0:
            return
        r, _, _ = select.select([fd], [], [], wait)
        if not r:
            return
        data = os.read(fd, 65536)
        if not data:
            return
        if relevant(data):
            quiet_until = time.time() + quiet


# ----------------------------------------------------------------------------- wildcard DNS forwarder

# suffix -> {ip: last_seen}. Filled by the forwarder thread, drained into routes by the main loop.
_dynamic = {}
_dynamic_lock = threading.Lock()
# updated by evaluate() each cycle so the forwarder knows where to forward and whether to record.
_fwd = {"upstream": [], "suffixes": set(), "port": None, "active": False}
_fwd_lock = threading.Lock()


def _dns_skip_name(buf, off):
    """Advance past a DNS name at buf[off:], handling compression pointers. Returns new offset."""
    while off < len(buf):
        length = buf[off]
        if length == 0:
            return off + 1
        if length & 0xC0 == 0xC0:               # compression pointer: 2 bytes, name ends here
            return off + 2
        off += 1 + length
    return off


def parse_a_records(resp):
    """Extract IPv4 addresses from the answer section of a DNS response. Tolerant of malformed input."""
    ips = []
    try:
        if len(resp) < 12:
            return ips
        qd = (resp[4] << 8) | resp[5]
        an = (resp[6] << 8) | resp[7]
        off = 12
        for _ in range(qd):                     # skip questions
            off = _dns_skip_name(resp, off) + 4  # + QTYPE + QCLASS
        for _ in range(an):
            off = _dns_skip_name(resp, off)
            if off + 10 > len(resp):
                break
            rtype = (resp[off] << 8) | resp[off + 1]
            rdlen = (resp[off + 8] << 8) | resp[off + 9]
            rdata = off + 10
            if rtype == 1 and rdlen == 4 and rdata + 4 <= len(resp):
                ips.append(".".join(str(b) for b in resp[rdata:rdata + 4]))
            off = rdata + rdlen
    except Exception:
        pass
    return ips


def _query_name(q):
    try:
        off, labels = 12, []
        while off < len(q):
            n = q[off]
            if n == 0 or n & 0xC0 == 0xC0:
                break
            labels.append(q[off + 1:off + 1 + n].decode("ascii", "replace"))
            off += 1 + n
        return ".".join(labels).lower()
    except Exception:
        return ""


def _record_ips(name, ips):
    """Store discovered public IPs under the matching enabled wildcard suffix; poke the main loop."""
    with _fwd_lock:
        suffixes = _fwd["suffixes"]
    suffix = next((s for s in suffixes if name == s or name.endswith("." + s)), None)
    if not suffix:
        return
    good = []
    for ip in ips:
        try:
            a = ipaddress.ip_address(ip)
        except ValueError:
            continue
        if a.version == 4 and not (a.is_private or a.is_loopback or a.is_link_local
                                   or a.is_multicast or a.is_reserved or a.is_unspecified):
            good.append(ip)
    if not good:
        return
    now = time.time()
    with _dynamic_lock:
        d = _dynamic.setdefault(suffix, {})
        new = [ip for ip in good if ip not in d]
        for ip in good:
            d[ip] = now
    if new:
        log("wildcard %s: %s -> %s" % (suffix, name, ", ".join(new)))
        try:
            os.write(_wake_w, b"w")
        except OSError:
            pass


def _forward(query):
    """Send a raw query to the first upstream that answers; return the raw response or None."""
    with _fwd_lock:
        upstream = list(_fwd["upstream"])
    for host in upstream:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.settimeout(4)
            s.sendto(query, (host, 53))
            resp, _ = s.recvfrom(4096)
            s.close()
            if resp:
                return resp
        except OSError:
            try:
                s.close()
            except Exception:
                pass
    return None


def dynamic_entries(via_map=None):
    """Synthetic host entries for every discovered wildcard IP (fed into reconcile), carrying the
    wildcard's tunnel choice."""
    out = []
    via_map = via_map or {}
    with _dynamic_lock:
        for suffix, ips in _dynamic.items():
            for ip in ips:
                e = Entry(ip, "ip", True, "via *." + suffix, 0, auto=True, via=via_map.get(suffix, "checkpoint"))
                out.append(e)
    return out


def prune_dynamic():
    now = time.time()
    with _dynamic_lock:
        for suffix in list(_dynamic):
            _dynamic[suffix] = {ip: t for ip, t in _dynamic[suffix].items() if now - t < WILDCARD_TTL}
            if not _dynamic[suffix]:
                del _dynamic[suffix]


def forget_disabled_suffixes(active_suffixes):
    """Drop discovered IPs for wildcards no longer enabled, so their routes get removed."""
    with _dynamic_lock:
        for suffix in list(_dynamic):
            if suffix not in active_suffixes:
                del _dynamic[suffix]


class DNSForwarder(object):
    def __init__(self):
        self.port = None
        self.threads = []

    def start(self):
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        for port in (DNS_PORT_PREF, DNS_PORT_ALT, DNS_PORT_ALT + 1, DNS_PORT_ALT + 2, DNS_PORT_ALT + 7):
            try:
                udp.bind(("127.0.0.1", port))
                tcp.bind(("127.0.0.1", port))
                self.port = port
                break
            except OSError:
                continue
        if self.port is None:
            log("DNS forwarder: could not bind any loopback port (%d, %d..); wildcards disabled" % (DNS_PORT_PREF, DNS_PORT_ALT))
            udp.close()
            tcp.close()
            return None
        tcp.listen(16)
        with _fwd_lock:
            _fwd["port"] = self.port
        for target, sock in ((self._serve_udp, udp), (self._serve_tcp, tcp)):
            t = threading.Thread(target=target, args=(sock,), daemon=True)
            t.start()
            self.threads.append(t)
        log("DNS forwarder listening on 127.0.0.1:%d" % self.port)
        return self.port

    def _serve_udp(self, sock):
        while True:
            try:
                query, client = sock.recvfrom(4096)
            except OSError:
                return
            threading.Thread(target=self._handle_udp, args=(sock, query, client), daemon=True).start()

    def _handle_udp(self, sock, query, client):
        resp = _forward(query)
        if resp is None:
            resp = self._servfail(query)                 # let macOS fall back to the next nameserver
        else:
            _record_ips(_query_name(query), parse_a_records(resp))
        try:
            sock.sendto(resp, client)
        except OSError:
            pass

    def _serve_tcp(self, sock):
        while True:
            try:
                conn, _ = sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle_tcp, args=(conn,), daemon=True).start()

    def _handle_tcp(self, conn):
        try:
            conn.settimeout(5)
            hdr = conn.recv(2)
            if len(hdr) < 2:
                return
            n = (hdr[0] << 8) | hdr[1]
            query = b""
            while len(query) < n:
                chunk = conn.recv(n - len(query))
                if not chunk:
                    return
                query += chunk
            resp = _forward(query) or self._servfail(query)
            _record_ips(_query_name(query), parse_a_records(resp))
            conn.sendall(bytes([len(resp) >> 8, len(resp) & 0xFF]) + resp)
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except Exception:
                pass

    @staticmethod
    def _servfail(query):
        if len(query) < 12:
            return query
        b = bytearray(query[:12])
        b[2] |= 0x80            # QR = response
        b[3] = (b[3] & 0xF0) | 0x02   # RCODE = SERVFAIL
        b[6] = b[7] = 0         # ANCOUNT = 0
        return bytes(b) + query[12:]


def sync_resolvers(suffixes, port, fallback):
    """Make RESOLVER_DIR hold exactly one marked file per enabled wildcard suffix, pointing macOS at
    our forwarder. Only ever create/delete files carrying RESOLVER_MARK. Returns set of live suffixes."""
    if port is None:
        suffixes = set()                                 # forwarder not listening: install nothing
    try:
        os.makedirs(RESOLVER_DIR, exist_ok=True)
    except OSError as e:
        log("resolver dir %s: %s" % (RESOLVER_DIR, e))
        return set()
    want = {}
    for s in suffixes:
        lines = [RESOLVER_MARK, "nameserver 127.0.0.1"]
        if port == 53:
            for fb in fallback[:2]:                      # office DNS as same-port fallback if daemon is down
                lines.append("nameserver %s" % fb)
        else:
            lines.append("port %d" % port)
        want[s] = "\n".join(lines) + "\n"
    live = set()
    # remove our stale files
    for name in os.listdir(RESOLVER_DIR):
        p = os.path.join(RESOLVER_DIR, name)
        try:
            with open(p) as f:
                head = f.readline().strip()
        except OSError:
            continue
        if head != RESOLVER_MARK:
            continue                                     # not ours, never touch
        if name not in want:
            try:
                os.remove(p)
                log("removed resolver for %s" % name)
            except OSError:
                pass
    # write/refresh wanted files
    for s, text in want.items():
        p = os.path.join(RESOLVER_DIR, s)
        try:
            cur = open(p).read() if os.path.exists(p) else None
            if cur != text:
                tmp = p + ".tmp"
                with open(tmp, "w") as f:
                    f.write(text)
                os.replace(tmp, p)
                log("resolver for %s -> 127.0.0.1:%d" % (s, port))
            live.add(s)
        except OSError as e:
            log("resolver for %s: %s" % (s, e))
    return live


def remove_all_resolvers():
    """Uninstall / shutdown: delete every marked resolver file."""
    try:
        names = os.listdir(RESOLVER_DIR)
    except OSError:
        return
    for name in names:
        p = os.path.join(RESOLVER_DIR, name)
        try:
            with open(p) as f:
                if f.readline().strip() == RESOLVER_MARK:
                    os.remove(p)
        except OSError:
            pass


def run_daemon():
    if os.geteuid() != 0:
        sys.exit("vpnsplitd must run as root (use --once --dry-run to test as a user)")
    os.makedirs(BACKUP_DIR, exist_ok=True)
    prune_backups()
    st = State.load()
    ctx = Ctx()
    watcher = ConfigWatcher()
    forwarder = DNSForwarder()
    forwarder.start()
    log("vpnsplitd %s started; config %s; state %s" % (VERSION, CONF_DIR, STATE_DIR))
    if ctx.conf_error:
        log(ctx.conf_error)
    evaluate(st, ctx, force_resolve=True)

    mon = None
    next_forced = time.time() + SAFETY_POLL            # hard deadline: noise wake-ups must not postpone it
    while True:
        if mon is None or mon.poll() is not None:
            if mon is not None:
                log("route monitor exited, restarting")
                time.sleep(2)
            mon = subprocess.Popen(["route", "-n", "monitor"], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        mfd = mon.stdout.fileno()

        now = time.time()
        timeout = max(0.5, next_forced - now)
        mode, fu = read_control()
        pub_due = public_ip_due() if st.gw else None
        for due in (next_resolve_due(), fu, pub_due):
            if due is not None:
                timeout = min(timeout, max(0.5, due - now))
        r, _, _ = select.select([mfd, watcher, _wake_r], [], [], timeout)

        woke = route_evt = cfg = False
        force = False
        forced = time.time() >= next_forced
        if forced:
            next_forced = time.time() + SAFETY_POLL
        if _wake_r in r:
            os.read(_wake_r, 64)
            woke = True                                    # a background lookup (public IP / DNS) finished
        if mfd in r:
            data = os.read(mfd, 65536)
            if not data:
                continue                                   # monitor died; loop restarts it
            if relevant(data):
                drain_events(mfd)                          # debounce, noise-proof, capped
                route_evt = True
        if watcher in r or watcher.signature() != watcher.sig:
            if watcher.changed():
                ctx.entries, ctx.conf_error = load_entries()
                cfg = force = True
                log("config reloaded (%d entries)" % len(ctx.entries))
        if not (woke or route_evt or cfg or forced or not r):
            continue                                       # RTM_MISS/RTM_GET or vnode noise only
        evaluate(st, ctx, force_resolve=force)


# ----------------------------------------------------------------------------- cli

def self_test():
    assert expand("8/7", "UGSc") == ("net", "8.0.0.0/7")
    assert expand("11", "UGSc") == ("net", "11.0.0.0/8")
    assert expand("123", "UGSc") == ("net", "123.0.0.0/8")
    assert expand("192.168/16", "UGSc") == ("net", "192.168.0.0/16")
    assert expand("255.255.254", "UGSc") == ("net", "255.255.254.0/24")
    assert expand("255.255.255.254", "UGHS") == ("host", "255.255.255.254")
    assert expand("203.0.113.11", "UGHS") == ("host", "203.0.113.11")
    assert expand("10.0.188.2/31", "UGSc") == ("net", "10.0.188.2/31")
    assert expand("0/5", "UGScg") == ("net", "0.0.0.0/5")
    assert expand("default", "UGSc") is None and expand("link#11", "UCS") is None
    assert internet_default_present([Route("default", "192.168.1.1", "UGScg", "en0")])
    assert not internet_default_present([Route("default", "link#19", "UCSIg", "bridge100")]), "Internet Sharing bridge is not an internet path"
    assert not internet_default_present([Route("default", "link#24", "UCSIg", "utun7")])
    assert find_tunnel([Route("100.100.1.5", "100.100.1.5", "UHr", "utun3"), Route("10.0.201.192", "10.0.201.193", "UHr", "utun7")]) == ("utun7", "10.0.201.192", "10.0.201.193"), "self-peer tunnel (Tailscale-style) must be skipped"
    assert find_tunnel([Route("10.8.0.1", "10.8.0.1", "UHr", "utun2")]) is None
    assert not internet_default_present([Route("default", "10.0.1.1", "UGSc", "utun7"), Route("10.25/16", "10.0.1.1", "UGSc", "utun7")])
    assert expand("300.1.1.1", "UGHS") is None and expand("10/40", "UGSc") is None
    assert classify("10.26.0.0/16") == "cidr" and classify("10.25.8.118") == "ip"
    assert classify("jira.example.com") == "domain" and classify("10.26.4.27/32") == "cidr"
    assert classify("not valid!") is None and classify("::1") is None and classify("localhost") is None
    assert entry_error("10.26.0.0/16", "cidr") is None and entry_error("jira.x.com", "domain") is None
    assert entry_error("0.0.0.0/0", "cidr").startswith("prefix") and entry_error("10.0.0.0/7", "cidr")
    assert entry_error("127.0.0.1", "ip") and entry_error("224.0.0.0/8", "cidr") and entry_error("169.254.1.1", "ip")
    assert classify("*.example.com") == "wildcard" and classify("*.bad!") is None and classify("*.") is None
    assert classify("private") == "private" and entry_error("private", "private") is None
    pt = private_targets([ipaddress.ip_network("192.168.1.0/24"), ipaddress.ip_network("10.20.96.0/20")])
    nets = [ipaddress.ip_network(t[1]) for t in pt]
    assert ("net", "172.16.0.0/12") in pt and ("net", "10.0.0.0/8") not in pt and ("net", "192.168.0.0/16") not in pt
    for ex in ("192.168.1.7", "10.20.100.5"):
        assert not any(ipaddress.ip_address(ex) in n for n in nets), "LAN address must be carved out: " + ex
    for inside in ("10.26.4.27", "10.25.8.118", "192.168.10.2", "172.20.1.1"):
        assert any(ipaddress.ip_address(inside) in n for n in nets), "internal address must be covered: " + inside
    assert all(n.prefixlen >= MIN_PREFIX for n in nets)
    assert private_targets([]) == [("net", "10.0.0.0/8"), ("net", "172.16.0.0/12"), ("net", "192.168.0.0/16")]
    assert private_targets([ipaddress.ip_network("10.0.0.0/8")]) == [("net", "172.16.0.0/12"), ("net", "192.168.0.0/16")]
    assert lan_carve([Route("192.168.1/24", "link#11", "UCS", "en0"), Route("192.168.1.1/32", "link#11", "UCS", "en0"),
                      Route("10.229.0.128/25", "link#30", "UCS", "utun8")]) == [ipaddress.ip_network("192.168.1.0/24")]
    assert entry_error("*.example.com", "wildcard") is None
    we = Entry("*.example.com", "wildcard", True, "", 0)
    assert we.suffix == "example.com" and we.targets() == []
    we.ips = ["1.2.3.4"]
    assert we.targets() == [("host", "1.2.3.4")]
    # DNS A-record parser: header + 1 question (a.b, A/IN) + 2 A answers via a compression pointer
    q = bytes([0,1, 0x81,0x80, 0,1, 0,2, 0,0, 0,0]) + bytes([1,97,1,98,0]) + bytes([0,1,0,1])
    ans = bytes([0xC0,0x0C, 0,1,0,1, 0,0,0,60, 0,4, 5,6,7,8]) + bytes([0xC0,0x0C, 0,1,0,1, 0,0,0,60, 0,4, 9,10,11,12])
    assert parse_a_records(q + ans) == ["5.6.7.8", "9.10.11.12"], parse_a_records(q + ans)
    assert parse_a_records(b"") == [] and parse_a_records(b"\x00" * 12) == []
    assert _query_name(q) == "a.b", _query_name(q)
    text = ("# header comment\n10.26.0.0/16  # QA database\n#off  Jira.example.com # jira\n"
            "10.25.8.118\n10.26.4.27/32\nbad entry\n\n#OFF 1.2.3.0/24\n0.0.0.0/0\n")
    es = parse_routes(text)
    assert [e.raw for e in es] == ["10.26.0.0/16", "jira.example.com", "10.25.8.118",
                                   "10.26.4.27/32", "bad entry", "1.2.3.0/24", "0.0.0.0/0"], [e.raw for e in es]
    assert [e.enabled for e in es] == [True, False, True, True, True, False, True]
    assert es[0].comment == "QA database" and es[1].comment == "jira" and es[2].comment == ""
    assert es[4].kind is None and es[4].error.startswith("invalid entry")
    # tunnel selection
    vs = parse_routes("10.50.0.0/16 via azure  # vnet\n*.corp.example via azure\n10.26.0.0/16 via checkpoint\n10.1.0.0/16 via mars\n")
    assert [(e.raw, e.via, e.kind) for e in vs[:3]] == [("10.50.0.0/16", "azure", "cidr"), ("*.corp.example", "azure", "wildcard"), ("10.26.0.0/16", "checkpoint", "cidr")], [(e.raw, e.via) for e in vs]
    assert vs[3].kind is None and "via azure|checkpoint" in vs[3].error
    assert split_if_conflict(("net", "10.26.0.0/16"), {("net", "10.26.0.0/16")}) == [("net", "10.26.0.0/17"), ("net", "10.26.128.0/17")]
    assert split_if_conflict(("net", "10.26.0.0/16"), {("net", "10.26.0.0/24")}) == [("net", "10.26.0.0/16")], "only an equal-prefix clash is split"
    assert split_if_conflict(("host", "10.26.4.27"), {("host", "10.26.4.27")}) == [("host", "10.26.4.27")]
    assert split_if_conflict(("net", "10.0.0.0/31"), {("net", "10.0.0.0/31")}) == [("host", "10.0.0.0"), ("host", "10.0.0.1")]
    assert es[6].kind is None and es[6].error.startswith("prefix") and es[6].targets() == []
    assert parse_routes("x" * 200 + "\n")[0].raw.endswith("…") and len(parse_routes("x" * 200)[0].raw) == 61
    assert es[0].targets() == [("net", "10.26.0.0/16")]
    assert es[2].targets() == [("host", "10.25.8.118")]
    assert es[3].targets() == [("host", "10.26.4.27")]
    es[1].ips = ["1.1.1.1", "2.2.2.2"]
    assert es[1].targets() == [("host", "1.1.1.1"), ("host", "2.2.2.2")]
    assert relevant(b"RTM_ADD: Add Route: len 160") and not relevant(b"RTM_MISS: Lookup failed")
    lan = lan_networks([Route("192.168.1/24", "link#11", "UCS", "en0"), Route("default", "192.168.1.1", "UGScg", "en0"),
                        Route("10.25/16", "10.0.203.59", "UGSc", "utun7"), Route("127", "127.0.0.1", "UCS", "lo0"),
                        Route("169.254", "link#11", "UCS", "en0")])
    assert [str(n) for n in lan] == ["192.168.1.0/24", "169.254.0.0/16"], lan
    scutil = ("DNS configuration\n\nresolver #1\n  search domain[0] : home-router\n"
              "  nameserver[0] : 10.0.10.16\n  nameserver[1] : 192.168.1.1\n  nameserver[2] : 10.80.20.180\n"
              "  nameserver[3] : 8.8.8.8\n  nameserver[4] : 10.0.10.16\n  if_index : 11 (en0)\n\n"
              "resolver #2\n  nameserver[0] : 10.99.99.99\n  domain : local\n\n"
              "DNS configuration (for scoped queries)\n\nresolver #1\n  nameserver[0] : 10.77.77.77\n")
    assert parse_dns_servers(scutil, lan) == ["10.0.10.16", "10.80.20.180"], parse_dns_servers(scutil, lan)
    # office DNS 192.168.10.2 is off-subnet (Wi-Fi is 10.20.96/20) -> only the baseline tells it is not the VPN's
    office = "DNS configuration\n\nresolver #1\n  nameserver[0] : 192.168.10.2\n  if_index : 11 (en0)\nresolver #2\n"
    office_lan = [ipaddress.ip_network("10.20.96.0/20")]
    assert parse_dns_servers(office, office_lan) == ["192.168.10.2"]
    assert parse_dns_servers(office, office_lan, exclude=["192.168.10.2"]) == []
    assert resolver_servers(office) == ["192.168.10.2"]
    assert lan_gateway([Route("default", "10.20.96.1", "UGScg", "en0"), Route("default", "link#24", "UCSIg", "utun7")]) == ("10.20.96.1", "en0")
    assert lan_gateway([Route("default", "link#24", "UCSIg", "utun7")]) is None
    assert parse_dns_servers("resolver #1\n  nameserver[0] : 192.168.1.1\n", lan) == []
    d = dns_entries(["10.0.10.16"])[0]
    assert d.kind == "dns" and d.auto and d.targets() == [("host", "10.0.10.16")]
    # tiling detection: many of OUR routes must not look like hub-mode tiling (the flapping bug)
    ours = {("host", "13.235.116.%d" % i) for i in range(1, 15)} | {("net", "10.26.0.0/16"), ("net", "10.25.0.0/16")}
    mine = [Route("13.235.116.%d" % i, "10.0.201.192", "UGHS", "utun7") for i in range(1, 15)] + \
           [Route("10.26/16", "10.0.201.192", "UGSc", "utun7"), Route("10.25/16", "10.0.201.192", "UGSc", "utun7"),
            Route("10.0.201.192", "10.0.201.193", "UHr", "utun7")]
    assert not tiling_present(mine, "utun7", ours), "own routes mistaken for tiling"
    cp = mine + [Route(d, "10.0.201.192", "UGSc", "utun7") for d in ("0/5", "8/7", "64/3", "128.0/2")]
    assert tiling_present(cp, "utun7", ours), "real tiles not detected"
    assert tiling_present(cp, "utun7", set()), "fresh connection (nothing applied yet) must detect tiling"
    few = mine + [Route("203.0.113.11", "10.0.201.192", "UGHS", "utun7")]
    assert not tiling_present(few, "utun7", ours), "a stray foreign host route is not tiling"
    # debounce must end despite continuous noise, and must end within max_wait despite continuous real events
    rfd, wfd = os.pipe()
    stop = {"v": False}

    def noise(payload):
        while not stop["v"]:
            os.write(wfd, payload)
            time.sleep(0.05)
    t = threading.Thread(target=noise, args=(b"RTM_MISS: Lookup failed\n",), daemon=True)
    t0 = time.time(); t.start(); drain_events(rfd, quiet=0.3, max_wait=5.0); stop["v"] = True; t.join()
    took = time.time() - t0
    assert 0.25 <= took < 1.0, "noise extended debounce: %.2fs" % took
    stop["v"] = False
    t = threading.Thread(target=noise, args=(b"RTM_ADD: Add Route\n",), daemon=True)
    t0 = time.time(); t.start(); drain_events(rfd, quiet=0.3, max_wait=0.8); stop["v"] = True; t.join()
    took = time.time() - t0
    assert 0.75 <= took < 1.5, "max_wait not honoured: %.2fs" % took
    os.close(rfd); os.close(wfd)
    _e2e_test()
    print("self-test OK")


def _e2e_test():
    """Drive evaluate() against a fake routing table and a temp config/state dir (no root, no network):
    split strips the tiling but leaves a stray 'default' alone, adds desired + DNS routes, refuses a
    /0 entry; full mode restores; an expired timer strips again; stale backups and symlinked config
    files are rejected."""
    global sh, log, _fetch_public_ip, STATE_DIR, STATUS_FILE, APPLIED_FILE, BACKUP_DIR, CONF_DIR, ROUTES_FILE, CONTROL_FILE, RESOLVER_DIR
    import shutil
    import tempfile
    saved = (sh, log, _fetch_public_ip, STATE_DIR, STATUS_FILE, APPLIED_FILE, BACKUP_DIR, CONF_DIR, ROUTES_FILE, CONTROL_FILE, RESOLVER_DIR)
    tmp = tempfile.mkdtemp()
    STATE_DIR = os.path.join(tmp, "state")
    BACKUP_DIR, STATUS_FILE, APPLIED_FILE = STATE_DIR + "/backups", STATE_DIR + "/status.json", STATE_DIR + "/applied.json"
    CONF_DIR = os.path.join(tmp, "config")
    ROUTES_FILE, CONTROL_FILE = CONF_DIR + "/routes.conf", CONF_DIR + "/control.json"
    RESOLVER_DIR = os.path.join(tmp, "resolver")
    os.makedirs(BACKUP_DIR)
    os.makedirs(CONF_DIR)
    os.makedirs(RESOLVER_DIR)
    _dynamic.clear()
    with _fwd_lock:
        _fwd["port"] = 53          # pretend the forwarder bound :53 so sync_resolvers installs files
        _fwd["suffixes"] = set()
        _fwd["upstream"] = []
    # The installer runs this as root. The daemon refuses root-owned config, so the test's config
    # must belong to a real user: the sudo caller if there is one, otherwise 'nobody'.
    test_uid = os.geteuid()
    if test_uid == 0:
        import pwd
        test_uid = pwd.getpwnam(os.environ.get("SUDO_USER") or "nobody").pw_uid

    def uwrite(path, text):
        _write(path, text)
        if os.geteuid() == 0:
            os.chown(path, test_uid, -1)
    if os.geteuid() == 0:
        os.chown(CONF_DIR, test_uid, -1)
    uwrite(ROUTES_FILE, "10.26.0.0/16  # db\n10.25.8.118\n0.0.0.0/0  # must be refused\n*.example.com\n10.50.0.0/16 via azure  # vnet\n")
    uwrite(CONTROL_FILE, '{"mode": "split", "full_until": null}')

    GW, LOCAL = "10.0.203.59", "10.0.203.60"
    tiles = ["0/5", "8/7", "10/17", "11", "12/6", "16/4", "32/3", "64/3", "96/4", "112/5", "120/7", "128.0/2"]
    table = [("default", "192.168.1.1", "UGScg", "en0"), ("192.168.1/24", "link#11", "UCS", "en0"),
             (GW, LOCAL, "UHr", "utun7"), ("default", GW, "UGSc", "utun7")]
    table += [(d, GW, "UGSc", "utun7") for d in tiles]
    N_TILES = len(tiles)
    # Azure VPN Client on utun8: scoped default + interface routes, and it also announces 10.26/16
    table += [("default", "link#30", "UCSIg", "utun8"), ("10.26/16", "link#30", "UCS", "utun8"),
              ("10.229.0.128/25", "link#30", "UCS", "utun8"), ("10.229.0.130", "10.229.0.130", "UH", "utun8")]
    AZ_BASE = 4

    def utun():
        return [t for t in table if t[3] == "utun7"]

    def dests():
        return {expand(t[0], t[2]) for t in utun()} - {None}

    class R(object):
        returncode, stdout, stderr = 0, "", ""

    scutil_ns = [["10.0.10.16", "192.168.1.1"]]          # mutable so phases can change what the VPN "pushed"

    def fake_sh(cmd):
        r = R()
        if cmd[0] == "netstat":
            r.stdout = "Routing tables\n\nInternet:\nDestination Gateway Flags Netif Expire\n" + \
                       "\n".join("%s %s %s %s" % t for t in table) + "\n"
        elif cmd[0] == "scutil":
            r.stdout = "DNS configuration\n\nresolver #1\n" + "".join("  nameserver[%d] : %s\n" % (i, a) for i, a in enumerate(scutil_ns[0]))
        elif cmd[0] == "ifconfig":
            r.stdout = "utun8: flags=8051 mtu 1500\n\tinet 10.229.0.130 --> 10.229.0.130 netmask 0xffffff80\n" if cmd[1] == "utun8" else "utun7: inet 10.0.203.60 --> 10.0.203.59\n"
        elif cmd[0] == "route":
            action = cmd[2]
            kind, target = (cmd[3][1:], cmd[4]) if action != "get" else ("", cmd[3])
            if action == "get":
                dst = cmd[3]
                best = None
                for t in table:
                    e = expand(t[0], t[2])
                    if not e: continue
                    net = ipaddress.ip_network(e[1] if "/" in e[1] else e[1] + "/32", strict=False)
                    if ipaddress.ip_address(dst) in net and (best is None or net.prefixlen > best[0]):
                        best = (net.prefixlen, t[3])
                r.stdout = "   interface: %s\n" % (best[1] if best else "en0")
                return r
            if "-interface" in cmd:
                iface, gw, flags = cmd[cmd.index("-interface") + 1], "link#30", ("UHS" if kind == "host" else "UCS")
            else:
                gw = cmd[5] if len(cmd) > 5 else ""
                iface, flags = ("en0" if gw == "192.168.1.1" else "utun7"), ("UGHS" if kind == "host" else "UGSc")
            if action == "delete":
                # real `route delete` matches the destination on any interface (first match)
                hits = [i for i, t in enumerate(table) if expand(t[0], t[2]) == (kind, target)]
            else:
                hits = [i for i, t in enumerate(table) if expand(t[0], t[2]) == (kind, target)]   # kernel: one route per prefix
            if action == "add":
                if hits:
                    r.returncode, r.stderr = 1, "route: writing to routing socket: File exists"
                else:
                    table.append((target, gw, flags, iface))
            elif hits:
                del table[hits[0]]
            else:
                r.returncode, r.stderr = 1, "route: not in table"
        return r

    sh, log, _fetch_public_ip = fake_sh, (lambda *a: None), (lambda: None)
    try:
        st, ctx = State(), Ctx()
        assert ctx.conf_error is None, ctx.conf_error
        assert [e.raw for e in ctx.entries] == ["10.26.0.0/16", "10.25.8.118", "0.0.0.0/0", "*.example.com", "10.50.0.0/16"]
        assert ctx.entries[2].kind is None and ctx.entries[2].error.startswith("prefix")
        assert ctx.entries[3].kind == "wildcard" and ctx.entries[4].via == "azure"

        # leftover from an earlier session: our /17 re-parented onto en0 with a dead gateway
        table.append(("10.26/17", "10.0.202.181", "UGSc", "en0"))
        table.append(("10.0.10.16", "10.0.202.181", "UGHS", "en0"))
        table.append(("10.80.20.180", "10.0.202.181", "UGHS", "en0"))   # not in config, not a current DNS server
        table.append(("10.0.0.0/8", "192.168.1.1", "UGSc", "en0"))        # legit DHCP static route via the LAN router
        table.append(("10.9.9.1", "10.9.9.2", "UH", "ppp0"))              # another VPN (L2TP/IKEv2 style): peer address
        table.append(("172.20.0.0/16", "10.9.9.1", "UGSc", "ppp0"))        #   ... and a route through that peer: NOT ours
        table.append(("172.21.0.0/16", "10.9.9.1", "UGSc", "en5"))         # same peer gw parked on USB-Ethernet: dead
        assert {t for t, _ in dead_gateway_routes([Route(*x) for x in table])} == \
            {("net", "10.26.0.0/17"), ("host", "10.0.10.16"), ("host", "10.80.20.180"), ("net", "172.21.0.0/16")}
        evaluate(st, ctx, True)                                     # split
        d = dests()
        assert not any(t[3] == "en0" and t[1] == "10.0.202.181" for t in table), "stale en0 routes must be swept: %r" % [t for t in table if t[3] == "en0"]
        assert ("10.0.0.0/8", "192.168.1.1", "UGSc", "en0") in table, "on-link gateway routes must be kept"
        assert ("172.20.0.0/16", "10.9.9.1", "UGSc", "ppp0") in table, "another VPN's peer-gateway routes must be kept"
        assert ("172.21.0.0/16", "10.9.9.1", "UGSc", "en5") not in table, "dead gateway on en5 must be swept"
        # Azure also announces 10.26/16 -> Check Point gets two /17s instead of the /16 so it wins
        assert ("net", "10.26.0.0/17") in d and ("net", "10.26.128.0/17") in d and ("net", "10.26.0.0/16") not in d, d
        assert ("host", "10.25.8.118") in d and ("host", "10.0.10.16") in d, d
        assert ("net", "0.0.0.0/5") not in d and ("net", "0.0.0.0/0") not in d, d
        assert ("default", GW, "UGSc", "utun7") in table, "stray default on utun must be left alone"
        assert len(utun()) == 6, utun()
        az_routes = {expand(t[0], t[2]) for t in table if t[3] == "utun8"} - {None}
        assert ("net", "10.50.0.0/16") in az_routes, az_routes                  # 'via azure' entry on Azure's interface
        assert ("net", "10.50.0.0/16") not in d, "azure entry must not touch Check Point's tunnel"
        assert ("net", "10.26.0.0/16") in az_routes, "Azure's own route untouched"
        status = json.load(open(STATUS_FILE))
        assert status["mode"] == "split" and status["route_count"] == 6 and status["tiling"] is False
        assert status["azure"]["connected"] is True and status["azure"]["if"] == "utun8"
        assert [e["kind"] for e in status["entries"]] == ["cidr", "ip", None, "wildcard", "cidr", "dns"], status["entries"]
        assert [e["via"] for e in status["entries"]][:5] == ["checkpoint", "checkpoint", "checkpoint", "checkpoint", "azure"]
        assert next(e for e in status["entries"] if e["raw"] == "10.50.0.0/16")["applied"] is True
        assert next(e for e in status["entries"] if e["raw"] == "10.26.0.0/16")["applied"] is True
        assert st.backup and os.path.exists(os.path.join(st.backup, "deleted_routes.txt"))
        assert sum(1 for _ in open(os.path.join(st.backup, "deleted_routes.txt"))) == N_TILES

        # wildcard: resolver file installed for the enabled suffix, and only ours is touched
        assert os.path.exists(os.path.join(RESOLVER_DIR, "example.com")), os.listdir(RESOLVER_DIR)
        assert open(os.path.join(RESOLVER_DIR, "example.com")).readline().strip() == RESOLVER_MARK
        _write(os.path.join(RESOLVER_DIR, "keepme"), "nameserver 9.9.9.9\n")   # someone else's file
        wc = next(e for e in status["entries"] if e["kind"] == "wildcard")
        assert wc["resolver"] is True and wc["ips"] == [], wc
        # a browser lookup arrives: forwarder records a public IP -> reconcile adds a host route
        _record_ips("api.example.com", ["93.184.216.34", "10.9.9.9"])          # private one must be ignored
        evaluate(st, ctx)
        assert ("host", "93.184.216.34") in dests() and ("host", "10.9.9.9") not in dests(), dests()
        wc = next(e for e in json.load(open(STATUS_FILE))["entries"] if e["kind"] == "wildcard")
        assert wc["ips"] == ["93.184.216.34"], wc
        # disable the wildcard: route and resolver file go away, the foreign file stays
        uwrite(ROUTES_FILE, "10.26.0.0/16  # db\n10.25.8.118\n#off *.example.com\n")
        ctx.entries, ctx.conf_error = load_entries()
        evaluate(st, ctx)
        assert ("host", "93.184.216.34") not in dests(), "disabled wildcard route must be removed"
        assert not os.path.exists(os.path.join(RESOLVER_DIR, "example.com")), "our resolver file must be gone"
        assert os.path.exists(os.path.join(RESOLVER_DIR, "keepme")), "must never delete a file we did not create"
        uwrite(ROUTES_FILE, "10.26.0.0/16  # db\n10.25.8.118\n0.0.0.0/0  # must be refused\n*.example.com\n10.50.0.0/16 via azure  # vnet\n")
        ctx.entries, ctx.conf_error = load_entries()
        evaluate(st, ctx)

        uwrite(CONTROL_FILE, '{"mode": "full", "full_until": null}')  # full: restore
        scutil_ns[0] = ["192.168.1.1"]                                   # ... and this time the VPN pushed no DNS
        evaluate(st, ctx)
        assert len(utun()) == 2 + N_TILES, utun()
        assert ("host", "10.25.8.118") not in dests() and st.applied == set()
        assert json.load(open(STATUS_FILE))["mode"] == "full"
        assert ("192.168.1.1", "192.168.1.1", "UGHS", "en0") in table, "LAN DNS must stay reachable in Full VPN when none was pushed"
        assert "pushed no DNS" in (json.load(open(STATUS_FILE))["note"] or "")
        scutil_ns[0] = ["10.0.10.16", "192.168.1.1"]

        uwrite(CONTROL_FILE, '{"mode": "full", "full_until": %f}' % (time.time() - 1))  # expired -> split
        evaluate(st, ctx)
        assert len(utun()) == 6 and ("net", "10.26.0.0/17") in dests(), utun()
        assert ("192.168.1.1", "192.168.1.1", "UGHS", "en0") not in table and st.applied_lan == set(), "LAN DNS route goes away in split"
        assert ("net", "10.50.0.0/16") in {expand(t[0], t[2]) for t in table if t[3] == "utun8"}, "azure route survives mode changes"
        assert open(CONTROL_FILE).read().startswith('{"mode": "full"'), "root must never rewrite control.json"
        assert json.load(open(STATUS_FILE))["mode"] == "split"

        # zero-config: `private` routes every RFC1918 range except the LAN (192.168.1/24 in the fake table)
        uwrite(ROUTES_FILE, "private   # all internal networks\n")
        ctx.entries, ctx.conf_error = load_entries()
        evaluate(st, ctx)
        pd = dests()
        pnets = [ipaddress.ip_network(t[1]) for t in pd if t[0] == "net" and t[1] != "0.0.0.0/0"]
        assert ("net", "10.0.0.0/8") in pd and ("net", "172.16.0.0/12") in pd, pd
        assert not any(ipaddress.ip_address("192.168.1.50") in n for n in pnets), "LAN must stay local"
        assert any(ipaddress.ip_address("192.168.10.2") in n for n in pnets), "other private space goes via VPN"
        st_e = [e for e in json.load(open(STATUS_FILE))["entries"] if e["raw"] == "private"][0]
        assert st_e["kind"] == "private" and st_e["applied"] is True and len(st_e["ips"]) == len(pnets), st_e

        assert find_session_backup(GW, time.time() + 3600) is None, "backup older than the connection must be ignored"
        assert find_session_backup(GW, st.since) == st.backup

        os.remove(ROUTES_FILE)
        os.symlink("/etc/hosts", ROUTES_FILE)
        es, err = load_entries()
        assert es == [] and err and "not readable" in err, (es, err)
        os.remove(ROUTES_FILE)
        os.mkdir(ROUTES_FILE)
        if os.geteuid() == 0:
            os.chown(ROUTES_FILE, test_uid, -1)
        es, err = load_entries()
        assert es == [] and "regular file" in err, err
        if os.geteuid() == 0:                                       # root-owned file must be refused too
            os.rmdir(ROUTES_FILE)
            _write(ROUTES_FILE, "10.26.0.0/16\n")
            es, err = load_entries()
            assert es == [] and "owned by uid 0" in err, err
    finally:
        sh, log, _fetch_public_ip, STATE_DIR, STATUS_FILE, APPLIED_FILE, BACKUP_DIR, CONF_DIR, ROUTES_FILE, CONTROL_FILE, RESOLVER_DIR = saved
        shutil.rmtree(tmp, ignore_errors=True)


def show_status():
    try:
        with open(STATUS_FILE) as f:
            d = json.load(f)
    except (OSError, ValueError) as e:
        sys.exit("no status: %s" % e)
    age = time.time() - d.get("ts", 0)
    print("daemon %s, status age %.0fs%s" % (d.get("daemon_version"), age, " (STALE)" if age > 75 else ""))
    v = d.get("vpn", {})
    print("vpn: %s" % ("connected %s gw %s" % (v.get("if"), v.get("gw")) if v.get("connected") else "not connected"))
    print("mode: %s%s" % (d.get("mode"), (" until " + time.strftime("%H:%M", time.localtime(d["full_until"])))
                          if d.get("full_until") else ""))
    print("routes on tunnel: %s (tiling: %s)   public ip: %s" % (d.get("route_count"), d.get("tiling"), d.get("public_ip")))
    if d.get("note"):
        print("note:", d["note"])
    for e in d.get("entries", []):
        flag = "on " if e["enabled"] else "off"
        extra = (" -> " + ", ".join(e["ips"])) if e.get("ips") else ""
        err = ("  ! " + e["error"]) if e.get("error") else ""
        print("  [%s] %-28s %-6s applied=%s%s%s" % (flag, e["raw"], e["kind"], e["applied"], extra, err))
    if d.get("last_action"):
        print("last action:", d["last_action"])


def main(argv):
    global DRY, ONCE
    if "--self-test" in argv:
        return self_test()
    if "--status" in argv:
        return show_status()
    DRY = "--dry-run" in argv
    ONCE = "--once" in argv
    if ONCE:
        if os.geteuid() != 0 and not DRY:
            sys.exit("--once without --dry-run needs root")
        st = State.load() if os.geteuid() == 0 else State()
        evaluate(st, Ctx(), force_resolve=True)
        return
    if DRY:
        sys.exit("--dry-run only makes sense with --once")
    run_daemon()


if __name__ == "__main__":
    main(sys.argv[1:])
