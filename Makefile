# ============================================================
# FOGCCC Makefile — 编译C程序和Python共享库
#
# 用法:
#   make          编译测试程序 + 共享库
#   make test     编译并运行测试
#   make lib      只编译共享库 (给Python用)
#   make clean    清理
#
# 交叉编译 (在PC上为板卡编译):
#   make CROSS=arm-linux-gnueabihf-
# ============================================================

CROSS   ?=
CC      := $(CROSS)gcc
CFLAGS  := -O2 -Wall -Wextra
LDFLAGS := -lrt

# 源文件
CSRC    := csrc/fpga_gc.c csrc/test_main.c
HDR     := csrc/fpga_gc.h

# 目标
TEST_BIN := test_fpga
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

# 运行Python基准
bench:
	python3 python/benchmark.py

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
	@echo "  make bench    运行Python GC基准"
	@echo "  make clean    清理构建文件"
	@echo ""
	@echo "交叉编译: make CROSS=arm-linux-gnueabihf-"
