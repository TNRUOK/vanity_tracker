// In-browser receipt OCR for Vanity Tracker (Flutter web).
// Uses a self-hosted copy of Tesseract.js 6.0.1 (web/tesseract/). Images never leave
// the browser and no CDN is contacted at runtime.
(function () {
  'use strict';

  var base = new URL('tesseract/', document.baseURI).href;
  var workerPromise = null;
  var RECOGNIZE_TIMEOUT_MS = 120000;

  function getWorker() {
    if (workerPromise) return workerPromise;
    if (typeof Tesseract === 'undefined') {
      return Promise.reject(new Error('OCR engine failed to load (tesseract/tesseract.min.js is missing).'));
    }
    workerPromise = Tesseract.createWorker('eng', Tesseract.OEM.LSTM_ONLY, {
      workerPath: base + 'worker.min.js',
      corePath: base + 'core',
      langPath: base + 'lang',
      workerBlobURL: false,
      gzip: true,
      cacheMethod: 'none',
    }).then(function (worker) {
      // Receipts are mostly single-column blocks of text.
      return worker.setParameters({ tessedit_pageseg_mode: '6', preserve_interword_spaces: '1' })
        .then(function () { return worker; });
    }).catch(function (err) {
      workerPromise = null; // allow a retry after a failed initialisation
      throw new Error('OCR engine could not start: ' + (err && err.message ? err.message : err));
    });
    return workerPromise;
  }

  function withTimeout(promise, ms) {
    return new Promise(function (resolve, reject) {
      var t = setTimeout(function () { reject(new Error('OCR timed out after ' + ms / 1000 + ' seconds.')); }, ms);
      promise.then(function (v) { clearTimeout(t); resolve(v); }, function (e) { clearTimeout(t); reject(e); });
    });
  }

  /**
   * Recognises text in an image.
   * @param {Uint8Array} bytes raw image file bytes
   * @param {string} mimeType e.g. image/jpeg
   * @returns {Promise<string>} recognised text ('' when no text was found)
   */
  window.recognizeReceiptWeb = function (bytes, mimeType) {
    if (!bytes || !bytes.length) {
      return Promise.reject(new Error('No image data was provided.'));
    }
    var blob = new Blob([bytes], { type: mimeType || 'image/jpeg' });
    return getWorker().then(function (worker) {
      return withTimeout(worker.recognize(blob), RECOGNIZE_TIMEOUT_MS);
    }).then(function (result) {
      var text = result && result.data && typeof result.data.text === 'string' ? result.data.text : null;
      if (text === null) throw new Error('OCR returned an unexpected response.');
      return text;
    }, function (err) {
      var msg = err && err.message ? err.message : String(err);
      if (/decode|image|bitmap/i.test(msg) && !/OCR engine/.test(msg)) {
        msg = 'The selected file could not be read as an image (' + msg + ').';
      }
      console.error('Receipt OCR error:', err);
      throw new Error(msg);
    });
  };

  /** Lets Dart check the engine is present before showing the scanner as available. */
  window.receiptOcrAvailable = function () {
    return typeof Tesseract !== 'undefined';
  };
})();
