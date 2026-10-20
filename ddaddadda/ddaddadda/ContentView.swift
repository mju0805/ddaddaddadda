    //
//  ContentView.swift
//  ddaddadda
//
//  Created by sun on 10/15/26.
//

import SwiftUI
import MapKit

struct ContentView: View {
    @State private var store = TripStore()

    var body: some View {
        Group {
            if !store.isReady {
                ProgressView("여행방을 준비하고 있어요…")
            } else if store.hasActiveTrip {
                NavigationStack { PlacePickerView(store: store) }
            } else {
                TripRoomEntryView(store: store)
            }
        }
        .tint(TripTheme.coral)
        .onOpenURL { store.handleInviteURL($0) }
        .alert("확인해주세요", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

private struct PlacePickerView: View {
    @Bindable var store: TripStore
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @State private var showPicks = true
    @State private var showPeople = false
    @State private var showAnalysis = false
    @State private var limitNotice = false
    @State private var camera: MapCameraPosition = .region(.pohang)

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $camera) {
                ForEach(store.allPicks) { pick in
                    Annotation(pick.name, coordinate: pick.coordinate) {
                        PlacePin(pick: pick, isMine: pick.ownerID == store.me.id)
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
            .mapControls { MapCompass(); MapScaleView() }
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 10) {
                header
                if !searchText.trimmingCharacters(in: .whitespaces).isEmpty { searchPanel }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { showPicks ? AnyView(picksSheet) : AnyView(collapsedBar) }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showPeople) {
            PeopleSheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showAnalysis) { AnalysisView(store: store) }
        .alert("6곳을 모두 골랐어요", isPresented: $limitNotice) {
            Button("확인", role: .cancel) {}
        } message: { Text("장소를 바꾸려면 아래 목록에서 하나를 먼저 지워주세요.") }
        .task(id: searchText) { await search() }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.tripTitle).font(.title3.bold())
                    Text("가고 싶은 곳을 6개 골라주세요").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showPeople = true } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            ForEach(Array(store.members.prefix(3).enumerated()), id: \.element.id) { index, member in
                                Circle().fill(member.color).frame(width: 24, height: 24)
                                    .overlay(Text(member.initial).font(.caption2.bold()).foregroundStyle(.white))
                                    .offset(x: CGFloat(index) * 15)
                            }
                        }.frame(width: 55, alignment: .leading)
                        Image(systemName: "person.2.fill")
                    }
                    .padding(.horizontal, 12).frame(height: 42)
                    .background(.ultraThinMaterial, in: Capsule())
                }.buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("장소 이름을 검색해보세요", text: $searchText)
                    .textInputAutocapitalization(.never).submitLabel(.search)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                }
            }
            .padding(.horizontal, 14).frame(height: 50)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
        }
    }

    private var searchPanel: some View {
        VStack(spacing: 0) {
            if isSearching { ProgressView().padding() }
            else if searchResults.isEmpty {
                ContentUnavailableView("검색 결과가 없어요", systemImage: "mappin.slash").frame(height: 130)
            } else {
                ForEach(Array(searchResults.prefix(5).enumerated()), id: \.offset) { index, item in
                    Button { add(item) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(TripTheme.coral)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name ?? "이름 없는 장소").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text(item.placemark.shortAddress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: store.hasPlace(item) ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(store.hasPlace(item) ? TripTheme.teal : .secondary)
                        }.padding(.horizontal, 14).frame(minHeight: 58)
                    }.buttonStyle(.plain)
                    if index < min(searchResults.count, 5) - 1 { Divider().padding(.leading, 52) }
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }

    private var picksSheet: some View {
        VStack(spacing: 0) {
            Capsule().fill(.tertiary).frame(width: 38, height: 5).padding(.top, 10)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("내가 고른 장소").font(.headline)
                    Text("\(store.myPicks.count) / 6 · 친구의 핀도 지도에 함께 보여요").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { withAnimation { showPicks = false } } label: {
                    Image(systemName: "chevron.down").frame(width: 34, height: 34).background(Color.secondary.opacity(0.10), in: Circle())
                }
            }.padding(.horizontal, 20).padding(.vertical, 14)
            if store.myPicks.isEmpty {
                Label("위 검색창에서 첫 장소를 골라보세요", systemImage: "hand.tap")
                    .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 66)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) { ForEach(store.myPicks) { pick in PickChip(pick: pick) { store.remove(pick) } } }
                        .padding(.horizontal, 20)
                }.frame(height: 70)
            }
            Button { store.confirmMine(); showAnalysis = true } label: {
                HStack {
                    Text(store.myPicks.isEmpty ? "장소를 먼저 골라주세요" : "이 장소들로 확정하기")
                    Spacer(); Image(systemName: "arrow.right")
                }
                .font(.headline).foregroundStyle(.white).padding(.horizontal, 20).frame(height: 56)
                .background(store.myPicks.isEmpty ? Color.secondary : TripTheme.coral, in: RoundedRectangle(cornerRadius: 17))
            }
            .disabled(store.myPicks.isEmpty).padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
        }
        .background(.ultraThickMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
        .shadow(color: .black.opacity(0.13), radius: 18, y: -4)
    }

    private var collapsedBar: some View {
        Button { withAnimation(.spring(response: 0.35)) { showPicks = true } } label: {
            HStack { Text("내가 고른 장소"); Spacer(); Text("\(store.myPicks.count) / 6").foregroundStyle(.secondary); Image(systemName: "chevron.up") }
                .font(.headline).padding(.horizontal, 20).frame(height: 62).background(.ultraThickMaterial)
        }.buttonStyle(.plain)
    }

    private func search() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count > 1 else { searchResults = []; return }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isSearching = true
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query; request.region = .pohang
        request.resultTypes = [.pointOfInterest, .address]
        let response = try? await MKLocalSearch(request: request).start()
        guard !Task.isCancelled else { return }
        searchResults = response?.mapItems ?? []; isSearching = false
    }

    private func add(_ item: MKMapItem) {
        if store.myPicks.count >= 6 { limitNotice = true; return }
        guard store.add(item) else { return }
        withAnimation { searchText = "" }
        camera = .region(MKCoordinateRegion(center: item.placemark.coordinate, latitudinalMeters: 7_000, longitudinalMeters: 7_000))
    }
}

private struct PlacePin: View {
    let pick: PlacePick; let isMine: Bool
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(pick.owner.color).frame(width: isMine ? 42 : 35, height: isMine ? 42 : 35)
                Image(systemName: pick.category.symbol).font(.system(size: isMine ? 17 : 14, weight: .bold)).foregroundStyle(.white)
            }.overlay(Circle().stroke(.white, lineWidth: 3)).shadow(color: .black.opacity(0.22), radius: 4, y: 3)
            Triangle().fill(pick.owner.color).frame(width: 11, height: 7).offset(y: -1)
        }
    }
}

private struct PickChip: View {
    let pick: PlacePick; let remove: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: pick.category.symbol).foregroundStyle(TripTheme.coral)
            Text(pick.name).font(.subheadline.weight(.medium)).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
        }.padding(.horizontal, 12).frame(height: 42).background(Color.secondary.opacity(0.09), in: Capsule())
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path { Path { p in p.move(to: .init(x: rect.midX, y: rect.maxY)); p.addLine(to: .init(x: rect.minX, y: rect.minY)); p.addLine(to: .init(x: rect.maxX, y: rect.minY)); p.closeSubpath() } }
}

extension MKCoordinateRegion {
    static let pohang = MKCoordinateRegion(center: .init(latitude: 36.050, longitude: 129.365), span: .init(latitudeDelta: 0.30, longitudeDelta: 0.24))
}

#Preview { ContentView() }
