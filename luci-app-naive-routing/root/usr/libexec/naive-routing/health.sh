#!/bin/sh
# ============================================================================
# health.sh — fail-safe watchdog for the naiveproxy intercept (fw4/nftables).
#
# Part of luci-app-naive-routing. Runs from cron every minute and at boot.
#
#   1. naive not running -> start it and wait for the SOCKS port.
#   2. Probe the REAL exit IP through the tunnel (socks), not the process state:
#      naive binds the port before it can actually proxy.
#   3. Tunnel alive -> keep the intercept rules. Tunnel dead -> remove them and
#      let traffic go direct (connectivity must never depend on the tunnel).
#   4. Disabled flag present -> remove rules, keep the tunnel running.
#   5. QUIC (UDP/443) towards intercepted addresses is rejected: naive is
#      TCP-only, otherwise clients silently bypass the tunnel over UDP.
#
# Sets:
#   set_blocked — dynamic, filled by the DNS resolver (domain -> address map)
#   set_static  — static address lists (services that work without DNS)
#   set_direct  — dynamic bypass; its rule is placed BEFORE the intercept rules
# ============================================================================

UCI_CONF="naive_routing"

# Read an option from UCI. Both layouts are accepted: the named section used by
# the shipped config (naive_routing.settings.<option>) and a bare named section
# (naive_routing.<option>), which is what hand-written configs often use.
opt() {
	v=$(uci -q get "$UCI_CONF.settings.$1" 2>/dev/null)
	[ -n "$v" ] || v=$(uci -q get "$UCI_CONF.$1" 2>/dev/null)
	[ -n "$v" ] || v="$2"
	echo "$v"
}

VPS_DOMAIN=$(opt vps_domain "vps.example.com")
VPS_IP_OVERRIDE=$(opt vps_ip "")
SOCKS_PORT=$(opt socks_port "11081")
REDIR_PORT=$(opt redir_port "11090")
CHAIN_NAT=$(opt chain_nat "nat_naive")
CHAIN_QUIC=$(opt chain_quic "quic_block")
# reject: answer UDP/443 with ICMP port-unreachable so the client switches to
# TCP at once. direct: leave UDP/443 alone.
QUIC_POLICY=$(opt quic_policy "reject")
SET_BLOCKED=$(opt set_blocked "ru-blocked")
SET_STATIC=$(opt set_static "ru-static")
SET_DIRECT=$(opt set_direct "naive-direct")
INIT_NAIVE=$(opt init_script "/etc/init.d/naive")
ELEMENTS=$(opt static_ips "/etc/naive/blocked_elements.nft")
RANGES=$(opt static_ranges "/etc/naive/ranges_ipv4.nft")
DISABLED=$(opt disabled_flag "/etc/naive/disabled")
STATE=$(opt state_file "/tmp/naive_state")
EXITFILE=$(opt exit_file "/tmp/naive_exit_ip")
STATIC_MIN=$(opt static_min_entries "40")

log() { logger -t naive-failsafe "$*"; }

# --- 1. is naive running? ---
# The bracket class matters: pgrep -f matches the whole command line, so the
# literal "/usr/bin/naive" matches the calling shell itself (cron wrapper,
# interactive command) and naive would be considered running while it is not.
NEED_WAIT=0
if ! pgrep -f "/usr/bin/[n]aive" >/dev/null 2>&1; then
	log "naive is not running -> starting"
	"$INIT_NAIVE" start 2>/dev/null
	NEED_WAIT=1
fi

if [ "$NEED_WAIT" = "1" ]; then
	i=0
	while [ "$i" -lt 15 ]; do
		netstat -ln 2>/dev/null | grep -q ":$SOCKS_PORT" && break
		sleep 1
		i=$((i + 1))
	done
	sleep 1
fi

# --- 2. VPS address (needed for the anti-loop rule) ---
resolve_ip() {
	nslookup "$VPS_DOMAIN" "$1" 2>/dev/null \
		| awk '/^Address[ 0-9]*:/ {print $NF}' \
		| grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
		| tail -1
}
if [ -n "$VPS_IP_OVERRIDE" ]; then
	VPS_IP="$VPS_IP_OVERRIDE"
else
	VPS_IP=$(resolve_ip 127.0.0.1)
	[ -z "$VPS_IP" ] && VPS_IP=$(resolve_ip 8.8.8.8)
	# Resolution failure is a local DNS problem, NOT evidence that the tunnel is
	# down. Fall back to the last known address; tearing the rules down on a
	# failed lookup would flap the intercept on every resolver hiccup.
	if [ -z "$VPS_IP" ]; then
		VPS_IP=$(cat /tmp/naive_vps_ip 2>/dev/null)
		[ -n "$VPS_IP" ] && log "cannot resolve $VPS_DOMAIN, using the last known address $VPS_IP"
	fi
fi
[ -n "$VPS_IP" ] && echo "$VPS_IP" > /tmp/naive_vps_ip

# --- 3. sets: create and seed ---
# `fw4 reload` recreates the table: elements are lost, the set object may
# survive. Check contents, not existence.
for S in "$SET_BLOCKED" "$SET_STATIC" "$SET_DIRECT"; do
	nft list set inet fw4 "$S" >/dev/null 2>&1 || \
		nft add set inet fw4 "$S" '{ type ipv4_addr; flags interval; auto-merge; }' 2>/dev/null
done

# DNS-based blockers may answer 0.0.0.0; such an address is useless in a set.
for S in "$SET_BLOCKED" "$SET_STATIC"; do
	nft delete element inet fw4 "$S" '{ 0.0.0.0 }' 2>/dev/null
done

cnt_of() {
	nft list set inet fw4 "$1" 2>/dev/null \
		| grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]+)?' | wc -l
}

# Static lists: ranges first (the file starts with a flush), then single IPs.
if [ -s "$RANGES" ] && [ "$(cnt_of "$SET_STATIC")" -lt "$STATIC_MIN" ]; then
	nft -f "$RANGES" 2>/dev/null && log "$SET_STATIC: $(cnt_of "$SET_STATIC") entries (ranges)"
	[ -s "$ELEMENTS" ] && nft -f "$ELEMENTS" 2>/dev/null && \
		log "$SET_STATIC: $(cnt_of "$SET_STATIC") entries (addresses)"
fi

# Fallback: the intercept set is still empty (no DNS resolution yet, domain
# lists not loaded). Seed it with static addresses so the intercept works now.
if [ "$(cnt_of "$SET_BLOCKED")" -lt 10 ] && [ -s "$ELEMENTS" ]; then
	nft -f "$ELEMENTS" 2>/dev/null && log "$SET_BLOCKED: seeded from static list"
fi

# --- 4. tunnel probe: real exit IP ---
check_exit_ip() {
	curl -s -m 8 --socks5-hostname "127.0.0.1:$SOCKS_PORT" https://1.1.1.1/cdn-cgi/trace 2>/dev/null \
		| grep '^ip=' | head -1 | cut -d= -f2
}

EXIT_IP=""
if command -v curl >/dev/null 2>&1; then
	i=0
	while [ "$i" -lt 4 ]; do
		EXIT_IP=$(check_exit_ip)
		[ -n "$EXIT_IP" ] && break
		sleep 3
		i=$((i + 1))
	done
fi
echo "${EXIT_IP:-}" > "$EXITFILE"

install_rules() {
	C="$1"; TYPE="$2"; PROTO="$3"; ACT="$4"
	nft delete chain inet fw4 "$C" 2>/dev/null
	nft add chain inet fw4 "$C" "$TYPE" 2>/dev/null
	nft add rule inet fw4 "$C" ip daddr "$VPS_IP" counter return 2>/dev/null
	# Bypass rule goes FIRST: a domain can be in both the intercept set and the
	# bypass set (which is the case for github while it stays in the big list).
	# Rule order decides, so list updates cannot break the bypass.
	nft add rule inet fw4 "$C" iifname "br-lan" ip daddr "@$SET_DIRECT" counter return 2>/dev/null
	for S in "$SET_BLOCKED" "$SET_STATIC"; do
		nft add rule inet fw4 "$C" iifname "br-lan" ip daddr "@$S" "$PROTO" counter $ACT 2>/dev/null
	done
}

remove_chains() {
	for C in "$CHAIN_NAT" "$CHAIN_QUIC"; do
		nft list chain inet fw4 "$C" >/dev/null 2>&1 && nft delete chain inet fw4 "$C" 2>/dev/null
	done
}

if [ -e "$DISABLED" ]; then
	if nft list chain inet fw4 "$CHAIN_NAT" >/dev/null 2>&1; then
		remove_chains
		log "intercept disabled by flag -> direct"
	fi
	echo "off" > "$STATE"
elif [ -n "$VPS_IP" ] && [ "$EXIT_IP" = "$VPS_IP" ]; then
	RULES=$(nft list chain inet fw4 "$CHAIN_NAT" 2>/dev/null | grep -c 'redirect to')
	BYPASS=$(nft list chain inet fw4 "$CHAIN_NAT" 2>/dev/null | grep -c "@$SET_DIRECT")
	if [ "$RULES" = "0" ] || [ "$BYPASS" = "0" ]; then
		install_rules "$CHAIN_NAT" '{ type nat hook prerouting priority -100; policy accept; }' \
			'tcp dport { 80, 443 }' "redirect to :$REDIR_PORT"
		log "tunnel UP (exit=$EXIT_IP) -> TCP intercept ENABLED"
	fi

	case "$QUIC_POLICY" in
	direct|none|off)
		if nft list chain inet fw4 "$CHAIN_QUIC" >/dev/null 2>&1; then
			nft delete chain inet fw4 "$CHAIN_QUIC" 2>/dev/null
			log "QUIC policy direct -> UDP/443 left untouched"
		fi
		;;
	*)
		QRULES=$(nft list chain inet fw4 "$CHAIN_QUIC" 2>/dev/null | grep -c 'udp dport 443')
		QBYPASS=$(nft list chain inet fw4 "$CHAIN_QUIC" 2>/dev/null | grep -c "@$SET_DIRECT")
		if [ "$QRULES" = "0" ] || [ "$QBYPASS" = "0" ]; then
			install_rules "$CHAIN_QUIC" '{ type filter hook forward priority 0; policy accept; }' \
				'udp dport 443' 'reject'
			log "QUIC rejected -> clients fall back to TCP"
		fi
		;;
	esac

	echo "up" > "$STATE"
else
	if nft list chain inet fw4 "$CHAIN_NAT" >/dev/null 2>&1; then
		nft delete chain inet fw4 "$CHAIN_NAT" 2>/dev/null
		log "tunnel DOWN (exit='$EXIT_IP') -> TCP intercept DISABLED, direct"
	fi
	if nft list chain inet fw4 "$CHAIN_QUIC" >/dev/null 2>&1; then
		nft delete chain inet fw4 "$CHAIN_QUIC" 2>/dev/null
		log "QUIC block removed (tunnel down)"
	fi
	echo "down" > "$STATE"
fi

exit 0
