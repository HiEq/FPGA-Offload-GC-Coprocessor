#ifndef FOGCCC_SHADOW_H
#define FOGCCC_SHADOW_H

/* No #include here on purpose: JamVM's headers have no include guards and
   alloc.c includes jam.h before this file.  fogccc_shadow.c includes
   jam.h itself before including this header. */

/* Set by the mark loop to the object currently being scanned; every
   reference it marks becomes an edge fogccc_from -> object. */
extern Object *fogccc_from;

/* Called once from doMark() before the mark: assigns ids in heap-address
   order so a chain walks the side table sequentially. */
int  fogccc_shadow_enabled(void);
void fogccc_shadow_register(Object *ob);

void fogccc_shadow_root(Object *ob);
void fogccc_shadow_edge(Object *from, Object *to, int hard);
void fogccc_shadow_run(int (*is_hard_marked)(Object *));

/* Set while the takeover/incremental export runs: soft-reference referents are
   emitted even though JamVM's marks have already been cleared. */
extern int fogccc_ref_emit_all;

/* Every Class object allocated after boot (see allocClass). */
void fogccc_note_new_class(Object *c);

/* Allocated-block check that does not consult the mark bit (takeover clears
   the marks before the export). */
int fogccc_object_alloced(Object *ob);

#endif
