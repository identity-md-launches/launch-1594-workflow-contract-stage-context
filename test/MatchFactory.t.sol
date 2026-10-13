// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixtures} from "./utils/Fixtures.sol";
import {MatchFactory} from "../src/MatchFactory.sol";
import {PrizeVault} from "../src/PrizeVault.sol";
import {Buyback} from "../src/Buyback.sol";
import {Owned} from "../src/lib/Common.sol";

contract MatchFactoryTest is Fixtures {
    uint96 constant FEE = 10e18;

    function test_constructorWiring() public view {
        assertEq(mf.owner(), owner);
        assertEq(address(mf.imd()), address(imd));
        assertEq(address(mf.risk()), address(risk));
        assertEq(address(mf.vault()), address(vault));
        assertEq(address(mf.buyback()), address(buyback));
        assertEq(mf.outcomeSigner(), address(0));
    }

    function test_createValidation() public {
        vm.startPrank(p[0]);
        vm.expectRevert(MatchFactory.InvalidPlayerCount.selector);
        mf.createMatch(1, FEE, bytes32(uint256(1)), 0, 0);
        vm.expectRevert(MatchFactory.InvalidPlayerCount.selector);
        mf.createMatch(7, FEE, bytes32(uint256(1)), 0, 0);
        vm.expectRevert(MatchFactory.InvalidEntryFee.selector);
        mf.createMatch(2, 0, bytes32(uint256(1)), 0, 0);
        vm.expectRevert(MatchFactory.InvalidCommit.selector);
        mf.createMatch(2, FEE, bytes32(0), 0, 0);
        vm.stopPrank();
    }

    function test_fullLobbyStartsRevealAndDuplicateJoinReverts() public {
        uint256 id = mf.nextMatchId();
        vm.prank(p[0]);
        mf.createMatch(3, FEE, _commit(id, 0), 0, 0);
        vm.prank(p[0]);
        vm.expectRevert(MatchFactory.AlreadyJoined.selector);
        mf.join(id, bytes32(uint256(5)), 0, 0);
        vm.prank(p[1]);
        mf.join(id, _commit(id, 1), 0, 0);
        vm.prank(p[2]);
        mf.join(id, _commit(id, 2), 0, 0);
        assertEq(uint256(mf.getMatch(id).status), uint256(MatchFactory.Status.Revealing));
        assertEq(imd.balanceOf(address(mf)), 3 * FEE);
        vm.prank(p[3]);
        vm.expectRevert(MatchFactory.WrongStatus.selector);
        mf.join(id, bytes32(uint256(5)), 0, 0);
    }

    function test_lateJoinReverts() public {
        uint256 id = mf.nextMatchId();
        vm.prank(p[0]);
        mf.createMatch(4, FEE, bytes32(uint256(1)), 0, 0);
        vm.warp(block.timestamp + mf.JOIN_WINDOW() + 1);
        vm.prank(p[1]);
        vm.expectRevert(MatchFactory.TooLate.selector);
        mf.join(id, bytes32(uint256(2)), 0, 0);
    }

    function test_creatorStartsEarly_othersCannot() public {
        uint256 id = mf.nextMatchId();
        vm.prank(p[0]);
        mf.createMatch(4, FEE, _commit(id, 0), 0, 0);
        vm.prank(p[1]);
        mf.join(id, _commit(id, 1), 0, 0);
        vm.prank(p[1]);
        vm.expectRevert(MatchFactory.NotAuthorized.selector);
        mf.startReveal(id);
        vm.prank(p[0]);
        mf.startReveal(id);
        assertEq(uint256(mf.getMatch(id).status), uint256(MatchFactory.Status.Revealing));
    }

    function test_underfilledLobbyRefunds() public {
        uint256 id = mf.nextMatchId();
        vm.prank(p[0]);
        mf.createMatch(4, FEE, bytes32(uint256(1)), 0, 0);
        vm.prank(p[0]);
        vm.expectRevert(MatchFactory.TooEarly.selector);
        mf.startReveal(id);
        vm.warp(block.timestamp + mf.JOIN_WINDOW() + 1);
        mf.startReveal(id);
        assertEq(uint256(mf.getMatch(id).status), uint256(MatchFactory.Status.Cancelled));
        uint256 before = imd.balanceOf(p[0]);
        vm.prank(p[0]);
        mf.withdrawRefund();
        assertEq(imd.balanceOf(p[0]), before + FEE);
        vm.prank(p[0]);
        vm.expectRevert(MatchFactory.NothingToWithdraw.selector);
        mf.withdrawRefund();
    }

    function test_revealProducesSeedFromAllSecrets() public {
        uint256 id = _openFull(3, FEE);
        vm.prank(p[0]);
        vm.expectRevert(MatchFactory.BadReveal.selector);
        mf.reveal(id, _secret(9));
        vm.prank(p[5]);
        vm.expectRevert(MatchFactory.NotPlayer.selector);
        mf.reveal(id, _secret(5));
        _revealAll(id, 3);
        MatchFactory.Match memory m = mf.getMatch(id);
        assertEq(uint256(m.status), uint256(MatchFactory.Status.Playing));
        bytes32 expected =
            keccak256(abi.encode(_secret(0))) ^ keccak256(abi.encode(_secret(1))) ^ keccak256(abi.encode(_secret(2)));
        assertEq(m.seed, expected);
        vm.prank(p[0]);
        vm.expectRevert(MatchFactory.WrongStatus.selector);
        mf.reveal(id, _secret(0));
    }

    function test_nonRevealerForfeitsToRevealers() public {
        uint256 id = _openFull(3, FEE);
        vm.prank(p[0]);
        mf.reveal(id, _secret(0));
        vm.prank(p[1]);
        mf.reveal(id, _secret(1));
        vm.expectRevert(MatchFactory.TooEarly.selector);
        mf.cancelUnrevealed(id);
        vm.warp(block.timestamp + mf.REVEAL_WINDOW() + 1);
        vm.prank(p[2]);
        vm.expectRevert(MatchFactory.TooLate.selector);
        mf.reveal(id, _secret(2));
        mf.cancelUnrevealed(id);
        assertEq(mf.refunds(p[0]) + mf.refunds(p[1]), 3 * FEE);
        assertEq(mf.refunds(p[2]), 0);
        assertEq(mf.totalRefundsOwed(), imd.balanceOf(address(mf)));
    }

    function test_nobodyRevealedRefundsAll() public {
        uint256 id = _openFull(2, FEE);
        vm.warp(block.timestamp + mf.REVEAL_WINDOW() + 1);
        mf.cancelUnrevealed(id);
        assertEq(mf.refunds(p[0]), FEE);
        assertEq(mf.refunds(p[1]), FEE);
    }

    function test_settleUnanimousPaysPrizes() public {
        _linkVault();
        uint256 id = _openFull(4, FEE);
        _revealAll(id, 4);
        address[] memory ranking = _ranking(2, 0, 3, 3);
        mf.settle(id, ranking, _unanimous(id, ranking, 4));
        assertEq(uint256(mf.getMatch(id).status), uint256(MatchFactory.Status.Settled));
        uint256 pot = 4 * FEE;
        assertEq(vault.claimable(p[2]), pot * 6000 / 10000);
        assertEq(vault.claimable(p[0]), pot * 2500 / 10000);
        assertEq(vault.claimable(p[3]), pot * 1500 / 10000);
        assertEq(vault.claimable(p[1]), 0);
        assertEq(imd.balanceOf(address(mf)), 0);
        assertEq(imd.balanceOf(address(vault)), pot);

        uint256 before = imd.balanceOf(p[2]);
        vm.prank(p[2]);
        vault.claim();
        assertEq(imd.balanceOf(p[2]), before + pot * 6000 / 10000);

        bytes[] memory again = _unanimous(id, ranking, 4);
        vm.expectRevert(MatchFactory.WrongStatus.selector);
        mf.settle(id, ranking, again);
    }

    function test_twoPlayerSplit() public {
        _linkVault();
        uint256 id = _openFull(2, FEE);
        _revealAll(id, 2);
        address[] memory ranking = _ranking(1, 0, 0, 2);
        mf.settle(id, ranking, _unanimous(id, ranking, 2));
        assertEq(vault.claimable(p[1]), 15e18);
        assertEq(vault.claimable(p[0]), 5e18);
    }

    function test_settleRejectsMissingOrWrongSignatures() public {
        _linkVault();
        uint256 id = _openFull(3, FEE);
        _revealAll(id, 3);
        address[] memory ranking = _ranking(0, 1, 2, 3);
        bytes[] memory sigs = _unanimous(id, ranking, 3);
        // one player signed a different ranking
        address[] memory other = _ranking(1, 0, 2, 3);
        sigs[2] = _sign(pks[2], mf.outcomeDigest(id, other));
        vm.expectRevert(MatchFactory.InvalidSignatures.selector);
        mf.settle(id, ranking, sigs);
        // only two of three players
        bytes[] memory two = new bytes[](2);
        vm.expectRevert(MatchFactory.InvalidSignatures.selector);
        mf.settle(id, ranking, two);
    }

    function test_settleRejectsBadRanking() public {
        _linkVault();
        uint256 id = _openFull(3, FEE);
        _revealAll(id, 3);
        address[] memory dup = _ranking(0, 0, 2, 3);
        bytes[] memory sigs_dup = _unanimous(id, dup, 3);
        vm.expectRevert(MatchFactory.InvalidRanking.selector);
        mf.settle(id, dup, sigs_dup);
        address[] memory outsider = _ranking(0, 1, 5, 3);
        bytes[] memory sigs_outsider = _unanimous(id, outsider, 3);
        vm.expectRevert(MatchFactory.InvalidRanking.selector);
        mf.settle(id, outsider, sigs_outsider);
        address[] memory short = _ranking(0, 1, 0, 2);
        bytes[] memory sigs_short = _unanimous(id, short, 3);
        vm.expectRevert(MatchFactory.InvalidRanking.selector);
        mf.settle(id, short, sigs_short);
    }

    function test_seatSignerPathNotConfiguredThenConfigured() public {
        _linkVault();
        uint256 seatPk = 0x5EA7;
        uint256 id = _openFull(3, FEE);
        _revealAll(id, 3);
        address[] memory ranking = _ranking(0, 1, 2, 3);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(seatPk, mf.outcomeDigest(id, ranking));
        vm.expectRevert(MatchFactory.OutcomeSignerNotConfigured.selector);
        mf.settle(id, ranking, sigs);

        vm.prank(p[0]);
        vm.expectRevert(Owned.NotOwner.selector);
        mf.setOutcomeSigner(vm.addr(seatPk));
        vm.prank(owner);
        mf.setOutcomeSigner(vm.addr(seatPk));

        bytes[] memory wrong = new bytes[](1);
        wrong[0] = _sign(pks[0], mf.outcomeDigest(id, ranking));
        vm.expectRevert(MatchFactory.InvalidSignatures.selector);
        mf.settle(id, ranking, wrong);

        mf.settle(id, ranking, sigs);
        assertEq(vault.claimable(p[0]), 18e18);
    }

    function test_settleRevertsWhenVaultNotLinked() public {
        uint256 id = _openFull(2, FEE);
        _revealAll(id, 2);
        address[] memory ranking = _ranking(0, 1, 0, 2);
        bytes[] memory sigs = _unanimous(id, ranking, 2);
        vm.expectRevert(PrizeVault.MatchFactoryNotConfigured.selector);
        mf.settle(id, ranking, sigs);
    }

    function test_unsettledMatchExpiresAndRefunds() public {
        _linkVault();
        uint256 id = _openFull(2, FEE);
        _revealAll(id, 2);
        vm.expectRevert(MatchFactory.TooEarly.selector);
        mf.expire(id);
        vm.warp(block.timestamp + mf.PLAY_WINDOW() + mf.SETTLE_GRACE() + 1);
        address[] memory ranking = _ranking(0, 1, 0, 2);
        bytes[] memory sigs = _unanimous(id, ranking, 2);
        vm.expectRevert(MatchFactory.TooLate.selector);
        mf.settle(id, ranking, sigs);
        mf.expire(id);
        assertEq(mf.refunds(p[0]), FEE);
        assertEq(mf.refunds(p[1]), FEE);
    }

    function test_signatureNotReplayableAcrossMatches() public {
        _linkVault();
        uint256 id1 = _openFull(2, FEE);
        _revealAll(id1, 2);
        address[] memory ranking = _ranking(0, 1, 0, 2);
        bytes[] memory sigs = _unanimous(id1, ranking, 2);
        uint256 id2 = _openFull(2, FEE);
        _revealAll(id2, 2);
        vm.expectRevert(MatchFactory.InvalidSignatures.selector);
        mf.settle(id2, ranking, sigs);
    }

    // ---------------------------------------------------------------- RISK entries

    function test_riskEntryBurnsTenPercentAndRoutesToImd() public {
        _setVenue();
        uint256 id = mf.nextMatchId();
        uint256 deadBefore = risk.balanceOf(DEAD);
        uint256 imdBefore = imd.balanceOf(p[0]);
        // 1 RISK = 1 IMD in the mock: 20 RISK -> 2 burned, 18 routed -> 18 IMD, 10 kept, 8 returned
        vm.prank(p[0]);
        mf.createMatch(2, FEE, _commit(id, 0), 20e18, FEE);
        assertEq(risk.balanceOf(DEAD) - deadBefore, 2e18);
        assertEq(mf.totalRiskBurned(), 2e18);
        assertEq(imd.balanceOf(address(mf)), FEE);
        assertEq(imd.balanceOf(p[0]), imdBefore + 8e18);
        assertEq(risk.balanceOf(address(mf)), 0);
        assertEq(risk.balanceOf(address(buyback)), 0);
        assertEq(buyback.circulatingSupply(), 1e27 - risk.balanceOf(DEAD));
    }

    function test_riskEntryFailsWithoutVenueOrEnoughOutput() public {
        uint256 id = mf.nextMatchId();
        vm.prank(p[0]);
        vm.expectRevert(Buyback.VenueNotConfigured.selector);
        mf.createMatch(2, FEE, _commit(id, 0), 20e18, FEE);
        _setVenue();
        vm.prank(p[0]);
        vm.expectRevert(MatchFactory.InsufficientImdOut.selector);
        mf.createMatch(2, FEE, _commit(id, 0), 20e18, FEE - 1);
        // 5 RISK -> 4.5 IMD < fee: venue enforces minOut
        vm.prank(p[0]);
        vm.expectRevert(bytes("slippage"));
        mf.createMatch(2, FEE, _commit(id, 0), 5e18, FEE);
        assertEq(risk.balanceOf(DEAD), 0);
    }

    function test_reentrantVenueCannotReenterJoin() public {
        _setVenue();
        uint256 id = mf.nextMatchId();
        vm.prank(p[0]);
        mf.createMatch(3, FEE, _commit(id, 0), 0, 0);
        venue.setReenter(address(mf), abi.encodeCall(MatchFactory.join, (id, bytes32(uint256(7)), 0, 0)));
        vm.prank(p[1]);
        vm.expectRevert();
        mf.join(id, _commit(id, 1), 20e18, FEE);
        assertEq(mf.getMatch(id).playerCount, 1);
    }

    function testFuzz_conservationThroughCancel(uint8 n, uint8 revealers) public {
        n = uint8(bound(n, 2, 6));
        revealers = uint8(bound(revealers, 0, n - 1));
        uint256 id = _openFull(n, FEE);
        for (uint256 i; i < revealers; ++i) {
            vm.prank(p[i]);
            mf.reveal(id, _secret(i));
        }
        vm.warp(block.timestamp + mf.REVEAL_WINDOW() + 1);
        mf.cancelUnrevealed(id);
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            sum += mf.refunds(p[i]);
        }
        assertEq(sum, uint256(n) * FEE);
        assertEq(imd.balanceOf(address(mf)), sum);
    }
}
