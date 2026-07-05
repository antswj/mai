import Foundation

public struct GroundedProviderProfile: Codable, Sendable, Equatable {
    public let id: String
    public let estimatedQuality: Double
    public let estimatedLatencyMs: Int
    public let costUnits: Double
    public let supportedRoutes: Set<LookupRoute>

    public init(id: String, estimatedQuality: Double, estimatedLatencyMs: Int,
                costUnits: Double, supportedRoutes: Set<LookupRoute>) {
        self.id = id
        self.estimatedQuality = estimatedQuality
        self.estimatedLatencyMs = estimatedLatencyMs
        self.costUnits = costUnits
        self.supportedRoutes = supportedRoutes
    }
}

public struct ProviderRouteWeights: Codable, Sendable, Equatable {
    public let quality: Double
    public let latency: Double
    public let cost: Double

    public init(quality: Double, latency: Double, cost: Double) {
        self.quality = quality
        self.latency = latency
        self.cost = cost
    }
}

public struct RoutedGroundedCandidate: Sendable {
    public let profile: GroundedProviderProfile
    public let provider: GroundedSearch

    public init(profile: GroundedProviderProfile, provider: GroundedSearch) {
        self.profile = profile
        self.provider = provider
    }
}

public struct ProviderRoutingPolicy: Sendable, Equatable {
    public init() {}

    public func weights(for route: LookupRoute) -> ProviderRouteWeights {
        switch route {
        case .fresh:
            return ProviderRouteWeights(quality: 0.58, latency: 0.22, cost: 0.20)
        case .technical:
            return ProviderRouteWeights(quality: 0.48, latency: 0.34, cost: 0.18)
        case .entity, .screen:
            return ProviderRouteWeights(quality: 0.50, latency: 0.38, cost: 0.12)
        default:
            return ProviderRouteWeights(quality: 0.40, latency: 0.45, cost: 0.15)
        }
    }

    public func rankedProfiles(_ profiles: [GroundedProviderProfile], route: LookupRoute) -> [GroundedProviderProfile] {
        profiles
            .filter { $0.supportedRoutes.contains(route) || $0.supportedRoutes.isEmpty }
            .sorted { score($0, route: route) > score($1, route: route) }
    }

    public func score(_ profile: GroundedProviderProfile, route: LookupRoute) -> Double {
        let weights = weights(for: route)
        let latencyPenalty = min(1.5, Double(profile.estimatedLatencyMs) / 3000.0)
        return profile.estimatedQuality * weights.quality
            - latencyPenalty * weights.latency
            - profile.costUnits * weights.cost
    }
}

public struct PolicyGroundedSearch: RoutedGroundedSearch {
    private let candidates: [RoutedGroundedCandidate]
    private let policy: ProviderRoutingPolicy

    public init(candidates: [RoutedGroundedCandidate], policy: ProviderRoutingPolicy = ProviderRoutingPolicy()) {
        self.candidates = candidates
        self.policy = policy
    }

    public func answer(query: String, interface: Language, route: LookupRoute) async throws -> GroundedResult {
        let rankedProfiles = policy.rankedProfiles(candidates.map(\.profile), route: route)
        let ranked = rankedProfiles.compactMap { profile in
            candidates.first { $0.profile.id == profile.id }
        }
        var lastError: Error?
        for candidate in ranked {
            do {
                let result: GroundedResult
                if let routed = candidate.provider as? any RoutedGroundedSearch {
                    result = try await routed.answer(query: query, interface: interface, route: route)
                } else {
                    result = try await candidate.provider.answer(query: query, interface: interface)
                }
                if !result.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return result
                }
            } catch {
                lastError = error
                continue
            }
        }
        if let lastError { throw lastError }
        return GroundedResult(answer: "", sources: [])
    }
}
