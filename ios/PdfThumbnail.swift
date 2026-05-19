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

    func generatePage(pdfPage: PDFPage, filePath: String, page: Int, quality: Int) -> Dictionary<String, Any>? {
        autoreleasepool {
            let pageRect = pdfPage.bounds(for: .mediaBox)
            let scale: CGFloat = 2.0
            let imageSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

            // On iOS 26 every PDFKit rendering API
            // (thumbnail/draw/PDFView.layer.render) lost the ability to
            // composite signature widget annotations. Bypass PDFKit and use
            // QLThumbnailGenerator, which runs the system QuickLook PDF
            // renderer (same one as Files.app) and respects signed widgets.
            // QL only thumbnails the first page of a PDF, so we extract the
            // requested page into a single-page temp PDF first.
            guard let pageCopy = pdfPage.copy() as? PDFPage else { return nil }
            let singleDoc = PDFDocument()
            singleDoc.insert(pageCopy, at: 0)
            let tempUrl = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdf-thumb-\(UUID().uuidString).pdf")
            guard singleDoc.write(to: tempUrl) else { return nil }
            defer { try? FileManager.default.removeItem(at: tempUrl) }

            let request = QLThumbnailGenerator.Request(
                fileAt: tempUrl,
                size: imageSize,
                scale: 1.0,
                representationTypes: .thumbnail
            )
            request.iconMode = false

            var resultImage: UIImage?
            let semaphore = DispatchSemaphore(value: 0)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                resultImage = rep?.uiImage
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 10.0)

            let outputFile = getCachesDirectory().appendingPathComponent(getOutputFilename(filePath: filePath, page: page))
            guard let finalImage = resultImage,
                  let data = finalImage.jpegData(compressionQuality: CGFloat(quality) / 100) else {
                return nil
            }

            let width: Int;
            let height: Int;

            if (pdfPage.rotation % 180 == 90) {
                width = Int(pageRect.height);
                height = Int(pageRect.width);
            } else {
                width = Int(pageRect.width);
                height = Int(pageRect.height);
            }

            do {
                try data.write(to: outputFile)
                return [
                    "uri": outputFile.absoluteString,
                    "width": width,
                    "height": height,
                ]
            } catch {
                return [
                    "error": error
                ]
                // return nil
            }
        }
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

            let pageResult = generatePage(pdfPage: pdfPage, filePath: filePath, page: page, quality: quality);
            let isErrorExists = pageResult?["error"] != nil;
            
            if (pageResult != nil) {
                if (isErrorExists) {
                    reject("INTERNAL_ERROR", "Cannot write image data: \(String(describing: pageResult?["error"]))", nil);
                    return;
                } else {
                    resolve(pageResult)
                }
            }
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

        autoreleasepool {
            var result: [Dictionary<String, Any>] = []
            for page in 0..<pdfDocument.pageCount {
                autoreleasepool {
                    guard let pdfPage = pdfDocument.page(at: page) else {
                        reject("INVALID_PAGE", "Page number \(page) is invalid, file has \(pdfDocument.pageCount) pages", nil)
                        return
                    }

                    let res = generatePage(pdfPage: pdfPage, filePath: filePath, page: page, quality: quality)
                    
                    if ((res) != nil) {
                        let isErrorExists = res?["error"] != nil;
                        
                        if (isErrorExists) {
                            reject("INTERNAL_ERROR", "Cannot write image data: \(String(describing: res?["error"]))", nil);
                            return;
                        } else {
                            result.append(res!);
                        }
                    }

                    // if let pageResult = generatePage(pdfPage: pdfPage, filePath: filePath, page: page, quality: quality) {
                    //     result.append(pageResult)
                    // } else {
                    //     reject("INTERNAL_ERROR", "Cannot write image data", nil)
                    //     return
                    // }
                }
            }
            resolve(result)
        }
    }
}
