#!/usr/bin/env python3
"""Applies deterministic fixes to a checkout of amosavian/AMSMB2 (commit 8d8e19e):
1. Preserve real libsmb2 NTSTATUS & error strings when session setup / tree connect / service fails.
2. Replace `fd > 0` guard in `generic_handler` with an explicit teardown opaque sentinel so
   error callbacks arriving after `smb2_close_context()` are never dropped.
3. Pass NULL (`nil`) rather than empty string "" for unset domain / workstation so libsmb2's
   NTLMSSP adopts the Windows server target_name domain.
4. Fall back cleanly in `listShares()` (shareEnum -> shareEnumSwift) and `connect()`
   (auto target_name -> explicit empty domain -> SMB 3.0.2 compatibility dialect).
"""

import pathlib
import sys


def replace_exact(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"Expected 1 match for [{label}], found {count}")
    return text.replace(old, new, 1)


def patch_context_swift(path: pathlib.Path) -> None:
    text = path.read_text(encoding="utf-8")

    # 1. Computed destroying sentinel property on SMB2Client (Swift 6 Sendable-safe)
    old_sentinel_anchor = """final class SMB2Client: CustomDebugStringConvertible, CustomReflectable, @unchecked Sendable {
    var context: UnsafeMutablePointer<smb2_context>?
    private var _context_lock = NSRecursiveLock()"""
    new_sentinel_anchor = """final class SMB2Client: CustomDebugStringConvertible, CustomReflectable, @unchecked Sendable {
    private static var destroyingSentinel: UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(bitPattern: 0xDEAD)!
    }

    var context: UnsafeMutablePointer<smb2_context>?
    private var _context_lock = NSRecursiveLock()"""
    text = replace_exact(text, old_sentinel_anchor, new_sentinel_anchor, "Context.destroyingSentinel")

    # 2. Mark opaque sentinel in deinit before smb2_destroy_context
    old_deinit = """        try? withThreadSafeContext { context in
            self.context = nil
            smb2_destroy_context(context)
        }"""
    new_deinit = """        try? withThreadSafeContext { context in
            smb2_set_opaque(context, SMB2Client.destroyingSentinel)
            self.context = nil
            smb2_destroy_context(context)
        }"""
    text = replace_exact(text, old_deinit, new_deinit, "Context.deinit")

    # 3. Pass nil when workstation/domain are empty, plus setRawDomain / setNegotiateVersion helpers
    old_ws_domain = """    var workstation: String {
        get {
            smb2_get_workstation(context).map(String.init(cString:)) ?? ""
        }
        set {
            try? withThreadSafeContext { context in
                smb2_set_workstation(context, newValue)
            }
        }
    }
    
    var domain: String {
        get {
            smb2_get_domain(context).map(String.init(cString:)) ?? ""
        }
        set {
            try? withThreadSafeContext { context in
                smb2_set_domain(context, newValue)
            }
        }
    }"""
    new_ws_domain = """    var workstation: String {
        get {
            smb2_get_workstation(context).map(String.init(cString:)) ?? ""
        }
        set {
            try? withThreadSafeContext { context in
                smb2_set_workstation(context, newValue.isEmpty ? nil : newValue)
            }
        }
    }
    
    var domain: String {
        get {
            smb2_get_domain(context).map(String.init(cString:)) ?? ""
        }
        set {
            try? withThreadSafeContext { context in
                smb2_set_domain(context, newValue.isEmpty ? nil : newValue)
            }
        }
    }

    func setRawDomain(_ rawDomain: String?) {
        try? withThreadSafeContext { context in
            smb2_set_domain(context, rawDomain)
        }
    }

    func setNegotiateVersion(_ version: Version) {
        try? withThreadSafeContext { context in
            smb2_set_version(context, version)
        }
    }"""
    text = replace_exact(text, old_ws_domain, new_ws_domain, "Context.workstation_domain")

    # 4 & 5. formatError helper + capture ntError/errorString before smb2_destroy_context in service(revents:)
    old_service = """    func service(revents: Int32) throws {
        let result = smb2_service(context, revents)
        if result < 0 {
            smb2_destroy_context(context)
            context = nil
            try POSIXError.throwIfError(result, description: errorString)
        }
    }"""
    new_service = """    fileprivate static func formatError(
        ntStatus: NTStatus,
        message: String?,
        fallbackResult: Int32
    ) -> (Errno, String) {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let code: Errno = ntStatus != .success ? ntStatus.errno : Errno(rawValue: CInt(max(1, -fallbackResult)))
        var parts: [String] = []
        if ntStatus != .success {
            parts.append(ntStatus.description)
        }
        if !trimmed.isEmpty {
            if ntStatus == .success || !trimmed.contains(ntStatus.localizedDescription) {
                parts.append(trimmed)
            }
        }
        let detail = parts.isEmpty ? "SMB error (\\(code))" : parts.joined(separator: " | ")
        return (code, detail)
    }

    func service(revents: Int32) throws {
        let result = smb2_service(context, revents)
        if result < 0 {
            let capturedNT = ntError
            let capturedErr = errorString
            if let ctx = context {
                smb2_set_opaque(ctx, SMB2Client.destroyingSentinel)
                context = nil
                smb2_destroy_context(ctx)
            }
            let (code, detail) = Self.formatError(
                ntStatus: capturedNT,
                message: capturedErr,
                fallbackResult: result
            )
            throw POSIXError(code, description: detail)
        }
    }"""
    text = replace_exact(text, old_service, new_service, "Context.service")

    # 6. Expand CBData to preserve NTStatus and error description
    old_cbdata = """    private class CBData {
        var result: Int32 = .init(NTStatus.success.rawValue)
        var isFinished: Bool = false
        var dataHandler: ((UnsafeMutableRawPointer?) -> Void)?
        var status: NTStatus {
            NTStatus(rawValue: result)
        }
    }"""
    new_cbdata = """    private class CBData {
        var result: Int32 = .init(NTStatus.success.rawValue)
        var ntStatus: NTStatus = .success
        var errorDescription: String?
        var isFinished: Bool = false
        var dataHandler: ((UnsafeMutableRawPointer?) -> Void)?
        var status: NTStatus {
            NTStatus(rawValue: result)
        }
    }"""
    text = replace_exact(text, old_cbdata, new_cbdata, "Context.CBData")

    # 7. Set opaque sentinel in abandonConnection() before smb2_destroy_context()
    old_abandon = """    private func abandonConnection() {
        guard let context else { return }
        self.context = nil
        smb2_destroy_context(context)
    }"""
    new_abandon = """    private func abandonConnection() {
        guard let context else { return }
        smb2_set_opaque(context, SMB2Client.destroyingSentinel)
        self.context = nil
        smb2_destroy_context(context)
    }"""
    text = replace_exact(text, old_abandon, new_abandon, "Context.abandonConnection")

    # 8. In poll_for_reply(), break cleanly if callback already finished when service() throws
    old_poll = """            try service(revents: Int32(pfd.revents))
        }
    }"""
    new_poll = """            do {
                try service(revents: Int32(pfd.revents))
            } catch {
                if cb.isFinished {
                    break
                }
                throw error
            }
        }
    }"""
    text = replace_exact(text, old_poll, new_poll, "Context.poll_for_reply")

    # 9. Replace fd > 0 check with opaque sentinel + capture nterror and error string
    old_handler = """    static let generic_handler: smb2_command_cb = { smb2, status, command_data, cbdata in
        do {
            guard try smb2.unwrap().pointee.fd > 0 else { return }
            let cbdata = try cbdata.unwrap().bindMemory(to: CBData.self, capacity: 1).pointee
            if NTStatus(rawValue: status) != .success {
                cbdata.result = status
            }
            cbdata.dataHandler?(command_data)
            cbdata.isFinished = true
        } catch {}
    }"""
    new_handler = """    static let generic_handler: smb2_command_cb = { smb2, status, command_data, cbdata in
        do {
            let smb2Ptr = try smb2.unwrap()
            guard smb2_get_opaque(smb2Ptr) != SMB2Client.destroyingSentinel else { return }
            let cbdata = try cbdata.unwrap().bindMemory(to: CBData.self, capacity: 1).pointee
            if NTStatus(rawValue: status) != .success {
                cbdata.result = status
            }
            let nt = NTStatus(rawValue: smb2_get_nterror(smb2Ptr))
            if nt != .success {
                cbdata.ntStatus = nt
            }
            if let errPtr = smb2_get_error(smb2Ptr) {
                let msg = String(cString: errPtr).trimmingCharacters(in: .whitespacesAndNewlines)
                if !msg.isEmpty {
                    cbdata.errorDescription = msg
                }
            }
            cbdata.dataHandler?(command_data)
            cbdata.isFinished = true
        } catch {}
    }"""
    text = replace_exact(text, old_handler, new_handler, "Context.generic_handler")

    # 10. Throw rich formatted error from async_await when cbResult < 0
    old_throw = """            let cbResult = cb.result
            
            try POSIXError.throwIfError(cbResult, description: errorString)
            if let error = dataHandlerError { throw error }"""
    new_throw = """            let cbResult = cb.result
            if cbResult < 0 {
                let capturedNT = cb.ntStatus != .success ? cb.ntStatus : ntError
                let capturedMsg = cb.errorDescription ?? errorString
                let (code, detail) = Self.formatError(
                    ntStatus: capturedNT,
                    message: capturedMsg,
                    fallbackResult: cbResult
                )
                throw POSIXError(code, description: detail)
            }
            if let error = dataHandlerError { throw error }"""
    text = replace_exact(text, old_throw, new_throw, "Context.async_await_throw")

    path.write_text(text, encoding="utf-8")


def patch_amsmb2_swift(path: pathlib.Path) -> None:
    text = path.read_text(encoding="utf-8")

    # 1. Fall back from shareEnum() to shareEnumSwift() in listShares()
    old_list_shares = """    open func listShares(
        enumerateHidden: Bool = false,
        completionHandler: @Sendable @escaping (_ result: Result<[(name: String, comment: String)], any Error>) -> Void
    ) {
        // Connecting to Interprocess Communication share
        with(shareName: "IPC$", encrypted: false, completionHandler: completionHandler) { client in
            try client.shareEnum().map(enumerateHidden: enumerateHidden)
        }
    }"""
    new_list_shares = """    open func listShares(
        enumerateHidden: Bool = false,
        completionHandler: @Sendable @escaping (_ result: Result<[(name: String, comment: String)], any Error>) -> Void
    ) {
        // Connecting to Interprocess Communication share
        with(shareName: "IPC$", encrypted: false, completionHandler: completionHandler) { client in
            do {
                return try client.shareEnum().map(enumerateHidden: enumerateHidden)
            } catch let dcerpcError {
                do {
                    if client.isActive {
                        return try client.shareEnumSwift().map(enumerateHidden: enumerateHidden)
                    }
                    let fresh = try self.connect(shareName: "IPC$", encrypted: false)
                    defer {
                        if fresh.isActive {
                            try? fresh.disconnect()
                        }
                    }
                    return try fresh.shareEnumSwift().map(enumerateHidden: enumerateHidden)
                } catch {
                    throw dcerpcError
                }
            }
        }
    }"""
    text = replace_exact(text, old_list_shares, new_list_shares, "AMSMB2.listShares")

    # 2. Compatibility fallbacks in connect(shareName:encrypted:)
    old_connect = """    private func connect(shareName: String, encrypted: Bool) throws -> SMB2Client {
        let client = try SMB2Client()
        self.client = client
        initClient(client, encrypted: encrypted)
        let server = url.host! + (url.port.map { ":\\($0)" } ?? "")
        try client.connect(server: server, share: shareName, user: _user)
        return client
    }"""
    new_connect = """    private func isLogonFailure(_ error: any Error) -> Bool {
        let upper = error.localizedDescription.uppercased()
        return upper.contains("STATUS_LOGON_FAILURE") || upper.contains("0XC000006D") || upper.contains("LOGON_FAILURE")
    }

    private func connect(shareName: String, encrypted: Bool) throws -> SMB2Client {
        let server = url.host! + (url.port.map { ":\\($0)" } ?? "")

        let firstClient = try SMB2Client()
        self.client = firstClient
        initClient(firstClient, encrypted: encrypted)
        do {
            try firstClient.connect(server: server, share: shareName, user: _user)
            return firstClient
        } catch let firstError {
            var allLogonFailures = isLogonFailure(firstError)

            if _domain.isEmpty {
                if let secondClient = try? SMB2Client() {
                    self.client = secondClient
                    initClient(secondClient, encrypted: encrypted)
                    secondClient.setRawDomain("")
                    do {
                        try secondClient.connect(server: server, share: shareName, user: _user)
                        return secondClient
                    } catch let secondError {
                        allLogonFailures = allLogonFailures && isLogonFailure(secondError)
                    }
                }
            }

            if !allLogonFailures {
                if let thirdClient = try? SMB2Client() {
                    self.client = thirdClient
                    initClient(thirdClient, encrypted: encrypted)
                    thirdClient.setNegotiateVersion(.v3_02)
                    do {
                        try thirdClient.connect(server: server, share: shareName, user: _user)
                        return thirdClient
                    } catch {
                        // Fall through and report firstError below.
                    }
                }
            }

            self.client = nil
            throw firstError
        }
    }"""
    text = replace_exact(text, old_connect, new_connect, "AMSMB2.connect")

    path.write_text(text, encoding="utf-8")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <amsmb2_dir>", file=sys.stderr)
        return 2
    root = pathlib.Path(sys.argv[1])
    patch_context_swift(root / "AMSMB2" / "Context.swift")
    patch_amsmb2_swift(root / "AMSMB2" / "AMSMB2.swift")
    print(f"Patched AMSMB2 cleanly in {root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
