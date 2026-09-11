// SPDX-FileCopyrightText: 2026 The NextDOS Authors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Minimal glib-2.0 compatibility layer for the vendored libslirp 4.8.0.
//
// Why this exists: libslirp depends on glib-2.0, but the symbol surface the
// engine's slirp backend actually uses is small (no GHashTable, GMutex or
// GMainLoop). Shipping real glib into the HAP would add megabytes for a
// handful of helpers, so this header + glib_shim.c reimplement exactly the
// surface libslirp touches (see the symbol list in PRD REQ-04 section 1).
//
// Semantics follow upstream glib where it matters: g_malloc0 zeroes,
// g_string_free(s, FALSE) returns the segment and transfers ownership,
// g_strdup(NULL) returns NULL, g_free(NULL) is a no-op. The fork_exec /
// g_spawn path is implemented as "log and report failure" - the DOSBox
// engine never calls it (libslirp only uses it for the unused
// `exec`/`fork_exec` socket feature).
//
// Everything is declared with C linkage; libslirp compiles as C99.

#ifndef __G_LIB_H__
#define __G_LIB_H__

/* signal.h: real glib pulls it in through <glib/gmain.h>, and libslirp's
 * misc.c fork_exec child-setup path relies on that (SIG_SETMASK/SIGCHLD/
 * SIG_DFL) without including <signal.h> itself. Keep the same transitive
 * availability so the vendored sources stay byte-identical to upstream. */
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ */
/* Scalar types (subset of glib's gtypes.h)                            */
/* ------------------------------------------------------------------ */
typedef char gchar;
typedef unsigned char guchar;
typedef int gint;
typedef unsigned int guint;
typedef long glong;
typedef unsigned long gulong;
typedef void* gpointer;
typedef const void* gconstpointer;

typedef int8_t gint8;
typedef uint8_t guint8;
typedef int16_t gint16;
typedef uint16_t guint16;
typedef int32_t gint32;
typedef uint32_t guint32;
typedef int64_t gint64;
typedef uint64_t guint64;
typedef float gfloat;
typedef double gdouble;

typedef size_t gsize;
typedef ptrdiff_t gssize;
typedef int gboolean;
typedef guint32 GQuark;
typedef gint GPid;
typedef gchar** GStrv;

#ifndef TRUE
#define TRUE 1
#endif
#ifndef FALSE
#define FALSE 0
#endif

/* ------------------------------------------------------------------ */
/* Version / endianness / OS detection                                 */
/* ------------------------------------------------------------------ */
#define GLIB_MAJOR_VERSION 2
#define GLIB_MINOR_VERSION 58
#define GLIB_MICRO_VERSION 0

#define GLIB_CHECK_VERSION(major, minor, micro)                          \
    (GLIB_MAJOR_VERSION > (major) ||                                     \
     (GLIB_MAJOR_VERSION == (major) && GLIB_MINOR_VERSION > (minor)) ||  \
     (GLIB_MAJOR_VERSION == (major) && GLIB_MINOR_VERSION == (minor) &&  \
      GLIB_MICRO_VERSION >= (micro)))

#define G_LITTLE_ENDIAN 1234
#define G_BIG_ENDIAN 4321
#define G_PDP_ENDIAN 3412

#if defined(__BYTE_ORDER__) && (__BYTE_ORDER__ == __ORDER_BIG_ENDIAN__)
#define G_BYTE_ORDER G_BIG_ENDIAN
#else
#define G_BYTE_ORDER G_LITTLE_ENDIAN
#endif

#if defined(_WIN32)
#define G_OS_WIN32 1
#else
#define G_OS_UNIX 1
#endif

/* ------------------------------------------------------------------ */
/* Utility macros                                                      */
/* ------------------------------------------------------------------ */
#define G_N_ELEMENTS(arr) (sizeof(arr) / sizeof((arr)[0]))

#define G_UNLIKELY(expr) __builtin_expect(!!(expr), 0)
#define G_LIKELY(expr) __builtin_expect(!!(expr), 1)

#define G_GNUC_PRINTF(fmt_idx, arg_idx) \
    __attribute__((__format__(__printf__, fmt_idx, arg_idx)))

#define G_GNUC_UNUSED __attribute__((__unused__))

#define G_STMT_START do
#define G_STMT_END while (0)

#if defined(__STDC_VERSION__) && (__STDC_VERSION__ >= 201112L)
#define G_STATIC_ASSERT(expr) _Static_assert((expr), #expr)
#else
#define G_STATIC_ASSERT(expr)                                            \
    typedef char glib_static_assertion_##__LINE__[(expr) ? 1 : -1]       \
            __attribute__((__unused__))
#endif

#ifndef G_SIZEOF_MEMBER
#define G_SIZEOF_MEMBER(type, member) sizeof(((type*)0)->member)
#endif

#ifndef MIN
#define MIN(a, b) (((a) < (b)) ? (a) : (b))
#endif
#ifndef MAX
#define MAX(a, b) (((a) > (b)) ? (a) : (b))
#endif
#ifndef ABS
#define ABS(a) (((a) < 0) ? -(a) : (a))
#endif
#ifndef CLAMP
#define CLAMP(x, low, high) (((x) > (high)) ? (high) : (((x) < (low)) ? (low) : (x)))
#endif

/* ------------------------------------------------------------------ */
/* Memory                                                              */
/* ------------------------------------------------------------------ */
gpointer g_malloc(gsize n_bytes);
gpointer g_malloc0(gsize n_bytes);
gpointer g_realloc(gpointer mem, gsize n_bytes);
void g_free(gpointer mem);

#define g_new(struct_type, n_structs) \
    ((struct_type*)g_malloc(sizeof(struct_type) * (gsize)(n_structs)))

#define g_new0(struct_type, n_structs) \
    ((struct_type*)g_malloc0(sizeof(struct_type) * (gsize)(n_structs)))

#define g_renew(struct_type, mem, n_structs) \
    ((struct_type*)g_realloc((mem), sizeof(struct_type) * (gsize)(n_structs)))

/* ------------------------------------------------------------------ */
/* Strings                                                             */
/* ------------------------------------------------------------------ */
gchar* g_strdup(const gchar* str);
gsize g_strlcpy(gchar* dest, const gchar* src, gsize dest_size);
gchar* g_strstr_len(const gchar* haystack, gssize haystack_len,
                    const gchar* needle);
gboolean g_str_has_prefix(const gchar* str, const gchar* prefix);
gint g_ascii_strcasecmp(const gchar* s1, const gchar* s2);
gint g_snprintf(gchar* string, gulong n, const gchar* format, ...)
        G_GNUC_PRINTF(3, 4);
gint g_vsnprintf(gchar* string, gulong n, const gchar* format, va_list args);
void g_strfreev(gchar** str_array);
guint g_strv_length(gchar** str_array);
gchar* g_strerror(gint errnum);
const gchar* g_getenv(const gchar* variable);

/* ------------------------------------------------------------------ */
/* GString (growable string)                                           */
/* ------------------------------------------------------------------ */
typedef struct _GString {
    gchar* str;
    gsize len;
    gsize allocated_len;
} GString;

GString* g_string_new(const gchar* init);
gchar* g_string_free(GString* string, gboolean free_segment);
GString* g_string_append_printf(GString* string, const gchar* format, ...)
        G_GNUC_PRINTF(2, 3);

/* ------------------------------------------------------------------ */
/* GRand (pseudo random; used for DHCP/port randomisation only, no     */
/* cryptographic strength required)                                    */
/* ------------------------------------------------------------------ */
typedef struct _GRand GRand;

GRand* g_rand_new(void);
void g_rand_free(GRand* rand);
gint32 g_rand_int_range(GRand* rand, gint32 begin, gint32 end);

/* ------------------------------------------------------------------ */
/* GError                                                              */
/* ------------------------------------------------------------------ */
typedef struct _GError {
    GQuark domain;
    gint code;
    gchar* message;
} GError;

void g_error_free(GError* error);

/* ------------------------------------------------------------------ */
/* Process spawning (never used by the engine's slirp backend; the     */
/* shim logs and reports failure instead of forking)                   */
/* ------------------------------------------------------------------ */
typedef enum {
    G_SPAWN_DEFAULT = 0,
    G_SPAWN_LEAVE_DESCRIPTORS_OPEN = 1 << 0,
    G_SPAWN_DO_NOT_REAP_CHILD = 1 << 1,
    G_SPAWN_SEARCH_PATH = 1 << 2,
    G_SPAWN_STDOUT_TO_DEV_NULL = 1 << 3,
    G_SPAWN_STDERR_TO_DEV_NULL = 1 << 4,
    G_SPAWN_CHILD_INHERITS_STDIN = 1 << 5,
    G_SPAWN_FILE_AND_ARGV_ZERO = 1 << 6,
    G_SPAWN_SEARCH_PATH_FROM_ENVP = 1 << 7,
    G_SPAWN_CLOEXEC_PIPES = 1 << 8,
} GSpawnFlags;

typedef void (*GSpawnChildSetupFunc)(gpointer user_data);

gboolean g_spawn_async(const gchar* working_directory, gchar** argv,
                       gchar** envp, GSpawnFlags flags,
                       GSpawnChildSetupFunc child_setup, gpointer user_data,
                       GPid* child_pid, GError** error);

gboolean g_spawn_async_with_fds(const gchar* working_directory, gchar** argv,
                                gchar** envp, GSpawnFlags flags,
                                GSpawnChildSetupFunc child_setup,
                                gpointer user_data, GPid* child_pid,
                                gint stdin_fd, gint stdout_fd, gint stderr_fd,
                                GError** error);

gboolean g_shell_parse_argv(const gchar* command_line, gint* argcp,
                            gchar*** argvp, GError** error);

/* ------------------------------------------------------------------ */
/* Debug keys (SLIRP_DEBUG parsing)                                    */
/* ------------------------------------------------------------------ */
typedef struct _GDebugKey {
    const gchar* name;
    guint bit;
} GDebugKey;

guint g_parse_debug_string(const gchar* string, const GDebugKey* keys,
                           guint nkeys);

/* ------------------------------------------------------------------ */
/* Logging                                                             */
/* ------------------------------------------------------------------ */
void g_warning(const gchar* format, ...) G_GNUC_PRINTF(1, 2);
void g_critical(const gchar* format, ...) G_GNUC_PRINTF(1, 2);
/* Faithful to glib: g_error() never returns. */
void g_error(const gchar* format, ...)
        __attribute__((__noreturn__)) G_GNUC_PRINTF(1, 2);
void g_debug(const gchar* format, ...) G_GNUC_PRINTF(1, 2);

/* Fatal-assert plumbing (implemented in glib_shim.c). */
void glib_shim_assert_fail(const char* expr, const char* file, int line,
                           const char* func) __attribute__((__noreturn__));
void glib_shim_return_fail(const char* expr, const char* file, int line,
                           const char* func);

#ifdef G_DISABLE_ASSERT
#define g_assert(expr) G_STMT_START { (void)0; } G_STMT_END
#define g_assert_not_reached() G_STMT_START { (void)0; } G_STMT_END
#else
#define g_assert(expr)                                                    \
    G_STMT_START                                                          \
    {                                                                     \
        if (G_UNLIKELY(!(expr))) {                                        \
            glib_shim_assert_fail(#expr, __FILE__, __LINE__, __func__);   \
        }                                                                 \
    }                                                                     \
    G_STMT_END
#define g_assert_not_reached()                                            \
    G_STMT_START                                                          \
    {                                                                     \
        glib_shim_assert_fail("code should not be reached", __FILE__,     \
                              __LINE__, __func__);                        \
    }                                                                     \
    G_STMT_END
#endif

#define g_return_if_fail(expr)                                            \
    G_STMT_START                                                          \
    {                                                                     \
        if (G_UNLIKELY(!(expr))) {                                        \
            glib_shim_return_fail(#expr, __FILE__, __LINE__, __func__);   \
            return;                                                       \
        }                                                                 \
    }                                                                     \
    G_STMT_END

#define g_return_val_if_fail(expr, val)                                   \
    G_STMT_START                                                          \
    {                                                                     \
        if (G_UNLIKELY(!(expr))) {                                        \
            glib_shim_return_fail(#expr, __FILE__, __LINE__, __func__);   \
            return (val);                                                 \
        }                                                                 \
    }                                                                     \
    G_STMT_END

#define g_warn_if_fail(expr)                                              \
    G_STMT_START                                                          \
    {                                                                     \
        if (G_UNLIKELY(!(expr))) {                                        \
            glib_shim_return_fail(#expr, __FILE__, __LINE__, __func__);   \
        }                                                                 \
    }                                                                     \
    G_STMT_END

#define g_warn_if_reached()                                               \
    G_STMT_START                                                          \
    {                                                                     \
        glib_shim_return_fail("code should not be reached", __FILE__,     \
                              __LINE__, __func__);                        \
    }                                                                     \
    G_STMT_END

#ifdef __cplusplus
}
#endif

#endif /* __G_LIB_H__ */
