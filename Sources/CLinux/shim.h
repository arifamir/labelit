// System headers and calls Swift's Glibc module leaves out: extended attributes, and a file's birth time (statx).
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/xattr.h>

/// When the file was created on this file system, or -1 where the file system doesn't record it.
/// (Foundation's creationDate on Linux is the status-change time, which moves on every rename.)
static inline double labelit_birth_time(const char *path) {
    struct statx info;
    if (statx(AT_FDCWD, path, 0, STATX_BTIME, &info) != 0 || !(info.stx_mask & STATX_BTIME)) return -1;
    return (double)info.stx_btime.tv_sec + (double)info.stx_btime.tv_nsec / 1e9;
}
