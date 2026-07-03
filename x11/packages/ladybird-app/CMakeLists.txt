# CMakeLists.txt — the iOS/UIKit frontend target for Ladybird (UI/iOS/).
#
# Dropped into the Ladybird source tree as UI/iOS/ and pulled in via
#   if (IOS) add_subdirectory(UI/iOS)   (m0-patch #18, app-build mode)
# from the top-level CMakeLists. When built inside the Ladybird build it sees the Lagom
# targets directly; on iOS those are STATIC (top CMakeLists forces BUILD_SHARED_LIBS OFF
# for `if (ANDROID OR IOS)`), so the engine links into this binary.
#
# The live paint path is the normal compositor cycle: the CPU Compositor helper (built for
# iOS by patch #18, launched --force-cpu-painting) rasters the page into a ShareableBitmap
# backing store and ships it to the UI, which fills m_client_state.front_bitmap and fires
# on_ready_to_paint -> LadybirdWebView presents via the CPU CGImage path. No IOSurface/GPU.

cmake_minimum_required(VERSION 3.25)

set(LADYBIRD_IOS_SOURCES
    Sources/IOSWebViewBridge.cpp          # pure C++ ViewImplementation subclass
    Sources/LadybirdWebView.mm            # UIView host: CPU CGImage present + input
    Sources/Event.mm                      # UIKit event -> LibWeb input converters
    Sources/BrowserViewController.mm      # M0 chrome: address bar, back/fwd/reload, 1 tab
    Sources/IOSApplication.mm             # WebView::Application subclass + AppDelegate + main()
    Sources/IOSEventLoop.mm               # CFRunLoop-backed Core::EventLoopImplementation
)

add_executable(Ladybird ${LADYBIRD_IOS_SOURCES})

set_source_files_properties(
    Sources/LadybirdWebView.mm Sources/Event.mm Sources/BrowserViewController.mm Sources/IOSApplication.mm Sources/IOSEventLoop.mm
    PROPERTIES COMPILE_FLAGS "-fobjc-arc")

target_compile_features(Ladybird PRIVATE cxx_std_23)
target_include_directories(Ladybird PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/Sources
    ${LADYBIRD_SOURCE_DIR}
    ${LADYBIRD_SOURCE_DIR}/Libraries
    ${LADYBIRD_SOURCE_DIR}/Services
    ${CMAKE_CURRENT_BINARY_DIR})

# Frameworks available in the iPhoneOS SDK; cctools ld64 links them.
target_link_libraries(Ladybird PRIVATE
    "-framework UIKit"
    "-framework Foundation"
    "-framework CoreGraphics"
    "-framework QuartzCore"
    "-framework CoreText"
    "-framework ImageIO"
    "-framework Metal"
    "-framework IOSurface"
)

# Engine libs (static on iOS). Mirror UI/CMakeLists.txt's LADYBIRD_LIBS set exactly.
target_link_libraries(Ladybird PRIVATE
    AK LibCore LibFileSystem LibGfx LibImageDecoderClient LibIPC LibJS
    LibMain LibWeb LibWebView LibRequests LibSync LibURL)
target_link_libraries(Ladybird PRIVATE OpenSSL::Crypto OpenSSL::SSL)

# The five spawned helpers (WebContent, RequestServer, ImageDecoder, WebWorker, Compositor)
# are the engine's own Services/* targets — built alongside, copied into the bundle by the
# driver. This CMake only builds the UI executable.
add_dependencies(Ladybird ${ladybird_helper_processes})
