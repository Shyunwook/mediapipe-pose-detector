/**
 * 최적화된 MediaPipe 포즈 감지 (순수 Web 성능)
 * Flutter에서 결과만 읽어가는 방식
 */

// MediaPipe 인스턴스
let poseLandmarker = null;
let vision = null;

// 최적화된 카메라 및 감지 관련
let optimizedVideo = null;
let optimizedStream = null;
let optimizedAnimationId = null;
let lastOptimizedVideoTime = -1;

// 성능 모니터링
let frameCount = 0;
let lastFpsTime = performance.now();
let currentFPS = 0;

// 전역 상태
window.visionInitialized = false;
window.poseLandmarkerLoaded = false;
window.optimizedPoseResults = null;

/**
 * MediaPipe Vision 초기화
 */
async function initializeMediaPipeVision() {
  try {
    if (!window.MediaPipeTasksVision?.FilesetResolver) {
      throw new Error('MediaPipeTasksVision not available');
    }

    // WASM 파일 로딩
    vision = await window.MediaPipeTasksVision.FilesetResolver.forVisionTasks(
      "https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.11/wasm"
    );

    window.vision = vision;
    window.visionInitialized = true;
    return true;

  } catch (error) {
    window.visionInitializationFailed = true;
    window.visionInitializationError = error.message;
    return false;
  }
}

/**
 * MediaPipe Vision 초기화 (동기식 시작)
 */
function initializeMediaPipeVisionSync() {
  window.visionInitialized = false;
  window.visionInitializationFailed = false;

  initializeMediaPipeVision()
    .then((success) => {
      // 결과 처리 완료
    })
    .catch((error) => {
      window.visionInitializationFailed = true;
      window.visionInitializationError = error.message;
    });

  return 'started';
}

/**
 * PoseLandmarker 로드
 */
async function loadPoseLandmarker() {
  try {
    if (!window.visionInitialized || !vision) {
      throw new Error('Vision not initialized');
    }

    if (!window.MediaPipeTasksVision?.PoseLandmarker) {
      throw new Error('PoseLandmarker class not available');
    }

    // 기존 모델 정리
    if (poseLandmarker) {
      poseLandmarker.close();
      poseLandmarker = null;
    }

    // PoseLandmarker 생성
    poseLandmarker = await window.MediaPipeTasksVision.PoseLandmarker.createFromOptions(
      vision,
      {
        baseOptions: {
          modelAssetPath: "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task",
          delegate: "GPU",
        },
        runningMode: "VIDEO",
        numPoses: 1,
        minPoseDetectionConfidence: 0.3,
        minPosePresenceConfidence: 0.3,
        minTrackingConfidence: 0.3,
      }
    );

    window.poseLandmarkerLoaded = true;
    window.poseLandmarkerInstance = poseLandmarker;
    return true;

  } catch (error) {
    window.poseLandmarkerLoaded = false;
    window.poseLandmarkerError = error.message;
    return false;
  }
}

/**
 * 최적화된 카메라 스트림 시작 (Promise를 반환하지 않는 버전)
 */
function startOptimizedCameraStream(constraints = { video: true }) {
  // 에러 정보 초기화
  window.optimizedCameraError = null;
  window.optimizedCameraSuccess = false;
  
  // 비동기 처리를 내부적으로 수행
  (async () => {
    try {
      // 기존 스트림 정리
      if (optimizedStream) {
        optimizedStream.getTracks().forEach(track => track.stop());
      }

      // 직접 getUserMedia로 카메라 획득
      optimizedStream = await navigator.mediaDevices.getUserMedia(constraints);
      
      // 숨겨진 비디오 엘리먼트 생성
      if (!optimizedVideo) {
        optimizedVideo = document.createElement('video');
        optimizedVideo.style.display = 'none';
        optimizedVideo.autoplay = true;
        optimizedVideo.playsInline = true;
        document.body.appendChild(optimizedVideo);
      }

      optimizedVideo.srcObject = optimizedStream;

      // 비디오 로드 완료 대기
      await new Promise((resolve) => {
        optimizedVideo.addEventListener('loadeddata', resolve, { once: true });
      });

      window.optimizedCameraSuccess = true;

    } catch (error) {
      window.optimizedCameraError = error.message || error.toString();
      window.optimizedCameraSuccess = false;
    }
  })();

  // 즉시 'started' 반환 (Flutter가 상태를 별도로 확인)
  return 'started';
}

/**
 * 카메라 스트림 상태 확인
 */
function getCameraStreamStatus() {
  return {
    success: window.optimizedCameraSuccess || false,
    error: window.optimizedCameraError || null,
    hasStream: optimizedStream !== null,
    hasVideo: optimizedVideo !== null && optimizedVideo.srcObject !== null
  };
}

/**
 * 최적화된 실시간 포즈 감지 시작
 */
function startOptimizedRealtimePoseDetection() {
  if (!poseLandmarker || !optimizedVideo) {
    return false;
  }

  function detectPose() {
    if (optimizedVideo.currentTime !== lastOptimizedVideoTime) {
      lastOptimizedVideoTime = optimizedVideo.currentTime;
      
      try {
        // 직접 detectForVideo 호출 - 복사 없음!
        const results = poseLandmarker.detectForVideo(
          optimizedVideo, 
          performance.now()
        );

        // Flutter용 결과 생성
        const landmarks = [];
        if (results.landmarks && results.landmarks.length > 0) {
          const firstPose = results.landmarks[0];
          
          for (let i = 0; i < firstPose.length; i++) {
            const landmark = firstPose[i];
            landmarks.push({
              x: landmark.x,
              y: landmark.y,
              z: landmark.z || 0.0,
              visibility: landmark.visibility || 0.0,
              index: i
            });
          }
        }

        // 전역 변수에 저장
        window.optimizedPoseResults = {
          success: true,
          landmarks: landmarks,
          detected: landmarks.length > 0,
          timestamp: performance.now(),
          fps: calculateCurrentFPS()
        };

      } catch (error) {
        window.optimizedPoseResults = {
          success: false,
          error: error.message,
          timestamp: performance.now()
        };
      }
    }

    optimizedAnimationId = requestAnimationFrame(detectPose);
  }

  optimizedAnimationId = requestAnimationFrame(detectPose);
  return true;
}

/**
 * 포즈 감지 중단
 */
function stopOptimizedRealtimePoseDetection() {
  if (optimizedAnimationId) {
    cancelAnimationFrame(optimizedAnimationId);
    optimizedAnimationId = null;
  }

  // 카메라 스트림 정리
  if (optimizedStream) {
    optimizedStream.getTracks().forEach(track => track.stop());
    optimizedStream = null;
  }

  if (optimizedVideo) {
    optimizedVideo.srcObject = null;
    optimizedVideo.remove();
    optimizedVideo = null;
  }

  // 상태 초기화
  window.optimizedPoseResults = null;
  lastOptimizedVideoTime = -1;
}

/**
 * FPS 계산
 */
function calculateCurrentFPS() {
  frameCount++;
  const now = performance.now();
  
  if (now - lastFpsTime >= 1000) {
    currentFPS = frameCount / ((now - lastFpsTime) / 1000);
    frameCount = 0;
    lastFpsTime = now;
  }
  
  return currentFPS;
}

/**
 * 최신 포즈 결과 가져오기
 */
function getLatestOptimizedPoseResults() {
  return window.optimizedPoseResults || {
    success: true,
    landmarks: [],
    detected: false,
    timestamp: performance.now(),
    fps: 0
  };
}

/**
 * 리소스 정리
 */
function disposeMediaPipe() {
  try {
    stopOptimizedRealtimePoseDetection();
    
    if (poseLandmarker) {
      poseLandmarker.close();
      poseLandmarker = null;
    }

    if (vision) {
      try {
        vision.close();
      } catch (e) {}
      vision = null;
    }

    // 전역 상태 정리
    window.visionInitialized = false;
    window.poseLandmarkerLoaded = false;
    window.optimizedPoseResults = null;
    window.optimizedCameraError = null;

    frameCount = 0;
    lastFpsTime = performance.now();
    currentFPS = 0;

  } catch (error) {
    // 에러 무시
  }
}

// Flutter에서 접근할 수 있도록 전역 함수로 노출
window.initializeMediaPipeVision = initializeMediaPipeVision;
window.initializeMediaPipeVisionSync = initializeMediaPipeVisionSync;
window.loadPoseLandmarker = loadPoseLandmarker;
window.startOptimizedCameraStream = startOptimizedCameraStream;
window.getCameraStreamStatus = getCameraStreamStatus;
window.startOptimizedRealtimePoseDetection = startOptimizedRealtimePoseDetection;
window.stopOptimizedRealtimePoseDetection = stopOptimizedRealtimePoseDetection;
window.getLatestOptimizedPoseResults = getLatestOptimizedPoseResults;
window.disposeMediaPipe = disposeMediaPipe;