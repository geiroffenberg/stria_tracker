#include "../../android/app/src/main/cpp/audio_engine.h"

#include <cstdlib>
#include <iostream>
#include <memory>

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

    static void pending(AudioEngine& engine, bool end, int samples) {
        engine.beginPendingRows();
        engine.appendPendingRow(row(samples));
        require(engine.configureSongPlanRows(true, {end ? 1 : 0}, {1}),
                "Pending batch publication failed");
    }

public:
    static void run() {
        // No stream is opened: exercise only row selection and queue boundaries.
        auto owner = std::make_unique<AudioEngine>();
        auto& engine = *owner;
        engine.enqueuePlaybackRow(row(100));
        engine.enqueuePlaybackRow(row(200));
        require(!engine.configureSongPlanRows(false, {1}, {1}),
                "Mismatched flags were accepted");
        require(engine.configureSongPlanRows(false, {0, 1}, {1, 0}),
                "Initial batch publication failed");
        engine.setQueuedPlaybackLooping(false);
        pending(engine, false, 300);
        require(engine.primeNextQueuedPlaybackRowLocked(), "First row failed");
        require(engine.mLineSamplesPerRow == 100, "Wrong first row");
        require(engine.primeNextQueuedPlaybackRowLocked(), "Second row failed");
        require(engine.mLineSamplesPerRow == 200, "Wrong second row");
        require(!engine.primeNextQueuedPlaybackRowLocked(),
                "Loop OFF played past a plan-end marker");
        require(!engine.consumeSongPlanUnderrun(),
                "Natural plan end was incorrectly reported as an underrun");

        engine.setQueuedPlaybackLooping(true);
        require(engine.primeNextQueuedPlaybackRowLocked(),
                "Loop ON did not chain to the published next batch");
        require(engine.mLineSamplesPerRow == 300, "Wrong chained row");
        require(!engine.primeNextQueuedPlaybackRowLocked(),
                "Missing batch silently replayed old rows");
        require(engine.consumeSongPlanUnderrun(), "Missing batch was not reported");
        require(!engine.consumeSongPlanUnderrun(), "Underrun was not consumed");

        engine.clearQueuedPlaybackRows();
        engine.enqueuePlaybackRow(row(400));
        require(engine.configureSongPlanRows(false, {0}, {1}),
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
        require(engine.configureSongPlanRows(false, {0}, {1}),
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
        require(engine.configureSongPlanRows(false, {1, 0}, {1, 1}),
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
        std::cout << "Song Plan native queue tests passed\n";
    }
};

int main() {
    SongPlanQueueTest::run();
}
