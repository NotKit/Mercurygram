/*
 * rtc::getifaddrs for the glibc port, replacing webrtc's
 * rtc_base/ifaddrs_android.cc.
 *
 * Two reasons it cannot be the Android one. It exists only because bionic had
 * no getifaddrs, which glibc does; and webrtc drops every interface whose
 * ifa_flags lack IFF_RUNNING (rtc_base/network.cc), which no interface on a
 * Halium device sets -- an Ubuntu Touch phone carrying a live connection on
 * wlan0 reports flags 0x1003: UP, BROADCAST, MULTICAST, no RUNNING. webrtc
 * then finds no local candidate and a call never connects.
 *
 * So: take glibc's list and treat "up, and has an address" as running, which
 * is what the flag means on a kernel that maintains it. Nothing else about the
 * list changes. On a host that does set IFF_RUNNING this is a no-op.
 *
 * webrtc's struct ifaddrs (rtc_base/ifaddrs_android.h) is the first five
 * members of glibc's, in the same order, and webrtc reads no others, so the
 * pointers pass through unchanged. This file must therefore NOT include that
 * header: both declare `struct ifaddrs` at global scope.
 */
#include <ifaddrs.h>
#include <net/if.h>

namespace rtc {

int getifaddrs(struct ifaddrs **result)
{
	if (::getifaddrs(result) != 0)
		return -1;

	for (struct ifaddrs *cursor = *result; cursor; cursor = cursor->ifa_next) {
		if ((cursor->ifa_flags & IFF_UP) && cursor->ifa_addr)
			cursor->ifa_flags |= IFF_RUNNING;
	}
	return 0;
}

void freeifaddrs(struct ifaddrs *addrs)
{
	::freeifaddrs(addrs);
}

} // namespace rtc
