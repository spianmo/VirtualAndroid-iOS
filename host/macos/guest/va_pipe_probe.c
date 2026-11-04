/*
 * VirtualAndroid: guest-side probe for host pipe services (test tool).
 *
 *   va_pipe_probe [-g] <pipe name> [send <text>] [sendz <text>]
 *                 [clipsend <text>] [read <seconds>] [clipread] [camreply]
 *                 [camsave <file>]
 *
 * Opens the service the way the guest's libqemupipe does: AF_VSOCK to the
 * host (cid 2) port 5000, or /dev/goldfish_pipe with -g, then writes
 * "pipe:<name>\0". "send" writes raw bytes ("sendz" adds a NUL, as camera
 * queries need), "camreply" reads one camera reply ("%08x" size + payload)
 * and prints its status and size, "clipsend" writes a clipboard message
 * (LE32 length + text), "read" dumps whatever arrives for N seconds,
 * "clipread" waits for one clipboard message and prints it, "camsave"
 * writes one camera reply's payload (after "ok:") to a file.
 * Build with the NDK: host/macos/build.sh guest
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <linux/vm_sockets.h>

static int write_all(int fd, const void *buf, size_t len)
{
    const char *p = buf;
    while (len) {
        ssize_t n = write(fd, p, len);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) {
                continue;
            }
            return -1;
        }
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static int read_all(int fd, void *buf, size_t len)
{
    char *p = buf;
    while (len) {
        ssize_t n = read(fd, p, len);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) {
                continue;
            }
            return -1;
        }
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

int main(int argc, char **argv)
{
    int i = 1, use_goldfish = 0;
    if (i < argc && !strcmp(argv[i], "-g")) {
        use_goldfish = 1;
        i++;
    }
    if (i >= argc) {
        fprintf(stderr, "usage: %s [-g] <pipe> [send T] [clipsend T] "
                "[read S] [clipread]\n", argv[0]);
        return 2;
    }
    const char *name = argv[i++];
    int fd;
    if (use_goldfish) {
        fd = open("/dev/goldfish_pipe", O_RDWR);
    } else {
        fd = socket(AF_VSOCK, SOCK_STREAM, 0);
        struct sockaddr_vm sa = { .svm_family = AF_VSOCK,
                                  .svm_cid = VMADDR_CID_HOST,
                                  .svm_port = 5000 };
        if (fd >= 0 && connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
            perror("connect vsock:2:5000");
            return 1;
        }
    }
    if (fd < 0) {
        perror("open");
        return 1;
    }
    char hs[256];
    int n = snprintf(hs, sizeof(hs), "pipe:%s", name);
    if (write_all(fd, hs, (size_t)n + 1)) {
        perror("handshake");
        return 1;
    }
    printf("connected to '%s' via %s\n", name,
           use_goldfish ? "goldfish_pipe" : "vsock");
    for (; i < argc; i++) {
        if (!strcmp(argv[i], "send") && i + 1 < argc) {
            const char *t = argv[++i];
            if (write_all(fd, t, strlen(t))) {
                perror("send");
                return 1;
            }
        } else if (!strcmp(argv[i], "sendz") && i + 1 < argc) {
            const char *t = argv[++i];
            if (write_all(fd, t, strlen(t) + 1)) {
                perror("sendz");
                return 1;
            }
        } else if (!strcmp(argv[i], "camreply")) {
            char hdr[9] = { 0 };
            if (read_all(fd, hdr, 8)) {
                fprintf(stderr, "camreply: EOF\n");
                return 1;
            }
            size_t len = strtoul(hdr, NULL, 16);
            char *buf = malloc(len + 1);
            if (!buf || read_all(fd, buf, len)) {
                fprintf(stderr, "camreply: short\n");
                return 1;
            }
            buf[len] = 0;
            int text = len < 200;
            printf("camreply: %zu bytes: %.2s%s%s\n", len, buf,
                   len > 3 && text ? " " : "", len > 3 && text ? buf + 3 : "");
            if (len > 8 && !text) {
                printf("camreply: first video bytes %u %u %u %u\n",
                       (uint8_t)buf[3], (uint8_t)buf[4], (uint8_t)buf[5],
                       (uint8_t)buf[6]);
            }
            free(buf);
        } else if (!strcmp(argv[i], "camsave") && i + 1 < argc) {
            const char *path = argv[++i];
            char hdr[9] = { 0 };
            if (read_all(fd, hdr, 8)) {
                fprintf(stderr, "camsave: EOF\n");
                return 1;
            }
            size_t len = strtoul(hdr, NULL, 16);
            char *buf = malloc(len + 1);
            if (!buf || read_all(fd, buf, len)) {
                fprintf(stderr, "camsave: short\n");
                return 1;
            }
            FILE *f = fopen(path, "wb");
            if (!f || len < 3 || fwrite(buf + 3, 1, len - 3, f) != len - 3) {
                perror("camsave");
                return 1;
            }
            fclose(f);
            printf("camsave: %.2s, %zu payload bytes -> %s\n", buf, len - 3,
                   path);
            free(buf);
        } else if (!strcmp(argv[i], "clipsend") && i + 1 < argc) {
            const char *t = argv[++i];
            uint32_t len = (uint32_t)strlen(t);
            if (write_all(fd, &len, 4) || write_all(fd, t, len)) {
                perror("clipsend");
                return 1;
            }
            printf("clipsend: %u bytes\n", len);
        } else if (!strcmp(argv[i], "clipread")) {
            uint32_t len;
            if (read_all(fd, &len, 4) || len > (1u << 20)) {
                fprintf(stderr, "clipread: EOF\n");
                return 1;
            }
            char *buf = malloc(len + 1);
            if (read_all(fd, buf, len)) {
                fprintf(stderr, "clipread: short\n");
                return 1;
            }
            buf[len] = 0;
            printf("clipread: %u bytes: '%s'\n", len, buf);
            free(buf);
        } else if (!strcmp(argv[i], "read") && i + 1 < argc) {
            int secs = atoi(argv[++i]);
            time_t end = time(NULL) + secs;
            char buf[4096];
            while (time(NULL) < end) {
                struct pollfd p = { .fd = fd, .events = POLLIN };
                if (poll(&p, 1, 200) <= 0) {
                    continue;
                }
                ssize_t r = read(fd, buf, sizeof(buf));
                if (r <= 0) {
                    printf("\n[EOF]\n");
                    break;
                }
                fwrite(buf, 1, (size_t)r, stdout);
            }
            printf("\n");
        }
    }
    fflush(stdout);
    close(fd);
    return 0;
}
