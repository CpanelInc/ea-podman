// P0-12 test-only BPF-LSM program (PLAN.md F11): deny user-namespace creation to non-root
// tasks unless they run under eapodman.slice. ALLOWED_CG (the eapodman.slice cgroup id, its
// inode number) and MIN_UID are set with -D at build time. Not for production use.
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

char LICENSE[] SEC("license") = "GPL";

#ifndef ALLOWED_CG
#error "build with -DALLOWED_CG=<eapodman.slice cgroup id>"
#endif
#ifndef MIN_UID
#define MIN_UID 1000
#endif

__u64 allowed = 0;
__u64 denied = 0;

SEC("lsm/userns_create")
int BPF_PROG(eapodman_userns_guard, const struct cred *cred, int ret)
{
    if (ret)
        return ret;
    __u32 uid = (__u32)bpf_get_current_uid_gid();
    if (uid < MIN_UID)
        return 0;
    // Level 1 is the top-level cgroup the task is under (eapodman.slice, user.slice, ...).
    if (bpf_get_current_ancestor_cgroup_id(1) == (__u64)ALLOWED_CG) {
        __sync_fetch_and_add(&allowed, 1);
        return 0;
    }
    __sync_fetch_and_add(&denied, 1);
    return -1;    /* -EPERM */
}
