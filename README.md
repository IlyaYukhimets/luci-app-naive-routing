**English** | [Русский](README.ru.md)

# luci-app-naive-routing

Domain-based split routing for [naiveproxy](https://github.com/klzgrad/naiveproxy) on OpenWrt.
The kernel intercepts only the destinations that the routing lists select; all other
traffic stays on the direct path. If the tunnel stops working, the intercept is removed
automatically, so connectivity never depends on the proxy.

LuCI page: state, on/off switch, connection count, domain decision lookup, editable lists.

---

## Design

Routing is decided in three layers.

**1. Domain → address (DNS resolver).** The package does not ship a DNS server. It plugs
into the resolver that is already running and hands it the domain lists. On every
resolution of a listed domain the resolver adds the resulting A records to an nftables
set. Only domains that are actually visited are resolved, so a list of 80 000 entries
does not require 80 000 lookups per day.

**2. Address → set (nftables).** Three sets exist in the `inet fw4` table:

| set | contents | filled by |
|---|---|---|
| `ru-blocked` | dynamic | DNS resolver, for domains from the intercept lists |
| `ru-static` | static | updater script, address lists for services without DNS |
| `naive-direct` | dynamic | DNS resolver, for domains from the bypass list |

**3. Set → action (nat/prerouting).** Rules in this order:

1. `ip daddr <vps_ip> counter return` — anti-loop: traffic to the server itself must not
   be redirected into the tunnel.
2. `ip daddr @naive-direct counter return` — **bypass, placed before the intercept**.
   A domain can be present in both the intercept list and the bypass list (this is the
   normal case for a large upstream list). Rule order decides, therefore upstream list
   updates cannot break the bypass.
3. `ip daddr @ru-blocked` / `@ru-static` `tcp dport { 80, 443 }` → `redirect to :<redir_port>`.

A separate `quic_block` chain handles QUIC. naiveproxy carries TCP only, so UDP/443
towards an intercepted address cannot be proxied. The default policy `reject` answers
such a datagram with ICMP port-unreachable: the client switches to TCP, which is
intercepted, within milliseconds. Two details make this the correct default rather than
an unnecessary cut. First, the destination is in the intercept list because it is
unreachable directly, so letting QUIC out means the handshake dies at the provider and
the client waits for its own timeout before falling back. Second, a QUIC Initial packet
carries the ClientHello behind a publicly derivable key, so the hostname is readable to
the provider in plaintext; through the tunnel the only visible name is the server's.

`quic_policy direct` leaves UDP/443 untouched. It is appropriate when an address is in
the intercept list but is in fact reachable directly and profits from HTTP/3; in that
case the hostname is exposed to the provider, which for an unblocked destination is not
a concern. Set it with `naive-ctl set-quic direct` or from the LuCI page.

The rule matches `udp dport 443` only. Other UDP traffic (games, WireGuard, VoIP,
DNS) is not touched, and QUIC towards addresses in the bypass list already goes out
directly because the bypass rule precedes the reject.

### Fail-safe

A watchdog runs from cron every minute. It probes the **real exit address** through the
SOCKS listener (`https://1.1.1.1/cdn-cgi/trace`) rather than checking whether the process
exists — naive binds its ports before it is able to proxy. Exit address equal to the
server address means the tunnel is alive: rules are installed. Anything else means the
intercept is removed and traffic goes direct.

A failed DNS lookup of the server name is not treated as evidence of a dead tunnel: the
last known address is reused instead.

---

## Requirements

* OpenWrt 23.05 or newer with `fw4` (nftables). Tested on 25.12.
* LuCI 24.10 or newer. The page uses the JavaScript view model introduced in 23.05 and
  is exercised on 24.10 and 25.12.
* `naiveproxy` client (`/usr/bin/naive`). It is **not part of the official feed**, so it
  must come from a third-party feed such as `openwrt-passwall-packages` or from a
  self-built package. The package declares a conditional dependency
  (`+PACKAGE_naiveproxy:naiveproxy`), which applies only when the client package exists
  in the build tree; a hard dependency would make this package unbuildable.
* A DNS backend, one of:
  * `smartdns` — domain sets plus `nftset`, and per-domain AAAA suppression;
  * `dnsmasq-full` — `nftset=` support. The base `dnsmasq` package may be built without
    it; the application reports this condition explicitly instead of failing silently.
* `nftables`, `kmod-nft-nat`, `curl`, `jsonfilter` (all present on a default image except
  where noted).

Footprint: the client binary is about 12.6 MB, the routing application (LuCI page, ACL,
`naive-ctl`, watchdog, both updaters) is about 56 KB, the domain and address lists are
about 2.5 MB.

---

## Installation

### Prebuilt packages

Every version tag triggers a GitHub Actions build with the official OpenWrt SDK
containers, and the artifacts are attached to the release:

* `luci-app-naive-routing-*.apk` — OpenWrt 25.x (apk-tools);
* `luci-app-naive-routing_*.ipk` — OpenWrt 24.10 and earlier (opkg).

The package contains only shell scripts and JavaScript and is built with
`PKGARCH:=all`, so one file per release line fits every target architecture of that
line.

```
# OpenWrt 24.10 and earlier
opkg update && opkg install ./luci-app-naive-routing_1.0.2-r1_all.ipk

# OpenWrt 25.x: the artifacts are not signed by a key present in the router, hence
# --allow-untrusted
apk add --allow-untrusted ./luci-app-naive-routing-1.0.2-r1.apk
```

The `naiveproxy` client is not included and is not pulled in automatically, see
Requirements. The build workflow lives in `.github/workflows/build.yml`.

### As a package

The repository is laid out as an OpenWrt feed: `luci-app-naive-routing/` holds the
package (Makefile, `root/`, `po/`), the repository root holds the license, the
documentation and the CI workflow. This layout is required — a `Makefile` in the feed
root makes the feed index generation fail.

```
# as a local feed inside an OpenWrt buildroot or SDK tree
echo "src-link naive /path/to/this/repository" >> feeds.conf
./scripts/feeds update naive && ./scripts/feeds install -p naive luci-app-naive-routing
make menuconfig      # LuCI -> Applications -> luci-app-naive-routing
make package/luci-app-naive-routing/compile V=s

# or straight into the package tree
git clone <this repository> package/naive-routing
make package/naive-routing/luci-app-naive-routing/compile V=s
```

The SDK produces both `ipk` (opkg) and `apk` (OpenWrt 25.x) artifacts. The LuCI build
machinery compiles `luci-app-naive-routing/po/ru/naive_routing.po` into the translation
catalog automatically.

Two details of the OpenWrt build system are not obvious and both are mandatory:

* The package must sit in a subdirectory of the feed, not in its root. `include/scan.mk`
  treats every `Makefile` under the feed as a package description, so a stray root
  `Makefile` breaks index generation with `target pattern contains no '%'`.
* The package `Makefile` must end with the signature comment
  `# call BuildPackage - OpenWrt buildroot signature`. The scanner locates packages by
  grepping for a `BuildPackage` call, and `luci.mk` hides the real one; without the
  comment the package silently never reaches the build metadata and
  `make package/luci-app-naive-routing/compile` reports `No rule to make target`.

### Manually, without building

```
scp -r . root@router:/tmp/luci-app-naive-routing
ssh root@router 'cd /tmp/luci-app-naive-routing && ./install.sh'
```

`./install.sh` copies files, registers the cron entries and reloads the affected
services. `./install.sh uninstall` removes the application files while keeping
`/etc/config/naive_routing` and `/etc/naive-routing`.

### The naiveproxy client

The package does not ship the client binary and does not pull it from a feed: `naiveproxy`
is absent from the official OpenWrt feeds. Install it from the upstream release that
matches the target architecture:

```
arch=$( . /etc/openwrt_release; echo $DISTRIB_ARCH )
ver=v154.0.8037.49-5
wget -O /tmp/naive.tar.xz \
  "https://github.com/klzgrad/naiveproxy/releases/download/$ver/naiveproxy-$ver-openwrt-$arch-static.tar.xz"
tar -xJf /tmp/naive.tar.xz -C /tmp
install -m 755 /tmp/naiveproxy-$ver-openwrt-$arch-static/naive /usr/bin/naive
```

Two points that are easy to get wrong:

* Take the `openwrt-<arch>-static` asset. The `linux-*` assets are dynamically linked
  against glibc and fail on OpenWrt with `not found`, because OpenWrt uses musl.
* `naive --version` prints only the Chromium version (`154.0.8037.49`); the release
  suffix (`-5`, `-4`) is not visible at runtime. Verify the patch level through the
  checksum of the downloaded archive, not through `--version`.

## Scheduling

The watchdog and the list updaters are started by the init script as supervised procd
instances, so no cron entries are created and a clean install needs no manual setup:

* `watchdog` runs `health.sh` every `watchdog_interval` seconds (default 60);
* `lists` runs `update-ips.sh` and `update-domains.sh` once a day at `update_hour`:`update_min`
  (default 03:30 local time).

Both are controlled from `/etc/config/naive_routing`:

```
uci set naive_routing.settings.watchdog='1'
uci set naive_routing.settings.watchdog_interval='60'
uci set naive_routing.settings.update_lists='1'
uci set naive_routing.settings.update_hour='3'
uci set naive_routing.settings.update_min='30'
uci commit naive_routing && /etc/init.d/naive-routing restart
```

## Migration from a manual installation

If the files were placed by hand, remove them before installing the package, otherwise
they stay untracked and later updates leave stale copies behind:

```
cp /etc/config/naive_routing /root/naive_routing.backup
rm -rf /usr/libexec/naive-routing /www/luci-static/resources/view/naive_routing
rm -f /usr/bin/naive-ctl /etc/nftables.d/10-naive-sets.nft
rm -f /usr/share/luci/menu.d/luci-app-naive-routing.json \
      /usr/share/rpcd/acl.d/luci-app-naive-routing.json
sed -i '/naive-routing\|naive-ctl/d' /etc/crontabs/root    # cron entries of the manual setup
/etc/init.d/naive stop; /etc/init.d/naive disable 2>/dev/null   # hand-written init script
apk add --allow-untrusted ./luci-app-naive-routing-1.0.2-r1.apk
cp /root/naive_routing.backup /etc/config/naive_routing
/etc/init.d/naive-routing enable && /etc/init.d/naive-routing start
```

`/etc/config/naive_routing` is deliberately preserved: it holds the tunnel address,
ports and policies, and the package default replaces them with empty values.

## Configuration

```
uci set naive_routing.settings.proxy_url='https://user:password@vps.example.com'
uci set naive_routing.settings.vps_domain='vps.example.com'
uci commit naive_routing
/etc/init.d/naive-routing enable
/etc/init.d/naive-routing start
/usr/libexec/naive-routing/health.sh
```

The client configuration (`/var/etc/naive/config.json`) is generated from UCI on every
start, so `/etc/config/naive_routing` is the single source of truth.

### Options

| option | default | meaning |
|---|---|---|
| `enabled` | `1` | intended state, informational |
| `proxy_url` | — | upstream URL including credentials |
| `vps_domain` | `vps.example.com` | server name, resolved for the anti-loop rule |
| `vps_ip` | — | pin the server address, skips resolution |
| `redir_port` | `11090` | redirect target for intercepted TCP |
| `socks_port` | `11081` | SOCKS listener used for probes |
| `concurrency` | `3` | parallel TLS connections (`insecure-concurrency`) |
| `dns_backend` | `auto` | `auto`, `smartdns`, `dnsmasq`, `none` |
| `quic_policy` | `reject` | `reject` (answer UDP/443 with ICMP unreachable) or `direct` |
| `big_list` | `/etc/naive-routing/blocked_domains.txt` | large domain list |
| `direct_list` | `/etc/naive-routing/direct_domains.txt` | bypass list |
| `proxy_list` | `/etc/naive-routing/proxy_domains.txt` | own additions to the intercept |
| `static_ips` | `/etc/naive-routing/blocked_ips.nft` | static address list |
| `static_ranges` | `/etc/naive-routing/ranges_ipv4.nft` | static ranges (services without DNS) |
| `chain_nat`, `chain_quic` | `nat_naive`, `quic_block` | nft chain names |
| `set_blocked`, `set_static`, `set_direct` | `ru-blocked`, `ru-static`, `naive-direct` | nft set names |
| `domains_min_entries` | `20000` | updater guard, see below |
| `ips_min_entries` | `1000` | updater guard, see below |

Both UCI layouts are accepted: `naive_routing.settings.<option>` (as shipped) and
`naive_routing.<option>` (hand-written configs).

An existing manual installation can be reused: point `naive_config`, `init_script`,
`health_script`, `big_list`, `direct_list`, `proxy_list`, `static_ips` and
`static_ranges` at the current paths and leave `proxy_url` empty.

---

## Domain lists

Domains are entered one per line. Subdomains are inherited. Lines starting with `#`
and empty lines are ignored, and comments survive saving from the LuCI page. Input is
normalised on apply: scheme, path and port are stripped, upper case is lowered, invalid
entries are dropped, duplicates are collapsed.

* `direct_list` — bypass. Wins over the intercept list because of rule order.
* `proxy_list` — own additions to the intercept, on top of the large list.

Decision lookup: the LuCI page section *Where will a domain go*, or
`naive-ctl check example.com`. The answer is derived from the lists, and the resolved
addresses are shown for reference.

**The domain path requires that LAN clients use the router as their DNS server.** If a
client is configured for DoH/DoT to an external resolver (browser "secure DNS", Android
Private DNS), the resolver never sees the domain and the corresponding addresses do not
reach the sets. Such traffic falls back to the static address list or goes direct.

---

## DNS backends

`auto` selects `smartdns` when its configuration file exists and the process is running,
otherwise `dnsmasq`.

**smartdns.** The application writes `/etc/smartdns/custom.conf` (path configurable)
containing `domain-set` declarations, `nftset` bindings, `nftset-timeout 3600` and
`domain-rules … -address #6` to suppress AAAA for intercepted domains.

**dnsmasq.** The application writes `<dnsmasq_dir>/naive-routing.conf` with `nftset=`
directives in the documented form `nftset=/<domains>/4#inet#fw4#<set>`, split into
chunks to keep every line short. dnsmasq merges several directives that target the same
set. The `confdir` option of dnsmasq is pointed at a persistent directory, because the
OpenWrt default is `/tmp/dnsmasq.d` and would not survive a reboot. Per-domain AAAA
suppression is not available in dnsmasq; on networks without IPv6 this has no practical
effect.

Switch: `naive-ctl set-dns <auto|smartdns|dnsmasq|none>`, or the selector on the LuCI
page. `naive-ctl dns-check` reports the active backend and whether its build provides
`nftset`.

---

## Speed versus stealth

`concurrency` maps to `--insecure-concurrency` of naive. A single connection is limited
to roughly 11-13 MB/s by the HTTP/2 flow-control window; the limit does not depend on
the link. Parallel TLS connections remove that ceiling for parallel workloads (browsers,
package managers, layer pulls), not for a single stream.

Measured on a 250 Mbit/s uplink with 36 ms RTT to the server (OpenWrt on a Xiaomi
AX3000T, single core pair):

| configuration | three parallel streams |
|---|---|
| `concurrency = 1` | 11.3 MB/s |
| `concurrency = 3` | 20.8 MB/s |
| three separate client processes | 20-24 MB/s |

The price is analytical: more simultaneous TLS connections to one domain are less
consistent with browser behaviour. The naive author states this explicitly in `USAGE.txt`
("More connections make the tunneling easier to detect and less secure") and recommends
no more than four. Use `1` when stealth matters more than throughput.

---

## Updaters

Two cron jobs, both installed by `install.sh`:

* `30 3 * * *` `update-ips.sh` — static address list
  (`Re-filter-lists/ipsum.lst` by default) converted to nft elements and applied to
  `ru-static`.
* `40 3 * * *` `update-domains.sh` — large domain list
  (`Re-filter-lists/domains_all.lst` by default).

Both download directly first and through the tunnel as a fallback, normalise the
content, refuse to replace an existing list when the result is smaller than the
configured threshold, and skip the reload when nothing changed. `update-domains.sh`
verifies that the resolver still answers and restores the previous list otherwise. Logs
go to `logread` with tags `naive-ips` and `naive-domains`.

---

## Diagnostics

```
naive-ctl status                 # key=value, the same data the LuCI page renders
naive-ctl dns-check              # active backend and nftset support
naive-ctl check example.com      # list-level decision and resolved addresses
logread | grep naive-           # watchdog, DNS backend and updater events
nft list chain inet fw4 nat_naive
nft list set inet fw4 ru-blocked
```

Frequent causes of "a listed domain still goes direct":

* the client resolves through its own DoH/DoT, so the domain never reaches the resolver;
* the domain is in `direct_list`, which wins by rule order;
* the resolver has no `nftset` support (base `dnsmasq` instead of `dnsmasq-full`);
* the resolver was restarted before the nft sets existed, so it never registered its
  bindings — `naive-ctl apply` runs the watchdog first and then the resolver reload,
  which is the required order.

`state=down` with a live tunnel usually means the exit address could not be verified
(probe blocked, `curl` missing) or the server address could not be resolved and no
previous address was known.

---

## Limitations

* TCP only. naiveproxy does not carry UDP, therefore games, QUIC-based streaming and part
  of voice traffic cannot be proxied; the QUIC reject rule exists to force the TCP
  fallback.
* A single stream remains limited by the HTTP/2 window regardless of `concurrency`.
* Domain routing depends on the router being the DNS server for the LAN.
* The application does not implement the proxy protocol itself. It supervises the
  official naive client, whose TLS fingerprint is the reason naive survives DPI. Do not
  replace it with a reimplementation.

---

## Credits

* [klzgrad/naiveproxy](https://github.com/klzgrad/naiveproxy) — client and the Caddy
  `forwardproxy` fork used on the server side.
* [1andrevich/Re-filter-lists](https://github.com/1andrevich/Re-filter-lists) — domain and
  address lists used by the default updater configuration.
* OpenWrt `fw4` and `dnsmasq` documentation for the nftables set and `nftset` interfaces.

## License

MIT, see [LICENSE](LICENSE).
