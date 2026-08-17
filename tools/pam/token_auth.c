#include "token_auth.h"

#include <CoreFoundation/CoreFoundation.h>
#include <OpenDirectory/OpenDirectory.h>
#include <Security/Security.h>
#include <ctype.h>
#include <stdio.h>
#include <string.h>

#define CHALLENGE_BYTES 32

static void emit(void (*log)(const char *), const char *format, ...) {
    if (!log) return;
    char buffer[512];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    log(buffer);
}

// Collects ";tokenidentity;<HASH>" entries from the user's
// AuthenticationAuthority. This is where `sc_auth pair` records a pairing, and
// checking it is what stops somebody else's card authenticating as this user.
static CFMutableArrayRef copy_paired_hashes(const char *username,
                                            void (*log)(const char *)) {
    CFMutableArrayRef hashes = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFErrorRef error = NULL;

    ODSessionRef session = ODSessionCreate(NULL, NULL, &error);
    if (!session) { emit(log, "OpenDirectory session unavailable"); goto done; }

    ODNodeRef node = ODNodeCreateWithNodeType(NULL, session, kODNodeTypeAuthentication, &error);
    if (!node) { emit(log, "OpenDirectory node unavailable"); CFRelease(session); goto done; }

    CFStringRef name = CFStringCreateWithCString(NULL, username, kCFStringEncodingUTF8);
    ODRecordRef record = ODNodeCopyRecord(node, kODRecordTypeUsers, name, NULL, &error);
    CFRelease(name);
    if (!record) {
        emit(log, "no user record for %s", username);
        CFRelease(node); CFRelease(session); goto done;
    }

    CFArrayRef values = ODRecordCopyValues(record,
        CFSTR("dsAttrTypeStandard:AuthenticationAuthority"), &error);
    if (values) {
        for (CFIndex i = 0; i < CFArrayGetCount(values); i++) {
            CFStringRef entry = CFArrayGetValueAtIndex(values, i);
            if (CFGetTypeID(entry) != CFStringGetTypeID()) continue;

            char text[2048];
            if (!CFStringGetCString(entry, text, sizeof(text), kCFStringEncodingUTF8)) continue;

            const char *cursor = text;
            const char *marker;
            while ((marker = strstr(cursor, ";tokenidentity;")) != NULL) {
                marker += strlen(";tokenidentity;");
                char hash[64] = {0};
                size_t length = 0;
                while (length < sizeof(hash) - 1 && isxdigit((unsigned char)marker[length])) {
                    hash[length] = (char)toupper((unsigned char)marker[length]);
                    length++;
                }
                if (length > 0) {
                    CFStringRef value = CFStringCreateWithCString(NULL, hash, kCFStringEncodingUTF8);
                    CFArrayAppendValue(hashes, value);
                    CFRelease(value);
                }
                cursor = marker + length;
            }
        }
        CFRelease(values);
    }
    CFRelease(record);
    CFRelease(node);
    CFRelease(session);

done:
    if (error) CFRelease(error);
    return hashes;
}

static CFStringRef copy_hex(CFDataRef data) {
    CFMutableStringRef hex = CFStringCreateMutable(NULL, 0);
    const UInt8 *bytes = CFDataGetBytePtr(data);
    for (CFIndex i = 0; i < CFDataGetLength(data); i++)
        CFStringAppendFormat(hex, NULL, CFSTR("%02X"), bytes[i]);
    return hex;
}

token_auth_result_t token_authenticate(const char *username,
                                       void (*log)(const char *message)) {
    if (!username) return TOKEN_AUTH_NO_TOKEN;

    CFArrayRef paired = copy_paired_hashes(username, log);
    if (CFArrayGetCount(paired) == 0) {
        emit(log, "%s has no paired smart-card identities", username);
        CFRelease(paired);
        return TOKEN_AUTH_NO_TOKEN;
    }

    const void *queryKeys[] = { kSecClass, kSecAttrKeyClass, kSecAttrAccessGroup,
                                kSecReturnRef, kSecReturnAttributes, kSecMatchLimit };
    const void *queryValues[] = { kSecClassKey, kSecAttrKeyClassPrivate,
                                  kSecAttrAccessGroupToken, kCFBooleanTrue,
                                  kCFBooleanTrue, kSecMatchLimitAll };
    CFDictionaryRef query = CFDictionaryCreate(NULL, queryKeys, queryValues, 6,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFArrayRef found = NULL;
    OSStatus status = SecItemCopyMatching(query, (CFTypeRef *)&found);
    CFRelease(query);
    if (status != errSecSuccess || !found) {
        emit(log, "no token keys available (status %d)", (int)status);
        CFRelease(paired);
        return TOKEN_AUTH_NO_TOKEN;
    }

    token_auth_result_t result = TOKEN_AUTH_NO_TOKEN;
    CFRange range = CFRangeMake(0, CFArrayGetCount(paired));

    for (CFIndex i = 0; i < CFArrayGetCount(found); i++) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(found, i);
        CFDataRef label = CFDictionaryGetValue(item, kSecAttrApplicationLabel);
        SecKeyRef key = (SecKeyRef)CFDictionaryGetValue(item, kSecValueRef);
        if (!label || !key) continue;

        // kSecAttrApplicationLabel on a key is the SHA-1 of its public key,
        // which is exactly the hash sc_auth pairs against.
        CFStringRef hex = copy_hex(label);
        bool isPaired = CFArrayContainsValue(paired, range, hex);
        char shown[64] = {0};
        CFStringGetCString(hex, shown, sizeof(shown), kCFStringEncodingUTF8);
        CFRelease(hex);
        if (!isPaired) continue;

        // From here a paired card is present, so a failure is a real failure
        // rather than a reason to fall through to the password.
        result = TOKEN_AUTH_FAILED;
        emit(log, "challenging paired identity %s", shown);

        UInt8 challenge[CHALLENGE_BYTES];
        if (SecRandomCopyBytes(kSecRandomDefault, sizeof(challenge), challenge) != errSecSuccess) {
            emit(log, "cannot generate a challenge");
            break;
        }
        CFDataRef digest = CFDataCreate(NULL, challenge, sizeof(challenge));

        SecKeyAlgorithm algorithm = kSecKeyAlgorithmECDSASignatureDigestX962SHA256;
        if (!SecKeyIsAlgorithmSupported(key, kSecKeyOperationTypeSign, algorithm))
            algorithm = kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256;

        // The call that reaches the token driver, and therefore the reader.
        CFErrorRef error = NULL;
        CFDataRef signature = SecKeyCreateSignature(key, algorithm, digest, &error);
        if (!signature) {
            emit(log, "signing failed");
            if (error) CFRelease(error);
            CFRelease(digest);
            continue;
        }

        SecKeyRef publicKey = SecKeyCopyPublicKey(key);
        bool verified = publicKey && SecKeyVerifySignature(publicKey, algorithm, digest,
                                                           signature, &error);
        if (publicKey) CFRelease(publicKey);
        if (error) CFRelease(error);
        CFRelease(signature);
        CFRelease(digest);

        if (verified) {
            emit(log, "signature verified; %s authenticated", username);
            result = TOKEN_AUTH_OK;
            break;
        }
        emit(log, "signature did not verify");
    }

    CFRelease(found);
    CFRelease(paired);
    return result;
}
