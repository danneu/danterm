// Single-threaded child bootstrap for macOS session and controlling-terminal
// setup that public posix_spawn file actions cannot express.
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

enum bootstrap_stage {
    bootstrap_stage_usage = 1,
    bootstrap_stage_cloexec,
    bootstrap_stage_setsid,
    bootstrap_stage_open_slave,
    bootstrap_stage_controlling_terminal,
    bootstrap_stage_standard_streams,
    bootstrap_stage_foreground_group,
    bootstrap_stage_working_directory,
    bootstrap_stage_exec
};

struct bootstrap_failure {
    int32_t stage;
    int32_t error;
};

static void fail_bootstrap(int status_fd, enum bootstrap_stage stage, int error) {
    struct bootstrap_failure failure = {(int32_t)stage, (int32_t)error};
    const uint8_t *bytes = (const uint8_t *)&failure;
    size_t remaining = sizeof(failure);
    while (remaining > 0) {
        ssize_t written = write(status_fd, bytes, remaining);
        if (written > 0) {
            bytes += written;
            remaining -= (size_t)written;
        } else if (written < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    _exit(127);
}

int main(int argc, char *argv[], char *envp[]) {
    if (argc < 6) {
        _exit(127);
    }
    int status_fd = atoi(argv[1]);
    if (fcntl(status_fd, F_SETFD, FD_CLOEXEC) < 0) {
        fail_bootstrap(status_fd, bootstrap_stage_cloexec, errno);
    }
    if (setsid() < 0) {
        fail_bootstrap(status_fd, bootstrap_stage_setsid, errno);
    }
    int slave = open(argv[2], O_RDWR);
    if (slave < 0) {
        fail_bootstrap(status_fd, bootstrap_stage_open_slave, errno);
    }
    if (ioctl(slave, TIOCSCTTY, 0) < 0) {
        fail_bootstrap(status_fd, bootstrap_stage_controlling_terminal, errno);
    }
    if (dup2(slave, STDIN_FILENO) < 0 ||
        dup2(slave, STDOUT_FILENO) < 0 ||
        dup2(slave, STDERR_FILENO) < 0) {
        fail_bootstrap(status_fd, bootstrap_stage_standard_streams, errno);
    }
    if (slave > STDERR_FILENO) {
        close(slave);
    }
    if (tcsetpgrp(STDIN_FILENO, getpgrp()) < 0) {
        fail_bootstrap(status_fd, bootstrap_stage_foreground_group, errno);
    }
    if (chdir(argv[3]) < 0) {
        fail_bootstrap(status_fd, bootstrap_stage_working_directory, errno);
    }
    execve(argv[4], &argv[5], envp);
    fail_bootstrap(status_fd, bootstrap_stage_exec, errno);
}
