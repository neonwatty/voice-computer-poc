import AVFoundation
import Combine
import Foundation

/// A small, local-only recording path for the first voice-input experiment.
final class LocalVoiceInput: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case recording
        case transcribing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var errorMessage = ""

    var onEvent: ((String, [String: String]) -> Void)?

    private let endpoint = URL(string: "http://127.0.0.1:8080/v1/audio/transcriptions")!
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordingStartedAt: TimeInterval?
    private var request: URLSessionDataTask?

    var statusMessage: String {
        switch state {
        case .idle: return "Transcripts appear in the command field for review."
        case .requestingPermission: return "Requesting microphone access…"
        case .recording: return "Recording locally. Click Stop Recording when finished."
        case .transcribing: return "Transcribing with the local server…"
        }
    }

    func start() {
        guard state == .idle else { return }
        errorMessage = ""
        state = .requestingPermission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            onEvent?("voice_permission_checked", ["status": "authorized"])
            beginRecording()
        case .notDetermined:
            onEvent?("voice_permission_checked", ["status": "not_determined"])
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.state == .requestingPermission else { return }
                    if granted {
                        self.onEvent?("voice_permission_granted", [:])
                        self.beginRecording()
                    } else {
                        self.fail(
                            "Microphone access is required to record a command.",
                            event: "voice_permission_denied")
                    }
                }
            }
        case .denied, .restricted:
            onEvent?("voice_permission_checked", ["status": "denied_or_restricted"])
            fail(
                "Enable microphone access for Voice Computer POC in System Settings → Privacy & Security → Microphone.",
                event: "voice_permission_denied")
        @unknown default:
            fail("Could not determine microphone permission.", event: "voice_permission_unknown")
        }
    }

    func stop(completion: @escaping (String) -> Void) {
        guard state == .recording, let recorder, let recordingURL else { return }
        recorder.stop()
        self.recorder = nil
        self.recordingURL = nil
        state = .transcribing
        let duration = ProcessInfo.processInfo.systemUptime - (recordingStartedAt ?? 0)
        recordingStartedAt = nil
        onEvent?("voice_recording_stopped", ["duration_ms": String(Int(duration * 1_000))])
        let audio = try? Data(contentsOf: recordingURL)
        removeRecordingFile(at: recordingURL)
        guard let audio else {
            fail("Could not read the recorded audio.", event: "voice_recording_read_failed")
            return
        }
        guard audio.count > 44 else {
            fail("No audio was recorded. Try speaking for a little longer.", event: "voice_recording_empty")
            return
        }
        onEvent?("voice_transcription_started", ["audio_bytes": String(audio.count)])
        let urlRequest = makeTranscriptionRequest(audio: audio)
        request = URLSession.shared.dataTask(with: urlRequest) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleTranscriptionResponse(
                    data, response: response, error: error, completion: completion)
            }
        }
        request?.resume()
    }

    private func makeTranscriptionRequest(audio: Data) -> URLRequest {
        let boundary = "VoiceComputerPOC-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n")
        body.append(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"command.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
        )
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n")

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = 60
        return urlRequest
    }

    private func handleTranscriptionResponse(
        _ data: Data?, response: URLResponse?, error: Error?, completion: (String) -> Void
    ) {
        guard state == .transcribing else { return }
        request = nil
        if let error {
            fail(
                "Could not reach the local transcription server at 127.0.0.1:8080.",
                event: "voice_transcription_network_failed",
                details: ["error": error.localizedDescription])
            return
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            fail(
                "The local transcription server gave no HTTP response.",
                event: "voice_transcription_invalid_response")
            return
        }
        guard status == 200 else {
            fail(
                "The local transcription server returned HTTP \(status).",
                event: "voice_transcription_http_failed",
                details: ["http_status": String(status)])
            return
        }
        guard let data,
            let result = try? JSONDecoder().decode(TranscriptionResponse.self, from: data),
            !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            fail("The local transcription server returned no transcript.", event: "voice_transcription_empty")
            return
        }
        let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .idle
        onEvent?("voice_transcription_completed", ["character_count": String(transcript.count)])
        completion(transcript)
    }

    func cancel() {
        let previousState = state
        recorder?.stop()
        recorder = nil
        if let recordingURL { removeRecordingFile(at: recordingURL) }
        recordingURL = nil
        recordingStartedAt = nil
        request?.cancel()
        request = nil
        state = .idle
        if previousState != .idle {
            onEvent?("voice_input_cancelled", ["phase": String(describing: previousState)])
        }
    }

    private func beginRecording() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "voice-computer-\(UUID().uuidString).wav")
        do {
            let recorder = try AVAudioRecorder(
                url: url,
                settings: [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ])
            guard recorder.prepareToRecord(), recorder.record() else {
                removeRecordingFile(at: url)
                fail("Could not start microphone recording.", event: "voice_recording_start_failed")
                return
            }
            self.recorder = recorder
            recordingURL = url
            recordingStartedAt = ProcessInfo.processInfo.systemUptime
            state = .recording
            onEvent?("voice_recording_started", [:])
        } catch {
            removeRecordingFile(at: url)
            fail(
                "Could not start microphone recording.", event: "voice_recording_start_failed",
                details: ["error": error.localizedDescription])
        }
    }

    private func fail(_ message: String, event: String, details: [String: String] = [:]) {
        errorMessage = message
        state = .idle
        onEvent?(event, details)
    }

    private func removeRecordingFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            onEvent?("voice_recording_cleanup_failed", ["error": error.localizedDescription])
        }
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
    }
}

extension Data {
    fileprivate mutating func append(_ text: String) {
        append(Data(text.utf8))
    }
}
