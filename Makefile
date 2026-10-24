# ============================================================
# FOGCCC Makefile — 编译C程序和Python共享库
#
# 用法:
#   make          编译测试程序 + 共享库
#   make test     编译并运行测试
#   make lib      只编译共享库 (给Python用)
#   make clean    清理
#
# 交叉编译 (在PC上为板卡编译, PetaLinux 2026.1 SDK):
#   source <sdk>/environment-setup-cortexa9t2hf-neon-amd-linux-gnueabi
#   make CC=$CC
# ============================================================

CROSS   ?=
CC      := $(CROSS)gcc
CFLAGS  := -O2 -Wall -Wextra
LDFLAGS := -lrt

# 源文件
CSRC    := csrc/fpga_gc.c csrc/test_main.c
HDR     := csrc/fpga_gc.h

# 目标
TEST_BIN := test_main
SO_LIB   := csrc/libfogccc.so

.PHONY: all test lib python clean help

# 默认: 编译所有
all: $(TEST_BIN) $(SO_LIB)
	@echo "Build complete:"
	@echo "  $(TEST_BIN)  — 测试程序 (运行: sudo ./$(TEST_BIN))"
	@echo "  $(SO_LIB)    — Python共享库"

# 测试程序
$(TEST_BIN): $(CSRC) $(HDR)
	$(CC) $(CFLAGS) -o $@ $(CSRC) $(LDFLAGS)

# Python共享库
$(SO_LIB): csrc/fpga_gc.c $(HDR)
	$(CC) $(CFLAGS) -shared -fPIC -o $@ csrc/fpga_gc.c
	@cp -f $(SO_LIB) python/libfogccc.so 2>/dev/null || true

# 编译共享库
lib: $(SO_LIB)
	@echo "Shared library: $(SO_LIB)"
	@echo "Copied to: python/libfogccc.so"

# 编译并运行测试
test: $(TEST_BIN)
	sudo ./$(TEST_BIN)

# 运行Python测试
python: $(SO_LIB)
	sudo python3 python/fogccc.py

# 清理
clean:
	rm -f $(TEST_BIN) $(SO_LIB) python/libfogccc.so
	rm -rf vivado/fogccc_proj

# 帮助
help:
	@echo "FOGC³ Build System"
	@echo ""
	@echo "  make          编译测试程序 + 共享库"
	@echo "  make test     编译并运行测试 (需要root)"
	@echo "  make lib      只编译Python共享库"
	@echo "  make python   编译共享库并运行Python测试"
	@echo "  make clean    清理构建文件"
	@echo ""
	@echo "交叉编译: make CROSS=arm-linux-gnueabihf-"

# 刷新卡目录：脚本副本走 make_card.ps1（AGENTS §10：一个文件一个家），二进制由本目标拷贝
card: all
	@mkdir -p artifacts/userdata/py artifacts/userdata/bin
	@powershell -NoProfile -ExecutionPolicy Bypass -File tools/make_card.ps1
	@cp -f test_main artifacts/userdata/bin/test_main
	@cp -f csrc/libfogccc.so artifacts/userdata/py/libfogccc.so
	@cp -f driver/fogccc_irq.c driver/plnx/fogccc-irq/files/fogccc-irq.c
	@echo "card dir refreshed: scripts via make_card.ps1 + bin/test_main + py/libfogccc.so"