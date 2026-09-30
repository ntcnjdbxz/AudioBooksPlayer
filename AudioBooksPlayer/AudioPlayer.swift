import Foundation
import AVFoundation
import MediaPlayer
import UIKit

struct AudioBook: Identifiable, Hashable {
    let id: String
    let folderURL: URL
    let title: String
    let coverURL: URL?
    let tracks: [URL]
    let totalDuration: TimeInterval

    var firstTrack: URL? { tracks.first }
}

struct PlaybackState: Codable {
    var trackName: String
    var position: TimeInterval
    var lastPlayed: Date
    var completed: Bool
}

struct Bookmark: Codable, Identifiable, Hashable {
    let id: UUID
    let bookID: String
    let trackName: String
    let position: TimeInterval
    let createdAt: Date
}

final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var books: [AudioBook] = []
    @Published private(set) var currentBook: AudioBook?
    @Published private(set) var currentTrackIndex: Int = 0
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var volume: Float = 1.0
    @Published private(set) var isPlaying = false
    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var sleepRemaining: TimeInterval?
    @Published var sleepAfterCurrentTrack = false

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var sleepTimer: Timer?
    private var playbackStates: [String: PlaybackState] = [:]
    private let fm = FileManager.default
    private let persistenceBackupKey = "AudioBooksPlayer.persistence.backup.v1"
    static let inProgressThreshold: TimeInterval = 5 * 60

    override init() {
        super.init()
        setupAudioSession()
        loadPersistence()
        scanLibrary()
        configureRemoteCommands()
        setupLifecycleObservers()
    }

    deinit {
        timer?.invalidate()
        sleepTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Library

    func scanLibrary() {
        let root = booksDirectory()
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            print("Cannot create Books directory: \(error)")
        }

        let folders = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var result: [AudioBook] = []
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let book = makeBook(from: folder) else { continue }
            result.append(book)
        }

        books = result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        if let currentBook, let refreshed = books.first(where: { $0.id == currentBook.id }) {
            self.currentBook = refreshed
        }
    }

    private func makeBook(from folder: URL) -> AudioBook? {
        let urls = (try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let tracks = urls
            .filter { $0.pathExtension.lowercased() == "mp3" }
            .sorted(by: Self.trackSort)

        guard !tracks.isEmpty else { return nil }

        let coverURL = ["book_cover.jpeg", "book_cover.jpg", "book_cover.png"]
            .map { folder.appendingPathComponent($0) }
            .first(where: { fm.fileExists(atPath: $0.path) })

        let total = tracks.reduce(0) { partial, url in
            partial + AVAudioPlayer.durationForFile(url)
        }

        return AudioBook(
            id: folder.path,
            folderURL: folder,
            title: folder.lastPathComponent,
            coverURL: coverURL,
            tracks: tracks,
            totalDuration: total
        )
    }

    private static func trackSort(_ lhs: URL, _ rhs: URL) -> Bool {
        let l = leadingNumber(lhs.deletingPathExtension().lastPathComponent)
        let r = leadingNumber(rhs.deletingPathExtension().lastPathComponent)

        switch (l, r) {
        case let (a?, b?) where a != b:
            return a < b
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }
    }

    private static func leadingNumber(_ name: String) -> Int? {
        let digits = name.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    // MARK: - Playback

    func open(book: AudioBook) {
        saveCurrentState()
        stopTimer()
        player?.stop()
        isPlaying = false

        currentBook = book
        let state = playbackStates[book.id]
        let index = state.flatMap { saved in
            book.tracks.firstIndex { $0.lastPathComponent == saved.trackName }
        } ?? 0

        currentTrackIndex = min(index, max(0, book.tracks.count - 1))
        loadCurrentTrack(position: state?.position ?? 0)
    }

    func reloadLibrary() {
        scanLibrary()
    }

    func playPause() {
        guard let player else { return }
        if player.isPlaying {
            pause()
        } else {
            do { try AVAudioSession.sharedInstance().setActive(true) } catch { print(error) }
            player.play()
            isPlaying = true
            startTimer()
            updateNowPlaying()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        saveCurrentState()
        stopTimer()
        updateNowPlaying()
    }

    func stop() {
        player?.stop()
        isPlaying = false
        saveCurrentState()
        stopTimer()
        updateNowPlaying()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        currentTime = player.currentTime
        saveCurrentState()
        updateNowPlaying()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func previousTrack() {
        guard let book = currentBook else { return }
        if currentTime > 5 {
            seek(to: 0)
            return
        }
        guard currentTrackIndex > 0 else { return }
        saveCurrentState()
        currentTrackIndex -= 1
        loadCurrentTrack(position: 0)
        playIfWasPlayingOrStart()
    }

    func nextTrack() {
        guard let book = currentBook, currentTrackIndex + 1 < book.tracks.count else { return }
        saveCurrentState()
        currentTrackIndex += 1
        loadCurrentTrack(position: 0)
        playIfWasPlayingOrStart()
    }

    private func playIfWasPlayingOrStart() {
        do { try AVAudioSession.sharedInstance().setActive(true) } catch { print(error) }
        player?.play()
        isPlaying = true
        startTimer()
        updateNowPlaying()
    }

    private func loadCurrentTrack(position: TimeInterval) {
        guard let book = currentBook, book.tracks.indices.contains(currentTrackIndex) else { return }
        let url = book.tracks[currentTrackIndex]

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            newPlayer.volume = volume
            newPlayer.currentTime = min(max(0, position), newPlayer.duration)
            player = newPlayer
            currentTime = newPlayer.currentTime
            duration = newPlayer.duration
            updateNowPlaying()
        } catch {
            print("Player error: \(error)")
            player = nil
            duration = 0
            currentTime = 0
        }
    }

    func setVolume(_ value: Float) {
        volume = value
        player?.volume = value
        UserDefaults.standard.set(Double(value), forKey: "playerVolume")
    }

    func selectTrack(index: Int) {
        guard let book = currentBook, book.tracks.indices.contains(index) else { return }
        let wasPlaying = isPlaying
        saveCurrentState()
        stopTimer()
        player?.stop()
        isPlaying = false
        currentTrackIndex = index
        loadCurrentTrack(position: 0)
        if wasPlaying { playIfWasPlayingOrStart() }
    }

    // MARK: - Progress

    func bookProgress(_ book: AudioBook) -> Double {
        guard book.totalDuration > 0 else { return 0 }
        guard let state = playbackStates[book.id] else { return 0 }
        if state.completed { return 1 }

        let before = book.tracks.prefix { $0.lastPathComponent != state.trackName }
            .reduce(0) { $0 + AVAudioPlayer.durationForFile($1) }
        return min(1, max(0, (before + state.position) / book.totalDuration))
    }

    func lastPlayedDate(for book: AudioBook) -> Date? {
        playbackStates[book.id]?.lastPlayed
    }

    func isCompleted(_ book: AudioBook) -> Bool {
        playbackStates[book.id]?.completed == true
    }

    func isInProgress(_ book: AudioBook) -> Bool {
        guard let state = playbackStates[book.id], !state.completed else { return false }
        return bookProgress(book) * book.totalDuration >= Self.inProgressThreshold
    }

    func stateDescription(for book: AudioBook) -> String {
        if isCompleted(book) {
            return "Прослушано"
        }
        guard let state = playbackStates[book.id],
              let index = book.tracks.firstIndex(where: { $0.lastPathComponent == state.trackName }) else {
            return "Не начато"
        }
        let chapter = index + 1
        return "Глава \(chapter) · \(formatTime(state.position))"
    }

    // MARK: - Bookmarks

    func addBookmark() {
        guard let book = currentBook, let player else { return }
        let bookmark = Bookmark(
            id: UUID(), bookID: book.id,
            trackName: book.tracks[currentTrackIndex].lastPathComponent,
            position: player.currentTime,
            createdAt: Date()
        )
        bookmarks.append(bookmark)
        savePersistence()
    }

    func removeBookmark(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        savePersistence()
    }

    func openBookmark(_ bookmark: Bookmark) {
        guard let book = books.first(where: { $0.id == bookmark.bookID }),
              let index = book.tracks.firstIndex(where: { $0.lastPathComponent == bookmark.trackName }) else { return }
        currentBook = book
        currentTrackIndex = index
        loadCurrentTrack(position: bookmark.position)
        playIfWasPlayingOrStart()
    }

    func bookmarks(for book: AudioBook) -> [Bookmark] {
        bookmarks.filter { $0.bookID == book.id }.sorted { $0.position < $1.position }
    }

    // MARK: - Sleep timer

    func startSleepTimer(minutes: Int) {
        sleepAfterCurrentTrack = false
        sleepRemaining = TimeInterval(minutes * 60)
        sleepTimer?.invalidate()
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let remaining = self.sleepRemaining else { return }
            if remaining <= 1 {
                self.cancelSleepTimer()
                self.pause()
            } else {
                self.sleepRemaining = remaining - 1
            }
        }
        RunLoop.main.add(sleepTimer!, forMode: .common)
    }

    func sleepUntilEndOfTrack() {
        cancelSleepTimer()
        sleepAfterCurrentTrack = true
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepRemaining = nil
        sleepAfterCurrentTrack = false
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopTimer()
        isPlaying = false
        currentTime = duration

        if sleepAfterCurrentTrack {
            sleepAfterCurrentTrack = false
            cancelSleepTimer()
            saveCurrentState()
            updateNowPlaying()
            return
        }

        guard let book = currentBook else { return }
        if currentTrackIndex + 1 < book.tracks.count {
            currentTrackIndex += 1
            loadCurrentTrack(position: 0)
            playIfWasPlayingOrStart()
        } else {
            playbackStates[book.id] = PlaybackState(
                trackName: book.tracks[currentTrackIndex].lastPathComponent,
                position: duration,
                lastPlayed: Date(),
                completed: true
            )
            savePersistence()
            updateNowPlaying()
        }
    }

    // MARK: - Persistence

    private func persistenceURL() -> URL {
        booksDirectory().appendingPathComponent(".audiobooks_state.json")
    }

    private struct Persistence: Codable {
        var playback: [String: PlaybackState]
        var bookmarks: [Bookmark]
    }

    private func loadPersistence() {
        let defaultsVolume = UserDefaults.standard.double(forKey: "playerVolume")
        volume = defaultsVolume == 0 && UserDefaults.standard.object(forKey: "playerVolume") == nil ? 1.0 : Float(defaultsVolume)

        // First try the normal JSON file. This is the existing storage format and
        // must remain the primary source of playback history.
        if let data = try? Data(contentsOf: persistenceURL()),
           let value = try? JSONDecoder().decode(Persistence.self, from: data) {
            playbackStates = value.playback
            bookmarks = value.bookmarks

            // Keep a second copy in UserDefaults so an app update cannot leave
            // us with an empty history if the file is unexpectedly lost.
            UserDefaults.standard.set(data, forKey: persistenceBackupKey)
            return
        }

        // Fallback for an existing installation where the JSON file disappeared
        // or could not be decoded. Never replace the missing/invalid history with
        // an empty state during startup.
        if let data = UserDefaults.standard.data(forKey: persistenceBackupKey),
           let value = try? JSONDecoder().decode(Persistence.self, from: data) {
            playbackStates = value.playback
            bookmarks = value.bookmarks

            // Restore the normal file as well.
            try? data.write(to: persistenceURL(), options: .atomic)
        }
    }

    private func savePersistence() {
        let value = Persistence(playback: playbackStates, bookmarks: bookmarks)
        guard let data = try? JSONEncoder().encode(value) else { return }

        // Write both copies. UserDefaults is a safety net for app updates; the
        // JSON file remains the normal persistent storage used by the app.
        try? data.write(to: persistenceURL(), options: .atomic)
        UserDefaults.standard.set(data, forKey: persistenceBackupKey)
    }

    private func saveCurrentState() {
        guard let book = currentBook,
              book.tracks.indices.contains(currentTrackIndex) else { return }

        let track = book.tracks[currentTrackIndex]
        let position = player?.currentTime ?? currentTime
        let existing = playbackStates[book.id]

        // Preserve a completed state only while the playback position is still at the end.
        // If the user seeks back from the end, the book becomes in-progress again.
        let isAtEnd = duration > 0 && position >= duration - 0.5
        let completed = (existing?.completed == true) && isAtEnd

        playbackStates[book.id] = PlaybackState(
            trackName: track.lastPathComponent,
            position: position,
            lastPlayed: Date(),
            completed: completed
        )
        savePersistence()
    }

    // MARK: - Audio session / lifecycle / remote controls

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc private func appWillResignActive() {
        saveCurrentState()
    }

    @objc private func appDidEnterBackground() {
        saveCurrentState()
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if !self.isPlaying { self.playPause() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.isPlaying { self.pause() }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.skip(by: -15); return .success }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in self?.skip(by: 30); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.nextTrack(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.previousTrack(); return .success }
    }

    private func updateNowPlaying() {
        guard let book = currentBook, book.tracks.indices.contains(currentTrackIndex) else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let track = book.tracks[currentTrackIndex]
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: book.title,
            MPMediaItemPropertyAlbumTitle: track.deletingPathExtension().lastPathComponent,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let cover = book.coverURL, let image = UIImage(contentsOfFile: cover.path) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.currentTime = player.currentTime
            if Int(player.currentTime) % 5 == 0 { self.saveCurrentState() }
            self.updateNowPlaying()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "00:00" }
        let total = max(0, Int(time))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    func booksDirectory() -> URL {
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Books", isDirectory: true)
    }
}

private extension AVAudioPlayer {
    static func durationForFile(_ url: URL) -> TimeInterval {
        (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
    }
}
