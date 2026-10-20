import SwiftUI
import UIKit

struct TripRoomEntryView: View {
    @Bindable var store: TripStore
    @State private var name = ""
    @State private var roomTitle = "포항 여행"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 9) {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(TripTheme.coral)
                        Text("여행방에서\n함께 계획해요").font(.largeTitle.bold())
                        Text("한 명이 방을 만들면 바로 장소를 고를 수 있어요. 친구는 초대 코드나 링크로 같은 방에 들어옵니다.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("내 정보").font(.headline)
                        TextField("내 이름", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    .roomCard()

                    VStack(alignment: .leading, spacing: 14) {
                        Label("새 여행방 만들기", systemImage: "plus.circle.fill").font(.headline)
                        TextField("여행방 이름", text: $roomTitle)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            store.rename(name)
                            store.createRoom(title: roomTitle)
                        } label: {
                            actionLabel("방 만들고 지도 열기", symbol: "map.fill")
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isWorking || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .roomCard()

                    HStack { Rectangle().fill(.tertiary).frame(height: 1); Text("또는").font(.caption).foregroundStyle(.secondary); Rectangle().fill(.tertiary).frame(height: 1) }

                    VStack(alignment: .leading, spacing: 14) {
                        Label("초대 코드로 들어가기", systemImage: "link.circle.fill").font(.headline)
                        TextField("6자리 초대 코드", text: $store.inviteCodeInput)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Button {
                            store.rename(name)
                            store.joinRoom()
                        } label: {
                            actionLabel("여행방 들어가기", symbol: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isWorking || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.inviteCodeInput.isEmpty)
                    }
                    .roomCard()

                    if store.isWorking {
                        HStack { Spacer(); ProgressView("여행방을 확인하고 있어요…"); Spacer() }
                    }
                }
                .padding(22)
            }
            .background(Color(.systemGroupedBackground))
            .onAppear { name = store.me.name }
        }
    }

    private func actionLabel(_ title: String, symbol: String) -> some View {
        HStack {
            Image(systemName: symbol)
            Text(title)
            Spacer()
            if store.isWorking { ProgressView().tint(.white) }
        }
        .font(.headline)
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(TripTheme.coral, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct PeopleSheet: View {
    @Bindable var store: TripStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var showLeaveConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(store.tripTitle, systemImage: "person.3.fill")
                            .font(.title2.bold())
                        Text("이 방의 장소와 일정은 구성원 모두에게 실시간으로 반영돼요.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }

                    inviteCard

                    HStack {
                        TextField("내 이름", text: $name).textFieldStyle(.roundedBorder)
                        Button("저장") { store.rename(name) }.buttonStyle(.bordered)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("여행 구성원").font(.headline)
                        ForEach(store.members) { member in
                            HStack(spacing: 12) {
                                Circle().fill(member.color).frame(width: 38, height: 38)
                                    .overlay(Text(member.initial).font(.headline).foregroundStyle(.white))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(member.name + (member.id == store.me.id ? " (나)" : "")).fontWeight(.semibold)
                                    Text("\(store.allPicks.filter { $0.ownerID == member.id }.count)개 선택")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Label(member.isConfirmed ? "확정" : "선택 중", systemImage: member.isConfirmed ? "checkmark.circle.fill" : "ellipsis.circle")
                                    .font(.caption.weight(.semibold)).foregroundStyle(member.isConfirmed ? TripTheme.teal : .secondary)
                            }
                            .padding(.vertical, 5)
                        }
                    }

                    Button(role: .destructive) { showLeaveConfirmation = true } label: {
                        Label("여행방 나가기", systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(20)
            }
            .navigationTitle("여행방").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
            .onAppear { name = store.me.name }
            .confirmationDialog("이 여행방에서 나갈까요?", isPresented: $showLeaveConfirmation, titleVisibility: .visible) {
                Button("여행방 나가기", role: .destructive) {
                    dismiss()
                    store.leaveRoom()
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("다시 참여하려면 초대 코드가 필요해요.")
            }
        }
    }

    private var inviteCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("친구 초대하기").font(.headline)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("초대 코드").font(.caption).foregroundStyle(.secondary)
                    Text(store.inviteCode ?? "------")
                        .font(.system(.title2, design: .monospaced, weight: .bold))
                        .tracking(3)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = store.inviteCode
                } label: {
                    Label("복사", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }

            if let url = store.inviteURL {
                ShareLink(
                    item: url,
                    subject: Text("\(store.tripTitle) 초대"),
                    message: Text("따따따에서 함께 여행을 계획해요. 초대 코드: \(store.inviteCode ?? "")")
                ) {
                    Label("초대 링크 보내기", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(TripTheme.indigo, in: RoundedRectangle(cornerRadius: 15))
                }
            }
        }
        .roomCard()
    }
}

private extension View {
    func roomCard() -> some View {
        padding(18)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}
