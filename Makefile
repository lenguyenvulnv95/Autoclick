all:
	clang++ -arch arm64 -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=13.0 -std=c++17 -fobjc-arc -dynamiclib \
	-I. -Iimgui -Iimgui/backends \
	-framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore -framework Metal -framework MetalKit -framework Accelerate -framework IOKit -framework Vision \
	-install_name @rpath/AutoClick.dylib \
	-lc++ \
	-o AutoClick.dylib AutoClick.mm LevelRecognizer.mm \
	imgui/imgui.cpp imgui/imgui_draw.cpp imgui/imgui_tables.cpp imgui/imgui_widgets.cpp \
	imgui/backends/imgui_impl_metal.mm
