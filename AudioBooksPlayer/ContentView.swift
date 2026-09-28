import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var audioPlayer = AudioPlayer()

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                Image(systemName: "headphones.circle.fill")
                    .font(.system(size: 90))
                    .foregroundStyle(.blue)

                Text(audioPlayer.fileName)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal)

                VStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { audioPlayer.currentTime },
                            set: { audioPlayer.seek(to: $0) }
                        ),
                        in: 0...max(audioPlayer.duration, 0.01)
                    )

                    HStack {
                        Text(formatTime(audioPlayer.currentTime))
                        Spacer()
                        Text(formatTime(audioPlayer.duration))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                Button {
                    audioPlayer.playPause()
                } label: {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32))
                        .frame(width: 82, height: 82)
                        .background(.blue)
                        .foregroundStyle(.white)
                        .clipShape(Circle())
                }
                .disabled(audioPlayer.fileName == "MP3 не найден")

                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "speaker.fill")
                        Slider(
                            value: Binding(
                                get: { Double(audioPlayer.volume) },
                                set: { audioPlayer.setVolume(Float($0)) }
                            ),
                            in: 0...1
                        )
                        Image(systemName: "speaker.wave.3.fill")
                    }

                    Text("Громкость")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                Button {
                    audioPlayer.reload()
                } label: {
                    Label("Обновить Books", systemImage: "arrow.clockwise")
                }

                Spacer()
            }
            .padding()
            .navigationTitle("AudioBooks")
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "00:00" }

        let totalSeconds = max(0, Int(time))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

#Preview {
    ContentView()
}
