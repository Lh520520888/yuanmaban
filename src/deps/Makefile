# =============================================================================
#  src/deps/Makefile
#  ??? C ????? iOS ???,??????
#
#    ??(macOS + Xcode):
#      cd src/deps && make            # ??
#      cd src/deps && make xpf        # ?? XPF
#      cd src/deps && make clean
#
#  ??????????? dylib:
#    ????(xpf_* / grab_kernelcache / choma_*)??????? dlsym ?
#    ????,????????????,??? @rpath ????????
# =============================================================================

UPSTREAM   := $(CURDIR)/../..
CHOMA      := $(UPSTREAM)/upstream/ChOma
XPF        := $(UPSTREAM)/upstream/XPF
IMG4       := $(XPF)/external/img4lib
GRAB       := $(UPSTREAM)/upstream/libgrabkernel2

SDK        := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC         := xcrun -sdk iphoneos clang
ARCH       := -arch arm64 -arch arm64e
SYSROOT    := -isysroot $(SDK) -miphoneos-version-min=15.0

BUILD      := $(CURDIR)/build/ios

COMMON_CFLAGS := $(ARCH) $(SYSROOT) -O2 -fPIC \
	-Wno-unused-function -Wno-unused-parameter -Wno-multichar \
	-Wno-four-char-constants -Wno-variadic-macros

IMG4_CFLAGS := -DUSE_COMMONCRYPTO -DUSE_LIBCOMPRESSION -DiOS10 \
	-DDER_MULTIBYTE_TAGS=1 -D__unused="__attribute__((unused))" \
	-DDER_TAG_SIZE=8 -I$(IMG4) -I$(IMG4)/libDER -Wno-variadic-macros

CHOMA_SRCS := $(wildcard $(CHOMA)/src/*.c)
IMG4_SRCS  := $(IMG4)/lzss.c \
	$(wildcard $(IMG4)/libvfs/*.c) \
	$(wildcard $(IMG4)/libDER/*.c)
IMG4_SRCS  := $(filter-out $(IMG4)/libvfs/vfs_lzvn.c, $(IMG4_SRCS))
XPF_SRCS   := $(wildcard $(XPF)/src/*.c)

.PHONY: all choma img4 xpf grabkernel2 clean

all: choma img4 xpf grabkernel2
	@echo "==> ????: $(BUILD)"

# ---- ChOma ----
choma: $(BUILD)/libchoma.a

$(BUILD)/libchoma.a: $(CHOMA_SRCS)
	@mkdir -p $(BUILD)/choma
	@for f in $^ ; do \
		o=$(BUILD)/choma/$$(basename $$f .c).o ; \
		$(CC) $(COMMON_CFLAGS) -I$(CHOMA)/include -c $$f -o $$o || exit 1 ; \
	done
	libtool $(BUILD)/choma/*.o -o $@

# ---- img4lib(XPF ?? kernelcache ?)----
img4: $(BUILD)/libimg4.a

$(BUILD)/libimg4.a: $(IMG4_SRCS)
	@mkdir -p $(BUILD)/img4
	@for f in $^ ; do \
		o=$(BUILD)/img4/$$(echo $$f | md5 | cut -c1-8)_$$(basename $$f .c).o ; \
		$(CC) $(COMMON_CFLAGS) $(IMG4_CFLAGS) -c $$f -o $$o || exit 1 ; \
	done
	libtool $(BUILD)/img4/*.o -o $@

# ---- XPF(??? patchfinding)----
xpf: $(BUILD)/libxpf.a

$(BUILD)/libxpf.a: $(XPF_SRCS) | choma
	@mkdir -p $(BUILD)/xpf
	@for f in $(XPF_SRCS) ; do \
		o=$(BUILD)/xpf/$$(basename $$f .c).o ; \
		$(CC) $(COMMON_CFLAGS) $(IMG4_CFLAGS) -I$(XPF)/src -I$(CHOMA)/include \
			-c $$f -o $$o || exit 1 ; \
	done
	libtool $(BUILD)/xpf/*.o -o $@

# ---- libgrabkernel2(??? CDN ? kernelcache)----
# ?? Makefile ??? TARGET=ios ?????,????,???????????
grabkernel2:
	@echo "==> ?? libgrabkernel2 (ios)"
	$(MAKE) -C "$(GRAB)" TARGET=ios DISABLE_TESTS=1
	@mkdir -p $(BUILD)
	cp "$(GRAB)/output/ios/lib/libgrabkernel2.a" $(BUILD)/
	@echo "==> libgrabkernel2 -> $(BUILD)/libgrabkernel2.a"

clean:
	rm -rf $(BUILD)
	$(MAKE) -C "$(GRAB)" clean || true
