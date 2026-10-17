/* Owned-container process identity fixture; never a product executable. */
#include <signal.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <unistd.h>

int main(void) {
    prctl(PR_SET_DUMPABLE, 1);
    if (getenv("FARPANE_TEST_IGNORE_TERM")) signal(SIGTERM, SIG_IGN);
    for (;;) pause();
}
