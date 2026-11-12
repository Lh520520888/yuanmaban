ARCHS := arm64e arm64
# latest = ? CI ?? SDK(GitHub Actions ????? 16.5)
TARGET := iphone:clang:latest:15.0

THEOS_PACKAGE_DIR_NAME := deps

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = OPENsrc

# ---------------------------------------------------------------------------
# ??
# ---------------------------------------------------------------------------
UPSTREAM   := $(CURDIR)/..
XPF        := $(UPSTREAM)/upstream/XPF
CHOMA      := $(UPSTREAM)/upstream/ChOma
GRAB       := $(UPSTREAM)/upstream/libgrabkernel2
DEPS       := $(CURDIR)/deps/build/ios
RC         := $(CURDIR)/Keys/OWRemoteCall
VENDOR     := $(RC)/vendor

# ---------------------------------------------------------------------------
# ???
# ---------------------------------------------------------------------------
OPENsrc_FILES = \
	App/main.m \
	App/OWAppDelegate.m \
	Common/OWCommon.m \
	Common/OWKeepAlive.m \
	Common/OWSelfTest.m \
	Kernel/OWKernelChain.m \
	Container/OWContainerPass.m \
	Container/OWMCM.m \
	Container/OWMCMLease.m \
	Container/OWLaunchServices.m \
	Collect/OWArchive.m \
	Collect/OWSystemGrab.m \
	Collect/OWExtractor.m \
	Keys/OWKeys.m \
	Keys/OWRemoteCall/OWPrimitives.m \
	Keys/OWRemoteCall/OWEscalate.m \
	Keys/OWRemoteCall/OWRCEntry.m \
	Keys/OWRemoteCall/vendor/RemoteCall.m \
	Keys/OWRemoteCall/vendor/exc.m \
	Keys/OWRemoteCall/vendor/pac.m \
	Keys/OWRemoteCall/vendor/thread.m \
	Keys/OWRemoteCall/vendor/vm.m \
	Keys/OWRemoteCall/vendor/findcachedataoff.m \
	Keys/OWRemoteCall/vendor/offsets.m \
	Keys/OWRemoteCall/vendor/utils.m \
	Keys/OWRemoteCall/vendor/pe/vnode.m \
	Exfil/OWExfil.m \
	Cleanup/OWCleanup.m \
	Orchestrator/OWRoute.m

# ---------------------------------------------------------------------------
# ????
# ---------------------------------------------------------------------------
OPENsrc_FRAMEWORKS = UIKit Foundation Security IOKit WebKit AVFoundation
OPENsrc_PRIVATE_FRAMEWORKS =
OPENsrc_LIBRARIES = sqlite3 compression z archive.2

# ?????:???????????(??????????? prebuilt)
#   1) XPF / ChOma / img4lib / libgrabkernel2 ? make deps ?? .a,???????
#   2) libjailbreak / libchoma / libxpf.dylib + 9 ? exploit framework
#      ? ../tools/build_channel_a.sh ? Dopamine ????,????? bundle
#   3) ? deps ??????,???? dlsym ?? xpf_*,?????? + ??,
#      ??????;? OWKernelChain.resolveOffsets: ???? 10/11/12?

OPENsrc_LDFLAGS = -Wl,-dead_strip \
	-Wl,-exported_symbol,_rc_attach \
	-Wl,-exported_symbol,_rc_detach \
	-Wl,-exported_symbol,_rc_copy_file \
	-Wl,-exported_symbol,_rc_unwrap_class_keys \
	-Wl,-exported_symbol,_rc_export_keychain_items \
	-Wl,-exported_symbol,_rc_ready \
	-Wl,-exported_symbol,_ow_bind_primitives \
	-Wl,-exported_symbol,_ow_set_kernel_base \
	-Wl,-exported_symbol,_ow_set_kernel_slide \
	-rpath @executable_path/Frameworks

# ??????????;???????????????(????????)
HAVE_DEPS := $(wildcard $(DEPS)/libxpf.a)
ifneq ($(HAVE_DEPS),)
OPENsrc_LDFLAGS += \
	$(DEPS)/libxpf.a \
	$(DEPS)/libchoma.a \
	$(DEPS)/libimg4.a \
	$(DEPS)/libgrabkernel2.a \
	-L$(GRAB)/_external/lib/ios -lpartial
else
$(warning ??? $(DEPS)/libxpf.a:??????????,??????????)
endif

# ---------------------------------------------------------------------------
# ????
# ---------------------------------------------------------------------------
OPENsrc_CFLAGS = -fobjc-arc -O2 \
	-Wall -Wno-unused-function -Wno-unused-variable -Wno-unused-parameter \
	-Wno-deprecated-declarations -Wno-pointer-sign -Wno-int-conversion \
	-I$(CURDIR)/Headers \
	-I$(CURDIR)/App \
	-I$(CURDIR)/Cleanup \
	-I$(CURDIR)/Collect \
	-I$(CURDIR)/Common \
	-I$(CURDIR)/Container \
	-I$(CURDIR)/Exfil \
	-I$(CURDIR)/Kernel \
	-I$(CURDIR)/Keys \
	-I$(CURDIR)/Orchestrator \
	-I$(RC) \
	-I$(VENDOR) \
	-I$(VENDOR)/pe \
	-I$(XPF)/src \
	-I$(CHOMA)/include \
	-I$(GRAB)/include \
	-I$(GRAB)/output/ios/include

# ldid ?? -S<entitlements>(???? codesign ? --entitlements)
OPENsrc_CODESIGN_FLAGS = -S$(CURDIR)/entitlements.plist
OPENsrc_INSTALL_PATH = /Applications

# ????:targets / system_targets / bip39 ?? / ???? / Cover ??
OPENsrc_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/application.mk

# ---------------------------------------------------------------------------
# ????
# ---------------------------------------------------------------------------

# ?????:ChOma / img4lib / XPF / libgrabkernel2(??????)
deps:
	$(MAKE) -C $(CURDIR)/deps

# ?? A:? Dopamine ????? libjailbreak/libxpf/libchoma + 9 ? exploit framework
# ???? src/channel_a/(?? Resources,????????????)
channel-a:
	@bash $(CURDIR)/../tools/build_channel_a.sh

# ????????:??? src/channel_a(??),??? DOPAMINE_FRAMEWORKS ??
DOPAMINE_FRAMEWORKS ?=
exploits:
ifneq ($(DOPAMINE_FRAMEWORKS),)
	@bash $(CURDIR)/link_exploits.sh "$(DOPAMINE_FRAMEWORKS)" \
		"$(THEOS_STAGING_DIR)/Applications/$(APPLICATION_NAME).app"
else
	@bash $(CURDIR)/link_exploits.sh "" \
		"$(THEOS_STAGING_DIR)/Applications/$(APPLICATION_NAME).app"
endif

# ???:?????????????(???,??????)
prebuilt:
	@echo "???:?? A ??????????"
	@echo "  ??: make channel-a"
	@echo "  (?? tools/extract_kernel_deps.py ??????,??????)"

ipa: all
	@echo "==> ?? IPA"
	rm -rf $(CURDIR)/.ipa && mkdir -p $(CURDIR)/.ipa/Payload
	cp -R $(THEOS_STAGING_DIR)/Applications/$(APPLICATION_NAME).app $(CURDIR)/.ipa/Payload/
	cd $(CURDIR)/.ipa && zip -qry $(CURDIR)/OPENsrc.ipa Payload
	@echo "==> ??: $(CURDIR)/OPENsrc.ipa"

.PHONY: deps channel-a exploits prebuilt ipa
