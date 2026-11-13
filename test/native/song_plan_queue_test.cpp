#include "../../android/app/src/main/cpp/audio_engine.h"

#include <cstdlib>
#include <iostream>
#include <memory>
#include <cmath>

class SongPlanQueueTest {
    static void require(bool condition, const char* message) {
        if (!condition) {
            std::cerr << message << '\n';
            std::exit(1);
        }
    }

    static QueuedPlaybackRow row(int samples) {
        QueuedPlaybackRow result;
        result.lineSamples = samples;
        return result;
    }

    static void pending(AudioEngine& engine, bool end, int samples, int muteMask = 0) {
        engine.beginPendingRows();
        engine.appendPendingRow(row(samples));
        require(engine.configureSongPlanRows(true, {end ? 1 : 0}, {1}, {muteMask}),
                "Pending batch publication failed");
    }

    static std::vector<float> renderMutes(int source, int destination, int mask,
                                          bool liveMute = false, bool otherSolo = false) {
        auto owner = std::make_unique<AudioEngine>();
        auto& engine = *owner;
        engine.setMasterLimiterEnabled(false);
        auto& voice = engine.mVoices[source];
        voice.midiNote = 69;
        voice.currentFreq = voice.targetFreq = 440.0f;
        voice.gain = voice.gainTarget = voice.envLevel = voice.sustainLevel = 1.0f;
        voice.envStage = EnvelopeStage::Sustain;
        voice.noteHeld = true;
        engine.mTrackMute[source] = liveMute;
        engine.mTrackSolo[1] = otherSolo;
        engine.mTrackSendChannel[source] = destination;
        engine.enqueuePlaybackRow(row(64));
        engine.enqueuePlaybackRow(row(64));
        engine.enqueuePlaybackRow(row(6400));
        require(engine.configureSongPlanRows(false, {0, 0, 1}, {1, 1, 1},
                                             {mask, 0, mask}), "Mute publication failed");
        require(engine.primeNextQueuedPlaybackRowLocked(), "Mute first row failed");
        engine.mPlayheadRunning.store(true);
        std::vector<float> audio(192 * 2);
        engine.renderAudio(audio.data(), 192, 48000.0, false);
        require(engine.mTrackMute[source] == liveMute, "Plan overwrote live mute");
        require(engine.mTrackSolo[1] == otherSolo, "Plan overwrote live solo");
        require(voice.noteHeld, "Plan mute killed a voice instead of muting its bus");
        require(engine.mSongPlanMuteMask == mask, "Wrong final mute mask");
        engine.clearQueuedPlaybackRows();
        require(engine.mSongPlanMuteMask == 0, "Clear retained plan mute");
        std::vector<float> afterClear(192 * 2);
        engine.renderAudio(afterClear.data(), 192, 48000.0, false);
        double afterClearEnergy = 0.0;
        for (float sample : afterClear) afterClearEnergy += sample * sample;
        require(liveMute || otherSolo ? afterClearEnergy < 1e-10 : afterClearEnergy > 0.001,
                "Clearing the plan did not restore live mixer audibility");
        return audio;
    }

    static void checkAudioMutes() {
        for (int source : {0, 15}) {
            for (int destination : {0, 2}) {
                const auto reference = renderMutes(source, destination, 0);
                for (int mask : {1 << source, destination == 0 ? 1 << source : 1 << (destination - 1)}) {
                    const auto muted = renderMutes(source, destination, mask);
                    double audibleEnergy = 0.0;
                    for (int frame = 0; frame < 192; ++frame) {
                        for (int channel = 0; channel < 2; ++channel) {
                            const int index = frame * 2 + channel;
                            require(std::isfinite(muted[index]), "Non-finite plan audio");
                            if (frame >= 64 && frame < 128) {
                                require(std::abs(muted[index] - reference[index]) < 1e-7f,
                                        "Unmuted range changed the audio");
                                audibleEnergy += muted[index] * muted[index];
                            } else {
                                require(std::abs(muted[index]) < 1e-7f,
                                        "Plan mute leaked before/after an exact row boundary");
                            }
                        }
                    }
                    require(audibleEnergy > 0.001, "Unmuted step did not sound");
                }
                for (bool solo : {false, true}) {
                    const auto muted = renderMutes(source, destination, 1 << source, !solo, solo);
                    for (float sample : muted) {
                        require(std::abs(sample) < 1e-7f, "Blank plan cell overrode live mute/solo");
                    }
                }
            }
        }
    }

public:
    static void run() {
        // No stream is opened: exercise only row selection and queue boundaries.
        auto owner = std::make_unique<AudioEngine>();
        auto& engine = *owner;
        engine.enqueuePlaybackRow(row(100));
        engine.enqueuePlaybackRow(row(200));
        require(!engine.configureSongPlanRows(false, {1}, {1}, {0}),
                "Mismatched flags were accepted");
        require(!engine.configureSongPlanRows(false, {0, 1}, {1, 0}, {0}),
                "Mismatched mute masks were accepted");
        require(!engine.configureSongPlanRows(false, {0, 1}, {1, 0}, {0, 0x10000}),
                "Out-of-range mute mask was accepted");
        require(!engine.configureSongPlanRows(false, {0, 1}, {1, 0}, {-1, 0}),
                "Negative mute mask was accepted");
        require(engine.configureSongPlanRows(false, {0, 1}, {1, 0}, {0x8001, 0}),
                "Initial batch publication failed");
        engine.setQueuedPlaybackLooping(false);
        pending(engine, false, 300, 4);
        require(engine.primeNextQueuedPlaybackRowLocked(), "First row failed");
        require(engine.mLineSamplesPerRow == 100, "Wrong first row");
        require(engine.mSongPlanMuteMask == 0x8001, "First row lost plan mutes");
        require(engine.primeNextQueuedPlaybackRowLocked(), "Second row failed");
        require(engine.mLineSamplesPerRow == 200, "Wrong second row");
        require(engine.mSongPlanMuteMask == 0, "Next step inherited plan mutes");
        require(!engine.primeNextQueuedPlaybackRowLocked(),
                "Loop OFF played past a plan-end marker");
        require(!engine.consumeSongPlanUnderrun(),
                "Natural plan end was incorrectly reported as an underrun");

        engine.setQueuedPlaybackLooping(true);
        require(engine.primeNextQueuedPlaybackRowLocked(),
                "Loop ON did not chain to the published next batch");
        require(engine.mLineSamplesPerRow == 300, "Wrong chained row");
        require(engine.mSongPlanMuteMask == 4, "Pending batch lost plan mutes");
        require(!engine.primeNextQueuedPlaybackRowLocked(),
                "Missing batch silently replayed old rows");
        require(engine.consumeSongPlanUnderrun(), "Missing batch was not reported");
        require(!engine.consumeSongPlanUnderrun(), "Underrun was not consumed");

        engine.clearQueuedPlaybackRows();
        engine.enqueuePlaybackRow(row(400));
        require(engine.configureSongPlanRows(false, {0}, {1}, {0}),
                "Second plan failed");
        engine.setQueuedPlaybackLooping(false);
        pending(engine, true, 500);
        require(engine.primeNextQueuedPlaybackRowLocked(), "Active row failed");
        require(engine.primeNextQueuedPlaybackRowLocked(),
                "A batch boundary incorrectly required Loop ON");
        require(engine.mLineSamplesPerRow == 500, "Wrong non-loop chained row");
        require(!engine.primeNextQueuedPlaybackRowLocked(), "Final row did not end");

        engine.clearQueuedPlaybackRows();
        engine.enqueuePlaybackRow(row(600));
        require(engine.configureSongPlanRows(false, {0}, {1}, {0}),
                "Publication test setup failed");
        engine.beginPendingRows();
        engine.appendPendingRow(row(700));
        require(engine.primeNextQueuedPlaybackRowLocked(), "Publication first row failed");
        require(!engine.primeNextQueuedPlaybackRowLocked(),
                "An incomplete, unpublished batch became audible");
        require(engine.consumeSongPlanUnderrun(), "Unpublished batch was not reported");

        engine.clearQueuedPlaybackRows();
        engine.enqueuePlaybackRow(row(750));
        engine.enqueuePlaybackRow(row(760));
        require(engine.configureSongPlanRows(false, {1, 0}, {1, 1}, {0, 0}),
                "Mid-batch end marker setup failed");
        require(engine.primeNextQueuedPlaybackRowLocked(), "Mid-batch first row failed");
        require(!engine.primeNextQueuedPlaybackRowLocked(),
                "Loop OFF ignored an end marker inside a batch");
        engine.setQueuedPlaybackLooping(true);
        require(engine.primeNextQueuedPlaybackRowLocked(),
                "Loop ON did not continue to the next plan cycle inside a batch");
        require(engine.mLineSamplesPerRow == 760, "Wrong row after mid-batch end");

        engine.clearQueuedPlaybackRows();
        require(!engine.mSongPlanQueue, "Clear did not restore legacy playback mode");
        engine.enqueuePlaybackRow(row(800));
        engine.setQueuedPlaybackLooping(true);
        require(engine.primeNextQueuedPlaybackRowLocked(), "Legacy first row failed");
        require(engine.primeNextQueuedPlaybackRowLocked(), "Legacy looping changed");
        require(engine.mLineSamplesPerRow == 800, "Legacy loop did not replay");
        engine.beginPendingRows();
        engine.appendPendingRow(row(900));
        require(engine.primeNextQueuedPlaybackRowLocked(), "Legacy pending swap changed");
        require(engine.mLineSamplesPerRow == 900, "Legacy pending row was not used");
        engine.setQueuedPlaybackLooping(false);
        require(!engine.primeNextQueuedPlaybackRowLocked(), "Legacy stop changed");
        checkAudioMutes();
        std::cout << "Song Plan native queue tests passed\n";
    }
};

int main() {
    SongPlanQueueTest::run();
}
