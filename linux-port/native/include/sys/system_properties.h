/*
 * bionic's <sys/system_properties.h>, for libtgvoip built with __ANDROID__ so
 * it selects its JNI audio path. There is no property store here; every
 * lookup answers "unset".
 */
#ifndef PORT_SYS_SYSTEM_PROPERTIES_H
#define PORT_SYS_SYSTEM_PROPERTIES_H

#define PROP_VALUE_MAX 92

#ifdef __cplusplus
extern "C" {
#endif

static inline int __system_property_get(const char *name, char *value)
{
	(void)name;
	value[0] = '\0';
	return 0;
}

#ifdef __cplusplus
}
#endif

#endif
