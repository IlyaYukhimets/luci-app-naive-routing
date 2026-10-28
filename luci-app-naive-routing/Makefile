# SPDX-License-Identifier: MIT
#
# OpenWrt package for the LuCI naiveproxy split-routing application.
# Build with the OpenWrt SDK: the SDK produces ipk on 24.10 and earlier and apk
# on 25.x from the same source. Manual installation: ./install.sh in the
# repository root.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-naive-routing
PKG_VERSION:=1.0.1
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Ilya Yukhimets <bosikmobile105@gmail.com>

LUCI_TITLE:=LuCI application for naiveproxy split routing
LUCI_DESCRIPTION:=Domain-based split routing for naiveproxy: the kernel intercepts \
\ only what the domain and address lists select, everything else goes direct. \
\ Fail-safe by the real exit address.
LUCI_PKGARCH:=all
# luci.mk defaults these to the generic LuCI values; ?= means a value set here wins.
LUCI_URL:=https://github.com/IlyaYukhimets/luci-app-naive-routing
LUCI_MAINTAINER:=Ilya Yukhimets <bosikmobile105@gmail.com>
# naiveproxy is not part of the official feed, so a hard dependency would make
# this package unbuildable. The conditional dependency is applied only when the
# client package exists in the build tree, for example from the
# openwrt-passwall-packages feed.
#
# kmod-nft-nat is not listed: firewall4 is mandatory for this application (the
# rules live in table inet fw4) and already depends on it. Listing it here would
# additionally force a kernel build in SDK and CI runs.
LUCI_DEPENDS:=+nftables +curl +jsonfilter +PACKAGE_naiveproxy:naiveproxy

include $(TOPDIR)/feeds/luci/luci.mk

# The package scanner in include/scan.mk locates packages by grepping for a
# BuildPackage call, which luci.mk hides. This signature line is required for the
# package to enter the build metadata at all - every LuCI package carries it.
# call BuildPackage - OpenWrt buildroot signature
