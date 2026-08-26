// phostor-transcribe -- on-device transcription of one visit's recording.
//
// Reads any container AVFoundation can open (MP4, Ogg, WAV, CAF, M4A), decodes
// it to the format SpeechAnalyzer asks for, and writes the words beside the
// audio. Nothing leaves the machine.
//
// Two files come out of one pass: `visit-NNNN.tsv`, one row per phrase with
// the seconds it spans, and `visit-NNNN.txt`, the same words as prose. The
// .tsv is written first, so a .txt on disk always has a .tsv beside it -- that
// is what lets R tell a transcript made by this version from one made before
// timings existed, and what keeps the .txt.part in-flight marker honest.
//
// WebM is not readable by AVFoundation, whatever its codec: those recordings
// exit `formatUnreadable` and phostor logs it and carries on. This is why the
// app records MP4 or Ogg -- see pickMime() in inst/shiny/app.R.
//
// AVAudioFile cannot be used here. It opens a fragmented MP4 but reports
// length 0 and throws on read, because MediaRecorder leaves the moov duration
// unset. AVURLAsset with PreferPreciseDurationAndTiming scans the fragments
// and gets it right.
//
// Built on first use by ph_transcribe_build(); see R/transcribe.R.

import AVFoundation
import Foundation
import Speech

// Exit codes. R maps these back to a reason string, so they are API.
enum Exit: Int32 {
  case ok = 0
  case usage = 1
  case unavailable = 2       // too old an OS, or no SpeechTranscriber
  case formatUnreadable = 3  // WebM, or a corrupt file
  case noAudio = 4           // opened, but no audio track or no samples
  case locale = 5            // no speech model for this language
  case model = 6             // model download or install failed
  case failed = 7            // transcription itself failed
  case write = 8
}

func warn(_ s: String) {
  FileHandle.standardError.write(Data((s + "\n").utf8))
}

func quit(_ code: Exit, _ message: String? = nil) -> Never {
  if let m = message { warn("phostor-transcribe: " + m) }
  exit(code.rawValue)
}

struct Options {
  var locale = Locale.current
  var out: String?
  var check = false
  var pcm = false
  var input: String?
}

func parse(_ argv: [String]) -> Options {
  var o = Options()
  var i = 0
  while i < argv.count {
    switch argv[i] {
    case "--pcm":
      o.pcm = true
    case "--check":
      o.check = true
    case "--locale":
      i += 1
      guard i < argv.count else { quit(.usage, "--locale needs a value") }
      o.locale = Locale(identifier: argv[i])
    case "--out":
      i += 1
      guard i < argv.count else { quit(.usage, "--out needs a value") }
      o.out = argv[i]
    case "--help", "-h":
      print("""
        usage: phostor-transcribe [--locale LOCALE] --out FILE AUDIO
               phostor-transcribe --pcm --out FILE.wav AUDIO
               phostor-transcribe --check [--locale LOCALE]
        """)
      exit(0)
    default:
      if argv[i].hasPrefix("-") { quit(.usage, "unknown option \(argv[i])") }
      o.input = argv[i]
    }
    i += 1
  }
  return o
}

@available(macOS 26.0, *)
@discardableResult
func ensureModel(_ transcriber: SpeechTranscriber) async -> Bool {
  switch await AssetInventory.status(forModules: [transcriber]) {
  case .installed:
    return true
  case .unsupported:
    return false
  case .supported, .downloading:
    do {
      // nil means another process already installed it between the two calls.
      if let request = try await AssetInventory.assetInstallationRequest(
        supporting: [transcriber])
      {
        try await request.downloadAndInstall()
      }
      return true
    } catch {
      warn("model install failed: \(error.localizedDescription)")
      return false
    }
  @unknown default:
    return false
  }
}

// One CMSampleBuffer's PCM, copied into a buffer the analyzer will take.
//
// The reader is configured to emit exactly `format`, so this copies raw bytes
// and never inspects the sample type. That matters: the analyzer asks for Int16
// here, not Float32, so reaching for floatChannelData would come back nil.
func pcmBuffer(from sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
  let frames = CMSampleBufferGetNumSamples(sample)
  guard frames > 0,
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(frames))
  else { return nil }
  buffer.frameLength = AVAudioFrameCount(frames)

  // Ask how large the buffer list needs to be rather than computing it:
  // a hand-rolled size is rejected with kCMSampleBufferError_ArrayTooSmall.
  var listSize = 0
  guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
    sample,
    bufferListSizeNeededOut: &listSize,
    bufferListOut: nil,
    bufferListSize: 0,
    blockBufferAllocator: nil,
    blockBufferMemoryAllocator: nil,
    flags: 0,
    blockBufferOut: nil) == noErr, listSize > 0
  else { return nil }

  var blockBuffer: CMBlockBuffer?
  let listRaw = UnsafeMutableRawPointer.allocate(
    byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
  defer { listRaw.deallocate() }
  let list = listRaw.assumingMemoryBound(to: AudioBufferList.self)

  let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
    sample,
    bufferListSizeNeededOut: nil,
    bufferListOut: list,
    bufferListSize: listSize,
    blockBufferAllocator: kCFAllocatorDefault,
    blockBufferMemoryAllocator: kCFAllocatorDefault,
    flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
    blockBufferOut: &blockBuffer)
  guard status == noErr else { return nil }

  let src = UnsafeMutableAudioBufferListPointer(list)
  let dst = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
  guard src.count == dst.count else { return nil }
  for i in 0..<src.count {
    guard let from = src[i].mData, let to = dst[i].mData else { return nil }
    let bytes = min(Int(src[i].mDataByteSize), Int(dst[i].mDataByteSize))
    memcpy(to, from, bytes)
    dst[i].mDataByteSize = UInt32(bytes)
  }
  return buffer
}

@available(macOS 26.0, *)
func transcribe(input: URL, out: URL, locale requested: Locale) async -> Exit {
  guard SpeechTranscriber.isAvailable else {
    warn("SpeechTranscriber is not available on this machine")
    return .unavailable
  }

  let asset = AVURLAsset(
    url: input, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
  let tracks: [AVAssetTrack]
  do {
    tracks = try await asset.loadTracks(withMediaType: .audio)
  } catch {
    warn("\(input.lastPathComponent): cannot read this format")
    return .formatUnreadable
  }
  guard let track = tracks.first else {
    warn("\(input.lastPathComponent): no audio track")
    return .noAudio
  }

  guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
    warn("no speech model for \(requested.identifier)")
    return .locale
  }
  let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
  _ = try? await AssetInventory.reserve(locale: locale)
  guard await ensureModel(transcriber) else { return .model }

  guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
    compatibleWith: [transcriber])
  else {
    warn("no audio format compatible with the transcriber")
    return .model
  }

  let reader: AVAssetReader
  let output: AVAssetReaderTrackOutput
  do {
    reader = try AVAssetReader(asset: asset)
    let asbd = format.streamDescription.pointee
    output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: format.sampleRate,
      AVNumberOfChannelsKey: Int(format.channelCount),
      AVLinearPCMBitDepthKey: Int(asbd.mBitsPerChannel),
      AVLinearPCMIsFloatKey: (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
      AVLinearPCMIsBigEndianKey: (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0,
      AVLinearPCMIsNonInterleaved: !format.isInterleaved,
    ])
    guard reader.canAdd(output) else {
      warn("\(input.lastPathComponent): cannot decode this audio")
      return .formatUnreadable
    }
    reader.add(output)
  } catch {
    warn("\(input.lastPathComponent): \(error.localizedDescription)")
    return .formatUnreadable
  }
  guard reader.startReading() else {
    warn("\(input.lastPathComponent): \(reader.error?.localizedDescription ?? "cannot read")")
    return .formatUnreadable
  }

  let analyzer = SpeechAnalyzer(modules: [transcriber])
  let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()

  // Results arrive while the audio is still being fed, so they are collected
  // on their own task; the sequence ends when the analyzer finishes.
  //
  // Each finalized result covers one phrase and carries the range of audio it
  // came from, which is what the app highlights with. Volatile results are not
  // requested (no .volatileResults in the preset), but isFinal is checked
  // anyway: a partial result would otherwise be written as a phrase of its own
  // and repeated when its final arrived.
  let collected = Task { () -> [Phrase] in
    var out: [Phrase] = []
    for try await result in transcriber.results where result.isFinal {
      let words = String(result.text.characters)
      let range = result.range
      out.append(Phrase(start: range.start.seconds,
                        end: range.end.seconds,
                        text: words))
    }
    return out
  }

  let pump = Task { () -> Int in
    var n = 0
    while let sample = output.copyNextSampleBuffer() {
      if let buffer = pcmBuffer(from: sample, format: format) {
        n += Int(buffer.frameLength)
        feed.yield(AnalyzerInput(buffer: buffer))
      }
    }
    feed.finish()
    return n
  }

  let frames: Int
  do {
    _ = try await analyzer.analyzeSequence(stream)
    frames = await pump.value
    try await analyzer.finalizeAndFinishThroughEndOfInput()
  } catch {
    collected.cancel()
    warn("\(input.lastPathComponent): \(error.localizedDescription)")
    return .failed
  }

  if reader.status == .failed {
    collected.cancel()
    warn("\(input.lastPathComponent): \(reader.error?.localizedDescription ?? "read failed")")
    return .formatUnreadable
  }
  guard frames > 0 else {
    collected.cancel()
    warn("\(input.lastPathComponent): no audio samples")
    return .noAudio
  }

  let phrases: [Phrase]
  do {
    phrases = try await collected.value
  } catch {
    warn("\(input.lastPathComponent): \(error.localizedDescription)")
    return .failed
  }

  // Both files are written even when there was no speech: an empty .txt and a
  // header-only .tsv. "Transcribed and silent" has to be distinguishable from
  // "not transcribed yet", or every silent recording is retried for ever.
  //
  // The .tsv goes first. See the note at the top of this file.
  let timed = out.deletingPathExtension().appendingPathExtension("tsv")
  let rows = ["start\tend\ttext"] + phrases.map(\.row)
  if !writeAtomically(rows.joined(separator: "\n") + "\n", to: timed) {
    return .write
  }

  let body = phrases.map(\.text).joined()
    .trimmingCharacters(in: .whitespacesAndNewlines)
  if !writeAtomically(body + "\n", to: out) { return .write }
  return .ok
}

// One phrase of speech, and where in the recording it was said.
struct Phrase {
  let start: Double
  let end: Double
  let text: String

  // A tab or a newline in the text would split the row into the wrong number
  // of fields, so they become spaces -- the same reason phostor refuses them
  // in a path. A non-finite time (an unset CMTime) is written as 0.
  var row: String {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\t", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
    return String(format: "%.3f\t%.3f\t%@", secs(start), secs(end), t)
  }

  private func secs(_ x: Double) -> Double { x.isFinite && x > 0 ? x : 0 }
}

// Written to .part and renamed, so a reader never sees a half-written file and
// phostor can tell "a run is in flight" from "there is a transcript".
func writeAtomically(_ body: String, to out: URL) -> Bool {
  let part = out.appendingPathExtension("part")
  do {
    try body.write(to: part, atomically: true, encoding: .utf8)
    if FileManager.default.fileExists(atPath: out.path) {
      try FileManager.default.removeItem(at: out)
    }
    try FileManager.default.moveItem(at: part, to: out)
  } catch {
    try? FileManager.default.removeItem(at: part)
    warn("cannot write \(out.lastPathComponent): \(error.localizedDescription)")
    return false
  }
  return true
}

// Decode to 16 kHz mono WAV. The same AVAssetReader path the transcriber uses,
// which is the part that knows how to open a fragmented MP4; anything that
// wants the samples rather than the words reads the result of this.
//
// Not gated on macOS 26: this is AVFoundation, not Speech, and R needs it on
// machines that can never transcribe.
func writePCM(input: URL, out: URL) async -> Exit {
  let asset = AVURLAsset(url: input,
    options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
  let tracks: [AVAssetTrack]
  do {
    tracks = try await asset.loadTracks(withMediaType: .audio)
  } catch {
    warn("\(input.lastPathComponent): cannot read this format")
    return .formatUnreadable
  }
  guard let track = tracks.first else {
    warn("\(input.lastPathComponent): no audio track")
    return .noAudio
  }
  let reader: AVAssetReader
  let output: AVAssetReaderTrackOutput
  do {
    reader = try AVAssetReader(asset: asset)
    output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ])
    guard reader.canAdd(output) else {
      warn("\(input.lastPathComponent): cannot decode this audio")
      return .formatUnreadable
    }
    reader.add(output)
  } catch {
    warn("\(input.lastPathComponent): \(error.localizedDescription)")
    return .formatUnreadable
  }
  guard reader.startReading() else {
    warn("\(input.lastPathComponent): \(reader.error?.localizedDescription ?? "cannot read")")
    return .formatUnreadable
  }

  // 16-bit signed, which tuneR::readWave() reads back as integers. Float32
  // would come back on a wildly different scale and every energy threshold
  // downstream would move with it.
  let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                          channels: 1, interleaved: true)!
  var samples = Data()
  var frames = 0
  while let sample = output.copyNextSampleBuffer() {
    guard let buf = pcmBuffer(from: sample, format: fmt),
          let src = buf.int16ChannelData else { continue }
    let n = Int(buf.frameLength)
    frames += n
    samples.append(UnsafeBufferPointer(start: src[0], count: n))
  }
  if reader.status == .failed {
    warn("\(input.lastPathComponent): \(reader.error?.localizedDescription ?? "read failed")")
    return .formatUnreadable
  }
  guard frames > 0 else {
    warn("\(input.lastPathComponent): no audio samples")
    return .noAudio
  }

  // The header is written by hand. AVAudioFile(forWriting:) ignores the .wav
  // extension and produces a CAF, which tuneR refuses -- and an extensible
  // WAVE would be refused too. This is the plain 44-byte canonical form that
  // every reader accepts.
  let part = out.appendingPathExtension("part")
  do {
    try (wavHeader(frames: frames, rate: 16000) + samples).write(to: part)
  } catch {
    warn("cannot write \(out.lastPathComponent): \(error.localizedDescription)")
    return .write
  }
  return writeRename(part, out) ? .ok : .write
}

// Canonical 44-byte RIFF/WAVE header for mono 16-bit PCM.
func wavHeader(frames: Int, rate: Int) -> Data {
  let bytes = frames * 2
  var d = Data()
  func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
  func u32(_ v: Int) { var x = UInt32(v).littleEndian
                       withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
  func u16(_ v: Int) { var x = UInt16(v).littleEndian
                       withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
  str("RIFF"); u32(36 + bytes); str("WAVE")
  str("fmt "); u32(16); u16(1); u16(1)          // PCM, one channel
  u32(rate); u32(rate * 2); u16(2); u16(16)     // byte rate, block align, bits
  str("data"); u32(bytes)
  return d
}

// Rename a finished .part over its destination, so a reader never sees a
// half-written file.
func writeRename(_ part: URL, _ out: URL) -> Bool {
  do {
    if FileManager.default.fileExists(atPath: out.path) {
      try FileManager.default.removeItem(at: out)
    }
    try FileManager.default.moveItem(at: part, to: out)
  } catch {
    try? FileManager.default.removeItem(at: part)
    warn("cannot write \(out.lastPathComponent): \(error.localizedDescription)")
    return false
  }
  return true
}

@available(macOS 26.0, *)
func check(locale requested: Locale) async -> Exit {
  guard SpeechTranscriber.isAvailable else {
    print("available: no")
    return .unavailable
  }
  print("available: yes")
  guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
    print("locale: \(requested.identifier) unsupported")
    return .locale
  }
  print("locale: \(locale.identifier)")
  let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
  _ = try? await AssetInventory.reserve(locale: locale)
  guard await ensureModel(transcriber) else {
    print("model: unavailable")
    return .model
  }
  print("model: installed")
  let installed = await SpeechTranscriber.installedLocales
  print("installed: " + installed.map(\.identifier).sorted().joined(separator: " "))
  return .ok
}

@main
struct PhostorTranscribe {
  static func main() async {
    let options = parse(Array(CommandLine.arguments.dropFirst()))

    // Before the macOS 26 gate on purpose: this is AVFoundation, not Speech,
    // and R needs the samples on machines that can never transcribe.
    if options.pcm {
      guard let input = options.input, let out = options.out else {
        quit(.usage, "usage: phostor-transcribe --pcm --out FILE.wav AUDIO")
      }
      guard FileManager.default.fileExists(atPath: input) else {
        quit(.formatUnreadable, "no such file: \(input)")
      }
      exit(await writePCM(input: URL(fileURLWithPath: input),
                          out: URL(fileURLWithPath: out)).rawValue)
    }

    guard #available(macOS 26.0, *) else {
      quit(.unavailable, "transcription needs macOS 26 or newer")
    }

    if options.check {
      exit(await check(locale: options.locale).rawValue)
    }
    guard let input = options.input, let out = options.out else {
      quit(.usage, "usage: phostor-transcribe [--locale LOCALE] --out FILE AUDIO")
    }
    guard FileManager.default.fileExists(atPath: input) else {
      quit(.formatUnreadable, "no such file: \(input)")
    }
    let code = await transcribe(
      input: URL(fileURLWithPath: input),
      out: URL(fileURLWithPath: out),
      locale: options.locale)
    exit(code.rawValue)
  }
}
