// SPDX-FileCopyrightText: 2026 The NextDOS Authors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Implementation of the minimal glib-2.0 compatibility layer declared in
// glib.h. See that header for the rationale and the exact symbol surface.
//
// Logging goes through the OHOS hilog NDK (domain 0x0000, tag "NextDOS",
// the repo-wide native logging convention). Messages are formatted here and
// forwarded as a single %{public}s argument so upstream glib format strings
// (which carry no hilog privacy annotations) still print verbatim.

#include "glib.h"

#include <time.h>

#include <hilog/log.h>

#define SLIRP_SHIM_LOG_TAG "NextDOS"
#define SLIRP_SHIM_LOG_DOMAIN 0x0000

/* ------------------------------------------------------------------ */
/* Logging helpers                                                     */
/* ------------------------------------------------------------------ */

static void glib_shim_vlog(LogLevel level, const char* format, va_list args)
{
    /* hilog caps a single record; keep the buffer modest and bounded. */
    char buf[1024];
    vsnprintf(buf, sizeof(buf), format, args);
    OH_LOG_Print(LOG_APP, level, SLIRP_SHIM_LOG_DOMAIN, SLIRP_SHIM_LOG_TAG,
                 "%{public}s", buf);
}

/* printf-style front end for the shim's own messages (the variadic glib
 * entry points above forward a va_list instead). */
static void glib_shim_log(LogLevel level, const char* format, ...)
        __attribute__((__format__(__printf__, 2, 3)));

static void glib_shim_log(LogLevel level, const char* format, ...)
{
    va_list args;
    va_start(args, format);
    glib_shim_vlog(level, format, args);
    va_end(args);
}

void g_warning(const gchar* format, ...)
{
    va_list args;
    va_start(args, format);
    glib_shim_vlog(LOG_WARN, format, args);
    va_end(args);
}

void g_critical(const gchar* format, ...)
{
    va_list args;
    va_start(args, format);
    glib_shim_vlog(LOG_ERROR, format, args);
    va_end(args);
}

void g_debug(const gchar* format, ...)
{
    va_list args;
    va_start(args, format);
    glib_shim_vlog(LOG_DEBUG, format, args);
    va_end(args);
}

void g_error(const gchar* format, ...)
{
    va_list args;
    va_start(args, format);
    glib_shim_vlog(LOG_ERROR, format, args);
    va_end(args);
    /* Faithful to glib: g_error() is fatal. libslirp only reaches it on
     * unrecoverable socket-setup failures. */
    abort();
}

void glib_shim_assert_fail(const char* expr, const char* file, int line,
                           const char* func)
{
    OH_LOG_Print(LOG_APP, LOG_FATAL, SLIRP_SHIM_LOG_DOMAIN, SLIRP_SHIM_LOG_TAG,
                 "%{public}s", "libslirp assertion failed");
    glib_shim_log(LOG_FATAL, "%s:%d (%s): assertion \"%s\" failed", file,
                  line, func, expr);
    abort();
}

void glib_shim_return_fail(const char* expr, const char* file, int line,
                           const char* func)
{
    glib_shim_log(LOG_WARN, "%s:%d (%s): condition \"%s\" not met", file, line,
                  func, expr);
}

/* ------------------------------------------------------------------ */
/* Memory                                                              */
/* ------------------------------------------------------------------ */

gpointer g_malloc(gsize n_bytes)
{
    /* glib aborts on OOM rather than returning NULL; callers rely on that. */
    gpointer mem = malloc(n_bytes ? n_bytes : 1);
    if (G_UNLIKELY(mem == NULL)) {
        glib_shim_log(LOG_FATAL, "g_malloc(%lu) failed",
                      (unsigned long)n_bytes);
        abort();
    }
    return mem;
}

gpointer g_malloc0(gsize n_bytes)
{
    gpointer mem = calloc(1, n_bytes ? n_bytes : 1);
    if (G_UNLIKELY(mem == NULL)) {
        glib_shim_log(LOG_FATAL, "g_malloc0(%lu) failed",
                      (unsigned long)n_bytes);
        abort();
    }
    return mem;
}

gpointer g_realloc(gpointer mem, gsize n_bytes)
{
    gpointer out = realloc(mem, n_bytes ? n_bytes : 1);
    if (G_UNLIKELY(out == NULL)) {
        glib_shim_log(LOG_FATAL, "g_realloc(%lu) failed",
                      (unsigned long)n_bytes);
        abort();
    }
    return out;
}

void g_free(gpointer mem)
{
    free(mem);
}

/* ------------------------------------------------------------------ */
/* Strings                                                             */
/* ------------------------------------------------------------------ */

gchar* g_strdup(const gchar* str)
{
    if (str == NULL) {
        return NULL;
    }
    const gsize len = strlen(str) + 1;
    return (gchar*)memcpy(g_malloc(len), str, len);
}

gsize g_strlcpy(gchar* dest, const gchar* src, gsize dest_size)
{
    const gsize src_len = (src != NULL) ? strlen(src) : 0;
    if (dest_size > 0) {
        const gsize copy = (src_len < dest_size - 1) ? src_len : dest_size - 1;
        if (src != NULL && copy > 0) {
            memcpy(dest, src, copy);
        }
        dest[copy] = '\0';
    }
    return src_len;
}

gchar* g_strstr_len(const gchar* haystack, gssize haystack_len,
                    const gchar* needle)
{
    if (haystack == NULL || needle == NULL) {
        return NULL;
    }
    if (haystack_len < 0) {
        return (gchar*)strstr(haystack, needle);
    }
    const gsize needle_len = strlen(needle);
    if (needle_len == 0) {
        return (gchar*)haystack;
    }
    const gsize hlen = (gsize)haystack_len;
    if (hlen < needle_len) {
        return NULL;
    }
    for (gsize i = 0; i + needle_len <= hlen; ++i) {
        if (haystack[i] == needle[0] &&
            memcmp(haystack + i, needle, needle_len) == 0) {
            return (gchar*)(haystack + i);
        }
    }
    return NULL;
}

gboolean g_str_has_prefix(const gchar* str, const gchar* prefix)
{
    if (str == NULL || prefix == NULL) {
        return FALSE;
    }
    return strncmp(str, prefix, strlen(prefix)) == 0;
}

gint g_ascii_strcasecmp(const gchar* s1, const gchar* s2)
{
    return strcasecmp(s1, s2);
}

gint g_vsnprintf(gchar* string, gulong n, const gchar* format, va_list args)
{
    return vsnprintf(string, (size_t)n, format, args);
}

gint g_snprintf(gchar* string, gulong n, const gchar* format, ...)
{
    va_list args;
    va_start(args, format);
    const gint result = vsnprintf(string, (size_t)n, format, args);
    va_end(args);
    return result;
}

void g_strfreev(gchar** str_array)
{
    if (str_array == NULL) {
        return;
    }
    for (gchar** it = str_array; *it != NULL; ++it) {
        g_free(*it);
    }
    g_free(str_array);
}

guint g_strv_length(gchar** str_array)
{
    guint len = 0;
    if (str_array != NULL) {
        while (str_array[len] != NULL) {
            ++len;
        }
    }
    return len;
}

gchar* g_strerror(gint errnum)
{
    /* glib returns a freshly allocated string; callers free it. */
    return g_strdup(strerror(errnum));
}

const gchar* g_getenv(const gchar* variable)
{
    return getenv(variable);
}

/* ------------------------------------------------------------------ */
/* GString                                                             */
/* ------------------------------------------------------------------ */

GString* g_string_new(const gchar* init)
{
    GString* string = (GString*)g_malloc0(sizeof(GString));
    const gsize init_len = (init != NULL) ? strlen(init) : 0;
    string->allocated_len = init_len + 1;
    string->str = (gchar*)g_malloc(string->allocated_len);
    if (init_len > 0) {
        memcpy(string->str, init, init_len);
    }
    string->str[init_len] = '\0';
    string->len = init_len;
    return string;
}

gchar* g_string_free(GString* string, gboolean free_segment)
{
    if (string == NULL) {
        return NULL;
    }
    gchar* segment = NULL;
    if (free_segment) {
        g_free(string->str);
    } else {
        segment = string->str;
    }
    g_free(string);
    return segment;
}

GString* g_string_append_printf(GString* string, const gchar* format, ...)
{
    if (string == NULL || format == NULL) {
        return string;
    }
    va_list args;
    va_start(args, format);
    va_list args_copy;
    va_copy(args_copy, args);
    /* Two-pass: measure, grow once, then format into the tail. */
    const int needed = vsnprintf(NULL, 0, format, args);
    va_end(args);
    if (needed < 0) {
        va_end(args_copy);
        return string;
    }
    const gsize needed_len = (gsize)needed;
    const gsize required = string->len + needed_len + 1;
    if (required > string->allocated_len) {
        gsize new_size = string->allocated_len * 2;
        if (new_size < required) {
            new_size = required;
        }
        string->str = (gchar*)g_realloc(string->str, new_size);
        string->allocated_len = new_size;
    }
    vsnprintf(string->str + string->len, string->allocated_len - string->len,
              format, args_copy);
    va_end(args_copy);
    string->len += needed_len;
    return string;
}

/* ------------------------------------------------------------------ */
/* GRand (xorshift64*; adequate for ephemeral ports and DHCP jitter)   */
/* ------------------------------------------------------------------ */

struct _GRand {
    guint64 state;
};

GRand* g_rand_new(void)
{
    GRand* rand = (GRand*)g_malloc0(sizeof(GRand));
    struct timespec ts = {0, 0};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    /* Never seed to zero - xorshift degenerates to a constant. */
    rand->state = ((guint64)ts.tv_sec << 32) ^ (guint64)ts.tv_nsec ^
                  0x9E3779B97F4A7C15ull;
    if (rand->state == 0) {
        rand->state = 0x2545F4914F6CDD1Dull;
    }
    return rand;
}

void g_rand_free(GRand* rand)
{
    g_free(rand);
}

static guint64 g_rand_next(GRand* rand)
{
    guint64 x = rand->state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    rand->state = x;
    return x * 0x2545F4914F6CDD1Dull;
}

gint32 g_rand_int_range(GRand* rand, gint32 begin, gint32 end)
{
    if (rand == NULL) {
        return begin;
    }
    /* glib's contract is [begin, end); guard against empty/inverted ranges. */
    if (end <= begin) {
        return begin;
    }
    const guint64 range = (guint64)((gint64)end - (gint64)begin);
    return (gint32)((gint64)begin + (gint64)(g_rand_next(rand) % range));
}

/* ------------------------------------------------------------------ */
/* GError                                                              */
/* ------------------------------------------------------------------ */

void g_error_free(GError* error)
{
    if (error == NULL) {
        return;
    }
    g_free(error->message);
    g_free(error);
}

/* ------------------------------------------------------------------ */
/* Process spawning - deliberately unsupported                         */
/*                                                                     */
/* libslirp only needs these for its `exec`/`fork_exec` socket         */
/* feature, which the DOSBox Staging slirp backend never drives. The   */
/* shim logs and reports failure instead of forking a child process,   */
/* so a hypothetical caller degrades cleanly rather than misbehaving.  */
/* ------------------------------------------------------------------ */

gboolean g_spawn_async(const gchar* working_directory, gchar** argv,
                       gchar** envp, GSpawnFlags flags,
                       GSpawnChildSetupFunc child_setup, gpointer user_data,
                       GPid* child_pid, GError** error)
{
    (void)working_directory;
    (void)argv;
    (void)envp;
    (void)flags;
    (void)child_setup;
    (void)user_data;
    (void)child_pid;
    (void)error;
    g_warning("g_spawn_async: unsupported in the NextDOS glib shim");
    return FALSE;
}

gboolean g_spawn_async_with_fds(const gchar* working_directory, gchar** argv,
                                gchar** envp, GSpawnFlags flags,
                                GSpawnChildSetupFunc child_setup,
                                gpointer user_data, GPid* child_pid,
                                gint stdin_fd, gint stdout_fd, gint stderr_fd,
                                GError** error)
{
    (void)working_directory;
    (void)argv;
    (void)envp;
    (void)flags;
    (void)child_setup;
    (void)user_data;
    (void)child_pid;
    (void)stdin_fd;
    (void)stdout_fd;
    (void)stderr_fd;
    (void)error;
    g_warning("g_spawn_async_with_fds: unsupported in the NextDOS glib shim");
    return FALSE;
}

gboolean g_shell_parse_argv(const gchar* command_line, gint* argcp,
                            gchar*** argvp, GError** error)
{
    (void)command_line;
    (void)argcp;
    (void)argvp;
    (void)error;
    g_warning("g_shell_parse_argv: unsupported in the NextDOS glib shim");
    return FALSE;
}

/* ------------------------------------------------------------------ */
/* Debug keys                                                          */
/* ------------------------------------------------------------------ */

guint g_parse_debug_string(const gchar* string, const GDebugKey* keys,
                           guint nkeys)
{
    if (string == NULL) {
        return 0;
    }
    /* glib matches whole key names separated by ':'; "all" selects every
     * key. Kept compatible enough for libslirp's SLIRP_DEBUG parsing. */
    guint result = 0;
    const gchar* p = string;
    while (*p != '\0') {
        const gchar* end = strpbrk(p, ":;, ");
        const gsize token_len = (end != NULL) ? (gsize)(end - p) : strlen(p);
        for (guint i = 0; i < nkeys; ++i) {
            const gchar* name = keys[i].name;
            if (strcmp(name, "all") == 0 ||
                (token_len == strlen(name) && strncmp(p, name, token_len) == 0)) {
                result |= keys[i].bit;
            }
        }
        if (end == NULL) {
            break;
        }
        p = end + 1;
    }
    return result;
}
