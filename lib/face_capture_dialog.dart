import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Mode popup kamera wajah.
enum FaceCaptureMode {
  /// Memotret wajah untuk absensi (dibandingkan dengan descriptor terdaftar).
  absen,

  /// Mendaftarkan wajah baru (menyimpan descriptor + foto).
  register,
}

/// Hasil pengambilan foto wajah dari popup.
class FaceCaptureResult {
  const FaceCaptureResult({
    required this.photoBase64,
    required this.statusWajah,
    this.descriptor,
    this.distance,
  });

  /// Foto dalam format base64 (tanpa prefix `data:image/...;base64,`).
  final String photoBase64;

  /// Status hasil pengecekan wajah, mengikuti nilai pada web referensi:
  /// `Sesuai (Sama)`, `Dicurigai (Tidak Sama)`, `Wajah Tidak Terdeteksi`,
  /// atau `Terdaftar` untuk pendaftaran wajah.
  final String statusWajah;

  /// Descriptor 128 dimensi (hanya diisi pada mode [FaceCaptureMode.register]).
  final List<double>? descriptor;

  /// Jarak euclidean terhadap descriptor terdaftar (mode absen).
  final double? distance;

  /// Descriptor dalam bentuk JSON string, siap disimpan ke kolom
  /// `users.face_descriptor` (format sama dengan web referensi).
  String? get descriptorJson {
    final value = descriptor;
    if (value == null || value.isEmpty) return null;
    return jsonEncode(value);
  }

  /// Foto dalam bentuk data URL, siap disimpan ke kolom `users.foto_wajah`.
  String get photoDataUrl => 'data:image/jpeg;base64,$photoBase64';
}

/// Menampilkan popup absen wajah.
///
/// Popup memakai `face-api.js` di dalam WebView agar perilakunya sama dengan
/// halaman absen web (`web-references-zabsen/index.html` + `face.js`):
/// - kamera depan,
/// - deteksi wajah + countdown 3 detik sebelum foto otomatis diambil,
/// - descriptor 128 dimensi untuk membandingkan wajah dengan data terdaftar.
///
/// Mengembalikan `null` bila pengguna membatalkan atau kamera tidak tersedia.
Future<FaceCaptureResult?> showFaceCaptureDialog(
  BuildContext context, {
  required FaceCaptureMode mode,
  required String tipeAbsen,
  String? registeredDescriptor,
}) async {
  if (!_isMobilePlatform) {
    await _showUnsupportedDialog(context);
    return null;
  }

  final granted = await _requestCameraPermission(context);
  if (!granted || !context.mounted) return null;

  return showDialog<FaceCaptureResult>(
    context: context,
    barrierDismissible: false,
    useSafeArea: true,
    builder: (_) => FaceCaptureDialog(
      mode: mode,
      tipeAbsen: tipeAbsen,
      registeredDescriptor: registeredDescriptor,
    ),
  );
}

bool get _isMobilePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

Future<void> _showUnsupportedDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(
        children: [
          Icon(Icons.no_photography_outlined, color: Color(0xFF4A1010)),
          SizedBox(width: 8),
          Text('Kamera Tidak Tersedia', style: TextStyle(fontSize: 18)),
        ],
      ),
      content: const Text(
        'Fitur absen wajah hanya tersedia pada aplikasi mobile '
        '(Android/iOS).',
        style: TextStyle(fontSize: 14),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Tutup'),
        ),
      ],
    ),
  );
}

Future<bool> _requestCameraPermission(BuildContext context) async {
  PermissionStatus status = await Permission.camera.status;

  if (!status.isGranted) {
    status = await Permission.camera.request();
  }

  if (status.isGranted) return true;
  if (!context.mounted) return false;

  final openSettings = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(
        children: [
          Icon(Icons.camera_alt_outlined, color: Color(0xFF4A1010)),
          SizedBox(width: 8),
          Text('Izin Kamera', style: TextStyle(fontSize: 18)),
        ],
      ),
      content: const Text(
        'Akses kamera diperlukan untuk memotret wajah saat absen. '
        'Aktifkan izin kamera pada pengaturan aplikasi.',
        style: TextStyle(fontSize: 14),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Batal'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF500808),
            foregroundColor: Colors.white,
          ),
          child: const Text('Buka Pengaturan'),
        ),
      ],
    ),
  );

  if (openSettings == true) {
    await openAppSettings();
  }
  return false;
}

/// Dialog popup yang menampilkan kamera + pemindaian wajah.
class FaceCaptureDialog extends StatefulWidget {
  const FaceCaptureDialog({
    super.key,
    required this.mode,
    required this.tipeAbsen,
    this.registeredDescriptor,
  });

  final FaceCaptureMode mode;
  final String tipeAbsen;
  final String? registeredDescriptor;

  @override
  State<FaceCaptureDialog> createState() => _FaceCaptureDialogState();
}

class _FaceCaptureDialogState extends State<FaceCaptureDialog> {
  static const Color _dark = Color(0xFF120404);

  late final WebViewController _controller;
  String? _error;
  bool _isFinishing = false;

  @override
  void initState() {
    super.initState();

    _controller =
        WebViewController(
            onPermissionRequest: (request) {
              // Izin OS sudah diminta lewat permission_handler sebelum popup dibuka.
              request.grant();
            },
          )
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(_dark)
          ..setOnConsoleMessage((message) {
            debugPrint('[FaceJS] ${message.message}');
          })
          ..addJavaScriptChannel(
            'FaceBridge',
            onMessageReceived: _onJavaScriptMessage,
          );

    _controller.loadHtmlString(_buildHtml(), baseUrl: 'https://localhost/');
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);

    return Dialog(
      backgroundColor: _dark,
      insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 460,
          maxHeight: media.height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            if (_error != null)
              Container(
                width: double.infinity,
                color: const Color(0xFF7F1D1D),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(24),
                ),
                child: WebViewWidget(controller: _controller),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF3B0B0B), Color(0xFF1E0404)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              widget.mode == FaceCaptureMode.register
                  ? Icons.face_retouching_natural
                  : Icons.camera_front_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.mode == FaceCaptureMode.register
                      ? 'Pendaftaran Wajah'
                      : 'Absen Wajah',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  widget.mode == FaceCaptureMode.register
                      ? 'Daftarkan wajah Anda sekali saja'
                      : 'Kategori: ${widget.tipeAbsen}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.72),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _finish,
            icon: const Icon(Icons.close_rounded, color: Colors.white),
            tooltip: 'Tutup',
          ),
        ],
      ),
    );
  }

  void _onJavaScriptMessage(JavaScriptMessage message) {
    if (!mounted) return;

    Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is! Map) return;
      payload = Map<String, dynamic>.from(decoded);
    } catch (e) {
      debugPrint('Pesan FaceBridge tidak valid: $e');
      return;
    }

    final type = payload['type']?.toString();

    if (type == 'close') {
      _finish();
      return;
    }

    if (type == 'error') {
      setState(() {
        _error =
            payload['message']?.toString() ??
            'Terjadi kesalahan saat membuka kamera wajah.';
      });
      return;
    }

    if (type != 'capture') return;

    final photo = payload['photoBase64']?.toString();
    if (photo == null || photo.isEmpty) {
      setState(() => _error = 'Foto wajah tidak berhasil diambil.');
      return;
    }

    final descriptorRaw = payload['descriptor'];
    final List<double>? descriptor = descriptorRaw is List
        ? descriptorRaw
              .whereType<num>()
              .map((value) => value.toDouble())
              .toList()
        : null;

    final distanceRaw = payload['distance'];
    final result = FaceCaptureResult(
      photoBase64: photo,
      statusWajah:
          payload['statusWajah']?.toString() ?? 'Wajah Tidak Terdeteksi',
      descriptor: descriptor,
      distance: distanceRaw is num ? distanceRaw.toDouble() : null,
    );

    _finish(result);
  }

  Future<void> _finish([FaceCaptureResult? result]) async {
    if (_isFinishing) return;
    _isFinishing = true;

    try {
      await _controller.runJavaScript('window.faceStop && window.faceStop();');
    } catch (_) {
      // WebView mungkin sudah tidak aktif; abaikan.
    }

    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  String _buildHtml() {
    final descriptor = _parseDescriptor(widget.registeredDescriptor);
    final descriptorLiteral = jsonEncode(descriptor);
    final modeLiteral = jsonEncode(widget.mode.name);
    final tipeLiteral = jsonEncode(widget.tipeAbsen);

    return _faceHtmlTemplate
        .replaceAll('__MODE__', modeLiteral)
        .replaceAll('__TIPELABEL__', tipeLiteral)
        .replaceAll('__DESCRIPTOR__', descriptorLiteral);
  }

  List<double>? _parseDescriptor(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final values = decoded
            .whereType<num>()
            .map((value) => value.toDouble())
            .toList();
        return values.isEmpty ? null : values;
      }
    } catch (e) {
      debugPrint('Descriptor wajah tidak valid: $e');
    }
    return null;
  }
}

/// Template halaman kamera. Memakai `face-api.js` + model yang sama dengan
/// web referensi (`web-references-zabsen/face.js`).
const String _faceHtmlTemplate = r'''
<!DOCTYPE html>
<html lang="id">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
  <title>Absen Wajah</title>
  <style>
    :root { color-scheme: dark; }
    * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
    html, body {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      overflow: hidden;
      background: #120404;
      color: #fff;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    }
    #app { display: flex; flex-direction: column; height: 100%; }
    #camera-wrap {
      position: relative;
      flex: 1;
      min-height: 0;
      background: #000;
      overflow: hidden;
    }
    #video, #preview {
      position: absolute;
      inset: 0;
      width: 100%;
      height: 100%;
      object-fit: cover;
      display: block;
      transform: scaleX(-1);
    }
    #preview { display: none; }
    #overlay {
      position: absolute;
      inset: 0;
      display: flex;
      align-items: center;
      justify-content: center;
      pointer-events: none;
    }
    #face-frame {
      width: 58%;
      max-width: 235px;
      aspect-ratio: 3 / 4;
      border: 2px dashed rgba(255, 255, 255, 0.8);
      border-radius: 46% 46% 42% 42%;
      box-shadow: 0 0 0 9999px rgba(0, 0, 0, 0.3);
      transition: border-color 0.2s ease, border-style 0.2s ease;
    }
    #face-frame.ok {
      border-style: solid;
      border-color: #4ade80;
    }
    #countdown {
      position: absolute;
      inset: 0;
      display: none;
      align-items: center;
      justify-content: center;
      font-size: 92px;
      font-weight: 900;
      color: #fff;
      text-shadow: 0 8px 28px rgba(0, 0, 0, 0.7);
      pointer-events: none;
    }
    #status {
      position: absolute;
      left: 12px;
      right: 12px;
      bottom: 12px;
      padding: 10px 14px;
      border-radius: 999px;
      font-size: 12px;
      line-height: 1.35;
      font-weight: 700;
      text-align: center;
      background: rgba(0, 0, 0, 0.62);
      backdrop-filter: blur(8px);
    }
    #status.ok { background: rgba(22, 101, 52, 0.94); }
    #status.warn { background: rgba(146, 64, 14, 0.94); }
    #status.err { background: rgba(127, 29, 29, 0.96); }
    #footer {
      display: flex;
      gap: 10px;
      padding: 12px 14px calc(12px + env(safe-area-inset-bottom));
      background: #120404;
    }
    button {
      flex: 1;
      border: 0;
      border-radius: 14px;
      padding: 14px 12px;
      font-size: 13px;
      font-weight: 800;
      font-family: inherit;
      cursor: pointer;
    }
    #btn-cancel { background: #2a1414; color: #f2dada; }
    #btn-action {
      background: linear-gradient(180deg, #6d1414, #3b0b0b);
      color: #fff;
    }
    #btn-action:disabled { opacity: 0.45; }
    #btn-cancel:disabled { opacity: 0.5; }
  </style>
</head>
<body>
  <div id="app">
    <div id="camera-wrap">
      <video id="video" autoplay playsinline muted></video>
      <img id="preview" alt="Hasil foto wajah">
      <div id="overlay"><div id="face-frame"></div></div>
      <div id="countdown">3</div>
      <div id="status">Memuat kamera...</div>
    </div>
    <div id="footer">
      <button id="btn-cancel" type="button">Batal</button>
      <button id="btn-action" type="button" disabled>Menyiapkan...</button>
    </div>
  </div>
  <canvas id="canvas" style="display:none"></canvas>

  <script src="https://cdn.jsdelivr.net/npm/@vladmandic/face-api/dist/face-api.js"></script>
  <script>
    const MODE = __MODE__;
    const TIPE_LABEL = __TIPELABEL__;
    const REGISTERED_DESCRIPTOR = __DESCRIPTOR__;

    const MODEL_URLS = [
      'https://cdn.jsdelivr.net/gh/justadudewhohacks/face-api.js@master/weights',
      'https://raw.githubusercontent.com/justadudewhohacks/face-api.js/master/weights'
    ];

    const video = document.getElementById('video');
    const preview = document.getElementById('preview');
    const statusEl = document.getElementById('status');
    const actionBtn = document.getElementById('btn-action');
    const cancelBtn = document.getElementById('btn-cancel');
    const frameEl = document.getElementById('face-frame');
    const countdownEl = document.getElementById('countdown');
    const canvas = document.getElementById('canvas');

    let stream = null;
    let modelsLoaded = false;
    let modelsLoading = false;
    let sending = false;
    let stopped = false;
    let facePresent = false;
    let countdownTimer = null;
    let countdownValue = 3;
    let registeredDescriptor = null;

    try {
      if (Array.isArray(REGISTERED_DESCRIPTOR) && REGISTERED_DESCRIPTOR.length > 0) {
        registeredDescriptor = new Float32Array(REGISTERED_DESCRIPTOR);
      }
    } catch (e) {
      console.warn('Descriptor wajah tidak dapat dibaca:', e);
    }

    function post(payload) {
      try {
        FaceBridge.postMessage(JSON.stringify(payload));
      } catch (e) {
        console.error('Gagal mengirim pesan ke aplikasi:', e);
      }
    }

    function setStatus(text, kind) {
      statusEl.textContent = text;
      statusEl.className = kind || '';
    }

    function setAction(text) {
      actionBtn.textContent = text;
    }

    function resetCountdown() {
      if (countdownTimer) {
        clearInterval(countdownTimer);
        countdownTimer = null;
      }
      countdownValue = 3;
      countdownEl.style.display = 'none';
      countdownEl.textContent = '3';
    }

    function stopCamera() {
      stopped = true;
      resetCountdown();
      if (stream) {
        stream.getTracks().forEach(function (track) {
          try { track.stop(); } catch (e) {}
        });
        stream = null;
      }
      try { video.pause(); } catch (e) {}
      try { video.srcObject = null; } catch (e) {}
    }

    window.faceStop = stopCamera;

    window.faceReset = function (message) {
      sending = false;
      stopped = false;
      preview.style.display = 'none';
      video.style.display = 'block';
      actionBtn.disabled = true;
      setAction(MODE === 'register' ? 'Simpan Data Wajah' : 'Ambil Foto');
      setStatus(message || 'Silakan coba lagi.', 'warn');
      startDetection();
    };

    function goBack() {
      stopCamera();
      post({ type: 'close' });
    }

    async function loadModels() {
      if (modelsLoaded) return true;
      if (modelsLoading) return false;
      modelsLoading = true;
      setStatus('Memuat model pendeteksi wajah...', 'warn');

      for (let i = 0; i < MODEL_URLS.length; i++) {
        const base = MODEL_URLS[i];
        try {
          await Promise.all([
            faceapi.nets.tinyFaceDetector.loadFromUri(base),
            faceapi.nets.faceLandmark68Net.loadFromUri(base),
            faceapi.nets.faceRecognitionNet.loadFromUri(base)
          ]);
          modelsLoaded = true;
          modelsLoading = false;
          return true;
        } catch (e) {
          console.warn('Gagal memuat model dari ' + base, e);
        }
      }

      modelsLoading = false;
      return false;
    }

    async function startCamera() {
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        setStatus('Kamera tidak didukung pada perangkat ini.', 'err');
        post({
          type: 'error',
          message: 'Kamera tidak didukung pada perangkat ini. Gunakan aplikasi mobile Android/iOS.'
        });
        return;
      }

      try {
        try {
          stream = await navigator.mediaDevices.getUserMedia({
            audio: false,
            video: {
              facingMode: 'user',
              width: { ideal: 720 },
              height: { ideal: 960 }
            }
          });
        } catch (e) {
          stream = await navigator.mediaDevices.getUserMedia({
            audio: false,
            video: true
          });
        }

        video.srcObject = stream;
        await video.play().catch(function (e) {
          console.warn('Video play warning:', e);
        });
      } catch (e) {
        const message = e && e.message ? e.message : 'Izin kamera ditolak.';
        setStatus('Kamera gagal diakses: ' + message, 'err');
        post({ type: 'error', message: 'Kamera gagal diakses: ' + message });
        return;
      }

      const loaded = await loadModels();
      if (!loaded) {
        setStatus('Gagal memuat model AI. Periksa koneksi internet.', 'err');
        post({
          type: 'error',
          message: 'Gagal memuat model face-api.js. Periksa koneksi internet lalu coba lagi.'
        });
        return;
      }

      if (MODE === 'register') {
        setAction('Simpan Data Wajah');
        setStatus('Posisikan wajah di dalam bingkai.', 'warn');
      } else {
        setAction('Ambil Foto');
        setStatus('Posisikan wajah di dalam bingkai.', 'warn');
      }

      startDetection();
    }

    function startDetection() {
      stopped = false;
      detectLoop();
    }

    async function detectLoop() {
      if (stopped || sending || !stream) return;

      try {
        if (video.readyState >= 2 && video.videoWidth > 0) {
          const detection = await faceapi.detectSingleFace(
            video,
            new faceapi.TinyFaceDetectorOptions({
              inputSize: 224,
              scoreThreshold: 0.5
            })
          );

          if (detection) {
            facePresent = true;
            frameEl.classList.add('ok');
            actionBtn.disabled = false;

            if (MODE === 'absen') {
              if (!countdownTimer && !sending) {
                countdownValue = 3;
                countdownEl.textContent = String(countdownValue);
                countdownEl.style.display = 'flex';
                setStatus('Wajah terdeteksi. Tahan posisi (' + countdownValue + 's)...', 'ok');

                countdownTimer = setInterval(function () {
                  countdownValue -= 1;

                  if (countdownValue > 0) {
                    countdownEl.textContent = String(countdownValue);
                    setStatus('Wajah terdeteksi. Tahan posisi (' + countdownValue + 's)...', 'ok');
                  } else {
                    resetCountdown();
                    captureAbsen();
                  }
                }, 1000);
              }
            } else {
              setStatus('Wajah terdeteksi! Tekan "Simpan Data Wajah".', 'ok');
            }
          } else {
            facePresent = false;
            frameEl.classList.remove('ok');
            resetCountdown();

            if (!sending) {
              actionBtn.disabled = true;
              setStatus(
                MODE === 'absen'
                  ? 'Wajah tidak terdeteksi. Posisikan wajah di dalam bingkai.'
                  : 'Posisikan wajah di dalam bingkai.',
                'warn'
              );
            }
          }
        }
      } catch (e) {
        console.warn('Detection loop warning:', e);
      }

      if (!stopped && !sending) {
        setTimeout(detectLoop, 320);
      }
    }

    function drawVideoToCanvas() {
      canvas.width = video.videoWidth;
      canvas.height = video.videoHeight;
      const ctx = canvas.getContext('2d', { willReadFrequently: true });
      ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
      return canvas;
    }

    async function detectDescriptorFromCanvas() {
      return faceapi
        .detectSingleFace(canvas, new faceapi.TinyFaceDetectorOptions())
        .withFaceLandmarks()
        .withFaceDescriptor();
    }

    async function captureAbsen() {
      if (sending || !facePresent) return;

      sending = true;
      resetCountdown();
      actionBtn.disabled = true;
      cancelBtn.disabled = true;
      setAction('Memproses...');
      setStatus('Menganalisis wajah...', 'warn');

      drawVideoToCanvas();
      const photo = canvas.toDataURL('image/jpeg', 0.86);

      video.style.display = 'none';
      preview.src = photo;
      preview.style.display = 'block';

      let detection = null;
      try {
        detection = await detectDescriptorFromCanvas();
      } catch (e) {
        console.warn('Gagal menganalisis wajah:', e);
      }

      let statusWajah = 'Wajah Tidak Terdeteksi';
      let distance = null;

      if (detection) {
        if (registeredDescriptor) {
          distance = faceapi.euclideanDistance(
            registeredDescriptor,
            detection.descriptor
          );
          statusWajah = distance > 0.55
            ? 'Dicurigai (Tidak Sama)'
            : 'Sesuai (Sama)';
        } else {
          statusWajah = 'Wajah Terdeteksi';
        }
      }

      setStatus(
        statusWajah === 'Sesuai (Sama)'
          ? 'Wajah sesuai. Menyimpan absen...'
          : statusWajah,
        statusWajah === 'Sesuai (Sama)' ? 'ok' : 'warn'
      );

      post({
        type: 'capture',
        mode: 'absen',
        photoBase64: photo.split(',')[1],
        statusWajah: statusWajah,
        distance: distance
      });
    }

    async function captureRegister() {
      if (sending || !facePresent) return;

      sending = true;
      resetCountdown();
      actionBtn.disabled = true;
      cancelBtn.disabled = true;
      setAction('Memproses...');
      setStatus('Menyimpan data wajah...', 'warn');

      drawVideoToCanvas();
      const photo = canvas.toDataURL('image/jpeg', 0.86);

      video.style.display = 'none';
      preview.src = photo;
      preview.style.display = 'block';

      let detection = null;
      try {
        detection = await detectDescriptorFromCanvas();
      } catch (e) {
        console.warn('Gagal menganalisis wajah:', e);
      }

      if (!detection) {
        sending = false;
        cancelBtn.disabled = false;
        preview.style.display = 'none';
        video.style.display = 'block';
        setStatus('Wajah tidak terdeteksi. Posisikan wajah lalu coba lagi.', 'err');
        startDetection();
        return;
      }

      const descriptor = Array.from(detection.descriptor);
      setStatus('Wajah terdeteksi. Menyimpan data wajah...', 'ok');

      post({
        type: 'capture',
        mode: 'register',
        photoBase64: photo.split(',')[1],
        descriptor: descriptor,
        statusWajah: 'Terdaftar'
      });
    }

    actionBtn.addEventListener('click', function () {
      if (MODE === 'register') {
        captureRegister();
      } else {
        captureAbsen();
      }
    });

    cancelBtn.addEventListener('click', goBack);

    if (typeof faceapi === 'undefined') {
      setStatus('Gagal memuat face-api.js. Periksa koneksi internet.', 'err');
      post({
        type: 'error',
        message: 'Gagal memuat library face-api.js. Periksa koneksi internet.'
      });
    } else {
      startCamera();
    }
  </script>
</body>
</html>
''';
