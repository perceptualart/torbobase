#if canImport(SwiftUI)
import SwiftUI

// MARK: - Filter Mode

private enum ConnectorFilter: String, CaseIterable {
    case popular = "Popular"
    case all = "All"
    case connected = "Connected"
    case available = "Available"
}

// MARK: - ConnectorsView

struct ConnectorsView: View {
    @EnvironmentObject private var state: AppState

    @State private var searchText = ""
    @State private var activeFilter: ConnectorFilter = .popular
    @State private var categoryFilter: ConnectorCategory? = nil
    @State private var connectorStates: [String: Bool] = [:]
    @State private var selectedConnector: ConnectorDefinition? = nil
    @State private var showConfigSheet = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connectors")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Browse and configure service integrations for your agents")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 20)

                // Search bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.white.opacity(0.3))
                        .font(.system(size: 13))
                    TextField("Search connectors...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 32)
                .padding(.bottom, 16)

                // Filter pills + category dropdown
                HStack(spacing: 8) {
                    ForEach(ConnectorFilter.allCases, id: \.self) { filter in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { activeFilter = filter }
                        } label: {
                            Text(filter.rawValue)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(activeFilter == filter ? .white : .white.opacity(0.5))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(activeFilter == filter ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    // Category dropdown
                    Menu {
                        Button("All Categories") {
                            categoryFilter = nil
                        }
                        Divider()
                        ForEach(ConnectorCategory.allCases, id: \.self) { cat in
                            Button {
                                categoryFilter = cat
                            } label: {
                                Label(cat.rawValue, systemImage: cat.icon)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: categoryFilter?.icon ?? "line.3.horizontal.decrease")
                                .font(.system(size: 11))
                            Text(categoryFilter?.rawValue ?? "Category")
                                .font(.system(size: 12, weight: .medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.04))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 20)

                // Connector grid
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filteredConnectors, id: \.id) { connector in
                        connectorCard(connector)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)

                if filteredConnectors.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.2))
                        Text("No connectors found")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
        }
        .task { await loadStates() }
        .sheet(isPresented: $showConfigSheet) {
            if let connector = selectedConnector {
                ConnectorConfigSheet(connector: connector, connectorStates: $connectorStates)
            }
        }
    }

    // MARK: - Card

    @ViewBuilder
    private func connectorCard(_ connector: ConnectorDefinition) -> some View {
        let isConnected = connectorStates[connector.id] == true
        let isComingSoon = connector.status == .comingSoon

        HStack(spacing: 12) {
            // Icon
            Image(systemName: connector.icon)
                .font(.system(size: 18))
                .foregroundStyle(isComingSoon ? .white.opacity(0.2) : .white.opacity(0.7))
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(connector.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isComingSoon ? .white.opacity(0.3) : .white)
                        .lineLimit(1)

                    if isConnected {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                    }
                }

                Text(connector.description)
                    .font(.system(size: 12))
                    .foregroundStyle(isComingSoon ? .white.opacity(0.15) : .white.opacity(0.4))
                    .lineLimit(2)

                // Category badge
                Text(connector.category.rawValue)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.04))
                    .clipShape(Capsule())
            }

            Spacer(minLength: 0)

            // Actions
            if isComingSoon {
                Text("Coming Soon")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.2))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.04))
                    .clipShape(Capsule())
            } else if isConnected {
                Button {
                    selectedConnector = connector
                    showConfigSheet = true
                } label: {
                    Text("Configure")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            } else {
                Toggle("", isOn: Binding(
                    get: { connectorStates[connector.id] == true },
                    set: { newValue in
                        if newValue && !connector.configFields.isEmpty {
                            selectedConnector = connector
                            showConfigSheet = true
                        } else {
                            connectorStates[connector.id] = newValue
                            Task { await ConnectorStore.shared.setEnabled(connector.id, newValue) }
                        }
                    }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.7)
                .frame(width: 36)
            }
        }
        .padding(12)
        .background(Color.white.opacity(isComingSoon ? 0.01 : 0.02))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(isConnected ? 0.1 : 0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(isComingSoon ? 0.6 : 1.0)
    }

    // MARK: - Filtering

    private var filteredConnectors: [ConnectorDefinition] {
        var connectors = ConnectorCatalog.all

        // Category filter
        if let cat = categoryFilter {
            connectors = connectors.filter { $0.category == cat }
        }

        // Tab filter
        switch activeFilter {
        case .popular:
            connectors = connectors.filter { ConnectorCatalog.popularIDs.contains($0.id) }
        case .connected:
            connectors = connectors.filter { connectorStates[$0.id] == true }
        case .available:
            connectors = connectors.filter { connectorStates[$0.id] != true && $0.status != .comingSoon }
        case .all:
            break
        }

        // Search
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            connectors = connectors.filter {
                $0.name.lowercased().contains(query) || $0.description.lowercased().contains(query)
            }
        }

        return connectors
    }

    // MARK: - State Loading

    private func loadStates() async {
        let enabled = await ConnectorStore.shared.allEnabled()
        await MainActor.run {
            for id in enabled {
                connectorStates[id] = true
            }
        }
    }
}
#endif
