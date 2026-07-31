# CMake toolchain for a cross build of the port's native code, driven by the
# variables env.sh exports ($PORT_TRIPLE, $PORT_CC, ...). A native build passes
# no toolchain file at all, so this file only ever describes the arm64 target.
#
# There is no CMAKE_SYSROOT: the build container is a multiarch root, where the
# target's headers and libraries sit beside the host's and the cross gcc already
# knows where to look.

set(CMAKE_SYSTEM_NAME Linux)

if("$ENV{PORT_TRIPLE}" MATCHES "^aarch64")
    set(CMAKE_SYSTEM_PROCESSOR aarch64)
else()
    message(FATAL_ERROR "toolchain-cross.cmake: unhandled PORT_TRIPLE '$ENV{PORT_TRIPLE}'")
endif()

set(CMAKE_C_COMPILER   "$ENV{PORT_CC}")
set(CMAKE_CXX_COMPILER "$ENV{PORT_CXX}")
set(CMAKE_AR           "$ENV{PORT_AR}")
set(CMAKE_RANLIB       "$ENV{PORT_RANLIB}")
set(CMAKE_STRIP        "$ENV{PORT_STRIP}")

# Host tools (perl, go, python) must stay findable; libraries and includes are
# the target's, and every one this build needs is passed as an explicit path.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
