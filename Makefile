all:
	clang++ -arch arm64 -isysroot /Applications/Xcode_26.6.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk -miphonesos-version-min=12.0 -fobjc-arc -dynamiclib \
	-framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
	-install_name @rpath/AutoClick.dylib \
	-lc++ \
	-o AutoClick.dylib AutoClick.m
