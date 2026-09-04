import Foundation

// MARK: - Draining & teardown

extension CrispASREngine {
    func poll() -> ASREvent? {
        lock.lock(); defer { lock.unlock() }
        guard !inbox.isEmpty else { return nil }
        return inbox.removeFirst()
    }

    func finish() -> [ASREvent] {
        lock.lock()
        finishing = true
        lock.unlock()
        // Wait (bounded) for any in-flight decode or VAD pass to finish.
        // The deadline caps the TOTAL wait: each semaphore wait is at most
        // the remaining budget, so a hung decode/VAD call (its flag never
        // clears) delays teardown by at most `drainTimeout` instead of
        // re-arming a fresh 30 s wait forever.
        let deadline = ContinuousClock.now + Duration.seconds(Self.drainTimeout)
        while true {
            lock.lock()
            let inFlight = decodeInFlight || vadInFlight
            lock.unlock()
            if !inFlight {
                break
            }
            let remaining = deadline - ContinuousClock.now
            if remaining <= .zero {
                break
            }
            let components = remaining.components
            let nanoseconds = components.seconds * 1_000_000_000
                + components.attoseconds / 1_000_000_000
            _ = jobFinished.wait(timeout: .now() + .nanoseconds(Int(nanoseconds)))
        }

        // Flush any open utterance synchronously — capture has already
        // stopped, so nothing new can arrive. Skip speechless buffers
        // (VAD-confirmed silence, or the RMS backstop in degraded mode).
        // Snapshot the session under the lock: `close()` nils it there.
        lock.lock()
        let pcm = utterance
        let start = vadFirstSpeechStartSample ?? utteranceStartSample
        let end = vadLastSpeechEndSample ?? (utteranceStartSample + utterance.count)
        let hadSpeech = utteranceHasSpeech || (!vadActive && utteranceHasLoudAudio)
        let sessionHandle = session
        lock.unlock()

        if hadSpeech, let sessionHandle {
            if let raw = decode(pcm: pcm, session: sessionHandle) {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                #if DEBUG
                    print("[asr] flush decode: \(pcm.count) samples -> \(text.isEmpty ? "no text" : "\(text.count) chars")")
                #endif
                if !text.isEmpty {
                    inbox.append(.final(
                        text: text, startSample: start, endSample: end, lang: languageCode
                    ))
                }
            }
        }

        lock.lock()
        let drained = inbox
        inbox = []
        lock.unlock()
        return drained
    }

    /// Releases the C session (and the resident model) permanently. Not part
    /// of normal teardown — sessions stay warm so restarts are instant. Used
    /// only when the factory discards the engine (e.g. the model file was
    /// replaced and a fresh one takes its place).
    func close() {
        prepareLock.lock()
        defer { prepareLock.unlock() }
        lock.lock()
        finishing = true
        let sessionHandle = session
        session = nil
        lock.unlock()
        if let sessionHandle {
            lib.closeSession(sessionHandle)
        }
    }
}
