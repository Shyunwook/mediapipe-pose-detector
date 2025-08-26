/**
 * MediaPipe Web Worker
 * 백그라운드에서 포즈 감지를 처리하여 메인 스레드 블로킹 방지
 */

// MediaPipe 인스턴스
let poseLandmarker = null;
let vision = null;

// 성능 모니터링
let processingStats = {
  frameCount: 0,
  totalProcessTime: 0,
  lastFpsTime: performance.now(),
  currentFps: 0,
  avgProcessTime: 0
};

// 적응형 품질 설정
let adaptiveConfig = {
  targetFps: 30,
  minConfidence: 0.3,
  enableAdaptiveQuality: true,
  currentQuality: 'medium'
};

/**
 * MediaPipe 초기화 (Worker 내부)
 */
async function initializeMediaPipe() {
  try {
    // MediaPipe 라이브러리가 Worker에서 사용 가능한지 확인
    if (typeof MediaPipeTasksVision === 'undefined') {
      // 메인 스레드에서 라이브러리 로드
      importScripts('https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.11/vision_bundle.js');
    }

    // Vision 초기화
    vision = await MediaPipeTasksVision.FilesetResolver.forVisionTasks(
      "https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.11/wasm"
    );

    // PoseLandmarker 생성
    poseLandmarker = await MediaPipeTasksVision.PoseLandmarker.createFromOptions(vision, {
      baseOptions: {
        modelAssetPath: "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task",
      },
      runningMode: "VIDEO",
      numPoses: 1,
      minPoseDetectionConfidence: adaptiveConfig.minConfidence,
      minPosePresenceConfidence: adaptiveConfig.minConfidence,
      minTrackingConfidence: adaptiveConfig.minConfidence,
    });

    postMessage({
      type: 'initialized',
      success: true
    });

  } catch (error) {
    postMessage({
      type: 'initialized',
      success: false,
      error: error.message
    });
  }
}

/**
 * 포즈 감지 처리 (최적화된 버전)
 */
function processPoseDetection(imageData, width, height, timestamp) {
  const startTime = performance.now();
  
  try {
    if (!poseLandmarker) {
      throw new Error('PoseLandmarker not initialized');
    }

    // ImageData를 Canvas로 변환 (Worker 내에서 OffscreenCanvas 사용)
    const canvas = new OffscreenCanvas(width, height);
    const ctx = canvas.getContext('2d');
    
    const imgData = new ImageData(new Uint8ClampedArray(imageData), width, height);
    ctx.putImageData(imgData, 0, 0);

    // MediaPipe 포즈 감지 실행
    const results = poseLandmarker.detectForVideo(canvas, timestamp);
    
    // 결과 처리 및 최적화
    const landmarks = [];
    let validLandmarkCount = 0;
    
    if (results.landmarks && results.landmarks.length > 0) {
      const firstPoseLandmarks = results.landmarks[0];
      
      for (let i = 0; i < firstPoseLandmarks.length; i++) {
        const landmark = firstPoseLandmarks[i];
        const visibility = landmark.visibility || 0.0;
        
        // 적응형 가시성 필터링
        if (visibility >= adaptiveConfig.minConfidence) {
          landmarks.push({
            x: landmark.x,
            y: landmark.y,
            z: landmark.z || 0.0,
            visibility: visibility,
            index: i
          });
          validLandmarkCount++;
        }
      }
    }

    // 성능 통계 업데이트
    const processTime = performance.now() - startTime;
    updatePerformanceStats(processTime);

    // 결과 전송 (최적화된 구조)
    postMessage({
      type: 'detection_result',
      success: true,
      data: {
        landmarks: landmarks,
        validLandmarkCount: validLandmarkCount,
        detected: landmarks.length > 0,
        visibility: landmarks.length > 0 ? 
          landmarks.reduce((sum, l) => sum + l.visibility, 0) / landmarks.length : 0.0,
        processTime: processTime,
        fps: processingStats.currentFps
      },
      timestamp: timestamp
    });

  } catch (error) {
    postMessage({
      type: 'detection_result',
      success: false,
      error: error.message,
      timestamp: timestamp
    });
  }
}

/**
 * 성능 통계 업데이트 및 적응형 품질 조절
 */
function updatePerformanceStats(processTime) {
  processingStats.frameCount++;
  processingStats.totalProcessTime += processTime;
  processingStats.avgProcessTime = processingStats.totalProcessTime / processingStats.frameCount;

  // FPS 계산 (1초마다)
  const now = performance.now();
  if (now - processingStats.lastFpsTime >= 1000) {
    processingStats.currentFps = processingStats.frameCount / ((now - processingStats.lastFpsTime) / 1000);
    processingStats.lastFpsTime = now;
    processingStats.frameCount = 0;
    processingStats.totalProcessTime = 0;

    // 적응형 품질 조절
    if (adaptiveConfig.enableAdaptiveQuality) {
      adjustQualityBasedOnPerformance();
    }
  }
}

/**
 * 성능 기반 품질 자동 조절
 */
function adjustQualityBasedOnPerformance() {
  const targetFps = adaptiveConfig.targetFps;
  const currentFps = processingStats.currentFps;
  const avgProcessTime = processingStats.avgProcessTime;

  if (currentFps < targetFps * 0.8 || avgProcessTime > 30) {
    // 성능이 부족하면 품질 낮춤
    if (adaptiveConfig.minConfidence < 0.7) {
      adaptiveConfig.minConfidence = Math.min(0.7, adaptiveConfig.minConfidence + 0.1);
      adaptiveConfig.currentQuality = 'low';
    }
  } else if (currentFps > targetFps * 1.1 && avgProcessTime < 15) {
    // 성능이 충분하면 품질 높임
    if (adaptiveConfig.minConfidence > 0.3) {
      adaptiveConfig.minConfidence = Math.max(0.3, adaptiveConfig.minConfidence - 0.1);
      adaptiveConfig.currentQuality = 'high';
    }
  }

  // MediaPipe 모델 재구성 (필요시)
  if (poseLandmarker) {
    // Note: 실제로는 모델 재생성 비용이 크므로, 
    // 런타임에서 confidence 값만 필터링으로 적용
  }
}

// Worker 메시지 핸들러
self.addEventListener('message', async function(e) {
  const { type, data } = e.data;

  switch (type) {
    case 'initialize':
      await initializeMediaPipe();
      break;
      
    case 'process_frame':
      const { imageData, width, height, timestamp } = data;
      processPoseDetection(imageData, width, height, timestamp);
      break;
      
    case 'update_config':
      adaptiveConfig = { ...adaptiveConfig, ...data };
      break;
      
    case 'get_stats':
      postMessage({
        type: 'stats',
        data: {
          ...processingStats,
          config: adaptiveConfig
        }
      });
      break;
      
    case 'dispose':
      if (poseLandmarker) {
        poseLandmarker.close();
        poseLandmarker = null;
      }
      vision = null;
      postMessage({ type: 'disposed' });
      break;
  }
});