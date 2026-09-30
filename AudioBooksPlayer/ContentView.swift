import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var audioPlayer = AudioPlayer()
    @StateObject private var wifiServer = WiFiTransferServer()
    @AppStorage("backgroundStyle") private var backgroundStyle = "lightGray"
    @AppStorage("fontSize") private var fontSize = 1
    @AppStorage("cardSize") private var cardSize = 1
    @AppStorage("sortMode") private var sortMode = "title"
    @AppStorage("sortAscending") private var sortAscending = true
    @State private var searchText = ""
    @State private var showingSettings = false
    @State private var showingWiFiTransfer = false

    private var bg: Color {
        switch backgroundStyle {
        case "white": return .white
        case "darkGray": return Color(white: 0.18)
        case "black": return .black
        default: return Color(white: 0.94)
        }
    }

    private var books: [AudioBook] {
        let filtered = audioPlayer.books.filter {
            searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText)
        }
        switch sortMode {
        case "lastPlayed":
            let values = filtered.sorted { a, b in
                (audioPlayer.lastPlayedDate(for: a) ?? .distantPast) > (audioPlayer.lastPlayedDate(for: b) ?? .distantPast)
            }
            return sortAscending ? values : values.reversed()
        case "progress":
            let values = filtered.sorted { audioPlayer.bookProgress($0) > audioPlayer.bookProgress($1) }
            return sortAscending ? values : values.reversed()
        default:
            let values = filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return sortAscending ? values : values.reversed()
        }
    }

    private var listeningNowBooks: [AudioBook] {
        books.filter { audioPlayer.isInProgress($0) }
            .sorted { (audioPlayer.lastPlayedDate(for: $0) ?? .distantPast) > (audioPlayer.lastPlayedDate(for: $1) ?? .distantPast) }
    }

    private var completedBooks: [AudioBook] {
        books.filter { audioPlayer.isCompleted($0) }
            .sorted { (audioPlayer.lastPlayedDate(for: $0) ?? .distantPast) > (audioPlayer.lastPlayedDate(for: $1) ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                bg.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !listeningNowBooks.isEmpty {
                            SectionTitle(title: "Слушаю сейчас", size: textSize(22))
                            LazyVStack(spacing: 12) {
                                ForEach(listeningNowBooks) { book in
                                    NavigationLink(value: book) {
                                        BookCard(book: book, player: audioPlayer, size: cardSize, fontSize: fontSize, prominent: true)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        SectionTitle(title: "Мои аудиокниги", size: textSize(22))

                        if books.isEmpty {
                            EmptyLibraryView()
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(books) { book in
                                    NavigationLink(value: book) {
                                        BookCard(book: book, player: audioPlayer, size: cardSize, fontSize: fontSize)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if !completedBooks.isEmpty {
                            SectionTitle(title: "Прослушано", size: textSize(22))
                            LazyVStack(spacing: 12) {
                                ForEach(completedBooks) { book in
                                    NavigationLink(value: book) {
                                        BookCard(book: book, player: audioPlayer, size: cardSize, fontSize: fontSize)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("AudioBooks")
            .searchable(text: $searchText, prompt: "Поиск книг")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { audioPlayer.reloadLibrary() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    Button { showingWiFiTransfer = true } label: {
                        Image(systemName: "wifi")
                    }
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .navigationDestination(for: AudioBook.self) { book in
                PlayerView(book: book, player: audioPlayer, fontSize: fontSize, background: bg)
            }
            .sheet(isPresented: $showingWiFiTransfer) {
                WiFiTransferView(server: wifiServer) {
                    audioPlayer.reloadLibrary()
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(backgroundStyle: $backgroundStyle, fontSize: $fontSize, cardSize: $cardSize, sortMode: $sortMode, sortAscending: $sortAscending)
                    .presentationDetents([.medium, .large])
            }
        }
        .preferredColorScheme(backgroundStyle == "black" || backgroundStyle == "darkGray" ? .dark : .light)
    }

    private func textSize(_ base: CGFloat) -> CGFloat {
        switch fontSize { case 0: return base - 2; case 2: return base + 3; case 3: return base + 6; default: return base }
    }
}

struct SectionTitle: View {
    let title: String
    let size: CGFloat
    var body: some View {
        Text(title).font(.system(size: size, weight: .bold))
    }
}

struct BookCard: View {
    let book: AudioBook
    @ObservedObject var player: AudioPlayer
    let size: Int
    let fontSize: Int
    var prominent = false

    private var coverW: CGFloat { size == 0 ? 70 : (size == 2 ? 120 : 90) }
    private var coverH: CGFloat { coverW * 4 / 3 }
    private var titleSize: CGFloat {
        switch fontSize { case 0: return prominent ? 18 : 16; case 2: return prominent ? 23 : 20; case 3: return prominent ? 26 : 23; default: return prominent ? 21 : 18 }
    }

    var body: some View {
        HStack(spacing: 14) {
            CoverView(url: book.coverURL, width: coverW, height: coverH)

            VStack(alignment: .leading, spacing: 7) {
                Text(book.title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .lineLimit(3)

                Text(player.stateDescription(for: book))
                    .font(.system(size: max(12, titleSize - 4)))
                    .foregroundStyle(.secondary)

                ProgressView(value: player.bookProgress(book))

                Text(player.formatTime(book.totalDuration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct CoverView: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.25))
                    VStack(spacing: 7) {
                        Image(systemName: "book.closed.fill").font(.system(size: width * 0.34))
                        Text("No Cover").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical.fill").font(.system(size: 55)).foregroundStyle(.secondary)
            Text("Книг пока нет").font(.title3.weight(.semibold))
            Text("Создай папку книги внутри AudioBooks и положи туда один или несколько MP3-файлов.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text("Files → On My iPhone → AudioBooks → Books")
                .font(.footnote.monospaced()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}

struct WiFiTransferView: View {
    @ObservedObject var server: WiFiTransferServer
    let reloadLibrary: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: server.isRunning ? "wifi" : "wifi.slash")
                    .font(.system(size: 50))
                    .foregroundStyle(server.isRunning ? .blue : .secondary)

                Text("Передача книг по Wi-Fi")
                    .font(.title2.weight(.bold))

                if server.isRunning {
                    Text("На Windows откройте в браузере:")
                        .foregroundStyle(.secondary)

                    let urlInfo = URLComponents(string: server.address)
                    let host = urlInfo?.host ?? "—"
                    let port = urlInfo?.port.map(String.init) ?? "—"

                    VStack(spacing: 14) {
                        VStack(spacing: 5) {
                            Text("IP-адрес iPhone")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(host)
                                .font(.system(size: 23, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .textSelection(.enabled)
                        }

                        Divider()

                        VStack(spacing: 5) {
                            Text("ПОРТ · фиксированный")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(port)
                                .font(.system(size: 34, weight: .bold, design: .monospaced))
                                .textSelection(.enabled)
                        }

                        Divider()

                        VStack(spacing: 5) {
                            Text("Полный адрес")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(server.address)
                                .font(.system(size: 15, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                                .allowsTightening(true)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity)
                        }

                        Button {
                            UIPasteboard.general.string = server.address
                        } label: {
                            Label("Копировать полный адрес", systemImage: "doc.on.doc")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))

                    Text("Выберите папку аудиокниги. Все MP3 и обложки будут сохранены в Books.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if server.uploadedCount > 0 {
                        Text("Загружено файлов: \(server.uploadedCount)")
                            .font(.headline)
                        if !server.lastUploadedPath.isEmpty {
                            Text(server.lastUploadedPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Button("Обновить библиотеку") {
                        reloadLibrary()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Остановить сервер") {
                        server.stop()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text(server.status)
                        .foregroundStyle(.secondary)

                    if let error = server.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    Button("Запустить передачу") {
                        server.start()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Spacer()
            }
            .padding(24)
            .navigationTitle("Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                server.start()
            }
            .onDisappear {
                server.stop()
                reloadLibrary()
            }
        }
    }
}

struct PlayerView: View {
    let book: AudioBook
    @ObservedObject var player: AudioPlayer
    let fontSize: Int
    let background: Color
    @State private var showChapters = false
    @State private var showBookmarks = false
    @State private var showSleep = false

    private var titleSize: CGFloat {
        switch fontSize { case 0: return 19; case 2: return 25; case 3: return 28; default: return 22 }
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    CoverView(url: book.coverURL, width: 240, height: 320)
                        .shadow(radius: 8)
                        .padding(.top, 10)

                    Text(book.title)
                        .font(.system(size: titleSize, weight: .bold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    if let current = player.currentBook, current.id == book.id, current.tracks.indices.contains(player.currentTrackIndex) {
                        Text(current.tracks[player.currentTrackIndex].deletingPathExtension().lastPathComponent)
                            .font(.system(size: max(13, titleSize - 6)))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    VStack(spacing: 6) {
                        Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 0.01))
                        HStack {
                            Text(player.formatTime(player.currentTime)); Spacer(); Text(player.formatTime(player.duration))
                        }.font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal)

                    HStack(spacing: 28) {
                        Button { player.previousTrack() } label: { Image(systemName: "backward.fill").font(.title2) }
                        Button { player.skip(by: -15) } label: { Image(systemName: "gobackward.15").font(.title2) }
                        Button { player.playPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 30)).frame(width: 76, height: 76).background(.blue).foregroundStyle(.white).clipShape(Circle())
                        }
                        Button { player.skip(by: 30) } label: { Image(systemName: "goforward.30").font(.title2) }
                        Button { player.nextTrack() } label: { Image(systemName: "forward.fill").font(.title2) }
                    }
                    .disabled(player.currentBook?.id != book.id)

                    HStack {
                        Image(systemName: "speaker.fill")
                        Slider(value: Binding(get: { Double(player.volume) }, set: { player.setVolume(Float($0)) }), in: 0...1)
                        Image(systemName: "speaker.wave.3.fill")
                    }.padding(.horizontal)

                    HStack(spacing: 10) {
                        ActionButton(title: "Главы", icon: "list.bullet") { showChapters = true }
                        ActionButton(title: "Закладка", icon: "bookmark") { player.addBookmark() }
                        ActionButton(title: "Таймер", icon: "moon.zzz") { showSleep = true }
                    }

                    if let remaining = player.sleepRemaining {
                        Text("Таймер: \(player.formatTime(remaining))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if player.sleepAfterCurrentTrack {
                        Text("Остановить после текущего файла").font(.caption).foregroundStyle(.secondary)
                    }

                    Button { showBookmarks = true } label: {
                        Label("Мои закладки", systemImage: "bookmark.fill")
                    }
                    .padding(.top, 4)
                }
                .padding(.bottom, 30)
            }
        }
        .navigationTitle("Плеер")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if player.currentBook?.id != book.id { player.open(book: book) } }
        .sheet(isPresented: $showChapters) { ChaptersView(book: book, player: player) }
        .sheet(isPresented: $showBookmarks) { BookmarksView(book: book, player: player) }
        .sheet(isPresented: $showSleep) { SleepTimerView(player: player) }
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) { Image(systemName: icon); Text(title).font(.caption) }
                .frame(maxWidth: .infinity).padding(.vertical, 10).background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}

struct ChaptersView: View {
    let book: AudioBook
    @ObservedObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(Array(book.tracks.enumerated()), id: \.offset) { index, track in
                Button {
                    if player.currentBook?.id != book.id { player.open(book: book) }
                    player.selectTrack(index: index)
                    dismiss()
                } label: {
                    HStack {
                        Text(String(format: "%02d", index + 1)).foregroundStyle(.secondary).frame(width: 35, alignment: .leading)
                        Text(track.deletingPathExtension().lastPathComponent).lineLimit(2)
                        Spacer()
                        if player.currentBook?.id == book.id && player.currentTrackIndex == index { Image(systemName: player.isPlaying ? "waveform" : "pause") }
                    }
                }
            }
            .navigationTitle("Главы")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
}

struct BookmarksView: View {
    let book: AudioBook
    @ObservedObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(player.bookmarks(for: book)) { bookmark in
                    Button {
                        player.openBookmark(bookmark); dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "bookmark.fill")
                            Text(bookmark.trackName).lineLimit(1)
                            Spacer()
                            Text(player.formatTime(bookmark.position)).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button(role: .destructive) { player.removeBookmark(bookmark) } label: { Label("Удалить", systemImage: "trash") } }
                }
            }
            .overlay {
                if player.bookmarks(for: book).isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bookmark").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Нет закладок").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Закладки")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
}

struct SleepTimerView: View {
    @ObservedObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    let options = [15, 30, 45, 60]
    var body: some View {
        NavigationStack {
            List {
                Section("Таймер") {
                    Button("Выкл.") { player.cancelSleepTimer(); dismiss() }
                    ForEach(options, id: \.self) { minutes in
                        Button("\(minutes) минут") { player.startSleepTimer(minutes: minutes); dismiss() }
                    }
                    Button("До конца текущего файла") { player.sleepUntilEndOfTrack(); dismiss() }
                }
            }
            .navigationTitle("Таймер сна")
        }
    }
}

struct SettingsView: View {
    @Binding var backgroundStyle: String
    @Binding var fontSize: Int
    @Binding var cardSize: Int
    @Binding var sortMode: String
    @Binding var sortAscending: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Внешний вид") {
                    Picker("Фон", selection: $backgroundStyle) {
                        Text("Светло-серый").tag("lightGray")
                        Text("Белый").tag("white")
                        Text("Тёмно-серый").tag("darkGray")
                        Text("Чёрный").tag("black")
                    }
                    Picker("Размер текста", selection: $fontSize) {
                        Text("Маленький").tag(0)
                        Text("Обычный").tag(1)
                        Text("Большой").tag(2)
                        Text("Очень большой").tag(3)
                    }
                    Picker("Размер карточек", selection: $cardSize) {
                        Text("Компактный · 70×93").tag(0)
                        Text("Обычный · 90×120").tag(1)
                        Text("Крупный · 120×160").tag(2)
                    }
                }
                Section("Библиотека") {
                    Picker("Сортировать", selection: $sortMode) {
                        Text("По названию").tag("title")
                        Text("По прогрессу").tag("progress")
                        Text("По последнему прослушиванию").tag("lastPlayed")
                    }
                    Picker("Направление", selection: $sortAscending) {
                        Text("А → Я").tag(true)
                        Text("Я → А").tag(false)
                    }
                }
                Section("Плеер") {
                    Text("Скорость воспроизведения фиксирована: 1.0×")
                        .foregroundStyle(.secondary)
                    Text("Фоновое воспроизведение и управление с экрана блокировки включены постоянно.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Настройки")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
}
