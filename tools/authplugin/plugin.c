// Authorization plugin: satisfy a GUI authorization prompt with a button press.
//
// macOS has three separate authentication paths, and they need three different
// answers:
//
//   sudo                        PAM              -> tools/pam/ (solved)
//   Chrome, LAContext clients   LocalAuthentication -> no extension point exists
//   System Settings, system.*   authorization DB -> this plugin
//
// The authorization database evaluates a right by running an ordered list of
// mechanisms. Placing this one *before* builtin:authenticate means it can grant
// authorization before the password UI is ever shown — which is why a plugin
// works here and a PAM module does not: those stacks use use_first_pass, so by
// the time PAM runs the prompt has already happened.
//
// Returning anything other than Allow lets evaluation continue to the next
// mechanism, so a failure here just gets the usual password prompt.

#include <Security/AuthorizationPlugin.h>
#include <Security/AuthorizationTags.h>
#include <os/log.h>
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef SMARTCARD_AUTH_HELPER
#define SMARTCARD_AUTH_HELPER "/usr/local/libexec/smartcard-auth-helper"
#endif

// Matches token_auth.h; the helper exits with one of these.
#define TOKEN_AUTH_OK 0

typedef struct {
    const AuthorizationCallbacks *callbacks;
} Plugin;

typedef struct {
    Plugin *plugin;
    AuthorizationEngineRef engine;
} Mechanism;

static os_log_t logger(void) {
    static os_log_t log;
    if (!log) log = os_log_create("io.openhanko.authplugin", "mechanism");
    return log;
}

// The user being authenticated. SecurityAgent puts it in the context as
// "username"; some flows only set it as a hint.
static bool copy_username(Mechanism *mechanism, char *out, size_t size) {
    const AuthorizationValue *value = NULL;
    AuthorizationContextFlags flags = 0;

    if (mechanism->plugin->callbacks->GetContextValue(
            mechanism->engine, kAuthorizationEnvironmentUsername,
            &flags, &value) != errAuthorizationSuccess || !value) {
        if (mechanism->plugin->callbacks->GetHintValue(
                mechanism->engine, kAuthorizationEnvironmentUsername,
                &value) != errAuthorizationSuccess || !value) {
            return false;
        }
    }
    if (!value->data || value->length == 0 || value->length >= size) return false;

    memcpy(out, value->data, value->length);
    out[value->length] = '\0';
    // Values are not always NUL-terminated; trim if they are.
    out[strcspn(out, "\n")] = '\0';
    return out[0] != '\0';
}

// Runs the token check as the target user. Same fork+exec shape as the PAM
// module, and for the same two reasons: token keys live in that user's
// CryptoTokenKit session, and Objective-C frameworks cannot run in a forked
// child without exec.
static bool authenticate(const char *username) {
    struct passwd *pw = getpwnam(username);
    if (!pw) return false;

    pid_t child = fork();
    if (child < 0) return false;
    if (child == 0) {
        if (setgid(pw->pw_gid) != 0 || setuid(pw->pw_uid) != 0) _exit(1);
        execl(SMARTCARD_AUTH_HELPER, SMARTCARD_AUTH_HELPER, pw->pw_name, (char *)NULL);
        _exit(1);
    }

    int status = 0;
    if (waitpid(child, &status, 0) < 0 || !WIFEXITED(status)) return false;
    return WEXITSTATUS(status) == TOKEN_AUTH_OK;
}

static OSStatus MechanismCreate(AuthorizationPluginRef inPlugin,
                                AuthorizationEngineRef inEngine,
                                AuthorizationMechanismId mechanismId,
                                AuthorizationMechanismRef *outMechanism) {
    (void)mechanismId;
    Mechanism *mechanism = calloc(1, sizeof(Mechanism));
    if (!mechanism) return errAuthorizationInternal;
    mechanism->plugin = (Plugin *)inPlugin;
    mechanism->engine = inEngine;
    *outMechanism = mechanism;
    return errAuthorizationSuccess;
}

static OSStatus MechanismInvoke(AuthorizationMechanismRef inMechanism) {
    Mechanism *mechanism = (Mechanism *)inMechanism;

    char username[256];
    if (!copy_username(mechanism, username, sizeof(username))) {
        os_log(logger(), "no username in context; deferring to the next mechanism");
        // Undefined, not Deny: Deny would refuse the whole authorization rather
        // than let the password prompt have its turn.
        return mechanism->plugin->callbacks->SetResult(mechanism->engine,
                                                       kAuthorizationResultUndefined);
    }

    os_log(logger(), "authenticating %{public}s by smart-card presence", username);
    bool ok = authenticate(username);
    os_log(logger(), "%{public}s", ok ? "granted by presence" : "deferring to the next mechanism");

    return mechanism->plugin->callbacks->SetResult(
        mechanism->engine,
        ok ? kAuthorizationResultAllow : kAuthorizationResultUndefined);
}

static OSStatus MechanismDeactivate(AuthorizationMechanismRef inMechanism) {
    Mechanism *mechanism = (Mechanism *)inMechanism;
    return mechanism->plugin->callbacks->DidDeactivate(mechanism->engine);
}

static OSStatus MechanismDestroy(AuthorizationMechanismRef inMechanism) {
    free(inMechanism);
    return errAuthorizationSuccess;
}

static OSStatus PluginDestroy(AuthorizationPluginRef inPlugin) {
    free(inPlugin);
    return errAuthorizationSuccess;
}

static AuthorizationPluginInterface interface = {
    kAuthorizationPluginInterfaceVersion,
    PluginDestroy,
    MechanismCreate,
    MechanismInvoke,
    MechanismDeactivate,
    MechanismDestroy,
};

OSStatus AuthorizationPluginCreate(const AuthorizationCallbacks *callbacks,
                                   AuthorizationPluginRef *outPlugin,
                                   const AuthorizationPluginInterface **outPluginInterface) {
    if (callbacks->version < kAuthorizationCallbacksVersion) return errAuthorizationInternal;

    Plugin *plugin = calloc(1, sizeof(Plugin));
    if (!plugin) return errAuthorizationInternal;
    plugin->callbacks = callbacks;

    *outPlugin = plugin;
    *outPluginInterface = &interface;
    return errAuthorizationSuccess;
}
