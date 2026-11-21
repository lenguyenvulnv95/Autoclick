clang++ -arch arm64 -isysroot $(SDK) -miphoneos-version-min=13.0 -fobjc-arc -dynamiclib \
	-framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
	-framework Metal -framework MetalKit -framework Accelerate \
	-install_name @rpath/AutoClick.dylib \
	-o AutoClick.dylib AutoClick.mm
