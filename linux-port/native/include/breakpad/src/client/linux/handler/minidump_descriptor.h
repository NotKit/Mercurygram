/*
 * Shim for google_breakpad::MinidumpDescriptor — breakpad is not built for the
 * desktop port (its Android-specific sources and getcontext asm are excluded),
 * so utilities.cpp compiles against this no-op instead. Crash minidumps are a
 * Non-Goal; HotSpot writes its own hs_err file.
 */
#ifndef LINUX_PORT_BREAKPAD_MINIDUMP_DESCRIPTOR_H
#define LINUX_PORT_BREAKPAD_MINIDUMP_DESCRIPTOR_H

#include <string>

namespace google_breakpad {

class MinidumpDescriptor {
public:
	explicit MinidumpDescriptor(const char *directory) : directory_(directory ? directory : "") {}
	explicit MinidumpDescriptor(const std::string &directory) : directory_(directory) {}
	const char *path() const { return directory_.c_str(); }

private:
	std::string directory_;
};

}  // namespace google_breakpad

#endif /* LINUX_PORT_BREAKPAD_MINIDUMP_DESCRIPTOR_H */
