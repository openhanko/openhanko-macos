#pragma once

#include <stdbool.h>

// Authenticates `username` by proving possession of a smart-card key paired to
// them, with no PIN: the token driver handles authentication, which for this
// device means a fingerprint on the reader.
//
// Returns one of:
typedef enum {
    TOKEN_AUTH_OK = 0,        // challenge signed and verified
    TOKEN_AUTH_NO_TOKEN,      // no paired card present — caller should fall through
    TOKEN_AUTH_FAILED,        // a paired card was present and did not authenticate
} token_auth_result_t;

// `log` may be NULL. It is called with human-readable progress, and exists so
// the PAM module can route messages to os_log while the CLI prints them.
token_auth_result_t token_authenticate(const char *username,
                                       void (*log)(const char *message));
