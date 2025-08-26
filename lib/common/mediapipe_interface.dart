/// MediaPipe 추론 결과 구조체
class MediaPipeResult {
  final bool success;
  final Map<String, dynamic>? data;
  final String? error;

  const MediaPipeResult({required this.success, this.data, this.error});

  /// 손 랜드마크 데이터 추출
  List<Map<String, double>> get landmarks {
    if (!success || data == null) return [];

    final result = data!['result'];
    if (result is! Map) return [];

    final landmarks = result['landmarks'];
    if (landmarks is List) {
      return landmarks.map((landmark) {
        if (landmark is Map) {
          return Map<String, double>.from(
            landmark.map(
              (key, value) =>
                  MapEntry(key.toString(), (value as num).toDouble()),
            ),
          );
        }
        return <String, double>{};
      }).toList();
    }
    return [];
  }
}

/// 플랫폼별 MediaPipe 구현을 위한 추상 인터페이스
abstract class MediaPipeInterface {
  /// MediaPipe 모델 초기화
  Future<void> initialize();

  Future<MediaPipeResult> detect();

  /// 리소스 정리
  Future<void> dispose();

  /// 현재 모델 로딩 상태
  bool get isModelLoaded;
  
  /// 최적화된 모드 시작 (Web 전용, 다른 플랫폼에서는 false 반환)
  Future<bool> startOptimizedMode() async => false;
  
  /// 최적화된 모드 중단 (Web 전용, 다른 플랫폼에서는 무시)
  void stopOptimizedMode() {}
  
  /// 성능 통계 가져오기 (Web 전용, 다른 플랫폼에서는 null 반환)
  Map<String, dynamic>? getPerformanceStats() => null;
}

/// MediaPipe 설정 옵션
class MediaPipeConfig {
  /// 최대 감지할 손 개수
  final int numHands;

  /// 손 감지 최소 신뢰도
  final double minHandDetectionConfidence;

  /// 손 존재 최소 신뢰도
  final double minHandPresenceConfidence;

  /// 추적 최소 신뢰도
  final double minTrackingConfidence;

  const MediaPipeConfig({
    this.numHands = 2,
    this.minHandDetectionConfidence = 0.5,
    this.minHandPresenceConfidence = 0.5,
    this.minTrackingConfidence = 0.5,
  });
}
