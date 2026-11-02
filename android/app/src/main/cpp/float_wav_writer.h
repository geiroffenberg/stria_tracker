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

// Streams stereo IEEE-float WAV without clipping or buffering an entire song.
class FloatWavWriter {
public:
    FloatWavWriter(const std::string& path, int sampleRate) : mSampleRate(sampleRate) {
        mFile.exceptions(std::ios::failbit | std::ios::badbit);
        mFile.open(path, std::ios::binary | std::ios::trunc);
        writeHeader(0);
    }

    void append(const float* left, const float* right, int frames, float firstGain = 1.0f,
                float gainStep = 0.0f) {
        if (mFrames + frames > (std::numeric_limits<uint32_t>::max() - 48u) / 8u) {
            throw std::runtime_error("Stem exceeds the WAV file size limit");
        }
        mBytes.resize(static_cast<size_t>(frames) * 8);
        for (int i = 0; i < frames; ++i) {
            const float gain = std::max(0.0f, firstGain + i * gainStep);
            for (int ch = 0; ch < 2; ++ch) {
                const float value = (ch == 0 ? left[i] : right[i]) * gain;
                if (!std::isfinite(value)) {
                    throw std::runtime_error("Non-finite audio detected while exporting stems");
                }
                uint32_t bits;
                static_assert(sizeof(bits) == sizeof(value));
                std::memcpy(&bits, &value, sizeof(bits));
                for (int b = 0; b < 4; ++b) {
                    mBytes[static_cast<size_t>(i) * 8 + ch * 4 + b] =
                        static_cast<char>((bits >> (b * 8)) & 0xff);
                }
            }
        }
        mFile.write(mBytes.data(), static_cast<std::streamsize>(mBytes.size()));
        mFrames += frames;
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
        mFile.write("RIFF", 4); u32(48u + frames * 8u);
        mFile.write("WAVEfmt ", 8); u32(16);
        mFile.write("\x03\x00\x02\x00", 4); // IEEE float, stereo
        u32(mSampleRate); u32(mSampleRate * 8);
        mFile.write("\x08\x00\x20\x00", 4); // block alignment, 32 bits
        mFile.write("fact", 4); u32(4); u32(frames);
        mFile.write("data", 4); u32(frames * 8u);
    }

    std::ofstream mFile;
    int mSampleRate;
    uint64_t mFrames = 0;
    std::vector<char> mBytes;
};
