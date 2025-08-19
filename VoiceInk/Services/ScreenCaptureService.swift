import Foundation
import AppKit
import Vision
import os
import ScreenCaptureKit

class ScreenCaptureService: NSObject, ObservableObject, SCStreamDelegate, SCStreamOutput {
    @Published var isCapturing = false
    @Published var lastCapturedText: String?
    
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.VoiceInk",
        category: "aienhancement"
    )
    
    private var stream: SCStream?
    private var continuation: CheckedContinuation<NSImage?, Never>?
    
    private func getActiveWindowInfo() -> (title: String, ownerName: String, windowID: CGWindowID)? {
        let windowListInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        
        if let frontWindow = windowListInfo.first(where: { info in
            let layer = info[kCGWindowLayer as String] as? Int32 ?? 0
            let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
            return layer == 0 && ownerName != "VoiceInk" && !ownerName.contains("Dock") && !ownerName.contains("Menu Bar")
        }) {
            guard let windowID = frontWindow[kCGWindowNumber as String] as? CGWindowID,
                  let ownerName = frontWindow[kCGWindowOwnerName as String] as? String,
                  let title = frontWindow[kCGWindowName as String] as? String else {
                return nil
            }
            
            return (title: title, ownerName: ownerName, windowID: windowID)
        }
        
        return nil
    }
    
    func captureActiveWindow() async -> NSImage? {
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task {
                do {
                    let content = try await SCShareableContent.current
                    let windows = content.windows.filter {
                        guard let app = $0.owningApplication else { return false }
                        return app.applicationName != "VoiceInk" && app.applicationName != "Dock" && app.applicationName != "Window Manager"
                    }
                    
                    guard let window = windows.first else {
                        logger.notice("❌ No active window found to capture.")
                        self.continuation?.resume(returning: await self.captureFullScreen())
                        self.continuation = nil
                        return
                    }
                    
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let config = SCStreamConfiguration()
                    config.width = Int(window.frame.width)
                    config.height = Int(window.frame.height)
                    config.showsCursor = false
                    
                    stream = SCStream(filter: filter, configuration: config, delegate: self)
                    try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                    stream?.startCapture(completionHandler: { error in
                        if let error = error {
                            self.logger.error("❌ Capture start error: \(error.localizedDescription)")
                            self.continuation?.resume(returning: nil)
                            self.continuation = nil
                        }
                    })
                } catch {
                    self.logger.error("❌ Error getting shareable content: \(error.localizedDescription)")
                    self.continuation?.resume(returning: nil)
                    self.continuation = nil
                }
            }
        }
    }
    
    private func captureFullScreen() async -> NSImage? {
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task {
                do {
                    let content = try await SCShareableContent.current
                    guard let display = content.displays.first else {
                        logger.notice("❌ No display found to capture.")
                        self.continuation?.resume(returning: nil)
                        self.continuation = nil
                        return
                    }
                    
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let config = SCStreamConfiguration()
                    config.width = display.width
                    config.height = display.height
                    
                    stream = SCStream(filter: filter, configuration: config, delegate: self)
                    try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                    stream?.startCapture(completionHandler: { error in
                        if let error = error {
                            self.logger.error("❌ Full screen capture start error: \(error.localizedDescription)")
                            self.continuation?.resume(returning: nil)
                            self.continuation = nil
                        }
                    })
                } catch {
                    self.logger.error("❌ Error getting shareable content for full screen: \(error.localizedDescription)")
                    self.continuation?.resume(returning: nil)
                    self.continuation = nil
                }
            }
        }
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        stream.stopCapture()
        
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }
        
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        continuation?.resume(returning: image)
        continuation = nil
    }
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("❌ Stream stopped with error: \(error.localizedDescription)")
        if continuation != nil {
            continuation?.resume(returning: nil)
            continuation = nil
        }
    }
    
    func extractText(from image: NSImage, completion: @escaping (String?) -> Void) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            logger.notice("❌ Failed to convert NSImage to CGImage for text extraction")
            completion(nil)
            return
        }
        
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest { request, error in
            if let error = error {
                self.logger.notice("❌ Text recognition error: \(error.localizedDescription, privacy: .public)")
                completion(nil)
                return
            }
            
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                self.logger.notice("❌ No text observations found")
                completion(nil)
                return
            }
            
            let text = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }.joined(separator: "\n")
            
            if text.isEmpty {
                self.logger.notice("⚠️ Text extraction returned empty result")
                completion(nil)
            } else {
                self.logger.notice("✅ Text extraction successful, found \(text.count, privacy: .public) characters")
                completion(text)
            }
        }
        
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        
        do {
            try requestHandler.perform([request])
        } catch {
            logger.notice("❌ Failed to perform text recognition: \(error.localizedDescription, privacy: .public)")
            completion(nil)
        }
    }
    
    func captureAndExtractText() async -> String? {
        guard !isCapturing else {
            logger.notice("⚠️ Screen capture already in progress, skipping")
            return nil
        }
        
        isCapturing = true
        defer {
            DispatchQueue.main.async {
                self.isCapturing = false
            }
        }
        
        logger.notice("🎬 Starting screen capture")
        
        guard let windowInfo = getActiveWindowInfo() else {
            logger.notice("❌ Failed to get window info")
            return nil
        }
        
        logger.notice("🎯 Found window: \(windowInfo.title, privacy: .public) (\(windowInfo.ownerName, privacy: .public))")
        
        var contextText = """
        Active Window: \(windowInfo.title)
        Application: \(windowInfo.ownerName)
        
        """
        
        if let capturedImage = await captureActiveWindow() {
            let extractedText = await withCheckedContinuation({ continuation in
                extractText(from: capturedImage) { text in
                    continuation.resume(returning: text)
                }
            })
            
            if let extractedText = extractedText {
                contextText += "Window Content:\n\(extractedText)"
                logger.notice("✅ Captured text successfully")
                
                await MainActor.run {
                    self.lastCapturedText = contextText
                }
                
                return contextText
            }
        }
        
        logger.notice("❌ Capture attempt failed")
        return nil
    }
}