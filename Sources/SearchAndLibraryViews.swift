import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    private var matches: [Channel] {
        query.isEmpty ? [] : model.channels.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.group.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(matches) { channel in
                NavigationLink(channel.name, value: channel)
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Channels, movies, and series")
            .navigationDestination(for: Channel.self) { PlayerView(channel: $0) }
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    private var favourites: [Channel] { model.channels.filter { model.favourites.contains($0.id) } }

    var body: some View {
        NavigationStack {
            Group {
                if favourites.isEmpty {
                    ContentUnavailableView("Library Empty", systemImage: "star",
                        description: Text("Favourite channels and saved titles will appear here."))
                } else {
                    List(favourites) { channel in
                        NavigationLink(channel.name, value: channel)
                    }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: Channel.self) { PlayerView(channel: $0) }
        }
    }
}

