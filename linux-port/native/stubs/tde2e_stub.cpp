/*
 * Stand-in for libtde2e (jni/td submodule, not checked out). Instance.cpp
 * only reaches it from a conference call's frame encryptor, so those calls
 * fail while one-to-one and group calls are unaffected. Building the real
 * library is the follow-up; see BRINGUP_NOTES.md.
 */
#include "e2e_api.h"

namespace tde2e_api {

static Error unavailable()
{
	return Error{ErrorCode::UnknownError, "tde2e is not built in this port"};
}

Result<Bytes> call_encrypt(CallId, CallChannelId, SecureSlice, size_t)
{
	return unavailable();
}

Result<SecureBytes> call_decrypt(CallId, UserId, CallChannelId, Slice)
{
	return unavailable();
}

} // namespace tde2e_api
