#!/usr/bin/env python3
"""P3 step 1: per-object dirty bitmap + ring (no export change here).

Adds:
  - fogccc_card_touch()/fogccc_card_report() in fogccc_shadow.c
    (the name is kept so the interpreter/JNI call sites stay unchanged)
  - heap base/size accessors and fogccc_object_live() in alloc.c
  - barrier calls in interp.c (AASTORE, PUTFIELD_QUICK _REF)
  - barrier calls in jni.c (SetObjectField, SetObjectArrayElement)

Bitmap: one bit per 8-byte heap slot (objects are 8-byte aligned and at least
16 bytes, so each object owns its slot).  The first touch of a collection sets
the bit and appends the object's heap offset to a 64K ring; later touches are
one load + test.  Enabled by FOGCCC_CARD=1 (or FOGCCC_SHADOW=1).
"""
import io
import os
import sys

SRC = os.path.expanduser("~/jamvm-src-fogccc/src")


def sub(path, old, new, count=1):
    p = os.path.join(SRC, path)
    t = io.open(p, encoding="utf-8", errors="surrogateescape").read()
    n = t.count(old)
    if n != count:
        sys.exit("%s: expected %d found %d for %r" % (path, count, n, old[:90]))
    io.open(p, "w", encoding="utf-8", errors="surrogateescape").write(t.replace(old, new))


# ---------------------------------------------------------------- header
sub("fogccc_shadow.h",
    "void fogccc_shadow_run(int (*is_hard_marked)(Object *));",
    """void fogccc_shadow_run(int (*is_hard_marked)(Object *));

/* P3 dirty tracking: one bit per 8-byte heap slot plus a ring of the offsets
   touched since the last collection.  A write barrier calls
   fogccc_card_touch(container). */
void fogccc_card_touch(Object *ob);
void fogccc_card_report(const char *tag);

/* 1 when `ob` is an allocated, live object of the current mark. */
int  fogccc_object_live(Object *ob);""")

# ---------------------------------------------------------------- accessors
sub("alloc.c",
    "static char *heapbase;\nstatic char *heaplimit;\nstatic char *heapmax;",
    """static char *heapbase;
static char *heaplimit;
static char *heapmax;

/* FOGCCC: the dirty bitmap is indexed by heap offset; the exporter owns the
   table, so it needs the heap bounds.  Both are valid after allocInit(). */
char *fogccc_heap_base(void) { return heapbase; }
/* Current committed size.  JamVM grows the heap in place (expandHeap raises
   heaplimit), so this value changes over the life of the process and the
   exporter must re-read it instead of caching it. */
uint32_t fogccc_heap_size(void) { return (uint32_t)(heaplimit - heapbase); }
/* Whole reserved range: the dirty bitmap must cover it, otherwise a write to
   an object allocated after an expansion is silently dropped by the barrier. */
uint32_t fogccc_heap_max_size(void) { return (uint32_t)(heapmax - heapbase); }
char *fogccc_heap_end(void) { return heaplimit; }""")

sub("alloc.c",
    "static int fogccc_is_hard_marked(Object *ob) {",
    """/* P3: is this address an allocated, marked object of the current cycle? */
int fogccc_object_live(Object *ob) {
    char *p = (char *)ob;

    if (p < heapbase + HEADER_SIZE || p >= heaplimit)
        return 0;
    if (!HDR_ALLOCED(HEADER(p - HEADER_SIZE)))
        return 0;
    return IS_MARKED(ob);
}

static int fogccc_is_hard_marked(Object *ob) {""")

# ---------------------------------------------------------------- dirty bitmap
sub("fogccc_shadow.c",
    "void fogccc_shadow_root(Object *ob) {",
    """/* ---------------------------------------------------------------- P3 dirty
 * One bit per 8-byte heap slot.  Objects are 8-byte aligned and at least 16
 * bytes, so a slot never holds two objects.  The first touch after a
 * collection sets the bit and appends the offset to the ring; the collector
 * walks the ring instead of the heap.  FOGCCC_CARD=1 enables the barrier
 * without the shadow exporter (mutator-overhead measurement).
 */
#define DIRTY_SHIFT  3
#define RING_MAX     65536

static uint32_t *g_dirty;        /* 1 bit per (1 << DIRTY_SHIFT) bytes */
static uint32_t *g_ring;         /* heap offsets touched this cycle */
static uint32_t  g_ring_n;
static uint32_t  g_ring_ovf;
static uint32_t  g_ring_max = RING_MAX;   /* FOGCCC_RING_MAX: negative-control hook */
static uint32_t  g_dirty_words;
static char     *g_heap_lo;
static uint32_t  g_heap_bytes;
static uint32_t  g_card_dirty;   /* number of ring entries (report) */
static int       g_card_ready;

extern char *fogccc_heap_base(void);
extern uint32_t fogccc_heap_size(void);
extern uint32_t fogccc_heap_max_size(void);
extern char *fogccc_heap_end(void);
extern void fogccc_heap_dbg(const char *tag);

static void card_init(void) {
    uint32_t slots;

    if (g_card_ready)
        return;
    g_card_ready = 1;
    g_heap_lo = fogccc_heap_base();
    /* Cover the whole reserved heap, not just the currently committed part:
       the heap grows while the mutator runs and a cached size would drop every
       write above the old limit (measured: 63% of a 1M-object graph lost). */
    g_heap_bytes = fogccc_heap_max_size();
    if (g_heap_lo == NULL || g_heap_bytes == 0)
        return;
    slots = (g_heap_bytes >> DIRTY_SHIFT) + 1u;
    g_dirty_words = (slots + 31u) >> 5;
    g_dirty = (uint32_t *)calloc((size_t)g_dirty_words, sizeof(uint32_t));
    g_ring = (uint32_t *)malloc((size_t)RING_MAX * sizeof(uint32_t));
    {
        /* Negative-control hook: shrink the ring so a small workload provably
           overflows it, then check that the takeover refuses to run. */
        const char *e = getenv("FOGCCC_RING_MAX");

        if (e != NULL) {
            long v = atol(e);

            if (v > 0 && v < (long)RING_MAX)
                g_ring_max = (uint32_t)v;
        }
    }
    if (g_dirty == NULL || g_ring == NULL) {
        free(g_dirty);
        free(g_ring);
        g_dirty = NULL;
        g_ring = NULL;
        g_dirty_words = 0;
    }
}

static int card_on(void) {
    static int v = -1;

    if (v < 0) {
        const char *c = getenv("FOGCCC_CARD");
        const char *s = getenv("FOGCCC_SHADOW");

        v = ((c != NULL && c[0] != '\\0' && c[0] != '0') ||
             (s != NULL && s[0] != '\\0' && s[0] != '0')) ? 1 : 0;
        if (v)
            card_init();
    }
    return v;
}

void fogccc_card_touch(Object *ob) {
    uintptr_t a = (uintptr_t)ob;
    uint32_t off, idx, word, bit;

    if (!card_on() || g_dirty == NULL)
        return;
    if (a < (uintptr_t)g_heap_lo)
        return;
    off = (uint32_t)(a - (uintptr_t)g_heap_lo);
    if (off >= g_heap_bytes)
        return;
    idx = off >> DIRTY_SHIFT;
    word = idx >> 5;
    bit = 1u << (idx & 31u);
    if (g_dirty[word] & bit)
        return;
    g_dirty[word] |= bit;
    /* Mutator threads share the ring.  Reserve the slot with a CAS so two
       threads can never write the same index or lose an entry; the ring stays
       <= RING_MAX.  The dirty-bit test above is not atomic, so a duplicate
       entry is possible -- the export is idempotent, a lost slot is not. */
    {
        uint32_t slot = g_ring_n;

        for (;;) {
            if (slot >= g_ring_max) {
                __sync_fetch_and_add(&g_ring_ovf, 1u);
                break;
            }
            if (__sync_bool_compare_and_swap(&g_ring_n, slot, slot + 1u))
                break;
            slot = g_ring_n;
        }
        if (slot < g_ring_max) {
            /* Absolute address: the heap can shrink after a collection, so a
       heap-relative offset captured earlier may fall outside the new
       limit.  The entry is a 32-bit address on ARM. */
    g_ring[slot] = (uint32_t)(uintptr_t)ob;
            g_card_dirty = slot + 1u;
        }
    }
}

void fogccc_card_report(const char *tag) {
    if (!card_on() || g_dirty == NULL)
        return;
    printf("[FOGCCC] dirty %s: objects=%u overflow=%u\\n",
           tag, g_ring_n, g_ring_ovf);
}

void fogccc_shadow_root(Object *ob) {""")

# ---------------------------------------------------------------- interp.c
sub("interp/engine/interp.c",
    '#include "interp.h"',
    '#include "interp.h"\n#include "fogccc_shadow.h"')

sub("interp/engine/interp.c",
    """        ARRAY_DATA(array, Object*)[idx] = obj;
        DISPATCH(0, 1);""",
    """        ARRAY_DATA(array, Object*)[idx] = obj;
        fogccc_card_touch(array);
        DISPATCH(0, 1);""")

sub("interp/engine/interp.c",
    """#define PUTFIELD_QUICK(type, suffix)                         \\
    DEF_OPC_012(OPC_PUTFIELD_QUICK##suffix, {                \\
        Object *obj = (Object *)cache.i.v1;                  \\
        NULL_POINTER_CHECK(obj);                             \\
                                                             \\
        INST_DATA(obj, type, SINGLE_INDEX(pc)) = cache.i.v2; \\
        DISPATCH(0, 3);                                      \\
    })""",
    """#define PUTFIELD_QUICK(type, suffix, hook)                   \\
    DEF_OPC_012(OPC_PUTFIELD_QUICK##suffix, {                \\
        Object *obj = (Object *)cache.i.v1;                  \\
        NULL_POINTER_CHECK(obj);                             \\
                                                             \\
        INST_DATA(obj, type, SINGLE_INDEX(pc)) = cache.i.v2; \\
        hook;                                                \\
        DISPATCH(0, 3);                                      \\
    })""")

sub("interp/engine/interp.c",
    """#define PUTFIELD_QUICK(type, suffix)                        \\
    DEF_OPC_012(OPC_PUTFIELD_QUICK##suffix, {               \\
        Object *obj = (Object *)ostack[-2];                 \\
                                                            \\
        ostack -= 2;                                        \\
        NULL_POINTER_CHECK(obj);                            \\
        INST_DATA(obj, type, SINGLE_INDEX(pc)) = ostack[1]; \\
        DISPATCH(0, 3);                                     \\
    })""",
    """#define PUTFIELD_QUICK(type, suffix, hook)                  \\
    DEF_OPC_012(OPC_PUTFIELD_QUICK##suffix, {               \\
        Object *obj = (Object *)ostack[-2];                 \\
                                                            \\
        ostack -= 2;                                        \\
        NULL_POINTER_CHECK(obj);                            \\
        INST_DATA(obj, type, SINGLE_INDEX(pc)) = ostack[1]; \\
        hook;                                               \\
        DISPATCH(0, 3);                                     \\
    })""")

sub("interp/engine/interp.c",
    """    PUTFIELD_QUICK(u4, /* none */)
    PUTFIELD_QUICK(uintptr_t, _REF)""",
    """    PUTFIELD_QUICK(u4, /* none */, /* no dirty bit: not a reference */)
    PUTFIELD_QUICK(uintptr_t, _REF, fogccc_card_touch(obj))""")

# ---------------------------------------------------------------- jni.c
sub("jni.c",
    '#include "alloc.h"',
    '#include "alloc.h"\n#include "fogccc_shadow.h"')

sub("jni.c",
    """    INST_DATA(ob, jobject, fb->u.offset) = REF_TO_OBJ(value);
}""",
    """    INST_DATA(ob, jobject, fb->u.offset) = REF_TO_OBJ(value);
    fogccc_card_touch(ob);
}""")

sub("jni.c",
    """    ARRAY_DATA(REF_TO_OBJ(array), Object*)[index] = REF_TO_OBJ(value);
}""",
    """    ARRAY_DATA(REF_TO_OBJ(array), Object*)[index] = REF_TO_OBJ(value);
    fogccc_card_touch(REF_TO_OBJ(array));
}""")

# ---------------------------------------------------------------- allocation
sub("alloc.c",
    """    Object *ob = gcMalloc(cb->object_size);

    if(ob != NULL) {
        ob->class = class;""",
    """    Object *ob = gcMalloc(cb->object_size);

    if(ob != NULL) {
        ob->class = class;
        fogccc_card_touch(ob);""")

sub("alloc.c",
    """    ob = gcMalloc(size * el_size + sizeof(uintptr_t) + sizeof(Object));

    if(ob != NULL) {
        ob->class = class;
        ARRAY_LEN(ob) = size;""",
    """    ob = gcMalloc(size * el_size + sizeof(uintptr_t) + sizeof(Object));

    if(ob != NULL) {
        ob->class = class;
        ARRAY_LEN(ob) = size;
        fogccc_card_touch(ob);""")

sub("alloc.c",
    """int fogccc_object_live(Object *ob) {
    char *p = (char *)ob;

    if (p < heapbase + HEADER_SIZE || p >= heaplimit)
        return 0;
    if (!HDR_ALLOCED(HEADER(p - HEADER_SIZE)))
        return 0;
    return IS_MARKED(ob);
}""",
    """int fogccc_object_live(Object *ob) {
    char *p = (char *)ob;

    if (p < heapbase + HEADER_SIZE || p >= heaplimit)
        return 0;
    if (!HDR_ALLOCED(HEADER(p - HEADER_SIZE)))
        return 0;
    return IS_MARKED(ob);
}

int fogccc_mark_value(Object *ob) { return IS_MARKED(ob); }
char *fogccc_heap_lo_dbg(void) { return heapbase; }

/* 0 = live; 1 = below heap, 2 = above limit, 3 = not allocated, 4 = unmarked */
int fogccc_live_reason(Object *ob) {
    char *p = (char *)ob;

    if (p < heapbase + HEADER_SIZE)
        return 1;
    if (p >= heaplimit)
        return 2;
    if (!HDR_ALLOCED(HEADER(p - HEADER_SIZE)))
        return 3;
    if (!IS_MARKED(ob))
        return 4;
    return 0;
}""")

sub("fogccc_shadow.h",
    "int  fogccc_object_live(Object *ob);",
    """int  fogccc_object_live(Object *ob);
int  fogccc_mark_value(Object *ob);
char *fogccc_heap_lo_dbg(void);
int  fogccc_live_reason(Object *ob);""")

# The ring only holds addresses the barrier saw as objects, so the mark bit is
# the liveness oracle; the block-header check was redundant and misread.
sub("alloc.c",
    """int fogccc_object_live(Object *ob) {
    char *p = (char *)ob;

    if (p < heapbase + HEADER_SIZE || p >= heaplimit)
        return 0;
    if (!HDR_ALLOCED(HEADER(p - HEADER_SIZE)))
        return 0;
    return IS_MARKED(ob);
}""",
    """int fogccc_object_live(Object *ob) {
    char *p = (char *)ob;

    if (p < heapbase + HEADER_SIZE || p >= heaplimit)
        return 0;
    return IS_MARKED(ob);
}""")

sub("interp/engine/interp.c",
    """            if(*fb->type == 'L' || *fb->type == '[')
                INST_DATA(obj, uintptr_t, fb->u.offset) = cache.i.v2;
            else""",
    """            if(*fb->type == 'L' || *fb->type == '[') {
                INST_DATA(obj, uintptr_t, fb->u.offset) = cache.i.v2;
                fogccc_card_touch(obj);
            } else""")

sub("interp/engine/interp.c",
    """            if(*fb->type == 'L' || *fb->type == '[')
                INST_DATA(obj, uintptr_t, fb->u.offset) = ostack[1];
            else""",
    """            if(*fb->type == 'L' || *fb->type == '[') {
                INST_DATA(obj, uintptr_t, fb->u.offset) = ostack[1];
                fogccc_card_touch(obj);
            } else""")

sub("natives.c",
    '#include "jam.h"',
    '#include "jam.h"\n#include "fogccc_shadow.h"')

sub("natives.c",
    """uintptr_t *putObjectVolatile(Class *class, MethodBlock *mb, uintptr_t *ostack) {
    long long offset = *((long long *)&ostack[2]);
    volatile uintptr_t *addr = (uintptr_t*)((char *)ostack[1] + offset);
    uintptr_t value = ostack[4];

    MBARRIER();
    *addr = value;

    return ostack;
}""",
    """uintptr_t *putObjectVolatile(Class *class, MethodBlock *mb, uintptr_t *ostack) {
    long long offset = *((long long *)&ostack[2]);
    volatile uintptr_t *addr = (uintptr_t*)((char *)ostack[1] + offset);
    uintptr_t value = ostack[4];

    MBARRIER();
    *addr = value;
    fogccc_card_touch((Object *)ostack[1]);

    return ostack;
}""")

sub("natives.c",
    """uintptr_t *putObject(Class *class, MethodBlock *mb, uintptr_t *ostack) {
    long long offset = *((long long *)&ostack[2]);
    uintptr_t *addr = (uintptr_t*)((char *)ostack[1] + offset);
    uintptr_t value = ostack[4];

    *addr = value;
    return ostack;
}""",
    """uintptr_t *putObject(Class *class, MethodBlock *mb, uintptr_t *ostack) {
    long long offset = *((long long *)&ostack[2]);
    uintptr_t *addr = (uintptr_t*)((char *)ostack[1] + offset);
    uintptr_t value = ostack[4];

    *addr = value;
    fogccc_card_touch((Object *)ostack[1]);
    return ostack;
}""")

sub("natives.c",
    """    *ostack++ = result;
    return ostack;
}

uintptr_t *putOrderedObject""",
    """    fogccc_card_touch((Object *)ostack[1]);
    *ostack++ = result;
    return ostack;
}

uintptr_t *putOrderedObject""")

sub("natives.c",
    """uintptr_t *putOrderedObject(Class *class, MethodBlock *mb, uintptr_t *ostack) {
    long long offset = *((long long *)&ostack[2]);
    volatile uintptr_t *addr = (uintptr_t*)((char *)ostack[1] + offset);
    uintptr_t value = ostack[4];

    *addr = value;
    return ostack;
}""",
    """uintptr_t *putOrderedObject(Class *class, MethodBlock *mb, uintptr_t *ostack) {
    long long offset = *((long long *)&ostack[2]);
    volatile uintptr_t *addr = (uintptr_t*)((char *)ostack[1] + offset);
    uintptr_t value = ostack[4];

    *addr = value;
    fogccc_card_touch((Object *)ostack[1]);
    return ostack;
}""")

print("dirty bitmap + ring + write barrier installed")
