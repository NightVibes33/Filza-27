#ifndef sandbox_escape_h
#define sandbox_escape_h

#include <stdint.h>

int sandbox_access_is_active(void);
int sandbox_escape(uint64_t self_proc);
int sandbox_elevate_to_root(uint64_t self_proc);

#endif
