// Samples the process wakeup counters that back Activity Monitor's idle-wakeup view.
#include <errno.h>
#include <inttypes.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <time.h>

static struct rusage_info_v0 read_usage(pid_t pid) {
    struct rusage_info_v0 usage = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V0, (rusage_info_t *)&usage) != 0) {
        perror("proc_pid_rusage");
        exit(1);
    }
    return usage;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s PID SECONDS\n", argv[0]);
        return 2;
    }

    const pid_t pid = (pid_t)strtol(argv[1], NULL, 10);
    const double requested_seconds = strtod(argv[2], NULL);
    if (pid <= 0 || requested_seconds <= 0) {
        fprintf(stderr, "PID and SECONDS must be positive\n");
        return 2;
    }

    struct timespec started;
    struct timespec finished;
    clock_gettime(CLOCK_MONOTONIC, &started);
    const struct rusage_info_v0 before = read_usage(pid);

    struct timespec remaining = {
        .tv_sec = (time_t)requested_seconds,
        .tv_nsec = (long)((requested_seconds - (time_t)requested_seconds) * 1000000000.0),
    };
    while (nanosleep(&remaining, &remaining) != 0) {
        if (errno != EINTR) {
            perror("nanosleep");
            return 1;
        }
    }

    const struct rusage_info_v0 after = read_usage(pid);
    clock_gettime(CLOCK_MONOTONIC, &finished);
    const double elapsed = (double)(finished.tv_sec - started.tv_sec)
        + (double)(finished.tv_nsec - started.tv_nsec) / 1000000000.0;
    const uint64_t interrupt_wakeups = after.ri_interrupt_wkups - before.ri_interrupt_wkups;
    const uint64_t package_idle_wakeups = after.ri_pkg_idle_wkups - before.ri_pkg_idle_wkups;

    printf(
        "{\"seconds\":%.6f,\"interruptWakeups\":%" PRIu64
        ",\"packageIdleWakeups\":%" PRIu64
        ",\"interruptWakeupsPerSecond\":%.6f"
        ",\"packageIdleWakeupsPerSecond\":%.6f}\n",
        elapsed,
        interrupt_wakeups,
        package_idle_wakeups,
        interrupt_wakeups / elapsed,
        package_idle_wakeups / elapsed
    );
    return 0;
}
