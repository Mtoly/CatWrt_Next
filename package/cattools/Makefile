include $(TOPDIR)/rules.mk

PKG_NAME:=cattools
# Keep in sync with the package version in Cargo.toml.
PKG_VERSION:=1.0.1
PKG_RELEASE:=2
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/cattools
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=CatWrt configuration toolbox
endef

define Build/Compile
endef

define Package/cattools/install
	@test -n "$(CATTOOLS_BIN)" || { echo "cattools: CATTOOLS_BIN must name the prebuilt static binary" >&2; exit 1; }
	@test -f "$(CATTOOLS_BIN)" || { echo "cattools: missing prebuilt binary: $(CATTOOLS_BIN)" >&2; exit 1; }
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) "$(CATTOOLS_BIN)" $(1)/usr/bin/cattools
endef

define Package/cattools/postinst
#!/bin/sh
if [ -e "$${IPKG_INSTROOT}/www/logs.txt" ] || [ -L "$${IPKG_INSTROOT}/www/logs.txt" ]; then
	rm "$${IPKG_INSTROOT}/www/logs.txt" || exit 1
fi
exit 0
endef

$(eval $(call BuildPackage,cattools))
