import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            HomeView().tabItem { Label("Home", systemImage: "house") }
            PlaceholderCatalogView(title: "Movies", icon: "film").tabItem { Label("Movies", systemImage: "film") }
            PlaceholderCatalogView(title: "Series", icon: "tv").tabItem { Label("Series", systemImage: "tv") }
            LiveTVView().tabItem { Label("Live TV", systemImage: "dot.radiowaves.left.and.right") }
            SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }
            LibraryView().tabItem { Label("Library", systemImage: "books.vertical") }
        }
    }
}

private struct HomeView: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text("Vibe TV").font(.largeTitle.bold())
                Text("Import a playlist in Live TV to begin. Movies, series, EPG, and TMDB integrations are ready for provider configuration.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(60)
        }
    }
}

struct PlaceholderCatalogView: View {
    let title: String
    let icon: String
    var body: some View {
        ContentUnavailableView(title, systemImage: icon,
            description: Text("Connect an authorised catalogue provider to populate this section."))
    }
}

