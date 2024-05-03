package org.songsterq.pdfthumbnail

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.WritableNativeArray
import com.facebook.react.bridge.WritableNativeMap
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.Random

import com.shockwave.pdfium.PdfiumCore;
import com.shockwave.pdfium.PdfDocument;

class PdfThumbnailModule(reactContext: ReactApplicationContext) :
  ReactContextBaseJavaModule(reactContext) {

  val pdfiumCore = PdfiumCore(reactContext)
  val subFolderName = "imagesSign"

  override fun getName(): String {
    return NAME
  }

  @ReactMethod
  fun deleteGeneratedFolder(): Boolean {
    val cacheDir = File(reactApplicationContext.cacheDir, subFolderName)
    if (cacheDir.exists()) {
      cacheDir.deleteRecursively();
      return true;
    }
    return true;
  }

  @ReactMethod
  fun getTotalPage(filePath: String, promise: Promise) {
    var parcelFileDescriptor: ParcelFileDescriptor? = null
    var pdfDocument: PdfDocument? = null;
    try {
      parcelFileDescriptor = getParcelFileDescriptor(filePath)
      if (parcelFileDescriptor == null) {
        promise.reject("FILE_NOT_FOUND", "File $filePath not found")
        return
      }

      // Create a sub-folder before generate image.
      val subFolder = File(reactApplicationContext.cacheDir, subFolderName)
      if (!subFolder.exists()) {
          subFolder.mkdirs()
      }

      pdfDocument = pdfiumCore.newDocument(parcelFileDescriptor)
      val pageCount = pdfiumCore.getPageCount(pdfDocument);

      promise.resolve(pageCount);
    } catch (ex: IOException) {
      promise.reject("INTERNAL_ERROR", ex)
    } finally {
      parcelFileDescriptor?.close()
    }
  }
  
  @ReactMethod
  fun generate(filePath: String, page: Int, quality: Int, promise: Promise) {
    var parcelFileDescriptor: ParcelFileDescriptor? = null
    var pdfDocument: PdfDocument? = null;
    try {
      parcelFileDescriptor = getParcelFileDescriptor(filePath)
      if (parcelFileDescriptor == null) {
        promise.reject("FILE_NOT_FOUND", "File $filePath not found")
        return
      }

      pdfDocument = pdfiumCore.newDocument(parcelFileDescriptor)
      val pageCount = pdfiumCore.getPageCount(pdfDocument);

      if (page < 0 || page >= pageCount) {
        promise.reject("INVALID_PAGE", "Page number $page is invalid, file has $pageCount pages")
        return
      }

      val result = renderPage(page, filePath, quality, pdfDocument)
      // important!
      pdfiumCore.closeDocument(pdfDocument);
      promise.resolve(result)
    } catch (ex: IOException) {
      promise.reject("INTERNAL_ERROR", ex)
    } finally {
      parcelFileDescriptor?.close()
    }
  }

  @ReactMethod
  fun generateAllPages(filePath: String, quality: Int, promise: Promise) {
    var parcelFileDescriptor: ParcelFileDescriptor? = null
    var pdfDocument: PdfDocument? = null;
    try {
      parcelFileDescriptor = getParcelFileDescriptor(filePath)
      if (parcelFileDescriptor == null) {
        promise.reject("FILE_NOT_FOUND", "File $filePath not found")
        return
      }

      pdfDocument = pdfiumCore.newDocument(parcelFileDescriptor)
      val pageCount = pdfiumCore.getPageCount(pdfDocument);

      val result = WritableNativeArray()
      for (page in 0 until pageCount) {
        result.pushMap(renderPage(page, filePath, quality, pdfDocument))
      }
      // important!
      pdfiumCore.closeDocument(pdfDocument);
      promise.resolve(result)
    } catch (ex: IOException) {
      promise.reject("INTERNAL_ERROR", ex)
    } finally {
      parcelFileDescriptor?.close()
    }
  }

  private fun getParcelFileDescriptor(filePath: String): ParcelFileDescriptor? {
    val uri = Uri.parse(filePath)
    if (ContentResolver.SCHEME_CONTENT == uri.scheme || ContentResolver.SCHEME_FILE == uri.scheme) {
      return this.reactApplicationContext.contentResolver.openFileDescriptor(uri, "r")
    } else if (filePath.startsWith("/")) {
      val file = File(filePath)
      return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }
    return null
  }

  private fun renderPage(page: Int, filePath: String, quality: Int, pdfDocument: PdfDocument): WritableNativeMap {
    pdfiumCore.openPage(pdfDocument, page);
    val width = pdfiumCore.getPageWidthPoint(pdfDocument, page) * 2;
    val height = pdfiumCore.getPageHeightPoint(pdfDocument, page) * 2;

    /**
     * ARGB_8888 - best quality, high memory usage, higher possibility of OutOfMemoryError
     * RGB_565 - little worse quality, twice less memory usage
     */
    val bitmapWhiteBG = Bitmap.createBitmap(width, height, Bitmap.Config.RGB_565)
    pdfiumCore.renderPageBitmap(pdfDocument, bitmapWhiteBG, page, 0, 0, width, height, true)

    val outputFile = File.createTempFile(getOutputFilePrefix(filePath, page), ".png", reactApplicationContext.cacheDir)
    if (outputFile.exists()) {
      outputFile.delete()
    }
    val out = FileOutputStream(outputFile)
    bitmapWhiteBG.compress(Bitmap.CompressFormat.JPEG, 100, out)
    bitmapWhiteBG.recycle()
    out.flush()
    out.close()

    val map = WritableNativeMap()
    map.putString("uri", Uri.fromFile(outputFile).toString())
    map.putInt("width", width)
    map.putInt("height", height)
    return map
  }

  private fun getOutputFilePrefix(filePath: String, page: Int): String {
    val tokens = filePath.split("/")
    val originalFilename = tokens[tokens.lastIndex]
    val prefix = originalFilename.replace(".", "-")
    val generator = Random()
    val random = generator.nextInt(Integer.MAX_VALUE)
    return "$prefix-thumbnail-$page-$random"
  }

  companion object {
    const val NAME = "PdfThumbnail"
  }
}
