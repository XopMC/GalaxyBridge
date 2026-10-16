#define _DARWIN_C_SOURCE
#include <sys/socket.h>
#include <sys/un.h>
#include <pthread.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

/* Private host fixture: a retained descriptor models the socket reference held
 * by an in-flight Android accept/recv. No network interface or phone is used. */
struct blocked_socket { int descriptor; int accepting; };
static void *blocked(void *raw) {
    struct blocked_socket *socket = raw;
    if (socket->accepting) {
        int accepted = accept(socket->descriptor, NULL, NULL);
        if (accepted >= 0) close(accepted);
    } else {
        char byte;
        (void) recv(socket->descriptor, &byte, 1, 0);
    }
    puts("unblocked");
    close(socket->descriptor);
    return NULL;
}
int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "accept") && strcmp(argv[1], "read"))) return 2;
    setbuf(stdout, NULL);
    int descriptor, peer = -1;
    char path[104] = "";
    if (!strcmp(argv[1], "accept")) {
        const char *directory = getenv("GB_SHELL_SOCKET_FIXTURE_DIRECTORY");
        if (!directory || snprintf(path, sizeof(path), "%s/s", directory) >= (int) sizeof(path)) return 3;
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un address;
        memset(&address, 0, sizeof(address)); address.sun_family = AF_UNIX;
        memcpy(address.sun_path, path, strlen(path) + 1);
        if (descriptor < 0 || bind(descriptor, (struct sockaddr *) &address, sizeof(address)) || listen(descriptor, 1)) return 4;
    } else {
        int pair[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair)) return 5;
        descriptor = pair[0]; peer = pair[1];
    }
    struct blocked_socket target = { dup(descriptor), !strcmp(argv[1], "accept") };
    if (target.descriptor < 0) return 6;
    pthread_t worker;
    if (pthread_create(&worker, NULL, blocked, &target)) return 7;
    puts("ready");
    char command[32];
    while (fgets(command, sizeof(command), stdin)) {
        if (!strcmp(command, "shutdown\n")) {
            int result = shutdown(descriptor, SHUT_RDWR);
#if defined(__APPLE__)
            if (result && errno == ENOTCONN && target.accepting) puts("darwin_listener_shutdown_unsupported");
            else
#endif
            puts(result ? "shutdown_error" : "shutdown");
        } else if (!strcmp(command, "close\n")) {
            close(descriptor); descriptor = -1; puts("closed");
        }
    }
    /* Even a failing regression must leave no blocked worker or socket path. */
    shutdown(target.descriptor, SHUT_RDWR);
    if (*path) {
        // Darwin does not implement shutdown on a listening socket. Wake only
        // this private test accept for cleanup; production targets Android.
        int wake = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un address;
        memset(&address, 0, sizeof(address)); address.sun_family = AF_UNIX;
        memcpy(address.sun_path, path, strlen(path) + 1);
        if (wake >= 0) { (void) connect(wake, (struct sockaddr *) &address, sizeof(address)); close(wake); }
    }
    pthread_join(worker, NULL);
    if (descriptor >= 0) close(descriptor);
    if (peer >= 0) close(peer);
    if (*path) unlink(path);
    return 0;
}
