// Privilege-dropped helper, executed by the PAM module.
//
// It exists because the module cannot do this work in a forked child: the
// OpenDirectory and Security frameworks are Objective-C underneath, and the ObjC
// runtime refuses to run after fork() without exec —
//
//   objc[2603]: +[ODSession initialize] may have been in progress in another
//   thread when fork() was called. We cannot safely call it. Crashing instead.
//
// exec gives the child a clean runtime, and running as a separate process also
// means a crash in here cannot take sudo down with it.
//
// Exit status is a token_auth_result_t, which the module maps to a PAM result.

#include "token_auth.h"

#include <os/log.h>
#include <stdio.h>

static void note(const char *message) {
    static os_log_t log;
    if (!log) log = os_log_create("io.openhanko.pam", "helper");
    os_log(log, "%{public}s", message);
}

int main(int argc, char **argv) {
    if (argc < 2) return TOKEN_AUTH_NO_TOKEN;
    return (int)token_authenticate(argv[1], note);
}
