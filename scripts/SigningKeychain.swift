// Dedicated local signing-keychain management. Creation/import/unlock/deletion
// require explicit subcommands; there is no code-signing or trust-store API.
// Passwords are read only from owner-only files in owner-only directories.
// Compile: clang -c scripts/SigningKeyHeader.c -o /private/tmp/keywoo-signing-key-header.o
//   swiftc -module-cache-path /private/tmp/keydance-swift-module-cache \
//   -import-objc-header scripts/SigningKeyHeader.h scripts/SigningKeychain.swift \
//   /private/tmp/keywoo-signing-key-header.o -o /private/tmp/keywoo-signing-keychain-plan
// Run: ... plan /absolute/path/KeyWoo-local-signing.keychain-db
//      ... probe-acl
//      ... create KEYCHAIN PASSFILE P12FILE P12PASSFILE
//      ... unlock KEYCHAIN PASSFILE
//      ... delete KEYCHAIN PASSFILE  # only a keychain created by this helper
import Foundation
import Security
import CryptoKit
import Darwin

enum PlanError: Error, CustomStringConvertible {
    case usage, security(String, OSStatus), invalidPath, rejected(String)
    var description: String {
        switch self {
        case .usage: return "Usage: SigningKeychain plan PATH | probe-acl | create KEYCHAIN PASSFILE P12FILE P12PASSFILE | unlock KEYCHAIN PASSFILE | delete KEYCHAIN PASSFILE"
        case .invalidPath: return "A new absolute keychain path is required; existing paths are not accepted."
        case .security(let operation, let status):
            return "\(operation) failed (OSStatus \(status))."
        case .rejected(let reason): return reason
        }
    }
}

private func normalized(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
}

/// The private parent directory prevents path replacement by another user.
/// O_NOFOLLOW/fstat below additionally reject final-component symlinks and
/// validate the actual opened file instead of trusting a pre-open stat.
func validatePrivateParent(_ path: String) throws {
    guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path == normalized(path) else {
        throw PlanError.rejected("Paths must be absolute and must not traverse symlinks.")
    }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    let fd = Darwin.open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw PlanError.rejected("Cannot open the private parent directory.") }
    defer { Darwin.close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o777 == 0o700 else {
        throw PlanError.rejected("The parent directory must be owned by the current user with mode 0700.")
    }
}

func privateFile(_ path: String, maximumBytes: Int) throws -> Data {
    try validatePrivateParent(path)
    let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw PlanError.rejected("Cannot open a required private file.") }
    defer { Darwin.close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFREG,
          st.st_mode & 0o777 == 0o600, st.st_nlink == 1,
          st.st_size > 0, st.st_size <= maximumBytes else {
        throw PlanError.rejected("Private files must be regular owner-only mode-0600 files, without hard links, and within the size limit.")
    }
    var data = Data(count: Int(st.st_size))
    try data.withUnsafeMutableBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw PlanError.rejected("A private file changed or could not be read completely.") }
            offset += count
        }
    }
    return data
}

func passwordFile(_ path: String) throws -> Data {
    var data = try privateFile(path, maximumBytes: 4096)
    // Match OpenSSL's file-password convention, allowing one final newline.
    if data.last == 10 { data.removeLast(); if data.last == 13 { data.removeLast() } }
    guard !data.isEmpty, String(data: data, encoding: .utf8) != nil,
          !data.contains(0), !data.contains(10), !data.contains(13) else {
        throw PlanError.rejected("A password must be one nonempty UTF-8 line without NUL bytes.")
    }
    return data
}

func rawKeychainPath(_ keychain: SecKeychain) throws -> String {
    var bytes = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    var count = UInt32(bytes.count)
    try checked("SecKeychainGetPath", SecKeychainGetPath(keychain, &count, &bytes))
    return String(cString: bytes)
}

/// Security can return /tmp for the canonical /private/tmp, independent of
/// the caller's spelling. Canonicalize only this OS-provided path via realpath.
/// If Security supplies a non-existent logical .keychain name, resolve its
/// existing parent, retaining the basename for the exact -db alias check.
/// User-supplied paths still pass validatePrivateParent without relaxation.
func canonicalSecurityPath(_ path: String) throws -> String {
    guard path.hasPrefix("/") else { throw PlanError.rejected("Security returned a relative keychain path.") }
    if let resolved = realpath(path, nil) {
        defer { free(resolved) }
        return String(cString: resolved)
    }
    guard errno == ENOENT else { throw PlanError.rejected("Cannot canonicalize the Security keychain path: \(path).") }
    let url = URL(fileURLWithPath: path)
    guard let parent = realpath(url.deletingLastPathComponent().path, nil) else {
        throw PlanError.rejected("Cannot canonicalize the Security keychain parent: \(path).")
    }
    defer { free(parent) }
    return String(cString: parent) + "/" + url.lastPathComponent
}

func keychainPath(_ keychain: SecKeychain) throws -> String {
    try canonicalSecurityPath(rawKeychainPath(keychain))
}

func keychainAliases(_ databasePath: String) throws -> Set<String> {
    guard databasePath.hasSuffix(".keychain-db") else { throw PlanError.invalidPath }
    return [databasePath, String(databasePath.dropLast(3))]
}

/// Accept only the documented file-keychain spelling pair in the exact same
/// private directory. The physical database must exist, be regular and owned
/// by this UID; the alternate logical spelling must not be a filesystem link
/// or a competing legacy database.
func verifiedKeychainPath(_ keychain: SecKeychain, databasePath: String) throws -> String {
    try validatePrivateParent(databasePath)
    let reported = try keychainPath(keychain)
    guard try keychainAliases(databasePath).contains(reported) else {
        throw PlanError.rejected("Unexpected Security keychain path: requested=\(databasePath), returned=\(reported).")
    }
    let logical = String(databasePath.dropLast(3))
    var logicalStat = stat()
    guard lstat(logical, &logicalStat) != 0, errno == ENOENT else {
        throw PlanError.rejected("The logical keychain spelling is a competing file or link: \(logical).")
    }
    let fd = Darwin.open(databasePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
        throw PlanError.rejected("The expected physical keychain database is missing: requested=\(databasePath), returned=\(reported).")
    }
    defer { Darwin.close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFREG,
          st.st_mode & 0o077 == 0, st.st_nlink == 1 else {
        throw PlanError.rejected("The physical keychain database must be owner-only and must not be a link: \(databasePath).")
    }
    return reported
}

func searchList() throws -> [SecKeychain] {
    var list: CFArray?
    try checked("SecKeychainCopySearchList", SecKeychainCopySearchList(&list))
    guard let result = list as? [SecKeychain] else { throw PlanError.rejected("Could not inspect the user keychain search list.") }
    return result
}

func defaultKeychainPath() throws -> String {
    var keychain: SecKeychain?
    try checked("SecKeychainCopyDefault", SecKeychainCopyDefault(&keychain))
    guard let keychain else { throw PlanError.rejected("No default keychain exists; refusing a creation with ambiguous side effects.") }
    return try keychainPath(keychain)
}

/// Current Apple Security does not add ordinary private keychains to the search
/// list. If an older implementation adds this new keychain, remove only that
/// item from a fresh list. Never restore an old whole-list snapshot.
func removeOnlyOwnedSearchEntry(_ path: String) throws {
    let aliases = try keychainAliases(path)
    let current = try searchList()
    let filtered = try current.filter { try !aliases.contains(keychainPath($0)) }
    if filtered.count != current.count {
        try checked("remove newly created search-list entry", SecKeychainSetSearchList(filtered as CFArray))
        guard try !searchList().contains(where: { try aliases.contains(keychainPath($0)) }) else {
            throw PlanError.rejected("The dedicated keychain remained in the search list.")
        }
    }
}

func restrictedAccess() throws -> SecAccess {
    var application: SecTrustedApplication?, access: SecAccess?
    try checked("SecTrustedApplicationCreateFromPath", SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &application))
    guard let application else { throw PlanError.security("trusted application", errSecInternalError) }
    try checked("SecAccessCreate", SecAccessCreate("KeyWoo local signing identity" as CFString, [application] as CFArray, &access))
    guard let access else { throw PlanError.security("access object", errSecInternalError) }
    return access
}

func certificateHashes(_ identity: SecIdentity) throws -> [String: String] {
    var certificate: SecCertificate?
    try checked("SecIdentityCopyCertificate", SecIdentityCopyCertificate(identity, &certificate))
    guard let certificate else { throw PlanError.security("identity certificate", errSecInternalError) }
    let data = SecCertificateCopyData(certificate) as Data
    return ["certificateSHA1": Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "certificateSHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
}

func identityIn(_ keychain: SecKeychain) throws -> SecIdentity {
    let query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecMatchSearchList: [keychain],
                                kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true]
    var value: CFTypeRef?
    try checked("query dedicated signing identity", SecItemCopyMatching(query as CFDictionary, &value))
    guard let entries = value as? [AnyObject], entries.count == 1,
          CFGetTypeID(entries[0]) == SecIdentityGetTypeID() else {
        throw PlanError.rejected("The dedicated keychain must contain exactly one signing identity.")
    }
    return unsafeBitCast(entries[0], to: SecIdentity.self)
}

/// Query non-encrypted record attributes only. SecKeyCopyAttributes is avoided:
/// the legacy CDSA implementation also tries to fill kSecValueData by exporting
/// the key. Both queries below explicitly disable data/reference return and UI.
/// A missing attribute is reported as unavailable, never mistaken for false.
func verifiedKeyAttributes(_ identity: SecIdentity, in keychain: SecKeychain) throws -> [String: Any] {
    var key: SecKey?
    try checked("SecIdentityCopyPrivateKey", SecIdentityCopyPrivateKey(identity, &key))
    guard let key else { throw PlanError.rejected("The identity has no private-key reference.") }
    var query: [CFString: Any] = [
        kSecClass: kSecClassKey, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        kSecMatchSearchList: [keychain], kSecMatchLimit: kSecMatchLimitAll,
        kSecReturnAttributes: true, kSecReturnData: false, kSecReturnRef: false,
        kSecUseNoAuthenticationUI: true,
    ]
    var value: CFTypeRef?
    try checked("query dedicated private-key attributes", SecItemCopyMatching(query as CFDictionary, &value))
    guard let rows = value as? [[String: Any]], rows.count == 1 else {
        throw PlanError.rejected("The dedicated keychain must contain exactly one private-key record.")
    }
    let attributes = rows[0]
    // Match the already-selected identity's private-key reference against the
    // same keychain, using the documented macOS record subset filter. This is
    // only an attributes query, not an export or a private-key operation.
    query[kSecMatchItemList] = [key]
    query[kSecMatchLimit] = kSecMatchLimitOne
    value = nil
    try checked("match identity private-key attributes", SecItemCopyMatching(query as CFDictionary, &value))
    guard let selected = value as? [String: Any],
          let soleLabel = attributes[kSecAttrApplicationLabel as String] as? Data,
          let selectedLabel = selected[kSecAttrApplicationLabel as String] as? Data,
          !soleLabel.isEmpty, soleLabel == selectedLabel else {
        throw PlanError.rejected("The sole private-key record does not match the selected signing identity.")
    }
    let fields: [(String, CFString)] = [
        ("canSign", kSecAttrCanSign), ("canDecrypt", kSecAttrCanDecrypt),
        ("canDerive", kSecAttrCanDerive), ("canUnwrap", kSecAttrCanUnwrap),
        ("isExtractable", kSecAttrIsExtractable), ("isSensitive", kSecAttrIsSensitive),
        ("isPermanent", kSecAttrIsPermanent)
    ]
    var result: [String: Any] = [:]
    for (name, attribute) in fields {
        result[name] = (attributes[attribute as String] as? NSNumber).map { $0.boolValue as Any } ?? "unavailable"
    }
    // File-keychain record queries omit sensitivity/extractability on this OS.
    // The tiny C shim uses public SecKeyGetCSSMKey (unavailable directly in
    // Swift) and returns only header usage/attribute flags. It verifies private
    // key class internally and never reads KeyData or exports anything.
    var headerUsage: UInt32 = 0, headerAttributes: UInt32 = 0
    try withExtendedLifetime(key) {
        try checked("SecKeyGetCSSMKey header only", KWCopySigningKeyHeader(key, &headerUsage, &headerAttributes))
    }
    guard headerUsage == UInt32(CSSM_KEYUSE_SIGN) else {
        throw PlanError.rejected("The identity's legacy key header is not a sign-only private key.")
    }
    let extracted = headerAttributes & UInt32(CSSM_KEYATTR_EXTRACTABLE) != 0
    let sensitive = headerAttributes & UInt32(CSSM_KEYATTR_SENSITIVE) != 0
    if let recorded = result["isExtractable"] as? Bool, recorded != extracted {
        throw PlanError.rejected("Private-key record and header disagree on extractability.")
    }
    if let recorded = result["isSensitive"] as? Bool, recorded != sensitive {
        throw PlanError.rejected("Private-key record and header disagree on sensitivity.")
    }
    result["isExtractable"] = extracted
    result["isSensitive"] = sensitive
    result["sensitivityAndExtractabilitySource"] = "SecKeyGetCSSMKey.KeyHeader only"
    result["legacyKeyHeader"] = ["keyUsage": headerUsage, "keyAttributes": headerAttributes]
    guard result["canSign"] as? Bool == true,
          result["isExtractable"] as? Bool == false, result["isSensitive"] as? Bool == true else {
        let publicData = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        throw PlanError.rejected("The imported key did not verify as signing-capable and nonextractable: " + String(decoding: publicData, as: UTF8.self))
    }
    for field in ["canDecrypt", "canDerive", "canUnwrap"] where result[field] as? Bool == true {
        throw PlanError.rejected("The imported key unexpectedly permits a non-signing private-key operation: \(field).")
    }
    return result
}

struct ManagedKeychainMarker: Codable {
    let schema: Int
    let purpose: String
    let uid: UInt32
    let path: String
    let logicalPath: String
    let certificateSHA256: String
}

func markerPath(_ path: String) -> String { path + ".keywoo-managed.json" }

func writeMarker(_ value: ManagedKeychainMarker) throws {
    let data = try JSONEncoder().encode(value)
    let fd = Darwin.open(markerPath(value.path), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw PlanError.rejected("Could not create the dedicated-keychain ownership marker.") }
    defer { Darwin.close(fd) }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw PlanError.rejected("Could not save the dedicated-keychain ownership marker.") }
            offset += count
        }
    }
    guard fsync(fd) == 0 else { throw PlanError.rejected("Could not flush the dedicated-keychain marker.") }
}

func openManagedKeychain(_ path: String, passwordPath: String) throws -> SecKeychain {
    try validatePrivateParent(path)
    let marker = try JSONDecoder().decode(ManagedKeychainMarker.self,
        from: privateFile(markerPath(path), maximumBytes: 4096))
    guard marker.schema == 2, marker.purpose == "KeyWoo dedicated code signing", marker.uid == getuid(), marker.path == path,
          try keychainAliases(path).contains(marker.logicalPath) else {
        throw PlanError.rejected("The ownership marker does not identify this dedicated signing keychain.")
    }
    // Validate only the database file's ownership/mode, not its secret contents.
    let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw PlanError.rejected("The dedicated keychain file is missing.") }
    var st = stat(); let status = fstat(fd, &st); Darwin.close(fd)
    guard status == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFREG, st.st_mode & 0o077 == 0 else {
        throw PlanError.rejected("The dedicated keychain database is not owner-only.")
    }
    var password = try passwordFile(passwordPath)
    defer { password.resetBytes(in: 0..<password.count) }
    var keychain: SecKeychain?
    try checked("SecKeychainOpen", SecKeychainOpen(path, &keychain))
    guard let keychain, try verifiedKeychainPath(keychain, databasePath: path) == marker.logicalPath else { throw PlanError.invalidPath }
    try password.withUnsafeBytes { bytes in
        try checked("SecKeychainUnlock", SecKeychainUnlock(keychain, UInt32(bytes.count), bytes.baseAddress, true))
    }
    let identity = try identityIn(keychain)
    let hashes = try certificateHashes(identity)
    _ = try verifiedKeyAttributes(identity, in: keychain)
    guard hashes["certificateSHA256"] == marker.certificateSHA256 else {
        throw PlanError.rejected("The identity certificate no longer matches the dedicated-keychain marker.")
    }
    return keychain
}

func createKeychain(path: String, passwordPath: String, p12Path: String, p12PasswordPath: String) throws -> [String: Any] {
    try validatePrivateParent(path)
    guard path.hasSuffix(".keychain-db"), !FileManager.default.fileExists(atPath: path),
          !FileManager.default.fileExists(atPath: String(path.dropLast(3))),
          !FileManager.default.fileExists(atPath: markerPath(path)) else { throw PlanError.invalidPath }
    let priorDefault = try defaultKeychainPath()
    let priorList = try searchList().map(keychainPath)
    let aliases = try keychainAliases(path)
    guard priorList.allSatisfy({ !aliases.contains($0) }) else { throw PlanError.rejected("The requested keychain is already referenced by the search list.") }
    var password = try passwordFile(passwordPath), p12Password = try passwordFile(p12PasswordPath)
    var p12 = try privateFile(p12Path, maximumBytes: 4 * 1024 * 1024)
    defer {
        password.resetBytes(in: 0..<password.count)
        p12Password.resetBytes(in: 0..<p12Password.count)
        p12.resetBytes(in: 0..<p12.count)
    }
    let access = try restrictedAccess()
    var keychain: SecKeychain?
    try password.withUnsafeBytes { bytes in
        try checked("SecKeychainCreate", SecKeychainCreate(path, UInt32(bytes.count), bytes.baseAddress, false, nil, &keychain))
    }
    guard let keychain else { throw PlanError.security("new keychain", errSecInternalError) }
    var committed = false
    defer {
        if !committed {
            // Only this just-created keychain can be rolled back, never an
            // existing user keychain. Report cleanup failure without secrets.
            let deletion = SecKeychainDelete(keychain)
            if deletion != errSecSuccess {
                FileHandle.standardError.write(Data("Rollback of new keychain failed (OSStatus \(deletion)).\n".utf8))
            }
            try? FileManager.default.removeItem(atPath: markerPath(path))
        }
    }
    let rawPath = try rawKeychainPath(keychain)
    let actualPath = try canonicalSecurityPath(rawPath)
    // Public paths only: useful evidence if an OS uses the logical alias.
    let pathDiagnostic = try JSONSerialization.data(withJSONObject: ["operation": "keychain-path-resolution", "requestedDatabasePath": path, "securityReturnedPath": rawPath, "canonicalSecurityPath": actualPath], options: [.sortedKeys])
    FileHandle.standardError.write(pathDiagnostic); FileHandle.standardError.write(Data([10]))
    _ = try verifiedKeychainPath(keychain, databasePath: path)
    var settings = SecKeychainSettings(version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1), lockOnSleep: true,
                                       useLockInterval: true, lockInterval: 300)
    try checked("SecKeychainSetSettings on new dedicated keychain", SecKeychainSetSettings(keychain, &settings))
    var actualSettings = SecKeychainSettings()
    actualSettings.version = UInt32(SEC_KEYCHAIN_SETTINGS_VERS1)
    try checked("SecKeychainCopySettings", SecKeychainCopySettings(keychain, &actualSettings))
    let actualSettingsReport: [String: Any] = ["version": actualSettings.version,
        "lockOnSleep": actualSettings.lockOnSleep.boolValue, "useLockInterval": "not_written_by_API",
        "lockIntervalSeconds": actualSettings.lockInterval]
    let settingsDiagnostic = try JSONSerialization.data(withJSONObject: ["operation": "keychain-settings-readback",
        "setSettingsStatus": 0, "copySettingsStatus": 0, "actualSettings": actualSettingsReport], options: [.sortedKeys])
    FileHandle.standardError.write(settingsDiagnostic); FileHandle.standardError.write(Data([10]))
    // Apple's SecKeychain.cpp copies only lockOnSleep and lockInterval. The
    // legacy useLockInterval struct field is not a read-back result.
    guard actualSettings.lockOnSleep.boolValue, actualSettings.lockInterval == 300 else {
        throw PlanError.rejected("The dedicated keychain did not retain its requested lock policy; actual public settings: " + String(decoding: settingsDiagnostic, as: UTF8.self))
    }
    try removeOnlyOwnedSearchEntry(path)
    guard try defaultKeychainPath() == priorDefault else {
        throw PlanError.rejected("Default keychain changed unexpectedly; this helper does not change defaults.")
    }
    let passphrase = p12Password as CFData
    let usage = [kSecAttrCanSign] as CFArray
    // Deliberately omit kSecAttrIsExtractable (the default would include it).
    let attributes = [kSecAttrIsPermanent, kSecAttrIsSensitive] as CFArray
    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    parameters.flags = [.importOnlyOne]
    parameters.passphrase = Unmanaged.passUnretained(passphrase)
    parameters.accessRef = Unmanaged.passUnretained(access)
    parameters.keyUsage = Unmanaged.passUnretained(usage)
    parameters.keyAttributes = Unmanaged.passUnretained(attributes)
    var format = SecExternalFormat.formatPKCS12
    var itemType = SecExternalItemType.itemTypeAggregate
    var items: CFArray?
    try withExtendedLifetime((passphrase, access, usage, attributes)) {
        try checked("SecItemImport", SecItemImport(p12 as CFData, "p12" as CFString, &format, &itemType,
                                                   [], &parameters, keychain, &items))
    }
    let identity = try identityIn(keychain)
    let hashes = try certificateHashes(identity)
    let keyAttributes = try verifiedKeyAttributes(identity, in: keychain)
    try writeMarker(ManagedKeychainMarker(schema: 2, purpose: "KeyWoo dedicated code signing", uid: getuid(),
                                        path: path, logicalPath: actualPath, certificateSHA256: hashes["certificateSHA256"]!))
    try removeOnlyOwnedSearchEntry(path)
    guard try defaultKeychainPath() == priorDefault else { throw PlanError.rejected("Default keychain changed unexpectedly.") }
    let afterList = try searchList().map(keychainPath)
    committed = true
    return ["operation": "create", "keychainPath": path, "logicalKeychainPath": actualPath, "identity": hashes,
            "actualKeyAttributes": keyAttributes,
            "settings": actualSettingsReport,
            "requestedSignOnly": true, "requestedNonextractable": true,
            "restrictedApplication": "/usr/bin/codesign", "defaultUnchanged": true,
            "searchListUnchanged": afterList == priorList, "dedicatedKeychainInSearchList": afterList.contains(where: aliases.contains),
            "trustModified": false]
}

func checked(_ operation: String, _ status: OSStatus) throws {
    if status != errSecSuccess { throw PlanError.security(operation, status) }
}

func output(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

/// Creates only detached Core Foundation ACL objects in this process. They are
/// never attached to a key or written to any keychain.
func inspectRestrictedACL() throws -> [String: Any] {
    var codesign: SecTrustedApplication?
    try checked("SecTrustedApplicationCreateFromPath", SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &codesign))
    guard let codesign else { throw PlanError.security("trusted application", errSecInternalError) }
    var access: SecAccess?
    try checked("SecAccessCreate", SecAccessCreate("KeyWoo local signing identity" as CFString, [codesign] as CFArray, &access))
    guard let access else { throw PlanError.security("access object", errSecInternalError) }
    var acls: CFArray?
    try checked("SecAccessCopyACLList", SecAccessCopyACLList(access, &acls))
    var entries: [[String: Any]] = []
    for acl in (acls as? [SecACL] ?? []) {
        var applications: CFArray?, description: CFString?
        var prompt = SecKeychainPromptSelector()
        try checked("SecACLCopyContents", SecACLCopyContents(acl, &applications, &description, &prompt))
        let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
        entries.append([
            "authorizations": authorizations,
            "trustedApplications": applications == nil ? "all applications (safe-operation ACL)" : "explicit list",
            "trustedApplicationCount": applications.map(CFArrayGetCount) ?? -1,
        ])
    }
    return ["persisted": false, "keychainOpened": false, "trustedRestrictedApplication": "/usr/bin/codesign", "entries": entries]
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.count == 5, args[0] == "create" {
        try output(createKeychain(path: args[1], passwordPath: args[2], p12Path: args[3], p12PasswordPath: args[4]))
    } else if args.count == 3, args[0] == "unlock" {
        let keychain = try openManagedKeychain(args[1], passwordPath: args[2])
        let identity = try identityIn(keychain)
        try output(["operation": "unlock", "keychainPath": args[1], "logicalKeychainPath": keychainPath(keychain),
                    "identity": certificateHashes(identity), "actualKeyAttributes": verifiedKeyAttributes(identity, in: keychain), "trustModified": false])
    } else if args.count == 3, args[0] == "delete" {
        let keychain = try openManagedKeychain(args[1], passwordPath: args[2])
        guard try !keychainAliases(args[1]).contains(defaultKeychainPath()) else {
            throw PlanError.rejected("Refusing to delete the default keychain.")
        }
        try removeOnlyOwnedSearchEntry(args[1])
        try checked("SecKeychainDelete", SecKeychainDelete(keychain))
        try FileManager.default.removeItem(atPath: markerPath(args[1]))
        try output(["operation": "delete", "deletedDedicatedKeychain": true, "trustModified": false])
    } else if args == ["probe-acl"] {
        try output(inspectRestrictedACL())
    } else if args.count == 2, args[0] == "plan" {
        let path = args[1]
        guard path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) else { throw PlanError.invalidPath }
        try output([
            "dryRun": true, "persistentChanges": false, "keychainPath": path,
            "restrictedPrivateKeyApplication": "/usr/bin/codesign",
            "proposedSteps": [
                "Create a dedicated keychain through SecKeychainCreate with a random UTF-8 password received over an inherited pipe; never argv, environment, shell history or logs.",
                "Read the encrypted PKCS12 and its distinct passphrase through bounded inherited file descriptors; do not print either.",
                "Use SecTrustedApplicationCreateFromPath(/usr/bin/codesign), SecAccessCreate with exactly that trusted application, and SecItemImportExportKeyParameters.accessRef.",
                "Call SecItemImport into the explicit dedicated keychain, format PKCS12, importOnlyOne flag, keyUsage [kSecAttrCanSign], keyAttributes [kSecAttrIsPermanent,kSecAttrIsSensitive]; do not use noAccessControl or default extractable attributes.",
                "Retain the CF objects backing Unmanaged import parameter fields until SecItemImport returns; require exactly one SecIdentity and verify the expected certificate fingerprint.",
                "Sign only a disposable copy with --keychain EXPLICIT_PATH and the exact identity fingerprint. Determine actual signing-policy compatibility before changing the installed app.",
                "Use an explicit certificate-pinned designated requirement if chosen by the owner; compare that requirement across two independently signed copies with changed resource seals.",
                "Keep the current app untouched; after authorized adoption close it, sign a fresh complete bundle, verify payload equivalence, then replace via new inode and retain the old bundle."
            ],
            "excludedOperations": ["SecTrustSettingsSetTrustSettings", "security add-trusted-cert", "TLS/SSL trust changes", "system keychain", "default keychain change", "search-list change", "security import -A", "broad apple: partition grants", "TCC database writes"],
            "unverified": [
                "No persistent identity has been created or imported by this helper.",
                "A certificate-pinned requirement avoiding trust lookup does not prove this macOS signer accepts an untrusted self-signed identity.",
                "Modern partition ACL behavior must be observed in an authorized disposable signing probe; do not automatically broaden ACLs on failure.",
                "Creating a file keychain may itself affect the user search list on some versions; snapshot and inspect it before and after an authorized future create. Explicit keychain selection must not become a broad default/search-list rewrite."
            ]
        ])
    } else { throw PlanError.usage }
} catch {
    FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
    exit(1)
}
