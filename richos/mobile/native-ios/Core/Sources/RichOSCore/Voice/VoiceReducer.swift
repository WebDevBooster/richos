import Foundation

/// The two ways to send a voice message (round-12 groups 4, 5, 6): hold-and-release, and slide up to
/// lock. One state machine, `idle → pressed → held → locked → ending → idle`, fed touch offsets and
/// time; every threshold is `VoiceGeometry`'s, from round 12's NOTES.md "Motion". The views only draw
/// the session and animate with the NOTES' timings.
///
/// Rules that are never broken, each a test: an interruption or a permission prompt is never a
/// send; a recording that reaches the ceiling or is interrupted is KEPT, never sent by itself and
/// never discarded; a release under 500 ms sends nothing; a press while the microphone is off always
/// answers with the microphone-off card, and nothing but a press raises it (D03).
enum VoiceReducer {
    static func reduce(_ s: inout AppState, _ action: Action, _ effects: inout [Effect]) {
        switch action {
        case .voicePress(let id, let width, let at):
            guard s.voice == nil, s.pairing == .paired, s.consentGiven, s.voiceAvailability == .available,
                  s.connectionNotice != .incompatible else { return }
            switch s.microphone {
            case .denied:
                // D03: the press is answered by the card that says the microphone is off and offers
                // iPhone Settings (round-12 `rec-mic-denied`). The press never asks again: iOS shows
                // its question once, and the person already answered it.
                s.microphoneCard = true
            case .unknown:
                // The system asks once, on the first deliberate press. This press never records.
                s.voice = VoiceSession(id: id, phase: .pressed, startedAtMs: at, nowMs: at, recordingStartedAtMs: nil, width: width)
                s.sheet = .microphonePrompt
                effects.append(.requestMicrophone)
            case .granted:
                s.voice = VoiceSession(id: id, phase: .pressed, startedAtMs: at, nowMs: at, recordingStartedAtMs: nil, width: width)
            }
        case .microphonePermission(let permission):
            s.microphone = permission
            // The card stays while the microphone is still off; it goes the moment it is allowed.
            if permission != .denied { s.microphoneCard = false }
            if s.sheet == .microphonePrompt {
                s.sheet = nil
                s.voice = nil  // the press that asked is over; the next press records
            }
        case .voiceMove(let dx, let dy, let at):
            guard var v = s.voice, v.phase == .held else { return }
            v.nowMs = at
            v.dx = dx
            v.dy = dy
            v.cancelProgress = min(1, max(0, -dx / VoiceGeometry.cancelDistance(width: v.width)))
            v.lockProgress = v.cancelProgress > VoiceGeometry.lockRefusedAfterCancelProgress
                ? 0 : min(1, max(0, -dy / VoiceGeometry.lockDistance))
            s.voice = v
            if v.cancelProgress >= 1 {
                end(&s, .canceled, &effects)          // fires mid-slide, without a release
            } else if v.lockProgress >= 1 {
                s.voice?.phase = .locked
                s.voice?.wasLocked = true
                s.voice?.dx = 0
                s.voice?.dy = 0
                s.voice?.cancelProgress = 0
                effects.append(.hapticTick)
            }
        case .voiceRelease(let at):
            guard let v = s.voice else { return }
            s.voice?.nowMs = at
            // Lifting the finger while the system asks for the microphone is not a gesture at all.
            if s.sheet == .microphonePrompt { return }
            switch v.phase {
            case .pressed:
                tooShort(&s, &effects)
            case .held:
                if v.cancelProgress > VoiceGeometry.releaseCancelsAfterProgress {
                    end(&s, .canceled, &effects)
                } else if (s.voice?.elapsedMs ?? 0) < VoiceGeometry.tooShortMs {
                    tooShort(&s, &effects)
                } else {
                    send(&s, at: at, &effects)
                }
            default:
                break  // a locked recording ignores the finger lifting; it was already lifted
            }
        case .voiceLockedSend(let at):
            guard s.voice?.phase == .locked else { return }
            s.voice?.nowMs = at
            send(&s, at: at, &effects)
        case .voiceLockedCancel(let at):
            guard s.voice?.phase == .locked else { return }
            s.voice?.nowMs = at
            end(&s, .canceled, &effects)
        case .voiceStartFailed(let id):
            if s.voice?.id == id { s.voice = nil }
        case .voiceTouchCanceled(let at):
            // The system took the touch (an alert, a call banner): lock under 30% slide, else cancel.
            guard s.voice?.phase == .held else {
                if s.voice?.phase == .pressed { s.voice = nil }
                return
            }
            s.voice?.nowMs = at
            if (s.voice?.cancelProgress ?? 0) < VoiceGeometry.lockRefusedAfterCancelProgress {
                s.voice?.phase = .locked
                s.voice?.wasLocked = true
            } else {
                end(&s, .canceled, &effects)
            }
        case .voiceInterrupted(let at), .backgrounded(let at):
            // The app left the screen, or the OS took the audio: keep what was recorded. Never a send.
            guard let v = s.voice else { return }
            s.voice?.nowMs = at
            switch v.phase {
            case .held, .locked:
                keep(&s, reason: .interrupted, &effects)
            case .pressed:
                s.voice = nil
            case .ending:
                break
            }
        case .voiceLevel(let level):
            guard let v = s.voice, v.phase == .held || v.phase == .locked else { return }
            s.voice?.levels.append(min(1, max(0, level)))
        case .dismissMicrophoneCard:
            s.microphoneCard = false
        case .voiceSettled:
            if case .ending? = s.voice?.phase { s.voice = nil }
            if s.toast == .tooShort { s.toast = nil }
        case .voiceStartLocked(let id, let width, let at):
            // VoiceOver's "record hands-free": no gesture to hold, so recording starts already locked.
            guard s.voice == nil, s.pairing == .paired, s.consentGiven, s.voiceAvailability == .available,
                  s.connectionNotice != .incompatible, s.microphone == .granted else {
                if s.microphone == .unknown, s.voice == nil { effects.append(.requestMicrophone) }
                // The same answer a held press gets while the microphone is off (D03).
                if s.microphone == .denied, s.voice == nil, s.pairing == .paired, s.consentGiven,
                   s.voiceAvailability == .available, s.connectionNotice != .incompatible {
                    s.microphoneCard = true
                }
                return
            }
            s.voice = VoiceSession(id: id, phase: .locked, startedAtMs: at, nowMs: at, recordingStartedAtMs: at,
                                   width: width, wasLocked: true)
            effects.append(.startRecording(id: id))
        case .tick(let at):
            // Nothing records while the system is asking for the microphone.
            guard var v = s.voice, s.sheet != .microphonePrompt else { return }
            v.nowMs = at
            if v.phase == .pressed, at - v.startedAtMs >= VoiceGeometry.pressDelayMs {
                v.phase = .held
                v.recordingStartedAtMs = v.startedAtMs + VoiceGeometry.pressDelayMs
                effects.append(.startRecording(id: v.id))
            }
            s.voice = v
            guard v.phase == .held || v.phase == .locked else { return }
            if v.elapsedMs >= Limits.voiceCeilingMs {
                keep(&s, reason: .ceiling, &effects)   // stops itself and is kept; the card offers Send
            } else if v.elapsedMs >= Limits.voiceWarningMs, !v.ceilingWarned {
                s.voice?.ceilingWarned = true
                s.toast = .ceilingWarning
            }
        case .sendKept(let id, let at):
            guard let i = s.keptRecordings.firstIndex(where: { $0.id == id }), s.pairing == .paired,
                  s.voiceAvailability == .available, s.connectionNotice != .incompatible else { return }
            let kept = s.keptRecordings.remove(at: i)
            enqueueVoice(&s, id: kept.id, durationMs: kept.durationMs, levels: kept.levels, at: at, &effects)
        case .discardKept(let id):
            guard s.keptRecordings.contains(where: { $0.id == id }) else { return }
            s.keptRecordings.removeAll { $0.id == id }
            effects.append(.deleteRecording(id: id))
        case .playRecording(let id):
            guard s.keptRecordings.contains(where: { $0.id == id }) || s.messages.contains(where: { $0.id == id && $0.kind == .voice }) else { return }
            if s.playback != nil { effects.append(.stopAudio) }
            s.playback = Playback(messageID: id, phase: .playing)
            let recordingID = s.messages.first(where: { $0.id == id && $0.kind == .voice })?.clientID ?? id
            effects.append(.playRecording(id: recordingID))
        default:
            break
        }
    }

    private static func tooShort(_ s: inout AppState, _ effects: inout [Effect]) {
        let recorded = s.voice?.recordingStartedAtMs != nil
        s.voice?.phase = .ending(.tooShort)
        s.toast = .tooShort
        if recorded, let id = s.voice?.id { effects.append(.stopRecording(id: id, keep: false)) }
    }

    private static func end(_ s: inout AppState, _ ending: VoiceEnding, _ effects: inout [Effect]) {
        guard let id = s.voice?.id else { return }
        s.voice?.phase = .ending(ending)
        effects.append(.stopRecording(id: id, keep: false))
    }

    private static func keep(_ s: inout AppState, reason: KeptRecording.Reason, _ effects: inout [Effect]) {
        guard let v = s.voice else { return }
        s.keptRecordings.append(KeptRecording(id: v.id, durationMs: Int(v.elapsedMs), levels: v.levels, reason: reason, recordedAt: v.recordingStartedAtMs ?? v.startedAtMs))
        effects.append(.stopRecording(id: v.id, keep: true))
        if reason == .ceiling {
            s.voice?.phase = .ending(.ceiling)
            s.toast = nil
        } else {
            s.voice = nil
        }
    }

    private static func send(_ s: inout AppState, at: Int64, _ effects: inout [Effect]) {
        guard let v = s.voice else { return }
        s.voice?.phase = .ending(.sent)
        effects.append(.stopRecording(id: v.id, keep: true))
        enqueueVoice(&s, id: v.id, durationMs: Int(v.elapsedMs), levels: v.levels, at: at, &effects)
    }

    /// The recording becomes a voice bubble backed by an outbox item; the destination conversation
    /// was captured when recording began (the Mac this phone is paired with).
    private static func enqueueVoice(_ s: inout AppState, id: String, durationMs: Int, levels: [Double], at: Int64, _ effects: inout [Effect]) {
        guard !s.outbox.contains(where: { $0.clientID == id }) else { return }
        s.outbox.append(OutboxItem(clientID: id, kind: .voice, body: nil, recordingID: id,
                                   target: Delivery.voiceTarget(clientID: id, threadID: s.mac?.threadID, seconds: Double(durationMs) / 1000,
                                                                sentAtISO: ConversationReducer.isoMillis(at)),
                                   queuedAt: at))
        s.messages.append(Message(id: id, author: .me, kind: .voice, text: "", sentAt: at, delivery: .waiting,
                                  durationMs: durationMs, levels: levels, clientID: id,
                                  echoAfterCursor: s.messages.compactMap(\.cursor).max(),
                                  echoAfterMessageID: s.messages.last(where: { $0.cursor != nil })?.id))
        s.following = true
        ConversationReducer.pump(&s, at: at, &effects)
    }
}
