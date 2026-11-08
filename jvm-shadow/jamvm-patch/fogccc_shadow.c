/*
 * FOGCCC shadow export for JamVM (P4a, 4K scale).
 *
 * Enabled at runtime with FOGCCC_SHADOW=1.  During the first full STW
 * collection the mark phase reports:
 *   - every root object            (fogccc_shadow_root)
 *   - every hard edge from->to     (fogccc_shadow_edge, called from
 *                                   MARK_AND_PUSH with mark == HARD_MARK)
 *
 * Objects get dense ids in first-seen order, which is enough to build a
 * side table in the FPGA graph window: 16 B header per object plus a
 * uint32_t ref array terminated by 0xFFFFFFFF.
 *
 * After JamVM's own mark phase the hardware mark is run from the same
 * roots and the bitmaps are compared:
 *   hw & !sw  -> must be 0 (hardware only follows real edges)
 *   sw & !hw  -> objects the 256 root registers could not reach
 */
#define _GNU_SOURCE     /* Dl_info / dladdr */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <pthread.h>   /* optional two-thread export/import (FOGCCC_SMP=1) */
#include <sys/mman.h>  /* madvise(MADV_HUGEPAGE) for the id map */
#include <signal.h>
#include <ucontext.h>
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>

#include "jam.h"
#include "fogccc_shadow.h"
#include "fpga_gc.h"

#define MAX_OBJ     1048576
#define HASH_SIZE   2097152        /* power of two, > 2 * MAX_OBJ */
#define ROOT_REGS   256           /* REG_ROOT_LIST depth */
#define MAX_ROOTS   4096          /* roots are fed 256 at a time, bitmap kept */
#define MAX_EDGES   1572864

Object *fogccc_from = NULL;

static Object   *g_obj[MAX_OBJ];
static int       g_nobj;
static int32_t   g_htab[HASH_SIZE];         /* id + 1, 0 = empty */
static uint32_t  g_edge[MAX_EDGES][2];
static int       g_nedge;
static int       g_edge_ovf;
static uint32_t  g_roots[MAX_ROOTS];
static Object   *g_root_objs[MAX_ROOTS];   /* survives an id-table reset */
static int       g_root_ovf;
static volatile int g_root_lock;

/* Direct address -> id map for the heap walk.  gcMalloc(<=4) yields an 8-byte
   block (4-byte payload), so two objects can be 8 bytes apart: the map uses
   8-byte granularity, which is collision-free.  A single load replaces the
   open-addressing hash probe (~1.6 s of the 1 M rebuild walk).  Capped:
   addresses beyond the cap fall back to the hash. */
#define IDMAP_SHIFT      3u
#define IDMAP_MAX        (8u << 20)          /* 32 MiB of table, covers 64 MiB */
static uint32_t *g_idmap;
static uint32_t  g_idmap_cap;
static char     *g_idmap_lo;

/* Serialises new-id assignment between the two export workers (and protects
   the class-object list).  Lookups stay lock-free: an entry is published with
   the release store after g_obj is written. */
static volatile int g_id_lock;
static volatile int g_cls_lock;

/* ---- id reclamation ------------------------------------------------------
   The RTL id space is 20-bit (MAX_OBJ).  Between rebuilds ids of objects that
   a collection freed used to stay in the table, so an allocation-heavy
   program reached the ceiling and fell back to the CPU (lusearch/h2 at
   -Xms700m).  After doMark() every id in g_obj[] has a known liveness: ids
   that did not survive are pushed on a free list and handed out again.
   A rebuild still resets everything (ids are positions, not persistent keys). */
static uint32_t *g_free_ids;        /* reclaimed ids, used LIFO */
static int       g_nfree;
uint64_t fogccc_reclaim_us;         /* time spent in the last reclaim pass */
int      fogccc_reclaim_freed;      /* ids returned to the free list */

extern char *fogccc_heap_base(void);
extern uint32_t fogccc_heap_size(void);

/* Diagnostic: JamVM has no SIGSEGV/SIGBUS handler, so an "external abort"
   (SIGBUS) just kills the process with no PC.  Print the fault address, the
   PC and its offset inside libjvm (mapped with addr2line), then re-raise. */
static unsigned long g_lib_base;

/* Signal-safe formatting: no snprintf (its lock may be held by the crashing
   thread) and no raise() (JamVM may keep the signal blocked, which turned the
   handler into an endless re-entry loop). */
static char *fogccc_hex(char *p, unsigned long v) {
    static const char h[] = "0123456789abcdef";
    int i, started = 0;

    *p++ = '0';
    *p++ = 'x';
    for (i = 28; i >= 0; i -= 4) {
        int d = (int)((v >> i) & 0xFu);

        if (d != 0 || started || i == 0) {
            *p++ = h[d];
            started = 1;
        }
    }
    return p;
}

/* Print the /proc/self/maps line that contains pc (async-signal-safe). */
static void fogccc_dump_map(unsigned long pc) {
    char m[8192];
    int fd, n, i;

    fd = open("/proc/self/maps", O_RDONLY);
    if (fd < 0)
        return;
    n = (int)read(fd, m, sizeof(m) - 1);
    close(fd);
    if (n <= 0)
        return;
    m[n] = 0;
    for (i = 0; i < n; ) {
        int e = i;
        unsigned long a = 0, b = 0;
        int k = i;

        while (e < n && m[e] != '\n')
            e++;
        while (k < e && m[k] != '-') {
            a = a * 16 + (unsigned long)(m[k] < 'a' ? m[k] - '0'
                          : m[k] - 'a' + 10);
            k++;
        }
        if (k < e)
            k++;
        while (k < e && m[k] != ' ') {
            b = b * 16 + (unsigned long)(m[k] < 'a' ? m[k] - '0'
                          : m[k] - 'a' + 10);
            k++;
        }
        if (pc >= a && pc < b) {
            ssize_t w = write(2, "[FOGCCC] MAP ", 13);
            (void)w;
            w = write(2, m + i, (size_t)(e - i));
            (void)w;
            w = write(2, "\n", 1);
            (void)w;
            return;
        }
        i = e + 1;
    }
}

static void fogccc_fault_handler(int sig, siginfo_t *si, void *uc) {
    ucontext_t *u = (ucontext_t *)uc;
    unsigned long pc = 0, lr = 0, sp = 0;
    unsigned long addr = (unsigned long)(si != NULL ? si->si_addr : 0);
    char buf[160];
    char *p = buf;

#if defined(__arm__)
    if (u != NULL) {
        pc = (unsigned long)u->uc_mcontext.arm_pc;
        lr = (unsigned long)u->uc_mcontext.arm_lr;
        sp = (unsigned long)u->uc_mcontext.arm_sp;
    }
#endif
    {
        static const char pre[] = "[FOGCCC] FAULT sig=";

        memcpy(p, pre, sizeof(pre) - 1);
        p += sizeof(pre) - 1;
    }
    p = fogccc_hex(p, (unsigned long)sig);
    {
        static const char t1[] = " addr=";

        memcpy(p, t1, sizeof(t1) - 1);
        p += sizeof(t1) - 1;
    }
    p = fogccc_hex(p, addr);
    {
        static const char t2[] = " pc=";

        memcpy(p, t2, sizeof(t2) - 1);
        p += sizeof(t2) - 1;
    }
    p = fogccc_hex(p, pc);
    {
        static const char t3[] = " off=";

        memcpy(p, t3, sizeof(t3) - 1);
        p += sizeof(t3) - 1;
    }
    p = fogccc_hex(p, g_lib_base != 0 ? pc - g_lib_base : 0);
    {
        static const char t4[] = " lr=";

        memcpy(p, t4, sizeof(t4) - 1);
        p += sizeof(t4) - 1;
    }
    p = fogccc_hex(p, lr);
    {
        static const char t5[] = " sp=";

        memcpy(p, t5, sizeof(t5) - 1);
        p += sizeof(t5) - 1;
    }
    p = fogccc_hex(p, sp);
    *p++ = '\n';
    {
        ssize_t w = write(2, buf, (size_t)(p - buf));
        (void)w;
    }
    fogccc_dump_map(pc);
    _exit(128 + sig);
}

void fogccc_install_fault_handler(void) {
    struct sigaction sa;
    Dl_info di;

    /* Install on every collection: the OpenJDK class library registers its own
       SIGSEGV/SIGBUS handlers (JVM_RegisterSignal) after our constructor, and
       those replaced ours.  Re-installing here (the first GC happens after
       classlib init) wins it back. */
    if (g_lib_base == 0 &&
        dladdr((void *)fogccc_install_fault_handler, &di) != 0)
        g_lib_base = (unsigned long)di.dli_fbase;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = fogccc_fault_handler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
}

/* Install at library load: the crash we are chasing happens before the first
   collection, so a hook inside shadow_begin() was too late. */
__attribute__((constructor)) static void fogccc_lib_ctor(void) {
    fogccc_install_fault_handler();
    /* Unbuffered so a SIGQUIT thread dump (and a crash report) is visible even
       when the adapter itself is disabled. */
    setvbuf(stdout, NULL, _IONBF, 0);
    /* Reclaimed-id pool: calloc maps zero pages lazily, so this costs address
       space only until the first collection frees an id.  Created here rather
       than in gc0() because gc0() runs with every thread suspended and must
       not take the malloc lock. */
    if (getenv("FOGCCC_TAKEOVER") != NULL)
        g_free_ids = (uint32_t *)calloc((size_t)MAX_OBJ, sizeof(uint32_t));
    {
        ssize_t w = write(2, "[FOGCCC] fault hook installed\n", 30);
        (void)w;
    }
}

static void idmap_ensure(void) {
    uint32_t need = (uint32_t)((fogccc_heap_size() + (1u << IDMAP_SHIFT) - 1u)
                               >> IDMAP_SHIFT);

    if (need > IDMAP_MAX)
        need = IDMAP_MAX;
    if (need <= g_idmap_cap)
        return;
    free(g_idmap);
    g_idmap = (uint32_t *)calloc(need, sizeof(uint32_t));
    if (g_idmap != NULL) {
        /* calloc maps zero pages lazily; touching them here moves the page
           faults out of the measured walk (3.2 k faults at 1 M). */
        memset(g_idmap, 0, (size_t)need * sizeof(uint32_t));
#ifdef MADV_HUGEPAGE
        madvise(g_idmap, (size_t)need * sizeof(uint32_t), MADV_HUGEPAGE);
#endif
        g_idmap_cap = need;
    } else {
        g_idmap_cap = 0;
    }
    g_idmap_lo = fogccc_heap_base();
}

static void idmap_clear(void) {
    if (g_idmap != NULL && g_idmap_cap != 0)
        memset(g_idmap, 0, (size_t)g_idmap_cap * sizeof(uint32_t));
}

/* Class metadata (lazily resolved constant-pool entries and static fields
   written by JVM code) changes without a write barrier, so the dirty ring
   cannot see it.  resolveSingleConstant() / the PUTSTATIC opcodes flag it and
   the next collection rebuilds the side table instead of trusting the ring. */
static volatile int g_meta_dirty;

void fogccc_meta_dirty(void) { g_meta_dirty = 1; }
int  fogccc_meta_pending(void) { return g_meta_dirty; }
void fogccc_meta_clear(void) { g_meta_dirty = 0; }

/* Classes whose constant pool was resolved since the last collection.  Their
   metadata edges (a resolved string is a new edge from the class) must be
   re-exported, but a full arena rebuild is not needed: exporting those few
   classes is enough.  Overflow falls back to the rebuild flag. */
#define CP_CLASS_MAX 256
static Object *g_cp_classes[CP_CLASS_MAX];
static volatile int g_cp_n;

void fogccc_note_cp_class(Class *c) {
    int n;

    if (c == NULL)
        return;
    n = __sync_fetch_and_add((int *)&g_cp_n, 1);
    if (n >= CP_CLASS_MAX) {
        g_meta_dirty = 1;      /* too many: let the next round rebuild */
        return;
    }
    g_cp_classes[n] = (Object *)c;
}

#define MAX_NEW_CLASSES 16384
static Object   *g_new_classes[MAX_NEW_CLASSES];
static int       g_nnew_classes;

/* Called from allocClass(): remember every Class object so the takeover export
   can pick up classes loaded since the last round without walking the heap.
   Class fields are written by JVM code (no write barrier), and a new class has
   no id yet, so no other export path sees it. */
void fogccc_note_new_class(Object *c) {
    if (g_nnew_classes < MAX_NEW_CLASSES)
        g_new_classes[g_nnew_classes++] = c;
}
static int       g_nroots;
static int       g_nroots_seen;
static int       g_state;                   /* 0 unset, 1 on, -1 off */
static int       g_done;

/* The mark loop emits all edges of one object back to back, so caching the
   last source saves one hash probe per edge. */
static Object   *g_from_cache;
static int       g_from_cached_id;

/* phase timing: collect(mark hooks) / write / init / mark / compare */
static uint64_t  t_first, t_run, t_write, t_init, t_mark, t_mkdone, t_cmp;

static uint64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)ts.tv_nsec / 1000ull;
}

static int shadow_on(void) {
    const char *e = getenv("FOGCCC_SHADOW");
    return e != NULL && e[0] != '\0' && e[0] != '0';
}

static uint32_t hash_ptr(const void *p) {
    return (uint32_t)((((uintptr_t)p) >> 3) * 2654435761u) & (HASH_SIZE - 1);
}

/* g_htab values: 0 = empty, > 0 = id + 1, -1 = tombstone (a reclaimed id).
   The tombstone keeps the probe sequence of the keys behind it intact; a
   deleted slot must not look like the end of the sequence.  Probes are
   bounded so a full table degrades to "no id" instead of hanging the GC. */
static int htab_find(Object *ob) {
    uint32_t h = hash_ptr(ob);
    uint32_t n = 0;

    while (g_htab[h] != 0 && n++ < (uint32_t)HASH_SIZE) {
        int32_t v = g_htab[h];

        if (v > 0 && g_obj[v - 1] == ob)
            return (int)(v - 1);
        h = (h + 1) & (HASH_SIZE - 1);
    }
    return -1;
}

static void htab_put(Object *ob, int id) {
    uint32_t h = hash_ptr(ob);
    uint32_t tomb = 0xFFFFFFFFu, n = 0;

    while (g_htab[h] != 0 && n++ < (uint32_t)HASH_SIZE) {
        if (g_htab[h] < 0) {
            if (tomb == 0xFFFFFFFFu)
                tomb = h;
        } else if (g_obj[g_htab[h] - 1] == ob) {
            return;                     /* already present */
        }
        h = (h + 1) & (HASH_SIZE - 1);
    }
    if (tomb != 0xFFFFFFFFu)
        h = tomb;
    else if (g_htab[h] != 0)
        return;                         /* table full: keep the old mapping */
    g_htab[h] = id + 1;
}

static void htab_del(Object *ob) {
    uint32_t h = hash_ptr(ob);
    uint32_t n = 0;

    while (g_htab[h] != 0 && n++ < (uint32_t)HASH_SIZE) {
        if (g_htab[h] > 0 && g_obj[g_htab[h] - 1] == ob) {
            g_htab[h] = -1;
            return;
        }
        h = (h + 1) & (HASH_SIZE - 1);
    }
}

/* One id.  Reclaimed ids are handed out first (LIFO keeps the most recently
   freed objects hot); otherwise the dense range extends.  Caller holds
   g_id_lock. */
static int id_alloc(void) {
    if (g_nfree > 0)
        return (int)g_free_ids[--g_nfree];
    if (g_nobj < MAX_OBJ)
        return g_nobj++;
    return -1;
}

static int id_of(Object *ob, int create) {
    if (g_idmap != NULL) {
        uintptr_t off = (uintptr_t)ob - (uintptr_t)g_idmap_lo;

        if (off >> IDMAP_SHIFT < g_idmap_cap) {
            uint32_t slot = (uint32_t)(off >> IDMAP_SHIFT);
            uint32_t v = g_idmap[slot];

            /* Objects are at least 16 B apart, so a slot never holds two
               different objects; a phantom/interior pointer that lands here
               maps to the containing object's id, which is exactly what the
               ring export would do anyway.  No g_obj confirmation load: that
               second random access cost ~0.4 s on a 1 M walk. */
            if (v != 0)
                return (int)(v - 1);
            if (!create)
                return -1;
            while (__sync_lock_test_and_set(&g_id_lock, 1))
                ;
            v = g_idmap[slot];
            if (v == 0) {
                int nid = id_alloc();

                if (nid >= 0) {
                    g_obj[nid] = ob;
                    g_idmap[slot] = (uint32_t)nid + 1;
                    v = (uint32_t)nid + 1;
                }
            }
            __sync_lock_release(&g_id_lock);
            return v != 0 ? (int)(v - 1) : -1;
        }
    }

    if (!create)
        return htab_find(ob);
    {
        int id;

        while (__sync_lock_test_and_set(&g_id_lock, 1))
            ;
        id = htab_find(ob);
        if (id < 0) {
            id = id_alloc();
            if (id >= 0) {
                g_obj[id] = ob;
                htab_put(ob, id);
            }
        }
        __sync_lock_release(&g_id_lock);
        return id;
    }
}

/* ---- address-based live set of the last collection -----------------------
   The rebuild walk used to export every allocated block, so a heap holding
   one collection's worth of garbage (lusearch: ~1 M blocks, 64 k live) hit the
   20-bit id ceiling before the mark even started.  Reclaiming ids is not
   enough there: the export happens *before* the mark.  So reclaim also
   records where the surviving objects are, and the next rebuild exports only
   blocks that were live last round or have been allocated/written since
   (the dirty bitmap; every allocation sets it).  A rebuild with no previous
   collection (g_waslive == NULL) still exports everything. */
#define WASLIVE_SHIFT 3
static uint32_t *g_waslive;
static uint32_t  g_waslive_words;
static char     *g_waslive_lo;
static int       g_waslive_skip;  /* live set is most of the heap: filter useless */

static void waslive_reset(void) {
    uint32_t need = (fogccc_heap_size() >> WASLIVE_SHIFT) / 32u + 2u;

    if (need > g_waslive_words) {
        if (g_waslive != NULL)
            munmap(g_waslive, (size_t)g_waslive_words * 4u);
        g_waslive = (uint32_t *)mmap(NULL, (size_t)need * 4u,
                                     PROT_READ | PROT_WRITE,
                                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (g_waslive == MAP_FAILED) {
            g_waslive = NULL;
            g_waslive_words = 0;
            return;
        }
        g_waslive_words = need;
    } else if (g_waslive != NULL) {
        memset(g_waslive, 0, (size_t)g_waslive_words * 4u);
    }
    g_waslive_skip = 0;
    g_waslive_lo = fogccc_heap_base();
}

static void fogccc_waslive_mark(Object *ob) {
    uintptr_t off = (uintptr_t)ob - (uintptr_t)g_waslive_lo;
    uint32_t slot = (uint32_t)(off >> WASLIVE_SHIFT);

    if (g_waslive != NULL && (slot >> 5) < g_waslive_words)
        g_waslive[slot >> 5] |= 1u << (slot & 31);
}

/* 1 = keep this block in the rebuild export (unknown also keeps it). */
static int fogccc_waslive_keep(Object *ob) {
    uintptr_t off = (uintptr_t)ob - (uintptr_t)g_waslive_lo;
    uint32_t slot = (uint32_t)(off >> WASLIVE_SHIFT);

    if (g_waslive == NULL || g_waslive_skip)
        return 1;
    if ((slot >> 5) >= g_waslive_words)
        return 1;
    return (int)((g_waslive[slot >> 5] >> (slot & 31)) & 1u);
}

static int fogccc_waslive_valid(void) { return g_waslive != NULL; }

/* The recorded addresses are only meaningful while the heap stays put.  A
   fixed heap (-Xms == -Xmx) is required; if it did move, drop the bitmap so
   the rebuild exports everything instead of skipping live blocks. */
static void fogccc_waslive_rebase(void) {
    if (g_waslive != NULL && g_waslive_lo != fogccc_heap_base()) {
        munmap(g_waslive, (size_t)g_waslive_words * 4u);
        g_waslive = NULL;
        g_waslive_words = 0;
    }
}

/* Release one id.  Runs at a safepoint (all threads suspended), so the tables
   are updated without the id lock. */
static void id_free(int id) {
    Object *ob = g_obj[id];

    if (ob == NULL)
        return;
    if (g_idmap != NULL) {
        uintptr_t off = (uintptr_t)ob - (uintptr_t)g_idmap_lo;

        if ((off >> IDMAP_SHIFT) < g_idmap_cap) {
            uint32_t slot = (uint32_t)(off >> IDMAP_SHIFT);

            if (g_idmap[slot] == (uint32_t)id + 1)
                g_idmap[slot] = 0;
            else
                htab_del(ob);       /* the address is hashed, not mapped */
        } else {
            htab_del(ob);
        }
    } else {
        htab_del(ob);
    }
    g_obj[id] = NULL;
    if (g_free_ids != NULL && g_nfree < MAX_OBJ)
        g_free_ids[g_nfree++] = (uint32_t)id;
}

/* Reclaim the ids of objects the collection did not mark.  gc0() calls this
   after doMark() -- finalizer and cleared-weak-reference marks included -- and
   before doSweep(), so g_obj[] still names valid blocks and the mark bits are
   the final liveness oracle.  Only the takeover side table needs a bounded id
   space; shadow mode keeps its ids for the graph diagnostics. */
extern uint32_t *fogccc_last_live_bm(void);
extern int       fogccc_last_live_n(void);
extern int       fogccc_last_live_ok(void);

int fogccc_id_reclaim(void) {
    const char *e = getenv("FOGCCC_TAKEOVER");
    const uint32_t *bm = NULL;
    int i, freed = 0;

    if (e == NULL || e[0] == '\0' || e[0] == '0')
        return 0;
    if (g_free_ids == NULL)
        return 0;
    /* Fast path: the bitmap imported this round.  One sequential word scan
       instead of a call per object (1 M calls measured ~95 ms of the pause). */
    if (fogccc_last_live_ok() && fogccc_last_live_n() == g_nobj)
        bm = fogccc_last_live_bm();
    /* When almost everything survives, the rebuild filter cannot skip much
       and the address bitmap costs one random write per object (~50 ms at
       1 M).  Skip it: the next rebuild exports everything, which is what it
       would do anyway when the live set fills the heap. */
    g_waslive_skip = 0;
    if (bm != NULL) {
        uint32_t nw = (uint32_t)((g_nobj + 31) / 32);
        uint32_t pc = 0;

        for (i = 0; i < (int)nw; i++)
            pc += (uint32_t)__builtin_popcount(bm[i]);
        if (pc > (uint32_t)g_nobj / 2)
            g_waslive_skip = 1;
    }
    /* Record the surviving addresses: the next rebuild uses them to skip the
       garbage this sweep is about to free. */
    if (!g_waslive_skip)
        waslive_reset();
    for (i = 0; i < g_nobj; i++) {
        Object *ob = g_obj[i];
        int live;

        if (ob == NULL)
            continue;
        live = (bm != NULL) ? (int)((bm[i >> 5] >> (i & 31)) & 1u)
                            : (fogccc_get_mark(ob) != 0);
        if (live) {
            if (!g_waslive_skip)
                fogccc_waslive_mark(ob);
            continue;
        }
        id_free(i);
        freed++;
    }
    fogccc_reclaim_freed = freed;
    return freed;
}

int fogccc_id_high(void) { return g_nobj; }
int fogccc_id_free_count(void) { return g_nfree; }
int fogccc_id_live(void) { return g_nobj - g_nfree; }

/* STW accounting: gc0() records the clock right after suspending and reports
   the whole pause here, once the world runs again (printing while suspended
   can deadlock on the stdio lock). */
uint64_t fogccc_gc_stw_t0;

void fogccc_report_stw(void) {
    const char *e = getenv("FOGCCC_STW");

    if (e == NULL || e[0] == '\0' || e[0] == '0')
        return;
    printf("[FOGCCC] stw: %llu us (ids_live=%d ids_high=%d ids_free=%d "
           "reclaim=%d reclaim_us=%llu)\n",
           (unsigned long long)(now_us() - fogccc_gc_stw_t0),
           fogccc_id_live(), g_nobj, g_nfree,
           fogccc_reclaim_freed,
           (unsigned long long)fogccc_reclaim_us);
}

static int state(void) {
    if (g_state == 0) {
        g_state = shadow_on() ? 1 : -1;
        if (g_state > 0) {
            t_first = now_us();
            /* A crash must not swallow the diagnostics: the JVM's stdout is
               block-buffered when redirected, and a segfault loses every line
               written since the last flush. */
            setvbuf(stdout, NULL, _IONBF, 0);
        }
    }
    return g_state;
}

int fogccc_shadow_enabled(void) {
    return state() > 0;
}

void fogccc_shadow_register(Object *ob) {
    if (state() < 0 || ob == NULL || g_done)
        return;
    (void)id_of(ob, 1);
}

void fogccc_shadow_root(Object *ob) {
    int id, i;

    if (state() < 0 || ob == NULL || g_done)
        return;

    id = id_of(ob, 1);
    if (id < 0)
        return;

    g_nroots_seen++;
    /* The two export workers call this for loader-table classes; the list
       needs a lock (an unlocked g_nroots++ lost entries and could corrupt the
       array). */
    while (__sync_lock_test_and_set(&g_root_lock, 1))
        ;
    for (i = 0; i < g_nroots; i++)
        if ((int)g_roots[i] == id) {
            __sync_lock_release(&g_root_lock);
            return;
        }

    if (g_nroots < MAX_ROOTS) {
        g_root_objs[g_nroots] = ob;
        g_roots[g_nroots++] = (uint32_t)id;
    } else if (!g_root_ovf) {
        g_root_ovf = 1;
        printf("[FOGCCC] root list full (%d): further roots dropped\n",
               MAX_ROOTS);
    }
    __sync_lock_release(&g_root_lock);
}

void fogccc_shadow_edge(Object *from, Object *to, int hard) {
    int f, t;

    if (state() < 0 || g_done || !hard || to == NULL)
        return;

    t = id_of(to, 1);
    if (t < 0) {
        g_edge_ovf++;
        return;
    }
    if (from == NULL)
        return;

    if (from == g_from_cache) {
        f = g_from_cached_id;
    } else {
        f = id_of(from, 1);
        if (f < 0)
            return;
        g_from_cache = from;
        g_from_cached_id = f;
    }

    if (g_nedge == MAX_EDGES) {
        g_edge_ovf++;
        return;
    }
    g_edge[g_nedge][0] = (uint32_t)f;
    g_edge[g_nedge][1] = (uint32_t)t;
    g_nedge++;
}

void fogccc_shadow_run(int (*is_hard_marked)(Object *)) {
    fpga_gc_t dev;
    uint32_t *cnt, *start, *cur, ref_base, off;
    uint8_t *base;
    uint32_t hw, cycles = 0;
    int i, base_pass, sw = 0, miss = 0, false_pos = 0;

    if (state() <= 0 || g_done)
        return;
    g_done = 1;
    t_run = now_us();

    printf("[FOGCCC] export objects=%d edges=%d roots_seen=%d roots_kept=%d edge_ovf=%d\n",
           g_nobj, g_nedge, g_nroots_seen, g_nroots, g_edge_ovf);
    if (g_nobj == 0)
        return;

    cnt = calloc((size_t)g_nobj, sizeof(uint32_t));
    start = calloc((size_t)g_nobj, sizeof(uint32_t));
    cur = calloc((size_t)g_nobj, sizeof(uint32_t));
    if (cnt == NULL || start == NULL || cur == NULL) {
        printf("[FOGCCC] export: out of memory\n");
        free(cnt); free(start); free(cur);
        return;
    }

    for (i = 0; i < g_nedge; i++)
        cnt[g_edge[i][0]]++;

    /* object headers first, then 4 KiB-aligned reference arrays */
    ref_base = (((uint32_t)g_nobj * 16u) + 0xFFFu) & ~0xFFFu;
    off = ref_base;
    for (i = 0; i < g_nobj; i++) {
        start[i] = off;
        off += cnt[i] * 4u + 4u;
    }
    if (off > (uint32_t)GRAPH_MAP_SIZE) {
        printf("[FOGCCC] export: graph too large (%u > %d), skipped\n",
               off, GRAPH_MAP_SIZE);
        free(cnt); free(start); free(cur);
        return;
    }

    t_init = now_us();
    if (fpga_gc_init(&dev) != 0) {
        printf("[FOGCCC] export: fpga_gc_init failed\n");
        free(cnt); free(start); free(cur);
        return;
    }

    /* No full-window clear: every header word and every reference terminator is
       written below, and the engine only reads [0, obj_count). */
    base = (uint8_t *)dev.graph_vaddr;

    for (i = 0; i < g_nobj; i++) {
        uint32_t *hdr = (uint32_t *)(base + (uint32_t)i * 16u);
        hdr[0] = (uint32_t)i;
        hdr[1] = cnt[i];
        hdr[2] = dev.graph_paddr + start[i];
        hdr[3] = 0u;
        *(uint32_t *)(base + start[i] + cnt[i] * 4u) = 0xFFFFFFFFu;
        cur[i] = start[i];
    }

    for (i = 0; i < g_nedge; i++) {
        uint32_t f = g_edge[i][0];
        *(uint32_t *)(base + cur[f]) = g_edge[i][1];
        cur[f] += 4u;
    }

    t_write = now_us();

    /* Optional dump of exactly what was written into the window, so a host
       tool can replay the same graph and separate "graph content" from
       "export path" effects. */
    {
        const char *dump = getenv("FOGCCC_DUMP");

        if (dump != NULL && dump[0] != '\0') {
            FILE *f = fopen(dump, "wb");

            if (f != NULL) {
                uint32_t hdr4[4];
                hdr4[0] = 0x47444347u;   /* 'GDCG' */
                hdr4[1] = (uint32_t)g_nobj;
                hdr4[2] = (uint32_t)g_nedge;
                hdr4[3] = (uint32_t)g_nroots;
                fwrite(hdr4, 4, 4, f);
                for (i = 0; i < g_nobj; i++) {
                    uint32_t *h = (uint32_t *)(base + (uint32_t)i * 16u);
                    uint32_t rc = h[1];
                    uint32_t roff = h[2] - dev.graph_paddr;
                    fwrite(&rc, 4, 1, f);
                    if (rc != 0)
                        fwrite(base + roff, 4, rc, f);
                }
                fwrite(g_roots, 4, (size_t)g_nroots, f);
                fclose(f);
                printf("[FOGCCC] dump %s objects=%d edges=%d roots=%d\n",
                       dump, g_nobj, g_nedge, g_nroots);
            }
        }
    }

    dev.obj_count = g_nobj;

    /* Feed the roots 256 at a time: the first pass clears the bitmap, the
       later ones keep it (CTRL[4] = BM_KEEP), so the union accumulates. */
    hw = 0;
    t_mark = now_us();
    for (base_pass = 0; base_pass * ROOT_REGS < g_nroots; base_pass++) {
        int first = base_pass * ROOT_REGS;
        int n = g_nroots - first;
        uint32_t pass_cycles = 0;

        if (n > ROOT_REGS)
            n = ROOT_REGS;

        fpga_gc_set_roots(&dev, g_roots + first, n);
        if (base_pass == 0)
            hw = fpga_gc_mark(&dev, &pass_cycles);
        else
            hw = fpga_gc_mark_incremental(&dev, &pass_cycles);
        cycles += pass_cycles;
        printf("[FOGCCC] pass %d roots=%d marked=%u cycles=%u\n",
               base_pass, n, hw, pass_cycles);
    }

    t_mkdone = now_us();

    hw = 0;
    {
        uint32_t wbuf[256];          /* 256 words = 8192 objects per burst */
        int base_i, wi, k, nw;

        for (base_i = 0; base_i < g_nobj; base_i += 256 * 32) {
            nw = (g_nobj - base_i + 31) / 32;
            if (nw > 256)
                nw = 256;
            if (fpga_gc_read_mark_words(&dev, (uint32_t)(base_i >> 5), wbuf, nw) != 0) {
                printf("[FOGCCC] export: bitmap read failed at object %d\n", base_i);
                break;
            }
            for (wi = 0; wi < nw; wi++) {
                uint32_t w = wbuf[wi];

                for (k = 0; k < 32; k++) {
                    int idx = base_i + wi * 32 + k;
                    int h, s;

                    if (idx >= g_nobj)
                        break;
                    h = (int)((w >> k) & 1u);
                    s = is_hard_marked(g_obj[idx]) ? 1 : 0;
                    sw += s;
                    hw += h;
                    if (h && !s)
                        false_pos++;
                    if (s && !h)
                        miss++;
                }
            }
        }
    }

    printf("[FOGCCC] hw=%u sw=%d miss=%d false_pos=%d cycles=%u status=0x%X\n",
           hw, sw, miss, false_pos, cycles, fpga_gc_status(&dev));
    printf("[FOGCCC] SHADOW_RESULT %s\n",
           false_pos != 0 ? "FAIL" : (miss != 0 ? "SOUND" : "OK"));

    t_cmp = now_us();
    printf("[FOGCCC] timing us: collect=%llu layout=%llu initwrite=%llu mark=%llu compare=%llu total=%llu\n",
           (unsigned long long)(t_run - t_first),
           (unsigned long long)(t_init - t_run),
           (unsigned long long)(t_write - t_init),
           (unsigned long long)(t_mkdone - t_write),
           (unsigned long long)(t_cmp - t_mkdone),
           (unsigned long long)(t_cmp - t_first));

    fpga_gc_close(&dev);
    free(cnt); free(start); free(cur);
}
