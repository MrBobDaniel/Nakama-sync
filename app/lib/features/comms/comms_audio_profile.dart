import 'package:equatable/equatable.dart';

enum CommsAudioCodec {
  pcm16,
  opus;

  String get wireValue => switch (this) {
    CommsAudioCodec.pcm16 => 'pcm16',
    CommsAudioCodec.opus => 'opus',
  };
}

class CommsAudioProfile extends Equatable {
  const CommsAudioProfile({
    required this.id,
    required this.label,
    required this.description,
    required this.codec,
    required this.supportedCodecs,
    required this.sampleRate,
    required this.supportedSampleRates,
    required this.frameDurationMs,
    required this.transportVersion,
    required this.isPreferredDefault,
  });

  final String id;
  final String label;
  final String description;
  final CommsAudioCodec codec;
  final List<CommsAudioCodec> supportedCodecs;
  final int sampleRate;
  final List<int> supportedSampleRates;
  final int frameDurationMs;
  final int transportVersion;
  final bool isPreferredDefault;

  String get codecWireValue => codec.wireValue;
  List<String> get supportedCodecWireValues =>
      supportedCodecs.map((codec) => codec.wireValue).toList(growable: false);

  static const voice = CommsAudioProfile(
    id: 'voice',
    label: 'Voice',
    description: 'Lower bandwidth and battery use for speech-first rooms.',
    codec: CommsAudioCodec.pcm16,
    supportedCodecs: [CommsAudioCodec.pcm16],
    sampleRate: 16000,
    supportedSampleRates: [16000],
    frameDurationMs: 20,
    transportVersion: 1,
    isPreferredDefault: false,
  );

  static const balanced = CommsAudioProfile(
    id: 'balanced',
    label: 'Balanced',
    description: 'Recommended default with clearer voice at moderate cost.',
    codec: CommsAudioCodec.pcm16,
    supportedCodecs: [CommsAudioCodec.pcm16],
    sampleRate: 24000,
    supportedSampleRates: [24000],
    frameDurationMs: 20,
    transportVersion: 1,
    isPreferredDefault: true,
  );

  static const highQuality = CommsAudioProfile(
    id: 'high_quality',
    label: 'High quality',
    description: 'Higher fidelity with more bandwidth and battery usage.',
    codec: CommsAudioCodec.pcm16,
    supportedCodecs: [CommsAudioCodec.pcm16],
    sampleRate: 48000,
    supportedSampleRates: [48000],
    frameDurationMs: 20,
    transportVersion: 1,
    isPreferredDefault: false,
  );

  static const List<CommsAudioProfile> values = [
    voice,
    balanced,
    highQuality,
  ];

  static const CommsAudioProfile preferredDefault = balanced;

  static CommsAudioProfile fromId(String? id) {
    for (final profile in values) {
      if (profile.id == id) {
        return profile;
      }
    }
    return preferredDefault;
  }

  @override
  List<Object?> get props => [
    id,
    label,
    description,
    codec,
    supportedCodecs,
    sampleRate,
    supportedSampleRates,
    frameDurationMs,
    transportVersion,
    isPreferredDefault,
  ];
}
