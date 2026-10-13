// Needs its per-file compiler flag (-DCLASSIC=1): the build fails if a migration drops it.
#ifndef CLASSIC
#error "util.c lost its -DCLASSIC=1 compiler flag"
#endif
int classic_answer(void) { return CLASSIC * 42; }
