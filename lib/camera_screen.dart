import 'package:flutter/material.dart';
import 'dart:async';
import 'pose_detector.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  late PoseDetector _detector;
  StreamSubscription<PoseResult>? _subscription;

  PoseResult? _currentResult;
  String _status = 'Initializing...';
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _detector = PoseDetector();
    _initialize();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _detector.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    final success = await _detector.initialize();

    setState(() {
      _isInitialized = success;
      _status = success ? 'Ready' : 'Initialization failed';
    });
  }

  Future<void> _startDetection() async {
    final success = await _detector.startRealtimeDetection();

    if (success) {
      _subscription = _detector.getPoseResultsStream().listen((result) {
        setState(() {
          _currentResult = result;
          _status = result.detected
              ? 'Pose detected! FPS: ${result.fps.toStringAsFixed(1)}'
              : 'No pose. FPS: ${result.fps.toStringAsFixed(1)}';
        });
      });
    } else {
      setState(() {
        _status = 'Failed to start detection';
      });
    }
  }

  void _stopDetection() {
    _subscription?.cancel();
    _subscription = null;
    _detector.stopRealtimeDetection();

    setState(() {
      _currentResult = null;
      _status = 'Stopped';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pose Detection'),
        backgroundColor: Colors.blue[600],
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // 상태
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Status: $_status',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (_currentResult != null) ...[
                  const SizedBox(height: 8),
                  Text('Landmarks: ${_currentResult!.landmarks.length}/33'),
                  if (_currentResult!.error != null)
                    Text(
                      'Error: ${_currentResult!.error}',
                      style: const TextStyle(color: Colors.red),
                    ),
                ],
              ],
            ),
          ),

          // 버튼들
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                onPressed: _isInitialized && !_detector.isRunning
                    ? _startDetection
                    : null,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                child: const Text(
                  'Start',
                  style: TextStyle(color: Colors.white),
                ),
              ),
              ElevatedButton(
                onPressed: _detector.isRunning ? _stopDetection : null,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text(
                  'Stop',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // 포즈 시각화
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey[400]!),
                borderRadius: BorderRadius.circular(8),
              ),
              child: _currentResult?.detected == true
                  ? CustomPaint(
                      painter: SimplePosePainter(_currentResult!.landmarks),
                      size: Size.infinite,
                    )
                  : const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.person_outline,
                            size: 80,
                            color: Colors.grey,
                          ),
                          SizedBox(height: 16),
                          Text(
                            'No pose detected',
                            style: TextStyle(fontSize: 18, color: Colors.grey),
                          ),
                          SizedBox(height: 8),
                          Text(
                            '🚀 Optimized: JS handles camera + MediaPipe',
                            style: TextStyle(fontSize: 12, color: Colors.blue),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 간단한 포즈 랜드마크 페인터
class SimplePosePainter extends CustomPainter {
  final List<PoseLandmark> landmarks;

  SimplePosePainter(this.landmarks);

  @override
  void paint(Canvas canvas, Size size) {
    final pointPaint = Paint()
      ..color = Colors.red
      ..strokeWidth = 4.0
      ..style = PaintingStyle.fill;

    final linePaint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    // 랜드마크 점들 그리기
    for (final landmark in landmarks) {
      if (landmark.visibility > 0.3) {
        final x = landmark.x * size.width;
        final y = landmark.y * size.height;

        canvas.drawCircle(Offset(x, y), landmark.visibility * 6, pointPaint);
      }
    }

    // 주요 연결선 (간단한 예시)
    _drawConnections(canvas, size, linePaint);
  }

  void _drawConnections(Canvas canvas, Size size, Paint paint) {
    // 간단한 연결선들
    final connections = [
      // 얼굴
      [0, 1], [1, 2], [2, 3], [3, 7],
      [0, 4], [4, 5], [5, 6], [6, 8],
      // 몸통
      [11, 12], [11, 23], [12, 24], [23, 24],
      // 팔
      [11, 13], [13, 15], [12, 14], [14, 16],
      // 다리
      [23, 25], [25, 27], [24, 26], [26, 28],
    ];

    for (final connection in connections) {
      if (connection.length >= 2 &&
          connection[0] < landmarks.length &&
          connection[1] < landmarks.length) {
        final start = landmarks[connection[0]];
        final end = landmarks[connection[1]];

        if (start.visibility > 0.3 && end.visibility > 0.3) {
          canvas.drawLine(
            Offset(start.x * size.width, start.y * size.height),
            Offset(end.x * size.width, end.y * size.height),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(SimplePosePainter oldDelegate) {
    return oldDelegate.landmarks != landmarks;
  }
}
