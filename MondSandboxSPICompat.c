#include <dlfcn.h>
#include <stdint.h>
#include <stddef.h>

/*
 * Mechanical host ABI glue for Mond's existing Sandbox SPI usage.
 *
 * Upstream Mond resolves these symbols from libsystem_sandbox.dylib at runtime.
 * When the same Swift source is compiled into Filza's Theos dylib, Swift emits
 * link references for the C names. Export the exact ABI locally and forward to
 * the same system dylib/symbols upstream Mond already uses.
 */

static void *mond_sandbox_handle(void)
{
    static void *handle;
    if (!handle) {
        handle = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW | RTLD_LOCAL);
    }
    return handle;
}

int64_t sandbox_extension_consume(const char *token)
{
    typedef int64_t (*consume_fn)(const char *);
    void *handle = mond_sandbox_handle();
    if (!handle) return -1;

    consume_fn fn = (consume_fn)dlsym(handle, "sandbox_extension_consume");
    if (!fn) return -1;
    return fn(token);
}

char *sandbox_extension_issue_file(const char *extension_class,
                                   const char *path,
                                   int32_t flags,
                                   int32_t reserved)
{
    typedef char *(*issue_fn)(const char *, const char *, int32_t, int32_t);
    void *handle = mond_sandbox_handle();
    if (!handle) return NULL;

    issue_fn fn = (issue_fn)dlsym(handle, "sandbox_extension_issue_file");
    if (!fn) return NULL;
    return fn(extension_class, path, flags, reserved);
}
