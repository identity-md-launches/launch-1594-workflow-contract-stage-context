// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixtures} from "./utils/Fixtures.sol";
import {MatchFactory} from "../src/MatchFactory.sol";
import {PrizeVault} from "../src/PrizeVault.sol";
import {Cosmetics} from "../src/Cosmetics.sol";
import {Buyback} from "../src/Buyback.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {RiskRules} from "../src/lib/RiskRules.sol";
import {Owned, ReentrancyGuard, SigLib, SafeTransfer} from "../src/lib/Common.sol";

/// @dev Inputs the happy-path suite did not try: bounds, boundaries, duplicates, malformed signatures,
/// dust, wrong callers and re-entrant venues.
contract MatchFactoryEdgeTest is Fixtures {
    uint96 constant FEE = 10e18;
    uint256 constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function test_entryFeeBounds() public {
        imd.mint(p[0], 20_000e18);
        uint256 id = mf.nextMatchId();
        uint96 min = uint96(mf.MIN_ENTRY());
        uint96 max = uint96(mf.MAX_ENTRY());
        bytes32 c0 = _commit(id, 0);
        bytes32 c1 = _commit(id + 1, 0);
        vm.startPrank(p[0]);
        vm.expectRevert(MatchFactory.InvalidEntryFee.selector);
        mf.createMatch(2, min - 1, id, c0, 0, 0);
        vm.expectRevert(MatchFactory.InvalidEntryFee.selector);
        mf.createMatch(2, max + 1, id, c0, 0, 0);
        mf.createMatch(2, min, id, c0, 0, 0);
        mf.createMatch(2, max, id + 1, c1, 0, 0);
        vm.stopPrank();
        assertEq(mf.getMatch(id).pot, min);
        assertEq(mf.getMatch(id + 1).pot, max);
    }

    function test_joinUnknownOrFinishedMatchReverts() public {
        vm.prank(p[1]);
        vm.expectRevert(MatchFactory.WrongStatus.selector);
        mf.join(999, bytes32(uint256(1)), 0, 0);
        uint256 id = _openFull(2, FEE);
        vm.warp(block.timestamp + mf.REVEAL_WINDOW() + 1);
        mf.cancelUnrevealed(id);
        vm.prank(p[2]);
        vm.expectRevert(MatchFactory.WrongStatus.selector);
        mf.join(id, bytes32(uint256(1)), 0, 0);
        vm.expectRevert(MatchFactory.WrongStatus.selector);
        mf.startReveal(id);
        vm.expectRevert(MatchFactory.WrongStatus.selector);
        mf.expire(id);
    }

    function test_joinDeadlineIsInclusive() public {
        uint256 id = mf.nextMatchId();
        vm.prank(p[0]);
        mf.createMatch(3, FEE, id, _commit(id, 0), 0, 0);
        vm.warp(mf.getMatch(id).joinDeadline);
        vm.prank(p[1]);
        mf.join(id, _commit(id, 1), 0, 0);
        vm.warp(block.timestamp + 1);
        vm.prank(p[2]);
        vm.expectRevert(MatchFactory.TooLate.selector);
        mf.join(id, _commit(id, 2), 0, 0);
        // anyone may close the expired lobby once two are in
        vm.prank(p[5]);
        mf.startReveal(id);
        assertEq(uint256(mf.getMatch(id).status), uint256(MatchFactory.Status.Revealing));
        vm.prank(p[0]);
        vm.expectRevert(MatchFactory.WrongStatus.selector);
        mf.startReveal(id);
    }

    function test_sixPlayerMatchPaysThreePlaces() public {
        _linkVault();
        uint256 id = _openFull(6, FEE);
        assertEq(uint256(mf.getMatch(id).status), uint256(MatchFactory.Status.Revealing));
        _revealAll(id, 6);
        address[] memory ranking = _ranking(5, 4, 3, 3);
        mf.settle(id, ranking, _unanimous(id, ranking, 6));
        assertEq(vault.claimable(p[5]), 36e18);
        assertEq(vault.claimable(p[4]), 15e18);
        assertEq(vault.claimable(p[3]), 9e18);
        assertEq(vault.claimable(p[0]) + vault.claimable(p[1]) + vault.claimable(p[2]), 0);
        assertEq(vault.totalClaimable(), 60e18);
    }

    function test_revealTwiceReverts() public {
        uint256 id = _openFull(2, FEE);
        vm.prank(p[0]);
        mf.reveal(id, _secret(0));
        vm.prank(p[0]);
        vm.expectRevert(MatchFactory.AlreadyRevealed.selector);
        mf.reveal(id, _secret(0));
    }

    function test_cancelUnrevealedDustGoesToFirstRevealer() public {
        uint96 fee = uint96(mf.MIN_ENTRY() + 1); // pot = 3e17 + 3, two revealers -> 1 wei of dust
        uint256 id = _openFull(3, fee);
        vm.prank(p[1]);
        mf.reveal(id, _secret(1));
        vm.prank(p[0]);
        mf.reveal(id, _secret(0));
        vm.warp(block.timestamp + mf.REVEAL_WINDOW() + 1);
        mf.cancelUnrevealed(id);
        uint256 pot = uint256(fee) * 3;
        uint256 share = pot / 2;
        assertEq(mf.refunds(p[0]), share + 1, "join-order first revealer gets the dust");
        assertEq(mf.refunds(p[1]), share);
        assertEq(mf.refunds(p[2]), 0);
        assertEq(mf.totalRefundsOwed(), pot);
        vm.prank(p[2]);
        vm.expectRevert(MatchFactory.NothingToWithdraw.selector);
        mf.withdrawRefund();
    }

    function test_settleGraceBoundary() public {
        _linkVault();
        uint256 id = _openFull(2, FEE);
        _revealAll(id, 2);
        uint256 edge = uint256(mf.getMatch(id).playDeadline) + mf.SETTLE_GRACE();
        vm.warp(edge);
        vm.expectRevert(MatchFactory.TooEarly.selector);
        mf.expire(id);
        address[] memory ranking = _ranking(0, 1, 0, 2);
        mf.settle(id, ranking, _unanimous(id, ranking, 2));
        assertEq(uint256(mf.getMatch(id).status), uint256(MatchFactory.Status.Settled));
    }

    function test_malformedSignaturesRejected() public {
        _linkVault();
        uint256 id = _openFull(2, FEE);
        _revealAll(id, 2);
        address[] memory ranking = _ranking(0, 1, 0, 2);
        bytes32 digest = mf.outcomeDigest(id, ranking);
        bytes[] memory sigs = _unanimous(id, ranking, 2);

        // 64-byte signature
        bytes memory good = sigs[1];
        sigs[1] = new bytes(64);
        vm.expectRevert(SigLib.BadSignature.selector);
        mf.settle(id, ranking, sigs);

        // v = 29
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[1], digest);
        sigs[1] = abi.encodePacked(r, s, uint8(29));
        vm.expectRevert(SigLib.BadSignature.selector);
        mf.settle(id, ranking, sigs);

        // high-s malleated copy of a valid signature
        bytes32 sHigh = bytes32(SECP256K1_N - uint256(s));
        sigs[1] = abi.encodePacked(r, sHigh, v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(SigLib.BadSignature.selector);
        mf.settle(id, ranking, sigs);

        // signatures in the wrong player order
        sigs[1] = good;
        (sigs[0], sigs[1]) = (sigs[1], sigs[0]);
        vm.expectRevert(MatchFactory.InvalidSignatures.selector);
        mf.settle(id, ranking, sigs);

        // zero signatures
        vm.expectRevert(MatchFactory.InvalidSignatures.selector);
        mf.settle(id, ranking, new bytes[](0));
    }

    function test_seatSignerCannotPoseAsPlayerAndIsSnapshottedAtCreation() public {
        _linkVault();
        uint256 seatPk = 0x5EA7;
        uint256 otherPk = 0x5EA8;
        vm.prank(owner);
        mf.setOutcomeSigner(vm.addr(seatPk));
        uint256 id = _openFull(2, FEE);
        assertEq(mf.getMatch(id).outcomeSigner, vm.addr(seatPk), "signer snapshotted at creation");
        _revealAll(id, 2);
        address[] memory ranking = _ranking(1, 0, 0, 2);
        bytes32 digest = mf.outcomeDigest(id, ranking);
        // two copies of the seat signature are not a unanimous settlement
        bytes[] memory two = new bytes[](2);
        two[0] = _sign(seatPk, digest);
        two[1] = _sign(seatPk, digest);
        vm.expectRevert(MatchFactory.InvalidSignatures.selector);
        mf.settle(id, ranking, two);
        // rotating the signer afterwards does not let the new key settle this match ...
        vm.prank(owner);
        mf.setOutcomeSigner(vm.addr(otherPk));
        bytes[] memory seat = new bytes[](1);
        seat[0] = _sign(otherPk, digest);
        vm.expectRevert(MatchFactory.InvalidSignatures.selector);
        mf.settle(id, ranking, seat);
        // ... and disabling it does not revoke the key this match was created with
        vm.prank(owner);
        mf.setOutcomeSigner(address(0));
        assertEq(mf.getMatch(id).outcomeSigner, vm.addr(seatPk));
        seat[0] = _sign(seatPk, digest);
        mf.settle(id, ranking, seat);
        assertEq(vault.claimable(p[1]), 15e18);
    }

    function test_matchCreatedBeforeSignerNeverGetsSeatPath() public {
        _linkVault();
        uint256 seatPk = 0x5EA7;
        uint256 id = _openFull(2, FEE);
        vm.prank(owner);
        mf.setOutcomeSigner(vm.addr(seatPk));
        _revealAll(id, 2);
        address[] memory ranking = _ranking(0, 1, 0, 2);
        bytes[] memory seat = new bytes[](1);
        seat[0] = _sign(seatPk, mf.outcomeDigest(id, ranking));
        vm.expectRevert(MatchFactory.OutcomeSignerNotConfigured.selector);
        mf.settle(id, ranking, seat);
        // a lobby opened after the key was set uses it
        uint256 id2 = _openFull(2, FEE);
        assertEq(mf.getMatch(id2).outcomeSigner, vm.addr(seatPk));
        mf.settle(id, ranking, _unanimous(id, ranking, 2));
    }

    function test_createMatchRejectsStaleIdWithoutTakingEntry() public {
        uint256 id = mf.nextMatchId();
        vm.prank(p[1]);
        mf.createMatch(2, FEE, id, _commit(id, 1), 0, 0);
        uint256 before = imd.balanceOf(p[0]);
        vm.prank(p[0]);
        vm.expectRevert(abi.encodeWithSelector(MatchFactory.MatchIdMismatch.selector, id, id + 1));
        mf.createMatch(2, FEE, id, _commit(id, 0), 0, 0);
        assertEq(imd.balanceOf(p[0]), before);
        assertEq(mf.nextMatchId(), id + 1, "a rejected create does not burn an id");
        vm.prank(p[0]);
        vm.expectRevert(abi.encodeWithSelector(MatchFactory.MatchIdMismatch.selector, 0, id + 1));
        mf.createMatch(2, FEE, 0, _commit(id, 0), 0, 0);
    }

    function test_rankingWithZeroAddressRejected() public {
        _linkVault();
        uint256 id = _openFull(3, FEE);
        _revealAll(id, 3);
        address[] memory ranking = _ranking(0, 1, 2, 3);
        ranking[2] = address(0);
        bytes[] memory sigs = _unanimous(id, ranking, 3);
        vm.expectRevert(MatchFactory.InvalidRanking.selector);
        mf.settle(id, ranking, sigs);
    }

    function test_refundsAccumulateAcrossMatches() public {
        uint256 a = _openFull(2, FEE);
        uint256 b = _openFull(2, FEE);
        vm.warp(block.timestamp + mf.REVEAL_WINDOW() + 1);
        mf.cancelUnrevealed(a);
        mf.cancelUnrevealed(b);
        assertEq(mf.refunds(p[0]), 2 * FEE);
        uint256 before = imd.balanceOf(p[0]);
        vm.prank(p[0]);
        assertEq(mf.withdrawRefund(), 2 * FEE);
        assertEq(imd.balanceOf(p[0]) - before, 2 * FEE);
        assertEq(mf.totalRefundsOwed(), 2 * FEE, "p1's two refunds are still owed");
    }

    function test_riskEntryExactOutputReturnsNothing() public {
        _setVenue();
        uint256 id = mf.nextMatchId();
        uint256 imdBefore = imd.balanceOf(p[0]);
        // 10 RISK: 1 burned, 9 routed at 1:1 = exactly the 9 IMD fee
        vm.prank(p[0]);
        mf.createMatch(2, 9e18, id, _commit(id, 0), 10e18, 9e18);
        assertEq(imd.balanceOf(p[0]), imdBefore);
        assertEq(imd.balanceOf(address(mf)), 9e18);
        assertEq(risk.balanceOf(DEAD), 1e18);
    }

    function test_riskEntryBetterRateRefundsExcess() public {
        _setVenue();
        venue.setRate(2, 1);
        uint256 id = mf.nextMatchId();
        uint256 imdBefore = imd.balanceOf(p[0]);
        vm.prank(p[0]);
        mf.createMatch(2, FEE, id, _commit(id, 0), 10e18, FEE);
        // 9 RISK routed -> 18 IMD; fee 10 kept, 8 returned
        assertEq(imd.balanceOf(p[0]) - imdBefore, 8e18);
        assertEq(imd.balanceOf(address(mf)), FEE);
    }

    function test_riskEntryTinyAmountLeavesNoTrace() public {
        _setVenue();
        uint256 id = mf.nextMatchId();
        uint256 riskBefore = risk.balanceOf(p[0]);
        vm.prank(p[0]);
        vm.expectRevert(bytes("slippage"));
        mf.createMatch(2, FEE, id, _commit(id, 0), 9, FEE);
        assertEq(risk.balanceOf(p[0]), riskBefore);
        assertEq(risk.balanceOf(DEAD), 0);
        assertEq(mf.nextMatchId(), id);
    }

    function test_reentrantVenueCannotWithdrawOrReveal() public {
        _setVenue();
        uint256 id = _openFull(2, FEE);
        vm.warp(block.timestamp + mf.REVEAL_WINDOW() + 1);
        mf.cancelUnrevealed(id);
        venue.setReenter(address(mf), abi.encodeCall(MatchFactory.withdrawRefund, ()));
        uint256 id2 = mf.nextMatchId();
        vm.prank(p[0]);
        vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
        mf.createMatch(2, FEE, id2, _commit(id2, 0), 20e18, FEE);
        assertEq(mf.refunds(p[0]), FEE);
    }

    function test_outcomeDigestBindsSeedAndChain() public {
        uint256 id = _openFull(2, FEE);
        address[] memory ranking = _ranking(0, 1, 0, 2);
        bytes32 beforeReveal = mf.outcomeDigest(id, ranking);
        _revealAll(id, 2);
        bytes32 afterReveal = mf.outcomeDigest(id, ranking);
        assertTrue(beforeReveal != afterReveal, "digest commits to the seed");
        vm.chainId(999);
        assertTrue(mf.outcomeDigest(id, ranking) != afterReveal, "digest commits to the chain");
    }

    function test_constructorRejectsZeroAndSameTokens() public {
        vm.expectRevert(Owned.ZeroAddress.selector);
        new MatchFactory(owner, address(imd), address(imd), address(vault), address(buyback));
        vm.expectRevert(Owned.ZeroAddress.selector);
        new MatchFactory(owner, address(imd), address(risk), address(0), address(buyback));
        vm.expectRevert(Owned.ZeroAddress.selector);
        new MatchFactory(address(0), address(imd), address(risk), address(vault), address(buyback));
    }
}

contract PrizeVaultEdgeTest is Fixtures {
    uint96 constant FEE = 10e18;

    function _linkSelf() internal {
        vm.prank(owner);
        vault.setMatchFactory(address(this));
        imd.mint(address(this), 1_000e18);
        imd.approve(address(vault), type(uint256).max);
    }

    function _settleTwo(uint256 a, uint256 b) internal {
        uint256 id = mf.nextMatchId();
        vm.prank(p[a]);
        mf.createMatch(2, FEE, id, _commit(id, a), 0, 0);
        vm.prank(p[b]);
        mf.join(id, _commit(id, b), 0, 0);
        vm.prank(p[a]);
        mf.reveal(id, _secret(a));
        vm.prank(p[b]);
        mf.reveal(id, _secret(b));
        address[] memory ranking = new address[](2);
        ranking[0] = p[a];
        ranking[1] = p[b];
        bytes32 digest = mf.outcomeDigest(id, ranking);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(pks[a], digest);
        sigs[1] = _sign(pks[b], digest);
        mf.settle(id, ranking, sigs);
    }

    function test_awardCountBoundsAndZeroPlacement() public {
        _linkSelf();
        imd.transfer(address(vault), 10e18);
        address[3] memory r = [p[0], p[1], p[2]];
        vm.expectRevert(PrizeVault.InvalidRanking.selector);
        vault.awardMatch(1, r, 1, 10e18, false);
        vm.expectRevert(PrizeVault.InvalidRanking.selector);
        vault.awardMatch(1, r, 4, 10e18, false);
        r[1] = address(0);
        vm.expectRevert(PrizeVault.InvalidRanking.selector);
        vault.awardMatch(1, r, 2, 10e18, false);
    }

    function test_awardWithoutDepositIsUnderfunded() public {
        _linkSelf();
        address[3] memory r = [p[0], p[1], address(0)];
        vm.expectRevert(PrizeVault.Underfunded.selector);
        vault.awardMatch(1, r, 2, 10e18, false);
        imd.transfer(address(vault), 10e18 - 1);
        vm.expectRevert(PrizeVault.Underfunded.selector);
        vault.awardMatch(1, r, 2, 10e18, false);
        imd.transfer(address(vault), 1);
        vault.awardMatch(1, r, 2, 10e18, false);
        assertEq(vault.claimable(p[0]), 7.5e18);
        assertEq(vault.claimable(p[1]), 2.5e18);
    }

    function test_awardBeforeLinkReverts() public {
        address[3] memory r = [p[0], p[1], address(0)];
        vm.expectRevert(PrizeVault.MatchFactoryNotConfigured.selector);
        vault.awardMatch(1, r, 2, 1, false);
        vm.prank(owner);
        vm.expectRevert(Owned.ZeroAddress.selector);
        vault.setMatchFactory(address(0));
    }

    function test_fundBonusZeroAndNoAllowance() public {
        vm.expectRevert(PrizeVault.ZeroAmount.selector);
        vault.fundBonus(0);
        imd.mint(address(this), 1e18);
        vm.expectRevert(SafeTransfer.TransferFailed.selector);
        vault.fundBonus(1e18);
    }

    function test_tinyPrizeRoundsToFirstWithoutConsumingOthersWins() public {
        _linkSelf();
        imd.transfer(address(vault), 1);
        address[3] memory r = [p[0], p[1], p[2]];
        vault.awardMatch(1, r, 3, 1, false);
        assertEq(vault.claimable(p[0]), 1);
        assertEq(vault.claimable(p[1]), 0);
        assertEq(vault.remainingRewardedWins(p[0]), 2);
        assertEq(vault.remainingRewardedWins(p[1]), 3, "a zero share does not count as a rewarded placement");
        assertEq(vault.remainingRewardedWins(p[2]), 3);
    }

    function test_bonusBelowCapAndEmptyPool() public {
        _linkSelf();
        address[3] memory r = [p[0], p[1], address(0)];
        // empty pool: seat-attested prize equals the pot
        imd.transfer(address(vault), 20e18);
        vault.awardMatch(1, r, 2, 20e18, true);
        assertEq(vault.claimable(p[0]) + vault.claimable(p[1]), 20e18);
        // pool 100: bonus = 1% = 1 < cap 10
        vault.fundBonus(100e18);
        imd.transfer(address(vault), 20e18);
        vault.awardMatch(2, r, 2, 20e18, true);
        assertEq(vault.bonusPool(), 99e18);
        assertEq(vault.claimable(p[0]) + vault.claimable(p[1]), 41e18);
        assertEq(imd.balanceOf(address(vault)), vault.totalClaimable() + vault.bonusPool());
    }

    function test_cappedSecondAndThirdPlacesForfeitToPool() public {
        _linkVault();
        for (uint256 i; i < 3; ++i) {
            _settleTwo(0, 1 + i);
        }
        uint256 poolBefore = vault.bonusPool();
        uint256 claimBefore = vault.claimable(p[0]);
        _settleTwo(4, 0); // p0 second: its 25% share goes to the pool
        assertEq(vault.claimable(p[0]), claimBefore);
        assertEq(vault.bonusPool() - poolBefore, 5e18);
        assertEq(vault.claimable(p[4]), 15e18);
    }

    function test_rollingSlotsFreeExactly24hAfterEachPlacement() public {
        _linkVault();
        uint256 t0 = block.timestamp;
        // three rewarded placements one hour apart fill every slot
        for (uint256 i; i < 3; ++i) {
            vm.warp(t0 + i * 1 hours);
            _settleTwo(0, 1 + i);
        }
        uint64[3] memory at = vault.rewardedAt(p[0]);
        assertEq(uint256(at[0]) + at[1] + at[2], 3 * t0 + 3 hours, "slots hold the three timestamps");
        assertEq(vault.nextRewardedWinAt(p[0]), t0 + 24 hours, "the oldest slot frees first");
        vm.warp(t0 + 24 hours - 1);
        assertEq(vault.remainingRewardedWins(p[0]), 0);
        uint256 claimBefore = vault.claimable(p[0]);
        uint256 poolBefore = vault.bonusPool();
        _settleTwo(0, 4);
        assertEq(vault.claimable(p[0]), claimBefore, "still capped one second before the oldest slot frees");
        assertEq(vault.bonusPool() - poolBefore, 15e18, "the capped first place goes to the pool");
        assertEq(vault.claimable(p[4]), 5e18, "the other placement is unaffected");
        vm.warp(t0 + 24 hours);
        assertEq(vault.remainingRewardedWins(p[0]), 1, "only the oldest slot is free");
        _settleTwo(0, 5);
        assertEq(vault.claimable(p[0]), claimBefore + 15e18);
        assertEq(vault.remainingRewardedWins(p[0]), 0, "the freed slot is consumed");
        assertEq(vault.nextRewardedWinAt(p[0]), t0 + 25 hours, "next free slot is the second placement's");
        at = vault.rewardedAt(p[0]);
        assertEq(uint256(at[0]) + at[1] + at[2], 3 * t0 + 27 hours, "the oldest slot was overwritten");
    }

    function test_fourthPlacementInTwentyFourHoursIsForfeitedEvenAsThird() public {
        _linkVault();
        for (uint256 i; i < 3; ++i) {
            _settleTwo(0, 1 + i);
        }
        uint256 claimBefore = vault.claimable(p[0]);
        uint256 poolBefore = vault.bonusPool();
        // p0 third in a three-player match: the 15% share is forfeited, the others are paid
        uint256 id = _openFull(3, FEE);
        _revealAll(id, 3);
        address[] memory ranking = _ranking(1, 2, 0, 3);
        mf.settle(id, ranking, _unanimous(id, ranking, 3));
        assertEq(vault.claimable(p[0]), claimBefore);
        assertEq(vault.bonusPool() - poolBefore, 4.5e18);
        assertEq(vault.claimable(p[1]), 5e18 + 18e18, "p1 keeps its earlier second place and adds first");
        assertEq(imd.balanceOf(address(vault)), vault.totalClaimable() + vault.bonusPool());
    }

    function test_setMatchFactoryIsPermanentAndNeedsCode() public {
        vm.prank(owner);
        vm.expectRevert(PrizeVault.NotAContract.selector);
        vault.setMatchFactory(p[0]);
        _linkVault();
        vm.prank(owner);
        vm.expectRevert(PrizeVault.MatchFactoryAlreadySet.selector);
        vault.setMatchFactory(address(this));
        vm.prank(owner);
        vm.expectRevert(PrizeVault.MatchFactoryAlreadySet.selector);
        vault.setMatchFactory(address(mf));
        assertEq(vault.matchFactory(), address(mf));
    }

    function test_claimTwiceReverts() public {
        _linkVault();
        _settleTwo(0, 1);
        vm.startPrank(p[0]);
        vault.claim();
        vm.expectRevert(PrizeVault.NothingToClaim.selector);
        vault.claim();
        vm.stopPrank();
        assertEq(vault.totalClaimable(), 5e18, "only p1's second place is left");
    }
}

contract CosmeticsEdgeTest is Fixtures {
    function test_capCannotDropBelowSoldButMayEqualIt() public {
        vm.prank(owner);
        cosmetics.configureItem(1, 1e18, 5, true);
        vm.prank(p[0]);
        cosmetics.buy(1, 3);
        vm.prank(owner);
        vm.expectRevert(Cosmetics.InvalidItem.selector);
        cosmetics.configureItem(1, 1e18, 2, true);
        vm.prank(owner);
        cosmetics.configureItem(1, 1e18, 3, true);
        vm.prank(p[0]);
        vm.expectRevert(Cosmetics.SoldOut.selector);
        cosmetics.buy(1, 1);
        // lifting the cap to unlimited reopens sales
        vm.prank(owner);
        cosmetics.configureItem(1, 1e18, 0, true);
        vm.prank(p[0]);
        cosmetics.buy(1, 10);
        assertEq(cosmetics.owned(p[0], 1), 13);
    }

    function test_deactivatedItemAndExactRemainingSupply() public {
        vm.prank(owner);
        cosmetics.configureItem(1, 1e18, 4, true);
        vm.prank(p[0]);
        cosmetics.buy(1, 4);
        (,, uint64 sold,) = cosmetics.items(1);
        assertEq(sold, 4);
        vm.prank(p[1]);
        vm.expectRevert(Cosmetics.SoldOut.selector);
        cosmetics.buy(1, 1);
        vm.prank(owner);
        cosmetics.configureItem(1, 1e18, 0, false);
        vm.prank(p[1]);
        vm.expectRevert(Cosmetics.ItemUnavailable.selector);
        cosmetics.buy(1, 1);
    }

    function test_dustRoundingFavoursVault() public {
        vm.prank(owner);
        cosmetics.configureItem(7, 3, 0, true);
        vm.prank(p[0]);
        cosmetics.buy(7, 1);
        assertEq(imd.balanceOf(address(buyback)), 0);
        assertEq(cosmetics.pendingSeatRewards(), 1);
        assertEq(vault.bonusPool(), 2);
        vm.prank(owner);
        cosmetics.configureItem(8, 1, 0, true);
        vm.prank(p[0]);
        cosmetics.buy(8, 1);
        assertEq(vault.bonusPool(), 3);
        assertEq(cosmetics.totalRevenue(), 4);
        assertEq(cosmetics.totalToVault(), 3);
    }

    function test_buyWithoutFundsReverts() public {
        vm.prank(owner);
        cosmetics.configureItem(1, 2_000e18, 0, true);
        vm.prank(p[0]);
        vm.expectRevert(SafeTransfer.TransferFailed.selector);
        cosmetics.buy(1, 1);
        (,, uint64 sold,) = cosmetics.items(1);
        assertEq(sold, 0, "a failed purchase is not counted");
        assertEq(cosmetics.owned(p[0], 1), 0);
    }

    function test_priceChangeAppliesToLaterBuysOnly() public {
        vm.prank(owner);
        cosmetics.configureItem(1, 10e18, 0, true);
        vm.prank(p[0]);
        assertEq(cosmetics.buy(1, 1), 10e18);
        vm.prank(owner);
        cosmetics.configureItem(1, 20e18, 0, true);
        vm.prank(p[0]);
        assertEq(cosmetics.buy(1, 1), 20e18);
        assertEq(cosmetics.totalRevenue(), 30e18);
    }

    function test_seatRecipientZeroRejected() public {
        vm.prank(owner);
        vm.expectRevert(Owned.ZeroAddress.selector);
        cosmetics.setSeatRewardsRecipient(address(0));
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(Owned.ZeroAddress.selector);
        new Cosmetics(owner, address(imd), address(0), address(buyback));
        vm.expectRevert(Owned.ZeroAddress.selector);
        new Cosmetics(owner, address(imd), address(vault), address(0));
    }
}

contract BuybackEdgeTest is Fixtures {
    function test_executeBuybackZeroInputAndZeroOutput() public {
        _setVenue();
        imd.mint(address(buyback), 10e18);
        vm.prank(owner);
        vm.expectRevert(Buyback.ZeroAmount.selector);
        buyback.executeBuyback(0, 0);
        venue.setRate(0, 1);
        vm.prank(owner);
        vm.expectRevert(Buyback.InsufficientOutput.selector);
        buyback.executeBuyback(10e18, 0);
        assertEq(imd.balanceOf(address(buyback)), 10e18, "nothing spent on a failed buyback");
        assertEq(buyback.totalImdSpent(), 0);
    }

    function test_executeBuybackMoreThanHeldReverts() public {
        _setVenue();
        imd.mint(address(buyback), 10e18);
        // the venue pulls more than the contract holds; the mock token panics and nothing changes
        vm.prank(owner);
        vm.expectRevert();
        buyback.executeBuyback(10e18 + 1, 1);
        assertEq(imd.balanceOf(address(buyback)), 10e18);
        assertEq(buyback.totalImdSpent(), 0);
    }

    function test_routeZeroAndUnderpayingVenue() public {
        _setVenue();
        vm.prank(p[0]);
        risk.approve(address(buyback), type(uint256).max);
        vm.prank(p[0]);
        vm.expectRevert(Buyback.ZeroAmount.selector);
        buyback.routeRiskToImd(0, 0, p[0]);
        venue.setRate(0, 1);
        uint256 before = risk.balanceOf(p[0]);
        vm.prank(p[0]);
        vm.expectRevert(Buyback.InsufficientOutput.selector);
        buyback.routeRiskToImd(1e18, 0, p[0]);
        assertEq(risk.balanceOf(p[0]), before);
    }

    function test_reentrantVenueBlocked() public {
        _setVenue();
        imd.mint(address(buyback), 10e18);
        venue.setReenter(address(buyback), abi.encodeCall(Buyback.burnHeldRisk, ()));
        vm.prank(owner);
        vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
        buyback.executeBuyback(10e18, 0);
    }

    function test_setVenueZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(Owned.ZeroAddress.selector);
        buyback.setVenue(address(0));
    }

    function test_burnTotalsCombineBothPaths() public {
        _setVenue();
        imd.mint(address(buyback), 5e18);
        vm.prank(owner);
        buyback.executeBuyback(5e18, 5e18);
        vm.prank(p[0]);
        risk.transfer(address(buyback), 2e18);
        buyback.burnHeldRisk();
        assertEq(buyback.totalRiskBurned(), 7e18);
        assertEq(buyback.burnedSupply(), 7e18);
        assertEq(buyback.circulatingSupply(), 1e27 - 7e18);
        assertEq(buyback.totalImdSpent(), 5e18);
    }
}

contract OwnedEdgeTest is Fixtures {
    function test_pendingOwnerOnlyAcceptsAndOldOwnerLosesRights() public {
        address n = makeAddr("next");
        vm.prank(p[0]);
        vm.expectRevert(Owned.NotOwner.selector);
        vault.transferOwnership(n);
        vm.prank(owner);
        vault.transferOwnership(n);
        assertEq(vault.pendingOwner(), n);
        vm.prank(owner);
        vm.expectRevert(Owned.NotOwner.selector);
        vault.acceptOwnership();
        vm.prank(n);
        vault.acceptOwnership();
        assertEq(vault.pendingOwner(), address(0));
        vm.prank(owner);
        vm.expectRevert(Owned.NotOwner.selector);
        vault.setMatchFactory(address(mf));
        vm.prank(n);
        vault.setMatchFactory(address(mf));
        assertEq(vault.matchFactory(), address(mf));
    }
}

contract LaunchTokenEdgeTest is Fixtures {
    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(p[0]);
        risk.approve(p[1], type(uint256).max);
        vm.prank(p[1]);
        risk.transferFrom(p[0], p[1], 1e18);
        assertEq(risk.allowance(p[0], p[1]), type(uint256).max);
    }

    function test_zeroAndSelfTransfers() public {
        vm.startPrank(p[0]);
        assertTrue(risk.transfer(p[1], 0));
        assertTrue(risk.transfer(p[0], 1_000e18));
        vm.stopPrank();
        assertEq(risk.balanceOf(p[0]), 1_000e18);
        vm.prank(p[0]);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        risk.transfer(p[1], 1_000e18 + 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferConservesSupply(uint256 amount, address to) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, 1_000e18);
        uint256 fromBefore = risk.balanceOf(p[0]);
        uint256 toBefore = risk.balanceOf(to);
        vm.prank(p[0]);
        risk.transfer(to, amount);
        if (to == p[0]) {
            assertEq(risk.balanceOf(p[0]), fromBefore);
        } else {
            assertEq(fromBefore - risk.balanceOf(p[0]), amount);
            assertEq(risk.balanceOf(to) - toBefore, amount);
        }
        assertEq(risk.totalSupply(), 1e27);
    }
}

contract RiskRulesEdgeTest is Fixtures {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_dieAlwaysOneToSix(bytes32 seed, uint256 b, uint256 k) public pure {
        uint8 d = RiskRules.die(seed, b, k);
        assertTrue(d >= 1 && d <= 6);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_compareLossesEqualPairsAndTiesGoToDefender(
        uint8[3] memory a,
        uint8[2] memory d,
        uint8 na,
        uint8 nd
    ) public pure {
        na = uint8(bound(na, 1, 3));
        nd = uint8(bound(nd, 1, 2));
        for (uint256 i; i < 3; ++i) {
            a[i] = uint8(bound(a[i], 1, 6));
        }
        for (uint256 i; i < 2; ++i) {
            d[i] = uint8(bound(d[i], 1, 6));
        }
        // unused slots zeroed, as resolveBattle does
        for (uint256 i = na; i < 3; ++i) {
            a[i] = 0;
        }
        for (uint256 i = nd; i < 2; ++i) {
            d[i] = 0;
        }
        (uint256 al, uint256 dl) = RiskRules.compare(a, na, d, nd);
        uint256 pairs = na < nd ? na : nd;
        assertEq(al + dl, pairs);
        // the top pair decides at least one loss the way a tie-break rule says it must
        uint8 amax = a[0] > a[1] ? (a[0] > a[2] ? a[0] : a[2]) : (a[1] > a[2] ? a[1] : a[2]);
        uint8 dmax = d[0] > d[1] ? d[0] : d[1];
        if (amax > dmax) assertGe(dl, 1);
        else assertGe(al, 1);
    }

    function test_defenderSixesNeverLoseAndAttackerSixesAlwaysWinAgainstLower() public pure {
        (uint256 al, uint256 dl) = RiskRules.compare([6, 6, 6], 3, [6, 6], 2);
        assertEq(al, 2);
        assertEq(dl, 0);
        (al, dl) = RiskRules.compare([6, 6, 6], 3, [5, 5], 2);
        assertEq(al, 0);
        assertEq(dl, 2);
        (al, dl) = RiskRules.compare([1, 0, 0], 1, [1, 0], 1);
        assertEq(al, 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_reinforcementsBounded(uint64 mask) public pure {
        mask = uint64(bound(mask, 0, (uint64(1) << 42) - 1));
        uint256 total = RiskRules.reinforcements(mask);
        uint256 owned;
        for (uint256 i; i < 42; ++i) {
            if (mask & (uint64(1) << i) != 0) ++owned;
        }
        uint256 base = owned / 3 < 3 ? 3 : owned / 3;
        assertGe(total, base);
        assertLe(total, base + 24);
        if (owned < 4) assertEq(total, 3, "no continent is smaller than 4 territories");
    }

    function test_everyTerritoryBelongsToExactlyOneContinentInOrder() public pure {
        uint256 last;
        for (uint256 t; t < 42; ++t) {
            uint256 c = RiskRules.continentOf(t);
            assertGe(c, last);
            last = c;
            (uint256 first, uint256 count,) = RiskRules.continent(c);
            assertTrue(t >= first && t < first + count);
        }
        assertEq(last, 5);
    }

    function test_invalidContinentReverts() public {
        vm.expectRevert(RiskRules.InvalidContinent.selector);
        this.continentExt(6);
    }

    function continentExt(uint256 c) external pure returns (uint256, uint256, uint256) {
        return RiskRules.continent(c);
    }
}

/// @dev The optimistic propose / dispute / finalize round, driven by the inputs it should refuse:
/// outsiders, repeats, the proposer disputing itself, both sides of every deadline, a ranking that is
/// not the proposed one, and the interaction with expiry, signatures and an unlinked vault.
contract OptimisticSettlementEdgeTest is Fixtures {
    uint96 constant FEE = 10e18;

    function _playing(uint8 n) internal returns (uint256 id) {
        id = _openFull(n, FEE);
        _revealAll(id, n);
    }

    function test_proposeRequiresPlayingStatusAndPlayer() public {
        _linkVault();
        uint256 id = _openFull(3, FEE);
        address[] memory ranking = _ranking(0, 1, 2, 3);
        vm.prank(p[0]);
        vm.expectRevert(MatchFactory.WrongStatus.selector);
        mf.proposeOutcome(id, ranking);
        _revealAll(id, 3);
        vm.prank(p[5]);
        vm.expectRevert(MatchFactory.NotPlayer.selector);
        mf.proposeOutcome(id, ranking);
        vm.prank(owner);
        vm.expectRevert(MatchFactory.NotPlayer.selector);
        mf.proposeOutcome(id, ranking);
        // malformed rankings: wrong length, outsider, duplicate
        vm.startPrank(p[0]);
        vm.expectRevert(MatchFactory.InvalidRanking.selector);
        mf.proposeOutcome(id, _ranking(0, 1, 0, 2));
        address[] memory outsider = _ranking(0, 1, 5, 3);
        vm.expectRevert(MatchFactory.InvalidRanking.selector);
        mf.proposeOutcome(id, outsider);
        address[] memory dup = _ranking(0, 1, 1, 3);
        vm.expectRevert(MatchFactory.InvalidRanking.selector);
        mf.proposeOutcome(id, dup);
        mf.proposeOutcome(id, ranking);
        vm.expectRevert(MatchFactory.AlreadyProposed.selector);
        mf.proposeOutcome(id, ranking);
        vm.stopPrank();
        // nobody else can propose a competing ranking either
        vm.prank(p[1]);
        vm.expectRevert(MatchFactory.AlreadyProposed.selector);
        mf.proposeOutcome(id, _ranking(1, 0, 2, 3));
        MatchFactory.Proposal memory pr = mf.getProposal(id);
        assertEq(pr.proposer, p[0]);
        assertEq(pr.proposedAt, block.timestamp);
        assertEq(pr.rankingHash, keccak256(abi.encode(ranking)));
        assertFalse(pr.disputed);
    }

    function test_proposeDeadlineIsTheSettleGraceInclusive() public {
        _linkVault();
        uint256 id = _playing(2);
        uint256 edge = uint256(mf.getMatch(id).playDeadline) + mf.SETTLE_GRACE();
        vm.warp(edge + 1);
        vm.prank(p[0]);
        vm.expectRevert(MatchFactory.TooLate.selector);
        mf.proposeOutcome(id, _ranking(0, 1, 0, 2));
        uint256 id2 = _playing(2);
        vm.warp(uint256(mf.getMatch(id2).playDeadline) + mf.SETTLE_GRACE());
        vm.prank(p[1]);
        mf.proposeOutcome(id2, _ranking(1, 0, 0, 2));
        // expire is now blocked for good while nobody disputes; finalize pays after the window
        vm.warp(block.timestamp + mf.DISPUTE_WINDOW());
        vm.expectRevert(MatchFactory.ProposalPending.selector);
        mf.expire(id2);
        vm.expectRevert(MatchFactory.TooEarly.selector);
        mf.finalizeProposal(id2, _ranking(1, 0, 0, 2));
        vm.warp(block.timestamp + 1);
        vm.prank(p[5]); // anyone, not only a player
        mf.finalizeProposal(id2, _ranking(1, 0, 0, 2));
        assertEq(vault.claimable(p[1]), 15e18);
        assertEq(vault.claimable(p[0]), 5e18);
        assertEq(uint256(mf.getMatch(id2).status), uint256(MatchFactory.Status.Settled));
    }

    function test_disputeRules() public {
        _linkVault();
        uint256 id = _playing(3);
        vm.prank(p[1]);
        vm.expectRevert(MatchFactory.NoProposal.selector);
        mf.disputeOutcome(id);
        vm.prank(p[0]);
        mf.proposeOutcome(id, _ranking(0, 1, 2, 3));
        vm.prank(p[0]);
        vm.expectRevert(MatchFactory.NotAuthorized.selector);
        mf.disputeOutcome(id);
        vm.prank(p[5]);
        vm.expectRevert(MatchFactory.NotPlayer.selector);
        mf.disputeOutcome(id);
        uint256 edge = block.timestamp + mf.DISPUTE_WINDOW();
        vm.warp(edge + 1);
        vm.prank(p[2]);
        vm.expectRevert(MatchFactory.TooLate.selector);
        mf.disputeOutcome(id);
        // a second match: dispute at the last second is accepted and is final
        uint256 id2 = _playing(3);
        vm.prank(p[0]);
        mf.proposeOutcome(id2, _ranking(0, 1, 2, 3));
        vm.warp(block.timestamp + mf.DISPUTE_WINDOW());
        vm.prank(p[2]);
        mf.disputeOutcome(id2);
        assertTrue(mf.getProposal(id2).disputed);
        vm.prank(p[1]);
        vm.expectRevert(MatchFactory.NoProposal.selector);
        mf.disputeOutcome(id2);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(MatchFactory.NoProposal.selector);
        mf.finalizeProposal(id2, _ranking(0, 1, 2, 3));
        // no second proposal after a dispute: the disputed one still occupies the slot
        vm.prank(p[2]);
        vm.expectRevert(MatchFactory.AlreadyProposed.selector);
        mf.proposeOutcome(id2, _ranking(2, 1, 0, 3));
    }

    function test_finalizeOnlyTheProposedRankingAndOnlyOnce() public {
        _linkVault();
        uint256 id = _playing(3);
        address[] memory ranking = _ranking(2, 0, 1, 3);
        vm.prank(p[2]);
        mf.proposeOutcome(id, ranking);
        vm.warp(block.timestamp + mf.DISPUTE_WINDOW() + 1);
        vm.expectRevert(MatchFactory.InvalidRanking.selector);
        mf.finalizeProposal(id, _ranking(2, 1, 0, 3));
        vm.expectRevert(MatchFactory.InvalidRanking.selector);
        mf.finalizeProposal(id, _ranking(2, 0, 0, 2));
        vm.expectRevert(MatchFactory.InvalidRanking.selector);
        mf.finalizeProposal(id, new address[](0));
        uint256 potBefore = imd.balanceOf(address(mf));
        mf.finalizeProposal(id, ranking);
        assertEq(potBefore - imd.balanceOf(address(mf)), 30e18);
        assertEq(vault.claimable(p[2]), 18e18);
        assertEq(vault.claimable(p[0]), 7.5e18);
        assertEq(vault.claimable(p[1]), 4.5e18);
        vm.expectRevert(MatchFactory.WrongStatus.selector);
        mf.finalizeProposal(id, ranking);
        bytes[] memory sigs = _unanimous(id, ranking, 3);
        vm.expectRevert(MatchFactory.WrongStatus.selector);
        mf.settle(id, ranking, sigs);
        vm.expectRevert(MatchFactory.WrongStatus.selector);
        mf.expire(id);
        vm.prank(p[0]);
        vm.expectRevert(MatchFactory.WrongStatus.selector);
        mf.disputeOutcome(id);
    }

    function test_finalizeNeverDrawsTheBonusPool() public {
        _linkVault();
        uint256 seatPk = 0x5EA7;
        vm.prank(owner);
        mf.setOutcomeSigner(vm.addr(seatPk));
        imd.mint(address(this), 1_000e18);
        imd.approve(address(vault), 1_000e18);
        vault.fundBonus(1_000e18);
        uint256 id = _playing(2);
        vm.prank(p[0]);
        mf.proposeOutcome(id, _ranking(0, 1, 0, 2));
        vm.warp(block.timestamp + mf.DISPUTE_WINDOW() + 1);
        mf.finalizeProposal(id, _ranking(0, 1, 0, 2));
        assertEq(vault.bonusPool(), 1_000e18, "optimistic settlement leaves the pool alone");
        assertEq(vault.claimable(p[0]) + vault.claimable(p[1]), 20e18);
    }

    function test_signaturesOverrideAPendingOrDisputedProposal() public {
        _linkVault();
        uint256 seatPk = 0x5EA7;
        vm.prank(owner);
        mf.setOutcomeSigner(vm.addr(seatPk));
        // pending proposal, unanimous settlement with a different ranking wins
        uint256 id = _playing(2);
        vm.prank(p[0]);
        mf.proposeOutcome(id, _ranking(0, 1, 0, 2));
        address[] memory truth = _ranking(1, 0, 0, 2);
        mf.settle(id, truth, _unanimous(id, truth, 2));
        assertEq(vault.claimable(p[1]), 15e18);
        vm.warp(block.timestamp + mf.DISPUTE_WINDOW() + 1);
        vm.expectRevert(MatchFactory.WrongStatus.selector);
        mf.finalizeProposal(id, _ranking(0, 1, 0, 2));
        // disputed proposal, seat signer settles and draws the bonus
        imd.mint(address(this), 100e18);
        imd.approve(address(vault), 100e18);
        vault.fundBonus(100e18);
        uint256 id2 = _playing(2);
        vm.prank(p[0]);
        mf.proposeOutcome(id2, _ranking(0, 1, 0, 2));
        vm.prank(p[1]);
        mf.disputeOutcome(id2);
        bytes[] memory seat = new bytes[](1);
        seat[0] = _sign(seatPk, mf.outcomeDigest(id2, truth));
        mf.settle(id2, truth, seat);
        assertEq(vault.bonusPool(), 99e18, "seat settlement after a dispute still draws the bonus");
        assertEq(vault.claimable(p[1]), 15e18 + 15.75e18);
    }

    function test_expireBlockedByPendingProposalUnlessDisputed() public {
        _linkVault();
        // A: an early proposal whose dispute window closes before the grace period ends
        uint256 a = _playing(2);
        vm.prank(p[0]);
        mf.proposeOutcome(a, _ranking(0, 1, 0, 2));
        uint256 graceEnd = uint256(mf.getMatch(a).playDeadline) + mf.SETTLE_GRACE();
        vm.warp(block.timestamp + mf.DISPUTE_WINDOW() + 1);
        assertLe(block.timestamp, graceEnd);
        vm.prank(p[1]);
        vm.expectRevert(MatchFactory.TooLate.selector);
        mf.disputeOutcome(a);
        vm.expectRevert(MatchFactory.TooEarly.selector);
        mf.expire(a);
        vm.warp(graceEnd + 1);
        vm.expectRevert(MatchFactory.ProposalPending.selector);
        mf.expire(a);
        mf.finalizeProposal(a, _ranking(0, 1, 0, 2));
        assertEq(vault.claimable(p[0]), 15e18);
        // B: a disputed proposal does not block expiry
        uint256 b = _playing(2);
        vm.prank(p[0]);
        mf.proposeOutcome(b, _ranking(0, 1, 0, 2));
        vm.prank(p[1]);
        mf.disputeOutcome(b);
        vm.warp(uint256(mf.getMatch(b).playDeadline) + mf.SETTLE_GRACE());
        vm.expectRevert(MatchFactory.TooEarly.selector);
        mf.expire(b);
        vm.warp(block.timestamp + 1);
        mf.expire(b);
        assertEq(mf.refunds(p[0]), FEE);
        assertEq(mf.refunds(p[1]), FEE);
        assertEq(uint256(mf.getMatch(b).status), uint256(MatchFactory.Status.Cancelled));
        vm.warp(block.timestamp + mf.DISPUTE_WINDOW());
        vm.expectRevert(MatchFactory.WrongStatus.selector);
        mf.finalizeProposal(b, _ranking(0, 1, 0, 2));
    }

    function test_unlinkedVaultCannotFinalizeButCanExpire() public {
        uint256 id = _playing(2);
        vm.prank(p[1]);
        mf.proposeOutcome(id, _ranking(1, 0, 0, 2));
        vm.warp(uint256(mf.getMatch(id).playDeadline) + mf.SETTLE_GRACE() + 1);
        vm.expectRevert(PrizeVault.MatchFactoryNotConfigured.selector);
        mf.finalizeProposal(id, _ranking(1, 0, 0, 2));
        assertEq(
            uint256(mf.getMatch(id).status), uint256(MatchFactory.Status.Playing), "failed finalize changes nothing"
        );
        assertEq(imd.balanceOf(address(mf)), 2 * FEE);
        mf.expire(id);
        assertEq(mf.totalRefundsOwed(), 2 * FEE);
    }

    function test_proposalDoesNotBlockUnrelatedMatchesOrReuseAcrossIds() public {
        _linkVault();
        uint256 a = _playing(2);
        uint256 b = _playing(2);
        vm.prank(p[0]);
        mf.proposeOutcome(a, _ranking(0, 1, 0, 2));
        assertEq(mf.getProposal(b).proposedAt, 0);
        vm.warp(uint256(mf.getMatch(b).playDeadline) + mf.SETTLE_GRACE() + 1);
        mf.expire(b);
        vm.expectRevert(MatchFactory.ProposalPending.selector);
        mf.expire(a);
        mf.finalizeProposal(a, _ranking(0, 1, 0, 2));
        assertEq(vault.totalClaimable(), 20e18);
        assertEq(mf.totalRefundsOwed(), 20e18);
        assertEq(imd.balanceOf(address(mf)), 20e18);
    }

    function test_cappedProposerForfeitsOwnShareToPool() public {
        _linkVault();
        // p0 proposes itself first, then wins three other matches while the dispute window runs
        uint256 id4 = _playing(2);
        vm.prank(p[0]);
        mf.proposeOutcome(id4, _ranking(0, 1, 0, 2));
        vm.warp(block.timestamp + 23 hours);
        for (uint256 i; i < 3; ++i) {
            uint256 id = mf.nextMatchId();
            vm.prank(p[0]);
            mf.createMatch(2, FEE, id, _commit(id, 0), 0, 0);
            vm.prank(p[2 + i]);
            mf.join(id, _commit(id, 2 + i), 0, 0);
            vm.prank(p[0]);
            mf.reveal(id, _secret(0));
            vm.prank(p[2 + i]);
            mf.reveal(id, _secret(2 + i));
            address[] memory r = _ranking(0, 2 + i, 0, 2);
            bytes32 digest = mf.outcomeDigest(id, r);
            bytes[] memory sigs = new bytes[](2);
            sigs[0] = _sign(pks[0], digest);
            sigs[1] = _sign(pks[2 + i], digest);
            mf.settle(id, r, sigs);
        }
        assertEq(vault.remainingRewardedWins(p[0]), 0);
        assertEq(vault.remainingRewardedWins(p[1]), 3);
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 poolBefore = vault.bonusPool();
        uint256 p0Before = vault.claimable(p[0]);
        mf.finalizeProposal(id4, _ranking(0, 1, 0, 2));
        assertEq(vault.claimable(p[0]), p0Before, "fourth placement in 24h pays nothing");
        assertEq(vault.bonusPool() - poolBefore, 15e18, "only the proposer's share is forfeited");
        assertEq(vault.claimable(p[1]), 5e18, "the uncapped runner-up is paid");
        assertEq(imd.balanceOf(address(vault)), vault.totalClaimable() + vault.bonusPool());
    }
}
