
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    pid_t child = fork();
    if (child < 0) return 3;
    if (child == 0) { execvp(argv[1], argv + 1); _exit(127); }
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    for (;;) pause();
}
