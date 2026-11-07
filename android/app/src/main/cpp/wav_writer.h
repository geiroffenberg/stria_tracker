#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

// Streams stereo WAV in bounded blocks; float stems retain unclipped headroom.
class WavWriter {
public:
    enum class Format { Float32, Pcm16 };

    WavWriter(const std::string& path, int sampleRate, Format format = Format::Float32)
        : mSampleRate(sampleRate), mFormat(format) {
        mFile.exceptions(std::ios::failbit | std::ios::badbit);
        mFile.open(path, std::ios::binary | std::ios::trunc);
        writeHeader(0);
    }

    void append(const float* left, const float* right, int frames, float firstGain = 1.0f,
                float gainStep = 0.0f, int stride = 1) {
        const int frameBytes = mFormat == Format::Float32 ? 8 : 4;
        const int headerBytes = mFormat == Format::Float32 ? 48 : 36;
        if (mFrames + frames > (std::numeric_limits<uint32_t>::max() - headerBytes) / frameBytes) {
            throw std::runtime_error("Export exceeds the WAV file size limit");
        }
        mBytes.resize(static_cast<size_t>(frames) * frameBytes);
        for (int i = 0; i < frames; ++i) {
            const float gain = std::max(0.0f, firstGain + i * gainStep);
            for (int ch = 0; ch < 2; ++ch) {
                const float value = (ch == 0 ? left[i * stride] : right[i * stride]) * gain;
                if (!std::isfinite(value)) {
                    throw std::runtime_error("Non-finite audio detected while exporting WAV");
                }
                uint32_t bits;
                const int sampleBytes = frameBytes / 2;
                if (mFormat == Format::Float32) {
                    static_assert(sizeof(bits) == sizeof(value));
                    std::memcpy(&bits, &value, sizeof(bits));
                } else {
                    // Match Dart's existing clamp, double-precision scale and truncation.
                    bits = static_cast<uint16_t>(static_cast<int16_t>(
                        std::clamp(static_cast<double>(value), -1.0, 1.0) * 32767.0));
                }
                for (int b = 0; b < sampleBytes; ++b) {
                    mBytes[static_cast<size_t>(i) * frameBytes + ch * sampleBytes + b] =
                        static_cast<char>((bits >> (b * 8)) & 0xff);
                }
            }
        }
        mFile.write(mBytes.data(), static_cast<std::streamsize>(mBytes.size()));
        mFrames += frames;
    }

    void appendInterleaved(const float* samples, int frames) {
        append(samples, samples + 1, frames, 1.0f, 0.0f, 2);
    }

    void finish() {
        mFile.seekp(0);
        writeHeader(static_cast<uint32_t>(mFrames));
        mFile.flush();
        mFile.close();
    }

private:
    void u32(uint32_t value) {
        const char bytes[] = {static_cast<char>(value), static_cast<char>(value >> 8),
                              static_cast<char>(value >> 16), static_cast<char>(value >> 24)};
        mFile.write(bytes, sizeof(bytes));
    }

    void writeHeader(uint32_t frames) {
        const bool floats = mFormat == Format::Float32;
        const uint32_t frameBytes = floats ? 8u : 4u;
        mFile.write("RIFF", 4); u32((floats ? 48u : 36u) + frames * frameBytes);
        mFile.write("WAVEfmt ", 8); u32(16);
        mFile.write(floats ? "\x03\x00\x02\x00" : "\x01\x00\x02\x00", 4);
        u32(mSampleRate); u32(mSampleRate * frameBytes);
        mFile.write(floats ? "\x08\x00\x20\x00" : "\x04\x00\x10\x00", 4);
        if (floats) {
            mFile.write("fact", 4); u32(4); u32(frames);
        }
        mFile.write("data", 4); u32(frames * frameBytes);
    }

    std::ofstream mFile;
    int mSampleRate;
    Format mFormat;
    uint64_t mFrames = 0;
    std::vector<char> mBytes;
};
