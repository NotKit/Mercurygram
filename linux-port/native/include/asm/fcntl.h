/*
 * gifvideo.cpp includes <asm/fcntl.h> and <linux/stat.h> next to <fcntl.h>.
 * bionic tolerates mixing the kernel UAPI headers with the libc ones; glibc
 * does not (struct flock, F_* and f_owner_ex end up defined twice). Forward to
 * the libc header, which is what the file actually wants (open() flags).
 */
#include <fcntl.h>
