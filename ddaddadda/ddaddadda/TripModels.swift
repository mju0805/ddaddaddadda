import SwiftUI
import MapKit

extension MKPlacemark {
    var shortAddress: String { [locality, subLocality, thoroughfare].compactMap { $0 }.joined(separator: " ") }
}

enum TripTheme {
    static let coral = Color(red: 0.96, green: 0.32, blue: 0.30)
    static let teal = Color(red: 0.08, green: 0.61, blue: 0.55)
    static let indigo = Color(red: 0.34, green: 0.29, blue: 0.82)
    static let amber = Color(red: 0.96, green: 0.60, blue: 0.12)
}

enum TravelMode: String, CaseIterable, Identifiable {
    case automobile, transit, walking
    var id: Self { self }
    var title: String {
        switch self { case .automobile: "자동차"; case .transit: "대중교통"; case .walking: "도보" }
    }
    var symbol: String {
        switch self { case .automobile: "car.fill"; case .transit: "bus.fill"; case .walking: "figure.walk" }
    }
    var transportType: MKDirectionsTransportType {
        switch self { case .automobile: .automobile; case .transit: .transit; case .walking: .walking }
    }
}

struct TripMember: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var colorIndex: Int
    var isConfirmed: Bool
    var initial: String { String(name.prefix(1)) }
    var color: Color { [TripTheme.coral, TripTheme.teal, TripTheme.indigo, TripTheme.amber][colorIndex % 4] }
}

enum PlaceCategory: String, Codable, CaseIterable, Sendable {
    case food, cafe, culture, nature, shopping, other
    var symbol: String {
        switch self {
        case .food: "fork.knife"
        case .cafe: "cup.and.saucer.fill"
        case .culture: "building.columns.fill"
        case .nature: "leaf.fill"
        case .shopping: "bag.fill"
        case .other: "mappin"
        }
    }

    var title: String {
        switch self {
        case .food: "맛집"
        case .cafe: "카페·베이커리"
        case .culture: "전시·문화"
        case .nature: "바다·자연"
        case .shopping: "쇼핑·서점"
        case .other: "새로운 장소"
        }
    }

    static func infer(from item: MKMapItem) -> PlaceCategory {
        let text = [item.name, item.pointOfInterestCategory?.rawValue].compactMap { $0 }.joined(separator: " ").lowercased()
        if text.contains("restaurant") || text.contains("food") || text.contains("횟집") || text.contains("식당") { return .food }
        if text.contains("cafe") || text.contains("bakery") || text.contains("카페") || text.contains("베이커리") { return .cafe }
        if text.contains("museum") || text.contains("미술관") || text.contains("박물관") { return .culture }
        if text.contains("beach") || text.contains("park") || text.contains("해수욕장") || text.contains("공원") { return .nature }
        if text.contains("store") || text.contains("shop") || text.contains("백화점") { return .shopping }
        return .other
    }
}

struct PlacePick: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    let category: PlaceCategory
    let owner: TripMember
    var ownerID: UUID { owner.id }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    init(item: MKMapItem, owner: TripMember) {
        id = UUID(); name = item.name ?? "이름 없는 장소"; address = item.placemark.shortAddress
        latitude = item.placemark.coordinate.latitude; longitude = item.placemark.coordinate.longitude
        category = .infer(from: item); self.owner = owner
    }

    init(
        id: UUID,
        name: String,
        address: String,
        latitude: Double,
        longitude: Double,
        category: PlaceCategory,
        owner: TripMember
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.category = category
        self.owner = owner
    }
}

struct PlaceCluster: Identifiable {
    let id = UUID(); let name: String; let picks: [PlacePick]; let center: CLLocationCoordinate2D
    var members: [TripMember] {
        var seen = Set<UUID>()
        return picks.compactMap { seen.insert($0.owner.id).inserted ? $0.owner : nil }
    }
}

struct PreferenceProfile: Identifiable {
    let member: TripMember
    let categories: [PlaceCategory]
    var id: UUID { member.id }
    var summary: String { categories.isEmpty ? "취향 파악 중" : categories.prefix(3).map(\.title).joined(separator: ", ") }
}

struct ActivityGroup: Identifiable, Sendable {
    let id: UUID
    let members: [TripMember]
    let picks: [PlacePick]
    let label: String
    let reason: String

    init(id: UUID = UUID(), members: [TripMember], picks: [PlacePick], label: String, reason: String) {
        self.id = id
        self.members = members
        self.picks = picks
        self.label = label
        self.reason = reason
    }

    var memberNames: String { members.map(\.name).joined(separator: " + ") }
    var title: String { picks.isEmpty ? "자유시간 또는 합류" : picks.map(\.name).joined(separator: " · ") }
    var categorySummary: String {
        Array(Set(picks.map(\.category))).map(\.title).sorted().joined(separator: ", ")
    }
}

struct GroupingProposal: Identifiable {
    let id = UUID()
    let cluster: PlaceCluster
    let groups: [ActivityGroup]
    var isSplit: Bool { groups.filter { !$0.picks.isEmpty }.count > 1 }
}

struct ScheduledGroupBlock: Identifiable, Sendable {
    let id: UUID
    let proposalID: UUID
    let group: ActivityGroup
    var day: Int
    var slot: Int

    init(id: UUID = UUID(), proposalID: UUID, group: ActivityGroup, day: Int, slot: Int) {
        self.id = id
        self.proposalID = proposalID
        self.group = group
        self.day = day
        self.slot = slot
    }
}
