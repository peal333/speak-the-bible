// SpeechServices.swift

import Foundation
import Speech
import AVFoundation
import Combine

// MARK: DO NOT MODIFY AUDIO SESSION BEHAVIOR!!!

// MARK: - AudioSessionCoordinator (Provided as Unchanged)
enum AudioUser: String, CustomStringConvertible {
    case none
    case speechToText
    case textToSpeech

    var description: String {
        return self.rawValue
    }
}

enum AudioFocusError: Error, LocalizedError {
    case conflict(activeUser: AudioUser)

    var errorDescription: String? {
        switch self {
        case .conflict(let activeUser):
            return "Cannot acquire audio focus. Currently used by: \(activeUser.description)."
        }
    }
    
    var activeUser: AudioUser {
        switch self {
        case .conflict(let user): return user
        }
    }
}

class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    private var currentAudioUser: AudioUser = .none
    private let lock = NSLock()

    private init() {}

    func requestAudioFocus(for requester: AudioUser) throws {
        lock.lock()
        defer { lock.unlock() }

        if currentAudioUser == .none || currentAudioUser == requester {
            // print("AudioCoordinator: Granting focus to \(requester). Current user was \(currentAudioUser)")
            currentAudioUser = requester
        } else {
            // print("AudioCoordinator: Denying focus to \(requester). Current user: \(currentAudioUser)")
            throw AudioFocusError.conflict(activeUser: currentAudioUser)
        }
    }

    func releaseAudioFocus(for releaser: AudioUser) {
        lock.lock()
        defer { lock.unlock() }

        if currentAudioUser == releaser {
            // print("AudioCoordinator: Releasing focus from \(releaser).")
            currentAudioUser = .none
        } else {
            // print("AudioCoordinator: \(releaser) tried to release focus, but current user is \(currentAudioUser). No change made.")
        }
    }
    
    func getCurrentAudioUser() -> AudioUser {
        lock.lock()
        defer { lock.unlock() }
        return currentAudioUser
    }
}


// MARK: - SpeechServiceManager
class SpeechServiceManager: NSObject, ObservableObject, SFSpeechRecognizerDelegate, AVSpeechSynthesizerDelegate {

    // MARK: - Published Properties
    @Published var recognizedText = ""
    @Published var isRecording = false
    @Published var isSpeaking: Bool = false

    // MARK: - STT Properties
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled: Bool = false
    
    var onSttFinalRecognition: ((String) -> Void)?
    var onSttError: ((Error) -> Void)?

    private var speechPauseTimer: Timer?
    private let speechPauseDuration: TimeInterval = 3.0 // User-configurable pause duration for STT

    private var sttStopCompletionHandlers: [() -> Void] = []

    enum STTError: Error, LocalizedError {
        case authorizationFailed
        case recognizerUnavailable
        case audioFocusDenied(activeUser: AudioUser)
        case engineSetupFailed(Error) // For issues during STT setup

        var errorDescription: String? {
            switch self {
            case .authorizationFailed: return "Speech recognition authorization not granted."
            case .recognizerUnavailable: return "Speech recognizer is not available."
            case .audioFocusDenied(let activeUser): return "Could not start recording: Audio system busy with \(activeUser.description)."
            case .engineSetupFailed(let underlyingError): return "Audio engine setup failed: \(underlyingError.localizedDescription)"
            }
        }
        
        var audioFocusDeniedActiveUser: AudioUser? {
            if case .audioFocusDenied(let user) = self { return user }
            return nil
        }
    }

    // MARK: - TTS Properties
    private let ttsSynthesizer: AVSpeechSynthesizer
    var onTtsDidFinish: (() -> Void)?
    private var ttsStopCompletionHandlers: [() -> Void] = []
    // `activeTtsSessionID` stores the UUID of the utterance currently expected to complete and trigger onTtsDidFinish.
    private var activeTtsSessionID: UUID? = nil
    // `utteranceToSessionIDMap` maps AVSpeechUtterance instances to their session UUIDs.
    // Using NSMapTable for weak keys (utterances) and strong values (session ID strings).
    private var utteranceToSessionIDMap = NSMapTable<AVSpeechUtterance, NSString>(keyOptions: .weakMemory, valueOptions: .strongMemory)


    // AppSettings will be accessed via AppSettings.shared
    // private let appSettings: AppSettings // Removed

    // MARK: - Initialization
    override init() { // Changed initializer
        self.ttsSynthesizer = AVSpeechSynthesizer()
        super.init()

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("SpeechServiceManager: Failed to set up audio session: \(error.localizedDescription)")
        }
        
        self.speechRecognizer.delegate = self
        self.ttsSynthesizer.delegate = self
    }

    // MARK: - STT Methods
    func requestSTTAuthorization() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                if authStatus != .authorized {
                    self.onSttError?(STTError.authorizationFailed)
                }
            }
        }
    }
    
    /// Centralized method to handle the completion of an STT session (success, error, or cancellation).
    private func completeSttSession(finalText: String?, error: Error?) {
        _cleanupSTTResources(releaseFocus: true) // Clean up engine, tap, request, task
        
        DispatchQueue.main.async {
            if self.isRecording { self.isRecording = false }
            
            if let err = error {
                let nsError = err as NSError
                // Treat common "cancellation" or "session ended" errors as non-fatal if we have text
                if nsError.domain == "kAFAssistantErrorDomain" && (nsError.code == 203 || nsError.code == 216 || nsError.code == 1107 || nsError.code == 209 || nsError.code == 1101 || nsError.code == 1110) || nsError.code == NSURLErrorCancelled {
                    self.onSttFinalRecognition?(finalText ?? self.recognizedText)
                } else {
                    self.onSttError?(err)
                }
            } else {
                self.onSttFinalRecognition?(finalText ?? self.recognizedText)
            }
            
            let handlers = self.sttStopCompletionHandlers
            self.sttStopCompletionHandlers.removeAll()
            handlers.forEach { $0() }
        }
    }

    /// Internal helper to clean up STT-related resources.
    private func _cleanupSTTResources(releaseFocus: Bool) {
        speechPauseTimer?.invalidate()
        speechPauseTimer = nil
        
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
  
        if releaseFocus && AudioSessionCoordinator.shared.getCurrentAudioUser() == .speechToText {
            AudioSessionCoordinator.shared.releaseAudioFocus(for: .speechToText)
        }
    }

    func startRecording() throws {
        self._cleanupSTTResources(releaseFocus: true) // Ensure clean state before starting
        
        var focusAcquired = false
        
        do {
            try AudioSessionCoordinator.shared.requestAudioFocus(for: .speechToText)
            focusAcquired = true

            guard SFSpeechRecognizer.authorizationStatus().isAuthorized else {
                requestSTTAuthorization() // Attempt to request if not authorized, though it's async
                throw STTError.authorizationFailed
            }
            guard speechRecognizer.isAvailable else { throw STTError.recognizerUnavailable }

            DispatchQueue.main.async { self.recognizedText = "" }

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else {
                // This should ideally not happen if the object can be created.
                throw STTError.engineSetupFailed(NSError(domain: "SpeechServiceManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create SFSpeechAudioBufferRecognitionRequest"]))
            }
            recognitionRequest.shouldReportPartialResults = true // ContentView uses partial results

            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self = self else { return }
                var isFinalBySystem = false
                if let res = result {
                    DispatchQueue.main.async {
                        if (!res.isFinal && self.recognizedText != res.bestTranscription.formattedString) {
                            self.resetSpeechPauseTimer()
                        }
                        self.recognizedText = res.bestTranscription.formattedString
                    }
                    isFinalBySystem = res.isFinal
                }
                if error != nil || isFinalBySystem {
                    // `completeSttSession` handles cleanup and callbacks
                    self.completeSttSession(finalText: result?.bestTranscription.formattedString, error: error)
                }
            }
            
            let inputNode = audioEngine.inputNode
            let tapFormat = inputNode.outputFormat(forBus: 0)
            
            // Check if format is valid before installing tap
            guard tapFormat.channelCount > 0 else {
                throw STTError.engineSetupFailed(NSError(domain: "SpeechServiceManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Audio input node has an invalid format (0 channels)."]))
            }

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }
                
            tapInstalled = true
            
            if !audioEngine.isRunning {
                audioEngine.prepare()
                try audioEngine.start()
            }
            
            DispatchQueue.main.async { self.isRecording = true }
            resetSpeechPauseTimer()

        } catch {
            _cleanupSTTResources(releaseFocus: focusAcquired) // Clean up after failure, release focus if acquired
            DispatchQueue.main.async {
                if self.isRecording { self.isRecording = false } // Ensure state is updated
                // Call any pending completion handlers from a potential stopRecording call during this failed start
                let handlers = self.sttStopCompletionHandlers
                self.sttStopCompletionHandlers.removeAll()
                handlers.forEach { $0() }
            }
            
            if let sttError = error as? STTError { throw sttError } // Re-throw our specific STTError
            else if let audioFocusError = error as? AudioFocusError { throw STTError.audioFocusDenied(activeUser: audioFocusError.activeUser) }
            else { throw STTError.engineSetupFailed(error) } // Wrap other errors
        }
    }

    func stopRecording(completion: (() -> Void)? = nil) {
        if let comp = completion { sttStopCompletionHandlers.append(comp) }

        speechPauseTimer?.invalidate()
        speechPauseTimer = nil

        if recognitionTask != nil && isRecording { // If a task is active and we are in a recording state
            recognitionRequest?.endAudio() // This will trigger the task's completion handler, which calls completeSttSession
        } else {
            // No active task, or not formally recording. Clean up and call completions directly.
            _cleanupSTTResources(releaseFocus: true)
            DispatchQueue.main.async {
                if self.isRecording { self.isRecording = false } // Ensure state is updated
                let handlers = self.sttStopCompletionHandlers
                self.sttStopCompletionHandlers.removeAll()
                handlers.forEach { $0() }
            }
        }
    }

    private func resetSpeechPauseTimer() {
        speechPauseTimer?.invalidate()
        guard isRecording else { speechPauseTimer = nil; return } // Only set timer if actively recording
        speechPauseTimer = Timer.scheduledTimer(withTimeInterval: speechPauseDuration, repeats: false) { [weak self] _ in
            // print("SpeechServiceManager (STT): Speech pause timer fired.")
            self?.recognitionRequest?.endAudio() // Ending audio triggers task finalization
            self?.speechPauseTimer = nil
        }
    }
    
    // SFSpeechRecognizerDelegate
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        DispatchQueue.main.async {
            if !available {
                // print("SpeechServiceManager (STT): Recognizer became unavailable.")
                self.onSttError?(STTError.recognizerUnavailable)
                if self.isRecording {
                    // print("SpeechServiceManager (STT): Stopping recording due to recognizer unavailability.")
                    self.stopRecording(completion: nil) // This will trigger cleanup and callbacks
                }
            }
        }
    }

    // MARK: - TTS Methods
    func speak(text: String, interrupt: Bool = true) -> Bool {
        _cleanupSTTResources(releaseFocus: true) // Stop any STT before starting TTS
        
        let newSessionID = UUID() // Unique ID for this specific speech operation

        if interrupt && ttsSynthesizer.isSpeaking {
            print("SpeechServiceManager (TTS): Speak called with interrupt. Current active session (before stop): \(activeTtsSessionID?.uuidString ?? "nil"). Synthesizer will be stopped.")
            // Note: activeTtsSessionID is not changed here yet. The didCancel for the stopped utterance
            // will check against the activeTtsSessionID *at that time*.
            // This new speak() call will set its own newSessionID as activeTtsSessionID shortly.
            ttsSynthesizer.stopSpeaking(at: .immediate)
        }
        
        var focusAcquired = false
        do {
            try AudioSessionCoordinator.shared.requestAudioFocus(for: .textToSpeech)
            focusAcquired = true
        } catch {
            print("SpeechServiceManager (TTS): Could not acquire audio focus for speak: \(error.localizedDescription).")
            let handlers = self.ttsStopCompletionHandlers; self.ttsStopCompletionHandlers.removeAll(); handlers.forEach { $0() }
            return false
        }
        
        let utterance = AVSpeechUtterance(string: text)
        
        if AppSettings.shared.selectedVoiceIdentifier != "",
           let voice = AVSpeechSynthesisVoice(identifier: AppSettings.shared.selectedVoiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        
        utterance.rate = Float(AppSettings.shared.utteranceRate)
        
        // Map this utterance to its session ID and set it as the active session we're waiting for.
        utteranceToSessionIDMap.setObject(newSessionID.uuidString as NSString, forKey: utterance)
        self.activeTtsSessionID = newSessionID
        
        print("SpeechServiceManager (TTS): Starting TTS. New active session: \(newSessionID.uuidString) for text: \"\(text.prefix(30))\(text.count > 30 ? "..." : "")\"")
        ttsSynthesizer.speak(utterance)
        
        return true
    }

    func stopTTSSpeaking(completion: (() -> Void)? = nil) {
        if let comp = completion { ttsStopCompletionHandlers.append(comp) }
        
        if ttsSynthesizer.isSpeaking {
            print("SpeechServiceManager (TTS): stopTTSSpeaking called while speaking. Current active session (before stop): \(activeTtsSessionID?.uuidString ?? "nil"). This session will be invalidated as active.")
            // Invalidate the currently active session, so its cancellation doesn't trigger onTtsDidFinish.
            self.activeTtsSessionID = nil
            ttsSynthesizer.stopSpeaking(at: .immediate) // `didCancel` delegate method will call _completeTTSSession
        } else {
            print("SpeechServiceManager (TTS): stopTTSSpeaking called but not speaking. Clearing active session and completing.")
            self.activeTtsSessionID = nil
            _completeTTSSession(for: nil, wasCancelledOrFinishedByDelegate: false) // Process completion handlers, no specific utterance ended.
        }
    }
    
    /// Centralized method to handle the completion of a TTS session (finished, cancelled, or stopped).
    /// - Parameter completedUtterance: The utterance object from the delegate, or nil if called from a non-delegate path.
    /// - Parameter wasCancelledOrFinishedByDelegate: True if called from didFinish or didCancel.
    private func _completeTTSSession(for completedUtterance: AVSpeechUtterance?, wasCancelledOrFinishedByDelegate: Bool) {
        let sessionIDOfProcessedUtterance: UUID?
        if let utterance = completedUtterance, let sessionStr = utteranceToSessionIDMap.object(forKey: utterance) {
            sessionIDOfProcessedUtterance = UUID(uuidString: sessionStr as String)
        } else {
            sessionIDOfProcessedUtterance = nil
        }
        
        // Capture the `activeTtsSessionID` at this moment for comparison.
        // This is the ID of the utterance we *expected* to complete.
        let expectedActiveSessionID = self.activeTtsSessionID

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
        
            // Update our isSpeaking state if the synthesizer is truly no longer speaking.
            // This check is important because multiple utterances might be queued/cancelled rapidly.
            if self.isSpeaking && !self.ttsSynthesizer.isSpeaking {
                 self.isSpeaking = false
            }

            if AudioSessionCoordinator.shared.getCurrentAudioUser() == .textToSpeech {
                AudioSessionCoordinator.shared.releaseAudioFocus(for: .textToSpeech)
            }
            
            // Only call the primary onTtsDidFinish if an utterance was processed by a delegate,
            // it had a session ID, and that session ID matches the one we were actively waiting for.
            if wasCancelledOrFinishedByDelegate,
               let sidProcessed = sessionIDOfProcessedUtterance,
               let sidExpectedActive = expectedActiveSessionID,
               sidProcessed == sidExpectedActive {
                print("SpeechServiceManager (TTS): _completeTTSSession - Processed utterance's session (\(sidProcessed.uuidString)) matches expected active session. Invoking onTtsDidFinish.")
                self.onTtsDidFinish?()
                // This session has now completed its role. Clear it so it's not reused.
                if self.activeTtsSessionID == sidExpectedActive { // Ensure it hasn't changed in the delay
                    self.activeTtsSessionID = nil
                }
            } else {
                if wasCancelledOrFinishedByDelegate {
                     print("SpeechServiceManager (TTS): _completeTTSSession (delegate) - Processed utterance's session (\(sessionIDOfProcessedUtterance?.uuidString ?? "unknown/nil")) does NOT match expected active session (\(expectedActiveSessionID?.uuidString ?? "nil")). Not invoking primary onTtsDidFinish.")
                } else {
                    // This path is for stopTTSSpeaking when not speaking.
                    print("SpeechServiceManager (TTS): _completeTTSSession (non-delegate) - Not invoking primary onTtsDidFinish. Expected active session: \(expectedActiveSessionID?.uuidString ?? "nil")")
                }
            }

            // Always call and clear completion handlers associated with stopTTSSpeaking calls.
            let handlers = self.ttsStopCompletionHandlers
            self.ttsStopCompletionHandlers.removeAll()
            if !handlers.isEmpty {
                print("SpeechServiceManager (TTS): _completeTTSSession - Invoking \(handlers.count) stop completion handlers.")
                handlers.forEach { $0() }
            }
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate Methods
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = true }
        let startedUtteranceSessionIDStr = utteranceToSessionIDMap.object(forKey: utterance)
        let startedUtteranceSessionID = UUID(uuidString: startedUtteranceSessionIDStr as String? ?? "")
        print("SpeechServiceManager (TTS): Delegate didStart utterance. Utterance's session: \(startedUtteranceSessionID?.uuidString ?? "unknown"). Current active session: \(activeTtsSessionID?.uuidString ?? "nil"): \"\(utterance.speechString.prefix(30))\(utterance.speechString.count > 30 ? "..." : "")\"")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finishedUtteranceSessionIDStr = utteranceToSessionIDMap.object(forKey: utterance)
        let finishedUtteranceSessionID = UUID(uuidString: finishedUtteranceSessionIDStr as String? ?? "")
        print("SpeechServiceManager (TTS): Delegate didFinish utterance. Utterance's session: \(finishedUtteranceSessionID?.uuidString ?? "unknown"). Current active session: \(activeTtsSessionID?.uuidString ?? "nil").")
        _completeTTSSession(for: utterance, wasCancelledOrFinishedByDelegate: true)
        utteranceToSessionIDMap.removeObject(forKey: utterance) // Clean up map
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let cancelledUtteranceSessionIDStr = utteranceToSessionIDMap.object(forKey: utterance)
        let cancelledUtteranceSessionID = UUID(uuidString: cancelledUtteranceSessionIDStr as String? ?? "")
        print("SpeechServiceManager (TTS): Delegate didCancel utterance. Utterance's session: \(cancelledUtteranceSessionID?.uuidString ?? "unknown"). Current active session: \(activeTtsSessionID?.uuidString ?? "nil").")
        _completeTTSSession(for: utterance, wasCancelledOrFinishedByDelegate: true)
        utteranceToSessionIDMap.removeObject(forKey: utterance) // Clean up map
    }
}

extension SpeechServiceManager {
    static func formatError(_ error: Error?, context: String, specificError: String? = nil) -> (String, RecitationFlowState) {
        let baseMessage: String
        var detail = "Unknown"

        if let sttError = error as? STTError {
            if let activeUser = sttError.audioFocusDeniedActiveUser {
                 baseMessage = specificError ?? "\(context): Audio system busy with \(activeUser.description)."
                 detail = "Busy (\(activeUser.description))"
            } else {
                baseMessage = specificError ?? "\(context): \(error?.localizedDescription ?? "Unknown STT error")"
                detail = error?.localizedDescription ?? "Unknown STT"
            }
        } else {
            baseMessage = specificError ?? "\(context): \(error?.localizedDescription ?? "Unknown error")"
            detail = error?.localizedDescription ?? "Unknown"
        }
        return (baseMessage, .error("\(context): \(detail)"))
    }
}

// MARK: - Helpers (Provided from original SpeechServices.swift)
extension SFSpeechRecognizerAuthorizationStatus {
    var isAuthorized: Bool { self == .authorized }
}
