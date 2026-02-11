# r3d-tool: CLI bridge for RED R3D SDK

SDK_PATH    = /Users/cheongzhiyan/Downloads/R3DSDKv9_1_2
INCLUDE     = $(SDK_PATH)/Include
STATIC_LIB  = $(SDK_PATH)/Lib/mac64
DYLIB_SRC   = $(SDK_PATH)/Redistributable/mac

INSTALL_BIN = $(HOME)/.local/bin
INSTALL_LIB = $(HOME)/.local/lib/R3DSDK

CXX      = clang++
CXXFLAGS = -std=c++17 -O2 -arch arm64 -I"$(INCLUDE)" \
           -DR3DSDK_DYLIB_PATH='"$(INSTALL_LIB)"'
LDFLAGS  = -L"$(STATIC_LIB)" -lR3DSDK-libcpp \
           -framework CoreFoundation -framework CoreGraphics \
           -framework ImageIO -framework CoreServices \
           -Wl,-rpath,"$(DYLIB_SRC)" \
           -Wl,-rpath,"$(INSTALL_LIB)"

.PHONY: all clean install

all: r3d-tool

r3d-tool: main.cpp
	$(CXX) $(CXXFLAGS) $< $(LDFLAGS) -o $@

clean:
	rm -f r3d-tool

install: r3d-tool
	mkdir -p "$(INSTALL_BIN)" "$(INSTALL_LIB)"
	cp r3d-tool "$(INSTALL_BIN)/r3d-tool"
	cp "$(DYLIB_SRC)"/*.dylib "$(INSTALL_LIB)/"
	@echo "Installed r3d-tool to $(INSTALL_BIN)/r3d-tool"
	@echo "Installed R3D SDK libraries to $(INSTALL_LIB)/"
