@testable import AppBundle
import Testing

@Suite("GridMove")
struct GridMoveTest {
    // MARK: bloom — pressing right repeatedly from lane 0 in a 6-lane grid

    @Test func bloomRightFromLeftEdgeSixLanes() {
        // Start: lane 0 only. 6 lanes total.
        // Width sequence: 1 → 2 → 3 → 4 → 5 → 6 → 5 → 4 → 3 → 2 → 1.
        let lanes = 6
        var state = (0, 0)
        var seen: [(Int, Int)] = [state]
        for _ in 0..<12 {
            state = GridMove.bloomLaneStep(lane0: state.0, lane1: state.1, lanes: lanes, signum: +1)
            seen.append(state)
        }
        let expected: [(Int, Int)] = [
            (0,0), (0,1), (0,2), (0,3), (0,4), (0,5),
            (1,5), (2,5), (3,5), (4,5), (5,5),
            (5,5), (5,5), // idempotent at extreme
        ]
        #expect(seen.count == expected.count)
        for (got, want) in zip(seen, expected) {
            #expect(got == want)
        }
    }

    @Test func bloomLeftFromRightEdgeSixLanes() {
        let lanes = 6
        var state = (5, 5)
        var seen: [(Int, Int)] = [state]
        for _ in 0..<12 {
            state = GridMove.bloomLaneStep(lane0: state.0, lane1: state.1, lanes: lanes, signum: -1)
            seen.append(state)
        }
        let expected: [(Int, Int)] = [
            (5,5), (4,5), (3,5), (2,5), (1,5), (0,5),
            (0,4), (0,3), (0,2), (0,1), (0,0),
            (0,0), (0,0),
        ]
        #expect(seen.count == expected.count)
        for (got, want) in zip(seen, expected) {
            #expect(got == want)
        }
    }

    @Test func bloomRightThenLeftIsIdentitySixLanes() {
        // Walk forward to (lanes-1, lanes-1), then walk back exactly the
        // same number of steps. Backward should mirror forward.reversed().
        let lanes = 6
        let chainLen = 2 * lanes - 2 // 10 transitions for 6-lane bloom
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

    @Test func bloomNoOpInSingleLaneGrid() {
        // 1-lane grid: every press is a no-op (no room to grow or shift).
        let s1 = GridMove.bloomLaneStep(lane0: 0, lane1: 0, lanes: 1, signum: +1)
        #expect(s1 == (0, 0))
        let s2 = GridMove.bloomLaneStep(lane0: 0, lane1: 0, lanes: 1, signum: -1)
        #expect(s2 == (0, 0))
    }

    @Test func bloomFromAlreadyMultiLaneSpan() {
        // Start (0, 1) in a 6-lane grid — pressing right keeps growing.
        let lanes = 6
        var s = (0, 1)
        s = GridMove.bloomLaneStep(lane0: s.0, lane1: s.1, lanes: lanes, signum: +1)
        #expect(s == (0, 2))
        s = GridMove.bloomLaneStep(lane0: s.0, lane1: s.1, lanes: lanes, signum: +1)
        #expect(s == (0, 3))
    }
}
