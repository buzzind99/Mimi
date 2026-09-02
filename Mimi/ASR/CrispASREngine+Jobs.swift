import Foundation

// MARK: - Scheduling & jobs (decoding and VAD)

//
// Scheduling decisions and the job bodies live apart from the core lifecycle;
// they interlock with it only through `lock` and the in-flight flags.

extension CrispASREngine {
    /// Caller holds `lock`. Dispatches any due VAD pass (on its own queue)
    /// plus at most one decode job: an endpoint (final) decode first, else a
    /// step-spaced window (partial) decode. VAD and decode jobs run
    /// concurrently — the VAD is what feeds the endpoint and partial gates,
    /// so it must keep flowing while a multi-second decode occupies the
    /// decode queue.
    func maybeScheduleWorkLocked() {
        guard session != nil, !finishing else { return }
        maybeScheduleVADLocked()
        if maybeScheduleFinalLocked() {
            return
        }
        maybeSchedulePartialLocked()
    }

    /// Caller holds `lock`. Returns true if an endpoint (final) decode or a
    /// discard was dispatched.
    @discardableResult
    private func maybeScheduleFinalLocked() -> Bool {
        guard session != nil, !finishing, !decodeInFlight, !utterance.isEmpty else { return false }

        // Silence endpoint: the VAD confirmed a ≥`vadMinSilenceMS` gap by
        // ending the last speech span, and has analyzed at least
        // `endpointSamples` of audio past it (so a lagging VAD pass can't
        // finalize mid-speech). The endpoint redecodes the whole utterance
        // span for a clean final.
        if let speechEnd = vadLastSpeechEndSample,
           vadAnalyzedThroughSample - speechEnd >= Self.endpointSamples
        {
            #if DEBUG
                print(String(
                    format: "[asr] endpoint: %.2fs of confirmed silence after speech",
                    Double(vadAnalyzedThroughSample - speechEnd) / Double(Self.sampleRate)
                ))
            #endif
            dispatchFinalLocked(end: speechEnd)
            return true
        }

        // Forced-final cap: safety net under VAD, and the only endpoint in
        // degraded mode. Never decodes a buffer the backstop knows is silent.
        if utterance.count >= Self.utteranceCapSamples {
            if utteranceHasLoudAudio || utteranceHasSpeech {
                #if DEBUG
                    print("[asr] endpoint: utterance cap reached")
                #endif
                dispatchFinalLocked(end: utteranceStartSample + utterance.count)
            } else {
                #if DEBUG
                    print("[asr] discard: silent utterance reached cap")
                #endif
                discardUtteranceLocked()
            }
            return true
        }
        return false
    }

    /// True when the VAD is actually in the loop (symbols bound, model
    /// present, not runtime-disabled). Everything else is degraded mode.
    /// Callers hold `lock`.
    var vadActive: Bool {
        vadEnabled && vadModelPath != nil
    }

    /// Caller holds `lock`. Re-runs the VAD over the utterance after
    /// `vadCheckIntervalSamples` of new audio. Returns true if dispatched.
    @discardableResult
    private func maybeScheduleVADLocked() -> Bool {
        guard vadActive, !vadInFlight, !utterance.isEmpty,
              totalSamples - lastVADDispatchSample >= Self.vadCheckIntervalSamples
        else { return false }
        lastVADDispatchSample = totalSamples
        let pcm = utterance
        let start = utteranceStartSample
        let generation = utteranceGeneration
        vadInFlight = true
        vadQueue.async { [weak self] in
            self?.runVADJob(pcm: pcm, utteranceStart: start, generation: generation)
        }
        return true
    }

    /// Caller holds `lock`. Dispatches the step-spaced partial decode, gated
    /// on VAD-confirmed speech (BGM-only stretches must not put hallucinated
    /// drafts on the HUD) and on the VAD having found new speech since the
    /// last partial — a pause must not re-decode an unchanged window (which
    /// would just freeze the HUD draft on identical text).
    private func maybeSchedulePartialLocked() {
        guard session != nil, !finishing, !decodeInFlight, !utterance.isEmpty,
              utteranceHasSpeech,
              (vadLastSpeechEndSample ?? 0) > lastPartialSpeechEndSample,
              totalSamples - lastDecodeDispatchSample >= Self.stepSamples
        else { return }
        let pcm = window
        let end = totalSamples
        lastPartialSpeechEndSample = vadLastSpeechEndSample ?? 0
        decodeInFlight = true
        decodeQueue.async { [weak self] in
            self?.runDecode(pcm: pcm, start: max(0, end - pcm.count), end: end, isFinal: false)
        }
        lastDecodeDispatchSample = totalSamples
    }

    private func dispatchFinalLocked(end: Int) {
        let pcm = utterance
        let start = vadFirstSpeechStartSample ?? utteranceStartSample
        #if DEBUG
            print(String(
                format: "[asr] final dispatch: %.2fs utterance [%.2fs..%.2fs]",
                Double(pcm.count) / Double(Self.sampleRate),
                Double(start) / Double(Self.sampleRate),
                Double(end) / Double(Self.sampleRate)
            ))
        #endif
        decodeInFlight = true
        decodeQueue.async { [weak self] in
            self?.runDecode(pcm: pcm, start: start, end: end, isFinal: true)
        }
    }

    /// Runs on `vadQueue`. One job at a time (guarded by `vadInFlight` and
    /// the serial queue). Updates speech state under `lock`; the
    /// `crispasr_vad_slices` call itself is lock-free (the C library
    /// serializes access to the cached model internally).
    private func runVADJob(pcm: [Float], utteranceStart: Int, generation: Int) {
        defer {
            lock.lock()
            vadInFlight = false
            // The VAD verdict may make an endpoint (or a decode step) due.
            maybeScheduleWorkLocked()
            lock.unlock()
            // Signal *after* the flag reset (semaphore counts, so a waiter
            // that checked the flag before this point still wakes): the old
            // order let `finish` miss the signal and stall for its full
            // 30 s timeout.
            jobFinished.signal()
        }
        guard let vadModelPath else { return }

        #if DEBUG
            let vadStart = ContinuousClock.now
        #endif
        guard let slices = lib.vadSlices(
            modelPath: vadModelPath, pcm: pcm,
            parameters: CrispASRVADParameters(
                sampleRate: Self.sampleRate, threshold: Self.vadThreshold,
                minSpeechMS: Self.vadMinSpeechMS, minSilenceMS: Self.vadMinSilenceMS,
                padMS: Self.vadPadMS
            )
        ) else { return }
        let count = slices.count
        #if DEBUG
            print("[asr] vad: \(pcm.count) samples -> \(count) spans in \(ContinuousClock.now - vadStart)")
        #endif
        guard count >= 0 else {
            handleVADFailure(code: count)
            return
        }

        lock.lock()
        defer { lock.unlock() }
        // A final/discard reset the utterance while this pass was running —
        // the result no longer matches live state.
        guard generation == utteranceGeneration, vadEnabled else {
            #if DEBUG
                print("[asr] vad: dropped stale result (generation \(generation) vs \(utteranceGeneration), vadEnabled=\(vadEnabled))")
            #endif
            lib.vadFree(slices.spans)
            return
        }
        vadAnalyzedThroughSample = utteranceStart + pcm.count

        if count == 0 || slices.spans == nil {
            // Speechless buffer (VAD is authoritative over BGM): drop it so
            // the forced-final cap can't decode speechless audio later.
            lib.vadFree(slices.spans)
            if pcm.count >= Self.vadMinDiscardSamples {
                #if DEBUG
                    print(String(
                        format: "[asr] vad: speechless buffer (%.2fs) — discarded",
                        Double(pcm.count) / Double(Self.sampleRate)
                    ))
                #endif
                discardUtteranceLocked()
            }
            return
        }
        guard let spansPtr = slices.spans else { return }
        defer { lib.vadFree(spansPtr) }

        // Spans are float pairs [start_s, end_s] relative to the snapshot.
        // Every pass re-analyzes the whole utterance, so the latest pass's
        // last span end supersedes earlier ones. This matters during the
        // first `vadMinSilenceMS` of a pause: the VAD still reports the
        // open segment flushed at the analyzed-buffer end (firered closes a
        // span only after `min_silence_ms` of silence), which lies *inside*
        // the silence. Keeping a max() would ratchet speechEnd forward and
        // blind the endpoint until `speechEnd + endpointSamples` — merging
        // any sentence gap shorter than that. The closed span from the
        // confirming pass must therefore replace the flushed value.
        let firstStart = utteranceStart
            + Int(spansPtr.pointee * Float(Self.sampleRate))
        let lastEnd = utteranceStart
            + Int(spansPtr[2 * (Int(count) - 1) + 1] * Float(Self.sampleRate))
        vadFirstSpeechStartSample = vadFirstSpeechStartSample ?? firstStart
        vadLastSpeechEndSample = lastEnd
        utteranceHasSpeech = true
    }

    /// Caller holds `lock`. Drops the current utterance (speechless audio)
    /// and shrinks the window so stale audio can't leak into later decodes.
    func discardUtteranceLocked() {
        utterance = []
        utteranceStartSample = 0
        utteranceGeneration += 1
        utteranceHasSpeech = false
        utteranceHasLoudAudio = false
        lastPartialSpeechEndSample = 0
        vadLastSpeechEndSample = nil
        vadAnalyzedThroughSample = 0
        vadFirstSpeechStartSample = nil
        trimWindowLocked(throughSample: totalSamples)
    }

    private func handleVADFailure(code: Int32) {
        lock.lock()
        consecutiveVADFailures += 1
        // -3 (model could not be loaded) is persistent — degrade immediately;
        // transient errors get a few retries first.
        let shouldDisable = code == -3 || consecutiveVADFailures >= 3
        let alreadyDisabled = !vadEnabled
        if shouldDisable {
            vadEnabled = false
        }
        let n = consecutiveVADFailures
        lock.unlock()

        if shouldDisable && !alreadyDisabled {
            let message = "VAD failed (\(code)) — falling back to cap-only finalization"
            #if DEBUG
                print("[asr] \(message)")
            #endif
            onEngineError?(message)
        } else if n == 1 || n % 32 == 0 {
            let message = "VAD pass failed (×\(n))"
            #if DEBUG
                print("[asr] \(message)")
            #endif
        }
    }

    /// Runs on `decodeQueue`. One decode at a time (guarded by `decodeInFlight`
    /// and the serial queue); posts results into the inbox under `lock`.
    private func runDecode(pcm: [Float], start: Int, end: Int, isFinal: Bool) {
        #if DEBUG
            let decodeStart = ContinuousClock.now
        #endif
        defer {
            lock.lock()
            decodeInFlight = false
            // A decode finishing may mean the next step (or a due VAD pass)
            // is already pending.
            maybeScheduleWorkLocked()
            lock.unlock()
            // Signal after the flag reset — see runVADJob.
            jobFinished.signal()
        }
        // Snapshot the session under the lock at job start: `close()` nils
        // it there, and the decode must not race that read.
        lock.lock()
        let sessionHandle = session
        lock.unlock()
        guard let sessionHandle else { return }

        // Backends with convolutional encoders reject audio shorter than the
        // first conv kernel (~2 s at 16 kHz); zero-pad short spans.
        var pcm = pcm
        if pcm.count < Self.minDecodeSamples {
            pcm.append(contentsOf: [Float](repeating: 0, count: Self.minDecodeSamples - pcm.count))
        }

        guard let raw = lib.transcribeText(
            session: sessionHandle, pcm: pcm, languageCode: languageCode
        ) else {
            reportDecodeFailure()
            if isFinal {
                // A failed final must still close out the utterance: leaving
                // it open keeps the endpoint/cap conditions true and
                // re-decodes the same buffer forever (same rationale as the
                // empty-text final below). Partials are step-gated and
                // simply retry on the next step.
                lock.lock()
                finalizeUtteranceLocked(end: end)
                lock.unlock()
            }
            return
        }
        #if DEBUG
            print("[asr] \(isFinal ? "final" : "partial") decode: \(pcm.count) samples in \(ContinuousClock.now - decodeStart)")
        #endif
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
            if text.isEmpty {
                print("[asr] \(isFinal ? "final" : "partial") decode returned no text (\(pcm.count) samples)")
            }
        #endif

        lock.lock()
        defer { lock.unlock() }
        processedCount = max(processedCount, end)
        if isFinal {
            if !text.isEmpty {
                inbox.append(.final(text: text, startSample: start, endSample: end, lang: languageCode))
            }
            // Close out the utterance even when the decode produced nothing:
            // leaving it open would keep the endpoint/cap conditions true and
            // re-decode the same buffer forever (finals wedge, partials die).
            finalizeUtteranceLocked(end: end)
        } else if !text.isEmpty {
            inbox.append(.partial(text: text))
        }
    }

    /// Caller holds `lock`. Closes out the utterance through `end` (the span
    /// a final decode covered): drops the finalized span, re-seeding any
    /// speech that resumed while the decode was in flight as the start of
    /// the next utterance, and resets all endpoint state.
    private func finalizeUtteranceLocked(end: Int) {
        let finalized = end - utteranceStartSample
        if finalized >= 0, finalized < utterance.count {
            utterance.removeFirst(finalized)
            utteranceStartSample = end
            if !utterance.isEmpty {
                utteranceHasLoudAudio = true
            }
        } else {
            utterance = []
            utteranceStartSample = 0
        }
        utteranceGeneration += 1
        utteranceHasSpeech = false
        lastPartialSpeechEndSample = 0
        vadLastSpeechEndSample = nil
        vadAnalyzedThroughSample = 0
        vadFirstSpeechStartSample = nil
        trimWindowLocked(throughSample: end)
    }

    /// Caller holds `lock`. Drops the finalized span from the rolling window
    /// (plus a short tail for decode context) so the next step-spaced partial
    /// decodes only post-final audio instead of re-transcribing the sentence
    /// that was just finalized.
    private func trimWindowLocked(throughSample end: Int) {
        let windowStart = totalSamples - window.count
        let drop = min(window.count, max(0, end + Self.windowKeepTailSamples - windowStart))
        if drop > 0 {
            window.removeFirst(drop)
        }
    }

    private func reportDecodeFailure() {
        lock.lock()
        consecutiveDecodeFailures += 1
        let n = consecutiveDecodeFailures
        lock.unlock()
        guard n == 1 || n % 32 == 0 else { return }
        let message = "ASR decode failed (×\(n))"
        #if DEBUG
            print("[asr] \(message)")
        #endif
        onEngineError?(message)
    }
}
