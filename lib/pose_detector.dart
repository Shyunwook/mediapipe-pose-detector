import 'dart:async';
import 'dart:js' as js;

/// MediaPipe 포즈 감지기
class PoseDetector {
  Timer? _resultTimer;
  bool _isRunning = false;
  
  bool get isRunning => _isRunning;

  /// MediaPipe 초기화
  Future<bool> initialize() async {
    try {
      // 라이브러리 로딩 대기
      await _waitForLibrary();
      
      // Vision 초기화
      js.context.callMethod('initializeMediaPipeVisionSync');
      await _waitForVision();
      
      // PoseLandmarker 로드
      final result = js.context.callMethod('loadPoseLandmarker');
      
      // JavaScript에서 Promise를 반환할 수 있으므로 다양한 방식으로 체크
      bool isSuccess = false;
      if (result == true) {
        isSuccess = true;
      } else if (result is Future) {
        final awaitedResult = await result;
        isSuccess = awaitedResult == true;
      } else {
        // PoseLandmarker 로딩 완료까지 대기 (Promise를 못받은 경우)
        for (int i = 0; i < 50; i++) { // 최대 10초 대기
          await Future.delayed(const Duration(milliseconds: 200));
          
          final loaded = js.context['poseLandmarkerLoaded'];
          final error = js.context['poseLandmarkerError'];
          
          if (loaded == true) {
            isSuccess = true;
            break;
          }
          
          if (error != null) {
            break;
          }
        }
      }
      
      return isSuccess;
      
    } catch (e) {
      return false;
    }
  }

  /// 실시간 포즈 감지 시작
  Future<bool> startRealtimeDetection() async {
    if (_isRunning) return true;

    try {
      // 카메라 시작 요청
      final startResult = js.context.callMethod('startOptimizedCameraStream');
      if (startResult != 'started') {
        return false;
      }

      // 카메라 상태 확인 (최대 10초 대기)
      bool cameraReady = false;
      for (int i = 0; i < 50; i++) { // 50 * 200ms = 10초
        await Future.delayed(const Duration(milliseconds: 200));
        
        final status = js.context.callMethod('getCameraStreamStatus');
        final success = status['success'];
        final error = status['error'];
        
        if (success == true) {
          cameraReady = true;
          break;
        }
        
        if (error != null) {
          return false;
        }
      }
      
      if (!cameraReady) {
        return false;
      }

      // 포즈 감지 시작
      final detectionResult = js.context.callMethod('startOptimizedRealtimePoseDetection');
      if (detectionResult != true) {
        return false;
      }

      _isRunning = true;
      return true;

    } catch (e) {
      return false;
    }
  }

  /// 포즈 감지 중단
  void stopRealtimeDetection() {
    if (!_isRunning) return;

    try {
      js.context.callMethod('stopOptimizedRealtimePoseDetection');
      _resultTimer?.cancel();
      _resultTimer = null;
      _isRunning = false;
    } catch (e) {
      // 에러 무시
    }
  }

  /// 포즈 결과 스트림
  Stream<PoseResult> getPoseResultsStream() {
    late StreamController<PoseResult> controller;
    
    controller = StreamController<PoseResult>(
      onListen: () {
        _resultTimer = Timer.periodic(
          const Duration(milliseconds: 16), // ~60 FPS
          (timer) {
            if (!_isRunning) {
              timer.cancel();
              return;
            }

            try {
              final result = _getCurrentResults();
              controller.add(result);
            } catch (e) {
              // 에러 무시
            }
          },
        );
      },
      onCancel: () {
        _resultTimer?.cancel();
        _resultTimer = null;
      },
    );

    return controller.stream;
  }

  /// 현재 포즈 결과 가져오기
  PoseResult getCurrentResults() => _getCurrentResults();

  /// 리소스 정리
  void dispose() {
    stopRealtimeDetection();
    try {
      js.context.callMethod('disposeMediaPipe');
    } catch (e) {
      // 에러 무시
    }
  }

  // Private methods

  Future<void> _waitForLibrary() async {
    for (int i = 0; i < 100; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      
      if (js.context['MediaPipeLibraryLoaded'] == true) {
        return;
      }
      
      if (js.context['MediaPipeLibraryError'] != null) {
        throw Exception('Library loading failed');
      }
    }
    throw Exception('Library loading timeout');
  }

  Future<void> _waitForVision() async {
    for (int i = 0; i < 100; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      
      if (js.context['visionInitialized'] == true) {
        return;
      }
      
      if (js.context['visionInitializationFailed'] == true) {
        final error = js.context['visionInitializationError'] ?? 'Unknown error';
        throw Exception('Vision initialization failed: $error');
      }
    }
    throw Exception('Vision initialization timeout');
  }

  PoseResult _getCurrentResults() {
    try {
      final jsResult = js.context.callMethod('getLatestOptimizedPoseResults');
      
      if (jsResult == null) {
        return PoseResult.empty();
      }

      // JS 객체를 Dart 객체로 변환
      final success = jsResult['success'] ?? false;
      final detected = jsResult['detected'] ?? false;
      final fps = jsResult['fps']?.toDouble() ?? 0.0;
      final timestamp = jsResult['timestamp']?.toDouble() ?? 0.0;
      final error = jsResult['error'];
      
      final List<PoseLandmark> landmarks = [];
      final jsLandmarks = jsResult['landmarks'];
      
      if (jsLandmarks != null) {
        final length = jsLandmarks['length'] ?? 0;
        for (int i = 0; i < length; i++) {
          final jsLandmark = jsLandmarks[i];
          if (jsLandmark != null) {
            landmarks.add(PoseLandmark(
              x: jsLandmark['x']?.toDouble() ?? 0.0,
              y: jsLandmark['y']?.toDouble() ?? 0.0,
              z: jsLandmark['z']?.toDouble() ?? 0.0,
              visibility: jsLandmark['visibility']?.toDouble() ?? 0.0,
              index: jsLandmark['index']?.toInt() ?? i,
            ));
          }
        }
      }

      return PoseResult(
        success: success,
        detected: detected,
        landmarks: landmarks,
        timestamp: timestamp,
        fps: fps,
        error: error,
      );

    } catch (e) {
      return PoseResult(
        success: false,
        detected: false,
        landmarks: [],
        timestamp: DateTime.now().millisecondsSinceEpoch.toDouble(),
        fps: 0.0,
        error: e.toString(),
      );
    }
  }
}

/// 포즈 랜드마크
class PoseLandmark {
  final double x, y, z;
  final double visibility;
  final int index;

  const PoseLandmark({
    required this.x,
    required this.y,
    required this.z,
    required this.visibility,
    required this.index,
  });

  @override
  String toString() => 'PoseLandmark($index: $x, $y, visibility: $visibility)';
}

/// 포즈 감지 결과
class PoseResult {
  final bool success;
  final bool detected;
  final List<PoseLandmark> landmarks;
  final double timestamp;
  final double fps;
  final String? error;

  const PoseResult({
    required this.success,
    required this.detected,
    required this.landmarks,
    required this.timestamp,
    required this.fps,
    this.error,
  });

  factory PoseResult.empty() {
    return PoseResult(
      success: true,
      detected: false,
      landmarks: [],
      timestamp: DateTime.now().millisecondsSinceEpoch.toDouble(),
      fps: 0.0,
    );
  }

  @override
  String toString() {
    return 'PoseResult(detected: $detected, landmarks: ${landmarks.length}, fps: ${fps.toStringAsFixed(1)})';
  }
}