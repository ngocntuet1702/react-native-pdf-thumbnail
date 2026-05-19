import PDFKit
import QuickLookThumbnailing

@objc(PdfThumbnail)
class PdfThumbnail: NSObject {

    @objc
    static func requiresMainQueueSetup() -> Bool {
        return false
    }

    func getCachesDirectory() -> URL {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        return paths[0]
    }

    func getOutputFilename(filePath: String, page: Int) -> String {
        let components = filePath.components(separatedBy: "/")
        var prefix: String
        if let origionalFileName = components.last {
            prefix = origionalFileName.replacingOccurrences(of: ".", with: "-")
        } else {
            prefix = "pdf"
        }
        let random = Int.random(in: 0 ..< Int.max)
        return "\(prefix)-thumbnail-\(page)-\(random).jpg"
    }

    // Async core. Extraction (PDF copy + temp write) runs synchronously on the
    // calling thread so callers serialize PDFKit access; the QL thumbnail step
    // and the JPEG write happen in QL's completion handler.
    private func generatePageAsync(
        pdfPage: PDFPage,
        filePath: String,
        page: Int,
        quality: Int,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        autoreleasepool {
            let pageRect = pdfPage.bounds(for: .mediaBox)
            let scale: CGFloat = 2.0
            let imageSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
            let rotation = pdfPage.rotation

            // On iOS 26 every PDFKit rendering API
            // (thumbnail/draw/PDFView.layer.render) lost the ability to
            // composite signature widget annotations. Bypass PDFKit and use
            // QLThumbnailGenerator, which runs the system QuickLook PDF
            // renderer (same one as Files.app) and respects signed widgets.
            // QL only thumbnails the first page of a PDF, so we extract the
            // requested page into a single-page temp PDF first.
            guard let pageCopy = pdfPage.copy() as? PDFPage else {
                completion(nil)
                return
            }
            let singleDoc = PDFDocument()
            singleDoc.insert(pageCopy, at: 0)
            let tempUrl = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdf-thumb-\(UUID().uuidString).pdf")
            guard singleDoc.write(to: tempUrl) else {
                completion(nil)
                return
            }

            let request = QLThumbnailGenerator.Request(
                fileAt: tempUrl,
                size: imageSize,
                scale: 1.0,
                representationTypes: .thumbnail
            )
            request.iconMode = false

            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
                autoreleasepool {
                    try? FileManager.default.removeItem(at: tempUrl)

                    guard let self = self,
                          let image = rep?.uiImage,
                          let data = image.jpegData(compressionQuality: CGFloat(quality) / 100) else {
                        completion(nil)
                        return
                    }

                    let outputFile = self.getCachesDirectory().appendingPathComponent(
                        self.getOutputFilename(filePath: filePath, page: page))

                    let width: Int
                    let height: Int
                    if rotation % 180 == 90 {
                        width = Int(pageRect.height)
                        height = Int(pageRect.width)
                    } else {
                        width = Int(pageRect.width)
                        height = Int(pageRect.height)
                    }

                    do {
                        try data.write(to: outputFile)
                        completion([
                            "uri": outputFile.absoluteString,
                            "width": width,
                            "height": height,
                        ])
                    } catch {
                        completion(["error": error])
                    }
                }
            }
        }
    }

    // Sync wrapper preserved for callers that still need it (single-page
    // `generate`). Blocks the caller via a semaphore until the async core
    // finishes.
    func generatePage(pdfPage: PDFPage, filePath: String, page: Int, quality: Int) -> Dictionary<String, Any>? {
        var result: [String: Any]?
        let semaphore = DispatchSemaphore(value: 0)
        generatePageAsync(pdfPage: pdfPage, filePath: filePath, page: page, quality: quality) { r in
            result = r
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10.0)
        return result
    }

    @available(iOS 11.0, *)
    @objc(generate:withPage:withQuality:withResolver:withRejecter:)
    func generate(filePath: String, page: Int, quality: Int, resolve:RCTPromiseResolveBlock, reject:RCTPromiseRejectBlock) -> Void {
        autoreleasepool {
            guard let fileUrl = URL(string: filePath) else {
                reject("FILE_NOT_FOUND", "File \(filePath) not found", nil)
                return
            }
            guard let pdfDocument = PDFDocument(url: fileUrl) else {
                reject("FILE_NOT_FOUND", "File \(filePath) not found", nil)
                return
            }
            guard let pdfPage = pdfDocument.page(at: page) else {
                reject("INVALID_PAGE", "Page number \(page) is invalid, file has \(pdfDocument.pageCount) pages", nil)
                return
            }

            guard let pageResult = generatePage(pdfPage: pdfPage, filePath: filePath, page: page, quality: quality) else {
                reject("INTERNAL_ERROR", "Thumbnail generation failed or timed out for page \(page)", nil)
                return
            }
            if pageResult["error"] != nil {
                reject("INTERNAL_ERROR", "Cannot write image data: \(String(describing: pageResult["error"]))", nil)
                return
            }
            resolve(pageResult)
        }
    }

    @available(iOS 11.0, *)
    @objc(generateAllPages:withQuality:withResolver:withRejecter:)
    func generateAllPages(filePath: String, quality: Int, resolve:RCTPromiseResolveBlock, reject:RCTPromiseRejectBlock) -> Void {
        guard let fileUrl = URL(string: filePath) else {
            reject("FILE_NOT_FOUND", "File \(filePath) not found", nil)
            return
        }
        guard let pdfDocument = PDFDocument(url: fileUrl) else {
            reject("FILE_NOT_FOUND", "File \(filePath) not found", nil)
            return
        }

        let pageCount = pdfDocument.pageCount
        if pageCount == 0 {
            resolve([])
            return
        }

        autoreleasepool {
            // Run page extraction + QL thumbnail concurrently. Total wait drops
            // from sum(per-page) to roughly max(per-page) within the
            // concurrency cap. PDFKit extraction stays serialized on this
            // thread (we acquire the slot before calling generatePageAsync) so
            // we don't race on PDFDocument state; QL itself is async.
            var results: [[String: Any]?] = Array(repeating: nil, count: pageCount)
            let resultsLock = NSLock()
            let group = DispatchGroup()
            let concurrencyLimit = DispatchSemaphore(value: 8)

            for page in 0..<pageCount {
                guard let pdfPage = pdfDocument.page(at: page) else { continue }

                concurrencyLimit.wait()
                group.enter()
                generatePageAsync(
                    pdfPage: pdfPage,
                    filePath: filePath,
                    page: page,
                    quality: quality
                ) { result in
                    if let r = result, r["error"] == nil {
                        resultsLock.lock()
                        results[page] = r
                        resultsLock.unlock()
                    }
                    concurrencyLimit.signal()
                    group.leave()
                }
            }

            // Cap the worst case so a stuck QL request can't deadlock the
            // bridge. 60s is far above any realistic per-document budget.
            _ = group.wait(timeout: .now() + 60.0)

            let ordered = results.compactMap { $0 }
            resolve(ordered)
        }
    }
}
