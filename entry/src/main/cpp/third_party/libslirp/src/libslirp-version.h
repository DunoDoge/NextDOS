/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * Hand-written replacement for the meson-generated libslirp-version.h.
 *
 * Upstream generates this file from libslirp-version.h.in via meson; the
 * NextDOS build vendors the source subset without meson, so the version
 * numbers are pinned here to match the libslirp v4.8.0 release the rest of
 * the tree (and the fork's public header) is aligned with.
 */
#ifndef LIBSLIRP_VERSION_H_
#define LIBSLIRP_VERSION_H_

#ifdef __cplusplus
extern "C" {
#endif

#define SLIRP_MAJOR_VERSION 4
#define SLIRP_MINOR_VERSION 8
#define SLIRP_MICRO_VERSION 0
#define SLIRP_VERSION_STRING "4.8.0"

#define SLIRP_CHECK_VERSION(major, minor, micro)                          \
    (SLIRP_MAJOR_VERSION > (major) ||                                     \
     (SLIRP_MAJOR_VERSION == (major) && SLIRP_MINOR_VERSION > (minor)) ||  \
     (SLIRP_MAJOR_VERSION == (major) && SLIRP_MINOR_VERSION == (minor) &&  \
      SLIRP_MICRO_VERSION >= (micro)))

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* LIBSLIRP_VERSION_H_ */
