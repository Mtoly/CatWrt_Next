include $(TOPDIR)/rules.mk

# UAmask is built from upstream source by scripts/build-packages.sh and passed in
# through UAMASK_BIN; this Makefile only assembles the APK so the GPL-3.0 sources
# stay out of this GPL-2.0-only repository.
PKG_NAME:=UAmask
PKG_VERSION:=0.4.3
PKG_RELEASE:=1

PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

UAMASK_LUA_DIR:=/usr/lib/lua/luci

define Package/UAmask
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=A transparent proxy for changing User-Agent (nftables)
  URL:=https://github.com/Zesuy/UA-Mask
  DEPENDS:=+luci-compat +libubox
  CONFLICTS:=ua3f-tproxy ua3f-tproxy-ipt UAmask-ipt
endef

define Package/UAmask/description
	A transparent proxy (TPROXY) for modifying HTTP User-Agent.
	This is the default version using nftables (firewall4).
endef

define Package/UAmask/conffiles
/etc/config/UAmask
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/files/luci
	$(CP) "$(UAMASK_BIN)" $(PKG_BUILD_DIR)/UAmask
	$(CP) "$(UAMASK_SRC)/LICENSE" $(PKG_BUILD_DIR)/LICENSE
	$(CP) "$(UAMASK_FILES)/UAmask.init" $(PKG_BUILD_DIR)/files/UAmask.init
	$(CP) "$(UAMASK_FILES)/UAmask.uci" $(PKG_BUILD_DIR)/files/UAmask.uci
	$(CP) "$(UAMASK_FILES)/luci/cbi.lua" $(PKG_BUILD_DIR)/files/luci/cbi.lua
	$(CP) "$(UAMASK_FILES)/luci/controller.lua" $(PKG_BUILD_DIR)/files/luci/controller.lua
endef

define Build/Compile
endef

define Package/UAmask/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/UAmask $(1)/usr/bin/UAmask
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/UAmask.init $(1)/etc/init.d/UAmask
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/files/UAmask.uci $(1)/etc/config/UAmask
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/files/luci/cbi.lua $(1)$(UAMASK_LUA_DIR)/model/cbi/UAmask.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/files/luci/controller.lua $(1)$(UAMASK_LUA_DIR)/controller/UAmask.lua
endef

# The prebuilt Go binary is already stripped; OpenWrt's sstrip corrupts its
# section-header string table when applied a second time.
RSTRIP:=:

$(eval $(call BuildPackage,UAmask))
