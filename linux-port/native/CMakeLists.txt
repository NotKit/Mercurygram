# libtmessages for x86_64-linux-gnu (desktop OpenJDK port).
#
# This is an overlay, not a wrapper: TMessagesProj/jni/CMakeLists.txt is built
# around ANDROID_ABI, the NDK toolchain file, AndroidNdkModules and an
# include() of voip/CMakeLists.txt, none of which exist here. It mirrors that
# file's targets, flags and source lists, minus what the port excludes:
#
#   * breakpad (header shims in include/breakpad/ keep utilities.cpp compiling)
#   * whisper (jni/whisper submodule not checked out)
#   * tde2e / tdutils (jni/td submodule not checked out; stubs/tde2e_stub.cpp
#     answers Instance.cpp's two calls with an error)
#   * cpufeatures (NDK module, only used by the excluded arm code)
#
# voip/ (libtgvoip, tgcalls, webrtc, rnnoise, openh264, voipandroid) comes in
# through voip.cmake, which rewrites jni/voip/CMakeLists.txt rather than
# copying it.
#
# Prebuilt static deps come from $PORT_NATIVE_OUT (see native/build_*_linux.sh),
# not from jni/<dep>/build/${ANDROID_ABI}/.
#
# Keep the source lists and compile flags below in sync with
# TMessagesProj/jni/CMakeLists.txt when that file changes.

cmake_minimum_required(VERSION 3.16)
project(tmessages_linux C CXX ASM)

if (NOT DEFINED PORT_NATIVE_OUT)
    message(FATAL_ERROR "PORT_NATIVE_OUT must be set (see build_tmessages_linux.sh)")
endif()

get_filename_component(JNI_DIR "${CMAKE_CURRENT_LIST_DIR}/../../TMessagesProj/jni" ABSOLUTE)
set(SHIM_DIR "${CMAKE_CURRENT_LIST_DIR}/include")
set(STUB_DIR "${CMAKE_CURRENT_LIST_DIR}/stubs")

# Every static archive below is linked into a shared object.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# The NDK sysroot supplies jni.h and android/*.h to every target for free; here
# the JDK headers and the shim headers have to be put on the path globally.
include_directories(SYSTEM ${JAVA_INCLUDE_DIRS})
include_directories(${SHIM_DIR})

# Same flags as jni/CMakeLists.txt. -DANDROID stays: in this tree it is not a
# platform switch but the "build the JNI bridge" switch — tgnet guards its
# JavaVM integration (ConnectionsManager::useJavaVM, NativeByteBuffer's
# jobject) behind #ifdef ANDROID. The real platform macro, __ANDROID__, is
# compiler-defined and correctly absent here.
set(CMAKE_CXX_FLAGS "-std=gnu++17 -DANDROID -Wno-register")
# See include/port_compat.hpp: NDK-toolchain assumptions in the jni/ C++ code
# that would otherwise need upstream edits.
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -include port_compat.hpp")
set(CMAKE_C_FLAGS "-w -std=gnu11 -DANDROID -D_LARGEFILE_SOURCE=1")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -ffunction-sections -fdata-sections")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -ffunction-sections -fdata-sections")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wno-builtin-macro-redefined -D__FILE__=__FILE_NAME__")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-builtin-macro-redefined -D__FILE__=__FILE_NAME__")

# --no-undefined turns a missing Android symbol into a link error instead of a
# runtime UnsatisfiedLinkError halfway through bring-up.
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,--build-id=none -Wl,--hash-style=gnu -Wl,-Bsymbolic -Wl,--gc-sections -Wl,--no-undefined -Wl,--exclude-libs=libtgvoip.a:libtgcalls.a:libtgcalls_tp.a:libopenh264.a:librnnoise.a:libtde2e.a:libtgnet.a:libflac.a:librlottie.a:libsqlite.a:libswscale.a:libavformat.a:libavcodec.a:libavresample.a:libavutil.a:libswresample.a:libvpx.a:libdav1d.a:libssl.a:libcrypto.a")

#
# Prebuilt dependencies (linux-port/native/build_*_linux.sh)
#
foreach(_lib avutil avformat avcodec avresample swresample swscale)
    add_library(${_lib} STATIC IMPORTED)
    set_target_properties(${_lib} PROPERTIES
            IMPORTED_LOCATION ${PORT_NATIVE_OUT}/ffmpeg/lib/lib${_lib}.a)
endforeach()

add_library(crypto STATIC IMPORTED)
set_target_properties(crypto PROPERTIES IMPORTED_LOCATION ${PORT_NATIVE_OUT}/boringssl/libcrypto.a)

add_library(ssl STATIC IMPORTED)
set_target_properties(ssl PROPERTIES IMPORTED_LOCATION ${PORT_NATIVE_OUT}/boringssl/libssl.a)

add_library(libvpx STATIC IMPORTED)
set_target_properties(libvpx PROPERTIES IMPORTED_LOCATION ${PORT_NATIVE_OUT}/libvpx/lib/libvpx.a)

add_library(libdav1d STATIC IMPORTED)
set_target_properties(libdav1d PROPERTIES IMPORTED_LOCATION ${PORT_NATIVE_OUT}/dav1d/lib/libdav1d.a)

#
# atlas libandroid.so.0 — jnigraphics (AndroidBitmap_*) and the NDK asset API.
# Prefer the artifacts build-atlas.sh copies out; fall back to the atlas builddir.
#
find_library(ATLAS_LIBANDROID
        NAMES android
        PATHS ${PORT_OUT}/atlas ${ATLAS_BUILDDIR}
        NO_DEFAULT_PATH REQUIRED)
message(STATUS "atlas libandroid: ${ATLAS_LIBANDROID}")

#
# Desktop stand-ins for Android system libraries.
#
add_library(androidlog STATIC ${STUB_DIR}/android_log.c)
target_include_directories(androidlog PUBLIC ${SHIM_DIR})

# No-op OpenSL ES, ported from mercurygram-click-packaging/stubs. webrtc and
# libtgvoip link their OpenSL backends but never select them: atlas reports
# no low-latency audio feature, so both take the Java AudioRecord/AudioTrack
# path. slCreateEngine answering "unsupported" keeps that honest.
add_library(OpenSLES SHARED ${STUB_DIR}/opensles_stub.c)
set_target_properties(OpenSLES PROPERTIES SOVERSION 1)

include(${CMAKE_CURRENT_LIST_DIR}/voip.cmake)

#
# tgnet
#
add_library(tgnet STATIC
        ${JNI_DIR}/tgnet/ApiScheme.cpp
        ${JNI_DIR}/tgnet/BuffersStorage.cpp
        ${JNI_DIR}/tgnet/ByteArray.cpp
        ${JNI_DIR}/tgnet/ByteStream.cpp
        ${JNI_DIR}/tgnet/Connection.cpp
        ${JNI_DIR}/tgnet/ConnectionSession.cpp
        ${JNI_DIR}/tgnet/ConnectionsManager.cpp
        ${JNI_DIR}/tgnet/ConnectionSocket.cpp
        ${JNI_DIR}/tgnet/Datacenter.cpp
        ${JNI_DIR}/tgnet/EventObject.cpp
        ${JNI_DIR}/tgnet/FileLog.cpp
        ${JNI_DIR}/tgnet/MTProtoScheme.cpp
        ${JNI_DIR}/tgnet/NativeByteBuffer.cpp
        ${JNI_DIR}/tgnet/Request.cpp
        ${JNI_DIR}/tgnet/Timer.cpp
        ${JNI_DIR}/tgnet/TLObject.cpp
        ${JNI_DIR}/tgnet/ProxyCheckInfo.cpp
        ${JNI_DIR}/tgnet/Handshake.cpp
        ${JNI_DIR}/tgnet/Config.cpp)
target_compile_options(tgnet PUBLIC
        -Wall -frtti -finline-functions -ffast-math -Oz)
target_compile_definitions(tgnet PUBLIC HAVE_PTHREAD)
target_include_directories(tgnet PUBLIC
        ${PORT_NATIVE_OUT}/boringssl/include)
target_link_libraries(tgnet crypto androidlog)

#
# rlottie
#
add_library(rlottie STATIC
        ${JNI_DIR}/rlottie/src/lottie/lottieanimation.cpp
        ${JNI_DIR}/rlottie/src/lottie/lottieitem.cpp
        ${JNI_DIR}/rlottie/src/lottie/lottiekeypath.cpp
        ${JNI_DIR}/rlottie/src/lottie/lottieloader.cpp
        ${JNI_DIR}/rlottie/src/lottie/lottiemodel.cpp
        ${JNI_DIR}/rlottie/src/lottie/lottieparser.cpp
        ${JNI_DIR}/rlottie/src/lottie/lottieproxymodel.cpp
        ${JNI_DIR}/rlottie/src/vector/freetype/v_ft_math.cpp
        ${JNI_DIR}/rlottie/src/vector/freetype/v_ft_raster.cpp
        ${JNI_DIR}/rlottie/src/vector/freetype/v_ft_stroker.cpp
        ${JNI_DIR}/rlottie/src/vector/pixman/vregion.cpp
        ${JNI_DIR}/rlottie/src/vector/stb/stb_image.cpp
        ${JNI_DIR}/rlottie/src/vector/vbezier.cpp
        ${JNI_DIR}/rlottie/src/vector/vbitmap.cpp
        ${JNI_DIR}/rlottie/src/vector/vbrush.cpp
        ${JNI_DIR}/rlottie/src/vector/vcompositionfunctions.cpp
        ${JNI_DIR}/rlottie/src/vector/vdasher.cpp
        ${JNI_DIR}/rlottie/src/vector/vdebug.cpp
        ${JNI_DIR}/rlottie/src/vector/vdrawable.cpp
        ${JNI_DIR}/rlottie/src/vector/vdrawhelper.cpp
        ${JNI_DIR}/rlottie/src/vector/vdrawhelper_neon.cpp
        ${JNI_DIR}/rlottie/src/vector/velapsedtimer.cpp
        ${JNI_DIR}/rlottie/src/vector/vimageloader.cpp
        ${JNI_DIR}/rlottie/src/vector/vinterpolator.cpp
        ${JNI_DIR}/rlottie/src/vector/vmatrix.cpp
        ${JNI_DIR}/rlottie/src/vector/vpainter.cpp
        ${JNI_DIR}/rlottie/src/vector/vpath.cpp
        ${JNI_DIR}/rlottie/src/vector/vpathmesure.cpp
        ${JNI_DIR}/rlottie/src/vector/vraster.cpp
        ${JNI_DIR}/rlottie/src/vector/vrect.cpp
        ${JNI_DIR}/rlottie/src/vector/vrle.cpp)
target_compile_options(rlottie PUBLIC
        -Wall -fno-rtti -finline-functions -ffast-math -Oz -fno-unwind-tables -fno-asynchronous-unwind-tables -Wnon-virtual-dtor -Woverloaded-virtual -Wno-unused-parameter -fvisibility=hidden)
target_compile_definitions(rlottie PUBLIC HAVE_PTHREAD NDEBUG)
target_include_directories(rlottie PUBLIC
        ${JNI_DIR}
        ${JNI_DIR}/rlottie/inc
        ${JNI_DIR}/rlottie/src/vector/
        ${JNI_DIR}/rlottie/src/vector/pixman
        ${JNI_DIR}/rlottie/src/vector/freetype
        ${JNI_DIR}/rlottie/src/vector/stb)

#
# flac
#
add_library(flac STATIC
        ${JNI_DIR}/exoplayer/libFLAC/bitmath.c
        ${JNI_DIR}/exoplayer/libFLAC/bitreader.c
        ${JNI_DIR}/exoplayer/libFLAC/bitwriter.c
        ${JNI_DIR}/exoplayer/libFLAC/cpu.c
        ${JNI_DIR}/exoplayer/libFLAC/crc.c
        ${JNI_DIR}/exoplayer/libFLAC/fixed.c
        ${JNI_DIR}/exoplayer/libFLAC/fixed_intrin_sse2.c
        ${JNI_DIR}/exoplayer/libFLAC/fixed_intrin_ssse3.c
        ${JNI_DIR}/exoplayer/libFLAC/float.c
        ${JNI_DIR}/exoplayer/libFLAC/format.c
        ${JNI_DIR}/exoplayer/libFLAC/lpc.c
        ${JNI_DIR}/exoplayer/libFLAC/lpc_intrin_avx2.c
        ${JNI_DIR}/exoplayer/libFLAC/lpc_intrin_sse2.c
        ${JNI_DIR}/exoplayer/libFLAC/lpc_intrin_sse41.c
        ${JNI_DIR}/exoplayer/libFLAC/lpc_intrin_sse.c
        ${JNI_DIR}/exoplayer/libFLAC/md5.c
        ${JNI_DIR}/exoplayer/libFLAC/memory.c
        ${JNI_DIR}/exoplayer/libFLAC/metadata_iterators.c
        ${JNI_DIR}/exoplayer/libFLAC/metadata_object.c
        ${JNI_DIR}/exoplayer/libFLAC/stream_decoder.c
        ${JNI_DIR}/exoplayer/libFLAC/stream_encoder.c
        ${JNI_DIR}/exoplayer/libFLAC/stream_encoder_framing.c
        ${JNI_DIR}/exoplayer/libFLAC/stream_encoder_intrin_avx2.c
        ${JNI_DIR}/exoplayer/libFLAC/stream_encoder_intrin_sse2.c
        ${JNI_DIR}/exoplayer/libFLAC/stream_encoder_intrin_ssse3.c
        ${JNI_DIR}/exoplayer/libFLAC/window.c)
target_compile_options(flac PUBLIC
        -Oz -finline-functions -fPIC -frtti)
target_compile_definitions(flac PUBLIC
        _REENTRANT PIC U_COMMON_IMPLEMENTATION HAVE_SYS_PARAM_H VERSION="1.3.1" FLAC__NO_MD5 FLAC__INTEGER_ONLY_LIBRARY FLAC__NO_ASM
        # share/alloc.h only reaches SIZE_MAX through <stdint.h> behind this
        # flag; bionic's <limits.h> happens to define it, glibc's does not.
        HAVE_STDINT_H=1)
target_include_directories(flac PUBLIC
        ${JNI_DIR}/exoplayer/libFLAC/include)

#
# sqlite
#
add_library(sqlite STATIC ${JNI_DIR}/sqlite/sqlite3.c)
target_compile_options(sqlite PUBLIC -fno-strict-aliasing -Oz)
target_compile_definitions(sqlite PUBLIC
        NULL=0 SOCKLEN_T=socklen_t LOCALE_NOT_USED ANDROID_NDK DISABLE_IMPORTGL AVOID_TABLES ANDROID_TILE_BASED_DECODE HAVE_STRCHRNUL=0 ANDROID_ARMV6_IDCT)

#
# libtmessages
#
set(NATIVE_LIB "tmessages.49")

add_library(${NATIVE_LIB} SHARED
        ${JNI_DIR}/jni.c
        ${JNI_DIR}/audio.c
        ${JNI_DIR}/webm_encoder.c
        ${JNI_DIR}/image.cpp
        ${JNI_DIR}/video.c
        ${JNI_DIR}/intro/IntroRenderer.c
        ${JNI_DIR}/SqliteWrapper.cpp
        ${JNI_DIR}/utilities.cpp
        ${JNI_DIR}/gifvideo.cpp
        ${JNI_DIR}/lottie.cpp
        ${JNI_DIR}/TgNetWrapper.cpp
        ${JNI_DIR}/NativeLoader.cpp
        ${JNI_DIR}/exoplayer/flac_jni.cc
        ${JNI_DIR}/exoplayer/flac_parser.cc
        ${JNI_DIR}/exoplayer/opus_jni.cc
        ${JNI_DIR}/exoplayer/ffmpeg_jni.cc
        ${JNI_DIR}/fast-edge.cpp
        ${JNI_DIR}/genann.c
        ${JNI_DIR}/secureid_ocr.cpp)

target_compile_options(${NATIVE_LIB} PUBLIC
        -ffast-math -Oz -funroll-loops -ffast-math -fno-strict-aliasing -fno-math-errno)

target_compile_definitions(${NATIVE_LIB} PUBLIC
        BSD=1 NULL=0 SOCKLEN_T=socklen_t ANDROID_NDK DISABLE_IMPORTGL AVOID_TABLES ANDROID_TILE_BASED_DECODE __STDC_CONSTANT_MACROS ANDROID_ARMV6_IDCT OPUS_BUILD FIXED_POINT USE_ALLOCA restrict= __EMX__ LOCALE_NOT_USED HAVE_LRINT HAVE_LRINTF)

target_sources(${NATIVE_LIB} PRIVATE
        ${JNI_DIR}/opus/src/opus.c
        ${JNI_DIR}/opus/src/opus_decoder.c
        ${JNI_DIR}/opus/src/opus_encoder.c
        ${JNI_DIR}/opus/src/opus_multistream.c
        ${JNI_DIR}/opus/src/opus_multistream_encoder.c
        ${JNI_DIR}/opus/src/opus_multistream_decoder.c
        ${JNI_DIR}/opus/src/repacketizer.c
        ${JNI_DIR}/opus/src/analysis.c
        ${JNI_DIR}/opus/src/mlp.c
        ${JNI_DIR}/opus/src/mlp_data.c
        ${JNI_DIR}/opus/src/opus_projection_encoder.c
        ${JNI_DIR}/opus/src/opus_projection_decoder.c
        ${JNI_DIR}/opus/src/mapping_matrix.c

        ${JNI_DIR}/opus/silk/CNG.c
        ${JNI_DIR}/opus/silk/code_signs.c
        ${JNI_DIR}/opus/silk/init_decoder.c
        ${JNI_DIR}/opus/silk/decode_core.c
        ${JNI_DIR}/opus/silk/decode_frame.c
        ${JNI_DIR}/opus/silk/decode_parameters.c
        ${JNI_DIR}/opus/silk/decode_indices.c
        ${JNI_DIR}/opus/silk/decode_pulses.c
        ${JNI_DIR}/opus/silk/decoder_set_fs.c
        ${JNI_DIR}/opus/silk/dec_API.c
        ${JNI_DIR}/opus/silk/enc_API.c
        ${JNI_DIR}/opus/silk/encode_indices.c
        ${JNI_DIR}/opus/silk/encode_pulses.c
        ${JNI_DIR}/opus/silk/gain_quant.c
        ${JNI_DIR}/opus/silk/interpolate.c
        ${JNI_DIR}/opus/silk/LP_variable_cutoff.c
        ${JNI_DIR}/opus/silk/NLSF_decode.c
        ${JNI_DIR}/opus/silk/NSQ.c
        ${JNI_DIR}/opus/silk/NSQ_del_dec.c
        ${JNI_DIR}/opus/silk/PLC.c
        ${JNI_DIR}/opus/silk/shell_coder.c
        ${JNI_DIR}/opus/silk/tables_gain.c
        ${JNI_DIR}/opus/silk/tables_LTP.c
        ${JNI_DIR}/opus/silk/tables_NLSF_CB_NB_MB.c
        ${JNI_DIR}/opus/silk/tables_NLSF_CB_WB.c
        ${JNI_DIR}/opus/silk/tables_other.c
        ${JNI_DIR}/opus/silk/tables_pitch_lag.c
        ${JNI_DIR}/opus/silk/tables_pulses_per_block.c
        ${JNI_DIR}/opus/silk/VAD.c
        ${JNI_DIR}/opus/silk/control_audio_bandwidth.c
        ${JNI_DIR}/opus/silk/quant_LTP_gains.c
        ${JNI_DIR}/opus/silk/VQ_WMat_EC.c
        ${JNI_DIR}/opus/silk/HP_variable_cutoff.c
        ${JNI_DIR}/opus/silk/NLSF_encode.c
        ${JNI_DIR}/opus/silk/NLSF_VQ.c
        ${JNI_DIR}/opus/silk/NLSF_unpack.c
        ${JNI_DIR}/opus/silk/NLSF_del_dec_quant.c
        ${JNI_DIR}/opus/silk/process_NLSFs.c
        ${JNI_DIR}/opus/silk/stereo_LR_to_MS.c
        ${JNI_DIR}/opus/silk/stereo_MS_to_LR.c
        ${JNI_DIR}/opus/silk/check_control_input.c
        ${JNI_DIR}/opus/silk/control_SNR.c
        ${JNI_DIR}/opus/silk/init_encoder.c
        ${JNI_DIR}/opus/silk/control_codec.c
        ${JNI_DIR}/opus/silk/A2NLSF.c
        ${JNI_DIR}/opus/silk/ana_filt_bank_1.c
        ${JNI_DIR}/opus/silk/biquad_alt.c
        ${JNI_DIR}/opus/silk/bwexpander_32.c
        ${JNI_DIR}/opus/silk/bwexpander.c
        ${JNI_DIR}/opus/silk/debug.c
        ${JNI_DIR}/opus/silk/decode_pitch.c
        ${JNI_DIR}/opus/silk/inner_prod_aligned.c
        ${JNI_DIR}/opus/silk/lin2log.c
        ${JNI_DIR}/opus/silk/log2lin.c
        ${JNI_DIR}/opus/silk/LPC_analysis_filter.c
        ${JNI_DIR}/opus/silk/LPC_inv_pred_gain.c
        ${JNI_DIR}/opus/silk/table_LSF_cos.c
        ${JNI_DIR}/opus/silk/NLSF2A.c
        ${JNI_DIR}/opus/silk/NLSF_stabilize.c
        ${JNI_DIR}/opus/silk/NLSF_VQ_weights_laroia.c
        ${JNI_DIR}/opus/silk/pitch_est_tables.c
        ${JNI_DIR}/opus/silk/resampler.c
        ${JNI_DIR}/opus/silk/resampler_down2_3.c
        ${JNI_DIR}/opus/silk/resampler_down2.c
        ${JNI_DIR}/opus/silk/resampler_private_AR2.c
        ${JNI_DIR}/opus/silk/resampler_private_down_FIR.c
        ${JNI_DIR}/opus/silk/resampler_private_IIR_FIR.c
        ${JNI_DIR}/opus/silk/resampler_private_up2_HQ.c
        ${JNI_DIR}/opus/silk/resampler_rom.c
        ${JNI_DIR}/opus/silk/sigm_Q15.c
        ${JNI_DIR}/opus/silk/sort.c
        ${JNI_DIR}/opus/silk/sum_sqr_shift.c
        ${JNI_DIR}/opus/silk/stereo_decode_pred.c
        ${JNI_DIR}/opus/silk/stereo_encode_pred.c
        ${JNI_DIR}/opus/silk/stereo_find_predictor.c
        ${JNI_DIR}/opus/silk/stereo_quant_pred.c
        ${JNI_DIR}/opus/silk/LPC_fit.c

        ${JNI_DIR}/opus/silk/fixed/LTP_analysis_filter_FIX.c
        ${JNI_DIR}/opus/silk/fixed/LTP_scale_ctrl_FIX.c
        ${JNI_DIR}/opus/silk/fixed/corrMatrix_FIX.c
        ${JNI_DIR}/opus/silk/fixed/encode_frame_FIX.c
        ${JNI_DIR}/opus/silk/fixed/find_LPC_FIX.c
        ${JNI_DIR}/opus/silk/fixed/find_LTP_FIX.c
        ${JNI_DIR}/opus/silk/fixed/find_pitch_lags_FIX.c
        ${JNI_DIR}/opus/silk/fixed/find_pred_coefs_FIX.c
        ${JNI_DIR}/opus/silk/fixed/noise_shape_analysis_FIX.c
        ${JNI_DIR}/opus/silk/fixed/process_gains_FIX.c
        ${JNI_DIR}/opus/silk/fixed/regularize_correlations_FIX.c
        ${JNI_DIR}/opus/silk/fixed/residual_energy16_FIX.c
        ${JNI_DIR}/opus/silk/fixed/residual_energy_FIX.c
        ${JNI_DIR}/opus/silk/fixed/warped_autocorrelation_FIX.c
        ${JNI_DIR}/opus/silk/fixed/apply_sine_window_FIX.c
        ${JNI_DIR}/opus/silk/fixed/autocorr_FIX.c
        ${JNI_DIR}/opus/silk/fixed/burg_modified_FIX.c
        ${JNI_DIR}/opus/silk/fixed/k2a_FIX.c
        ${JNI_DIR}/opus/silk/fixed/k2a_Q16_FIX.c
        ${JNI_DIR}/opus/silk/fixed/pitch_analysis_core_FIX.c
        ${JNI_DIR}/opus/silk/fixed/vector_ops_FIX.c
        ${JNI_DIR}/opus/silk/fixed/schur64_FIX.c
        ${JNI_DIR}/opus/silk/fixed/schur_FIX.c

        ${JNI_DIR}/opus/celt/bands.c
        ${JNI_DIR}/opus/celt/celt.c
        ${JNI_DIR}/opus/celt/celt_encoder.c
        ${JNI_DIR}/opus/celt/celt_decoder.c
        ${JNI_DIR}/opus/celt/cwrs.c
        ${JNI_DIR}/opus/celt/entcode.c
        ${JNI_DIR}/opus/celt/entdec.c
        ${JNI_DIR}/opus/celt/entenc.c
        ${JNI_DIR}/opus/celt/kiss_fft.c
        ${JNI_DIR}/opus/celt/laplace.c
        ${JNI_DIR}/opus/celt/mathops.c
        ${JNI_DIR}/opus/celt/mdct.c
        ${JNI_DIR}/opus/celt/modes.c
        ${JNI_DIR}/opus/celt/pitch.c
        ${JNI_DIR}/opus/celt/celt_lpc.c
        ${JNI_DIR}/opus/celt/quant_bands.c
        ${JNI_DIR}/opus/celt/rate.c
        ${JNI_DIR}/opus/celt/vq.c
        ${JNI_DIR}/opus/celt/arm/armcpu.c
        ${JNI_DIR}/opus/celt/arm/arm_celt_map.c

        ${JNI_DIR}/opus/ogg/bitwise.c
        ${JNI_DIR}/opus/ogg/framing.c
        ${JNI_DIR}/opus/opusfile/info.c
        ${JNI_DIR}/opus/opusfile/internal.c
        ${JNI_DIR}/opus/opusfile/opusfile.c
        ${JNI_DIR}/opus/opusfile/stream.c

        ${JNI_DIR}/third_party/libyuv/source/compare_common.cc
        ${JNI_DIR}/third_party/libyuv/source/compare_gcc.cc
        ${JNI_DIR}/third_party/libyuv/source/compare_neon64.cc
        ${JNI_DIR}/third_party/libyuv/source/compare_win.cc
        ${JNI_DIR}/third_party/libyuv/source/compare.cc
        ${JNI_DIR}/third_party/libyuv/source/convert_argb.cc
        ${JNI_DIR}/third_party/libyuv/source/convert_from_argb.cc
        ${JNI_DIR}/third_party/libyuv/source/convert_from.cc
        ${JNI_DIR}/third_party/libyuv/source/convert_jpeg.cc
        ${JNI_DIR}/third_party/libyuv/source/convert_to_argb.cc
        ${JNI_DIR}/third_party/libyuv/source/convert_to_i420.cc
        ${JNI_DIR}/third_party/libyuv/source/convert.cc
        ${JNI_DIR}/third_party/libyuv/source/cpu_id.cc
        ${JNI_DIR}/third_party/libyuv/source/mjpeg_decoder.cc
        ${JNI_DIR}/third_party/libyuv/source/mjpeg_validate.cc
        ${JNI_DIR}/third_party/libyuv/source/planar_functions.cc
        ${JNI_DIR}/third_party/libyuv/source/rotate_any.cc
        ${JNI_DIR}/third_party/libyuv/source/rotate_argb.cc
        ${JNI_DIR}/third_party/libyuv/source/rotate_common.cc
        ${JNI_DIR}/third_party/libyuv/source/rotate_gcc.cc
        ${JNI_DIR}/third_party/libyuv/source/rotate_neon64.cc
        ${JNI_DIR}/third_party/libyuv/source/rotate_win.cc
        ${JNI_DIR}/third_party/libyuv/source/rotate.cc
        ${JNI_DIR}/third_party/libyuv/source/row_any.cc
        ${JNI_DIR}/third_party/libyuv/source/row_common.cc
        ${JNI_DIR}/third_party/libyuv/source/row_gcc.cc
        ${JNI_DIR}/third_party/libyuv/source/row_neon64.cc
        ${JNI_DIR}/third_party/libyuv/source/row_win.cc
        ${JNI_DIR}/third_party/libyuv/source/scale_any.cc
        ${JNI_DIR}/third_party/libyuv/source/scale_argb.cc
        ${JNI_DIR}/third_party/libyuv/source/scale_common.cc
        ${JNI_DIR}/third_party/libyuv/source/scale_gcc.cc
        ${JNI_DIR}/third_party/libyuv/source/scale_neon64.cc
        ${JNI_DIR}/third_party/libyuv/source/scale_win.cc
        ${JNI_DIR}/third_party/libyuv/source/scale.cc
        ${JNI_DIR}/third_party/libyuv/source/video_common.cc
        ${JNI_DIR}/third_party/libyuv/source/scale_uv.cc
        ${JNI_DIR}/third_party/libyuv/source/rotate_lsx.cc
        ${JNI_DIR}/third_party/libyuv/source/row_lasx.cc
        ${JNI_DIR}/third_party/libyuv/source/row_lsx.cc
        ${JNI_DIR}/third_party/libyuv/source/scale_lsx.cc
        ${JNI_DIR}/third_party/libyuv/source/scale_rgb.cc)

target_include_directories(${NATIVE_LIB} PUBLIC
        ${SHIM_DIR}
        ${JNI_DIR}
        ${JNI_DIR}/opus/include
        ${JNI_DIR}/opus/silk
        ${JNI_DIR}/opus/silk/fixed
        ${JNI_DIR}/opus/celt
        ${JNI_DIR}/opus/
        ${JNI_DIR}/opus/opusfile
        ${JNI_DIR}/third_party/libyuv/include
        ${JNI_DIR}/exoplayer/include
        ${JNI_DIR}/exoplayer/libFLAC/include
        ${JNI_DIR}/intro
        ${JNI_DIR}/rlottie/inc
        # gifvideo.cpp includes two webrtc H.264 parser headers it never uses;
        # they resolve relative to jni/, their own includes need this root.
        ${JNI_DIR}/voip/webrtc
        ${JNI_DIR}/tde2e/include
        ${PORT_NATIVE_OUT}/boringssl/include
        ${PORT_NATIVE_OUT}/ffmpeg/include
        ${PORT_NATIVE_OUT}/libvpx/include
        ${JAVA_INCLUDE_DIRS})

target_link_libraries(${NATIVE_LIB}
        -Wl,--whole-archive rnnoise openh264 voipandroid -Wl,--no-whole-archive
        tgvoip
        tgcalls
        tgcalls_tp
        tde2e
        tgnet
        flac
        rlottie
        sqlite
        swscale
        avformat
        avcodec
        avresample
        swresample
        libvpx
        libdav1d
        avutil
        ssl
        crypto
        androidlog
        ${ATLAS_LIBANDROID}
        OpenSLES
        z
        GLESv2
        EGL
        pthread
        dl
        m)

# The .so is installed into $PORT_OUT next to the OpenSL ES stub, so $ORIGIN
# covers it; atlas's libandroid.so.0 comes from out/atlas/ once build-atlas.sh has run,
# with the atlas builddir as the fallback. Without this the default RPATH would
# be the CMake build tree.
# Only the JNI entry points are public; see native/libtmessages.map for the
# GStreamer plugin collision that made this load-bearing. It has to be on the
# target, not in CMAKE_SHARED_LINKER_FLAGS: that would hide the OpenSL ES
# stub's own symbols too, and this library imports them.
target_link_options(${NATIVE_LIB} PRIVATE
        "-Wl,--version-script=${CMAKE_CURRENT_LIST_DIR}/libtmessages.map")

set_target_properties(${NATIVE_LIB} PROPERTIES
        OUTPUT_NAME "tmessages.49"
        PREFIX "lib"
        BUILD_WITH_INSTALL_RPATH TRUE
        INSTALL_RPATH "$ORIGIN:$ORIGIN/atlas:${ATLAS_BUILDDIR}")
