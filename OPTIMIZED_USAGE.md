# 최적화된 MediaPipe 포즈 감지 사용법

이 프로젝트는 순수 Web 방식의 성능을 유지하면서 Flutter와 결합한 최적화된 MediaPipe 포즈 감지를 제공합니다.

## 성능 최적화 원리

### 기존 Flutter + JS 방식의 문제점
- Flutter 카메라 → Canvas 복사 → Worker 전송 → MediaPipe
- 여러 번의 메모리 복사로 인한 성능 저하
- Worker 통신 오버헤드

### 최적화된 방식
- JavaScript에서 직접 `getUserMedia()` → `detectForVideo()` 호출
- **복사 없음**: GPU 메모리에서 직접 처리
- Flutter는 결과만 받아서 UI 렌더링

## 사용법

### 1. 기본 설정

HTML 파일에 MediaPipe 라이브러리와 최적화된 스크립트 포함:

```html
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Optimized MediaPipe Pose Detection</title>
</head>
<body>
    <!-- MediaPipe 라이브러리 -->
    <script src="https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.11/vision_bundle.js"></script>
    
    <!-- 최적화된 MediaPipe 래퍼 -->
    <script src="js/mediapipe_web.js"></script>
    
    <!-- Flutter 앱 -->
    <script src="main.dart.js"></script>
</body>
</html>
```

### 2. Flutter 코드 예제

```dart
import 'package:flutter/material.dart';
import 'pose_detector.dart';

class MyPoseDetectionApp extends StatefulWidget {
  @override
  _MyPoseDetectionAppState createState() => _MyPoseDetectionAppState();
}

class _MyPoseDetectionAppState extends State<MyPoseDetectionApp> {
  late PoseDetector _detector;
  PoseResult? _currentResult;

  @override
  void initState() {
    super.initState();
    _detector = PoseDetector();
    _initializeDetector();
  }

  Future<void> _initializeDetector() async {
    // MediaPipe 초기화
    final success = await _detector.initialize();
    if (success) {
      print('✅ MediaPipe initialized successfully');
      
      // 실시간 감지 시작
      await _detector.startRealtimeDetection();
      
      // 결과 스트림 구독
      _detector.getPoseResultsStream().listen((result) {
        setState(() {
          _currentResult = result;
        });
      });
    }
  }

  @override
  void dispose() {
    _detector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Optimized Pose Detection')),
      body: Center(
        child: _currentResult != null && _currentResult!.detected
            ? Column(
                children: [
                  Text('FPS: ${_currentResult!.fps.toStringAsFixed(1)}'),
                  Text('Landmarks: ${_currentResult!.landmarks.length}'),
                  // 포즈 랜드마크 시각화
                  Expanded(
                    child: CustomPaint(
                      painter: PoseLandmarksPainter(_currentResult!.landmarks),
                      size: Size.infinite,
                    ),
                  ),
                ],
              )
            : Text('No pose detected'),
      ),
    );
  }
}
```

### 3. 핵심 API

#### PoseDetector

```dart
// 초기화
final detector = PoseDetector();
await detector.initialize();

// 실시간 감지 시작
await detector.startRealtimeDetection();

// 결과 스트림 구독 (권장)
detector.getPoseResultsStream().listen((result) {
  print('Pose detected: ${result.detected}');
  print('FPS: ${result.fps}');
  print('Landmarks: ${result.landmarks.length}');
});

// 현재 결과 한 번만 가져오기
final result = detector.getCurrentPoseResults();

// 정리
detector.dispose();
```

#### PoseResult

```dart
class PoseResult {
  final bool success;          // 처리 성공 여부
  final bool detected;         // 포즈 감지 여부
  final List<PoseLandmark> landmarks;  // 33개 랜드마크 좌표
  final double timestamp;      // 타임스탬프
  final double fps;           // 현재 FPS
  final String? error;        // 에러 메시지
}
```

#### PoseLandmark

```dart
class PoseLandmark {
  final double x, y, z;       // 정규화된 좌표 (0.0 ~ 1.0)
  final double visibility;    // 가시성 점수 (0.0 ~ 1.0)
  final int index;           // 랜드마크 인덱스 (0 ~ 32)
}
```

## 성능 비교

| 방식 | FPS | 메모리 복사 | 지연시간 |
|------|-----|------------|----------|
| 기존 Flutter + Worker | ~15-20 | 4-5회 | 높음 |
| **최적화된 방식** | **~30-60** | **0회** | **최소** |
| 순수 Web | ~30-60 | 0회 | 최소 |

## 장점

1. **순수 Web 성능**: 메모리 복사 없이 GPU에서 직접 처리
2. **Flutter UI**: 강력한 Flutter UI 프레임워크 활용
3. **간단한 통합**: 기존 Flutter 앱에 쉽게 통합 가능
4. **실시간 처리**: 60 FPS까지 가능한 고성능

## 주의사항

1. **Web 전용**: Flutter Web에서만 작동
2. **카메라 권한**: 브라우저에서 카메라 권한 필요
3. **HTTPS 필요**: 카메라 접근을 위해 HTTPS 환경 권장

## 예제 실행

```bash
# Flutter Web 앱 실행
flutter run -d chrome

# 또는 빌드 후 서빙
flutter build web
cd build/web
python -m http.server 8000
```

브라우저에서 `http://localhost:8000` 접속 후 카메라 권한 허용

## 문제 해결

### 카메라가 시작되지 않는 경우
- HTTPS 환경인지 확인
- 브라우저 콘솔에서 에러 메시지 확인
- `window.optimizedCameraError` 변수 확인

### MediaPipe 로딩 실패
- 인터넷 연결 확인
- CDN URL 접근 가능 여부 확인
- 브라우저 호환성 확인 (Chrome 권장)

### 성능이 낮은 경우
- GPU 가속 활성화 확인 (`chrome://gpu/`)
- 다른 탭의 리소스 사용량 확인
- 해상도 설정 조정