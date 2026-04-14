// tesseract_bridge.js — Improved Tesseract.js OCR bridge
// Communication: Flutter sends via window.postMessage({type:'tesseract_scan'})
// and listens for window.postMessage({type:'tesseract_result'}).
// Using postMessage (NOT CustomEvent) because Flutter web runs in a
// shadow DOM canvas and CustomEvent dispatches don't cross that boundary.
//
// Improvements over original:
// - Persistent worker pool (reuse workers, don't create/destroy each scan)
// - Multiple PSM modes for better plate coverage
// - Multiple contrast/threshold variants
// - Ready signal so Flutter knows when OCR is available
// - Proper cleanup of old listeners

var _tesseractWorker  = null;
var _tesseractReady   = false;
var _tesseractLoading = false;

// ── Initialize persistent Tesseract worker ────────────────────────
async function _initTesseractWorker() {
  if (_tesseractReady && _tesseractWorker) return true;
  if (_tesseractLoading) return false;
  _tesseractLoading = true;

  try {
    if (typeof Tesseract === 'undefined') {
      console.error('[TessBridge] Tesseract.js not loaded from CDN');
      _tesseractLoading = false;
      return false;
    }

    console.log('[TessBridge] Creating persistent worker...');
    _tesseractWorker = await Tesseract.createWorker('eng', Tesseract.OEM.LSTM_ONLY, {
      logger: function() {},
    });

    // Configure worker for plate recognition
    await _tesseractWorker.setParameters({
      tessedit_char_whitelist: 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789',
      preserve_interword_spaces: '0',
    });

    _tesseractReady   = true;
    _tesseractLoading = false;
    console.log('[TessBridge] Worker ready');

    // Signal Flutter that OCR is available
    window.postMessage({ type: 'tesseract_ready' }, '*');
    return true;
  } catch (e) {
    console.error('[TessBridge] Worker init failed:', e);
    _tesseractLoading = false;
    return false;
  }
}

// ── Image preprocessing — generate multiple variants ──────────────
function _prepareVariants(imageUrl) {
  return new Promise(function(resolve) {
    var img = new Image();
    img.onload = function() {
      // Scale up small images for better OCR accuracy
      var scale = Math.max(1, Math.min(4, 180 / img.height));
      if (img.width * scale > 1600) scale = 1600 / img.width;
      var w = Math.round(img.width * scale);
      var h = Math.round(img.height * scale);

      var cv = document.createElement('canvas');
      cv.width = w; cv.height = h;
      var cx = cv.getContext('2d');
      cx.drawImage(img, 0, 0, w, h);
      var raw = cx.getImageData(0, 0, w, h).data;

      function grey(data) {
        var o = new Uint8ClampedArray(data.length);
        for (var i = 0; i < data.length; i += 4) {
          var g = 0.299 * data[i] + 0.587 * data[i+1] + 0.114 * data[i+2];
          o[i] = o[i+1] = o[i+2] = g; o[i+3] = 255;
        }
        return o;
      }
      function contrast(d, f) {
        var o = new Uint8ClampedArray(d.length), ic = 128 * (1 - f);
        for (var i = 0; i < d.length; i += 4) {
          var v = Math.max(0, Math.min(255, f * d[i] + ic));
          o[i] = o[i+1] = o[i+2] = v; o[i+3] = 255;
        }
        return o;
      }
      function threshold(d, t) {
        var o = new Uint8ClampedArray(d.length);
        for (var i = 0; i < d.length; i += 4) {
          var v = d[i] > t ? 255 : 0;
          o[i] = o[i+1] = o[i+2] = v; o[i+3] = 255;
        }
        return o;
      }
      function invert(d) {
        var o = new Uint8ClampedArray(d.length);
        for (var i = 0; i < d.length; i += 4) {
          o[i] = o[i+1] = o[i+2] = 255 - d[i]; o[i+3] = 255;
        }
        return o;
      }
      function toUrl(pixels) {
        var c2 = document.createElement('canvas');
        c2.width = w; c2.height = h;
        var x2 = c2.getContext('2d');
        var id = x2.createImageData(w, h);
        id.data.set(pixels); x2.putImageData(id, 0, 0);
        return c2.toDataURL('image/png');
      }

      var g = grey(raw);
      resolve([
        toUrl(contrast(g, 2.0)),            // v1: high contrast grayscale
        toUrl(contrast(invert(g), 2.0)),    // v2: inverted (dark bg plates)
        toUrl(threshold(contrast(g, 1.5), 140)), // v3: binary threshold 140
        toUrl(threshold(contrast(g, 1.8), 120)), // v4: binary threshold 120
      ]);
    };
    img.onerror = function() { resolve([imageUrl]); };
    img.src = imageUrl;
  });
}

// ── Extract words from Tesseract result ───────────────────────────
function _extractWords(data) {
  var out = [];
  (data && data.words || []).forEach(function(w) {
    var t = (w.text || '').replace(/\s+/g, '').replace(/[^A-Z0-9]/gi, '').toUpperCase();
    if (t.length >= 2) out.push({
      text: t,
      confidence: w.confidence || 0,
      x0: w.bbox ? w.bbox.x0 : 0,
      y0: w.bbox ? w.bbox.y0 : 0,
      x1: w.bbox ? w.bbox.x1 : 0,
      y1: w.bbox ? w.bbox.y1 : 0,
    });
  });
  return out;
}

// ── Run OCR with persistent worker ────────────────────────────────
async function _runOCR(url, psm) {
  if (!_tesseractWorker) return [];
  try {
    await _tesseractWorker.setParameters({
      tessedit_pageseg_mode: psm,
    });
    var r = await _tesseractWorker.recognize(url);
    return _extractWords(r.data);
  } catch (e) {
    console.error('[TessBridge] OCR error:', e);
    return [];
  }
}

// ── Main scan processing ──────────────────────────────────────────
async function _processScan(imageUrl, requestId) {
  try {
    var variants = await _prepareVariants(imageUrl);
    var allWords = [];
    var seen = {};

    // Run multiple PSM modes on each variant
    // PSM 7 = Single line, PSM 8 = Single word, PSM 6 = Single block
    var psmModes = [
      Tesseract.PSM.SINGLE_LINE,
      Tesseract.PSM.SINGLE_WORD,
      Tesseract.PSM.SINGLE_BLOCK,
    ];

    for (var vi = 0; vi < variants.length; vi++) {
      for (var pi = 0; pi < psmModes.length; pi++) {
        var words = await _runOCR(variants[vi], psmModes[pi]);
        for (var wi = 0; wi < words.length; wi++) {
          var w = words[wi];
          if (!seen[w.text]) {
            seen[w.text] = true;
            allWords.push(w);
          } else {
            // Keep the higher-confidence version
            for (var ei = 0; ei < allWords.length; ei++) {
              if (allWords[ei].text === w.text && w.confidence > allWords[ei].confidence) {
                allWords[ei] = w;
                break;
              }
            }
          }
        }
      }
    }

    // Sort by element height (largest text = most likely plate)
    allWords.sort(function(a, b) {
      return (b.y1 - b.y0) - (a.y1 - a.y0);
    });

    console.log('[TessBridge] Result: ' + allWords.length + ' words for request ' + requestId);
    window.postMessage({
      type: 'tesseract_result',
      requestId: requestId,
      words: allWords,
    }, '*');
  } catch (err) {
    console.error('[TessBridge] Scan error:', err);
    window.postMessage({
      type: 'tesseract_result',
      requestId: requestId,
      error: 'OCR error: ' + (err.message || String(err)),
      words: [],
    }, '*');
  }
}

// ── Listen via postMessage (works across Flutter shadow DOM) ──────
window.addEventListener('message', function(e) {
  if (!e.data || e.data.type !== 'tesseract_scan') return;
  var imageUrl  = e.data.imageUrl;
  var requestId = e.data.requestId || '';

  if (_tesseractReady) {
    _processScan(imageUrl, requestId);
  } else {
    _initTesseractWorker().then(function(ok) {
      if (ok) _processScan(imageUrl, requestId);
      else window.postMessage({
        type: 'tesseract_result',
        requestId: requestId,
        error: 'Tesseract.js failed to initialize',
        words: [],
      }, '*');
    });
  }
});

// ── Pre-warm worker on page load ──────────────────────────────────
window.addEventListener('load', function() {
  setTimeout(function() {
    _initTesseractWorker().catch(function() {});
  }, 500);
});