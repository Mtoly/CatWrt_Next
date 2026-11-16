include $(TOPDIR)/rules.mk

PKG_NAME:=catwrt-base
PKG_VERSION:=1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

CATWRT_VERSION?=dev
IMMORTALWRT_VERSION?=25.12.2
CATWRT_ARCH?=x86_64
CATWRT_BUILD_DATE?=

define Package/catwrt-base
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=CatWrt Next files and first-boot defaults
  DEPENDS:=+default-settings-chn
  # Must be set inside the package definition to take effect.
  PKGARCH:=all
endef

define Package/catwrt-base/conffiles
/etc/config/catwrt
endef

define Build/Compile
endef

define Package/catwrt-base/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/uci-defaults
	$(INSTALL_DIR) $(1)/etc/apk/keys $(1)/etc/apk/repositories.d
	# base-files owns /etc/banner; ship ours here and copy it on first boot.
	$(INSTALL_DIR) $(1)/usr/share/catwrt
	$(INSTALL_DATA) ./files/usr/share/catwrt/banner $(1)/usr/share/catwrt/banner
	$(INSTALL_DATA) ./files/usr/share/catwrt/banner.failsafe $(1)/usr/share/catwrt/banner.failsafe
	$(INSTALL_DATA) ./files/etc/catwrt_release $(1)/etc/catwrt_release
	$(SED) 's|@CATWRT_VERSION@|$(CATWRT_VERSION)|g; s|@IMMORTALWRT_VERSION@|$(IMMORTALWRT_VERSION)|g; s|@ARCH@|$(CATWRT_ARCH)|g; s|@BUILD_DATE@|$(CATWRT_BUILD_DATE)|g' $(1)/etc/catwrt_release
	$(INSTALL_DATA) ./files/etc/config/catwrt $(1)/etc/config/catwrt
	$(INSTALL_DATA) ./files/etc/apk/keys/catwrt-next.pem $(1)/etc/apk/keys/catwrt-next.pem
	$(INSTALL_DATA) ./files/etc/apk/repositories.d/catwrt.list $(1)/etc/apk/repositories.d/catwrt.list
	$(INSTALL_BIN) ./files/etc/uci-defaults/zz-catwrt-defaults $(1)/etc/uci-defaults/zz-catwrt-defaults
endef

$(eval $(call BuildPackage,catwrt-base))
