/*
 * Shim for google_breakpad::ExceptionHandler — see minidump_descriptor.h.
 * Constructing one installs no signal handler; setupNativeCrashesListener
 * becomes a no-op.
 */
#ifndef LINUX_PORT_BREAKPAD_EXCEPTION_HANDLER_H
#define LINUX_PORT_BREAKPAD_EXCEPTION_HANDLER_H

#include "breakpad/src/client/linux/handler/minidump_descriptor.h"

namespace google_breakpad {

class ExceptionHandler {
public:
	typedef bool (*FilterCallback)(void *context);
	typedef bool (*MinidumpCallback)(const MinidumpDescriptor &descriptor, void *context, bool succeeded);

	ExceptionHandler(const MinidumpDescriptor &, FilterCallback, MinidumpCallback,
	                 void *, bool, int) {}
};

}  // namespace google_breakpad

#endif /* LINUX_PORT_BREAKPAD_EXCEPTION_HANDLER_H */
