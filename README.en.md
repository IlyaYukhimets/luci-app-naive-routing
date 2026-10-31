**English** | [Русский](README.md)

# luci-app-naive-routing

Domain-based routing for [naiveproxy](https://github.com/klzgrad/naiveproxy) on OpenWrt.
The kernel intercepts only those destination addresses selected by the routing lists; the
rest of the traffic goes direct. When the tunnel fails, interception is removed
automatically, so connectivity never depends on the proxy.

The LuCI page has three tabs: Overview (state and the interception switch), Settings
(client parameters, DNS backend, QUIC policy) and Routes (per-domain decision check and
list editors). Parameter explanations live in tooltips, which keeps the page readable.

---

## Design

Routing is decided at three levels.

**1. Domain → address (DNS resolver).** The package ships no resolver of its own. It
attaches to the resolver already running and hands it the domain lists. On every resolution
of a listed domain the resolver adds the resulting A records to an nftables set. Only
domains actually visited are resolved, so a list of 80,000 entries does not require 80,000
queries per day.

**2. Address → set (nftables).** The `inet fw4` table holds three sets:

| set | contents | filled by |
|---|---|---|
| `ru-blocked` | dynamic | the resolver, from the intercept domain lists |
| `ru-static` | static | the address list refresh, for services without DNS |
| `naive-direct` | dynamic | the resolver, from the bypass domain list |

**3. Set → action (nat/prerouting).** Rules in this order:

1. `ip daddr <vps_ip> counter return` — anti-loop: traffic to the server itself must not be
   routed back into the tunnel.
2. `ip daddr @naive-direct counter return` — **the bypass rule is placed before the
   interception rule**. A domain can appear in both the intercept list and the bypass list
   (normal for a large external list). Rule order decides, so external list updates cannot
   break the bypass.
3. `ip daddr @ru-blocked` / `@ru-static` `tcp dport { 80, 443 }` → `redirect to :<redir_port>`.

A separate `quic_block` chain handles QUIC. naiveproxy carries TCP only, therefore UDP/443
towards an intercepted address cannot be proxied. The default `reject` policy answers such a
datagram with ICMP port-unreachable: the client switches to TCP, which is intercepted,
within milliseconds. The policy is correct by default rather than redundant. First, the
address is in the intercept list because it is unreachable directly: if QUIC is allowed, the
handshake fails at the provider and the client waits for its own timeout before falling back
to TCP. Second, a QUIC Initial packet carries the ClientHello under a public key, so the
hostname is readable by the provider in plaintext; through the tunnel only the server name
is visible.

`quic_policy direct` leaves UDP/443 untouched. It is justified when an address is listed but
actually reachable directly and benefits from HTTP/3; in that case the hostname becomes
visible to the provider, which does not matter for an unblocked address. Switch with
`naive-ctl set-quic direct` or from the Settings tab.

The rule matches `udp dport 443` only. Other UDP traffic (games, WireGuard, VoIP, DNS) is
untouched, and QUIC towards bypass addresses goes direct because the bypass rule precedes
the reject rule.

### Fail-safe

The state watchdog (`health.sh`) runs as a procd process every `watchdog_interval` seconds,
60 by default. It verifies the **actual exit address** through the SOCKS port
(`https://1.1.1.1/cdn-cgi/trace`) rather than the existence of the process: naive opens its
ports before it is able to proxy. A matching exit address means the tunnel is alive and the
rules are installed. Otherwise interception is removed and traffic goes direct.

A failed resolution of the server name is not treated as a tunnel failure: the last known
address is used instead.

---

## Requirements

* OpenWrt 23.05 or newer with `fw4` (nftables). Tested on 25.12.
* LuCI 24.10 or newer. The page uses the JavaScript view model introduced in 23.05; tested
  on 24.10 and 25.12.
* The `naiveproxy` client (`/usr/bin/naive`). It is **absent from the official feed** and is
  installed from the upstream release, see "The naiveproxy client". The package declares a
  conditional dependency (`+PACKAGE_naiveproxy:naiveproxy`) which applies only when the
  client exists in the build tree; a hard dependency would make the package unbuildable.
* A DNS backend, one of:
  * `smartdns` — domain sets plus `nftset`, and per-domain AAAA suppression;
  * `dnsmasq-full` — `nftset=` support. The base `dnsmasq` package may be built without it;
    the application reports this explicitly instead of failing silently.
* `nftables` with NAT support (provided by `firewall4`), `curl`, `jsonfilter`.

Footprint: the client binary is about 12.6 MB, the application (LuCI page, ACL, `naive-ctl`,
state watchdog, two list refresh scripts) about 56 KB, the domain and address lists about
2.5 MB.

---

## Installation

### Prebuilt packages

Every version tag runs a GitHub Actions build with the official OpenWrt SDK containers and
attaches the results to the release:

* `luci-app-naive-routing-*.apk` — OpenWrt 25.x (apk-tools);
* `luci-app-naive-routing_*.ipk` — OpenWrt 24.10 and earlier (opkg);
* `luci-i18n-naive-routing-ru-*` — Russian interface translation, installed separately.

The package consists of shell scripts and JavaScript only and is built with
`PKGARCH:=all`, so one file per release line fits every architecture of that line.

```
# OpenWrt 24.10 and earlier
opkg update && opkg install ./luci-app-naive-routing_1.1.2-r1_all.ipk

# OpenWrt 25.x: the artifacts are not signed by a key present in the router, hence
# --allow-untrusted
apk add --allow-untrusted ./luci-app-naive-routing-1.1.2-r1.apk
```

The `naiveproxy` client is not part of the package and is not installed automatically, see
"The naiveproxy client". The build scenario is `.github/workflows/build.yml`.

### As a package

The repository is laid out as an OpenWrt feed: the package lives in the
`luci-app-naive-routing/` directory (Makefile, `root/`, `po/`), the root holds the licence,
the documentation and the CI scenario. This layout is mandatory: a `Makefile` in the feed
root breaks index generation.

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

The SDK produces both artifacts: `ipk` (opkg) and `apk` (OpenWrt 25.x). The LuCI build
machinery compiles `luci-app-naive-routing/po/ru/naive_routing.po` into the translation
catalog automatically.

Two details of the OpenWrt build system are not obvious and both are mandatory:

* The package must sit in a subdirectory of the feed, not in its root. `include/scan.mk`
  treats every `Makefile` under the feed as a package description, so a stray root
  `Makefile` breaks index generation with `target pattern contains no '%'`.
* The package `Makefile` must end with the signature comment
  `# call BuildPackage - OpenWrt buildroot signature`. The scanner locates packages by
  grepping for a `BuildPackage` call, and `luci.mk` hides the real one; without the comment
  the package silently never reaches the build metadata and
  `make package/luci-app-naive-routing/compile` reports `No rule to make target`.

### Manually, without building

```
scp -r . root@router:/tmp/luci-app-naive-routing
ssh root@router 'cd /tmp/luci-app-naive-routing && ./install.sh'
```

`./install.sh` copies the files, registers the service and restarts the affected components.
No cron entries are created: the state watchdog and the list refresh run as procd processes.
`./install.sh uninstall` removes the application files while keeping
`/etc/config/naive_routing` and `/etc/naive-routing`.

### The naiveproxy client

The package neither ships nor pulls the client binary: `naiveproxy` is absent from the
official OpenWrt feeds. Install it from the upstream release matching the target
architecture:

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
  against glibc and fail on OpenWrt with `not found`, because OpenWrt uses musl. Check
  before installing: `strings -a naive | grep -c GLIBC_2` must be zero.
* `naive --version` prints only the Chromium version (`154.0.8037.49`); the release suffix
  (`-5`, `-4`) is not visible at runtime. Verify the patch level through the checksum of the
  downloaded archive, not through `--version`.

Replacing the binary without downtime: keep a copy, stop the service, move the new file into
place (do not copy over a running binary, otherwise `Text file busy`), start the service and
check `naive-ctl status` and `naive-ctl check <domain>`.

## Scheduling

The state watchdog and the list refresh scripts are started by the init script as supervised
procd processes, so no cron entries are created and a clean install needs no manual setup:

* the `watchdog` process runs `health.sh` every `watchdog_interval` seconds (60 by default);
* the `lists` process runs `update-ips.sh` and `update-domains.sh` once a day at
  `update_hour`:`update_min` (03:30 local time by default).

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

If the files were placed by hand, remove them before installing the package, otherwise they
stay untracked and later updates leave stale copies behind:

```
cp /etc/config/naive_routing /root/naive_routing.backup
rm -rf /usr/libexec/naive-routing /www/luci-static/resources/view/naive_routing
rm -f /usr/bin/naive-ctl /etc/nftables.d/10-naive-sets.nft
rm -f /usr/share/luci/menu.d/luci-app-naive-routing.json \
      /usr/share/rpcd/acl.d/luci-app-naive-routing.json
sed -i '/naive-routing\|naive-ctl/d' /etc/crontabs/root   # cron entries of the previous setup
/etc/init.d/naive stop; /etc/init.d/naive disable 2>/dev/null  # previous hand-written init script
apk add --allow-untrusted ./luci-app-naive-routing-1.1.2-r1.apk
cp /root/naive_routing.backup /etc/config/naive_routing
/etc/init.d/naive-routing enable && /etc/init.d/naive-routing start
```

`/etc/config/naive_routing` is deliberately preserved: it holds the tunnel address, ports
and policies, while the package default replaces them with empty values.

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

| option | default | purpose |
|---|---|---|
| `enabled` | `1` | desired state, informational |
| `proxy_url` | — | upstream server address including credentials |
| `vps_domain` | `vps.example.com` | server name, resolved for the anti-loop rule |
| `vps_ip` | — | pinned server address, no resolution is performed |
| `redir_port` | `11090` | redirect target for intercepted TCP |
| `socks_port` | `11081` | SOCKS port used by the checks |
| `concurrency` | `3` | number of parallel TLS connections (`insecure-concurrency`) |
| `dns_backend` | `auto` | `auto`, `smartdns`, `dnsmasq`, `none` |
| `quic_policy` | `reject` | `reject` (answer UDP/443 with an ICMP refusal) or `direct` |
| `big_list` | `/etc/naive-routing/blocked_domains.txt` | large domain list |
| `direct_list` | `/etc/naive-routing/direct_domains.txt` | bypass list |
| `proxy_list` | `/etc/naive-routing/proxy_domains.txt` | additional domains to intercept |
| `static_ips` | `/etc/naive-routing/blocked_ips.nft` | static address list |
| `static_ranges` | `/etc/naive-routing/ranges_ipv4.nft` | static ranges |
| `chain_nat`, `chain_quic` | `nat_naive`, `quic_block` | nft chain names |
| `set_blocked`, `set_static`, `set_direct` | `ru-blocked`, `ru-static`, `naive-direct` | nft set names |
| `watchdog` | `1` | run the state watchdog process |
| `watchdog_interval` | `60` | state check period, seconds |
| `update_lists` | `1` | run the list refresh process |
| `update_hour`, `update_min` | `3`, `30` | daily list refresh time |
| `domains_min_entries` | `20000` | minimum size of a refreshed domain list |
| `ips_min_entries` | `1000` | minimum size of a refreshed address list |

Both UCI schemas are supported: `naive_routing.settings.<option>` (as in the shipped
configuration) and `naive_routing.<option>` (common in hand-written configurations).

An existing manual installation can be reused: point `naive_config`, `init_script`,
`health_script`, `big_list`, `direct_list`, `proxy_list`, `static_ips` and `static_ranges`
at the current paths and leave `proxy_url` empty.

---

## The LuCI interface

The page lives under Network → naiveproxy routing. Three tabs:

* **Overview** — the interception switch (green while interception is off, red while it is
  on), a state label and a table of parameters: tunnel, exit address, server address, DNS
  backend, rule count, set sizes, traffic counters, list sizes. Each row carries an `i`
  badge with an explanation.
* **Settings** — connections to the server, the DNS backend with an `nftset` support check,
  and the QUIC policy. Every parameter has a tooltip with the rationale.
* **Routes** — the per-domain decision check and two list editors: bypass and additional
  domains to intercept. Saving a list applies the rules without restarting the client.

The page polls the state every 5 seconds and updates the table without a reload.

---

## Domain lists

Domains are entered one per line. Subdomains are inherited. Lines starting with `#` and
empty lines are ignored, and comments survive saving from the LuCI page. On apply the input
is normalised: scheme, path and port are dropped, the case is lowered, invalid entries are
removed and duplicates collapse.

* `direct_list` — bypass. It wins over the intercept list through rule order.
* `proxy_list` — additional domains to intercept, on top of the large list.

Decision check: the Routes tab of the LuCI page or `naive-ctl check example.com`. The answer
is built from the lists and resolved addresses are shown for reference.

**The domain path requires LAN clients to use the router as their DNS server.** If a client
uses DoH/DoT towards an external resolver ("secure DNS" in a browser, Private DNS on
Android), the resolver never sees the domain and the corresponding addresses never reach the
sets. Such traffic is served by the static address list or goes direct.

---

## DNS backends

`auto` picks `smartdns` when its configuration file exists and the process is running,
otherwise `dnsmasq`.

**smartdns.** The application writes `/etc/smartdns/custom.conf` (path configurable) with
`domain-set` declarations, `nftset` bindings, `nftset-timeout 3600` and
`domain-rules … -address #6` to suppress AAAA for intercepted domains.

**dnsmasq.** The application writes `<dnsmasq_dir>/naive-routing.conf` with `nftset=`
directives in the documented form `nftset=/<domains>/4#inet#fw4#<set>`, split into chunks so
that each line stays short. dnsmasq merges several directives targeting one set by itself.
The `confdir` option is moved to a persistent directory, because the OpenWrt default
(`/tmp/dnsmasq.d`) does not survive a reboot. Per-domain AAAA suppression is not available
in dnsmasq; in a network without IPv6 this has no practical effect.

Switching: `naive-ctl set-dns <auto|smartdns|dnsmasq|none>` or the selector on the Settings
tab. `naive-ctl dns-check` reports the active backend and whether the build supports
`nftset`.

---

## Speed versus stealth

The `concurrency` option corresponds to `--insecure-concurrency` in naive. A single
connection is capped at roughly 11-13 MB/s by the HTTP/2 flow control window; the cap does
not depend on the link. Parallel TLS connections lift that ceiling for parallel load
(browser, package managers, layer pulls) but not for a single stream.

Measured on a 250 Mbit/s link with 36 ms RTT to the server (OpenWrt on Xiaomi AX3000T):

| configuration | three parallel streams |
|---|---|
| `concurrency = 1` | 11.3 MB/s |
| `concurrency = 3` | 20.8 MB/s |
| three separate client processes | 20-24 MB/s |

The price is analytical: several simultaneous TLS connections to one domain are less
consistent with browser behaviour. The naive author states it plainly in `USAGE.txt`
("More connections make the tunneling easier to detect and less secure") and recommends no
more than four. Use `1` when stealth matters more than throughput.

---

## List refresh

Two tasks, both run by the `lists` process of the init script:

* `update-ips.sh` — the static address list (`Re-filter-lists/ipsum.lst` by default),
  converted into nft elements and applied to the `ru-static` set;
* `update-domains.sh` — the large domain list (`Re-filter-lists/domains_all.lst` by
  default).

Both try a direct download first and retry through the tunnel, normalise the content, refuse
to replace the existing list when the result is below the configured threshold, and do not
restart services when nothing changed. `update-domains.sh` additionally verifies that the
resolver answers and otherwise keeps the previous list. Events are logged to `logread` with
the tags `naive-ips` and `naive-domains`.

---

## Diagnostics

```
naive-ctl status                 # key=value, the same data the LuCI page shows
naive-ctl dns-check              # active backend and nftset support
naive-ctl check example.com      # list decision and resolved addresses
logread | grep naive-            # watchdog, DNS and list refresh events
nft list chain inet fw4 nat_naive
nft list set inet fw4 ru-blocked
```

Common causes of "the domain is listed but goes direct":

* the client resolves names over its own DoH/DoT and the domain never reaches the resolver;
* the domain is present in `direct_list`, which wins through rule order;
* the resolver build lacks `nftset` (base `dnsmasq` instead of `dnsmasq-full`);
* the resolver was restarted before the nft sets existed and did not register the bindings —
  `naive-ctl apply` starts the state watchdog first and restarts the resolver afterwards;
  this order is required.

`state=down` with a working tunnel usually means the exit address could not be verified (the
probe is blocked, `curl` is missing) or the server name did not resolve and no previous
address is known.

If the service does not come up after installation, check process registration:

```
ubus call service list | jsonfilter -e '@["naive-routing"].instances'
ls -l /usr/bin/naive-ctl /usr/libexec/naive-routing/*.sh
```

A non-executable file in a process command makes procd drop the whole service registration
without a message in the log.

---

## Limitations

* TCP only. naiveproxy does not carry UDP, so games, QUIC video streaming and part of the
  voice traffic will not pass through it; the QUIC reject rule exists to force the client
  onto TCP.
* A single stream stays limited by the HTTP/2 window regardless of `concurrency`.
* Domain routing depends on the router being the DNS server of the local network.
* The application does not implement the proxy protocol itself. It manages the official
  naive client, whose TLS fingerprint provides resistance to DPI. Replacing the client with
  an own implementation is not planned.

---

## Credits

* [klzgrad/naiveproxy](https://github.com/klzgrad/naiveproxy) — the client and the
  `forwardproxy` fork of Caddy used on the server side.
* [1andrevich/Re-filter-lists](https://github.com/1andrevich/Re-filter-lists) — the domain
  and address lists used by the default refresh configuration.
* The OpenWrt documentation on `fw4` and `dnsmasq` for the description of the nftables set
  and `nftset` interfaces.

## License

MIT, see [LICENSE](LICENSE).
