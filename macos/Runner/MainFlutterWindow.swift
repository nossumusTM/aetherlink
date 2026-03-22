import Cocoa
import FlutterMacOS
import AVFoundation

class MainFlutterWindow: NSWindow {
  private var nativeMacosRecorder: NativeMacosRecorder?
  private var nativePermissionBridge: NativePermissionBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    let registrar = flutterViewController.registrar(forPlugin: "NativeMacosRecorder")
    let recorderChannel = FlutterMethodChannel(
      name: "sputni/native_recording",
      binaryMessenger: registrar.messenger
    )
    let recorder = NativeMacosRecorder()
    recorderChannel.setMethodCallHandler(recorder.handle)
    nativeMacosRecorder = recorder

    let permissionChannel = FlutterMethodChannel(
      name: "sputni/permissions",
      binaryMessenger: registrar.messenger
    )
    let permissionBridge = NativePermissionBridge()
    permissionChannel.setMethodCallHandler(permissionBridge.handle)
    nativePermissionBridge = permissionBridge

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}

final class NativePermissionBridge: NSObject {
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestMicrophoneAccess":
      requestMicrophoneAccess(result: result)
    case "openMicrophoneSettings":
      openMicrophoneSettings(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestMicrophoneAccess(result: @escaping FlutterResult) {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    switch status {
    case .authorized:
      result(true)
    case .denied, .restricted:
      result(false)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async {
          result(granted)
        }
      }
    @unknown default:
      result(false)
    }
  }

  private func openMicrophoneSettings(result: @escaping FlutterResult) {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
      )
    else {
      result(false)
      return
    }

    let opened = NSWorkspace.shared.open(url)
    result(opened)
  }
}

final class NativeMacosRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
  private let sessionQueue = DispatchQueue(label: "com.sputni.native_macos_recorder")
  private var captureSession: AVCaptureSession?
  private var movieOutput: AVCaptureMovieFileOutput?
  private var pendingStopResult: FlutterResult?
  private var isRecording = false

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(true)
    case "startRecording":
      startRecording(call.arguments, result: result)
    case "stopRecording":
      stopRecording(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startRecording(_ arguments: Any?, result: @escaping FlutterResult) {
    guard !isRecording else {
      result(
        FlutterError(
          code: "already_recording",
          message: "Native recorder is already active.",
          details: nil
        )
      )
      return
    }

    guard
      let args = arguments as? [String: Any],
      let path = args["path"] as? String
    else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "Missing recording path.",
          details: nil
        )
      )
      return
    }

    let includeAudio = (args["includeAudio"] as? Bool) ?? false
    let outputUrl = URL(fileURLWithPath: path)

    sessionQueue.async {
      do {
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let videoDevice = AVCaptureDevice.default(for: .video) else {
          throw RecorderError.cameraUnavailable
        }

        let videoInput = try AVCaptureDeviceInput(device: videoDevice)
        guard session.canAddInput(videoInput) else {
          throw RecorderError.unableToAddVideoInput
        }
        session.addInput(videoInput)

        if includeAudio {
          guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            throw RecorderError.microphoneUnavailable
          }

          let audioInput = try AVCaptureDeviceInput(device: audioDevice)
          guard session.canAddInput(audioInput) else {
            throw RecorderError.unableToAddAudioInput
          }
          session.addInput(audioInput)
        }

        let output = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else {
          throw RecorderError.unableToAddFileOutput
        }
        session.addOutput(output)
        session.commitConfiguration()

        self.captureSession = session
        self.movieOutput = output
        self.isRecording = true

        session.startRunning()
        output.startRecording(to: outputUrl, recordingDelegate: self)

        DispatchQueue.main.async {
          result(nil)
        }
      } catch {
        self.cleanupSession()
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "start_failed",
              message: self.errorMessage(for: error),
              details: nil
            )
          )
        }
      }
    }
  }

  private func stopRecording(result: @escaping FlutterResult) {
    sessionQueue.async {
      guard self.isRecording, let output = self.movieOutput else {
        DispatchQueue.main.async {
          result(nil)
        }
        return
      }

      self.pendingStopResult = result
      output.stopRecording()
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: Error?
  ) {
    let stopResult = pendingStopResult
    pendingStopResult = nil
    let completion: FlutterResult = stopResult ?? { _ in }

    if let error {
      let message = errorMessage(for: error)
      cleanupSession()
      DispatchQueue.main.async {
        completion(
          FlutterError(
            code: "stop_failed",
            message: message,
            details: nil
          )
        )
      }
      return
    }

    cleanupSession()
    DispatchQueue.main.async {
      completion(outputFileURL.path)
    }
  }

  private func cleanupSession() {
    if let output = movieOutput, output.isRecording {
      output.stopRecording()
    }

    captureSession?.stopRunning()
    movieOutput = nil
    captureSession = nil
    isRecording = false
  }

  private func errorMessage(for error: Error) -> String {
    if let recorderError = error as? RecorderError {
      return recorderError.localizedDescription
    }

    return error.localizedDescription
  }
}

private enum RecorderError: LocalizedError {
  case cameraUnavailable
  case microphoneUnavailable
  case unableToAddVideoInput
  case unableToAddAudioInput
  case unableToAddFileOutput

  var errorDescription: String? {
    switch self {
    case .cameraUnavailable:
      return "No camera device is available for recording."
    case .microphoneUnavailable:
      return "No microphone device is available for recording."
    case .unableToAddVideoInput:
      return "Unable to attach the camera input to the recorder."
    case .unableToAddAudioInput:
      return "Unable to attach the microphone input to the recorder."
    case .unableToAddFileOutput:
      return "Unable to attach the file output to the recorder."
    }
  }
}
