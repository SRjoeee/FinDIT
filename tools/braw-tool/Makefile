# braw-tool — Blackmagic RAW CLI 工具
#
# 依赖: BRAW SDK (从 Blackmagic 官网下载安装)
# 用途: FindIt 通过 Process 子进程调用此工具解码 .braw 文件

SDK_PATH = /Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac
INCLUDE  = $(SDK_PATH)/Include
FW_PATH  = $(SDK_PATH)/Libraries

CXX      = clang++
CXXFLAGS = -std=c++17 -O2 -arch arm64 -Wall -Wextra -Wno-unused-parameter
DISPATCH = $(INCLUDE)/BlackmagicRawAPIDispatch.cpp

FRAMEWORKS = -framework CoreFoundation -framework CoreGraphics \
             -framework ImageIO -framework CoreServices

.PHONY: all clean install

all: braw-tool

braw-tool: main.cpp
	$(CXX) $(CXXFLAGS) \
		-I"$(INCLUDE)" \
		main.cpp "$(DISPATCH)" \
		-F"$(FW_PATH)" \
		$(FRAMEWORKS) \
		-rpath "$(FW_PATH)" \
		-o braw-tool

install: braw-tool
	@mkdir -p ~/.local/bin
	cp braw-tool ~/.local/bin/braw-tool
	@echo "Installed to ~/.local/bin/braw-tool"

clean:
	rm -f braw-tool
