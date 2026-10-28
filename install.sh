#!/bin/sh
# ============================================================================
# Manual installation without building an OpenWrt package.
#
#   ./install.sh            install or upgrade
#   ./install.sh uninstall  remove everything this script installed
#
# The script installs files only; configuration is left to UCI:
#   /etc/config/naive_routing
# Set proxy_url there before enabling the service.
# ============================================================================
set -e

ACTION=${1:-install}
ROOT=${ROOT:-}
# Package sources live in the subdirectory named after the package, so that the
# repository can be used directly as an OpenWrt feed.
PKG="${PKG:-$(cd "$(dirname "$0")" && pwd)/luci-app-naive-routing}"
if [ -z "$ROOT" ] && [ "$(id -u)" != "0" ]; then
	echo "install.sh: run as root, or set ROOT to install into a staging tree" >&2
	exit 1
fi

# BusyBox has no install(1), so plain cp plus chmod is used.
copy() {
	src=$1; dst=$2; mode=${3:-0644}
	mkdir -p "$(dirname "$ROOT$dst")"
	cp "$src" "$ROOT$dst" && chmod "$mode" "$ROOT$dst"
	echo "  $dst"
}

case "$ACTION" in
install)
	echo "==> installing luci-app-naive-routing"
	copy "$PKG/root/usr/bin/naive-ctl"                          /usr/bin/naive-ctl 0755
	copy "$PKG/root/usr/libexec/naive-routing/health.sh"         /usr/libexec/naive-routing/health.sh 0755
	copy "$PKG/root/usr/libexec/naive-routing/update-domains.sh" /usr/libexec/naive-routing/update-domains.sh 0755
	copy "$PKG/root/usr/libexec/naive-routing/update-ips.sh"     /usr/libexec/naive-routing/update-ips.sh 0755
	copy "$PKG/root/etc/init.d/naive-routing"                    /etc/init.d/naive-routing 0755
	copy "$PKG/root/etc/nftables.d/10-naive-sets.nft"            /etc/nftables.d/10-naive-sets.nft
	copy "$PKG/root/usr/share/luci/menu.d/luci-app-naive-routing.json" /usr/share/luci/menu.d/luci-app-naive-routing.json
	copy "$PKG/root/usr/share/rpcd/acl.d/luci-app-naive-routing.json"  /usr/share/rpcd/acl.d/luci-app-naive-routing.json
	copy "$PKG/root/www/luci-static/resources/view/naive_routing/overview.js" \
		/www/luci-static/resources/view/naive_routing/overview.js

	# configuration and lists: never overwrite existing files on upgrade
	for f in direct_domains.txt proxy_domains.txt; do
		if [ -f "$ROOT/etc/naive-routing/$f" ]; then
			echo "  /etc/naive-routing/$f (kept)"
		else
			copy "$PKG/root/etc/naive-routing/$f" /etc/naive-routing/$f
		fi
	done
	if [ -f "$ROOT/etc/config/naive_routing" ]; then
		echo "  /etc/config/naive_routing (kept)"
	else
		copy "$PKG/root/etc/config/naive_routing" /etc/config/naive_routing
	fi

	# The watchdog and the list updaters are procd instances of the init
	# script, so no crontab entries are created any more.
	echo "==> enabling the service"
	if [ -z "$ROOT" ]; then
		/etc/init.d/naive-routing enable >/dev/null 2>&1 || true
	fi

	echo "==> restarting services"
	if [ -z "$ROOT" ]; then
		fw4 reload >/dev/null 2>&1 || true
		/etc/init.d/rpcd reload >/dev/null 2>&1 || true
		rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true
	fi

	echo
	echo "Done. Set the upstream server and enable the service:"
	echo "  uci set naive_routing.settings.proxy_url='https://user:password@vps.example.com'"
	echo "  uci commit naive_routing"
	echo "  /etc/init.d/naive-routing enable && /etc/init.d/naive-routing start"
	;;
uninstall)
	echo "==> uninstalling luci-app-naive-routing"
	/etc/init.d/naive-routing stop 2>/dev/null || true
	/etc/init.d/naive-routing disable 2>/dev/null || true
	rm -f "$ROOT"/usr/bin/naive-ctl
	rm -rf "$ROOT"/usr/libexec/naive-routing
	rm -f "$ROOT"/etc/init.d/naive-routing
	rm -f "$ROOT"/etc/nftables.d/10-naive-sets.nft
	rm -f "$ROOT"/usr/share/luci/menu.d/luci-app-naive-routing.json
	rm -f "$ROOT"/usr/share/rpcd/acl.d/luci-app-naive-routing.json
	rm -f "$ROOT"/www/luci-static/resources/view/naive_routing/overview.js
	# Legacy cleanup: versions up to 1.0.3 scheduled the watchdog through cron.
	sed -i '/naive-routing/d' /etc/crontabs/root 2>/dev/null || true
	/etc/init.d/cron reload >/dev/null 2>&1 || true
	fw4 reload >/dev/null 2>&1 || true
	echo "  files removed; /etc/config/naive_routing and /etc/naive-routing are kept"
	;;
*)
	echo "usage: $0 [install|uninstall]" >&2
	exit 2
	;;
esac
