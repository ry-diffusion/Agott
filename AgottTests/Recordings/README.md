# Recorded sets

Drop recordings here (`.json`, from Agott on the Watch or iPhone: Today → Record motion). Each one is
a set of one exercise with the real rep count you typed; `MotionRecordingTests.recordedSetsCountRight`
replays all of them through the rep counter and fails on any count off by more than one rep (or
10 %), printing the counted and real reps of each, which is what to tune `RepCounter.Settings` on.
