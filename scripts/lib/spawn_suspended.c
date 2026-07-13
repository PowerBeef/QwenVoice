#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static int write_pid(const char *path, pid_t pid) {
    FILE *stream = fopen(path, "wx");
    if (stream == NULL) {
        fprintf(stderr, "spawn-suspended: cannot create PID file %s: %s\n", path, strerror(errno));
        return 1;
    }
    if (fprintf(stream, "%d\n", pid) < 0 || fflush(stream) != 0 || fsync(fileno(stream)) != 0) {
        fprintf(stderr, "spawn-suspended: cannot write PID file %s: %s\n", path, strerror(errno));
        fclose(stream);
        return 1;
    }
    if (fclose(stream) != 0) {
        fprintf(stderr, "spawn-suspended: cannot close PID file %s: %s\n", path, strerror(errno));
        return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: spawn-suspended <pid-file> <executable> [args...]\n");
        return 64;
    }

    posix_spawnattr_t attributes;
    int error = posix_spawnattr_init(&attributes);
    if (error != 0) {
        fprintf(stderr, "spawn-suspended: posix_spawnattr_init: %s\n", strerror(error));
        return 70;
    }
    error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_START_SUSPENDED);
    if (error != 0) {
        fprintf(stderr, "spawn-suspended: posix_spawnattr_setflags: %s\n", strerror(error));
        posix_spawnattr_destroy(&attributes);
        return 70;
    }

    pid_t child = 0;
    error = posix_spawn(&child, argv[2], NULL, &attributes, &argv[2], environ);
    posix_spawnattr_destroy(&attributes);
    if (error != 0) {
        fprintf(stderr, "spawn-suspended: posix_spawn %s: %s\n", argv[2], strerror(error));
        return 71;
    }
    if (write_pid(argv[1], child) != 0) {
        kill(child, SIGKILL);
        waitpid(child, NULL, 0);
        return 73;
    }

    int status = 0;
    pid_t waited;
    do {
        waited = waitpid(child, &status, 0);
    } while (waited < 0 && errno == EINTR);
    if (waited < 0) {
        fprintf(stderr, "spawn-suspended: waitpid: %s\n", strerror(errno));
        return 74;
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return 75;
}
