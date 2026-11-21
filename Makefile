all:
git clone --depth 1 https://github.com/ocornut/imgui.git imgui_src || true
cp imgui_src/.h .
cp imgui_src/backends/imgui_impl_metal. .
clang++ -arch arm64 -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=12.0 -fobjc-arc -dynamiclib 
-framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore 
-install_name @rpath/AutoClick.dylib 
-lc++ 
-o AutoClick.dylib AutoClick.mm imgui_src/imgui.cpp imgui_src/imgui_draw.cpp imgui_src/imgui_tables.cpp imgui_src/imgui_widgets.cpp imgui_impl_metal.mm
