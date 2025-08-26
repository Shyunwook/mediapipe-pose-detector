import 'package:pose_detection_web_test/mediapipe_web.dart';
import 'mediapipe_interface.dart';

/// 플랫폼별 MediaPipe 구현체 팩토리
class MediaPipeFactory {
  /// 현재 플랫폼에 맞는 MediaPipe 인스턴스 생성
  static MediaPipeInterface create({
    MediaPipeConfig config = const MediaPipeConfig(),
  }) {
    return MediaPipeWeb(config: config);
  }
}
