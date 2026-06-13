import XCTest
@testable import HelmCore

final class AttentionItemTests: XCTestCase {

    private func session(_ state: SessionState, _ idleReason: IdleReason? = nil,
                         agent: AgentKind = .claude) -> ChatSession {
        ChatSession(sessionId: "s", cwd: "/w", project: "p", label: "L", state: state,
                    kind: "interactive", pid: 1, lastActive: Date(timeIntervalSince1970: 1000),
                    branch: "b", idleReason: idleReason, agent: agent)
    }

    // MARK: reason.rank — the single scale every item type sorts on

    func testRankOrdering() {
        XCTAssertEqual(AttentionReason.needsInput.rank, 0)
        XCTAssertEqual(AttentionReason.prChangesRequested.rank, 0)
        XCTAssertEqual(AttentionReason.prCiFailed.rank, 0)
        XCTAssertEqual(AttentionReason.needsReview.rank, 1)
        XCTAssertEqual(AttentionReason.prReviewRequested.rank, 1)
        XCTAssertEqual(AttentionReason.prMergeable.rank, 1)
        XCTAssertEqual(AttentionReason.live.rank, 2)
        XCTAssertEqual(AttentionReason.none.rank, 3)
    }

    func testWantsAttentionIsRankLEOne() {
        for r: AttentionReason in [.needsInput, .prChangesRequested, .prCiFailed,
                                   .needsReview, .prReviewRequested, .prMergeable] {
            XCTAssertTrue(r.wantsAttention, "\(r) should want attention")
        }
        for r: AttentionReason in [.live, .none] {
            XCTAssertFalse(r.wantsAttention, "\(r) should not want attention")
        }
    }

    // MARK: ChatSession derivation

    func testReasonDerivation() {
        XCTAssertEqual(session(.liveIdle, .needsInput).reason, .needsInput)
        XCTAssertEqual(session(.liveIdle, .needsReview).reason, .needsReview)
        XCTAssertEqual(session(.liveIdle, nil).reason, .needsReview)   // unclassified idle → review
        XCTAssertEqual(session(.liveBusy).reason, .live)
        XCTAssertEqual(session(.cold).reason, .none)
    }

    /// The fold must not change behavior: attentionRank stays identical to the old hand-rolled
    /// mapping for every session state.
    func testAttentionRankMatchesReasonRank() {
        for s in [session(.liveIdle, .needsInput), session(.liveIdle, .needsReview),
                  session(.liveIdle, nil), session(.liveBusy), session(.cold)] {
            XCTAssertEqual(SessionStore.attentionRank(s), s.reason.rank)
        }
    }

    func testBadgeCarriesAgent() {
        XCTAssertEqual(session(.cold, agent: .claude).badge, .session(.claude))
        XCTAssertEqual(session(.cold, agent: .pi).badge, .session(.pi))
    }

    func testSubtitleFoldsProjectAndBranch() {
        XCTAssertEqual(session(.cold).subtitle, "p · b")
        let noBranch = ChatSession(sessionId: "s", cwd: "/w", project: "p", label: "L",
                                   state: .cold, kind: nil, pid: nil,
                                   lastActive: Date(timeIntervalSince1970: 1), branch: nil)
        XCTAssertEqual(noBranch.subtitle, "p")
    }

    func testOtherContextUsesCwdLeaf() {
        let other = ChatSession(sessionId: "s", cwd: "/Users/me/Home/dev/scratch-app", project: "Other", label: "L",
                                state: .cold, kind: nil, pid: nil,
                                lastActive: Date(timeIntervalSince1970: 1), branch: "b")
        XCTAssertEqual(other.context, "scratch-app")
        XCTAssertEqual(other.subtitle, "scratch-app · b")

        let missingCwd = ChatSession(sessionId: "s", cwd: "", project: "Other", label: "L",
                                     state: .cold, kind: nil, pid: nil,
                                     lastActive: Date(timeIntervalSince1970: 1), branch: nil)
        XCTAssertEqual(missingCwd.context, "Other")
    }

    func testPrimaryActionResumesNormalSessionAndNewChatsPlaceholder() {
        XCTAssertEqual(session(.cold).primaryAction,
                       .resumeSession(agent: .claude, sessionId: "s", cwd: "/w"))
        let placeholder = ChatSession.placeholder(forProject: "proj", cwd: "/proj")
        XCTAssertEqual(placeholder.primaryAction, .newChat(project: "proj", cwd: "/proj"))
    }
}
