/*
 * Force-included into every C++ translation unit of the desktop build
 * (-include port_compat.hpp). It papers over the two ways the jni/ sources
 * depend on the NDK toolchain rather than on standard C++.
 */
#ifndef LINUX_PORT_COMPAT_HPP
#define LINUX_PORT_COMPAT_HPP

/*
 * 1. The NDK's libc++ pulls these in transitively from <string> and friends;
 *    libstdc++ does not, so tgnet and rlottie reference std::unique_ptr,
 *    std::memcpy, std::max and std::int32_t without including anything.
 *    (<cstdint> is only missed by gcc: clang's libstdc++ path happens to have
 *    it already, so this one first showed in the arm64 cross build.)
 */
#include <algorithm>
#include <climits>
#include <cstdint>
#include <cstring>
#include <memory>
#include <sys/time.h>
/* bionic's <ucontext.h> brings <signal.h> with it; glibc's does not, and
 * webrtc's sdk/android stacktrace.cc relies on that. */
#include <signal.h>

/*
 * 2. Android types JavaVM::AttachCurrentThread's first parameter as JNIEnv**,
 *    the JDK as void**. C++ rejects the implicit conversion, and the call
 *    appears in tgnet and gifvideo a dozen times. Insert the cast at the call
 *    sites instead of patching upstream files. The macro must come after
 *    <jni.h> so it does not rewrite the declaration itself.
 */
#include <jni.h>
#define AttachCurrentThread(penv, args) AttachCurrentThread((void **) (penv), (args))
#define AttachCurrentThreadAsDaemon(penv, args) AttachCurrentThreadAsDaemon((void **) (penv), (args))

/*
 * 3. clang 21 rejects [[clang::lifetimebound]] on a parameter of a function
 *    returning void, which webrtc's api/candidate.h has. absl defines the
 *    macro unconditionally, so include its header first and empty the macro;
 *    it is a lint annotation, nothing changes in the code. Targets without
 *    webrtc on their include path skip this.
 */
#if __has_include(<absl/base/attributes.h>)
#include <absl/base/attributes.h>
#undef ABSL_ATTRIBUTE_LIFETIME_BOUND
#define ABSL_ATTRIBUTE_LIFETIME_BOUND
#endif

#endif /* LINUX_PORT_COMPAT_HPP */
