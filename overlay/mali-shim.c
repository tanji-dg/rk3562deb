/*
 * Shim for glibc symbols missing in musl libc.
 * The Mali proprietary blob (libMali.so) is compiled against glibc and
 * references these symbols.  Provide stub/wrapper implementations so the
 * blob can run on Alpine/musl.
 */

#include <stdlib.h>
#include <string.h>
#include <pthread.h>

/* ---------- __register_atfork ---------- */
/* glibc internal used by C++ runtime / libMali.  Wrap to pthread_atfork. */
int __register_atfork(void (*prepare)(void),
                      void (*parent)(void),
                      void (*child)(void),
                      void *dso_handle)
{
    (void)dso_handle;
    return pthread_atfork(prepare, parent, child);
}

/* ---------- mallinfo ---------- */
struct mallinfo {
    int arena;
    int ordblks;
    int smblks;
    int hblks;
    int hblkhd;
    int usmblks;
    int fsmblks;
    int uordblks;
    int fordblks;
    int keepcost;
};

struct mallinfo mallinfo(void)
{
    struct mallinfo mi;
    memset(&mi, 0, sizeof(mi));
    return mi;
}

/* ---------- strtol_l / strtoul_l ---------- */
/* Locale-aware variants; musl doesn't have them.  Ignore the locale arg. */
long strtol_l(const char *nptr, char **endptr, int base, void *locale)
{
    (void)locale;
    return strtol(nptr, endptr, base);
}

unsigned long strtoul_l(const char *nptr, char **endptr, int base, void *locale)
{
    (void)locale;
    return strtoul(nptr, endptr, base);
}
