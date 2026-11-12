// recorder.swift — records two separate tracks: system audio (the others) and microphone (you).
// System audio comes from a Core Audio process tap (macOS 14.2+): no virtual audio drivers.
// Usage: CallRecorder <output-folder> [--tap=device|global]
// Stops on SIGINT/SIGTERM and writes system.wav + mic.wav (+ recorder.log).
//
// The `rec` script reads some of the log lines below (microphone, "system audio capture
// active", the level meter, "stopped after"). Keep their wording in sync with `rec`.

import Foundation
import AppKit
import AVFoundation
import CoreAudio
import AudioToolbox

// ─────────────────────────────────────────── helpers

var logFile: FileHandle? = nil
func log(_ s: String) {
    let line = "• " + s + "\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    logFile?.write(line.data(using: .utf8)!)
}

func fail(_ s: String) -> Never {
    let line = "ERROR: " + s + "\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    logFile?.write(line.data(using: .utf8)!)
    exit(1)
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr {
        var code = status.bigEndian
        let fourcc = withUnsafeBytes(of: &code) { raw -> String in
            let chars = raw.map { Character(UnicodeScalar($0)) }
            return chars.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " } ? String(chars) : ""
        }
        fail("\(what) → status \(status)\(fourcc.isEmpty ? "" : " '\(fourcc)'")")
    }
}

// ─────────────────────────────────────────── WAV writer (16-bit PCM)

final class WavWriter {
    private let handle: FileHandle
    private let sampleRate: Double
    private let channels: Int
    private var frames: Int = 0
    private let lock = NSLock()
    private(set) var peak: Float = 0

    init(url: URL, sampleRate: Double, channels: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        self.sampleRate = sampleRate
        self.channels = channels
        handle.write(Data(count: 44)) // placeholder header, rewritten on close
    }

    /// Takes float32 samples, interleaved or planar.
    func write(floatBuffers: [UnsafePointer<Float>], framesPerBuffer: Int, interleaved: Bool) {
        guard framesPerBuffer > 0, !floatBuffers.isEmpty else { return }
        var out = [Int16](repeating: 0, count: framesPerBuffer * channels)
        var localPeak: Float = 0

        if interleaved {
            let src = floatBuffers[0]
            for i in 0..<(framesPerBuffer * channels) {
                let v = src[i]
                localPeak = max(localPeak, abs(v))
                out[i] = Int16(max(-1, min(1, v)) * 32767)
            }
        } else {
            for ch in 0..<channels {
                let src = floatBuffers[min(ch, floatBuffers.count - 1)]
                for f in 0..<framesPerBuffer {
                    let v = src[f]
                    localPeak = max(localPeak, abs(v))
                    out[f * channels + ch] = Int16(max(-1, min(1, v)) * 32767)
                }
            }
        }

        lock.lock()
        peak = max(peak, localPeak)
        frames += framesPerBuffer
        lock.unlock()
        out.withUnsafeBytes { handle.write(Data($0)) }
    }

    func resetPeak() -> Float {
        lock.lock(); let p = peak; peak = 0; lock.unlock(); return p
    }

    var duration: Double { Double(frames) / sampleRate }

    func close() {
        lock.lock(); let n = frames; lock.unlock()
        let dataBytes = n * channels * 2
        var h = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        h.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + dataBytes))
        h.append("WAVE".data(using: .ascii)!)
        h.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate) * UInt32(channels) * 2)
        u16(UInt16(channels * 2)); u16(16)
        h.append("data".data(using: .ascii)!); u32(UInt32(dataBytes))
        try? handle.seek(toOffset: 0)
        handle.write(h)
        try? handle.close()
    }
}

// ─────────────────────────────────────────── Core Audio: output device

func audioProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      default def: T) -> T {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    var value = def
    var size = UInt32(MemoryLayout<T>.size)
    let st = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    return st == noErr ? value : def
}

func deviceUID(_ device: AudioObjectID) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var uid: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let st = withUnsafeMutablePointer(to: &uid) {
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
    }
    guard st == noErr, let uid else { return nil }
    return uid as String
}

func tapUID(_ tap: AudioObjectID) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var uid: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let st = withUnsafeMutablePointer(to: &uid) {
        AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, $0)
    }
    guard st == noErr, let uid else { return nil }
    return uid as String
}

func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let st = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
    return st == noErr ? asbd : nil
}

// ─────────────────────────────────────────── main

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: CallRecorder <output-folder> [--tap=device|global]") }
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
// The tap strategy is chosen at runtime: changing it must not need a rebuild
// (every build changes the ad-hoc signature and macOS asks for consent again).
let tapArg = args.dropFirst(2).first(where: { $0.hasPrefix("--tap=") })?
    .replacingOccurrences(of: "--tap=", with: "") ?? "device"
let strategy = (tapArg == "global" || tapArg == "globale") ? "global" : "device"
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let logURL = outDir.appendingPathComponent("recorder.log")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
logFile = try? FileHandle(forWritingTo: logURL)

let systemURL = outDir.appendingPathComponent("system.wav")
let micURL = outDir.appendingPathComponent("mic.wav")

// ── 0. The application must exist before asking for any permission:
// it is the context in which macOS draws the consent dialogs.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)

// ── 1. Microphone: ask for permission WITHOUT blocking.
// If we waited for the dialog, the system-audio tap would never start
// and macOS would never ask for the second permission.
var micWriter: WavWriter? = nil
let engine = AVAudioEngine()
let micLock = NSLock()

func startMicrophone() {
    let input = engine.inputNode
    let fmt = input.outputFormat(forBus: 0)
    guard fmt.sampleRate > 0 else { log("microphone not started: invalid format"); return }
    guard let w = try? WavWriter(url: micURL, sampleRate: fmt.sampleRate,
                                 channels: Int(fmt.channelCount)) else {
        log("microphone not started: cannot create mic.wav"); return
    }
    micLock.lock(); micWriter = w; micLock.unlock()
    log("microphone: \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) channels")
    input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buffer, _ in
        guard let ch = buffer.floatChannelData else { return }
        var ptrs: [UnsafePointer<Float>] = []
        for i in 0..<Int(buffer.format.channelCount) { ptrs.append(UnsafePointer(ch[i])) }
        w.write(floatBuffers: ptrs, framesPerBuffer: Int(buffer.frameLength), interleaved: false)
    }
    do { try engine.start() } catch {
        log("microphone not started: \(error.localizedDescription)")
        micLock.lock(); micWriter = nil; micLock.unlock()
    }
}

switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
    startMicrophone()
case .notDetermined:
    log("asking for microphone permission (macOS dialog)…")
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        if granted { DispatchQueue.main.async { startMicrophone() } }
        else { log("microphone denied: recording system audio only") }
    }
default:
    log("microphone denied: recording system audio only")
    log("  System Settings ▸ Privacy & Security ▸ Microphone")
}

// ── 2. Tap on system audio, excluding ourselves
let myPID = ProcessInfo.processInfo.processIdentifier
var myAudioObject = AudioObjectID(kAudioObjectUnknown)
do {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var pid = myPID
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                   UInt32(MemoryLayout<pid_t>.size), &pid, &size, &myAudioObject)
}

let excluded: [AudioObjectID] =
    myAudioObject == AudioObjectID(kAudioObjectUnknown) ? [] : [myAudioObject]

let outputDevice = audioProperty(AudioObjectID(kAudioObjectSystemObject),
                                 kAudioHardwarePropertyDefaultOutputDevice,
                                 default: AudioObjectID(kAudioObjectUnknown))
guard outputDevice != AudioObjectID(kAudioObjectUnknown),
      let outUID = deviceUID(outputDevice) else { fail("no audio output device") }
log("default output: \(outUID)")

let tapDesc: CATapDescription
switch strategy {
case "global":
    // global tap, not tied to a device
    tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
default:
    // tap on stream 0 of the output device in use
    tapDesc = CATapDescription(__excludingProcesses: excluded.map { NSNumber(value: $0) },
                               andDeviceUID: outUID, withStream: 0)
}
log("tap strategy: \(strategy)")
tapDesc.name = "Call Recorder"
tapDesc.isPrivate = true
tapDesc.muteBehavior = CATapMuteBehavior.unmuted

var tapID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(tapDesc, &tapID), "creating the system-audio tap")
guard let tapUIDString = tapUID(tapID) else { fail("cannot read the tap UID") }
guard let asbd = tapFormat(tapID) else { fail("cannot read the tap format") }

let sysRate = asbd.mSampleRate
let sysChannels = Int(asbd.mChannelsPerFrame)
let sysInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
log("system audio: \(Int(sysRate)) Hz, \(sysChannels) channels")

// ── 3. Private aggregate device that exposes the tap as an input
let aggUID = "call-rec-transcript.aggregate." + UUID().uuidString
let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Call Recorder",
    kAudioAggregateDeviceUIDKey: aggUID,
    kAudioAggregateDeviceMainSubDeviceKey: outUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
    kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapDriftCompensationKey: true,
        kAudioSubTapUIDKey: tapUIDString
    ]]
]

var aggID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID),
      "creating the aggregate device")

// ── 3b. Diagnostics: does the aggregate really have an input?
func inputStreamInfo(_ dev: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                          mScope: kAudioObjectPropertyScopeInput,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else {
        return "no input stream"
    }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else {
        return "reading the streams failed"
    }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    let chans = abl.map { Int($0.mNumberChannels) }
    return "\(abl.count) buffers, channels \(chans)"
}
log("aggregate input: " + inputStreamInfo(aggID))

// ── 4. Output file
let sysWriter = try WavWriter(url: systemURL, sampleRate: sysRate, channels: sysChannels)

var procID: AudioDeviceIOProcID?
let ioQueue = DispatchQueue(label: "recorder.io")
let cbCount = NSMutableArray(object: 0)
let ioBlock: AudioDeviceIOBlock = {
    _, inInputData, _, _, _ in
    cbCount[0] = (cbCount[0] as! Int) + 1
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    guard abl.count > 0 else { return }
    var pointers: [UnsafePointer<Float>] = []
    var frames = 0
    for buf in abl {
        guard let data = buf.mData else { continue }
        pointers.append(UnsafePointer(data.assumingMemoryBound(to: Float.self)))
        let ch = sysInterleaved ? sysChannels : 1
        frames = Int(buf.mDataByteSize) / (4 * ch)
    }
    guard !pointers.isEmpty, frames > 0 else { return }
    sysWriter.write(floatBuffers: pointers, framesPerBuffer: frames, interleaved: sysInterleaved)
}

// Creating the IO proc and starting the device must happen in the same block and in this
// order: starting the device without a registered IO proc captures nothing.
// On first run AudioDeviceCreateIOProcIDWithBlock hangs until the permission dialog is
// answered, so it runs on a background thread: the app stays alive and can say so.
DispatchQueue.global(qos: .userInitiated).async {
    check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue, ioBlock),
          "creating the IO proc")
    check(AudioDeviceStart(aggID, procID), "starting system-audio capture")
    log("system audio capture active")
}

// ── 5. Run until stopped
func shutDown() {
    AudioDeviceStop(aggID, procID)
    if let procID { AudioDeviceDestroyIOProcID(aggID, procID) }
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
    micLock.lock(); let mw = micWriter; micLock.unlock()
    if mw != nil { engine.stop() }
    usleep(200_000)
    sysWriter.close()
    mw?.close()
    let d = sysWriter.duration
    log(String(format: "stopped after %.1f s", d))
    print("DURATION=\(String(format: "%.1f", d))")
    exit(0)
}

let signalQueue = DispatchQueue(label: "recorder.signals")
for sig in [SIGINT, SIGTERM] { signal(sig, SIG_IGN) }
let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    let s = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    s.setEventHandler { shutDown() }
    s.resume()
    return s
}
_ = sources

let started = Date()
log("recording started — Ctrl-C to stop")

// Level meter, so you can see right away whether it is picking anything up
let meter = DispatchSource.makeTimerSource(queue: .main)
meter.schedule(deadline: .now() + 2, repeating: 2)
var warned = false
meter.setEventHandler {
    if !warned, sysWriter.duration == 0, ((cbCount[0] as? Int) ?? 0) == 0,
       Date().timeIntervalSince(started) > 10 {
        warned = true
        log("")
        log("macOS has not yet authorized system-audio capture.")
        log("If there is a dialog on screen, allow it. Otherwise:")
        log("System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording ▸ «Call Recorder»")
        log("")
    }
    func dbfs(_ p: Float) -> String {
        p < 0.0001 ? "   silence" : String(format: "%7.1f dB", 20 * log10(p))
    }
    let s = dbfs(sysWriter.resetPeak())
    micLock.lock(); let mwm = micWriter; micLock.unlock()
    let m = mwm.map { dbfs($0.resetPeak()) } ?? "   waiting"
    log(String(format: "%5.0fs  system %@   mic %@  [callback: %d]",
               sysWriter.duration, s, m, (cbCount[0] as? Int) ?? -1))
}
meter.resume()

app.run()
