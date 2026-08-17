// PAM module: authenticate by pressing the button on a paired smart card.
//
// Apple's pam_smartcard.so prompts "Enter PIN for '%s': " and types the PIN over
// the keyboard, because it does not link CryptoTokenKit and has no pinpad path.
// This module goes through CryptoTokenKit instead, so the token driver performs
// the authentication — for this device, a press on the reader.
//
// Install as `auth sufficient` so a failure falls through to the existing
// password stack rather than locking anyone out:
//
//     # /etc/pam.d/sudo_local
//     auth  sufficient  /usr/local/lib/pam_smartcard_presence.so
//
// The real work runs in a helper process that drops to the invoking user. Two
// reasons: token keys live in that user's CryptoTokenKit session, not root's,
// and a crash anywhere in the Security framework then cannot take sudo with it.
//
// It must be fork+exec, not just fork. OpenDirectory and Security are
// Objective-C underneath, and the ObjC runtime deliberately crashes rather than
// run after a fork without exec:
//
//   objc[...]: +[ODSession initialize] may have been in progress in another
//   thread when fork() was called. ... Crashing instead.

#include "token_auth.h"

#include <os/log.h>
#include <pwd.h>
#include <security/pam_appl.h>
#include <security/pam_modules.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

// Installed alongside the module by install.sh.
#ifndef SMARTCARD_AUTH_HELPER
#define SMARTCARD_AUTH_HELPER "/usr/local/libexec/smartcard-auth-helper"
#endif

static os_log_t logger(void) {
    static os_log_t log;
    if (!log) log = os_log_create("io.openhanko.pam", "auth");
    return log;
}

static void note(const char *message) {
    os_log(logger(), "%{public}s", message);
}

// The user being authenticated is the one invoking sudo, not the target. sudo is
// setuid root, so the real uid is still theirs; PAM_RUSER is preferred when the
// application sets it.
static const char *invoking_user(pam_handle_t *pamh, char *buffer, size_t size) {
    const char *ruser = NULL;
    if (pam_get_item(pamh, PAM_RUSER, (const void **)&ruser) == PAM_SUCCESS &&
        ruser && *ruser && strcmp(ruser, "root") != 0) {
        snprintf(buffer, size, "%s", ruser);
        return buffer;
    }

    uid_t uid = getuid();
    if (uid == 0) {
        const char *sudo_user = getenv("SUDO_USER");
        if (sudo_user && *sudo_user) {
            snprintf(buffer, size, "%s", sudo_user);
            return buffer;
        }
    }
    struct passwd *pw = getpwuid(uid);
    if (!pw) return NULL;
    snprintf(buffer, size, "%s", pw->pw_name);
    return buffer;
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags,
                                   int argc, const char **argv) {
    (void)flags; (void)argc; (void)argv;

    char name[256];
    const char *username = invoking_user(pamh, name, sizeof(name));
    if (!username) {
        note("cannot determine the invoking user");
        return PAM_AUTHINFO_UNAVAIL;
    }

    struct passwd *pw = getpwnam(username);
    if (!pw) {
        note("no passwd entry for the invoking user");
        return PAM_AUTHINFO_UNAVAIL;
    }

    pid_t child = fork();
    if (child < 0) {
        note("fork failed");
        return PAM_AUTHINFO_UNAVAIL;
    }

    if (child == 0) {
        // Drop to the invoking user before touching the keychain or the token,
        // then exec so the child gets a usable Objective-C runtime.
        if (setgid(pw->pw_gid) != 0 || setuid(pw->pw_uid) != 0) _exit(TOKEN_AUTH_NO_TOKEN);
        execl(SMARTCARD_AUTH_HELPER, SMARTCARD_AUTH_HELPER, pw->pw_name, (char *)NULL);
        _exit(TOKEN_AUTH_NO_TOKEN);  // exec failed; fall through to the password
    }

    int status = 0;
    if (waitpid(child, &status, 0) < 0 || !WIFEXITED(status)) {
        note("authentication helper did not exit cleanly");
        return PAM_AUTHINFO_UNAVAIL;
    }

    switch (WEXITSTATUS(status)) {
        case TOKEN_AUTH_OK:
            note("authenticated by smart-card presence");
            return PAM_SUCCESS;
        case TOKEN_AUTH_FAILED:
            note("paired card present but did not authenticate");
            return PAM_AUTH_ERR;
        default:
            // No paired card, or we could not look. Let the rest of the stack
            // ask for a password as it always has.
            return PAM_AUTHINFO_UNAVAIL;
    }
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags,
                              int argc, const char **argv) {
    (void)pamh; (void)flags; (void)argc; (void)argv;
    return PAM_SUCCESS;
}
