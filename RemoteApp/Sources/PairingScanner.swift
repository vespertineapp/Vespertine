//
// Vespertine Remote: scanning the QR code the Mac shows (VisionKit's live scanner; the Camera app works too).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VisionKit
import VespertineRemoteProtocol

struct PairingScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let found: (PairingLink) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    QRScanner(found: found).ignoresSafeArea()
                } else {
                    // On the app's own ground and type, as every other sheet: the system's plain white looked borrowed.
                    ContentUnavailableView {
                        Label {
                            Text("Can’t Scan Here").font(.serif(.title2, weight: .semibold)).foregroundStyle(Palette.text)
                        } icon: {
                            Image(systemName: "camera").foregroundStyle(Palette.brass)
                        }
                    } description: {
                        Text("Scan the code with the Camera app instead, or choose the Mac in the list and type the code under it.")
                            .foregroundStyle(Palette.text2)
                    }
                    .obsidianBackground()
                    .accessibilityIdentifier("scan-unavailable")
                }
            }
            .navigationTitle("Scan the Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let found: (PairingLink) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (PairingLink) -> Void
        private var done = false

        init(found: @escaping (PairingLink) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let text = code.payloadStringValue, let url = URL(string: text), let link = PairingLink(url: url) {
                    done = true
                    dataScanner.stopScanning()
                    found(link)
                    return
                }
            }
        }
    }
}
