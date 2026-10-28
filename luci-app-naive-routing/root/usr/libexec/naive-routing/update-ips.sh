#!/bin/sh
# Nightly refresh of the static ADDRESS list (services without DNS).
#
# The list is converted into nft elements and applied to the static set
# directly, without any DNS involvement.

UCI_CONF="naive_routing"
# Accepts naive_routing.settings.<option> and naive_routing.<option>.
opt() {
	v=$(uci -q get "$UCI_CONF.settings.$1" 2>/dev/null)
	[ -n "$v" ] || v=$(uci -q get "$UCI_CONF.$1" 2>/dev/null)
	[ -n "$v" ] || v="$2"
	echo "$v"
}

URL=$(opt ips_url "https://raw.githubusercontent.com/1andrevich/Re-filter-lists/main/ipsum.lst")
DST=$(opt static_ips "/etc/naive-routing/blocked_ips.nft")
SET_STATIC=$(opt set_static "ru-static")
SOCKS_PORT=$(opt socks_port "11081")
MIN=${IPS_MIN_ENTRIES:-$(opt ips_min_entries "1000")}
TMP="/tmp/naive-ips.lst"

log() { logger -t naive-ips "$*"; }

rm -f "$TMP"
curl -fsSL -m 20 -o "$TMP" "$URL" 2>/dev/null
[ -s "$TMP" ] || curl -fsSL -m 25 --socks5-hostname "127.0.0.1:$SOCKS_PORT" -o "$TMP" "$URL" 2>/dev/null
if [ ! -s "$TMP" ]; then
	log "download failed, keeping the existing list"
	rm -f "$TMP"; exit 0
fi

CNT=$(wc -l < "$TMP")
if [ "$CNT" -lt "$MIN" ]; then
	log "too small ($CNT < $MIN), keeping the existing list"
	rm -f "$TMP"; exit 0
fi

mkdir -p "$(dirname "$DST")"
# 0.0.0.0 and 255.255.255.255 are meaningless as route targets.
awk -v set="$SET_STATIC" '!/^0\.0\.0\.0(\/32)?$/ && !/^255\.255\.255\.255(\/32)?$/ && NF {
	print "add element inet fw4 " set " { " $1 " }"
}' "$TMP" > "$DST.new"
if [ -s "$DST.new" ]; then
	mv "$DST.new" "$DST"
	if nft list set inet fw4 "$SET_STATIC" >/dev/null 2>&1; then
		nft -f "$DST" 2>/dev/null
	fi
	log "static address list updated: $CNT entries -> $SET_STATIC"
fi
rm -f "$TMP"
exit 0
