import Foundation
import Observation
import MapKit
import FirebaseAuth
import FirebaseFirestore

@MainActor @Observable
final class TripStore {
    private(set) var me: TripMember
    private(set) var allPicks: [PlacePick] = []
    private(set) var members: [TripMember] = []
    private(set) var scheduledBlocks: [ScheduledGroupBlock] = []
    private(set) var activeTripID: String?
    private(set) var inviteCode: String?
    private(set) var tripTitle = "포항 여행"
    private(set) var isReady = false
    private(set) var isWorking = false
    var inviteCodeInput = ""
    var errorMessage: String?

    @ObservationIgnored private let database = Firestore.firestore()
    @ObservationIgnored private var listeners: [ListenerRegistration] = []
    @ObservationIgnored private var travelTimeCache: [RouteKey: TimeInterval] = [:]

    private static let activeTripKey = "activeTripID"
    private static let activeInviteKey = "activeInviteCode"

    init() {
        let storedID = UserDefaults.standard.string(forKey: "memberID").flatMap(UUID.init) ?? UUID()
        UserDefaults.standard.set(storedID.uuidString, forKey: "memberID")
        let defaultName = UserDefaults.standard.string(forKey: "memberName") ?? "나"
        me = TripMember(id: storedID, name: defaultName, colorIndex: Int(storedID.hashValue.magnitude % 4), isConfirmed: false)
        members = [me]
        Task { await prepare() }
    }

    var myPicks: [PlacePick] { allPicks.filter { $0.ownerID == me.id } }
    var hasActiveTrip: Bool { activeTripID != nil }
    var confirmedCount: Int { members.filter(\.isConfirmed).count }

    var inviteURL: URL? {
        guard let inviteCode else { return nil }
        var components = URLComponents()
        components.scheme = "ddaddadda"
        components.host = "join"
        components.queryItems = [URLQueryItem(name: "code", value: inviteCode)]
        return components.url
    }

    func add(_ item: MKMapItem) -> Bool {
        guard let activeTripID, myPicks.count < 6, !hasPlace(item) else { return false }
        let pick = PlacePick(item: item, owner: me)
        allPicks.append(pick)
        database.collection("trips").document(activeTripID).collection("places").document(pick.id.uuidString)
            .setData(Self.placeData(pick)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    self?.allPicks.removeAll { $0.id == pick.id }
                    self?.errorMessage = "장소를 저장하지 못했어요. \(error.localizedDescription)"
                }
            }
        return true
    }

    func remove(_ pick: PlacePick) {
        guard let activeTripID, pick.ownerID == me.id else { return }
        allPicks.removeAll { $0.id == pick.id }
        me.isConfirmed = false
        database.collection("trips").document(activeTripID).collection("places").document(pick.id.uuidString).delete()
        updateMyMember(["isConfirmed": false])
    }

    func hasPlace(_ item: MKMapItem) -> Bool {
        let c = item.placemark.coordinate
        return myPicks.contains { $0.name == item.name && abs($0.latitude - c.latitude) < 0.0001 && abs($0.longitude - c.longitude) < 0.0001 }
    }

    func confirmMine() {
        me.isConfirmed = true
        updateMyMember(["isConfirmed": true])
    }

    func rename(_ name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !cleaned.isEmpty else { return }
        me.name = cleaned
        UserDefaults.standard.set(cleaned, forKey: "memberName")
        updateMyMember(["name": cleaned])
        if let activeTripID, !myPicks.isEmpty {
            let batch = database.batch()
            for pick in myPicks {
                let reference = database.collection("trips").document(activeTripID).collection("places").document(pick.id.uuidString)
                batch.setData(["ownerName": cleaned], forDocument: reference, merge: true)
            }
            batch.commit()
        }
    }

    func createRoom(title: String) {
        guard !isWorking else { return }
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            isWorking = true
            errorMessage = nil
            defer { isWorking = false }
            do {
                let user = try await ensureAuthenticated()
                let code = try await uniqueInviteCode()
                let tripReference = database.collection("trips").document()
                let batch = database.batch()
                batch.setData([
                    "title": cleanedTitle.isEmpty ? "포항 여행" : cleanedTitle,
                    "destination": "포항",
                    "inviteCode": code,
                    "createdBy": user.uid,
                    "createdAt": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp()
                ], forDocument: tripReference)
                batch.setData([
                    "tripID": tripReference.documentID,
                    "active": true,
                    "createdAt": FieldValue.serverTimestamp()
                ], forDocument: database.collection("inviteCodes").document(code))
                batch.setData(Self.memberData(me), forDocument: tripReference.collection("members").document(user.uid))
                try await batch.commit()
                activateRoom(id: tripReference.documentID, code: code, title: cleanedTitle.isEmpty ? "포항 여행" : cleanedTitle)
            } catch {
                errorMessage = "여행방을 만들지 못했어요. \(error.localizedDescription)"
            }
        }
    }

    func joinRoom(code: String? = nil) {
        guard !isWorking else { return }
        let normalized = Self.normalizedInviteCode(code ?? inviteCodeInput)
        guard !normalized.isEmpty else {
            errorMessage = "초대 코드를 입력해주세요."
            return
        }
        inviteCodeInput = normalized
        Task { await joinRoom(code: normalized, showsProgress: true) }
    }

    func handleInviteURL(_ url: URL) {
        guard url.scheme?.lowercased() == "ddaddadda",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else { return }
        inviteCodeInput = Self.normalizedInviteCode(code)
    }

    func leaveRoom() {
        let tripID = activeTripID
        let userID = Auth.auth().currentUser?.uid
        deactivateRoom()
        if let tripID, let userID {
            database.collection("trips").document(tripID).collection("members").document(userID).delete()
        }
    }

    func addScheduleBlock(proposalID: UUID, group: ActivityGroup, day: Int, slot: Int) {
        guard let activeTripID else { return }
        let block = ScheduledGroupBlock(proposalID: proposalID, group: group, day: day, slot: slot)
        scheduledBlocks.append(block)
        database.collection("trips").document(activeTripID).collection("scheduleItems").document(block.id.uuidString)
            .setData(Self.scheduleData(block)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    self?.scheduledBlocks.removeAll { $0.id == block.id }
                    self?.errorMessage = "일정을 저장하지 못했어요. \(error.localizedDescription)"
                }
            }
    }

    func removeScheduleBlock(_ block: ScheduledGroupBlock) {
        guard let activeTripID else { return }
        scheduledBlocks.removeAll { $0.id == block.id }
        database.collection("trips").document(activeTripID).collection("scheduleItems").document(block.id.uuidString).delete()
    }

    func clusters(maxDistanceMeters: Double = 5_500) -> [PlaceCluster] {
        var remaining = allPicks; var result: [PlaceCluster] = []; var index = 1
        while let seed = remaining.first {
            var group = [seed]; remaining.removeFirst(); var changed = true
            while changed {
                changed = false
                let center = Self.center(of: group); let point = CLLocation(latitude: center.latitude, longitude: center.longitude)
                if let candidate = remaining.first(where: { point.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= maxDistanceMeters }) {
                    group.append(candidate); remaining.removeAll { $0.id == candidate.id }; changed = true
                }
            }
            let center = Self.center(of: group)
            result.append(.init(name: Self.regionName(for: group, index: index), picks: group, center: center)); index += 1
        }
        return result.sorted { $0.picks.count > $1.picks.count }
    }

    func clusters(mode: TravelMode, maxTravelMinutes: Int) async -> [PlaceCluster] {
        var remaining = allPicks
        var result: [PlaceCluster] = []
        var index = 1
        let limit = TimeInterval(maxTravelMinutes * 60)

        while let seed = remaining.first {
            var group = [seed]
            remaining.removeFirst()
            var changed = true
            while changed {
                changed = false
                for candidate in remaining {
                    guard let nearest = group.min(by: { straightDistance($0, candidate) < straightDistance($1, candidate) }) else { continue }
                    if let travelTime = await expectedTravelTime(from: nearest, to: candidate, mode: mode), travelTime <= limit {
                        group.append(candidate)
                        remaining.removeAll { $0.id == candidate.id }
                        changed = true
                        break
                    }
                }
            }
            result.append(.init(name: Self.regionName(for: group, index: index), picks: group, center: Self.center(of: group)))
            index += 1
        }
        return result.sorted { $0.picks.count > $1.picks.count }
    }

    func preferenceProfiles() -> [PreferenceProfile] {
        members.map { member in
            let picks = allPicks.filter { $0.ownerID == member.id }
            let counts = Dictionary(grouping: picks, by: \.category).mapValues(\.count)
            let ranked = counts.keys.sorted {
                if counts[$0, default: 0] == counts[$1, default: 0] { return $0.title < $1.title }
                return counts[$0, default: 0] > counts[$1, default: 0]
            }
            return PreferenceProfile(member: member, categories: ranked)
        }
    }

    func groupingProposals() -> [GroupingProposal] {
        proposals(for: clusters())
    }

    func groupingProposals(mode: TravelMode, maxTravelMinutes: Int) async -> [GroupingProposal] {
        proposals(for: await clusters(mode: mode, maxTravelMinutes: maxTravelMinutes))
    }

    private func proposals(for clusters: [PlaceCluster]) -> [GroupingProposal] {
        clusters.map { cluster in
            let activeMembers = cluster.members
            let categoriesByMember = Dictionary(uniqueKeysWithValues: activeMembers.map { member in
                (member.id, Set(cluster.picks.filter { $0.ownerID == member.id }.map(\.category)))
            })
            var unassigned = activeMembers
            var groups: [ActivityGroup] = []
            var groupIndex = 0

            while let seed = unassigned.first {
                unassigned.removeFirst()
                var grouped = [seed]
                let seedCategories = categoriesByMember[seed.id, default: []]
                let companions = unassigned.filter { member in
                    !seedCategories.intersection(categoriesByMember[member.id, default: []]).isEmpty
                }
                grouped.append(contentsOf: companions)
                unassigned.removeAll { candidate in companions.contains(where: { $0.id == candidate.id }) }
                let memberIDs = Set(grouped.map(\.id))
                let picks = cluster.picks.filter { memberIDs.contains($0.ownerID) }
                let tastes = Array(Set(picks.map(\.category))).map(\.title).sorted().joined(separator: ", ")
                groups.append(ActivityGroup(
                    members: grouped,
                    picks: picks,
                    label: "그룹 \(String(UnicodeScalar(65 + groupIndex)!))",
                    reason: grouped.count > 1 ? "\(tastes) 취향이 겹쳐 함께 즐기기 좋아요." : "\(tastes) 취향을 충분히 즐기도록 별도 그룹으로 제안해요."
                ))
                groupIndex += 1
            }

            let activeIDs = Set(activeMembers.map(\.id))
            for member in members where !activeIDs.contains(member.id) {
                groups.append(ActivityGroup(
                    members: [member], picks: [], label: "자유 선택",
                    reason: "이 지역에 저장한 장소가 없어요. 근처 자유시간을 갖거나 다른 그룹에 합류할지 본인에게 확인해야 해요."
                ))
            }
            return GroupingProposal(cluster: cluster, groups: groups)
        }
    }

    private func expectedTravelTime(from start: PlacePick, to end: PlacePick, mode: TravelMode) async -> TimeInterval? {
        let key = RouteKey(start: start.id, end: end.id, mode: mode)
        if let cached = travelTimeCache[key] { return cached }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end.coordinate))
        request.transportType = mode.transportType
        request.requestsAlternateRoutes = false
        do {
            let response = try await MKDirections(request: request).calculate()
            guard let seconds = response.routes.first?.expectedTravelTime else { return nil }
            travelTimeCache[key] = seconds
            travelTimeCache[RouteKey(start: end.id, end: start.id, mode: mode)] = seconds
            return seconds
        } catch {
            return nil
        }
    }

    private func straightDistance(_ first: PlacePick, _ second: PlacePick) -> CLLocationDistance {
        CLLocation(latitude: first.latitude, longitude: first.longitude)
            .distance(from: CLLocation(latitude: second.latitude, longitude: second.longitude))
    }

    private func prepare() async {
        do {
            let user = try await ensureAuthenticated()
            if let savedTripID = UserDefaults.standard.string(forKey: Self.activeTripKey),
               let savedCode = UserDefaults.standard.string(forKey: Self.activeInviteKey) {
                let snapshot = try await database.collection("trips").document(savedTripID).getDocument()
                if snapshot.exists {
                    try await database.collection("trips").document(savedTripID).collection("members").document(user.uid)
                        .setData(Self.memberData(me), merge: true)
                    activateRoom(
                        id: savedTripID,
                        code: savedCode,
                        title: snapshot.data()?["title"] as? String ?? "포항 여행"
                    )
                } else {
                    clearSavedRoom()
                }
            }
            isReady = true
        } catch {
            isReady = true
            clearSavedRoom()
            errorMessage = "Firebase에 연결하지 못했어요. \(error.localizedDescription)"
        }
    }

    private func ensureAuthenticated() async throws -> User {
        if let currentUser = Auth.auth().currentUser { return currentUser }
        return try await Auth.auth().signInAnonymously().user
    }

    private func uniqueInviteCode() async throws -> String {
        let characters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        for _ in 0..<8 {
            let code = String((0..<6).compactMap { _ in characters.randomElement() })
            let snapshot = try await database.collection("inviteCodes").document(code).getDocument()
            if !snapshot.exists { return code }
        }
        throw NSError(domain: "TripRoom", code: 1, userInfo: [NSLocalizedDescriptionKey: "사용할 수 있는 초대 코드를 만들지 못했어요."])
    }

    private func joinRoom(code: String, showsProgress: Bool) async {
        if showsProgress { isWorking = true }
        errorMessage = nil
        defer { if showsProgress { isWorking = false } }
        do {
            let user = try await ensureAuthenticated()
            let inviteSnapshot = try await database.collection("inviteCodes").document(code).getDocument()
            guard let inviteData = inviteSnapshot.data(),
                  inviteData["active"] as? Bool != false,
                  let tripID = inviteData["tripID"] as? String else {
                throw NSError(domain: "TripRoom", code: 2, userInfo: [NSLocalizedDescriptionKey: "유효한 여행방을 찾을 수 없어요."])
            }
            let tripReference = database.collection("trips").document(tripID)
            try await tripReference.collection("members").document(user.uid).setData(Self.memberData(me), merge: true)
            let tripSnapshot = try await tripReference.getDocument()
            guard tripSnapshot.exists else {
                throw NSError(domain: "TripRoom", code: 3, userInfo: [NSLocalizedDescriptionKey: "여행방이 존재하지 않아요."])
            }
            activateRoom(
                id: tripID,
                code: code,
                title: tripSnapshot.data()?["title"] as? String ?? "포항 여행"
            )
        } catch {
            errorMessage = "여행방에 들어가지 못했어요. \(error.localizedDescription)"
        }
    }

    private func activateRoom(id: String, code: String, title: String) {
        clearListeners()
        activeTripID = id
        inviteCode = code
        inviteCodeInput = code
        tripTitle = title
        UserDefaults.standard.set(id, forKey: Self.activeTripKey)
        UserDefaults.standard.set(code, forKey: Self.activeInviteKey)
        listenToRoom(id: id)
    }

    private func deactivateRoom() {
        clearListeners()
        activeTripID = nil
        inviteCode = nil
        inviteCodeInput = ""
        tripTitle = "포항 여행"
        allPicks = []
        scheduledBlocks = []
        me.isConfirmed = false
        members = [me]
        clearSavedRoom()
    }

    private func clearSavedRoom() {
        UserDefaults.standard.removeObject(forKey: Self.activeTripKey)
        UserDefaults.standard.removeObject(forKey: Self.activeInviteKey)
    }

    private func listenToRoom(id: String) {
        let tripReference = database.collection("trips").document(id)

        listeners.append(tripReference.addSnapshotListener { [weak self] snapshot, error in
            let title = snapshot?.data()?["title"] as? String
            let code = snapshot?.data()?["inviteCode"] as? String
            let errorText = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                if let title { self.tripTitle = title }
                if let code { self.inviteCode = code }
                if let errorText { self.errorMessage = "여행방 정보를 불러오지 못했어요. \(errorText)" }
            }
        })

        listeners.append(tripReference.collection("members").addSnapshotListener { [weak self] snapshot, error in
            let parsed = snapshot?.documents.compactMap { Self.member(from: $0.data()) } ?? []
            let errorText = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                if let mine = parsed.first(where: { $0.id == self.me.id }) { self.me = mine }
                self.members = parsed.sorted {
                    if $0.id == self.me.id { return true }
                    if $1.id == self.me.id { return false }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                self.reconcileEmbeddedMembers()
                if let errorText { self.errorMessage = "구성원을 불러오지 못했어요. \(errorText)" }
            }
        })

        listeners.append(tripReference.collection("places").addSnapshotListener { [weak self] snapshot, error in
            let parsed = snapshot?.documents.compactMap { Self.place(from: $0.data()) } ?? []
            let errorText = error?.localizedDescription
            Task { @MainActor in
                self?.allPicks = parsed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self?.reconcileEmbeddedMembers()
                if let errorText { self?.errorMessage = "장소를 불러오지 못했어요. \(errorText)" }
            }
        })

        listeners.append(tripReference.collection("scheduleItems").addSnapshotListener { [weak self] snapshot, error in
            let parsed = snapshot?.documents.compactMap { Self.scheduleBlock(from: $0.data()) } ?? []
            let errorText = error?.localizedDescription
            Task { @MainActor in
                self?.scheduledBlocks = parsed.sorted {
                    if $0.day == $1.day { return $0.slot < $1.slot }
                    return $0.day < $1.day
                }
                self?.reconcileEmbeddedMembers()
                if let errorText { self?.errorMessage = "일정을 불러오지 못했어요. \(errorText)" }
            }
        })
    }

    private func clearListeners() {
        listeners.forEach { $0.remove() }
        listeners.removeAll()
    }

    private func updateMyMember(_ values: [String: Any]) {
        guard let activeTripID, let userID = Auth.auth().currentUser?.uid else { return }
        database.collection("trips").document(activeTripID).collection("members").document(userID)
            .setData(values, merge: true)
    }

    private func reconcileEmbeddedMembers() {
        let memberByID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        allPicks = allPicks.map { pick in
            guard let currentOwner = memberByID[pick.ownerID] else { return pick }
            return PlacePick(
                id: pick.id,
                name: pick.name,
                address: pick.address,
                latitude: pick.latitude,
                longitude: pick.longitude,
                category: pick.category,
                owner: currentOwner
            )
        }
        scheduledBlocks = scheduledBlocks.map { block in
            let groupMembers = block.group.members.map { memberByID[$0.id] ?? $0 }
            let groupPicks = block.group.picks.map { pick in
                guard let currentOwner = memberByID[pick.ownerID] else { return pick }
                return PlacePick(
                    id: pick.id,
                    name: pick.name,
                    address: pick.address,
                    latitude: pick.latitude,
                    longitude: pick.longitude,
                    category: pick.category,
                    owner: currentOwner
                )
            }
            let group = ActivityGroup(
                id: block.group.id,
                members: groupMembers,
                picks: groupPicks,
                label: block.group.label,
                reason: block.group.reason
            )
            return ScheduledGroupBlock(id: block.id, proposalID: block.proposalID, group: group, day: block.day, slot: block.slot)
        }
    }

    private static func normalizedInviteCode(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func memberData(_ member: TripMember) -> [String: Any] {
        [
            "memberID": member.id.uuidString,
            "name": member.name,
            "colorIndex": member.colorIndex,
            "isConfirmed": member.isConfirmed,
            "joinedAt": FieldValue.serverTimestamp()
        ]
    }

    private static func placeData(_ pick: PlacePick) -> [String: Any] {
        [
            "id": pick.id.uuidString,
            "name": pick.name,
            "address": pick.address,
            "latitude": pick.latitude,
            "longitude": pick.longitude,
            "category": pick.category.rawValue,
            "ownerID": pick.owner.id.uuidString,
            "ownerName": pick.owner.name,
            "ownerColorIndex": pick.owner.colorIndex,
            "createdAt": FieldValue.serverTimestamp()
        ]
    }

    private static func scheduleData(_ block: ScheduledGroupBlock) -> [String: Any] {
        [
            "id": block.id.uuidString,
            "proposalID": block.proposalID.uuidString,
            "groupID": block.group.id.uuidString,
            "label": block.group.label,
            "reason": block.group.reason,
            "day": block.day,
            "slot": block.slot,
            "members": block.group.members.map { member in
                [
                    "memberID": member.id.uuidString,
                    "name": member.name,
                    "colorIndex": member.colorIndex,
                    "isConfirmed": member.isConfirmed
                ]
            },
            "picks": block.group.picks.map { pick in
                [
                    "id": pick.id.uuidString,
                    "name": pick.name,
                    "address": pick.address,
                    "latitude": pick.latitude,
                    "longitude": pick.longitude,
                    "category": pick.category.rawValue,
                    "ownerID": pick.owner.id.uuidString,
                    "ownerName": pick.owner.name,
                    "ownerColorIndex": pick.owner.colorIndex
                ]
            },
            "updatedAt": FieldValue.serverTimestamp()
        ]
    }

    nonisolated private static func member(from data: [String: Any]) -> TripMember? {
        guard let rawID = data["memberID"] as? String,
              let id = UUID(uuidString: rawID),
              let name = data["name"] as? String else { return nil }
        return TripMember(
            id: id,
            name: name,
            colorIndex: integer(data["colorIndex"]),
            isConfirmed: data["isConfirmed"] as? Bool ?? false
        )
    }

    nonisolated private static func place(from data: [String: Any]) -> PlacePick? {
        guard let rawID = data["id"] as? String,
              let id = UUID(uuidString: rawID),
              let name = data["name"] as? String,
              let latitude = number(data["latitude"]),
              let longitude = number(data["longitude"]),
              let categoryRaw = data["category"] as? String,
              let category = PlaceCategory(rawValue: categoryRaw),
              let ownerRawID = data["ownerID"] as? String,
              let ownerID = UUID(uuidString: ownerRawID) else { return nil }
        let owner = TripMember(
            id: ownerID,
            name: data["ownerName"] as? String ?? "친구",
            colorIndex: integer(data["ownerColorIndex"]),
            isConfirmed: false
        )
        return PlacePick(
            id: id,
            name: name,
            address: data["address"] as? String ?? "",
            latitude: latitude,
            longitude: longitude,
            category: category,
            owner: owner
        )
    }

    nonisolated private static func scheduleBlock(from data: [String: Any]) -> ScheduledGroupBlock? {
        guard let rawID = data["id"] as? String,
              let id = UUID(uuidString: rawID),
              let rawProposalID = data["proposalID"] as? String,
              let proposalID = UUID(uuidString: rawProposalID),
              let rawGroupID = data["groupID"] as? String,
              let groupID = UUID(uuidString: rawGroupID) else { return nil }
        let members = (data["members"] as? [[String: Any]] ?? []).compactMap { member(from: $0) }
        let picks = (data["picks"] as? [[String: Any]] ?? []).compactMap { place(from: $0) }
        let group = ActivityGroup(
            id: groupID,
            members: members,
            picks: picks,
            label: data["label"] as? String ?? "그룹",
            reason: data["reason"] as? String ?? ""
        )
        return ScheduledGroupBlock(
            id: id,
            proposalID: proposalID,
            group: group,
            day: integer(data["day"]),
            slot: integer(data["slot"])
        )
    }

    nonisolated private static func integer(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }

    nonisolated private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func center(of picks: [PlacePick]) -> CLLocationCoordinate2D {
        .init(latitude: picks.map(\.latitude).reduce(0, +) / Double(picks.count), longitude: picks.map(\.longitude).reduce(0, +) / Double(picks.count))
    }
    private static func regionName(for picks: [PlacePick], index: Int) -> String {
        let words = picks.flatMap { $0.address.split(separator: " ").map(String.init) }
        if let common = Dictionary(grouping: words, by: { $0 }).max(by: { $0.value.count < $1.value.count }), common.value.count > 1 { return "\(common.key)권" }
        return "지역 \(index)"
    }
}

private struct RouteKey: Hashable {
    let start: UUID
    let end: UUID
    let mode: TravelMode
}
