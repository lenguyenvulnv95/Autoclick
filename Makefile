all:
	clang++ -arch arm64 -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=13.0 -fobjc-arc -dynamiclib \
	-framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
	-install_name @rpath/AutoClick.dylib \
	-lc++ \
	-o AutoClick.dylib AutoClick.mm
