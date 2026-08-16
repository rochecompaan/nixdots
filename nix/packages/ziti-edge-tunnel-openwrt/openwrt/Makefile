include $(TOPDIR)/rules.mk

PKG_NAME:=ziti-edge-tunnel
PKG_VERSION:=1.15.1
PKG_RELEASE:=4
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Roché Compaan
PKG_INSTALL:=1
PKG_BUILD_PARALLEL:=1

ZITI_TUNNEL_SRC:=@zitiTunnelSrc@
ZITI_SDK_SRC:=@zitiSdkSrc@
LWIP_SRC:=@lwipSrc@
LWIP_CONTRIB_SRC:=@lwipContribSrc@
LLHTTP_SRC:=@llhttpSrc@
SUBCOMMAND_SRC:=@subcommandSrc@
TLSUV_SRC:=@tlsuvSrc@

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/ziti-edge-tunnel
  SECTION:=net
  CATEGORY:=Network
  TITLE:=OpenZiti edge tunneler
  URL:=https://openziti.io/
  DEPENDS:=+ca-bundle +kmod-tun +libatomic +libjson-c +libopenssl +libpcap +libprotobuf-c +libsodium +libstdcpp +libuv +zlib
endef

define Package/ziti-edge-tunnel/description
  OpenZiti edge tunneler packaged for router-originated traffic on OpenWRT.
endef

define Package/ziti-edge-tunnel/conffiles
/etc/config/ziti-edge-tunnel
endef

define Build/Prepare
	$(RM) -r $(PKG_BUILD_DIR)
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) $(ZITI_TUNNEL_SRC)/. $(PKG_BUILD_DIR)/
	chmod -R u+w $(PKG_BUILD_DIR)
	$(RM) -r $(PKG_BUILD_DIR)/deps/lwip
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/deps/lwip
	$(CP) $(LWIP_SRC)/. $(PKG_BUILD_DIR)/deps/lwip/
	$(RM) -r $(PKG_BUILD_DIR)/deps/llhttp
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/deps/llhttp
	$(CP) $(LLHTTP_SRC)/. $(PKG_BUILD_DIR)/deps/llhttp/
	chmod -R u+w $(PKG_BUILD_DIR)
endef

CMAKE_OPTIONS += \
	-DBUILD_DIST_PACKAGES=OFF \
	-DBUILD_EXAMPLES=OFF \
	-DBUILD_SHARED_LIBS=OFF \
	-DBUILD_STATIC_LIBS=ON \
	-DCMAKE_BUILD_TYPE=Release \
	-DDISABLE_LIBSYSTEMD_FEATURE=ON \
	-DDISABLE_SEMVER_VERIFICATION=ON \
	-DENABLE_VCPKG=OFF \
	-DFETCHCONTENT_FULLY_DISCONNECTED=ON \
	-DFETCHCONTENT_SOURCE_DIR_LWIP=$(PKG_BUILD_DIR)/deps/lwip \
	-DFETCHCONTENT_SOURCE_DIR_LWIP-CONTRIB=$(LWIP_CONTRIB_SRC) \
	-DFETCHCONTENT_SOURCE_DIR_SUBCOMMAND=$(SUBCOMMAND_SRC) \
	-DGIT_VERSION=v$(PKG_VERSION) \
	-DLLHTTP_BUILD_SHARED_LIBS=OFF \
	-DLLHTTP_BUILD_STATIC_LIBS=ON \
	-DLLHTTP_SOURCE_DIR=$(PKG_BUILD_DIR)/deps/llhttp \
	-DTLSUV_TLSLIB=openssl \
	-DZITI_SDK_DIR=$(ZITI_SDK_SRC) \
	-DZITI_SDK_VERSION=1.15.0 \
	-DZITI_TUNNEL_BUILD_TESTS=OFF \
	-Dtlsuv_DIR=$(TLSUV_SRC)

define Package/ziti-edge-tunnel/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/ziti-edge-tunnel $(1)/usr/bin/ziti-edge-tunnel
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/ziti-edge-tunnel $(1)/etc/config/ziti-edge-tunnel
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/ziti-edge-tunnel $(1)/etc/init.d/ziti-edge-tunnel
	$(INSTALL_DIR) $(1)/usr/lib/ziti-edge-tunnel
	$(INSTALL_BIN) ./files/usr/lib/ziti-edge-tunnel/run-managed $(1)/usr/lib/ziti-edge-tunnel/run-managed
	$(INSTALL_DIR) $(1)/etc/openziti/identities
	chmod 0700 $(1)/etc/openziti/identities
endef

$(eval $(call BuildPackage,ziti-edge-tunnel))
