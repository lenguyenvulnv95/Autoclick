SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
all:
	clang -arch arm64 -isysroot $(SDK) -miphoneos-version-min=12.0 -fobjc-arc -dynamiclib \
	  -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
	  -install_name @rpath/AutoClick.dylib \
	  -o AutoClick.dylib AutoClick.m
	@file AutoClick.dylib
	@otool -L AutoClick.dylib
