import 'dart:js' as js;
import 'dart:convert';
import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import '../common/mediapipe_interface.dart';

/// MediaPipe 동작 모드
enum MediaPipeMode {
  loading, // 초기 로딩 중
  fullMediaPipe, // 완전한 MediaPipe 동작
  manualLoading, // Vision 초기화는 실패했지만 SDK 로드됨, 수동 모델 로딩
  stubMode, // Mock 데이터 모드
}

/// 웹 플랫폼용 MediaPipe 구현체
class MediaPipeWeb implements MediaPipeInterface {
  /// MediaPipe 설정
  final MediaPipeConfig config;

  /// 현재 모델 로딩 상태
  bool _isModelLoaded = false;

  /// MediaPipe 모드 상태
  MediaPipeMode _currentMediaPipeMode = MediaPipeMode.loading;

  MediaPipeWeb({this.config = const MediaPipeConfig()});

  @override
  Future<void> initialize() async {
    try {
      debugPrint('🔍 Checking MediaPipe Web SDK loading...');

      // MediaPipe SDK 로딩 대기 (최대 15초)
      for (int i = 0; i < 150; i++) {
        await Future.delayed(const Duration(milliseconds: 100));

        // 로딩 성공 확인
        final mediaLoadedBool = js.context['MediaPipeLibraryLoaded'];
        final mediaError = js.context['MediaPipeLibraryError'];

        if (i % 10 == 0) {
          // 1초마다 로그 출력
          debugPrint(
            'Attempt ${i + 1}/150: MediaPipeLibraryLoaded=$mediaLoadedBool, Error=$mediaError',
          );
        }

        if (mediaLoadedBool == true) {
          // MediaPipe SDK가 성공적으로 로드됨
          final tasksVision = js.context['MediaPipeTasksVision'];
          if (tasksVision != null) {
            debugPrint('✅ MediaPipe Web SDK loaded successfully');

            // Vision 초기화 시도 (재시도 로직 포함)
            try {
              bool initSuccess = false;
              int retryCount = 0;
              const maxRetries = 2;

              while (!initSuccess && retryCount <= maxRetries) {
                if (retryCount > 0) {
                  debugPrint(
                    '🔄 Retrying MediaPipe Vision initialization (attempt ${retryCount + 1}/${maxRetries + 1})...',
                  );
                  await Future.delayed(
                    Duration(seconds: 2 * retryCount),
                  ); // 백오프 지연
                }

                initSuccess = await _initializeVision();

                if (initSuccess) {
                  
                  // PoseLandmarker 모델 명시적 로딩 (재시도 없음)
                  final modelLoaded = await _loadPoseLandmarkerModel();
                  if (modelLoaded) {
                    _isModelLoaded = true;
                    _currentMediaPipeMode = MediaPipeMode.fullMediaPipe;
                    return;
                  } else {
                    _currentMediaPipeMode = MediaPipeMode.manualLoading;
                    return;
                  }
                } else {
                  retryCount++;
                  if (retryCount <= maxRetries) {
                    debugPrint(
                      '⚠️ Vision initialization failed, will retry in ${2 * retryCount} seconds...',
                    );
                  }
                }
              }

              // 모든 재시도 실패 - fallback 시도
              debugPrint(
                '❌ MediaPipe Vision initialization failed after ${maxRetries + 1} attempts',
              );
              debugPrint('🔄 Attempting fallback initialization method...');

              final fallbackSuccess = await _initializeVisionFallback();
              if (fallbackSuccess) {
                
                // PoseLandmarker 모델 명시적 로딩 (fallback 후)
                final modelLoaded = await _loadPoseLandmarkerModel();
                if (modelLoaded) {
                  _isModelLoaded = true;
                  _currentMediaPipeMode = MediaPipeMode.fullMediaPipe;
                  return;
                } else {
                  _currentMediaPipeMode = MediaPipeMode.manualLoading;
                  return;
                }
              }

              debugPrint('❌ Fallback initialization also failed');
              debugPrint(
                '🔧 Switching to MANUAL LOADING MODE (SDK available, manual model loading)',
              );
              _currentMediaPipeMode = MediaPipeMode.manualLoading;
              return;
            } catch (e) {
              debugPrint('❌ MediaPipe Vision initialization error: $e');
              debugPrint(
                '🔧 Switching to MANUAL LOADING MODE (SDK available, manual model loading)',
              );
              _currentMediaPipeMode = MediaPipeMode.manualLoading;
              return;
            }
          }
        }

        if (mediaError != null) {
          debugPrint('⚠️ MediaPipe SDK loading failed: $mediaError');
          debugPrint('🔄 Switching to STUB MODE (mock data)');
          _currentMediaPipeMode = MediaPipeMode.stubMode;
          return;
        }
      }

      // 타임아웃
      debugPrint('⏰ MediaPipe SDK loading timeout');
      debugPrint('🔄 Switching to STUB MODE (mock data)');
      _currentMediaPipeMode = MediaPipeMode.stubMode;
    } catch (e) {
      debugPrint('❌ MediaPipe Web initialization failed: $e');
      debugPrint('🔄 Switching to STUB MODE (mock data)');
      _currentMediaPipeMode = MediaPipeMode.stubMode;
    }
  }

  /// MediaPipe Vision 초기화
  Future<bool> _initializeVision() async {
    try {
      // JavaScript 함수 존재 여부 확인
      if (!js.context.hasProperty('initializeMediaPipeVisionSync')) {
        debugPrint('❌ JavaScript initialization function not found');
        return false;
      }

      // 상태 초기화 및 초기화 시작
      js.context['visionInitialized'] = false;
      js.context['visionInitializationFailed'] = false;
      js.context['vision'] = null;

      final initResult = js.context.callMethod('initializeMediaPipeVisionSync');
      if (initResult != 'started') {
        debugPrint('❌ Failed to start vision initialization');
        return false;
      }

      // 초기화 완료 대기 (최대 20초)
      for (int i = 0; i < 200; i++) {
        await Future.delayed(const Duration(milliseconds: 100));

        final visionInitialized = js.context['visionInitialized'];
        final visionFailed = js.context['visionInitializationFailed'];
        final visionReady = js.context['vision'] != null;
        final mediaError = js.context['MediaPipeLibraryError'];

        // 주기적 상태 로그 (5초마다)
        if (i % 50 == 0) {
          debugPrint(
            'Vision status: initialized=$visionInitialized, failed=$visionFailed',
          );
        }

        // 성공 확인
        if (visionInitialized == true && visionReady) {
          debugPrint('✅ MediaPipe Vision initialized successfully');
          return true;
        }

        // 실패 확인
        if (visionFailed == true ||
            (mediaError != null && mediaError != false)) {
          debugPrint('❌ MediaPipe Vision initialization failed');
          return false;
        }
      }

      debugPrint('⏰ Vision initialization timeout');
      return false;
    } catch (e) {
      debugPrint('❌ Vision initialization error: $e');
      return false;
    }
  }

  /// Fallback Vision 초기화 메서드
  Future<bool> _initializeVisionFallback() async {
    try {
      debugPrint('🔄 Starting fallback MediaPipe Vision initialization...');

      // Fallback 함수 존재 여부 확인
      final hasFallbackFunction = js.context.hasProperty(
        'initializeMediaPipeVisionFallback',
      );
      if (!hasFallbackFunction) {
        debugPrint('❌ Fallback function not available');
        return false;
      }

      // 상태 초기화
      js.context['visionInitialized'] = false;
      js.context['visionInitializationFailed'] = false;

      // Fallback 함수 호출 (async)
      final fallbackResult = await js.context.callMethod(
        'initializeMediaPipeVisionFallback',
      );
      debugPrint('🎯 Fallback initialization result: $fallbackResult');

      // 결과 확인을 위한 짧은 대기
      for (int i = 0; i < 50; i++) {
        await Future.delayed(const Duration(milliseconds: 100));

        final visionInitialized = js.context['visionInitialized'];
        final visionFailed = js.context['visionInitializationFailed'];
        final visionReady = js.context['vision'] != null;

        if (visionInitialized == true && visionReady) {
          debugPrint('✅ Fallback MediaPipe Vision initialized and ready');
          return true;
        }

        if (visionFailed == true) {
          debugPrint('❌ Fallback MediaPipe Vision initialization failed');
          return false;
        }
      }

      debugPrint('⏰ Fallback initialization timeout');
      return false;
    } catch (e) {
      debugPrint('❌ Fallback initialization error: $e');
      return false;
    }
  }

  /// PoseLandmarker 모델 로딩
  Future<bool> _loadPoseLandmarkerModel() async {
    try {
      
      // JavaScript 함수 존재 여부 확인
      if (!js.context.hasProperty('loadPoseLandmarker')) {
        debugPrint('❌ loadPoseLandmarker JavaScript function not found');
        return false;
      }

      // 모델 로딩 호출 및 상세한 로깅
      final loadResult = await js.context.callMethod('loadPoseLandmarker');
      
      // 결과 검증 - 여러 형태로 체크
      bool isSuccess = false;
      if (loadResult == true) {
        isSuccess = true;
      } else if (loadResult is bool && loadResult) {
        isSuccess = true;
      } else if (loadResult.toString().toLowerCase() == 'true') {
        isSuccess = true;
      }
      
      if (isSuccess) {
        return true;
      } else {
        
        // 실패했지만 JavaScript 상태 확인
        final jsInstanceExists = js.context['poseLandmarkerInstance'] != null;
        if (jsInstanceExists) {
          return true;
        }
        
        return false;
      }
    } catch (e) {
      debugPrint('❌ Error loading PoseLandmarker model: $e');
      
      // 예외가 발생해도 JavaScript 인스턴스가 존재하는지 확인
      try {
        final jsInstanceExists = js.context['poseLandmarkerInstance'] != null;
        if (jsInstanceExists) {
          return true;
        }
      } catch (checkError) {
        // JavaScript 인스턴스 확인 실패 무시
      }
      
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    try {
      // JavaScript MediaPipe 리소스 정리
      js.context.callMethod('disposeMediaPipe');
    } catch (e) {
      // 에러 발생해도 계속 진행
    }

    _isModelLoaded = false;
  }

  @override
  bool get isModelLoaded => _isModelLoaded;

  @override
  Future<MediaPipeResult> detect() async {
    try {
      try {
        // 웹 카메라에서 실시간 프레임 캡처
        final frameData = js.context.callMethod('captureVideoFrame');

        if (frameData == null) {
          // 프레임 캡처 실패 시 빈 결과 반환
          return const MediaPipeResult(
            success: true,
            data: {
              'result': {
                'landmarks': [],
                'detected': false,
                'visibility': 0.0,
                'validLandmarks': 0,
              },
            },
          );
        }

        // JavaScript에서 직접 비디오 캡처 및 처리 (가장 안정적)
        final directResult = js.context.callMethod('detectPoseLandmarksFromVideo');
        
        if (directResult != null) {
          final result = json.decode(directResult.toString());
          return MediaPipeResult(
            success: true,
            data: Map<String, dynamic>.from(result),
          );
        }
        
        throw Exception('No result from JavaScript');
      } catch (e) {
        // 에러 시 빈 결과 반환
        return const MediaPipeResult(
          success: true,
          data: {
            'result': {
              'landmarks': [],
              'detected': false,
              'confidence': 0.0,
              'validLandmarks': 0,
            },
          },
        );
      }
    } catch (e) {
      return MediaPipeResult(
        success: false,
        error: 'Web pose detection failed: $e',
      );
    }
  }
}
