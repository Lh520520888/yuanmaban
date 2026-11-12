# =============================================================================
#  src/deps/Makefile
#  把上游 C 依赖编译成 iOS 静态库，供主工程链接
#
#    用法（macOS + Xcode）：
#      cd src/deps && make            # 全量
#      cd src/deps && make xpf        # 只编 XPF
#      cd src/deps && make clean
#
#  为什么编成静态库而不是 dylib：
#    这些符号（xpf_* / grab_kernelcache / choma_*）在主可执行里被 dlsym 或
#    直接引用，静态链进去后符号一定存在，不依赖 @rpath 与依赖拷贝顺序。
# =============================================================================

UPSTREAM   := $(CURDIR)/../..
CHOMA      := $(UPSTREAM)/01-越狱内核/ChOma
XPF        := $(UPSTREAM)/01-越狱内核/XPF
IMG4       := $(XPF)/external/img4lib
GRAB       := $(UPSTREAM)/05-工具链/libgrabkernel2

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
	@echo "==> 依赖就绪: $(BUILD)"

# ---- ChOma ----
choma: $(BUILD)/libchoma.a

$(BUILD)/libchoma.a: $(CHOMA_SRCS)
	@mkdir -p $(BUILD)/choma
	@for f in $^ ; do \
		o=$(BUILD)/choma/$$(basename $$f .c).o ; \
		$(CC) $(COMMON_CFLAGS) -I$(CHOMA)/include -c $$f -o $$o || exit 1 ; \
	done
	libtool $(BUILD)/choma/*.o -o $@

# ---- img4lib（XPF 解压 kernelcache 用）----
img4: $(BUILD)/libimg4.a

$(BUILD)/libimg4.a: $(IMG4_SRCS)
	@mkdir -p $(BUILD)/img4
	@for f in $^ ; do \
		o=$(BUILD)/img4/$$(echo $$f | md5 | cut -c1-8)_$$(basename $$f .c).o ; \
		$(CC) $(COMMON_CFLAGS) $(IMG4_CFLAGS) -c $$f -o $$o || exit 1 ; \
	done
	libtool $(BUILD)/img4/*.o -o $@

# ---- XPF（运行时 patchfinding）----
xpf: $(BUILD)/libxpf.a

$(BUILD)/libxpf.a: $(XPF_SRCS) | choma
	@mkdir -p $(BUILD)/xpf
	@for f in $(XPF_SRCS) ; do \
		o=$(BUILD)/xpf/$$(basename $$f .c).o ; \
		$(CC) $(COMMON_CFLAGS) $(IMG4_CFLAGS) -I$(XPF)/src -I$(CHOMA)/include \
			-c $$f -o $$o || exit 1 ; \
	done
	libtool $(BUILD)/xpf/*.o -o $@

# ---- libgrabkernel2（从苹果 CDN 抓 kernelcache）----
# 上游 Makefile 已支持 TARGET=ios 产出静态库，直接复用，避免重复维护编译参数。
grabkernel2:
	@echo "==> 构建 libgrabkernel2 (ios)"
	$(MAKE) -C "$(GRAB)" TARGET=ios DISABLE_TESTS=1
	@mkdir -p $(BUILD)
	cp "$(GRAB)/output/ios/lib/libgrabkernel2.a" $(BUILD)/
	@echo "==> libgrabkernel2 -> $(BUILD)/libgrabkernel2.a"

clean:
	rm -rf $(BUILD)
	$(MAKE) -C "$(GRAB)" clean || true
