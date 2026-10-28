#!/bin/sh
# Nightly refresh of the big DOMAIN list used by the DNS resolver.
#
# Why: the domain list is the source for the dynamic intercept set. Without a
# refresh, newly blocked domains never reach the tunnel and nothing reports it.
#
#   1. download (direct, then through the tunnel);
#   2. normalise and drop junk;
#   3. sanity-check the entry count;
#   4. replace atomically only if the content changed;
#   5. reload the DNS backend and verify it answers; roll back otherwise.
#
# Threshold override for testing: DOMAINS_MIN_ENTRIES=999999999 update-domains.sh

UCI_CONF="naive_routing"
# Accepts naive_routing.settings.<option> and naive_routing.<option>.
opt() {
	v=$(uci -q get "$UCI_CONF.settings.$1" 2>/dev/null)
	[ -n "$v" ] || v=$(uci -q get "$UCI_CONF.$1" 2>/dev/null)
	[ -n "$v" ] || v="$2"
	echo "$v"
}

URL=$(opt domains_url "https://raw.githubusercontent.com/1andrevich/Re-filter-lists/main/domains_all.lst")
DST=$(opt big_list "/etc/naive-routing/blocked_domains.txt")
SOCKS_PORT=$(opt socks_port "11081")
MIN=${DOMAINS_MIN_ENTRIES:-$(opt domains_min_entries "20000")}
MAX=${DOMAINS_MAX_ENTRIES:-2000000}
TMP="/tmp/naive-domains.lst"
PREV="/tmp/naive-domains.prev"

log() { logger -t naive-domains "$*"; }

rm -f "$TMP" "$TMP.new"
curl -fsSL -m 40 -o "$TMP" "$URL" 2>/dev/null
[ -s "$TMP" ] || curl -fsSL -m 60 --socks5-hostname "127.0.0.1:$SOCKS_PORT" -o "$TMP" "$URL" 2>/dev/null
if [ ! -s "$TMP" ]; then
	log "download failed, keeping the existing list"
	rm -f "$TMP"; exit 0
fi

# Tolerate adblock-like entries (||domain^), schemes, paths, upper case.
tr -d '\r' < "$TMP" \
	| sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
	      -e 's|^[a-zA-Z]*://||' -e 's|/.*$||' \
	      -e 's/^||//' -e 's/^\*\.//' -e 's/\^$//' -e 's/\.$//' \
	| tr 'A-Z' 'a-z' \
	| grep -E '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' \
	| grep -vE '^(localhost|0\.0\.0\.0|255\.255\.255\.255)$' \
	| sort -u > "$TMP.new"

CNT=$(wc -l < "$TMP.new" 2>/dev/null || echo 0)
if [ "$CNT" -lt "$MIN" ]; then
	log "too small ($CNT < $MIN), keeping the existing list"
	rm -f "$TMP" "$TMP.new"; exit 0
fi
if [ "$CNT" -gt "$MAX" ]; then
	log "suspiciously large ($CNT > $MAX), keeping the existing list"
	rm -f "$TMP" "$TMP.new"; exit 0
fi
if [ -f "$DST" ] && cmp -s "$TMP.new" "$DST"; then
	log "no changes ($CNT domains)"
	rm -f "$TMP" "$TMP.new"; exit 0
fi

OLDCNT=$(wc -l < "$DST" 2>/dev/null || echo 0)
mkdir -p "$(dirname "$DST")"
cp "$DST" "$PREV" 2>/dev/null
mv "$TMP.new" "$DST"
rm -f "$TMP"

if [ -x /usr/bin/naive-ctl ]; then
	naive-ctl apply >/dev/null 2>&1
else
	/etc/init.d/smartdns reload >/dev/null 2>&1 || /etc/init.d/dnsmasq reload >/dev/null 2>&1
fi
sleep 3
if nslookup example.com 127.0.0.1 >/dev/null 2>&1; then
	log "domains updated: $OLDCNT -> $CNT"
	rm -f "$PREV"; exit 0
fi
if [ -f "$PREV" ]; then
	mv "$PREV" "$DST"
	/etc/init.d/smartdns restart >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1
	log "resolver did not answer with the new list, rolled back to $OLDCNT domains"
fi
exit 1
