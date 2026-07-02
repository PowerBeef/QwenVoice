// Helper for scripts/lib/ios_device_state.sh — compiled on demand (see that file).
//
// Subcommands:
//   window-id            Print the CGWindowID of the iPhone Mirroring window
//                        (bundle com.apple.ScreenContinuity; process name is
//                        localized — French "Recopie de l'iPhone" — so we match
//                        by owner PID, never by name). Exit 1 when absent.
//   ocr <png-path>       Print Vision-recognized text lines (fr + en) from the
//                        capture, one per line, lowercased. Exit 1 on failure.
//
// Deliberately tiny + dependency-free: AppKit for the running-app lookup,
// CoreGraphics for the window list, Vision for OCR.

import AppKit
import CoreGraphics
import Foundation
import Vision

let mirroringBundleID = "com.apple.ScreenContinuity"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func mirroringPIDs() -> [pid_t] {
    NSWorkspace.shared.runningApplications
        .filter { $0.bundleIdentifier == mirroringBundleID }
        .map(\.processIdentifier)
}

func mirroringWindowID() -> CGWindowID? {
    let pids = Set(mirroringPIDs().map { Int($0) })
    guard !pids.isEmpty else { return nil }
    guard let info = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return nil }
    // Largest on-screen window owned by the Mirroring app (skips tooltips/panels).
    var best: (id: CGWindowID, area: Double)?
    for entry in info {
        guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int,
              pids.contains(ownerPID),
              let windowID = entry[kCGWindowNumber as String] as? Int,
              let bounds = entry[kCGWindowBounds as String] as? [String: Double],
              let width = bounds["Width"], let height = bounds["Height"],
              width > 80, height > 80
        else { continue }
        let area = width * height
        if best == nil || area > best!.area {
            best = (CGWindowID(windowID), area)
        }
    }
    return best?.id
}

func runOCR(pngPath: String) {
    guard let image = NSImage(contentsOfFile: pngPath),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { fail("could not load image at \(pngPath)") }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["fr-FR", "en-US"]
    request.usesLanguageCorrection = false

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
        try handler.perform([request])
    } catch {
        fail("Vision OCR failed: \(error.localizedDescription)")
    }
    for observation in request.results ?? [] {
        if let text = observation.topCandidates(1).first?.string {
            print(text.lowercased())
        }
    }
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "window-id":
    guard let id = mirroringWindowID() else { fail("no iPhone Mirroring window on screen") }
    print(id)
case "ocr":
    guard args.count > 2 else { fail("usage: mirror_state_ocr ocr <png-path>") }
    runOCR(pngPath: args[2])
default:
    fail("usage: mirror_state_ocr window-id | ocr <png-path>")
}
