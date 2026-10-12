import 'dart:typed_data';

/// Encodes raw audio samples as a WAV file.
class WavEncoder {
  /// Encode mono 32-bit float samples as a WAV file.
  /// Returns the complete WAV file as bytes.
  static Uint8List encodeWav({
    required List<double> samples,
    required int sampleRate,
    int numChannels = 1,
  }) {
    // 16-bit PCM RIFF/WAVE: 44-byte header followed by the sample data.
    final dataSize = samples.length * 2;
    final byteRate = sampleRate * numChannels * 2;
    final blockAlign = numChannels * 2;

    final out = Uint8List(44 + dataSize);
    final view = ByteData.sublistView(out);
    void tag(int offset, String text) {
      for (int i = 0; i < 4; i++) {
        out[offset + i] = text.codeUnitAt(i);
      }
    }

    tag(0, 'RIFF');
    view.setUint32(4, 36 + dataSize, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    view.setUint32(16, 16, Endian.little); // PCM fmt chunk size
    view.setUint16(20, 1, Endian.little); // PCM
    view.setUint16(22, numChannels, Endian.little);
    view.setUint32(24, sampleRate, Endian.little);
    view.setUint32(28, byteRate, Endian.little);
    view.setUint16(32, blockAlign, Endian.little);
    view.setUint16(34, 16, Endian.little); // bits per sample
    tag(36, 'data');
    view.setUint32(40, dataSize, Endian.little);

    // Clamp to [-1, 1] and convert to signed 16-bit.
    int offset = 44;
    for (int i = 0; i < samples.length; i++) {
      final s = samples[i];
      final v = s.isNaN ? 0.0 : s.clamp(-1.0, 1.0);
      view.setInt16(offset, (v * 32767).toInt(), Endian.little);
      offset += 2;
    }
    return out;
  }
}
