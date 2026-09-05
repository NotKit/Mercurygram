# voip: libtgvoip, tgcalls, webrtc, rnnoise, openh264 and the voipandroid JNI
# bridge, mirrored from TMessagesProj/jni/voip/CMakeLists.txt.
#
# That file is 2000 lines of source lists. Unlike jni/CMakeLists.txt it has no
# NDK dependency beyond branching on ANDROID_ABI, so instead of a copy that
# would drift, it is read at configure time, its jni/-relative paths are
# rewritten to absolute ones, and the result is include()d. Target names,
# flags and definitions are therefore exactly the Android ones; what the port
# changes is listed below, per edit.

if (CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)")
    set(ANDROID_ABI "arm64-v8a")
else()
    set(ANDROID_ABI "x86_64")
endif()

file(READ "${JNI_DIR}/voip/CMakeLists.txt" _voip)

# Its own CMAKE_CXX_FLAGS line would replace the port's; jni/CMakeLists.txt
# saves and restores the variable around the include, which has the same
# effect of ignoring it.
string(REGEX REPLACE "set\\(CMAKE_CXX_FLAGS[^\n]*\n" "" _voip "${_voip}")
string(REGEX REPLACE "cmake_minimum_required[^\n]*\n" "" _voip "${_voip}")

# jni/-relative sources and include dirs -> absolute. A match on a bare
# "voip" line swallows the newline the next line's match needs, so newlines
# are doubled around the rewrite.
string(REPLACE "\n" "\n\n" _voip "${_voip}")
string(REGEX REPLACE "\n([ \t]+)(voip|third_party|opus|boringssl|rlottie|tde2e)(/|\n|\\))" "\n\\1${JNI_DIR}/\\2\\3" _voip "${_voip}")
string(REGEX REPLACE "\n([ \t]+)\\./\n" "\n\\1${JNI_DIR}\n" _voip "${_voip}")
string(REPLACE "\n\n" "\n" _voip "${_voip}")
# The merged ffmpeg/include that patch_ffmpeg.sh makes on Android is the
# port's installed ffmpeg prefix (BRINGUP_NOTES.md).
string(REPLACE "${JNI_DIR}/ffmpeg/include" "${PORT_NATIVE_OUT}/ffmpeg/include" _voip "${_voip}")
string(REGEX REPLACE "\n([ \t]+)ffmpeg/include" "\n\\1${PORT_NATIVE_OUT}/ffmpeg/include" _voip "${_voip}")

# tgcalls_tp defines __ANDROID__ PUBLIC. On Android the toolchain defines it
# everywhere anyway; here it would push glibc code in every dependent target
# down bionic branches. libtgvoip is the one consumer that needs it, to pick
# its JNI audio path — it gets it PRIVATE below.
string(REPLACE " __ANDROID__ " " " _voip "${_voip}")

set(_voip_generated "${CMAKE_BINARY_DIR}/voip-generated.cmake")
file(WRITE "${_voip_generated}" "${_voip}")
include("${_voip_generated}")

foreach(_check tgvoip openh264 rnnoise tgcalls_tp tgcalls voipandroid)
    if (NOT TARGET ${_check})
        message(FATAL_ERROR "voip.cmake: target ${_check} missing after rewriting jni/voip/CMakeLists.txt")
    endif()
endforeach()

# libtgvoip selects its audio backend on __ANDROID__ (audio/AudioInput.cpp):
# the Android one is the JNI AudioRecordJNI/AudioTrackJNI classes the app
# ships, which is what runs here. include/sys/system_properties.h answers the
# property reads that come with it.
target_compile_definitions(tgvoip PRIVATE __ANDROID__)

# The OpenSL ES headers guard their deprecation marker with #ifndef, and its
# default expansion is a clang-only availability attribute that the cross gcc
# rejects. Nothing here is deprecated-API sensitive, so define it away. It has
# to be a compile option: CMake drops a function-style compile definition.
foreach(_t tgvoip tgcalls voipandroid)
    target_compile_options(${_t} PRIVATE "-DSL_API_DEPRECATED(level)=")
endforeach()

# The NDK defines __ANDROID_API__ from the toolchain; WEBRTC_ANDROID code
# reads it (rtc_base/event.cc picks a bionic-only cond wait below 21). 28 is
# the level the port reports as Build.VERSION.SDK_INT.
foreach(_t tgvoip openh264 rnnoise tgcalls_tp tgcalls voipandroid)
    target_include_directories(${_t} PRIVATE ${SHIM_DIR} ${JAVA_INCLUDE_DIRS})
    target_compile_definitions(${_t} PRIVATE __ANDROID_API__=28)
endforeach()

# webrtc spells the codec headers the Android way: <libvpx/vp8cx.h> and
# "ffmpeg/include/libavcodec/avcodec.h", the latter being the merged include
# dir patch_ffmpeg.sh creates on Android. Point both names at the port's
# installed prefixes.
set(_port_inc "${CMAKE_BINARY_DIR}/port-include")
file(MAKE_DIRECTORY "${_port_inc}/ffmpeg")
file(CREATE_LINK "${PORT_NATIVE_OUT}/libvpx/include/vpx" "${_port_inc}/libvpx" SYMBOLIC)
file(CREATE_LINK "${PORT_NATIVE_OUT}/ffmpeg/include" "${_port_inc}/ffmpeg/include" SYMBOLIC)
foreach(_t tgcalls voipandroid)
    target_include_directories(${_t} PRIVATE ${_port_inc} ${PORT_NATIVE_OUT}/libvpx/include)
endforeach()

# webrtc's bundled libevent carries an Android config.h with no fd_mask, and
# select.c then typedefs one that glibc already has.
target_compile_definitions(tgcalls PRIVATE _EVENT_HAVE_FD_MASK=1)

# webrtc's own getifaddrs is for bionic, and its IFF_RUNNING filter rejects
# every interface on a Halium kernel; see native/stubs/ifaddrs_port.cc.
get_target_property(_tgcalls_sources tgcalls SOURCES)
list(REMOVE_ITEM _tgcalls_sources "${JNI_DIR}/voip/webrtc/rtc_base/ifaddrs_android.cc")
list(APPEND _tgcalls_sources "${STUB_DIR}/ifaddrs_port.cc")
set_target_properties(tgcalls PROPERTIES SOURCES "${_tgcalls_sources}")

# Instance.cpp's conference-call encryptor.
add_library(tde2e STATIC ${STUB_DIR}/tde2e_stub.cpp)
target_include_directories(tde2e PUBLIC ${JNI_DIR}/tde2e/include)
