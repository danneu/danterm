// Test-only stand-in for PTYSessionBootstrap that writes half a
// `bootstrap_failure` payload down the status pipe and dies. It exists so the
// handshake reader has a producer for its truncated outcome; nothing but
// TerminalPTYHostTests should ever name it.
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        _exit(127);
    }
    int status_fd = atoi(argv[1]);
    const unsigned char half_payload[4] = {0, 0, 0, 0};
    ssize_t written = write(status_fd, half_payload, sizeof(half_payload));
    (void)written;
    _exit(127);
}
