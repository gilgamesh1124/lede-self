include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for Wired Mesh Networking (batman-adv)
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+luci-compat +luci-lua-runtime +kmod-batman-adv +batctl-default +iwinfo

PKG_VERSION:=1.0
PKG_RELEASE:=1

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
