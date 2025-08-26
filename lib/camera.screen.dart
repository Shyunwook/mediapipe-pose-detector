import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pose_detection_web_test/common/mediapipe_factory.dart';
import 'package:pose_detection_web_test/common/mediapipe_interface.dart';
import 'package:pose_detection_web_test/mediapipe_web.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  late final MediaPipeInterface _mediaPipe;

  late List<CameraDescription> cameras;
  CameraController? _controller;

  bool _isRecording = false;
  bool _isProcessing = false;

  double _screenWidth = 0.0;
  double _cameraRatio = 1.0;

  List<Offset> _landmarks = []; // 현재 프레임의 랜드마크 좌표들
  List<Offset> _previousLandmarks = [];

  Timer? _webImageTimer;

  // 최적화된 처리 모드
  bool _useOptimizedMode = true;
  Map<String, dynamic>? _performanceStats;

  // FPS 모니터링
  int _frameCount = 0;
  DateTime _lastFpsTime = DateTime.now();
  double _currentFps = 0.0;

  @override
  void initState() {
    super.initState();
    _mediaPipe = MediaPipeFactory.create();
    _asyncInitState();
  }

  Future<void> _asyncInitState() async {
    cameras = await availableCameras();
    await _initializeCamera();
    await _mediaPipe.initialize();

    // 최적화된 모드 시작 시도
    if (_useOptimizedMode && _mediaPipe is MediaPipeWeb) {
      final success = await _mediaPipe.startOptimizedMode();
      if (success) {
        debugPrint('✅ Successfully started optimized mode');
      } else {
        debugPrint('⚠️ Failed to start optimized mode, using legacy');
        _useOptimizedMode = false;
      }
    }

    setState(() {});
  }

  Future<void> _initializeCamera() async {
    if (cameras.isNotEmpty) {
      // 화면 비율 계산
      _screenWidth = MediaQuery.of(context).size.width;
      // Web: 카메라 원본 비율 사용
      _cameraRatio = 0.75;

      CameraDescription selectedCamera;

      if (kIsWeb) {
        // 웹: 첫 번째 카메라 사용 (보통 전면 카메라)
        selectedCamera = cameras.first;
      } else {
        // 모바일: 전면 카메라 찾기, 없으면 첫 번째 카메라
        try {
          selectedCamera = cameras.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.front,
            orElse: () => cameras.first,
          );
        } catch (e) {
          selectedCamera = cameras.first;
        }
      }

      _controller = CameraController(
        selectedCamera,
        kIsWeb ? ResolutionPreset.medium : ResolutionPreset.low,
        enableAudio: false,
      );

      await _controller!.initialize();

      if (mounted) {
        _screenWidth = MediaQuery.of(context).size.width;
      }
    }
  }

  /// 촬영 시작/중단 토글 버튼 핸들러
  void _toggleRecording() {
    setState(() {
      _isRecording = !_isRecording;
    });

    if (_isRecording) {
      _startImageStream(); // 촬영 시작
    } else {
      _stopImageStream(); // 촬영 중단
      _clearAllLandmarks();
    }
  }

  void _startImageStream() {
    if (_controller != null && _controller!.value.isInitialized) {
      if (_useOptimizedMode) {
        // 최적화된 모드: 매우 빠른 인터벌로 결과만 가져오기
        _webImageTimer = Timer.periodic(const Duration(milliseconds: 16), (
          // ~60 FPS 체크
          timer,
        ) async {
          if (!_isProcessing && _isRecording) {
            try {
              await _processOptimizedWeb();
            } catch (e) {
              // 에러 무시
            }
          }
        });
      } else {
        // 레거시 모드: 기존 방식
        _webImageTimer = Timer.periodic(const Duration(milliseconds: 100), (
          timer,
        ) async {
          if (!_isProcessing && _isRecording) {
            try {
              await _processWebImage(null);
            } catch (e) {
              // 에러 무시
            }
          }
        });
      }
    }
  }

  void _stopImageStream() {
    // 웹: 타이머 중지
    _webImageTimer?.cancel();
    _webImageTimer = null;
  }

  /// 최적화된 웹 처리 (캐시된 결과 사용)
  Future<void> _processOptimizedWeb() async {
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
    });

    try {
      // 최적화된 방식으로 결과 가져오기 (데이터 전송 최소화)
      MediaPipeResult result = await _mediaPipe.detect();

      // 결과 처리
      if (result.success) {
        _parseResult(result);

        // 성능 통계 업데이트
        _updateFpsStats();

        // 성능 모니터링 업데이트
        if (_mediaPipe is MediaPipeWeb) {
          _performanceStats = _mediaPipe.getPerformanceStats();
        }
      } else {
        _clearAllLandmarks();
      }
    } catch (e) {
      debugPrint('Optimized processing error: $e');
      _clearAllLandmarks();
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  /// 레거시 웹용 이미지 처리 함수 (JavaScript 기반)
  Future<void> _processWebImage(XFile? imageFile) async {
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
    });

    try {
      // MediaPipe 추론 실행 (JavaScript가 직접 비디오 프레임 처리)
      MediaPipeResult result = await _mediaPipe.detect();

      // 결과 처리
      if (result.success) {
        _parseResult(result);
      } else {
        _clearAllLandmarks();
      }
    } catch (e) {
      // 에러 무시
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  void _parseResult(MediaPipeResult result) {
    if (!_isRecording) return;

    final resultData = result.data!['result'];
    if (resultData == null) {
      return;
    }

    final landmarks = resultData['landmarks'] as List<dynamic>?;

    if (landmarks != null && landmarks.isNotEmpty) {
      if (!mounted) return;

      final newLandmarks = landmarks
          .map<Offset>((mark) {
            final markMap = mark as Map<String, dynamic>;
            double x = (markMap['x'] ?? 0.0).toDouble(); // 0.0 ~ 1.0
            double y = (markMap['y'] ?? 0.0).toDouble(); // 0.0 ~ 1.0
            double visibility = (markMap['visibility'] ?? 0.0).toDouble();

            // 가시성이 낮은 포인트는 건너뛰기 (성능 최적화)
            if (visibility < 0.5) {
              return Offset(-1, -1); // 화면 밖 좌표로 설정
            }

            // 플랫폼별 좌표 보정 (포즈는 보통 미러링 불필요)
            if (kIsWeb) {
              // 포즈 랜드마크는 일반적으로 미러링하지 않음
              // x = 1 - x; // 필요시에만 활성화
            }

            // 화면 크기에 맞춰 스케일링
            return Offset(
              x * _screenWidth, // x 좌표
              y * _screenWidth * _cameraRatio, // y 좌표 (비율 적용)
            );
          })
          .where((offset) => offset.dx >= 0 && offset.dy >= 0)
          .toList();

      // 4. 좌표 스무딩 (떨림 방지)
      if (_previousLandmarks.isNotEmpty &&
          _previousLandmarks.length == newLandmarks.length) {
        // 이전 프레임과 현재 프레임을 가중평균하여 부드러운 움직임 생성
        if (_landmarks.length != newLandmarks.length) {
          _landmarks = List.filled(newLandmarks.length, Offset.zero);
        }
        for (int i = 0; i < newLandmarks.length; i++) {
          _landmarks[i] = Offset(
            newLandmarks[i].dx * 0.7 +
                _previousLandmarks[i].dx * 0.3, // 70% 현재 + 30% 이전
            newLandmarks[i].dy * 0.7 + _previousLandmarks[i].dy * 0.3,
          );
        }
      } else {
        // 첫 프레임이거나 랜드마크 개수가 변경된 경우 그대로 사용
        _landmarks = newLandmarks;
      }

      // 5. 다음 프레임을 위해 현재 랜드마크 저장
      _previousLandmarks = List.from(_landmarks);
    } else {
      _clearAllLandmarks();
    }
  }

  /// FPS 통계 업데이트
  void _updateFpsStats() {
    _frameCount++;
    final now = DateTime.now();
    final elapsed = now.difference(_lastFpsTime).inMilliseconds;

    if (elapsed >= 1000) {
      // 1초마다 FPS 계산
      _currentFps = _frameCount / (elapsed / 1000.0);
      _frameCount = 0;
      _lastFpsTime = now;
    }
  }

  /// 성능 정보 표시 위젯
  Widget _buildPerformanceInfo() {
    if (!_useOptimizedMode) {
      return const SizedBox.shrink();
    }

    return Positioned(
      top: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'FPS: ${_currentFps.toStringAsFixed(1)}',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
            if (_performanceStats != null) ...[
              Text(
                'Worker FPS: ${_performanceStats!['workerFps']?.toStringAsFixed(1) ?? 'N/A'}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              Text(
                'Dropped: ${_performanceStats!['droppedFrames'] ?? 0}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              Text(
                'Mode: ${_useOptimizedMode ? 'Optimized' : 'Legacy'}',
                style: TextStyle(
                  color: _useOptimizedMode ? Colors.green : Colors.orange,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    // 최적화된 모드 중단
    if (_useOptimizedMode && _mediaPipe is MediaPipeWeb) {
      _mediaPipe.stopOptimizedMode();
    }

    _controller?.dispose();
    _mediaPipe.dispose();
    super.dispose();
  }

  void _clearAllLandmarks() {
    _landmarks.clear();
    _previousLandmarks.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pose Landmark Detection'),
        backgroundColor: Colors.blueGrey,
      ),
      body: Column(
        children: [
          Expanded(
            child: _controller == null
                ? Center(child: CircularProgressIndicator())
                : Stack(
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          return CameraPreview(_controller!);
                        },
                      ),
                      RepaintBoundary(
                        child: CustomPaint(
                          painter: LandmarkPainter(_landmarks),
                          size: Size.infinite,
                        ),
                      ),
                      // 성능 정보 표시
                      _buildPerformanceInfo(),
                    ],
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: _toggleRecording,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isRecording ? Colors.red : Colors.green,
                    foregroundColor: Colors.white,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_isRecording ? Icons.stop : Icons.play_arrow),
                      const SizedBox(width: 8),
                      Text(
                        _isRecording ? '중단' : '촬영 시작',
                        style: const TextStyle(fontSize: 16),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class LandmarkPainter extends CustomPainter {
  final List<Offset> landmarks;

  // Paint 객체 정적 캐싱 (메모리 최적화)
  static Paint? _cachedPaint; // 메인 랜드마크용
  static Paint? _cachedShadowPaint; // 그림자 효과용

  LandmarkPainter(this.landmarks);

  @override
  void paint(Canvas canvas, Size size) {
    if (landmarks.isEmpty) return;

    // Paint 객체 지연 초기화 및 캐싱
    _cachedPaint ??= Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill
      ..isAntiAlias = false; // 성능 향상을 위한 안티앨리어싱 비활성화

    _cachedShadowPaint ??= Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;

    // // 모든 랜드마크를 순서대로 그리기
    for (final landmark in landmarks) {
      // 1. 흰색 그림자 (가시성 향상)
      canvas.drawCircle(landmark, 6.5, _cachedShadowPaint!);
      // 2. 빨간색 메인 원
      canvas.drawCircle(landmark, 5.5, _cachedPaint!);
    }
  }

  @override
  bool shouldRepaint(LandmarkPainter oldDelegate) {
    // 랜드마크 개수나 위치가 변경된 경우에만 다시 그리기 (성능 최적화)
    if (landmarks.length != oldDelegate.landmarks.length) return true;

    // 위치 변화가 충분히 클 때만 다시 그리기 (미세한 떨림 무시)
    for (int i = 0; i < landmarks.length; i++) {
      final diff = (landmarks[i] - oldDelegate.landmarks[i]).distance;
      if (diff > 2.0) return true; // 2픽셀 이상 변화시에만 다시 그리기
    }
    return false;
  }
}
