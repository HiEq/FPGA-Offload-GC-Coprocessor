#!/usr/bin/env python3
"""P3 step 2: incremental side-table export driven by the card table.

FOGCCC_SHADOW=1 FOGCCC_INCREMENTAL=1 selects it.  The first collection does a
full export (fixed 16 MiB offset for the reference arrays, so new ids still
have a header slot); later collections re-export only the objects found in
dirty cards and re-feed the roots.

Requires apply_card.py (card table + barrier) and apply_addr_order.py.
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
    "void fogccc_card_touch(Object *ob);",
    """void fogccc_card_touch(Object *ob);

/* Incremental export: resets the per-collection roots/edges, and walks one
   heap range (a dirty card) calling fn() for every live object. */
void fogccc_shadow_begin(void);
void fogccc_scan_range(Object *first, char *to, void (*fn)(Object *));
void fogccc_scan_all(Object *first, char *to, void (*fn)(Object *));
char *fogccc_split_by_count(void);""")

# ---------------------------------------------------------------- alloc.c
sub("alloc.c",
    """static void doMark(Thread *self, int mark_soft_refs) {
    int i, j;

    clearMarkBits();""",
    """static void doMark(Thread *self, int mark_soft_refs) {
    int i, j;
    uint64_t t_cl = fogccc_now_us();

    clearMarkBits();
    fogccc_note_clear(fogccc_now_us() - t_cl);
    fogccc_shadow_begin();""")

sub("alloc.c",
    """Class *allocClass() {
    Class *class = gcMalloc(sizeof(ClassBlock)+sizeof(Class));

    if(class != NULL) {
        SET_SPECIAL_OB(class);""",
    """Class *allocClass() {
    Class *class = gcMalloc(sizeof(ClassBlock)+sizeof(Class));

    if(class != NULL) {
        SET_SPECIAL_OB(class);
        /* Record every Class object: a class loaded after the last round has
           no id and its fields are written by JVM code (no barrier), so the
           takeover export would otherwise never see it. */
        fogccc_note_new_class((Object *)class);""")

sub("alloc.c",
    "static int fogccc_is_hard_marked(Object *ob) {",
    """/* Allocated-block check only (no mark bit).  Takeover clears JamVM's marks
   before the export, so IS_MARKED() cannot be used as a liveness test there;
   the block header still tells us whether the address is an object. */
void fogccc_heap_dbg(const char *tag) {
    printf("[FOGCCC] heap[%s]: base=%p limit=%p max=%p size=%u\\n",
           tag, heapbase, heaplimit, heapmax,
           (unsigned)(heaplimit - heapbase));
}

int fogccc_object_alloced(Object *ob) {
    char *p = (char *)ob;
    static int dbg;

    /* heapmax, not heaplimit: JamVM shrinks heaplimit after a collection, so
       ring records captured earlier would look out of range. */
    if (p < heapbase + HEADER_SIZE || p >= heapmax) {
        if (dbg < 8 && getenv("FOGCCC_CLASSDBG") != NULL) {
            dbg++;
            printf("[FOGCCC] alloced range p=%p base=%p max=%p limit=%p\\n",
                   p, heapbase, heapmax, heaplimit);
        }
        return 0;
    }
    if (dbg < 8 && getenv("FOGCCC_CLASSDBG") != NULL) {
        uint32_t *w = (uint32_t *)p;

        dbg++;
        printf("[FOGCCC] alloced hdr p=%p base=%p w[-2]=0x%x w[-1]=0x%x w[0]=0x%x w[1]=0x%x\\n",
               p, heapbase, w[-2], w[-1], w[0], w[1]);
    }
    return HDR_ALLOCED(HEADER(p - HEADER_SIZE)) ? 1 : 0;
}

/* Incremental export: walk the blocks of [first, to) and call fn() for
   every allocated, live object.  `first` is an object pointer (or any address
   inside a block); the walk backs up to its block header.  Class blocks are
   allocated blocks but never marked, so IS_MARKED() filters them out. */
void fogccc_scan_range(Object *first, char *to, void (*fn)(Object *)) {
    char *p = ((char*)first) - HEADER_SIZE;

    while (p < to && p < heaplimit) {
        uintptr_t hdr = HEADER(p);
        uintptr_t size;

        if (HDR_ALLOCED(hdr)) {
            Object *ob = (Object*)(p + HEADER_SIZE);
            size = HDR_SIZE(hdr);
            if (IS_MARKED(ob))
                fn(ob);
        } else
            size = HDR_SIZE(hdr);
        p += size;
    }
}

/* Same walk without the mark filter: used when JamVM's mark bits are not the
   live oracle (takeover mode, where the hardware does the marking). */
void fogccc_scan_all(Object *first, char *to, void (*fn)(Object *)) {
    char *p = ((char*)first) - HEADER_SIZE;
    char *p0 = p;
    uint64_t n = 0;

    while (p < to && p < heaplimit) {
        uintptr_t hdr = HEADER(p);
        uintptr_t size;

        if (HDR_ALLOCED(hdr)) {
            Object *ob = (Object*)(p + HEADER_SIZE);
            size = HDR_SIZE(hdr);
            fn(ob);
            n++;
        } else
            size = HDR_SIZE(hdr);
        p += size;
    }
    printf("[FOGCCC] scan_all: from=%p to=%p end=%p objs=%llu\\n",
           p0, to, p, (unsigned long long)n);
}

/* Split point for the two-thread export: the block whose object makes the
   object count reach half of the heap, so both workers get the same amount of
   work (an address split was 66/34 because objects grow towards the top). */
char *fogccc_split_by_count(void) {
    char *p, *best = heaplimit;
    int n = 0, half;

    for (p = heapbase; p < heaplimit; ) {
        uintptr_t hdr = HEADER(p);
        uintptr_t size = HDR_SIZE(hdr);

        if (HDR_ALLOCED(hdr))
            n++;
        p += size;
    }
    half = n / 2;
    n = 0;
    for (p = heapbase; p < heaplimit; ) {
        uintptr_t hdr = HEADER(p);
        uintptr_t size = HDR_SIZE(hdr);

        if (HDR_ALLOCED(hdr) && ++n > half) {
            best = p;
            break;
        }
        p += size;
    }
    return best;
}

static int fogccc_is_hard_marked(Object *ob) {""")

# ---------------------------------------------------------------- exporter
sub("fogccc_shadow.c",
    "static int       g_done;",
    """static int       g_done;
static int       g_incr_mode;   /* FOGCCC_INCREMENTAL=1 */
int              fogccc_edge_hooks = 0;  /* 1 only for the legacy shadow export */
static int       g_ready;       /* the first (full) export has run */
static int       g_round;
/* Previous epoch's measured numbers, used by the takeover decision.  The dev
   struct is per call, so the decision inputs have to live here. */
static uint32_t  g_ep_q_hi, g_ep_cycles, g_ep_exp, g_ep_imp, g_ep_mark;
static int       g_ep_valid, g_ep_full;   /* full = the shadow (full-export) round */
static int       g_cpu_streak;            /* consecutive CPU choices */
static uint64_t  g_sw_mark_us;            /* last measured software mark */

static uint64_t now_us(void);             /* defined below */
uint64_t fogccc_now_us(void) { return now_us(); }
void fogccc_note_sw_mark(uint64_t us) { g_sw_mark_us = us; }
static uint64_t  g_clear_us;    /* clearMarkBits(), measured in doMark */
void fogccc_note_clear(uint64_t us) { g_clear_us = us; }
uint64_t fogccc_clear_us(void) { return g_clear_us; }
static __thread uint64_t  g_round_refs;  /* real edges emitted this round */
static __thread uint32_t  g_ref_base;    /* first byte of the reference-array area */
static __thread uint32_t  g_arena_off;   /* next free byte in that area */
static uint8_t  *g_stage;       /* cached staging copy of the graph arena */
static uint32_t  g_stage_hi;
static __thread uint32_t  g_arena_start; /* first byte written this round */
static uint32_t  g_arena2_start, g_arena2_off; /* second worker's region */
static __thread uint32_t  g_hdr_lo, g_hdr_hi;   /* header span written this round */
static __thread uint32_t  g_wr_ids[4096];       /* headers written this round */
static __thread int       g_wr_n, g_wr_ovf;
int              g_ring_export;        /* 1 while exporting dirty-ring records */
static fpga_gc_t *g_vdev;              /* device open during verify */
static uint32_t  g_live_bm[32768];     /* previous round's hardware bitmap */
static int       g_live_n;             /* object count that bitmap covers */
static int       g_live_valid;
static int       g_imp_verified;       /* verify ran: marks have extra bits */
static int       g_imp_this_round;     /* the bitmap was imported this GC */

/* Id reclaim (gc0) can test liveness against the imported bitmap instead of
   calling fogccc_get_mark() once per object: at 1 M ids the calls cost ~95 ms
   of the pause, the bitmap scan ~15 ms.  The bitmap is only usable when this
   round imported it and verify did not add extra marks. */
uint32_t *fogccc_last_live_bm(void) { return g_live_bm; }
int       fogccc_last_live_n(void) { return g_live_n; }
int       fogccc_last_live_ok(void) {
    return g_imp_this_round && g_live_valid && !g_imp_verified;
}
static uint32_t  g_full_nobj;  /* obj_count of the last full export */
static uint32_t  g_full_heap;  /* committed heap size at the last full/live walk */
static int       g_force_walk; /* ring overflow: rebuild this round from the heap */
static uint64_t  g_walk_us;    /* timer: heap walk inside the export */
static uint64_t  g_flush_us;   /* timer: staging copy to DDR */
extern uint64_t  g_cref_calls;    /* fogccc_class_refs() calls this round */
extern uint64_t  g_cref_nullclass;/* ... of which object.class was NULL */
int              fogccc_ref_emit_all;  /* takeover: emit soft referents */

/* Read the hardware bitmap for one id (1 marked, 0 clear, -1 no device).
   Used by the verify diagnostic to separate "the engine missed the bit"
   from "the import dropped it". */
int fogccc_hw_mark(int id) {
    int r;

    if (g_vdev == NULL)
        return -1;
    r = fpga_gc_read_mark(g_vdev, (uint32_t)id);
    /* fpga_gc_read_mark() returns 0xFFFFFFFF when the probe cannot be trusted
       (engine busy / timeout); that must NOT be read as "marked". */
    if (r == 1)
        return 1;
    if (r == 0)
        return 0;
    return -1;
}""")

# Diagnostics: does this object exist in the exported graph?
sub("fogccc_shadow.c",
    "static int state(void) {",
    """int fogccc_obj_has_id(Object *ob) { return id_of(ob, 0) >= 0; }
int fogccc_obj_id(Object *ob) { return id_of(ob, 0); }
void *fogccc_obj_ptr(int id) {
    if (id < 0 || id >= g_nobj)
        return NULL;
    return (void *)g_obj[id];
}

static int state(void) {""")

sub("fogccc_shadow.c",
    """static int id_of(Object *ob, int create) {""",
    """/* Drop the address->id map.  Only valid when the arena is rebuilt from
   scratch in the same round: ids are positions for that round, not persistent
   keys.  Without this the table fills with ids of garbage blocks after a few
   full walks and the offload stops at MAX_OBJ (measured on a 1M-object heap). */
static void id_reset(void) {
    g_nobj = 0;
    memset(g_htab, 0, sizeof(g_htab));
    idmap_clear();
    g_nfree = 0;
    g_live_n = 0;
    g_live_valid = 0;
}

static int id_of(Object *ob, int create) {""")

sub("fogccc_shadow.c",
    "void fogccc_shadow_run(int (*is_hard_marked)(Object *)) {",
    """/* Per-collection reset: roots and edges are rebuilt every collection. */
void fogccc_shadow_begin(void) {
    const char *inc = getenv("FOGCCC_INCREMENTAL");
    const char *tk  = getenv("FOGCCC_TAKEOVER");

    fogccc_install_fault_handler();
    if (state() < 0)
        return;
    /* Decide the mode before the mark: in incremental/takeover mode the side
       table comes from a heap walk, so the per-edge hook must be off or it
       doubles the software mark's cost. */
    g_incr_mode = ((inc != NULL && inc[0] != '\\0' && inc[0] != '0') ||
                   (tk  != NULL && tk[0]  != '\\0' && tk[0]  != '0'));
    fogccc_edge_hooks = !g_incr_mode;
    fogccc_ref_emit_all = g_incr_mode;
    g_nroots = 0;
    g_nroots_seen = 0;
    g_nedge = 0;
    g_edge_ovf = 0;
    g_from_cache = NULL;
    t_first = now_us();
}

/* ---------------------------------------------------------------- incremental
 * Write one object's header and reference array into the arena.  Ids are
 * stable across collections (id_of keeps the address->id map).  A reference
 * array may change size, so it is always appended; the old copy becomes
 * garbage and the arena is compacted by the next full export.
 */
static uint8_t *g_exp_base;
static uint32_t g_exp_paddr;
static __thread uint32_t g_exp_count;
static __thread uint32_t g_exp_ovf;

static __thread uint32_t g_exp_off;   /* cursor while writing one object */
static __thread uint32_t g_exp_n;     /* refs written for this object */
static __thread uint32_t g_exp_limit = (uint32_t)GRAPH_MAP_SIZE;

/* Class objects own metadata that changes without a Java store (constant-pool
   resolution).  Record them once and re-export them every incremental round. */
#define MAX_CLASS_OBJS 8192
static Object *g_class_objs[MAX_CLASS_OBJS];
static int g_nclass;

static void emit_ref(Object *from, Object *to) {
    int t;

    (void)from;
    if (to == NULL)
        return;
    t = id_of(to, 1);
    if (t < 0)
        return;
    if (g_exp_off + 4u > g_exp_limit) {
        g_exp_ovf++;
        return;
    }
    *(uint32_t *)(g_exp_base + g_exp_off) = (uint32_t)t;
    g_exp_off += 4u;
    g_exp_n++;
    g_round_refs++;
}

/* Loader-table callback: emit the edge and also seed the class as a root.
   JamVM's markLoaderClasses() marks every class in the loader's table; the
   reflective accessor loaders form a loader->class->loader cycle with no other
   incoming edge, so the hardware closure never entered it (DaCapo xalan lost
   ~600 objects).  Rooting the classes gives the cycle an entry. */
static void loader_emit_root(Object *from, Object *to) {
    if (to == NULL)
        return;
    emit_ref(from, to);
    fogccc_shadow_root(to);
}

static void export_one(Object *ob) {
    Class *class;
    ClassBlock *cb;
    int id;
    uint32_t start;

    /* Defensive: callers include hook-recorded objects that may not have been
       initialised yet (allocClass records the Class before its class field is
       set).  Dereferencing such an object crashes the JVM. */
    if (ob == NULL)
        return;
    class = ob->class;
    if (class == NULL)
        return;

    if (class == NULL)
        return;
    id = id_of(ob, 1);
    if (id < 0)
        return;
    cb = CLASS_CB(class);
    start = g_arena_off;
    g_exp_off = start;
    g_exp_n = 0;

    if (cb->name[0] == '[') {
        if (cb->name[1] == 'L' || cb->name[1] == '[') {
            Object **body = ARRAY_DATA(ob, Object*);
            int len = ARRAY_LEN(ob), i;

            for (i = 0; i < len; i++) {
                if (i + 1 < len) {
                    /* Warm the id-map slot of the next element: the map is a
                       13 MB random-access table, so the load is the cost.
                       Distance 1 measured best (distance 4 was 10% slower:
                       the extra prefetches competed for the cache). */
                    uintptr_t off = (uintptr_t)body[i + 1] -
                                    (uintptr_t)g_idmap_lo;

                    if (g_idmap != NULL && (off >> IDMAP_SHIFT) < g_idmap_cap)
                        __builtin_prefetch(&g_idmap[off >> IDMAP_SHIFT]);
                }
                emit_ref(ob, body[i]);
            }
        }
    } else {
        int i;

        for (i = 0; i < cb->refs_offsets_size; i++) {
            int o = cb->refs_offsets_table[i].start;
            int e = cb->refs_offsets_table[i].end;

            for (; o < e; o += sizeof(Object*))
                emit_ref(ob, INST_DATA(ob, Object*, o));
        }
        /* A Class object also owns static fields, the constant pool and the
           classlib class-block refs; those edges are not in the instance. */
        if (IS_CLASS_CLASS(cb)) {
            /* A dirty-ring record can be a stale offset that merely looks
               live; treating it as a Class reads a garbage ClassBlock and
               crashes.  Ring exports therefore emit the instance refs only --
               class metadata is refreshed from g_class_objs / the allocClass
               hook, which only ever see real classes. */
            if (!g_ring_export) {
                {
                    int fi;

                    for (fi = 0; fi < cb->fields_count; fi++) {
                        FieldBlock *f = &cb->fields[fi];

                        if (f->name != NULL &&
                            strcmp(f->name, "reflectionData") == 0) {
                            Object *rd = INST_DATA(ob, Object*, f->u.offset);

                            if (rd != NULL)
                                emit_ref(ob, rd);
                            break;
                        }
                    }
                }
                fogccc_class_refs(ob, emit_ref);
            }
            /* JamVM never unloads classes.  Seed every exported Class as a
               hardware root: a class whose only incoming edge is a
               loader-table entry can otherwise be unreachable in the hardware
               graph (sunflow lost a 20-object Class cluster this way). */
            fogccc_shadow_root(ob);
            {
                int ci, found = 0;

                /* Two export workers append here. */
                while (__sync_lock_test_and_set(&g_cls_lock, 1))
                    ;
                for (ci = 0; ci < g_nclass; ci++)
                    if (g_class_objs[ci] == ob) {
                        found = 1;
                        break;
                    }
                if (!found && g_nclass < MAX_CLASS_OBJS)
                    g_class_objs[g_nclass++] = ob;
                __sync_lock_release(&g_cls_lock);
            }
        }
        /* A Reference object's referent is not an ordinary field: JamVM marks
           it with a computed mark.  Emit it only when JamVM hard-marked it. */
        if (IS_REFERENCE(cb))
            fogccc_reference_refs(ob, emit_ref);
        if (!g_ring_export && IS_CLASS_LOADER(cb))
            fogccc_loader_classes(ob, loader_emit_root);
    }

    if (g_exp_off + 4u > g_exp_limit) {
        g_exp_ovf++;
        return;
    }
    *(uint32_t *)(g_exp_base + g_exp_off) = 0xFFFFFFFFu;
    g_exp_off += 4u;

    {
        uint32_t *hdr = (uint32_t *)(g_exp_base + (uint32_t)id * 16u);
        static int dbg;

        if (dbg < 4) {
            dbg++;
            printf("[FOGCCC] exp dbg id=%d start=%u n=%u off=%u\\n",
                   id, start, g_exp_n, g_exp_off);
        }
        if ((uint32_t)id * 16u < g_hdr_lo)
            g_hdr_lo = (uint32_t)id * 16u;
        if (((uint32_t)id + 1u) * 16u > g_hdr_hi)
            g_hdr_hi = ((uint32_t)id + 1u) * 16u;
        if (g_wr_n < 4096)
            g_wr_ids[g_wr_n++] = (uint32_t)id;
        else
            g_wr_ovf = 1;
        hdr[0] = (uint32_t)id;
        hdr[1] = g_exp_n;
        hdr[2] = g_exp_paddr + start;
        hdr[3] = 0u;
    }
    g_arena_off = g_exp_off;
    g_exp_count++;
}

/* Rebuild filter.  A rebuild used to export every allocated block "because an
   object that was unmarked last round can be live now".  That is true only if
   the write barrier missed an edge, and it cost the whole id space: a heap
   holding one collection's worth of garbage (lusearch: ~1 M blocks, 64 k
   live) reached MAX_OBJ before the mark.  An object that was dead last round
   can become live only through (a) a store into a live object -- the store
   dirties the container, (b) a new allocation -- the allocation hook dirties
   the object, or (c) a root -- roots are marked explicitly below.  So
   "live last round + dirty this round" is the correct closure input, and
   every edge target is in it as well. */
static void export_one_keep(Object *ob) {
    uintptr_t off;
    uint32_t slot;
    static int no_filter = -1;

    if (no_filter < 0)
        no_filter = (getenv("FOGCCC_NO_FILTER") != NULL);
    if (no_filter) {                    /* negative control */
        export_one(ob);
        return;
    }
    if (g_dirty == NULL) {              /* no dirty oracle: keep everything */
        export_one(ob);
        return;
    }
    /* Class handles are allocated by allocClass() (direct gcMalloc, not the
       hooked allocators) and their metadata is written without a barrier, so
       they are neither dirty nor necessarily in the previous live set.  They
       carry the constant-pool / static-field / reflection edges for everything
       below, so a filtered rebuild must still export them: skipping them made
       the hardware miss 20 Class-cluster objects in sunflow (verify_extra=20). */
    if (ob->class != NULL && IS_CLASS_CLASS(CLASS_CB(ob->class))) {
        export_one(ob);
        return;
    }
    off = (uintptr_t)ob - (uintptr_t)g_heap_lo;
    slot = (uint32_t)(off >> DIRTY_SHIFT);
    if (!fogccc_waslive_keep(ob) &&
        ((slot >> 5) >= g_dirty_words ||
         !((g_dirty[slot >> 5] >> (slot & 31)) & 1u)))
        return;                         /* last round's garbage, untouched */
    export_one(ob);
}

/* ---------------------------------------------------------------- two-thread walk
 * The 1 M rebuild walk is dominated by ~6 M id lookups; splitting the heap in
 * two halves halves that.  Each worker owns a disjoint arena region (so no
 * offset coordination is needed) and writes headers by id (disjoint too).
 * The split must be a block boundary; find it with a cheap header-only pass.
 */
typedef struct {
    char     *lo, *hi;
    uint32_t  arena_base;
    /* results */
    uint32_t  arena_off, hdr_lo, hdr_hi;
    uint32_t  count, ovf;
    uint64_t  refs;
    int       wr_ovf;
} exp_job2_t;

#define EXP_REGION (((uint32_t)GRAPH_MAP_SIZE - (uint32_t)MAX_OBJ * 16u) / 2u)

static void *exp_worker2(void *arg) {
    exp_job2_t *j = (exp_job2_t *)arg;

    g_arena_off = j->arena_base;
    g_arena_start = j->arena_base;
    g_exp_off = j->arena_base;
    g_exp_limit = j->arena_base + EXP_REGION;
    g_exp_count = 0;
    g_exp_ovf = 0;
    g_round_refs = 0;
    g_hdr_lo = 0xFFFFFFFFu;
    g_hdr_hi = 0;
    g_wr_n = 0;
    g_wr_ovf = 0;

    fogccc_scan_all((Object *)(j->lo + sizeof(uintptr_t)), j->hi, export_one_keep);

    j->arena_off = g_arena_off;
    j->hdr_lo = g_hdr_lo;
    j->hdr_hi = g_hdr_hi;
    j->count = g_exp_count;
    j->ovf = g_exp_ovf;
    j->refs = g_round_refs;
    j->wr_ovf = g_wr_ovf;
    return NULL;
}

/* Export filter for a takeover full walk: only objects that were live in the
   previous round are written.  JamVM's own mark bits are cleared before the
   walk, so the previous bitmap is the only live oracle available.  Objects
   without an id are new since the last export and are covered by the dirty
   ring. */
static void export_one_live(Object *ob) {
    int id = id_of(ob, 0);

    if (id >= 0 && id < g_live_n &&
        !((g_live_bm[id >> 5] >> (id & 31)) & 1u)) {
        /* Allocated before, unmarked last round: unswept garbage.  Its old
           header may still point at the reference area we are about to
           overwrite, so invalidate it (ref_count = 0). */
        uint32_t *h = (uint32_t *)(g_exp_base + (uint32_t)id * 16u);

        h[1] = 0u;
        h[2] = 0u;
        return;
    }
    export_one(ob);
}

/* Validity check for a Class object.  Class names are C strings in the
   metaspace, never in or next to the Java heap; a name pointer that lands
   there belongs to a reused or half-built block and dereferencing it faults
   (measured: external abort at heapbase-12). */
static int cls_ok(Object *c) {
    ClassBlock *cb;
    char *nm;

    if (c == NULL || !fogccc_object_alloced(c))
        return 0;
    /* A Class handle's object.class field is NULL: JamVM derives the
       ClassBlock from the handle itself (CLASS_CB(c) = c + 1), so the usual
       "class != NULL" test rejects every real class. */
    cb = CLASS_CB(c);
    nm = cb != NULL ? cb->name : NULL;
    if (nm == NULL || ((uintptr_t)nm & 3) != 0)
        return 0;
    {
        char *hb = fogccc_heap_base();
        char *hm = hb + fogccc_heap_max_size();

        if (nm >= hb - 0x100000 && nm < hm + 0x100000)
            return 0;
    }
    return 1;
}

static void export_cards(void) {
    uint32_t i, live = 0, dead = 0;

    g_ring_export = 1;
    for (i = 0; i < g_ring_n; i++) {
        Object *ob;

        ob = (Object *)(uintptr_t)g_ring[i];

        if (fogccc_object_live(ob)) {
            export_one(ob);
            live++;
        } else {
            if (dead < 3)
                printf("[FOGCCC] incr dead off=%u hdr=%08x cls=%p why=%d mark=%d\\n",
                       g_ring[i],
                       (unsigned)*(uintptr_t *)((char *)ob - sizeof(uintptr_t)),
                       (void *)ob->class, fogccc_live_reason(ob),
                       fogccc_mark_value(ob));
            dead++;
        }
    }
    g_ring_export = 0;
    /* Class metadata can change without a write barrier (new constant-pool
       resolutions), so refresh every Class object each round. */
    for (i = 0; i < (uint32_t)g_nclass; i++)
        if (fogccc_object_live(g_class_objs[i]))
            export_one(g_class_objs[i]);
    printf("[FOGCCC] incr ring: ring=%u live=%u dead=%u classes=%d\\n",
           g_ring_n, live, dead, g_nclass);
}

static void cards_clear(void) {
    uint32_t i;

    if (g_ring_ovf != 0) {
        /* entries were dropped; start the next cycle from a clean table */
        memset(g_dirty, 0, (size_t)g_dirty_words * sizeof(uint32_t));
    } else {
        for (i = 0; i < g_ring_n; i++) {
            uint32_t idx = (uint32_t)((uintptr_t)g_ring[i] -
                                (uintptr_t)g_heap_lo) >> DIRTY_SHIFT;
            g_dirty[idx >> 5] &= ~(1u << (idx & 31u));
        }
    }
    g_ring_n = 0;
    g_ring_ovf = 0;
    g_card_dirty = 0;
}

/* gc0() calls this at the end of every collection.  The shadow / CPU path
   never cleared the table, so the first takeover rebuild saw every block as
   "dirty" and could not filter last round's garbage (that is how lusearch hit
   the id ceiling). */
void fogccc_cards_clear(void) { cards_clear(); }

static uint8_t *stage_get(uint8_t *base) {
    if (g_stage == NULL)
        g_stage = (uint8_t *)malloc(GRAPH_MAP_SIZE);
    return g_stage != NULL ? g_stage : base;
}

static void stage_flush(uint8_t *base) {
    int i;

    if (g_exp_base != g_stage)
        return;
    if (g_arena_off > g_arena_start)
        memcpy(base + g_arena_start, g_stage + g_arena_start,
               g_arena_off - g_arena_start);
    if (g_arena2_off > g_arena2_start)
        memcpy(base + g_arena2_start, g_stage + g_arena2_start,
               g_arena2_off - g_arena2_start);
    if (g_wr_ovf) {
        /* Too many object headers this round (full walk): copy the span. */
        if (g_hdr_hi > g_hdr_lo)
            memcpy(base + g_hdr_lo, g_stage + g_hdr_lo, g_hdr_hi - g_hdr_lo);
    } else {
        /* Incremental round: the ids are scattered, so copying the whole
           [min,max] span would dominate the export (measured 17 ms on 403k). */
        for (i = 0; i < g_wr_n; i++) {
            uint32_t off = g_wr_ids[i] * 16u;

            memcpy(base + off, g_stage + off, 16u);
        }
    }
    g_stage_hi = g_arena_off;
}

/* Diagnostic: does any object in the exported arena reference `target`?
   Distinguishes "the export lost the edge" from "the engine lost the beat". */
void fogccc_arena_find_parents(int target) {
    int i, found = 0;

    {
        uint32_t *th = (uint32_t *)(g_exp_base + (uint32_t)target * 16u);

        printf("[FOGCCC] arena hdr id=%d: id=%u cnt=%u off=%u\\n",
               target, th[0], th[1], th[2] - g_exp_paddr);
    }
    for (i = 0; i < (int)g_nobj; i++) {
        uint32_t *h = (uint32_t *)(g_exp_base + (uint32_t)i * 16u);
        uint32_t cnt = h[1];
        uint32_t off = h[2] - g_exp_paddr;
        uint32_t k;

        if (cnt > 65536u)
            continue;
        for (k = 0; k < cnt; k++) {
            uint32_t t = *(uint32_t *)(g_exp_base + off + k * 4u);

            if (t == (uint32_t)target) {
                if (found < 5)
                    printf("[FOGCCC] arena parent id=%d cnt=%u off=%u\\n",
                           i, cnt, off);
                found++;
            }
        }
    }
    printf("[FOGCCC] arena parents of id=%d: %d\\n", target, found);
}

/* Third diagnostic scan: class metadata edges (static fields, resolved
   constant pool, classlib class-block refs).  The heap-parent scan cannot see
   these because they are not instance fields. */
static Object *g_meta_target;
static int g_meta_found;

static void meta_emit(Object *from, Object *to) {
    if (to == g_meta_target) {
        ClassBlock *cb = from->class ? CLASS_CB((Class *)from) : NULL;

        if (g_meta_found < 8)
            printf("[FOGCCC] meta parent class=%s id=%d hw=%d\\n",
                   cb != NULL ? cb->name : "?", fogccc_obj_id(from),
                   fogccc_hw_mark(fogccc_obj_id(from)));
        g_meta_found++;
    }
}

void fogccc_meta_find_parents(Object *target) {
    int i;

    g_meta_target = target;
    g_meta_found = 0;
    for (i = 0; i < g_nclass; i++) {
        Object *c = g_class_objs[i];

        if (!fogccc_object_alloced(c) || c->class == NULL)
            continue;
        fogccc_class_refs(c, meta_emit);
    }
    printf("[FOGCCC] meta parents of %p: %d\\n", (void *)target, g_meta_found);
}

int fogccc_root_has(Object *ob) {
    int i;

    for (i = 0; i < g_nroots; i++)
        if (g_root_objs[i] == ob)
            return 1;
    return 0;
}

int fogccc_root_id_of(Object *ob) {
    int i;

    for (i = 0; i < g_nroots; i++)
        if (g_root_objs[i] == ob)
            return (int)g_roots[i];
    return -1;
}


static void incr_run(int (*is_hard_marked)(Object *), fpga_gc_t *dev, int full) {
    uint8_t *base;
    uint32_t hw, cycles = 0;
    int pass, sw = 0, miss = 0, false_pos = 0;

    base = (uint8_t *)dev->graph_vaddr;
    g_exp_base = stage_get(base);
    g_exp_paddr = dev->graph_paddr;
    g_exp_count = 0;
    g_exp_ovf = 0;
    g_round_refs = 0;

    /* A ring overflow means this cycle's dirty set is incomplete: fall back to
       the full heap walk.  FOGCCC_FULL_EXPORT forces the full walk every round
       (debug: isolates the incremental export from the marking itself). */
    if (g_ring_ovf != 0)
        full = 1;
    if (getenv("FOGCCC_FULL_EXPORT") != NULL)
        full = 1;

    if (full)
        g_arena_off = (uint32_t)MAX_OBJ * 16u;

    g_arena_start = g_arena_off;
    g_hdr_lo = 0xFFFFFFFFu;
    g_hdr_hi = 0;
    g_wr_n = 0;
    g_wr_ovf = 0;

    t_init = now_us();
    if (full) {
        /* Full export = walk every live object and write its TRUE reference
           list.  The mark hooks only see the edges that newly marked a child
           (a spanning tree); after a mutation that tree can orphan a node, so
           the table must hold all edges. */
        uint32_t a0 = g_arena_off;

        g_nclass = 0;
        fogccc_scan_range((Object *)(g_heap_lo + sizeof(uintptr_t)),
                          fogccc_heap_end(), export_one);
        printf("[FOGCCC] full walk: classes=%d objects=%d refs=%llu arena %u->%u\\n",
               g_nclass, g_exp_count, (unsigned long long)g_round_refs,
               a0, g_arena_off);
        t_write = now_us();
        cards_clear();
    } else {
        export_cards();
        cards_clear();          // ring and dirty bits are per-cycle
        t_write = now_us();
    }

    stage_flush(base);
    t_write = now_us();

    dev->obj_count = (uint32_t)g_nobj;
    for (pass = 0; pass * ROOT_REGS < g_nroots; pass++) {
        int first = pass * ROOT_REGS;
        int n = g_nroots - first;
        uint32_t pc = 0;

        if (n > ROOT_REGS)
            n = ROOT_REGS;
        fpga_gc_set_roots(dev, g_roots + first, n);
        if (pass == 0)
            hw = fpga_gc_mark(dev, &pc);
        else
            hw = fpga_gc_mark_incremental(dev, &pc);
        cycles += pc;
    }
    t_mkdone = now_us();

    /* Compare the hardware bitmap with JamVM's own mark (the oracle). */
    hw = 0;
    {
        uint32_t wbuf[256];
        int base_i, wi, k, nw;

        for (base_i = 0; base_i < g_nobj; base_i += 256 * 32) {
            nw = (g_nobj - base_i + 31) / 32;
            if (nw > 256)
                nw = 256;
            if (fpga_gc_read_mark_words(dev, (uint32_t)(base_i >> 5), wbuf, nw) != 0) {
                printf("[FOGCCC] incr: bitmap read failed at object %d\\n", base_i);
                break;
            }
            memcpy(&g_live_bm[base_i >> 5], wbuf, (size_t)nw * 4u);
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
                    if (s && !h) {
                        miss++;
                        if (miss <= 20) {
                            ClassBlock *mcb = g_obj[idx]->class ? CLASS_CB(g_obj[idx]->class) : NULL;
                            uint32_t *mh = (uint32_t *)(base + (uint32_t)idx * 16u);
                            printf("[FOGCCC] miss id=%d cls=%s cnt=%u\\n",
                                   idx, mcb ? mcb->name : "?", mh[1]);
                        }
                    }
                }
            }
        }
    }
    t_cmp = now_us();
    g_live_n = g_nobj;
    g_live_valid = 1;

    printf("[FOGCCC] incr round=%d objects=%d exported=%d refs=%llu dirty_ovf=%d roots=%d "
           "hw=%u sw=%d miss=%d false_pos=%d cycles=%u q_hi=%u status=0x%X\\n",
           g_round, g_nobj, g_exp_count, (unsigned long long)g_round_refs,
           g_exp_ovf, g_nroots,
           hw, sw, miss, false_pos, cycles, dev->epoch_q_hi, fpga_gc_status(dev));
    printf("[FOGCCC] SHADOW_RESULT %s\\n",
           false_pos != 0 ? "FAIL" : (miss != 0 ? "SOUND" : "OK"));
    printf("[FOGCCC] incr timing us: export=%llu mark=%llu compare=%llu clear=%llu arena=%u\\n",
           (unsigned long long)(t_write - t_init),
           (unsigned long long)(t_mkdone - t_write),
           (unsigned long long)(t_cmp - t_mkdone),
           (unsigned long long)fogccc_clear_us(), g_arena_off);
    /* The shadow round's export is a full heap walk, so its numbers are not
       representative for the decision; g_ep_full tells the decider to use the
       shape only. */
    g_ep_q_hi   = dev->epoch_q_hi;
    g_ep_cycles = dev->epoch_cycles;
    g_ep_exp    = (uint32_t)(t_write - t_init);
    g_ep_imp    = 0;
    g_ep_mark   = (uint32_t)(t_mkdone - t_write);
    g_ep_full   = 1;
    g_ep_valid  = 1;
}

void fogccc_shadow_run(int (*is_hard_marked)(Object *)) {""")

# one-shot gate becomes "first run only" unless incremental is requested
sub("fogccc_shadow.c",
    """    if (state() <= 0 || g_done)
        return;
    g_done = 1;
    t_run = now_us();""",
    """    {
        const char *inc = getenv("FOGCCC_INCREMENTAL");
        const char *tk  = getenv("FOGCCC_TAKEOVER");

        g_incr_mode = ((inc != NULL && inc[0] != '\\0' && inc[0] != '0') ||
                       (tk  != NULL && tk[0]  != '\\0' && tk[0]  != '0'));
    }
    fogccc_edge_hooks = !g_incr_mode;
    if (state() <= 0 || (!g_incr_mode && g_done))
        return;
    if (!g_incr_mode)
        g_done = 1;
    g_round++;
    t_run = now_us();
    fogccc_card_report("at export");""")

# incremental path after the device is initialised
sub("fogccc_shadow.c",
    """    /* No full-window clear: every header word and every reference terminator is
       written below, and the engine only reads [0, obj_count). */
    base = (uint8_t *)dev.graph_vaddr;""",
    """    if (g_incr_mode) {
        incr_run(is_hard_marked, &dev, !g_ready);
        g_ready = 1;
        fpga_gc_close(&dev);
        free(cnt); free(start); free(cur);
        return;
    }

    /* No full-window clear: every header word and every reference terminator is
       written below, and the engine only reads [0, obj_count). */
    base = (uint8_t *)dev.graph_vaddr;""")

# fixed reference base when the table will grow across collections
sub("fogccc_shadow.c",
    "    ref_base = (((uint32_t)g_nobj * 16u) + 0xFFFu) & ~0xFFFu;",
    """    ref_base = g_incr_mode ? (MAX_OBJ * 16u)
                           : ((((uint32_t)g_nobj * 16u) + 0xFFFu) & ~0xFFFu);""")

# remember the arena end and mark the table ready after the full export
sub("fogccc_shadow.c",
    """    t_write = now_us();

    /* Optional dump of exactly what was written into the window, so a host""",
    """    t_write = now_us();
    g_ref_base = ref_base;
    g_arena_off = off;
    g_ready = 1;
    cards_clear();

    /* Optional dump of exactly what was written into the window, so a host""")

sub("fogccc_shadow.c",
    """void fogccc_shadow_edge(Object *from, Object *to, int hard) {
    int f, t;

    if (state() < 0 || g_done || !hard || to == NULL)
        return;""",
    """void fogccc_shadow_edge(Object *from, Object *to, int hard) {
    int f, t;

    /* After the first full export the dirty cards describe what changed, so
       the mark hooks must not rebuild the whole edge list again. */
    if (state() < 0 || g_done || g_incr_mode || !hard || to == NULL)
        return;""")

# class metadata holds references that no object body contains: static fields,
# resolved constant-pool objects and InvokeDynamic appendices.  Feed them as
# roots (statics are roots; the others stay live while the class is loaded).
sub("alloc.c",
    """                Object *ob = fb->u.static_value.p;
                TRACE_GC("Field %s %s object @%p\\n", fb->name, fb->type, ob);
                if(ob != NULL && mark > IS_MARKED(ob))
                    MARK_AND_PUSH(ob, mark);""",
    """                Object *ob = fb->u.static_value.p;
                TRACE_GC("Field %s %s object @%p\\n", fb->name, fb->type, ob);
                if(ob != NULL)
                    fogccc_shadow_root(ob);
                if(ob != NULL && mark > IS_MARKED(ob))
                    MARK_AND_PUSH(ob, mark);""")

sub("alloc.c",
    """            TRACE_GC("Resolved object @ constant pool idx %d type %d @%p\\n",
                     i, type, ob);
            if(ob != NULL && mark > IS_MARKED(ob))
                MARK_AND_PUSH(ob, mark);""",
    """            TRACE_GC("Resolved object @ constant pool idx %d type %d @%p\\n",
                     i, type, ob);
            if(ob != NULL)
                fogccc_shadow_root(ob);
            if(ob != NULL && mark > IS_MARKED(ob))
                MARK_AND_PUSH(ob, mark);""")

sub("fogccc_shadow.c",
    "#define MAX_ROOTS   4096          /* roots are fed 256 at a time, bitmap kept */",
    "#define MAX_ROOTS   16384         /* roots are fed 256 at a time, bitmap kept */")

sub("alloc.c",
    """#define MARK_CLASSBLOCK_FIELD(cb, field, mark)           \\
    if(cb->field != NULL && mark > IS_MARKED(cb->field)) \\
        MARK_AND_PUSH(cb->field, mark)""",
    """#define MARK_CLASSBLOCK_FIELD(cb, field, mark)           \\
    if(cb->field != NULL)                                \\
        fogccc_shadow_root(cb->field);                   \\
    if(cb->field != NULL && mark > IS_MARKED(cb->field)) \\
        MARK_AND_PUSH(cb->field, mark)""")

sub("alloc.c",
    """void markClassData(Class *class, int mark) {
    ClassBlock *cb = CLASS_CB(class);
    ConstantPool *cp = &cb->constant_pool;""",
    """void markClassData(Class *class, int mark) {
    ClassBlock *cb = CLASS_CB(class);
    ConstantPool *cp = &cb->constant_pool;

    /* A loaded class and its reflection data stay live; feed the Class object
       as a root so the hardware reaches that metadata closure too. */
    fogccc_shadow_root((Object *)class);""")

sub("alloc.c",
    """void markClassData(Class *class, int mark) {""",
    """/* Enumerate the references a Class object owns outside its instance body:
   classlib class-block fields, static fields, resolved constant-pool objects
   and InvokeDynamic appendices.  Used by the walk-based exporter. */
uint64_t g_cref_calls;
uint64_t g_cref_nullclass;

void fogccc_class_refs(Object *class_ob, void (*emit)(Object *, Object *)) {
    Class *class = (Class *)class_ob;
    ClassBlock *cb;
    ConstantPool *cp;
    FieldBlock *fb;
    int i;

    g_cref_calls++;
    if (class_ob == NULL || class_ob->class == NULL) {
        g_cref_nullclass++;
        return;
    }
    cb = CLASS_CB(class);
    if (cb == NULL || cb->name == NULL || cb->name[0] == '\\0')
        return;
    /* A class captured while it is still being initialised can have a bogus
       constant-pool count or field table; walking those would fault. */
    if (cb->state < CLASS_LINKED)
        return;
    if (cb->constant_pool_count <= 0 || cb->constant_pool_count > 65535)
        return;
    if (cb->fields_count < 0 || cb->fields_count > 65535)
        return;
    cp = &cb->constant_pool;
    fb = cb->fields;

    if (getenv("FOGCCC_CLASSDBG") != NULL) {
        static int calls;

        if (calls < 8) {
            calls++;
            printf("[FOGCCC] class_refs %s state=%d pd=%p cl=%p hc=%p sg=%p\\n",
                   cb->name, cb->state, (void *)cb->protection_domain,
                   (void *)cb->class_loader, (void *)cb->host_class,
                   (void *)cb->signers);
        }
    }

    /* OpenJDK 8 classlib class-block refs: protection_domain, class_loader,
       host_class, signers.  Hand-rolling only the first and last left every
       class's loader unreachable in the hardware graph (604 missed objects on
       DaCapo xalan). */
#define FOGCCC_CB_EMIT(ccb, field, ...) \
    if ((ccb)->field != NULL) emit(class_ob, (Object *)(ccb)->field)
    CLASSLIB_CLASSBLOCK_REFS_DO(FOGCCC_CB_EMIT, cb);
#undef FOGCCC_CB_EMIT

    if (cb->state >= CLASS_LINKED)
        for (i = 0; i < cb->fields_count; i++, fb++)
            if ((fb->access_flags & ACC_STATIC) &&
                ((*fb->type == 'L') || (*fb->type == '['))) {
                Object *ob = fb->u.static_value.p;
                if (ob != NULL)
                    emit(class_ob, ob);
            }

    for (i = 1; i < cb->constant_pool_count; i++) {
        int type = CP_TYPE(cp, i);

        if (type >= CONSTANT_ResolvedString) {
            Object *ob;

            if (type == CONSTANT_ResolvedPolyMethod)
                ob = ((PolyMethodBlock *)CP_INFO(cp, i))->appendix;
            else
                ob = (Object *)CP_INFO(cp, i);
            if (ob != NULL)
                emit(class_ob, ob);
        } else if (type == CONSTANT_ResolvedInvokeDynamic) {
            ResolvedInvDynCPEntry *entry = (ResolvedInvDynCPEntry *)CP_INFO(cp, i);
            InvDynMethodBlock *idmb;

            for (idmb = entry->idmb_list; idmb != NULL; idmb = idmb->next)
                if (idmb->appendix != NULL)
                    emit(class_ob, idmb->appendix);
        }
    }
}

void markClassData(Class *class, int mark) {""")

sub("fogccc_shadow.h",
    "int  fogccc_live_reason(Object *ob);",
    """int  fogccc_live_reason(Object *ob);
void fogccc_class_refs(Object *class_ob, void (*emit)(Object *, Object *));
void fogccc_loader_classes(Object *loader, void (*emit)(Object *, Object *));""")

sub("fogccc_shadow.c",
    "#define RING_MAX     65536",
    "#define RING_MAX     262144")

sub("fogccc_shadow.h",
    "int  fogccc_live_reason(Object *ob);",
    """int  fogccc_live_reason(Object *ob);
void fogccc_reference_refs(Object *ob, void (*emit)(Object *, Object *));""")

sub("alloc.c",
    """void fogccc_class_refs(Object *class_ob, void (*emit)(Object *, Object *)) {""",
    """/* Reference objects keep their referent outside the normal field table.
   Emit it when JamVM hard-marked it (shadow: identical to the software mark)
   or, in takeover, when it is a SOFT reference: JamVM's marks are cleared
   before that export, so the hard-mark test can never see the referent and
   the whole subtree behind a SoftReference (java.lang.Class.reflectionData
   is one) would be orphaned. */
void fogccc_reference_refs(Object *ob, void (*emit)(Object *, Object *)) {
    ClassBlock *cb = CLASS_CB(ob->class);

    if (IS_REFERENCE(cb)) {
        Object *referent = INST_DATA(ob, Object*, ref_referent_offset);

        if (referent != NULL &&
            (IS_HARD_MARKED(referent) ||
             (fogccc_ref_emit_all && IS_SOFT_REFERENCE(cb))))
            emit(ob, referent);
    }
}

void fogccc_class_refs(Object *class_ob, void (*emit)(Object *, Object *)) {""")

# ---------------------------------------------------------------- takeover import
sub("alloc.c",
    "static int fogccc_is_hard_marked(Object *ob) {",
    """/* Takeover: write the hardware bitmap back into JamVM's mark bits. */
/* A conservative root can be an address just outside the heap (or an interior
   pointer).  markbits is indexed from heapbase, so an address below it would
   write far outside the array and corrupt the allocator; an address above
   heaplimit would do the same.  Out-of-range marks are dropped. */
static int mark_addr_ok(Object *ob) {
    char *p = (char *)ob;

    return p >= heapbase && p < heaplimit;
}

void fogccc_set_hard_mark(Object *ob) {
    if (mark_addr_ok(ob))
        SET_MARK(ob, HARD_MARK);
}
void fogccc_clear_all_marks(void) { clearMarkBits(); }
int  fogccc_get_mark(Object *ob) {
    return mark_addr_ok(ob) ? IS_MARKED(ob) : 0;
}
int  fogccc_get_hard(Object *ob) {
    return mark_addr_ok(ob) ? IS_HARD_MARKED(ob) : 0;
}

int fogccc_count_hard_marks(void) {
    char *p;
    int n = 0;

    for (p = heapbase; p < heaplimit; ) {
        uintptr_t hdr = HEADER(p);
        uintptr_t size;

        if (HDR_ALLOCED(hdr)) {
            size = HDR_SIZE(hdr);
            if (IS_HARD_MARKED((Object *)(p + HEADER_SIZE)))
                n++;
        } else
            size = HDR_SIZE(hdr);
        p += size;
    }
    return n;
}

/* Debug: run the software mark on top of the imported marks and return how
   many extra objects it had to mark (0 = the hardware closure was complete). */
#define FOGCCC_VERIFY_MAX 1048576
static unsigned char g_vpre[FOGCCC_VERIFY_MAX];

static void verify_pre(Object *ob) {
    int id = fogccc_obj_id(ob);

    if (id >= 0 && id < FOGCCC_VERIFY_MAX && IS_HARD_MARKED(ob))
        g_vpre[id] = 1;
}

static int g_vextra;

/* Diagnostic: find the real owners of `target` on the heap side, so we can
   tell a missing arena edge from a missing root. */
static void fogccc_heap_find_parents(Object *target) {
    char *p;
    int found = 0;

    for (p = heapbase; p < heaplimit; ) {
        uintptr_t hdr = HEADER(p);
        uintptr_t size;

        if (HDR_ALLOCED(hdr)) {
            Object *ob = (Object *)(p + HEADER_SIZE);
            Class *cl = ob->class;

            size = HDR_SIZE(hdr);
            if (cl != NULL) {
                ClassBlock *cb = CLASS_CB(cl);

                if (cb->name[0] == '[') {
                    if (cb->name[1] == 'L' || cb->name[1] == '[') {
                        Object **body = ARRAY_DATA(ob, Object*);
                        int len = ARRAY_LEN(ob), i;

                        for (i = 0; i < len; i++)
                            if (body[i] == target) {
                                if (found < 8)
                                    printf("[FOGCCC] heap parent %p id=%d (array[%d])\\n",
                                           (void *)ob, fogccc_obj_id(ob), i);
                                found++;
                            }
                    }
                } else {
                    int i;

                    for (i = 0; i < cb->refs_offsets_size; i++) {
                        int o = cb->refs_offsets_table[i].start;
                        int e = cb->refs_offsets_table[i].end;

                        for (; o < e; o += sizeof(Object*))
                            if (INST_DATA(ob, Object*, o) == target) {
                                if (found < 8)
                                    printf("[FOGCCC] heap parent %p id=%d (field %d)\\n",
                                           (void *)ob, fogccc_obj_id(ob), o);
                                found++;
                            }
                    }
                }
            }
        } else
            size = HDR_SIZE(hdr);
        p += size;
    }
    printf("[FOGCCC] heap parents of %p: %d\\n", (void *)target, found);
}

static void verify_post(Object *ob) {
    int id = fogccc_obj_id(ob);

    if (id >= 0 && id < FOGCCC_VERIFY_MAX && IS_HARD_MARKED(ob) && !g_vpre[id]) {
        if (g_vextra < 8) {
            ClassBlock *cb = ob->class ? CLASS_CB(ob->class) : NULL;

            printf("[FOGCCC] verify: extra id=%d cls=%s ptr=%p hw=%d g_obj=%p\\n",
                   id, cb ? cb->name : "?", ob, fogccc_hw_mark(id),
                   fogccc_obj_ptr(id));
            if (g_vextra == 0) {
                fogccc_arena_find_parents(id);
                fogccc_heap_find_parents(ob);
            }
            if (g_vextra < 4) {
                printf("[FOGCCC] verify: root_has id=%d root_id=%d ptr=%p\\n",
                       id, fogccc_root_id_of(ob), (void *)ob);
                fogccc_meta_find_parents(ob);
            }
        }
        g_vextra++;
    }
}

int fogccc_verify_marks(int mark_soft) {
    int before = fogccc_count_hard_marks();
    int after, extra;

    memset(g_vpre, 0, sizeof(g_vpre));
    fogccc_scan_range((Object *)(heapbase + sizeof(uintptr_t)), heaplimit, verify_pre);
    scanHeapAndMark(mark_soft);
    after = fogccc_count_hard_marks();
    extra = after - before;
    printf("[FOGCCC] verify: before=%d after=%d extra=%d\\n", before, after, extra);
    if (extra > 0) {
        g_vextra = 0;
        fogccc_scan_range((Object *)(heapbase + sizeof(uintptr_t)), heaplimit, verify_post);
        printf("[FOGCCC] verify: extra=%d listed=%d\\n", extra, g_vextra);
    }
    return extra;
}

static int fogccc_is_hard_marked(Object *ob) {""")

sub("fogccc_shadow.h",
    "void fogccc_class_refs(Object *class_ob, void (*emit)(Object *, Object *));",
    """void fogccc_class_refs(Object *class_ob, void (*emit)(Object *, Object *));
void fogccc_loader_classes(Object *loader, void (*emit)(Object *, Object *));
void fogccc_set_hard_mark(Object *ob);
void fogccc_clear_all_marks(void);
int  fogccc_get_mark(Object *ob);
int  fogccc_get_hard(Object *ob);
/* Id reclamation: called by gc0() between doMark() and doSweep(). */
int  fogccc_id_reclaim(void);
int  fogccc_id_high(void);
int  fogccc_id_live(void);
int  fogccc_id_free_count(void);
void fogccc_cards_clear(void);
extern uint64_t fogccc_reclaim_us;
extern int      fogccc_reclaim_freed;
extern uint64_t fogccc_gc_stw_t0;
void fogccc_report_stw(void);
int  fogccc_obj_has_id(Object *ob);
int  fogccc_obj_id(Object *ob);
void fogccc_arena_find_parents(int target);
void fogccc_meta_find_parents(Object *target);
int  fogccc_root_has(Object *ob);
int  fogccc_root_id_of(Object *ob);
int  fogccc_hw_mark(int id);
void *fogccc_obj_ptr(int id);""")

# ---------------------------------------------------------------- import check
sub("fogccc_shadow.c",
    """    printf("[FOGCCC] timing us: collect=%llu layout=%llu initwrite=%llu mark=%llu compare=%llu total=%llu\\n",""",
    """    if (getenv("FOGCCC_IMPORT_CHECK") != NULL) {
        int imp_bad = 0;
        uint32_t wbuf2[256];
        int bi, wi, k, nw;

        /* Clear JamVM's marks and rebuild them from the hardware bitmap. */
        fogccc_clear_all_marks();
        for (bi = 0; bi < g_nobj; bi += 256 * 32) {
            nw = (g_nobj - bi + 31) / 32;
            if (nw > 256)
                nw = 256;
            if (fpga_gc_read_mark_words(&dev, (uint32_t)(bi >> 5), wbuf2, nw) != 0)
                break;
            for (wi = 0; wi < nw; wi++)
                for (k = 0; k < 32; k++) {
                    int idx = bi + wi * 32 + k;

                    if (idx >= g_nobj)
                        break;
                    if ((wbuf2[wi] >> k) & 1u)
                        fogccc_set_hard_mark(g_obj[idx]);
                }
        }
        /* Verify the imported marks against the bitmap itself. */
        for (bi = 0; bi < g_nobj; bi += 256 * 32) {
            nw = (g_nobj - bi + 31) / 32;
            if (nw > 256)
                nw = 256;
            if (fpga_gc_read_mark_words(&dev, (uint32_t)(bi >> 5), wbuf2, nw) != 0)
                break;
            for (wi = 0; wi < nw; wi++)
                for (k = 0; k < 32; k++) {
                    int idx = bi + wi * 32 + k;
                    int h;

                    if (idx >= g_nobj)
                        break;
                    h = (int)((wbuf2[wi] >> k) & 1u);
                    if ((fogccc_get_mark(g_obj[idx]) ? 1 : 0) != h)
                        imp_bad++;
                }
        }
        printf("[FOGCCC] import check: mismatches=%d\\n", imp_bad);
    }

    printf("[FOGCCC] timing us: collect=%llu layout=%llu initwrite=%llu mark=%llu compare=%llu total=%llu\\n",""")

sub("alloc.c",
    """    scanHeapAndMark(mark_soft_refs);

    /* FOGCCC: export the marked graph and compare with the FPGA engine */
    fogccc_shadow_run(fogccc_is_hard_marked);""",
    """    if (fogccc_takeover_active()) {
        /* Production path: the hardware marks, the bitmap is imported into
           JamVM's mark bits, and sweep/finalizers run on that result.
           A 0 return means the side table was incomplete (ring/id/arena
           overflow): run JamVM's own mark instead of trusting the bitmap. */
        if (!fogccc_shadow_takeover(mark_soft_refs,
                                    getenv("FOGCCC_TAKEOVER_VERIFY") != NULL)) {
            uint64_t t_sm = fogccc_now_us();

            scanHeapAndMark(mark_soft_refs);
            fogccc_note_sw_mark(fogccc_now_us() - t_sm);
        }
    } else {
        uint64_t t_sm = fogccc_now_us();

        scanHeapAndMark(mark_soft_refs);
        fogccc_note_sw_mark(fogccc_now_us() - t_sm);

        /* FOGCCC: export the marked graph and compare with the FPGA engine */
        fogccc_shadow_run(fogccc_is_hard_marked);
    }""")

sub("fogccc_shadow.h",
    "int  fogccc_get_mark(Object *ob);",
    """int  fogccc_get_mark(Object *ob);
int  fogccc_get_hard(Object *ob);
int  fogccc_count_hard_marks(void);
int  fogccc_verify_marks(int mark_soft);
uint64_t fogccc_now_us(void);
void fogccc_note_sw_mark(uint64_t us);
void fogccc_note_clear(uint64_t us);
uint64_t fogccc_clear_us(void);
int  fogccc_takeover_active(void);
/* Returns 1 when the hardware bitmap was imported.  0 means "fall back to
   JamVM's own mark": the side table was incomplete (ring/arena/id overflow),
   so the hardware closure cannot be trusted. */
int  fogccc_shadow_takeover(int mark_soft, int verify);""")

sub("fogccc_shadow.c",
    "    if (g_incr_mode) {\n        incr_run(is_hard_marked, &dev, !g_ready);",
    "    if (g_incr_mode) {\n        incr_run(is_hard_marked, &dev, !g_ready);")

sub("fogccc_shadow.c",
    "void fogccc_shadow_run(int (*is_hard_marked)(Object *)) {",
    """static void root_emit(Object *from, Object *to) {
    (void)from;
    if (to != NULL && fogccc_object_alloced(to))
        fogccc_shadow_root(to);
}

static int takeover_on(void) {
    const char *e = getenv("FOGCCC_TAKEOVER");

    return e != NULL && e[0] != '\\0' && e[0] != '0';
}

/* FOGCCC_TAKEOVER_DECIDE=0 disables the shape/cost decision (always run the
   hardware once the side table exists). */
static int takeover_decide_on(void) {
    const char *e = getenv("FOGCCC_TAKEOVER_DECIDE");

    return e == NULL || e[0] == '\\0' || e[0] != '0';
}


int fogccc_takeover_active(void) {
    /* FOGCCC_TAKEOVER_COLD lets the very first collection go straight to the
       takeover (the cold full walk handles the empty side table).  Needed for
       short benchmarks that collect only once. */
    return state() > 0 && takeover_on() &&
           (g_ready || getenv("FOGCCC_TAKEOVER_COLD") != NULL);
}

/* Set when the side table can no longer represent the heap (ring/id/arena
   overflow).  Offloading is then disabled for the rest of the process; the
   CPU mark stays correct, just slower. */
static int g_takeover_dead;

/* Production path: no JamVM mark.  Export the dirty ring + class metadata,
   run the engine, then import the bitmap into JamVM's mark bits.
   Returns 1 on success, 0 when the caller must run the CPU mark instead. */
int fogccc_shadow_takeover(int mark_soft, int verify) {
    fpga_gc_t dev;
    uint8_t *base;
    uint32_t cycles = 0;
    int pass, i, extra = -1, cold, rebuilt = 0;
    uint64_t t_imp;

    if (state() <= 0 || g_takeover_dead)
        return 0;
    /* Liveness oracle for the id reclaim at the end of this GC: only a bitmap
       imported in this round (and not extended by verify) can be used. */
    g_imp_this_round = 0;
    g_imp_verified = verify;
    if (g_ready && g_ring_ovf != 0) {
        /* The cycle's dirty set is incomplete.  Repair the side table with a
           full walk filtered by the previous collection's live set. */
        if (!g_live_valid && !fogccc_waslive_valid()) {
            g_takeover_dead = 1;
            cards_clear();
            printf("[FOGCCC] takeover: dirty ring overflow, CPU fallback for this process\\n");
            return 0;
        }
        printf("[FOGCCC] takeover: dirty ring overflow -> full live walk\\n");
        g_force_walk = 1;
    }
    /* Decision from the previous epoch's real numbers.  The first takeover has
       the shadow round behind it: shape only (its export was a full walk).
       Later epochs add the cost term: the adapter overhead must stay below the
       hardware mark, otherwise the CPU mark wins. */
    if (g_ep_valid && takeover_decide_on()) {
        printf("[FOGCCC] takeover decide: sw=%llu exp=%u mark=%u imp=%u "
               "full=%d streak=%d\\n",
               (unsigned long long)g_sw_mark_us, g_ep_exp, g_ep_mark,
               g_ep_imp, g_ep_full, g_cpu_streak);
    }
    if (g_ep_valid && g_sw_mark_us != 0 && g_cpu_streak < 4 &&
        takeover_decide_on()) {
        uint64_t hw = (uint64_t)g_ep_exp + g_ep_mark + g_ep_imp;
        uint64_t sw = g_sw_mark_us;

        if (g_ep_full)
            hw = g_ep_mark;   /* shadow round: its export was a full walk */
        if (hw * 100u >= sw * 95u) {   /* hardware must be >=5% cheaper */
            g_cpu_streak++;
            printf("[FOGCCC] takeover: CPU chosen (hw=%llu sw=%llu mark=%u "
                   "q_hi=%u/%u)\\n",
                   (unsigned long long)hw, (unsigned long long)sw,
                   g_ep_mark, g_ep_q_hi, g_ep_cycles);
            return 0;
        }
    }
    g_cpu_streak = 0;
    if (fpga_gc_init(&dev) != 0)
        return 0;

    base = (uint8_t *)dev.graph_vaddr;
    g_exp_base = stage_get(base);
    g_exp_paddr = dev.graph_paddr;
    g_exp_count = 0;
    g_exp_ovf = 0;
    g_round_refs = 0;
    g_cref_calls = 0;
    g_cref_nullclass = 0;

    fogccc_heap_dbg("takeover");
    cold = !g_ready;
    g_arena_start = g_arena_off;
    g_arena2_start = g_arena2_off = 0;
    /* The main thread is single-threaded from here on: exp_worker2() narrows
       this per worker and must not leak its half-region limit into the ring
       export (that produced a spurious "side table overflow"). */
    g_exp_limit = (uint32_t)GRAPH_MAP_SIZE;
    g_hdr_lo = 0xFFFFFFFFu;
    g_hdr_hi = 0;
    g_wr_n = 0;
    g_wr_ovf = 0;
    t_init = now_us();
    if (getenv("FOGCCC_ALWAYS_REBUILD") != NULL ||
        fogccc_meta_pending() ||
        g_force_walk || g_full_nobj == 0 ||
        (g_live_valid && g_full_heap != 0 &&
         fogccc_heap_size() > g_full_heap + g_full_heap / 4) ||
        (g_live_valid && g_nobj > 0 && (int)g_ring_n > g_nobj / 20)) {
        /* Cold process, dirty-ring overflow, a heap that grew ~25%, or a dirty
           set too large for the incremental side table: rebuild the arena from
           the heap.  Export every allocated block, not only the previous
           round's marked set: an object that was unmarked last round can be
           live now (the ring may have lost the edge that made it live), and
           skipping it drops all of its outgoing edges.  Unreachable blocks are
           exported too, but the engine only traverses what the roots reach, so
           they cannot add marks -- they only cost arena space.
           The id table is reset first: the rebuild rewrites every header, so
           ids only have to be unique within this round.  Roots were recorded
           as ids before the reset, so re-derive them from the object pointers
           (without the reset the table fills with garbage ids and the offload
           dies at MAX_OBJ on a 1M-object heap). */
        id_reset();
        idmap_ensure();
        for (i = 0; i < g_nroots; i++)
            g_roots[i] = (uint32_t)id_of(g_root_objs[i], 1);
        /* Roots are live by definition; keep them even if they were garbage at
           the end of the previous collection (a stack slot can legally be the
           only reference, and the previous round's bitmap cannot see it). */
        fogccc_waslive_rebase();
        for (i = 0; i < g_nroots; i++)
            if (g_root_objs[i] != NULL)
                fogccc_waslive_mark(g_root_objs[i]);
        g_nclass = 0;
        g_arena2_off = 0;
        {
            /* Two workers, split on a block boundary.  Each owns a disjoint
               arena region; header writes are disjoint by id. */
            char *hb = g_heap_lo;
            char *he = fogccc_heap_end();
            char *split = fogccc_split_by_count();
            exp_job2_t ja, jb;
            pthread_t th;
            int two = 0;
            uint64_t t_w0 = now_us();

            ja.lo = hb;
            ja.hi = he;
            ja.arena_base = (uint32_t)MAX_OBJ * 16u;
            jb.lo = he;
            jb.hi = he;
            jb.arena_base = 0;
            if (split > hb && split < he) {
                jb.lo = split;
                jb.hi = he;
                jb.arena_base = (uint32_t)MAX_OBJ * 16u + EXP_REGION;
                ja.hi = split;
                if (pthread_create(&th, NULL, exp_worker2, &jb) == 0) {
                    two = 1;
                } else {
                    ja.hi = he;     /* no thread: walk everything here */
                    jb.arena_base = 0;
                }
            }
            exp_worker2(&ja);
            if (two)
                pthread_join(th, NULL);

            g_walk_us = now_us() - t_w0;

            g_arena_start = (uint32_t)MAX_OBJ * 16u;
            g_arena_off = ja.arena_off;
            g_hdr_lo = ja.hdr_lo;
            g_hdr_hi = ja.hdr_hi;
            g_exp_count = ja.count;
            g_exp_ovf = ja.ovf;
            g_round_refs = ja.refs;
            g_wr_ovf = ja.wr_ovf;
            if (two) {
                if (jb.arena_off > g_arena_off)
                    g_arena_off = jb.arena_off;
                if (jb.count != 0) {
                    if (g_exp_count == 0 || jb.hdr_lo < g_hdr_lo)
                        g_hdr_lo = jb.hdr_lo;
                    if (jb.hdr_hi > g_hdr_hi)
                        g_hdr_hi = jb.hdr_hi;
                }
                g_exp_count += jb.count;
                g_exp_ovf += jb.ovf;
                g_round_refs += jb.refs;
                g_wr_ovf |= jb.wr_ovf;
                if (jb.arena_off > jb.arena_base)
                    g_arena2_start = jb.arena_base;
                else
                    g_arena2_start = 0;
                g_arena2_off = jb.arena_off;
            }
        }
        printf("[FOGCCC] takeover rebuild walk: classes=%d objects=%d heap=%u cref=%llu nullcls=%llu\\n",
               g_nclass, g_exp_count, (unsigned)fogccc_heap_size(),
               (unsigned long long)g_cref_calls,
               (unsigned long long)g_cref_nullclass);
        g_force_walk = 0;
        g_full_nobj = g_nobj;
        g_full_heap = fogccc_heap_size();
        rebuilt = 1;
        /* The walk just exported the current class metadata; anything the
           mutator flags from now on is for the next round. */
        fogccc_meta_clear();    } else if (getenv("FOGCCC_FULL_EXPORT") != NULL) {
        /* Debug/safe mode: rebuild the whole side table every round.
           NOT usable in production: fogccc_scan_all walks every allocated
           block, including garbage that has not been swept yet, and in
           takeover mode JamVM's mark bits are not a live oracle. */
        g_nclass = 0;
        g_arena_off = (uint32_t)MAX_OBJ * 16u;
        g_arena_start = g_arena_off;
        fogccc_scan_all((Object *)(g_heap_lo + sizeof(uintptr_t)),
                        fogccc_heap_end(), export_one);
        printf("[FOGCCC] takeover full walk: classes=%d objects=%d\\n",
               g_nclass, g_exp_count);
    } else if (getenv("FOGCCC_SMP_EXPORT") != NULL && smp_export(base) == 0) {
        /* dirty ring exported by two threads */
    } else {
        int newid = 0;

        g_ring_export = 1;
        if (getenv("FOGCCC_SKIP_RING") == NULL)
        for (i = 0; i < (int)g_ring_n; i++) {
            Object *ob;
            int had, id0;

            /* A ring record is an offset; never dereference one that is not
               inside the heap (a stale record would fault). */
            ob = (Object *)(uintptr_t)g_ring[i];
            had = fogccc_obj_has_id(ob);
            id0 = fogccc_obj_id(ob);

            if (ob->class == NULL)
                continue;
            export_one(ob);
            if (!had)
                newid++;
            if (i < 8)
                printf("[FOGCCC] ring exp off=%u had=%d id=%d now=%d\\n",
                       g_ring[i], had, id0, fogccc_obj_id(ob));
        }
        printf("[FOGCCC] ring: n=%u new_id=%d\\n", g_ring_n, newid);
        g_ring_export = 0;
    }
    printf("[FOGCCC] heap lo=%p bytes=%u nobj=%d\\n", g_heap_lo, (unsigned)fogccc_heap_size(), g_nobj);
    /* Resolved constant pools added edges since the last round.  Re-export
       just those classes (a handful) instead of rebuilding the whole arena. */
    if (g_cp_n > 0) {
        int n = g_cp_n, k;

        if (n > CP_CLASS_MAX)
            n = CP_CLASS_MAX;
        printf("[FOGCCC] cp classes: %d\\n", n);
        for (k = 0; k < n; k++) {
            Object *c = g_cp_classes[k];

            if (c != NULL && fogccc_object_alloced(c) && cls_ok(c)) {
                if (getenv("FOGCCC_CPDBG") != NULL)
                    printf("[FOGCCC] cp export %p %s id=%d\\n", (void *)c,
                           CLASS_CB(c)->name, id_of(c, 0));
                export_one(c);
            } else if (getenv("FOGCCC_CPDBG") != NULL) {
                ClassBlock *cb = CLASS_CB(c);

                printf("[FOGCCC] cp skip %p alloc=%d name=%p state=%d band=[%p,%p)\\n",
                       (void *)c, fogccc_object_alloced(c),
                       cb != NULL ? (void *)cb->name : NULL,
                       cb != NULL ? cb->state : -1,
                       (void *)fogccc_heap_base(),
                       (void *)(fogccc_heap_base() + fogccc_heap_max_size()));
            }
        }
        g_cp_n = 0;
    }
    printf("[FOGCCC] stage after-ring\\n");
    printf("[FOGCCC] stage after-newcls (%d)\\n", g_nnew_classes);
    /* Class metadata changes at run time (lazily resolved constant-pool
       strings, statics written without a barrier).  Re-exporting every class
       here would refresh those edges, but a swept/reused ClassBlock makes the
       metadata walk fault at the mmap base (measured), so it stays off until
       the ClassBlock can be validated cheaply.  Consequence: an incremental
       round can miss the objects behind a newly resolved constant (4 objects
       at 1M); a rebuild round (ring overflow / heap growth / cold) is exact. */
    if (getenv("FOGCCC_TAKEOVER_DEBUG") != NULL) {
        ClassBlock *fmut = NULL;
        int ci, k;

        for (ci = 0; ci < g_nclass; ci++) {
            ClassBlock *cb = CLASS_CB((Class *)g_class_objs[ci]);

            if (cb->name != NULL && strcmp(cb->name, "FogcccMutate") == 0) {
                fmut = cb;
                break;
            }
        }
        printf("[FOGCCC] dbg class=%s fields=%d roots=%d\\n",
               fmut != NULL ? "FOUND" : "MISSING",
               fmut != NULL ? fmut->fields_count : -1, g_nroots);
        if (fmut != NULL) {
            FieldBlock *fb = fmut->fields;

            for (k = 0; k < fmut->fields_count; k++, fb++) {
                if ((fb->access_flags & ACC_STATIC) &&
                    (*fb->type == 'L' || *fb->type == '[')) {
                    Object *o = fb->u.static_value.p;
                    int oid = o != NULL ? id_of(o, 0) : -1;
                    uint32_t *h = oid >= 0 ?
                        (uint32_t *)(base + (uint32_t)oid * 16u) : NULL;
                    int ri, inroot = 0;

                    for (ri = 0; ri < g_nroots; ri++)
                        if ((int)g_roots[ri] == oid) {
                            inroot = 1;
                            break;
                        }
                    printf("[FOGCCC] dbg static %s %s ob=%p id=%d "
                           "cnt=%d ptr=%08x inroot=%d\\n",
                           fb->name, fb->type, (void *)o, oid,
                           h != NULL ? (int)h[1] : -1,
                           h != NULL ? h[2] : 0u, inroot);
                }
            }
        }
    }
    if (getenv("FOGCCC_FORCE_EXP_OVF") != NULL)
        g_exp_ovf = 1;    /* negative control for the side-table guard */
    if (g_exp_ovf != 0 || g_nobj >= MAX_OBJ) {
        /* More allocated blocks than the 20-bit id space (the rebuild walk
           exports every block, including the garbage this collection is about
           to free).  Do not poison the process: run JamVM's own mark for this
           round -- its sweep then removes the garbage -- and rebuild the side
           table next round, when the heap is back near the live set.  The
           previous behaviour (CPU fallback for the rest of the process) turned
           one oversized round into "offload never runs" (lusearch at -Xms700m). */
        printf("[FOGCCC] takeover: side table overflow "
               "(objects=%d ref_ovf=%u), CPU mark for this round\\n",
               g_nobj, g_exp_ovf);
        cards_clear();
        g_force_walk = 1;          /* arena is partial: full rebuild next round */
        fpga_gc_close(&dev);
        return 0;
    }
    if (g_exp_ovf != 0) {
        /* Never run the engine on a truncated arena: the export overflowed the
           graph window, so the side table is incomplete and the closure would
           be wrong (and the sweep would free live objects). */
        g_takeover_dead = 1;
        printf("[FOGCCC] takeover: arena overflow (%u), CPU fallback for this "
               "process", g_exp_ovf);
        cards_clear();
        return 0;
    }
    {
        uint64_t t_f0 = now_us();

        stage_flush(base);
        g_flush_us = now_us() - t_f0;
    }
    t_write = now_us();
    cards_clear();

    dev.obj_count = (uint32_t)g_nobj;
    for (pass = 0; pass * ROOT_REGS < g_nroots; pass++) {
        int first = pass * ROOT_REGS;
        int n = g_nroots - first;
        uint32_t pc = 0;

        if (n > ROOT_REGS)
            n = ROOT_REGS;
        fpga_gc_set_roots(&dev, g_roots + first, n);
        if (pass == 0)
            (void)fpga_gc_mark(&dev, &pc);
        else
            (void)fpga_gc_mark_incremental(&dev, &pc);
        cycles += pc;
    }
    t_mkdone = now_us();
    printf("[FOGCCC] takeover decision: q_hi=%u q_hwm=%u cycles=%u cpu_pref=%d\\n",
           fpga_gc_q_hi(&dev), fpga_gc_q_hwm(&dev), dev.epoch_cycles,
           fpga_gc_prefer_cpu(&dev));

    fogccc_clear_all_marks();
    {
        static uint32_t bmbuf[32768];
        static uint32_t bmbuf2[32768];
        int nw = (g_nobj + 31) / 32;
        int idx;

        if (getenv("FOGCCC_IMPORT_PROBE") == NULL &&
            fpga_gc_dump_bitmap(&dev, bmbuf, nw) == 0) {
            /* One dump.  The earlier 4-way OR was a workaround for "lost
               dump words"; four dumps always agreed, so the loss was never in
               the dump -- it cost ~150-200 ms per round. */
            int diffs = 0;

            import_marked(base, bmbuf, g_nobj);
            g_imp_this_round = 1;
            /* Measured at 1M: a couple of bitmap words can stay 0 although
               their ids were fed as roots.  Re-feed only the roots whose bit
               the import does not see, in one kept pass, then merge a fresh
               dump.  If they are still missing the caller falls back to CPU
               (the verify below reports them). */
            {
                static uint32_t miss[MAX_ROOTS];
                int nm = 0, k;

                for (k = 0; k < g_nroots && nm < MAX_ROOTS; k++) {
                    uint32_t rid = g_roots[k];

                    if (rid < (uint32_t)g_nobj &&
                        !((bmbuf[rid >> 5] >> (rid & 31)) & 1u))
                        miss[nm++] = rid;
                }
                if (nm > 0) {
                    int still = 0;

                    printf("[FOGCCC] import: %d root bit(s) missing, retrying\\n", nm);
                    fpga_gc_set_roots(&dev, miss, nm);
                    (void)fpga_gc_mark_incremental(&dev, &cycles);
                    if (fpga_gc_dump_bitmap(&dev, bmbuf2, nw) == 0)
                        for (idx = 0; idx < nw; idx++)
                            bmbuf[idx] |= bmbuf2[idx];
                    import_marked(base, bmbuf, g_nobj);
                    for (k = 0; k < nm; k++)
                        if (!((bmbuf[miss[k] >> 5] >> (miss[k] & 31)) & 1u))
                            still++;
                    printf("[FOGCCC] import: retry left %d root bit(s) missing\\n",
                           still);
                }
                if (getenv("FOGCCC_IMPORT_STATS") != NULL) {
                    int inbm = 0, marked = 0, bad = 0;

                    for (k = 0; k < g_nobj; k++)
                        if ((bmbuf[k >> 5] >> (k & 31)) & 1u) {
                            inbm++;
                            if (fogccc_get_hard(g_obj[k]))
                                marked++;
                            else if (bad < 6) {
                                printf("[FOGCCC] import: id=%d bm=1 hard=0 val=%d ptr=%p\\n",
                                       k, fogccc_get_mark(g_obj[k]),
                                       (void *)g_obj[k]);
                                bad++;
                            }
                        }
                    printf("[FOGCCC] import: bm=%d hard=%d diff=%d count_now=%d\\n",
                           inbm, marked, inbm - marked,
                           fogccc_count_hard_marks());
                }
            }
            memcpy(g_live_bm, bmbuf, (size_t)nw * 4u);
            g_live_n = g_nobj;
            g_live_valid = 1;
            if (getenv("FOGCCC_ROOT_CHECK") != NULL) {
                /* Every root must be hard-marked after the import.  Print the
                   first offenders with their bitmap bit and address: this
                   separates "the engine never marked the root" (bit 0) from
                   "the import dropped the mark" (bit 1, hard 0). */
                int bad = 0, k;

                for (k = 0; k < g_nroots; k++) {
                    uint32_t rid = g_roots[k];
                    Object *ob = (rid < (uint32_t)g_nobj) ? g_obj[rid] : NULL;
                    int hard = (ob != NULL) ? fogccc_get_hard(ob) : -1;

                    if (hard == 1)
                        continue;
                    if (bad < 8)
                        printf("[FOGCCC] root check: k=%d id=%u ob=%p bit=%d "
                               "hard=%d hdr=%08x\\n", k, rid, (void *)ob,
                               (rid < (uint32_t)g_nobj) ?
                                   (int)((bmbuf[rid >> 5] >> (rid & 31)) & 1u) : -1,
                               hard,
                               (ob != NULL) ?
                                   *(uint32_t *)(base + (uint32_t)rid * 16u + 4u) : 0u);
                    bad++;
                }
                printf("[FOGCCC] root check: %d/%d roots not hard-marked\\n",
                       bad, g_nroots);
            }
        } else {
            /* Fall back to the AXI-Lite probe: slow (~190 ms) but correct. */
            uint32_t wbuf2[256];
            int bi, wi, k, nn;

            printf("[FOGCCC] takeover: bitmap dump failed, using probe\\n");
            for (bi = 0; bi < g_nobj; bi += 256 * 32) {
                nn = (g_nobj - bi + 31) / 32;
                if (nn > 256)
                    nn = 256;
                if (fpga_gc_read_mark_words(&dev, (uint32_t)(bi >> 5), wbuf2, nn) != 0)
                    break;
                for (wi = 0; wi < nn; wi++)
                    for (k = 0; k < 32; k++) {
                        int ii = bi + wi * 32 + k;

                        if (ii >= g_nobj)
                            break;
                        if ((wbuf2[wi] >> k) & 1u)
                            fogccc_set_hard_mark(g_obj[ii]);
                    }
            }
            g_live_valid = 0;   /* bitmap not captured on this path */
        }
        if (getenv("FOGCCC_TAKEOVER_DEBUG") != NULL) {
            ClassBlock *fmut = NULL;
            int ci;

            for (ci = 0; ci < g_nclass; ci++) {
                ClassBlock *cb = CLASS_CB((Class *)g_class_objs[ci]);

                if (cb->name != NULL && strcmp(cb->name, "FogcccMutate") == 0) {
                    fmut = cb;
                    break;
                }
            }
            if (fmut != NULL) {
                FieldBlock *fb = fmut->fields;
                int k;

                for (k = 0; k < fmut->fields_count; k++, fb++)
                    if ((fb->access_flags & ACC_STATIC) &&
                        (*fb->type == 'L' || *fb->type == '[') &&
                        strcmp(fb->name, "freshRoot") == 0 &&
                        fb->u.static_value.p != NULL) {
                        Object *o = fb->u.static_value.p;
                        int oid = id_of(o, 0);

                        if (oid >= 0) {
                            uint32_t *h = (uint32_t *)(base + (uint32_t)oid * 16u);
                            uint32_t soff = h[2] - g_exp_paddr;
                            int head = h[1] > 0 ?
                                (int)*(uint32_t *)(base + soff) : -1;
                            uint32_t hcnt = 0xDEADu, hptr = 0xDEADu;
                            uint32_t href0 = 0xDEADu;

                            if (head >= 0 && (uint32_t)head < (uint32_t)g_nobj) {
                                uint32_t *hh = (uint32_t *)(base +
                                                (uint32_t)head * 16u);

                                hcnt = hh[1];
                                hptr = hh[2];
                                if (hcnt > 0 && hcnt < 0x100000u)
                                    href0 = *(uint32_t *)(base +
                                             (hptr - g_exp_paddr));
                            }
                            printf("[FOGCCC] dbg hw fresh id=%d cnt=%d head=%d "
                                   "bit=%d hbit=%d hcnt=%u hptr=%08x "
                                   "href0=%u status=0x%X marked=%u\\n",
                                   oid, (int)h[1], head,
                                   (int)((bmbuf[oid >> 5] >> (oid & 31)) & 1u),
                                   head >= 0 ? (int)((bmbuf[head >> 5] >>
                                                      (head & 31)) & 1u) : -9,
                                   hcnt, hptr, href0,
                                   fpga_gc_status(&dev),
                                   dev.regs[REG_MARKED / 4]);
                            {
                                uint32_t pw0 = 0xDEADBEEFu, pw1 = 0xDEADBEEFu;
                                uint32_t nset = 0;
                                int wi, nw2 = (g_nobj + 31) / 32;

                                (void)fpga_gc_read_mark_words(&dev,
                                        (uint32_t)(oid >> 5), &pw0, 1);
                                if (head >= 0)
                                    (void)fpga_gc_read_mark_words(&dev,
                                            (uint32_t)(head >> 5), &pw1, 1);
                                for (wi = 0; wi < nw2; wi++)
                                    nset += (uint32_t)__builtin_popcount(
                                                bmbuf[wi]);
                                printf("[FOGCCC] dbg probe fresh=%08x "
                                       "head=%08x bmbits=%u objcnt=%u "
                                       "regmk=%u\\n",
                                       pw0, pw1, nset,
                                       dev.regs[REG_OBJ_COUNT / 4],
                                       dev.regs[REG_MARKED / 4]);
                            }
                            if (getenv("FOGCCC_TAKEOVER_PROBE") != NULL &&
                                head >= 0) {
                                static uint32_t pb[32768];
                                uint32_t ids[2];
                                int nw2 = (g_nobj + 31) / 32;
                                int run, wi;

                                ids[0] = (uint32_t)oid;
                                ids[1] = (uint32_t)head;
                                for (run = 0; run < 2; run++) {
                                    uint32_t pc2 = 0, nset2 = 0;
                                    uint32_t bself = 0, bh = 0;
                                    int ok;

                                    dev.obj_count = (uint32_t)g_nobj;
                                    fpga_gc_set_roots(&dev, &ids[run], 1);
                                    (void)fpga_gc_mark(&dev, &pc2);
                                    ok = fpga_gc_dump_bitmap(&dev, pb, nw2) == 0;
                                    if (ok) {
                                        for (wi = 0; wi < nw2; wi++)
                                            nset2 += (uint32_t)
                                                __builtin_popcount(pb[wi]);
                                        bself = (pb[ids[run] >> 5] >>
                                                 (ids[run] & 31)) & 1u;
                                        bh = (pb[head >> 5] >>
                                              (head & 31)) & 1u;
                                    }
                                    printf("[FOGCCC] dbg single-run=%d id=%u "
                                           "cycles=%u ok=%d bits=%u self=%u "
                                           "headbit=%u\\n",
                                           run, ids[run], pc2, ok, nset2,
                                           bself, bh);
                                }
                            }
                        }
                    }
            }
        }
    }
    t_imp = now_us();
    if (verify) {
        g_vdev = &dev;
        extra = fogccc_verify_marks(mark_soft);
        g_vdev = NULL;
    }
    t_cmp = now_us();

    printf("[FOGCCC] takeover: objects=%d exported=%d refs=%llu roots=%d classes=%d cycles=%u "
           "verify_extra=%d\\n",
           g_nobj, g_exp_count, (unsigned long long)g_round_refs,
           g_nroots, g_nclass, cycles, extra);
    printf("[FOGCCC] takeover timing us: export=%llu mark=%llu import=%llu verify=%llu clear=%llu walk=%llu flush=%llu\\n",
           (unsigned long long)(t_write - t_init),
           (unsigned long long)(t_mkdone - t_write),
           (unsigned long long)(t_imp - t_mkdone),
           (unsigned long long)(t_cmp - t_imp),
           (unsigned long long)fogccc_clear_us(),
           (unsigned long long)g_walk_us,
           (unsigned long long)g_flush_us);

    g_ready     = 1;
    g_ep_q_hi   = dev.epoch_q_hi;
    g_ep_cycles = dev.epoch_cycles;
    g_ep_exp    = (uint32_t)(t_write - t_init);
    g_ep_imp    = (uint32_t)(t_imp - t_mkdone);
    g_ep_mark   = (uint32_t)(t_mkdone - t_write);
    g_ep_full   = cold;
    g_ep_valid  = 1;

    fpga_gc_close(&dev);
    return 1;
}

void fogccc_shadow_run(int (*is_hard_marked)(Object *)) {""")

sub("fogccc_shadow.c",
    "/* Production path: no JamVM mark.",
    """/* ---- optional two-thread dirty-ring export (FOGCCC_SMP_EXPORT=1) ----
   The id table is shared: lookups are lock-free (an entry is published with a
   release barrier after g_obj is written), inserts take a spinlock.  Misses
   are rare because the full export already named every live object.  The
   arena and the headers are written by the calling thread only. */
#define SMP_REFS_MAX (1u << 21)     /* refs per worker */
#define SMP_PEND_MAX 4096

/* g_id_lock is declared next to the id map */

static int id_of_mt(Object *ob) {
    uint32_t h = hash_ptr(ob);
    int id;

    while (g_htab[h] != 0) {
        if (g_obj[g_htab[h] - 1] == ob)
            return g_htab[h] - 1;
        h = (h + 1) & (HASH_SIZE - 1);
    }
    while (__sync_lock_test_and_set(&g_id_lock, 1))
        ;
    h = hash_ptr(ob);
    while (g_htab[h] != 0) {
        if (g_obj[g_htab[h] - 1] == ob) {
            id = g_htab[h] - 1;
            __sync_lock_release(&g_id_lock);
            return id;
        }
        h = (h + 1) & (HASH_SIZE - 1);
    }
    if (g_nobj == MAX_OBJ) {
        __sync_lock_release(&g_id_lock);
        return -1;
    }
    id = g_nobj;
    g_obj[id] = ob;
    __sync_synchronize();          /* publish g_obj before the table slot */
    g_htab[h] = id + 1;
    g_nobj++;
    __sync_lock_release(&g_id_lock);
    return id;
}

typedef struct { uint32_t id, off, cnt; } exp_ent_t;

typedef struct {
    int lo, hi, ent_n, refs_n, pend_n, fail;
    uint32_t *refs;
    exp_ent_t ent[RING_MAX / 2 + 16];
    struct { uint32_t at; Object *to; } pend[SMP_PEND_MAX];
} exp_job_t;

static exp_job_t g_smp_job[2];
static uint32_t  g_smp_refs[2][SMP_REFS_MAX];
static __thread exp_job_t *g_job;

static void exp_emit(Object *from, Object *to) {
    exp_job_t *j = g_job;
    int id;

    (void)from;
    if (j == NULL || to == NULL)
        return;
    if (j->refs_n >= (int)SMP_REFS_MAX) { j->fail = 1; return; }
    id = id_of_mt(to);
    if (id < 0) { j->fail = 1; return; }
    j->refs[j->refs_n++] = (uint32_t)id;
}

static void exp_one(exp_job_t *j, Object *ob) {
    Class *class = ob->class;
    ClassBlock *cb;
    uint32_t off;
    int id, k;

    if (class == NULL)
        return;
    id = id_of_mt(ob);
    if (id < 0) { j->fail = 1; return; }
    cb = CLASS_CB(class);
    off = (uint32_t)j->refs_n;
    if (cb->name[0] == '[') {
        if (cb->name[1] == 'L' || cb->name[1] == '[') {
            Object **body = ARRAY_DATA(ob, Object*);
            int len = ARRAY_LEN(ob);

            for (k = 0; k < len; k++)
                exp_emit(ob, body[k]);
        }
    } else {
        for (k = 0; k < cb->refs_offsets_size; k++) {
            int o = cb->refs_offsets_table[k].start;
            int e = cb->refs_offsets_table[k].end;

            for (; o < e; o += sizeof(Object*))
                exp_emit(ob, INST_DATA(ob, Object*, o));
        }
        if (IS_CLASS_CLASS(cb))
            fogccc_class_refs(ob, exp_emit);
        if (IS_REFERENCE(cb))
            fogccc_reference_refs(ob, exp_emit);
    }
    if (j->ent_n >= (int)(RING_MAX / 2 + 16)) { j->fail = 1; return; }
    j->ent[j->ent_n].id = (uint32_t)id;
    j->ent[j->ent_n].off = off;
    j->ent[j->ent_n].cnt = (uint32_t)j->refs_n - off;
    j->ent_n++;
}

static void *exp_thread(void *arg) {
    exp_job_t *j = (exp_job_t *)arg;
    int i;

    g_job = j;
    for (i = j->lo; i < j->hi && !j->fail; i++) {
        Object *ob = (Object *)(uintptr_t)g_ring[i];

        if (ob->class != NULL)
            exp_one(j, ob);
    }
    g_job = NULL;
    return NULL;
}

static int smp_export(uint8_t *base) {
    pthread_t th;
    int half, i, k, threaded = 0;

    if (g_ring_n < 1024)
        return -1;
    half = (int)g_ring_n / 2;
    memset(g_smp_job, 0, sizeof(g_smp_job));
    g_smp_job[0].lo = 0;    g_smp_job[0].hi = half;
    g_smp_job[1].lo = half; g_smp_job[1].hi = (int)g_ring_n;
    g_smp_job[0].refs = g_smp_refs[0];
    g_smp_job[1].refs = g_smp_refs[1];

    if (pthread_create(&th, NULL, exp_thread, &g_smp_job[1]) == 0)
        threaded = 1;
    exp_thread(&g_smp_job[0]);
    if (threaded)
        pthread_join(th, NULL);
    else
        exp_thread(&g_smp_job[1]);

    if (g_smp_job[0].fail || g_smp_job[1].fail)
        return -1;
    for (k = 0; k < 2; k++) {
        exp_job_t *j = &g_smp_job[k];

        for (i = 0; i < j->ent_n; i++) {
            uint32_t start = g_arena_off;
            uint32_t cnt = j->ent[i].cnt;
            uint32_t id = j->ent[i].id;
            uint32_t *h;

            if (start + (cnt + 1u) * 4u > (uint32_t)GRAPH_MAP_SIZE) {
                g_exp_ovf++;
                return -1;
            }
            memcpy(base + start, j->refs + j->ent[i].off, cnt * 4u);
            *(uint32_t *)(base + start + cnt * 4u) = 0xFFFFFFFFu;
            h = (uint32_t *)(base + (uint32_t)id * 16u);
            h[0] = id;
            h[1] = cnt;
            h[2] = g_exp_paddr + start;
            h[3] = 0u;
            g_arena_off = start + (cnt + 1u) * 4u;
            g_exp_count++;
        }
    }
    return 0;
}

/* Bitmap import: two threads over disjoint id ranges; both only read g_obj
   and write marks into distinct objects, so no lock is needed. */
typedef struct {
    uint32_t *bm;
    uint8_t  *base;
    int lo, hi;
} imp_job_t;

static void imp_range(const imp_job_t *j) {
    int i;

    for (i = j->lo; i < j->hi; i++)
        if ((j->bm[i >> 5] >> (i & 31)) & 1u)
            fogccc_set_hard_mark(g_obj[i]);
}

static void *imp_thread(void *arg) {
    imp_range((const imp_job_t *)arg);
    return NULL;
}

/* Parallel import is on by default (it is a clear win); FOGCCC_SMP=0 turns it
   off.  The parallel *export* is opt-in: FOGCCC_SMP_EXPORT=1 (the current
   version is slower than the serial path). */
static int smp_import_on(void) {
    const char *e = getenv("FOGCCC_SMP");

    return e == NULL || (e[0] != '0' && e[0] != '\\0');
}

static void import_marked(uint8_t *base, uint32_t *bm, int n) {
    imp_job_t a, b;
    pthread_t th;
    int mid = n / 2;

    a.bm = bm; a.base = base; a.lo = 0; a.hi = mid;
    b = a; b.lo = mid; b.hi = n;
    /* Two threads writing JamVM's mark bits race whenever ids on either side
       of the split land in the same per-block mark word (id order is only
       approximately address order).  Measured: 0-2 lost marks per 403k-object
       round.  Opt-in until the split is address-aligned. */
    if (getenv("FOGCCC_SMP_IMPORT") != NULL && mid > 4096 &&
        pthread_create(&th, NULL, imp_thread, &b) == 0) {
        imp_range(&a);
        pthread_join(th, NULL);
    } else {
        imp_range(&a);
        imp_range(&b);
    }
}

/* Production path: no JamVM mark.""")

# ---------------------------------------------------------------- class.c
# Export the class loader's class table as graph edges: the hardware graph
# needs the same loader->class edges that JamVM's markLoaderClasses walks, or
# the application classes are unreachable in it.
sub("class.c",
    "void markLoaderClasses(Object *class_loader, int mark) {",
    """static __thread void (*g_loader_emit)(Object *, Object *);
static __thread Object *g_loader_src;

static void fogccc_loader_emit1(Object *ptr) {
    if (g_loader_emit != NULL)
        g_loader_emit(g_loader_src, ptr);
}

void fogccc_loader_classes(Object *class_loader, void (*emit)(Object *, Object *)) {
    HashTable *table = classlibLoaderTable(class_loader);

    if (table == NULL)
        return;
    g_loader_emit = emit;
    g_loader_src = class_loader;
#undef ITERATE
#define ITERATE(ptr) fogccc_loader_emit1(ptr)
    hashIterate((*table));
#undef ITERATE
#define ITERATE(ptr) markRoot(ptr)
    g_loader_emit = NULL;
    g_loader_src = NULL;
}

void markLoaderClasses(Object *class_loader, int mark) {""")

# ---------------------------------------------------------------- metadata dirty hooks
# Class metadata changes without a write barrier.  Flag it and let the next
# collection rebuild the side table instead of trusting the dirty ring.
sub("jam.h",
    "extern uintptr_t resolveSingleConstant(Class *class, int index);",
    """extern uintptr_t resolveSingleConstant(Class *class, int index);
extern void fogccc_meta_dirty(void);
extern void fogccc_note_cp_class(Class *c);""")

sub("resolve.c",
    "uintptr_t resolveSingleConstant(Class *class, int cp_index) {",
    """uintptr_t resolveSingleConstant(Class *class, int cp_index) {
    fogccc_meta_dirty();""")

sub("interp/engine/interp.c",
    "    DEF_OPC(OPC_PUTSTATIC_QUICK##suffix, level,            \\\n"
    "        POP_##level(*(type*)                               \\\n"
    "           (RESOLVED_FIELD(pc)->u.static_value.data), 3);  \\\n"
    "    )                                                      \\",
    "    DEF_OPC(OPC_PUTSTATIC_QUICK##suffix, level,            \\\n"
    "        fogccc_meta_dirty();                               \\\n"
    "        POP_##level(*(type*)                               \\\n"
    "           (RESOLVED_FIELD(pc)->u.static_value.data), 3);  \\\n"
    "    )                                                      \\")

sub("jni.c",
    """void Jam_SetStaticObjectField(JNIEnv *env, jclass clazz, jfieldID fieldID,
                              jobject value) {

    FieldBlock *fb = fieldID;
    fb->u.static_value.p = value;""",
    """void Jam_SetStaticObjectField(JNIEnv *env, jclass clazz, jfieldID fieldID,
                              jobject value) {

    FieldBlock *fb = fieldID;
    fogccc_meta_dirty();
    fb->u.static_value.p = value;""")

# ---------------------------------------------------------------- sweep timing
# The sweep is a full heap pass; measure it next to the mark so the two phases
# can be compared on the board.  The same block reclaims the ids of objects the
# mark did not reach: the sweep is about to recycle their blocks, and the id
# map must not keep stale address->id entries (they exhaust the 20-bit space).
sub("alloc.c",
    """    } else {
        doMark(self, mark_soft_refs);
        largest = compact ? doCompact() : doSweep(self);
    }""",
    """    } else {
        uint64_t t_s0, t_r0;

        if (getenv("FOGCCC_GCDBG") != NULL)
            (void)write(2, "[GCDBG] mark start\\n", 20);
        doMark(self, mark_soft_refs);
        if (getenv("FOGCCC_GCDBG") != NULL)
            (void)write(2, "[GCDBG] mark done\\n", 19);
        t_r0 = fogccc_now_us();
        fogccc_id_reclaim();
        fogccc_reclaim_us = fogccc_now_us() - t_r0;
        fogccc_cards_clear();
        t_s0 = fogccc_now_us();
        largest = compact ? doCompact() : doSweep(self);
        if (getenv("FOGCCC_GCDBG") != NULL)
            (void)write(2, "[GCDBG] sweep done\\n", 20);
        /* NOT unconditional: this runs with all threads suspended, and a
           suspended thread may hold the stdio lock, which deadlocks the GC.
           (DaCapo hung exactly here until this was gated.) */
        if (getenv("FOGCCC_SWEEP_TIME") != NULL)
            printf("[FOGCCC] sweep: %llu us\\n",
                   (unsigned long long)(fogccc_now_us() - t_s0));
    }""")

# The verbose-GC branch (the SW baseline) must reclaim too, and running the
# same code on both sides keeps the pause numbers comparable.
sub("alloc.c",
    """        getTime(&start);
        largest = compact ? doCompact() : doSweep(self);""",
    """        fogccc_id_reclaim();
        fogccc_cards_clear();
        getTime(&start);
        largest = compact ? doCompact() : doSweep(self);""")

# Total stop-the-world window: recorded right after the suspension and printed
# only once the world runs again (printing while suspended can deadlock).
sub("alloc.c",
    """    /* Restart the world */
    resumeAllThreads(self);
    enableSuspend(self);""",
    """    /* Restart the world */
    resumeAllThreads(self);
    enableSuspend(self);
    fogccc_report_stw();""")

# ---------------------------------------------------------------- gc suspend markers
# Pinpoint a DaCapo hang: the GC waits for all threads to reach a safepoint
# before doMark, so a marker before/after suspendAllThreads() separates a
# suspension hang from a mark/sweep hang.
sub("alloc.c",
    """    /* Stop the world */
    disableSuspend(self);
    suspendAllThreads(self);""",
    """    /* Stop the world */
    if (getenv("FOGCCC_GCDBG") != NULL)
        (void)write(2, "[GCDBG] suspending\\n", 20);
    fogccc_gc_stw_t0 = fogccc_now_us();
    disableSuspend(self);
    suspendAllThreads(self);
    if (getenv("FOGCCC_GCDBG") != NULL)
        (void)write(2, "[GCDBG] suspended\\n", 19);""")

# ---------------------------------------------------------------- thread-dump monitor owner
# When a thread is BLOCKED, show which monitor and who owns it.  A NULL owner
# means the pthread mutex was left locked by a thread that exited (JamVM does
# not release monitors on abnormal thread exit).
sub("thread.c",
    """        jam_printf("\\n\\\"%s\\\"%s %p priority: %d tid: %p id: %d state: "
                   "%s (0x%x)\\n", buffer, daemon ? " (daemon)" : "",
                   thread, priority, thread->tid, thread->id,
                   getThreadStateString(thread),
                   classlibGetThreadState(thread));""",
    """        jam_printf("\\n\\\"%s\\\"%s %p priority: %d tid: %p id: %d state: "
                   "%s (0x%x)\\n", buffer, daemon ? " (daemon)" : "",
                   thread, priority, thread->tid, thread->id,
                   getThreadStateString(thread),
                   classlibGetThreadState(thread));
        if(thread->blocked_mon != NULL) {
            Thread *own = thread->blocked_mon->owner;

            jam_printf("    blocked_mon=%p owner=%p owner_id=%d owner_state=%s\\n",
                       thread->blocked_mon, own, own != NULL ? own->id : -1,
                       own != NULL ? getThreadStateString(own) : "none");
        }""")

