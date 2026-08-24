// Standalone form of the PAM module, for testing without touching the auth stack.
#include "token_auth.h"

#include <stdio.h>
#include <unistd.h>

static void print_log(const char *message) { printf("  %s\n", message); fflush(stdout); }

int main(int argc, char **argv) {
    const char *username = argc > 1 ? argv[1] : getlogin();
    if (!username) { fprintf(stderr, "cannot determine username\n"); return 2; }

    printf("authenticating %s (touch the sensor when the reader asks)\n", username);
    switch (token_authenticate(username, print_log)) {
        case TOKEN_AUTH_OK:       printf("OK\n");                       return 0;
        case TOKEN_AUTH_NO_TOKEN: printf("no paired card available\n"); return 2;
        case TOKEN_AUTH_FAILED:   printf("FAILED\n");                   return 1;
    }
    return 1;
}
