// Controlled PTY child used only by integration tests to report kernel facts
// directly and synchronize resize notification without timing assumptions.
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

static int resize_pipe[2] = {-1, -1};

static void handle_winch(int signal_number) {
    (void)signal_number;
    uint8_t marker = 1;
    ssize_t ignored = write(resize_pipe[1], &marker, sizeof(marker));
    (void)ignored;
}

static void print_terminal_facts(const char *shell_argv0) {
    char cwd[PATH_MAX];
    struct winsize size = {0};
    ioctl(STDIN_FILENO, TIOCGWINSZ, &size);
    printf("__ARGV0__=%s\n", shell_argv0);
    printf("__PID__=%d\n", getpid());
    printf("__SID__=%d\n", getsid(0));
    printf("__PGID__=%d\n", getpgrp());
    printf("__TPGID__=%d\n", tcgetpgrp(STDIN_FILENO));
    printf("__TTY0__=%s\n", isatty(STDIN_FILENO) ? "yes" : "no");
    printf("__TTY1__=%s\n", isatty(STDOUT_FILENO) ? "yes" : "no");
    printf("__TTY2__=%s\n", isatty(STDERR_FILENO) ? "yes" : "no");
    printf("__TTYNAME0__=%s\n", ttyname(STDIN_FILENO));
    printf("__TTYNAME1__=%s\n", ttyname(STDOUT_FILENO));
    printf("__TTYNAME2__=%s\n", ttyname(STDERR_FILENO));
    printf("__CWD__=%s\n", getcwd(cwd, sizeof(cwd)));
    printf("__ENV__=%s\n", getenv("DANTERM_PROBE"));
    printf("__SIZE__=%u %u\n", size.ws_row, size.ws_col);
}

static int run_ownership_probe(const char *shell_argv0) {
    char input[256];
    print_terminal_facts(shell_argv0);
    printf("__READY__\n");
    fflush(stdout);
    if (fgets(input, sizeof(input), stdin) == NULL) {
        return 70;
    }
    input[strcspn(input, "\r\n")] = '\0';
    printf("__INPUT__=%s\n", input);
    fflush(stdout);
    return 7;
}

static int run_resize_probe(void) {
    if (pipe(resize_pipe) < 0) {
        return 71;
    }
    struct sigaction action = {0};
    action.sa_handler = handle_winch;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGWINCH, &action, NULL) < 0) {
        return 72;
    }
    printf("__READY__\n");
    fflush(stdout);

    uint8_t marker = 0;
    while (read(resize_pipe[0], &marker, sizeof(marker)) < 0 && errno == EINTR) {
    }
    struct winsize size = {0};
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, &size) < 0) {
        return 73;
    }
    printf("__WINCH__=%u %u\n", size.ws_row, size.ws_col);
    fflush(stdout);

    char input[16];
    if (fgets(input, sizeof(input), stdin) == NULL) {
        return 74;
    }
    return 0;
}

static int write_all(int descriptor, const uint8_t *bytes, size_t count) {
    while (count > 0) {
        ssize_t written = write(descriptor, bytes, count);
        if (written > 0) {
            bytes += written;
            count -= (size_t)written;
        } else if (written < 0 && errno == EINTR) {
            continue;
        } else {
            return -1;
        }
    }
    return 0;
}

static int run_fragmented_probe(void) {
    uint8_t payload[4093];
    size_t produced = 0;
    const size_t total = 256 * 1024;
    const size_t fragments[] = {1, 7, 113, 4093, 29, 2048};
    size_t fragment_index = 0;
    while (produced < total) {
        size_t count = fragments[fragment_index % (sizeof(fragments) / sizeof(fragments[0]))];
        if (count > total - produced) {
            count = total - produced;
        }
        for (size_t index = 0; index < count; index++) {
            payload[index] = (uint8_t)('A' + ((produced + index) % 26));
        }
        if (write_all(STDOUT_FILENO, payload, count) < 0) {
            return 75;
        }
        produced += count;
        fragment_index++;
    }
    printf("__FRAGMENTED_DONE__\n");
    fflush(stdout);
    return 0;
}

static int run_eof_first_probe(void) {
    if (pipe(resize_pipe) < 0) {
        return 76;
    }
    struct sigaction action = {0};
    action.sa_handler = handle_winch;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGUSR1, &action, NULL) < 0) {
        return 77;
    }
    printf("__PID__=%d\n", getpid());
    printf("__CLOSING_PTY__\n");
    fflush(stdout);
    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);

    uint8_t marker = 0;
    while (read(resize_pipe[0], &marker, sizeof(marker)) < 0 && errno == EINTR) {
    }
    return 6;
}

static int run_exit_first_probe(void) {
    pid_t descendant = fork();
    if (descendant < 0) {
        return 78;
    }
    if (descendant == 0) {
        uint8_t bytes[4096];
        memset(bytes, 'x', sizeof(bytes));
        for (;;) {
            if (write_all(STDOUT_FILENO, bytes, sizeof(bytes)) < 0) {
                _exit(0);
            }
        }
    }
    printf("__DESCENDANT__=%d\n", descendant);
    printf("__FINAL_MARKER__\n");
    fflush(stdout);
    _exit(9);
}

static int run_recording_probe(void) {
    char input[32];
    printf("__BEFORE_RESIZE__\n");
    fflush(stdout);
    if (fgets(input, sizeof(input), stdin) == NULL) {
        return 79;
    }
    printf("__AFTER_RESIZE__\n");
    fflush(stdout);
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        return 64;
    }
    if (strcmp(argv[1], "ownership") == 0) {
        return run_ownership_probe(argv[2]);
    }
    if (strcmp(argv[1], "resize") == 0) {
        return run_resize_probe();
    }
    if (strcmp(argv[1], "fragmented") == 0) {
        return run_fragmented_probe();
    }
    if (strcmp(argv[1], "eof-first") == 0) {
        return run_eof_first_probe();
    }
    if (strcmp(argv[1], "exit-first") == 0) {
        return run_exit_first_probe();
    }
    if (strcmp(argv[1], "recording") == 0) {
        return run_recording_probe();
    }
    return 65;
}
