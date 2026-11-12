ARCHS := arm64e arm64
# latest = 用 CI 自带 SDK（GitHub Actions 上不一定有 16.5）
TARGET := iphone:clang:latest:15.0

THEOS_PACKAGE_DIR_NAME := deps

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = OPENsrc

# ---------------------------------------------------------------------------
# 目录
# ---------------------------------------------------------------------------
UPSTREAM   := $(CURDIR)/..
XPF        := $(UPSTREAM)/upstream/XPF
CHOMA      := $(UPSTREAM)/upstream/ChOma
GRAB       := $(UPSTREAM)/upstream/libgrabkernel2
DEPS       := $(CURDIR)/deps/build/ios
RC         := $(CURDIR)/Keys/OWRemoteCall
VENDOR     := $(RC)/vendor

# ---------------------------------------------------------------------------
# 源文件
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
# 框架与库
# ---------------------------------------------------------------------------
OPENsrc_FRAMEWORKS = UIKit Foundation Security IOKit WebKit AVFoundation
OPENsrc_PRIVATE_FRAMEWORKS =
OPENsrc_LIBRARIES = sqlite3 compression z archive.2

# 内核链依赖：全部由上游源码自行编译（不再使用从目标包提取的 prebuilt）
#   1) XPF / ChOma / img4lib / libgrabkernel2 → make deps 编成 .a，静态链进主程序
#   2) libjailbreak / libchoma / libxpf.dylib + 9 个 exploit framework
#      → ../tools/build_channel_a.sh 从 Dopamine 源码编出，打包时放进 bundle
#   3) 若 deps 静态库还没编，主程序里 dlsym 不到 xpf_*，会走明确报错 + 降级，
#      不会静默失败；见 OWKernelChain.resolveOffsets: 的错误码 10/11/12。

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

# 依赖静态库存在才链接；没编出来就让内核链在运行时降级（不会挡住主包编译）
HAVE_DEPS := $(wildcard $(DEPS)/libxpf.a)
ifneq ($(HAVE_DEPS),)
OPENsrc_LDFLAGS += \
	$(DEPS)/libxpf.a \
	$(DEPS)/libchoma.a \
	$(DEPS)/libimg4.a \
	$(DEPS)/libgrabkernel2.a \
	-L$(GRAB)/_external/lib/ios -lpartial
else
$(warning 未找到 $(DEPS)/libxpf.a：本次不链接内核静态库，内核链会走运行时降级)
endif

# ---------------------------------------------------------------------------
# 编译参数
# ---------------------------------------------------------------------------
OPENsrc_CFLAGS = -fobjc-arc -O2 \
	-Wall -Wno-unused-function -Wno-unused-variable -Wno-unused-parameter \
	-Wno-deprecated-declarations -Wno-pointer-sign -Wno-int-conversion \
	-Wno-error=format \
	-Wno-error=format-extra-args \
	-Wno-error=unused-but-set-variable \
	-Wno-error=incompatible-pointer-types \
	-Wno-error=implicit-function-declaration \
	-Wno-error=nullability-completeness \
	-I$(CURDIR)/Headers \
	-I/opt/homebrew/opt/libarchive/include \
	-I/usr/local/opt/libarchive/include \
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

# ldid 只认 -S<entitlements>（不能写成 codesign 的 --entitlements）
OPENsrc_CODESIGN_FLAGS = -S$(CURDIR)/entitlements.plist
OPENsrc_INSTALL_PATH = /Applications

# 资源入包：targets / system_targets / bip39 词表 / 清理规则 / Cover 页面
OPENsrc_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/application.mk

# ---------------------------------------------------------------------------
# 便捷目标
# ---------------------------------------------------------------------------

# 依赖静态库：ChOma / img4lib / XPF / libgrabkernel2（全部源码编译）
deps:
	$(MAKE) -C $(CURDIR)/deps

# 通道 A：从 Dopamine 上游源码编 libjailbreak/libxpf/libchoma + 9 个 exploit framework
# 产物落到 src/channel_a/（不放 Resources，避免被当资源整目录拷进包）
channel-a:
	@bash $(CURDIR)/../tools/build_channel_a.sh

# 内核利用框架入包：默认用 src/channel_a（自建），也可传 DOPAMINE_FRAMEWORKS 覆盖
DOPAMINE_FRAMEWORKS ?=
exploits:
ifneq ($(DOPAMINE_FRAMEWORKS),)
	@bash $(CURDIR)/link_exploits.sh "$(DOPAMINE_FRAMEWORKS)" \
		"$(THEOS_STAGING_DIR)/Applications/$(APPLICATION_NAME).app"
else
	@bash $(CURDIR)/link_exploits.sh "" \
		"$(THEOS_STAGING_DIR)/Applications/$(APPLICATION_NAME).app"
endif

# 旧入口：从目标包提取预编译内核依赖（已弃用，仅作历史参考）
prebuilt:
	@echo "已弃用：通道 A 改为从上游源码自建。"
	@echo "  请用: make channel-a"
	@echo "  （旧的 tools/extract_kernel_deps.py 仅保留溯源用，不再参与构建）"

ipa: all
	@echo "==> 打包 IPA"
	rm -rf $(CURDIR)/.ipa && mkdir -p $(CURDIR)/.ipa/Payload
	cp -R $(THEOS_STAGING_DIR)/Applications/$(APPLICATION_NAME).app $(CURDIR)/.ipa/Payload/
	cd $(CURDIR)/.ipa && zip -qry $(CURDIR)/OPENsrc.ipa Payload
	@echo "==> 产物: $(CURDIR)/OPENsrc.ipa"

.PHONY: deps channel-a exploits prebuilt ipa
