@testable import AppBundle
import Testing

@Suite("GridMove")
struct GridMoveTest {
    // MARK: bloom — pressing right repeatedly from lane 0

    @Test func bloomRightFromLeftEdge() {
        // Start: lane 0 only. 3 lanes total.
        // Expected sequence (right): (0,0) → (0,1) → (0,2) → (1,2) → (2,2)
        let lanes = 3
        var state = (0, 0)
        var seen: [(Int, Int)] = [state]
        for _ in 0..<6 {
            state = GridMove.bloomLaneStep(lane0: state.0, lane1: state.1, lanes: lanes, signum: +1)
            seen.append(state)
        }
        // Once at (2, 2) the step is idempotent (no-op).
        let expected: [(Int, Int)] = [(0,0), (0,1), (0,2), (1,2), (2,2), (2,2), (2,2)]
        #expect(seen.count == expected.count)
        for (got, want) in zip(seen, expected) {
            #expect(got == want)
        }
    }

    // MARK: bloom — symmetric reverse

    @Test func bloomLeftFromRightEdge() {
        // Mirror of bloomRightFromLeftEdge.
        let lanes = 3
        var state = (2, 2)
        var seen: [(Int, Int)] = [state]
        for _ in 0..<6 {
            state = GridMove.bloomLaneStep(lane0: state.0, lane1: state.1, lanes: lanes, signum: -1)
            seen.append(state)
        }
        let expected: [(Int, Int)] = [(2,2), (1,2), (0,2), (0,1), (0,0), (0,0), (0,0)]
        #expect(seen.count == expected.count)
        for (got, want) in zip(seen, expected) {
            #expect(got == want)
        }
    }

    // MARK: bloom — round-trip is identity

    @Test func bloomRightThenLeftIsIdentity() {
        // Walk forward exactly to the far extreme, then walk backward
        // the same number of steps. The backward trace should mirror
        // forward.reversed() exactly. For lanes=N the chain length is
        // `2N - 1` states (`2N - 2` transitions).
        let lanes = 4
        let chainLen = 2 * lanes - 2
        var forward: [(Int, Int)] = [(0, 0)]
        var s = (0, 0)
        for _ in 0..<chainLen {
            s = GridMove.bloomLaneStep(lane0: s.0, lane1: s.1, lanes: lanes, signum: +1)
            forward.append(s)
        }
        #expect(forward.last! == (lanes - 1, lanes - 1))

        var backward: [(Int, Int)] = [forward.last!]
        s = forward.last!
        for _ in 0..<chainLen {
            s = GridMove.bloomLaneStep(lane0: s.0, lane1: s.1, lanes: lanes, signum: -1)
            backward.append(s)
        }
        let reversedForward = Array(forward.reversed())
        #expect(backward.count == reversedForward.count)
        for (a, b) in zip(backward, reversedForward) {
            #expect(a == b)
        }
    }

    // MARK: bloom — starting from middle lane

    @Test func bloomRightFromMiddleSingleLane() {
        // (1, 1) in a 3-lane grid → (1, 2) → (2, 2) → stuck.
        let lanes = 3
        let s1 = GridMove.bloomLaneStep(lane0: 1, lane1: 1, lanes: lanes, signum: +1)
        #expect(s1 == (1, 2))
        let s2 = GridMove.bloomLaneStep(lane0: s1.0, lane1: s1.1, lanes: lanes, signum: +1)
        #expect(s2 == (2, 2))
        let s3 = GridMove.bloomLaneStep(lane0: s2.0, lane1: s2.1, lanes: lanes, signum: +1)
        #expect(s3 == (2, 2)) // no-op at extreme
    }

    // MARK: bloom — single-lane shape is always no-op

    @Test func bloomNoOpInSingleLaneGrid() {
        let s = GridMove.bloomLaneStep(lane0: 0, lane1: 0, lanes: 1, signum: +1)
        #expect(s == (0, 0))
        let s2 = GridMove.bloomLaneStep(lane0: 0, lane1: 0, lanes: 1, signum: -1)
        #expect(s2 == (0, 0))
    }

    // MARK: bloom — already-multi-lane start

    @Test func bloomRightFromAlreadyTwoLane() {
        // Start (0, 1) in a 3-lane grid — pressing right grows to (0, 2),
        // then contracts left → (1, 2), then (2, 2).
        let lanes = 3
        var s = (0, 1)
        s = GridMove.bloomLaneStep(lane0: s.0, lane1: s.1, lanes: lanes, signum: +1)
        #expect(s == (0, 2))
        s = GridMove.bloomLaneStep(lane0: s.0, lane1: s.1, lanes: lanes, signum: +1)
        #expect(s == (1, 2))
        s = GridMove.bloomLaneStep(lane0: s.0, lane1: s.1, lanes: lanes, signum: +1)
        #expect(s == (2, 2))
    }
}
