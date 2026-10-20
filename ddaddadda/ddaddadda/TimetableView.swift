import SwiftUI

struct TimetableView: View {
    @Bindable var store: TripStore
    let proposals: [GroupingProposal]
    @State private var selectedDay = 1
    @State private var selectedCandidate: BlockCandidate?

    private let slots = ["09:00 - 11:00", "11:00 - 13:00", "14:00 - 16:00", "16:00 - 18:00", "19:00 - 21:00"]
    private var candidates: [BlockCandidate] {
        proposals.flatMap { proposal in proposal.groups.map { BlockCandidate(proposal: proposal, group: $0) } }
    }
    private var scheduledToday: [ScheduledGroupBlock] { store.scheduledBlocks.filter { $0.day == selectedDay }.sorted { $0.slot < $1.slot } }
    private var occupiedSlots: [Int] { Array(Set(scheduledToday.map(\.slot))).sorted() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                dayPicker
                unassignedBlocks
                timeline
            }.padding(18)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("그룹 일정")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedCandidate) { candidate in
            PlacementSheet(candidate: candidate, slots: slots, initialDay: selectedDay) { day, slot in
                store.addScheduleBlock(proposalID: candidate.proposal.id, group: candidate.group, day: day, slot: slot)
                selectedDay = day
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2박 3일 \(store.tripTitle)").font(.title2.bold())
            Text("취향으로 나눈 그룹 블록을 원하는 날짜와 시간에 담아보세요. 이동 순서는 자동으로 강제하지 않아요.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var dayPicker: some View {
        HStack(spacing: 10) {
            ForEach(1...3, id: \.self) { day in
                Button { withAnimation { selectedDay = day } } label: {
                    VStack(spacing: 4) {
                        Text("DAY \(day)").font(.caption.bold())
                        Text(day == 1 ? "1일차" : day == 2 ? "2일차" : "3일차").font(.caption2)
                    }
                    .foregroundStyle(selectedDay == day ? .white : .primary)
                    .frame(maxWidth: .infinity).frame(height: 58)
                    .background(selectedDay == day ? TripTheme.indigo : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
                }.buttonStyle(.plain)
            }
        }
    }

    private var unassignedBlocks: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("배치할 그룹 블록").font(.headline)
                Spacer(); Text("누르면 일정에 추가").font(.caption).foregroundStyle(.secondary)
            }
            if availableCandidates.isEmpty {
                Label("모든 그룹 블록을 배치했어요", systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(TripTheme.teal).padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(availableCandidates) { candidate in
                            Button { selectedCandidate = candidate } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Text(candidate.proposal.cluster.name).font(.caption.bold()).foregroundStyle(TripTheme.indigo)
                                        Spacer(); Image(systemName: "plus.circle.fill").foregroundStyle(TripTheme.indigo)
                                    }
                                    Text(candidate.group.memberNames).font(.subheadline.bold()).foregroundStyle(.primary)
                                    Text(candidate.group.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .padding(13).frame(width: 190, height: 112, alignment: .topLeading)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DAY \(selectedDay) 시간표").font(.headline).padding(.bottom, 14)
            if scheduledToday.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "calendar.badge.plus").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("아직 배치된 그룹이 없어요").font(.subheadline.bold())
                    Text("위 블록을 눌러 날짜와 시간을 골라주세요.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 42)
            } else {
                ForEach(occupiedSlots, id: \.self) { slot in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Circle().fill(slotColor(slot)).frame(width: 13, height: 13)
                            Rectangle().fill(Color.secondary.opacity(0.22)).frame(width: 2, height: 118)
                        }.padding(.top, 18)
                        slotRow(slot)
                    }
                }
            }
        }.cardStyle()
    }

    @ViewBuilder
    private func slotRow(_ slot: Int) -> some View {
        let blocks = blocks(in: slot)
        if blocks.count <= 2 {
            HStack(alignment: .top, spacing: 10) {
                ForEach(blocks) { block in scheduleCard(block) }
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(blocks) { block in scheduleCard(block).frame(width: 165) }
                }
            }
        }
    }

    private func scheduleCard(_ block: ScheduledGroupBlock) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(slots[block.slot]).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { store.removeScheduleBlock(block) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
            }
            Text(block.group.memberNames).font(.subheadline.bold()).lineLimit(1)
            Text(block.group.title).font(.subheadline).lineLimit(2)
            if !block.group.categorySummary.isEmpty { Text(block.group.categorySummary).font(.caption2).foregroundStyle(color(for: block.group)).lineLimit(1) }
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(color(for: block.group).opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(color(for: block.group).opacity(0.25)))
    }

    private var availableCandidates: [BlockCandidate] {
        let used = Set(store.scheduledBlocks.map { groupKey($0.group) })
        return candidates.filter { !used.contains(groupKey($0.group)) }
    }

    private func groupKey(_ group: ActivityGroup) -> String {
        let memberIDs = group.members.map { $0.id.uuidString }.sorted().joined(separator: ",")
        let placeIDs = group.picks.map { $0.id.uuidString }.sorted().joined(separator: ",")
        return "\(memberIDs)|\(placeIDs)"
    }
    private func blocks(in slot: Int) -> [ScheduledGroupBlock] { scheduledToday.filter { $0.slot == slot } }
    private func slotColor(_ slot: Int) -> Color { blocks(in: slot).first.map { color(for: $0.group) } ?? TripTheme.indigo }
    private func color(for group: ActivityGroup) -> Color { group.members.first?.color ?? TripTheme.indigo }
}

private struct BlockCandidate: Identifiable {
    let proposal: GroupingProposal
    let group: ActivityGroup
    var id: UUID { group.id }
}

private struct PlacementSheet: View {
    let candidate: BlockCandidate
    let slots: [String]
    let onAdd: (Int, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var day: Int
    @State private var slot = 0

    init(candidate: BlockCandidate, slots: [String], initialDay: Int, onAdd: @escaping (Int, Int) -> Void) {
        self.candidate = candidate; self.slots = slots; self.onAdd = onAdd; _day = State(initialValue: initialDay)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("그룹 블록") {
                    LabeledContent(candidate.group.memberNames, value: candidate.group.title)
                    Text(candidate.group.reason).font(.caption).foregroundStyle(.secondary)
                }
                Section("배치할 시간") {
                    Picker("날짜", selection: $day) { ForEach(1...3, id: \.self) { Text("DAY \($0)").tag($0) } }
                    Picker("시간", selection: $slot) { ForEach(slots.indices, id: \.self) { Text(slots[$0]).tag($0) } }
                }
            }
            .navigationTitle("일정에 담기").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("추가") { onAdd(day, slot); dismiss() } }
            }
        }
    }
}
