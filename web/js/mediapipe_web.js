/**
 * MediaPipe Web SDK를 위한 JavaScript 래퍼 함수들
 * Flutter Web에서 dart:js를 통해 호출됨
 */

// MediaPipe 인스턴스 저장
let poseLandmarker = null;
let vision = null;

// 전역 상태 변수 (플러터 Dart와 동기화용)
window.poseLandmarkerLoaded = false;
window.poseLandmarkerInstance = null;

// 재사용 가능한 Canvas 엘리먼트
let reusableCanvas = null;

// 웹 카메라 관련
let videoElement = null;
let captureCanvas = null;
let lastFrameTime = 0;
let lastVideoTimestamp = 1; // MediaPipe 비디오 타임스탬프 추적 (1부터 시작)
const FRAME_INTERVAL = 50; // 50ms 간격으로 프레임 캡처 (Flutter 100ms보다 빠르게)

// Web Worker 및 최적화된 프레임 처리
let mediaWorker = null;
let isProcessingFrame = false;
let frameQueue = [];
let animationFrameId = null;
let lastResultCache = null;
let processingStats = {
  frameCount: 0,
  droppedFrames: 0,
  avgFps: 0,
  lastStatsTime: performance.now(),
};

/**
 * Web Worker 초기화
 */
function initializeWebWorker() {
  try {
    if (mediaWorker) {
      mediaWorker.terminate();
    }

    mediaWorker = new Worker("/js/mediapipe_worker.js");

    mediaWorker.onmessage = function (e) {
      const { type, data, success, error, timestamp } = e.data;

      switch (type) {
        case "initialized":
          window.workerInitialized = success;
          if (!success) {
            console.error("Worker initialization failed:", error);
            window.workerInitializationError = error;
          }
          break;

        case "detection_result":
          handleWorkerResult(e.data);
          break;

        case "stats":
          window.mediaPipeStats = data;
          break;
      }
    };

    mediaWorker.onerror = function (error) {
      console.error("Worker error:", error);
      window.workerInitializationError = error.message;
    };

    // Worker 초기화 시작
    mediaWorker.postMessage({ type: "initialize" });

    return true;
  } catch (error) {
    console.error("Failed to create worker:", error);
    return false;
  }
}

/**
 * Worker 결과 처리
 */
function handleWorkerResult(result) {
  isProcessingFrame = false;

  if (result.success) {
    lastResultCache = {
      success: true,
      result: result.data,
      timestamp: result.timestamp,
    };

    // 성능 통계 업데이트
    updateProcessingStats(result.data.processTime, result.data.fps);

    // Flutter에서 접근 가능하도록 전역 변수에 저장
    window.lastDetectionResult = JSON.stringify(lastResultCache);
  } else {
    lastResultCache = {
      success: false,
      error: result.error,
    };
    window.lastDetectionResult = JSON.stringify(lastResultCache);
  }
}

/**
 * 성능 통계 업데이트
 */
function updateProcessingStats(processTime, workerFps) {
  processingStats.frameCount++;
  const now = performance.now();

  if (now - processingStats.lastStatsTime >= 1000) {
    processingStats.avgFps =
      processingStats.frameCount /
      ((now - processingStats.lastStatsTime) / 1000);
    processingStats.lastStatsTime = now;
    processingStats.frameCount = 0;

    // 성능 정보를 전역에서 접근 가능하도록
    window.mediaPipePerformance = {
      ...processingStats,
      workerFps: workerFps,
      lastProcessTime: processTime,
    };
  }
}

/**
 * requestAnimationFrame 기반 프레임 처리
 */
function startOptimizedFrameProcessing() {
  function processFrame() {
    if (!isProcessingFrame && videoElement && videoElement.readyState >= 2) {
      const frameData = captureVideoFrameOptimized();

      if (frameData && mediaWorker) {
        isProcessingFrame = true;
        const timestamp = Math.max(lastVideoTimestamp + 1, performance.now());
        lastVideoTimestamp = timestamp;

        // Worker로 프레임 전송 (최적화된 데이터)
        mediaWorker.postMessage({
          type: "process_frame",
          data: {
            imageData: frameData.data,
            width: frameData.width,
            height: frameData.height,
            timestamp: timestamp,
          },
        });
      } else if (!frameData) {
        processingStats.droppedFrames++;
      }
    }

    animationFrameId = requestAnimationFrame(processFrame);
  }

  if (animationFrameId) {
    cancelAnimationFrame(animationFrameId);
  }

  processFrame();
}

/**
 * 최적화된 프레임 처리 중단
 */
function stopOptimizedFrameProcessing() {
  if (animationFrameId) {
    cancelAnimationFrame(animationFrameId);
    animationFrameId = null;
  }
  isProcessingFrame = false;
}

/**
 * MediaPipe Vision 초기화 (WASM 로딩 및 런타임 준비)
 */
async function initializeMediaPipeVision() {
  try {
    // 1단계: 라이브러리가 로드되었는지 확인
    if (!window.MediaPipeLibraryLoaded) {
      if (window.MediaPipeLibraryError) {
        throw new Error(
          `Library loading failed: ${window.MediaPipeLibraryError}`
        );
      }
      throw new Error("MediaPipe library not loaded yet");
    }

    if (!window.MediaPipeTasksVision?.FilesetResolver) {
      throw new Error("FilesetResolver not available in loaded library");
    }

    // 2단계: WASM 파일 로딩 및 런타임 초기화 (메모리 최적화 버전)
    const wasmUrls = [
      "https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.11/wasm", // 더 안정적인 버전
      "https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.0/wasm", // 경량 버전
      "https://unpkg.com/@mediapipe/tasks-vision@0.10.11/wasm",
      "https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.14/wasm", // 최신 버전 마지막에
    ];

    let lastError = null;

    for (const wasmUrl of wasmUrls) {
      try {
        vision =
          await window.MediaPipeTasksVision.FilesetResolver.forVisionTasks(
            wasmUrl
          );

        window.vision = vision;
        window.visionInitialized = true;
        return true;
      } catch (error) {
        lastError = error;
        continue;
      }
    }

    throw new Error(`All WASM URLs failed. Last error: ${lastError?.message}`);
  } catch (error) {
    window.visionInitializationFailed = true;
    window.visionInitialized = false;
    return false;
  }
}

/**
 * 동기식 Vision 초기화 호출 (Flutter와의 호환성을 위해)
 */
function initializeMediaPipeVisionSync() {
  // 전역 상태 초기화
  window.visionInitialized = false;
  window.visionInitializationFailed = false;

  // 라이브러리 로딩 대기 후 초기화
  const startInitialization = () => {
    initializeMediaPipeVision()
      .then((success) => {
        if (success) {
        }
      })
      .catch((error) => {
        window.visionInitializationFailed = true;
      });
  };

  // 라이브러리가 이미 로드되었으면 바로 시작
  if (window.MediaPipeLibraryLoaded) {
    startInitialization();
  } else {
    // 라이브러리 로딩 대기
    const checkLibraryLoaded = () => {
      if (window.MediaPipeLibraryLoaded) {
        startInitialization();
      } else if (window.MediaPipeLibraryError) {
        window.visionInitializationFailed = true;
      } else {
        setTimeout(checkLibraryLoaded, 100);
      }
    };
    checkLibraryLoaded();
  }

  return "started";
}

/**
 * 대체 Vision 초기화 (더 단순한 접근법)
 */
async function initializeMediaPipeVisionFallback() {
  try {
    // MediaPipe TasksVision이 로드되었는지 확인
    if (
      !window.MediaPipeTasksVision ||
      !window.MediaPipeTasksVision.FilesetResolver
    ) {
      throw new Error("MediaPipeTasksVision not available for fallback");
    }

    // 단순한 초기화 시도 (CDN URL 없이)
    try {
      vision = window.MediaPipeTasksVision.FilesetResolver;
      window.vision = vision;
      window.visionInitialized = true;
      return true;
    } catch (e) {}

    // Mock fallback
    vision = await window.MediaPipeTasksVision.FilesetResolver.forVisionTasks(
      "mock://fallback"
    );
    window.vision = vision;
    window.visionInitialized = true;
    return true;
  } catch (error) {
    window.visionInitializationFailed = true;
    return false;
  }
}

async function loadPoseLandmarker() {
  try {
    // Vision 런타임 확인
    if (!window.visionInitialized || !vision) {
      throw new Error("MediaPipe Vision runtime not initialized");
    }

    // PoseLandmarker 클래스 확인
    if (
      !window.MediaPipeLibraryLoaded ||
      !window.MediaPipeTasksVision?.PoseLandmarker
    ) {
      throw new Error("PoseLandmarker not available");
    }

    // 3단계: PoseLandmarker 모델 생성 (메모리 최적화)

    // 기존 모델 정리
    if (poseLandmarker) {
      try {
        poseLandmarker.close();
      } catch (e) {}
      poseLandmarker = null;
    }

    poseLandmarker =
      await window.MediaPipeTasksVision.PoseLandmarker.createFromOptions(
        vision,
        {
          baseOptions: {
            modelAssetPath:
              "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task",
            delegate: ".GPU",
          },
          runningMode: "VIDEO",
          numPoses: 1,
          minPoseDetectionConfidence: 0.3, // 낮춤 (리소스 절약)
          minPosePresenceConfidence: 0.3, // 낮춤
          minTrackingConfidence: 0.3, // 낮춤
        }
      );

    // 모델 로딩 성공 확인
    if (poseLandmarker) {
      // 전역 변수로 상태 저장 (Dart에서 확인 가능)
      window.poseLandmarkerLoaded = true;
      window.poseLandmarkerInstance = poseLandmarker;

      return true;
    } else {
      return false;
    }
  } catch (error) {
    // 전역 상태 업데이트
    window.poseLandmarkerLoaded = false;
    window.poseLandmarkerInstance = null;
    return false;
  }
}

/**
 * 재사용 가능한 Canvas 엘리먼트 생성/반환
 */
function getReusableCanvas(width, height) {
  if (!reusableCanvas) {
    reusableCanvas = document.createElement("canvas");
  }

  if (reusableCanvas.width !== width || reusableCanvas.height !== height) {
    reusableCanvas.width = width;
    reusableCanvas.height = height;
  }

  return reusableCanvas;
}

/**
 * RGBA 이미지 데이터를 Canvas로 변환
 */
function createImageFromRGBA(imageData, width, height) {
  const canvas = getReusableCanvas(width, height);
  const ctx = canvas.getContext("2d");

  // 데이터 길이 검증
  const expectedLength = 4 * width * height; // RGBA = 4 bytes per pixel
  const actualLength = imageData.length;

  if (actualLength !== expectedLength) {
    // 데이터가 부족하면 패딩하거나 조정
    let adjustedData;
    if (actualLength < expectedLength) {
      // 데이터가 부족한 경우 0으로 채움
      adjustedData = new Uint8ClampedArray(expectedLength);
      adjustedData.set(imageData);
    } else {
      // 데이터가 너무 많은 경우 자름
      adjustedData = new Uint8ClampedArray(imageData.slice(0, expectedLength));
    }

    const imgData = new ImageData(adjustedData, width, height);
    ctx.putImageData(imgData, 0, 0);
  } else {
    // 정상적인 경우
    const imgData = new ImageData(
      new Uint8ClampedArray(imageData),
      width,
      height
    );
    ctx.putImageData(imgData, 0, 0);
  }

  return canvas;
}

/**
 * 포즈 랜드마크 감지 수행
 */
// 동기적 포즈 랜드마크 감지 (Promise 문제 해결)
function detectPoseLandmarksSync(imageData, width, height) {
  try {
    // PoseLandmarker가 로드되지 않았다면 에러 반환
    if (!poseLandmarker) {
      throw new Error("PoseLandmarker not loaded");
    }

    // 이미지 데이터를 Canvas로 변환
    const canvas = createImageFromRGBA(
      imageData, // RGBA 데이터 직접 사용
      width,
      height
    );

    // MediaPipe 추론 실행 - 단조 증가하는 타임스탬프 사용
    const timestamp = Math.max(lastVideoTimestamp + 1, performance.now());
    lastVideoTimestamp = timestamp;

    const results = poseLandmarker.detectForVideo(canvas, timestamp);

    // 결과를 Flutter 호환 형식으로 변환
    const landmarks = [];
    if (results.landmarks && results.landmarks.length > 0) {
      // 첫 번째 포즈의 랜드마크 사용 (33개 포인트)
      const firstPoseLandmarks = results.landmarks[0];

      for (const landmark of firstPoseLandmarks) {
        landmarks.push({
          x: landmark.x,
          y: landmark.y,
          z: landmark.z || 0.0,
          visibility: landmark.visibility || 0.0,
        });
      }
    }

    // 평균 가시성 계산
    let poseVisibility = 0.0;
    if (landmarks.length > 0) {
      const totalVisibility = landmarks.reduce(
        (sum, landmark) => sum + landmark.visibility,
        0
      );
      poseVisibility = totalVisibility / landmarks.length;
    }

    const detectionResult = JSON.stringify({
      success: true,
      result: {
        landmarks: landmarks,
        visibility: poseVisibility,
        detected: landmarks.length > 0,
        validLandmarks: landmarks.length,
      },
    });

    // 결과를 전역 변수에 저장 (Flutter에서 읽을 수 있도록)
    window.lastDetectionResult = detectionResult;

    return detectionResult;
  } catch (error) {
    const errorResult = JSON.stringify({
      success: false,
      error: error.message,
    });

    // 에러 결과도 전역 변수에 저장
    window.lastDetectionResult = errorResult;

    return errorResult;
  }
}

/**
 * 웹 카메라 비디오 엘리먼트 찾기 및 설정
 */
function setupWebCamera() {
  try {
    // Flutter 카메라 플러그인이 생성한 video 엘리먼트 찾기
    const videos = document.querySelectorAll("video");

    for (let i = 0; i < videos.length; i++) {
      const video = videos[i];

      if (video.srcObject && video.readyState >= 2) {
        videoElement = video;
        break;
      }
    }

    if (!videoElement) {
      return false;
    }

    // 캡처용 Canvas 생성
    if (!captureCanvas) {
      captureCanvas = document.createElement("canvas");
    }

    return true;
  } catch (error) {
    return false;
  }
}

/**
 * 최적화된 비디오 프레임 캡처 (메모리 효율적)
 */
function captureVideoFrameOptimized() {
  try {
    if (!videoElement || !captureCanvas) {
      if (!setupWebCamera()) {
        return null;
      }
    }

    // 비디오가 준비되지 않았으면 null 반환
    if (videoElement.readyState < 2) {
      return null;
    }

    // Canvas 크기를 비디오 크기에 맞춤 (해상도 최적화)
    const width = Math.min(
      videoElement.videoWidth || videoElement.clientWidth,
      640
    ); // 최대 640px
    const height = Math.min(
      videoElement.videoHeight || videoElement.clientHeight,
      480
    ); // 최대 480px

    if (width === 0 || height === 0) {
      return null;
    }

    // Canvas 크기가 변경된 경우에만 업데이트
    if (captureCanvas.width !== width || captureCanvas.height !== height) {
      captureCanvas.width = width;
      captureCanvas.height = height;
    }

    // 비디오 프레임을 Canvas에 그리기
    const ctx = captureCanvas.getContext("2d");
    ctx.drawImage(videoElement, 0, 0, width, height);

    // ImageData 추출 (재사용 가능한 방식)
    const imageData = ctx.getImageData(0, 0, width, height);

    return {
      width: width,
      height: height,
      data: imageData.data, // Uint8ClampedArray를 직접 전달
    };
  } catch (error) {
    return null;
  }
}

/**
 * 웹 카메라에서 현재 프레임 캡처 (기존 호환성 유지)
 */
function captureVideoFrame() {
  try {
    // 프레임 캡처 throttling 제거 - 매번 캡처 허용
    // const currentTime = Date.now();
    // if (currentTime - lastFrameTime < FRAME_INTERVAL) {
    //   console.log("⏸️ Throttling frame capture, elapsed:", currentTime - lastFrameTime);
    //   return null; // 너무 빈번한 캡처 방지
    // }
    // lastFrameTime = currentTime;

    if (!videoElement || !captureCanvas) {
      if (!setupWebCamera()) {
        return null;
      }
    }

    // 비디오가 준비되지 않았으면 null 반환
    if (videoElement.readyState < 2) {
      return null;
    }

    // Canvas 크기를 비디오 크기에 맞춤
    const width = videoElement.videoWidth || videoElement.clientWidth;
    const height = videoElement.videoHeight || videoElement.clientHeight;

    if (width === 0 || height === 0) {
      return null;
    }

    captureCanvas.width = width;
    captureCanvas.height = height;

    // 비디오 프레임을 Canvas에 그리기
    const ctx = captureCanvas.getContext("2d");
    ctx.drawImage(videoElement, 0, 0, width, height);

    // ImageData 추출
    const imageData = ctx.getImageData(0, 0, width, height);

    return {
      width: width,
      height: height,
      data: imageData.data,
    };
  } catch (error) {
    return null;
  }
}

/**
 * frameData를 MediaPipe용 grayscale로 변환
 */
function convertToGrayscale(frameData) {
  // frameData는 {width, height, data} 형태의 객체
  const rgbaData = frameData.data;
  const grayscaleData = new Uint8Array(frameData.width * frameData.height);

  for (let i = 0; i < rgbaData.length; i += 4) {
    // RGB to grayscale using luminance formula
    const gray = Math.round(
      0.299 * rgbaData[i] + // R
        0.587 * rgbaData[i + 1] + // G
        0.114 * rgbaData[i + 2] // B
    );
    grayscaleData[i / 4] = gray;
  }

  return grayscaleData;
}

/**
 * 최적화된 실시간 포즈 감지 시작
 */
function startOptimizedPoseDetection() {
  try {
    if (!setupWebCamera()) {
      return false;
    }

    // Web Worker가 준비되지 않았으면 초기화
    if (!mediaWorker) {
      if (!initializeWebWorker()) {
        return false;
      }
    }

    startOptimizedFrameProcessing();
    return true;
  } catch (error) {
    console.error("Failed to start optimized pose detection:", error);
    return false;
  }
}

/**
 * 최적화된 실시간 포즈 감지 중단
 */
function stopOptimizedPoseDetection() {
  stopOptimizedFrameProcessing();
}

/**
 * 최적화된 포즈 감지 결과 가져오기 (캐시 사용)
 */
function getOptimizedDetectionResult() {
  if (lastResultCache) {
    return JSON.stringify(lastResultCache);
  }

  // 빈 결과 반환
  return JSON.stringify({
    success: true,
    result: {
      landmarks: [],
      detected: false,
      visibility: 0.0,
      validLandmarks: 0,
    },
  });
}

/**
 * MediaPipe 성능 통계 가져오기
 */
function getPerformanceStats() {
  if (mediaWorker) {
    mediaWorker.postMessage({ type: "get_stats" });
  }
  return window.mediaPipePerformance || {};
}

/**
 * 적응형 품질 설정 업데이트
 */
function updateAdaptiveConfig(config) {
  if (mediaWorker) {
    mediaWorker.postMessage({
      type: "update_config",
      data: config,
    });
  }
}

/**
 * 리소스 정리
 */
function disposeMediaPipe() {
  try {
    // PoseLandmarker 리소스 정리
    if (poseLandmarker) {
      poseLandmarker.close();
      poseLandmarker = null;
    }

    // Vision 리소스 정리
    if (vision) {
      try {
        vision.close();
      } catch (e) {
        // 무시
      }
      vision = null;
    }

    // 웹 카메라 리소스 정리
    videoElement = null;
    captureCanvas = null;
    if (reusableCanvas) {
      reusableCanvas = null;
    }
    lastVideoTimestamp = 1;
    lastFrameTime = 0;

    // 전역 상태 정리
    window.lastDetectionResult = null;
    window.visionInitialized = false;
    window.vision = null;
    window.poseLandmarkerLoaded = false;
    window.poseLandmarkerInstance = null;

    // Web Worker 정리
    if (mediaWorker) {
      mediaWorker.postMessage({ type: "dispose" });
      mediaWorker.terminate();
      mediaWorker = null;
    }

    // 애니메이션 프레임 정리
    if (animationFrameId) {
      cancelAnimationFrame(animationFrameId);
      animationFrameId = null;
    }

    // 캐시 및 상태 정리
    lastResultCache = null;
    isProcessingFrame = false;
    frameQueue = [];

    // 성능 통계 정리
    processingStats = {
      frameCount: 0,
      droppedFrames: 0,
      avgFps: 0,
      lastStatsTime: performance.now(),
    };

    // 가베지 콜렉션 강제 수행
    if (typeof window.gc === "function") {
      window.gc();
    }
  } catch (error) {}
}

/**
 * 콜백 방식 래퍼 함수들 (Flutter dart:js와의 호환성을 위해)
 */

function initializeMediaPipeVisionWithCallback(successCallback, errorCallback) {
  initializeMediaPipeVision()
    .then((result) => successCallback(result))
    .catch((error) => errorCallback(error.message || error.toString()));
}

function loadHandLandmarkerWithCallback(successCallback, errorCallback) {
  loadHandLandmarker()
    .then((result) => successCallback(result))
    .catch((error) => errorCallback(error.message || error.toString()));
}

function loadGestureRecognizerWithCallback(successCallback, errorCallback) {
  loadGestureRecognizer()
    .then((result) => successCallback(result))
    .catch((error) => errorCallback(error.message || error.toString()));
}

/**
 * 비디오에서 직접 포즈 랜드마크 감지 (대안 방법)
 */
function detectPoseLandmarksFromVideo() {
  try {
    // 비디오 프레임 캡처
    const frameData = captureVideoFrame();
    if (!frameData) {
      return JSON.stringify({
        success: true,
        result: {
          landmarks: [],
          detected: false,
          visibility: 0.0,
          validLandmarks: 0,
        },
      });
    }

    // PoseLandmarker가 로드되지 않았다면 빈 결과 반환
    if (!poseLandmarker) {
      return JSON.stringify({
        success: true,
        result: {
          landmarks: [],
          detected: false,
          visibility: 0.0,
          validLandmarks: 0,
        },
      });
    }

    // RGBA 데이터를 직접 사용 (grayscale 변환 생략)
    return detectPoseLandmarksSync(
      frameData.data,
      frameData.width,
      frameData.height
    );
  } catch (error) {
    return JSON.stringify({
      success: false,
      error: error.message,
    });
  }
}

// Flutter에서 접근 가능하도록 전역 함수로 노출
window.initializeMediaPipeVision = initializeMediaPipeVision;
window.initializeMediaPipeVisionSync = initializeMediaPipeVisionSync;
window.initializeMediaPipeVisionFallback = initializeMediaPipeVisionFallback;
window.loadPoseLandmarker = loadPoseLandmarker;
window.detectPoseLandmarksSync = detectPoseLandmarksSync;
window.detectPoseLandmarksFromVideo = detectPoseLandmarksFromVideo;
window.disposeMediaPipe = disposeMediaPipe;

// 웹 카메라 관련 함수들
window.setupWebCamera = setupWebCamera;
window.captureVideoFrame = captureVideoFrame;
window.captureVideoFrameOptimized = captureVideoFrameOptimized;
window.convertToGrayscale = convertToGrayscale;

// 최적화된 함수들
window.initializeWebWorker = initializeWebWorker;
window.startOptimizedPoseDetection = startOptimizedPoseDetection;
window.stopOptimizedPoseDetection = stopOptimizedPoseDetection;
window.getOptimizedDetectionResult = getOptimizedDetectionResult;
window.getPerformanceStats = getPerformanceStats;
window.updateAdaptiveConfig = updateAdaptiveConfig;

// 콜백 방식 함수들도 노출
window.initializeMediaPipeVisionWithCallback =
  initializeMediaPipeVisionWithCallback;
window.loadHandLandmarkerWithCallback = loadHandLandmarkerWithCallback;
window.loadGestureRecognizerWithCallback = loadGestureRecognizerWithCallback;
