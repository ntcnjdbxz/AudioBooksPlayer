import Foundation
import AVFoundation

final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var volume: Float = 1.0
    @Published var fileName: String = "MP3 не найден"

    private var player: AVAudioPlayer?
    private var timer: Timer?

    override init() {
        super.init()
        setupAudioSession()
        loadFirstBook()
    }

    deinit {
        timer?.invalidate()
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    func loadFirstBook() {
        let booksURL = booksDirectory()

        do {
            try FileManager.default.createDirectory(
                at: booksURL,
                withIntermediateDirectories: true
            )
        } catch {
            print("Cannot create Books directory: \(error)")
        }

        let mp3Files = (try? FileManager.default.contentsOfDirectory(
            at: booksURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter {
            $0.pathExtension.lowercased() == "mp3"
        }.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        } ?? []

        guard let firstFile = mp3Files.first else {
            fileName = "MP3 не найден"
            player = nil
            return
        }

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: firstFile)
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            newPlayer.volume = volume

            player = newPlayer
            fileName = firstFile.deletingPathExtension().lastPathComponent
            duration = newPlayer.duration
            currentTime = 0
        } catch {
            fileName = "Ошибка открытия MP3"
            print("Player error: \(error)")
        }
    }

    func playPause() {
        guard let player else { return }

        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("Could not activate audio session: \(error)")
            }

            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        currentTime = 0
        isPlaying = false
        stopTimer()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = time
        currentTime = time
    }

    func setVolume(_ value: Float) {
        volume = value
        player?.volume = value
    }

    func reload() {
        stop()
        loadFirstBook()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.currentTime = player.currentTime
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func booksDirectory() -> URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        return documents.appendingPathComponent("Books", isDirectory: true)
    }

    func openBooksFolder() -> URL {
        booksDirectory()
    }

    func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        isPlaying = false
        currentTime = 0
        stopTimer()
    }
}
