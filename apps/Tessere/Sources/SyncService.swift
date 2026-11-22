import Foundation
import CryptoKit
import UIKit
import TessereCore

/// AES-GCM with the family key (32 bytes, kept in the Keychain and passed
/// to new members only inside the invite link / QR).
struct AESGCMCipher: SyncCipher {
    let key: SymmetricKey

    func seal(_ plain: Data) throws -> String {
        guard let combined = try AES.GCM.seal(plain, using: key).combined else { throw SyncError.badPayload }
        return combined.base64EncodedString()
    }

    func open(_ sealed: String) throws -> Data {
        guard let raw = Data(base64Encoded: sealed) else { throw SyncError.badPayload }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: raw), using: key)
    }
}

/// HTTP client of the Cloudflare Worker (backend/).
struct ServerAPI {
    let base: URL
    let token: String?

    struct Device: Decodable { let deviceId: String; let token: String }
    struct Health: Decodable { let ok: Bool; let passSigning: Bool?; let version: String? }
    struct Space: Decodable { let spaceId: String; let name: String? }
    struct Invite: Decodable { let code: String; let expiresAt: String? }
    struct Joined: Decodable { let deviceId: String; let token: String; let spaceId: String; let spaceName: String? }
    struct Member: Decodable, Identifiable {
        let deviceId: String
        let name: String
        let joinedAt: String?
        let isYou: Bool?
        let isOwner: Bool?
        var id: String { deviceId }
    }
    struct SpaceInfo: Decodable { let spaceId: String; let name: String?; let ownerDeviceId: String?; let members: [Member] }
    struct OK: Decodable { let ok: Bool? }
    struct ErrorBody: Decodable { let error: String }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func request(_ method: String, _ path: String, body: Encodable? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONFileStore<Int>.encoder(compact: true).encode(AnyEncodable(body))
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: req)
        } catch {
            throw SyncError.server("Server non raggiungibile: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw SyncError.server("Risposta non valida dal server") }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw SyncError.server(msg ?? "Errore del server (\(http.statusCode))")
        }
        return (data, http)
    }

    func call<T: Decodable>(_ method: String, _ path: String, body: Encodable? = nil) async throws -> T {
        let (data, _) = try await request(method, path, body: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SyncError.server("Risposta del server non leggibile")
        }
    }

    func health() async throws -> Health { try await call("GET", "v1/health") }

    func sync(_ body: SyncRequest) async throws -> SyncResponse { try await call("POST", "v1/sync", body: body) }

    func pass(_ body: PassRequest) async throws -> Data {
        let (data, http) = try await request("POST", "v1/pass", body: body)
        guard (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("pkpass") else {
            throw SyncError.server("Il server non ha restituito un pass")
        }
        return data
    }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

/// Family sync: register the device on the user's Worker, create or join a
/// family (space), push/pull cards. All card content is end-to-end encrypted.
@MainActor
@Observable
final class SyncService {
    static let shared = SyncService()

    private(set) var isSyncing = false
    private(set) var lastFailed = false
    var members: [ServerAPI.Member] = []
    var passSigningAvailable: Bool?

    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?

    private enum Keys {
        static let token = "device-token"
        static let spaceKey = "space-key"
    }

    private var model: AppModel { AppModel.shared }
    private var state: SyncState { model.data.sync }

    /// API client when the device is registered.
    var api: ServerAPI? {
        guard state.isRegistered, let url = URL(string: state.serverURL), let token = Keychain.string(Keys.token) else { return nil }
        return ServerAPI(base: url, token: token)
    }

    var hasSpaceKey: Bool { Keychain.get(Keys.spaceKey)?.count == 32 }

    private var cipher: AESGCMCipher? {
        guard let k = Keychain.get(Keys.spaceKey), k.count == 32 else { return nil }
        return AESGCMCipher(key: SymmetricKey(data: k))
    }

    private func setState(_ change: (inout SyncState) -> Void) {
        model.updateLocal { change(&$0.sync) }
    }

    static var defaultDeviceName: String { UIDevice.current.name }

    // MARK: Setup

    /// Registers this iPhone on the server (needs the enroll key set on the Worker).
    func register(server raw: String, enrollKey: String, name: String) async throws {
        guard let server = normalizedServerURL(raw), let url = URL(string: server) else {
            throw SyncError.server("Indirizzo del server non valido")
        }
        struct Body: Encodable { let name: String; let enrollKey: String }
        let api = ServerAPI(base: url, token: nil)
        let device: ServerAPI.Device = try await api.call("POST", "v1/devices", body: Body(name: name, enrollKey: enrollKey))
        Keychain.setString(device.token, for: Keys.token)
        Keychain.set(nil, for: Keys.spaceKey)
        setState {
            $0.serverURL = server
            $0.deviceID = device.deviceId
            $0.deviceName = name
            $0.spaceID = nil
            $0.spaceName = nil
            $0.isOwner = false
            $0.cursor = 0
            $0.lastError = nil
        }
        await checkHealth()
    }

    func checkHealth() async {
        guard let api else { passSigningAvailable = nil; return }
        passSigningAvailable = (try? await api.health())?.passSigning
    }

    func createFamily(name: String) async throws {
        guard let api else { throw SyncError.server("Collega prima questo iPhone al server") }
        struct Body: Encodable { let name: String }
        let space: ServerAPI.Space = try await api.call("POST", "v1/spaces", body: Body(name: name))
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        Keychain.set(key, for: Keys.spaceKey)
        setState {
            $0.spaceID = space.spaceId
            $0.spaceName = space.name ?? name
            $0.isOwner = true
        }
        model.update { SyncEngine.markAllForUpload(&$0) }
        await syncNow(manual: false)
        await loadMembers()
    }

    /// New invite (valid 48 h, single use): link/QR with the family key.
    func makeInvite() async throws -> InviteLink {
        guard let api, let key = Keychain.get(Keys.spaceKey) else { throw SyncError.server("Non fai parte di una famiglia") }
        let invite: ServerAPI.Invite = try await api.call("POST", "v1/spaces/invite")
        return InviteLink(server: state.serverURL, code: invite.code, key: key)
    }

    func join(_ invite: InviteLink, name: String) async throws {
        guard let url = URL(string: invite.server) else { throw SyncError.server("Invito non valido") }
        // Same server: keep the device identity; otherwise a new one is created.
        let sameServer = state.isRegistered && state.serverURL == invite.server
        let token = sameServer ? Keychain.string(Keys.token) : nil
        struct Body: Encodable { let code: String; let name: String }
        let api = ServerAPI(base: url, token: token)
        let joined: ServerAPI.Joined = try await api.call("POST", "v1/join", body: Body(code: invite.code, name: name))
        Keychain.setString(joined.token, for: Keys.token)
        Keychain.set(invite.key, for: Keys.spaceKey)
        setState {
            $0.serverURL = invite.server
            $0.deviceID = joined.deviceId
            $0.deviceName = name
            $0.spaceID = joined.spaceId
            $0.spaceName = joined.spaceName
            $0.isOwner = false
            $0.lastError = nil
        }
        model.update { SyncEngine.markAllForUpload(&$0) }
        await syncNow(manual: false)
        await loadMembers()
        await checkHealth()
    }

    func loadMembers() async {
        guard let api, state.isInSpace else { members = []; return }
        if let info: ServerAPI.SpaceInfo = try? await api.call("GET", "v1/space") {
            members = info.members
            setState {
                $0.spaceName = info.name ?? $0.spaceName
                $0.isOwner = info.ownerDeviceId == $0.deviceID
            }
        }
    }

    func removeMember(_ id: String) async throws {
        guard let api else { return }
        let _: ServerAPI.OK = try await api.call("DELETE", "v1/space/members/\(id)")
        await loadMembers()
    }

    /// Leaves the family: the cards stay on this iPhone.
    func leaveFamily() async {
        if let api, let me = state.deviceID {
            let _: ServerAPI.OK? = try? await api.call("DELETE", "v1/space/members/\(me)")
        }
        Keychain.set(nil, for: Keys.spaceKey)
        members = []
        setState {
            $0.spaceID = nil
            $0.spaceName = nil
            $0.isOwner = false
            $0.cursor = 0
            $0.lastSyncAt = nil
        }
        model.updateLocal { $0.pendingSync = [] }
    }

    /// Forgets the server completely (pass signing too).
    func disconnect() async {
        await leaveFamily()
        Keychain.set(nil, for: Keys.token)
        passSigningAvailable = nil
        setState { $0 = SyncState() }
    }

    // MARK: Sync

    func scheduleSync(delay: Duration = .seconds(2)) {
        guard state.isInSpace else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.syncNow(manual: false)
        }
    }

    func syncNow(manual: Bool) async {
        if let running {
            await running.value
            if !manual { return }
        }
        let task = Task { await performSync(manual: manual) }
        running = task
        await task.value
        running = nil
    }

    private func performSync(manual: Bool) async {
        guard state.isInSpace, let api, let cipher else {
            if manual { model.sheet = .family }
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        var totals = SyncEngine.Outcome()
        do {
            for _ in 0..<10 {
                let outgoing = try SyncEngine.outgoing(model.data, cipher: cipher) { LogoStore.data(for: $0) }
                let batch = Array(outgoing.prefix(200))
                let response = try await api.sync(SyncRequest(since: state.cursor, changes: batch))
                let o = model.applySync { data in
                    SyncEngine.apply(response, sent: batch, to: &data, cipher: cipher)
                }
                totals.added += o.added
                totals.updated += o.updated
                totals.removed += o.removed
                totals.unreadable += o.unreadable
                if !response.more && outgoing.count <= batch.count { break }
            }
            lastFailed = false
            setState {
                $0.lastSyncAt = Date()
                $0.lastError = totals.unreadable > 0 ? "\(totals.unreadable) carte non leggibili: la chiave della famiglia non corrisponde." : nil
            }
            if manual {
                Haptics.success()
                let n = totals.added + totals.updated + totals.removed
                model.show(n == 0 ? "Tutto aggiornato" : "Sincronizzate \(ItalianFormat.plural(n, "modifica", "modifiche"))",
                           icon: "arrow.triangle.2.circlepath")
            }
        } catch {
            lastFailed = true
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            setState { $0.lastError = message }
            if manual { model.show(message, icon: "exclamationmark.triangle.fill", style: .error) }
        }
    }
}
