import CryptoKit
import Foundation
import Testing
@testable import Agott

/// Rep counting on made-up motion: reps at any angle, pace and depth, rests
/// between sets, noise, and stillness that must not count.
struct RepCounterTests {
    private let pushUps = RepCounter.Settings.for(.pushUp, sensor: .watch)
    private let squats = RepCounter.Settings.for(.squat, sensor: .airpods)
    private let pullUps = RepCounter.Settings.for(.pullUp, sensor: .airpods)

    @Test(arguments: 1...6)
    func pushUpsFromWristTilt(seed: Int) {
        let workout = SyntheticWorkout(reps: 10, seed: UInt64(seed))
        #expect(SyntheticWorkout.count(workout.tilt(degrees: 25), pushUps) == 10)
    }

    @Test(arguments: 1...6)
    func fastShallowPushUps(seed: Int) {
        let workout = SyntheticWorkout(reps: 15, repSeconds: 1.2, seed: UInt64(seed))
        #expect(SyntheticWorkout.count(workout.tilt(degrees: 12, noise: 0.015), pushUps) == 15)
    }

    @Test(arguments: 1...4)
    func threeSetsWithRests(seed: Int) {
        let workout = SyntheticWorkout(reps: 30, restLongEvery: 10, seed: UInt64(seed))
        #expect(SyntheticWorkout.count(workout.tilt(degrees: 30), pushUps) == 30)
    }

    @Test(arguments: 1...6)
    func squatsFromHeadMotion(seed: Int) {
        let workout = SyntheticWorkout(reps: 12, repSeconds: 2.5, seed: UInt64(seed))
        #expect(SyntheticWorkout.count(workout.acceleration(meters: 0.45), squats) == 12)
    }

    @Test(arguments: 1...4)
    func slowSquatsWithPauses(seed: Int) {
        let workout = SyntheticWorkout(reps: 8, repSeconds: 3.5, restBetween: 2, seed: UInt64(seed))
        #expect(SyntheticWorkout.count(workout.acceleration(meters: 0.35), squats) == 8)
    }

    @Test(arguments: 1...4)
    func pullUpsInSets(seed: Int) {
        let workout = SyntheticWorkout(reps: 15, repSeconds: 2.2, restLongEvery: 5, seed: UInt64(seed))
        #expect(SyntheticWorkout.count(workout.acceleration(meters: 0.5), pullUps) == 15)
    }

    @Test func stillnessIsNotReps() {
        #expect(SyntheticWorkout.count(SyntheticWorkout.still(seconds: 60, noise: 0.01), pushUps) == 0)
        let still = SyntheticWorkout.still(seconds: 60, noise: 0.01).map { ($0.t, $0.v - Vec3(0, 0, -1)) }
        #expect(SyntheticWorkout.count(still, squats) == 0)
    }

    @Test func fidgetingIsNotReps() {
        let fidget = SyntheticWorkout(reps: 10, repSeconds: 1.5, seed: 9)
        #expect(SyntheticWorkout.count(fidget.tilt(degrees: 2), pushUps) == 0)
        #expect(SyntheticWorkout.count(fidget.acceleration(meters: 0.03), squats) == 0)
    }
}

struct WorkoutPlanTests {
    @Test func readsSetsAndRepsInBothLanguages() {
        let plan = WorkoutPlan.parse("""
        ## Calistenia
        - **Flexões**: 3x10
        - 4 séries de 12 agachamentos
        - Barra fixa: 3 sets of 5
        - 20 push-ups
        - Prancha: 3x30s
        - Descanso 60 segundos
        """)
        #expect(plan.steps.count == 6)
        #expect(plan.targets == [.pushUp: 50, .squat: 48, .pullUp: 15])
        #expect(plan.steps[4].exercise == nil)
        #expect(plan.steps[0].text == "Flexões: 3x10")
        #expect(!plan.steps[4].isCountable)
    }

    @Test func timedAndUnknownStepsAreTicked() {
        #expect(WorkoutPlan.reps(in: "agachamento isometrico 45s") == nil)
        #expect(WorkoutPlan.reps(in: "3 x 15 squats") == 45)
        #expect(WorkoutPlan.reps(in: "flexoes 2 min") == nil)
        let plan = WorkoutPlan.parse("- 10 flexões\n- 30s de alongamento de flexibilidade")
        #expect(plan.steps[1].exercise == nil)
        #expect(!plan.isProven(counts: [.pushUp: 10], ticked: []))
        #expect(plan.isProven(counts: [.pushUp: 10], ticked: [1]))
    }

    @Test func ninetyPercentIsEnough() {
        let plan = WorkoutPlan.parse("- 3x10 flexões")
        #expect(WorkoutPlan.required(30) == 27)
        #expect(!plan.isProven(counts: [.pushUp: 26], ticked: []))
        #expect(plan.isProven(counts: [.pushUp: 27], ticked: []))
    }
}

struct SyncCryptoTests {
    private let keys = SyncKeys(master: SymmetricKey(data: Data(repeating: 7, count: 32)))

    @Test func pbkdf2MatchesRFC7914() {
        let key = SyncKeys.master(passphrase: "password", salt: Data("salt".utf8), rounds: 4096)
        let hex = key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    @Test func sealsAndOpens() throws {
        let id = keys.recordID("routine/1")
        let sealed = try keys.seal(Data("treino".utf8), id: id)
        #expect(sealed.hasPrefix("v1."))
        #expect(!sealed.contains("treino"))
        #expect(try keys.open(sealed, id: id) == Data("treino".utf8))
        // Same text, new nonce: nothing repeats on the Worker.
        #expect(try keys.seal(Data("treino".utf8), id: id) != sealed)
    }

    @Test func aRecordMovedToAnotherIdDoesNotOpen() throws {
        let sealed = try keys.seal(Data("treino".utf8), id: keys.recordID("a"))
        #expect(throws: SyncCryptoError.self) { try keys.open(sealed, id: keys.recordID("b")) }
    }

    @Test func wrongPassphraseIsCaughtByTheCheck() throws {
        let salt = SyncKeys.newSalt()
        let right = SyncKeys(master: SyncKeys.master(passphrase: "certa", salt: salt, rounds: 1000))
        let wrong = SyncKeys(master: SyncKeys.master(passphrase: "errada", salt: salt, rounds: 1000))
        let check = try right.check()
        #expect(right.verify(check: check))
        #expect(!wrong.verify(check: check))
    }

    @Test func idsAreStableAndOpaque() {
        let a = keys.recordID(DoneRecord.name(UUID(), day: "2026-11-11"))
        #expect(a.count == 32)
        #expect(!a.contains("2026"))
        #expect(keys.recordID("keys") == keys.recordID("keys"))
        let other = SyncKeys(master: SymmetricKey(data: Data(repeating: 8, count: 32)))
        #expect(other.recordID("keys") != keys.recordID("keys"))
    }

    /// The same vector the Worker's tests open with WebCrypto.
    @Test func opensTheSharedVector() throws {
        let id = keys.recordID("routine/ABC")
        #expect(id == "NWz5B724jr62hb3qwoI6n5mxrxh_elp4")
        let opened = try keys.open("v1.60wdyc6nKWxaCii3MG78nE0eDP4nY_Oq5zqpqxUGvyURXQ8hpUYX", id: id)
        #expect(String(decoding: opened, as: UTF8.self) == #"{"hello":1}"#)
    }
}

struct RoutineDaysTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return calendar
    }

    @Test func streakCountsBackFromTodayOrYesterday() {
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9))!
        #expect(RoutineDays.day(today, calendar: calendar) == "2026-11-11")
        #expect(RoutineDays.streak(["2026-11-10", "2026-11-09", "2026-11-07"], today: today, calendar: calendar) == 2)
        #expect(RoutineDays.streak(["2026-11-11", "2026-11-10", "2026-11-09"], today: today, calendar: calendar) == 3)
        #expect(RoutineDays.streak(["2026-11-08"], today: today, calendar: calendar) == 0)
        #expect(RoutineDays.days(ending: today, count: 3, calendar: calendar) == ["2026-11-11", "2026-11-10", "2026-11-09"])
    }

    @Test func doneWithProofWins() {
        let id = UUID()
        let bare = SyncPayload.done(DoneRecord(routineID: id, day: "2026-11-11", at: .now, device: "Mac"))
        let proof = WorkoutProof(counts: [ExerciseCount(exercise: .pushUp, target: 30, counted: 31, sensor: .watch)],
                                 started: .now, ended: .now)
        let proven = SyncPayload.done(DoneRecord(routineID: id, day: "2026-11-11", at: .now, device: "Watch", proof: proof))
        #expect(SyncPayload.newer(bare, proven) == proven)
        #expect(SyncPayload.newer(proven, bare) == proven)
        #expect(bare.name == proven.name)
    }
}
