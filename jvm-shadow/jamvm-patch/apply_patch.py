#!/usr/bin/env python3
"""Patch a JamVM source tree with the FOGCCC shadow exporter (P4a, 4K)."""
import os
import shutil
import sys

SRC = os.path.expanduser("~/jamvm-src-fogccc")
HERE = "/mnt/c/Users/wwwmt/Desktop/C#DMA/jvm-shadow/jamvm-patch"

def sub(path, old, new, count=1):
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        text = f.read()
    n = text.count(old)
    if n != count:
        sys.exit("patch: %s expected %d match(es), found %d for:\n%s"
                 % (path, count, n, old[:200]))
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(text.replace(old, new))

alloc = os.path.join(SRC, "src/alloc.c")
makefile = os.path.join(SRC, "src/Makefile.am")

# 0. new files
for name in ("fogccc_shadow.c", "fogccc_shadow.h"):
    shutil.copy(os.path.join(HERE, name), os.path.join(SRC, "src", name))
for name in ("fpga_gc.c", "fpga_gc.h"):
    shutil.copy(os.path.join("/mnt/c/Users/wwwmt/Desktop/DEV-FPGA Offload GC Coprocessor/csrc", name),
                os.path.join(SRC, "src", name))

# 1. include
sub(alloc, '#include "classlib.h"\n',
          '#include "classlib.h"\n#include "fogccc_shadow.h"\n')

# 2. edge reporting inside MARK_AND_PUSH
sub(alloc,
"""#define MARK_AND_PUSH(object, mark) {                \\
    SET_MARK(object, mark);                          \\
                                                     \\
    if(((char*)object) < mark_scan_ptr) {            \\
        if(mark_stack_count == MARK_STACK_SIZE)      \\
            mark_stack_overflow++;                   \\
        else                                         \\
            mark_stack[mark_stack_count++] = object; \\
    }                                                \\
}
""",
"""/* FOGCCC: report every hard edge to the shadow exporter.  The hooks are off in
   incremental/takeover mode: the side table is built from a heap walk there,
   and the call per edge would double the software mark's cost. */
extern int fogccc_edge_hooks;
#define FOGCCC_EDGE(object, mark) \\
    if (fogccc_edge_hooks) \\
        fogccc_shadow_edge(fogccc_from, (object), (mark) == HARD_MARK)

#define MARK_AND_PUSH(object, mark) {                \\
    SET_MARK(object, mark);                          \\
                                                     \\
    if(((char*)object) < mark_scan_ptr) {            \\
        if(mark_stack_count == MARK_STACK_SIZE)      \\
            mark_stack_overflow++;                   \\
        else                                         \\
            mark_stack[mark_stack_count++] = object; \\
    }                                                \\
    FOGCCC_EDGE((object), (mark));                   \\
}
""")

# 3. roots
sub(alloc,
"""void markRoot(Object *object) {
    if(object != NULL)
        MARK(object, HARD_MARK);
}
""",
"""void markRoot(Object *object) {
    if(object != NULL) {
        MARK(object, HARD_MARK);
        fogccc_shadow_root(object);
    }
}
""")

sub(alloc,
"""void markConservativeRoot(Object *object) {
    if(object == NULL)
        return;

    MARK(object, HARD_MARK);
    addConservativeRoot(object);
}
""",
"""void markConservativeRoot(Object *object) {
    if(object == NULL)
        return;

    MARK(object, HARD_MARK);
    addConservativeRoot(object);
    fogccc_shadow_root(object);
}
""")

# 4. current source object for edges
sub(alloc,
"""void markStack(int mark_soft_refs) {
    while(mark_stack_count > 0) {
        Object *object = mark_stack[--mark_stack_count];
        int mark = IS_MARKED(object);

        markChildren(object, mark, mark_soft_refs);
    }
}
""",
"""void markStack(int mark_soft_refs) {
    while(mark_stack_count > 0) {
        Object *object = mark_stack[--mark_stack_count];
        int mark = IS_MARKED(object);

        fogccc_from = object;
        markChildren(object, mark, mark_soft_refs);
    }
    fogccc_from = NULL;
}
""")

sub(alloc,
"""            if(mark) {
                markChildren(ob, mark, mark_soft_refs);
                markStack(mark_soft_refs);
            }
""",
"""            if(mark) {
                fogccc_from = ob;
                markChildren(ob, mark, mark_soft_refs);
                markStack(mark_soft_refs);
            }
""")

sub(alloc,
"""        /* Skip to next block */
        mark_scan_ptr += size;
    }
}
""",
"""        /* Skip to next block */
        mark_scan_ptr += size;
    }
    fogccc_from = NULL;
}
""")

# 5. callback + run point
sub(alloc,
"""static void doMark(Thread *self, int mark_soft_refs) {
""",
"""/* FOGCCC: JamVM's final hard-mark state, used to check the hardware run. */
static int fogccc_is_hard_marked(Object *ob) {
    return IS_HARD_MARKED(ob);
}

static void doMark(Thread *self, int mark_soft_refs) {
""")

sub(alloc,
"""    if(oom) MARK(oom, HARD_MARK);
""",
"""    if(oom) {
        MARK(oom, HARD_MARK);
        fogccc_shadow_root(oom);
    }
""")

sub(alloc,
"""    /* All roots should now be marked.  Scan the heap and recursively
       mark all marked objects - once the heap has been scanned all
       reachable objects should be marked */

    scanHeapAndMark(mark_soft_refs);
""",
"""    /* All roots should now be marked.  Scan the heap and recursively
       mark all marked objects - once the heap has been scanned all
       reachable objects should be marked */

    scanHeapAndMark(mark_soft_refs);

    /* FOGCCC: export the marked graph and compare with the FPGA engine */
    fogccc_shadow_run(fogccc_is_hard_marked);
""")

# 6. build the new sources into libcore
sub(makefile,
"""                     jni-stubs.c annotations.h
""",
"""                     jni-stubs.c annotations.h \\
                     fogccc_shadow.c fogccc_shadow.h fpga_gc.c fpga_gc.h
""")

print("patched OK")
