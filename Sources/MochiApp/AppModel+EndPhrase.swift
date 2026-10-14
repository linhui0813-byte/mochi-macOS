import Foundation
import MochiCore
import MochiKernel

extension AppModel {
    /// Downloads/prepares Apple's local English model without starting the microphone.
    func checkEndingPhrase() {
        guard !busy, !endingPhrasePreparing, let phrase = settings.effectiveEndingPhrase else { return }
        cancelEndingPhrasePreparation()
        let id = UUID()
        endingPhrasePreparationID = id
        endingPhrasePreparing = true
        endingPhraseStatus = String(localized: "Preparing local speech recognition…")
        endingPhrasePreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let device = try await makeEndPhraseDevice(phrase)
                guard !Task.isCancelled, endingPhrasePreparationID == id else {
                    device?.stop()
                    return
                }
                if let device { preparedEndingPhrase = (phrase, device) }
                endingPhraseStatus = device == nil ? String(localized: "Not prepared") : String(localized: "Ready")
            } catch {
                guard !Task.isCancelled, endingPhrasePreparationID == id else { return }
                endingPhraseStatus = String(localized: "Unavailable · pause detection still works")
                notice = AppFailure.message(
                    for: error,
                    fallback: "Spoken ending phrase detection is unavailable. Pause detection still works.")
            }
            if endingPhrasePreparationID == id {
                endingPhrasePreparing = false
                endingPhrasePreparationTask = nil
            }
        }
    }
    func cancelEndingPhrasePreparation() {
        endingPhrasePreparationID = UUID()
        endingPhrasePreparationTask?.cancel()
        endingPhrasePreparationTask = nil
        preparedEndingPhrase?.device.stop()
        preparedEndingPhrase = nil
        endingPhrasePreparing = false
        endingPhraseStatus =
            settings.effectiveEndingPhrase == nil ? String(localized: "Off") : String(localized: "Not prepared")
    }
}
