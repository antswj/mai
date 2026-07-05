import Foundation

public actor TTLCacheBox<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry: Sendable {
        let value: Value
        let expiresAt: Date
    }

    private let ttlSeconds: Double
    private var entries: [Key: Entry] = [:]

    public init(ttlSeconds: Double) {
        self.ttlSeconds = ttlSeconds
    }

    public func value(for key: Key, now: Date = Date()) -> Value? {
        guard let entry = entries[key] else { return nil }
        if entry.expiresAt < now {
            entries[key] = nil
            return nil
        }
        return entry.value
    }

    public func insert(_ value: Value, for key: Key, now: Date = Date()) {
        entries[key] = Entry(value: value, expiresAt: now.addingTimeInterval(ttlSeconds))
    }

    public func count(now: Date = Date()) -> Int {
        entries = entries.filter { $0.value.expiresAt >= now }
        return entries.count
    }
}

public enum ProviderCacheDirectory {
    public static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        if fm.fileExists(atPath: cwd.appendingPathComponent("Package.swift").path) {
            return cwd.appendingPathComponent("data/provider-cache", isDirectory: true)
        }
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return support.appendingPathComponent("Mai/provider-cache", isDirectory: true)
        }
        return fm.temporaryDirectory.appendingPathComponent("Mai/provider-cache", isDirectory: true)
    }
}

public actor DiskTTLCacheBox<Key: Codable & Hashable & Sendable, Value: Codable & Sendable> {
    private struct Entry: Codable, Sendable {
        let key: Key
        var value: Value
        var expiresAt: Date
        var insertedAt: Date
        var lastAccessedAt: Date
    }

    private struct Snapshot: Codable, Sendable {
        let version: Int
        let entries: [Entry]
    }

    private let url: URL
    private let ttlSeconds: Double
    private let maxEntries: Int
    private var entries: [Key: Entry] = [:]

    public init(url: URL, ttlSeconds: Double, maxEntries: Int = 250) {
        self.url = url
        self.ttlSeconds = ttlSeconds
        self.maxEntries = max(1, maxEntries)
        self.entries = Self.load(from: url, maxEntries: self.maxEntries, now: Date())
    }

    public func value(for key: Key, now: Date = Date()) -> Value? {
        let pruned = Self.prune(&entries, maxEntries: maxEntries, now: now)
        guard var entry = entries[key] else {
            if pruned { persist() }
            return nil
        }
        entry.lastAccessedAt = now
        entries[key] = entry
        if pruned { persist() }
        return entry.value
    }

    public func insert(_ value: Value, for key: Key, now: Date = Date()) {
        entries[key] = Entry(key: key, value: value, expiresAt: now.addingTimeInterval(ttlSeconds),
                             insertedAt: now, lastAccessedAt: now)
        _ = Self.prune(&entries, maxEntries: maxEntries, now: now)
        persist()
    }

    public func count(now: Date = Date()) -> Int {
        if Self.prune(&entries, maxEntries: maxEntries, now: now) { persist() }
        return entries.count
    }

    private static func load(from url: URL, maxEntries: Int, now: Date) -> [Key: Entry] {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder.mai.decode(Snapshot.self, from: data) else { return [:] }
        var loaded = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.key, $0) })
        _ = prune(&loaded, maxEntries: maxEntries, now: now)
        return loaded
    }

    @discardableResult
    private static func prune(_ entries: inout [Key: Entry], maxEntries: Int, now: Date) -> Bool {
        let before = entries.count
        entries = entries.filter { $0.value.expiresAt >= now }
        if entries.count > maxEntries {
            let overflow = entries.count - maxEntries
            let victims = entries
                .sorted { lhs, rhs in
                    if lhs.value.lastAccessedAt == rhs.value.lastAccessedAt {
                        lhs.value.insertedAt < rhs.value.insertedAt
                    } else {
                        lhs.value.lastAccessedAt < rhs.value.lastAccessedAt
                    }
                }
                .prefix(overflow)
                .map(\.key)
            for key in victims { entries[key] = nil }
        }
        return entries.count != before
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let ordered = entries.values.sorted { lhs, rhs in
            if lhs.lastAccessedAt == rhs.lastAccessedAt { return lhs.insertedAt > rhs.insertedAt }
            return lhs.lastAccessedAt > rhs.lastAccessedAt
        }
        let snapshot = Snapshot(version: 1, entries: ordered)
        guard let data = try? JSONEncoder.prettyMai.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private struct EntityCacheKey: Codable, Hashable, Sendable {
    let term: String
    let spoken: Language
    let interface: Language
}

public struct CachedEntityLookup: EntityLookup {
    private let base: EntityLookup
    private let cache: DiskTTLCacheBox<EntityCacheKey, EntityResult>

    public init(base: EntityLookup, ttlSeconds: Double = 60 * 60, maxEntries: Int = 500, cacheURL: URL? = nil) {
        self.base = base
        let url = cacheURL ?? ProviderCacheDirectory.defaultDirectory().appendingPathComponent("entity.json")
        self.cache = DiskTTLCacheBox(url: url, ttlSeconds: ttlSeconds, maxEntries: maxEntries)
    }

    public func lookup(term: String, spoken: Language, interface: Language) async throws -> EntityResult? {
        let key = EntityCacheKey(term: term.normalizedCacheKey, spoken: spoken, interface: interface)
        if let cached = await cache.value(for: key) { return cached }
        guard let result = try await base.lookup(term: term, spoken: spoken, interface: interface) else { return nil }
        await cache.insert(result, for: key)
        return result
    }
}

private struct GroundedCacheKey: Codable, Hashable, Sendable {
    let query: String
    let interface: Language
}

public struct CachedGroundedSearch: GroundedSearch {
    private let base: GroundedSearch
    private let cache: DiskTTLCacheBox<GroundedCacheKey, GroundedResult>

    public init(base: GroundedSearch, ttlSeconds: Double = 5 * 60, maxEntries: Int = 300, cacheURL: URL? = nil) {
        self.base = base
        let url = cacheURL ?? ProviderCacheDirectory.defaultDirectory().appendingPathComponent("grounded.json")
        self.cache = DiskTTLCacheBox(url: url, ttlSeconds: ttlSeconds, maxEntries: maxEntries)
    }

    public func answer(query: String, interface: Language) async throws -> GroundedResult {
        let key = GroundedCacheKey(query: query.normalizedCacheKey, interface: interface)
        if let cached = await cache.value(for: key) { return cached }
        let result = try await base.answer(query: query, interface: interface)
        if !result.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await cache.insert(result, for: key)
        }
        return result
    }
}

private struct PlacesCacheKey: Codable, Hashable, Sendable {
    let query: String
    let latBucket: Int
    let lngBucket: Int
    let language: Language
}

public struct CachedPlacesProvider: PlacesProvider {
    private let base: PlacesProvider
    private let cache: DiskTTLCacheBox<PlacesCacheKey, [Place]>

    public init(base: PlacesProvider, ttlSeconds: Double = 10 * 60, maxEntries: Int = 300, cacheURL: URL? = nil) {
        self.base = base
        let url = cacheURL ?? ProviderCacheDirectory.defaultDirectory().appendingPathComponent("places.json")
        self.cache = DiskTTLCacheBox(url: url, ttlSeconds: ttlSeconds, maxEntries: maxEntries)
    }

    public func nearby(query: String, lat: Double, lng: Double, language: Language) async throws -> [Place] {
        let key = PlacesCacheKey(query: query.normalizedCacheKey,
                                 latBucket: Int((lat * 10_000).rounded()),
                                 lngBucket: Int((lng * 10_000).rounded()),
                                 language: language)
        if let cached = await cache.value(for: key) { return cached }
        let result = try await base.nearby(query: query, lat: lat, lng: lng, language: language)
        if !result.isEmpty { await cache.insert(result, for: key) }
        return result
    }
}

private extension String {
    var normalizedCacheKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
