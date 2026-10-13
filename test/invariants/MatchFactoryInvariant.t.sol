// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {Buyback} from "../../src/Buyback.sol";
import {PrizeVault} from "../../src/PrizeVault.sol";
import {MatchFactory} from "../../src/MatchFactory.sol";
import {MockERC20, MockVenue} from "../utils/Fixtures.sol";

/// @dev Drives the full match lifecycle (IMD and RISK entries, early/late lobby close, partial reveals,
/// unanimous and seat-attested settlement, expiry, refunds, claims, time) with six signing actors.
/// Every handler call pre-checks the contract state it needs so that an unexpected revert is a failure
/// (fail-on-revert is on), and asserts the exact per-call accounting it can know.
contract MatchHandler is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant N = 6;

    MatchFactory public mf;
    PrizeVault public vault;
    Buyback public buyback;
    MockERC20 public imd;
    LaunchToken public risk;
    MockVenue public venue;

    address public owner;
    address public sponsor;
    uint256 public seatPk = 0x5EA7;
    address public seatSigner;
    uint256[N] public pks = [uint256(0xA11CE), 0xB0B, 0xCA401, 0xD00D, 0xE11E, 0xF00D];
    address[N] public actors;
    mapping(address => uint256) public pkOf;

    // ---- ghost state
    uint256 public ghostImdIn; // entry fees that reached the factory (IMD path and RISK route alike)
    uint256 public ghostImdPaidByActors; // entry fees actors paid out of their own IMD
    uint256 public ghostBonusFunded; // sponsor IMD into the vault bonus pool
    uint256 public ghostImdOut; // refunds withdrawn + prizes claimed
    uint256 public ghostRefundsWithdrawn;
    uint256 public ghostRiskBurned;
    uint256 public ghostExcessReturned; // IMD the venue paid above the fee, handed back to the player
    uint256 public ghostCancelledPots;
    uint256 public ghostSettledPots;
    uint256 public ghostBonusTaken;
    uint256 public ghostAwarded;
    uint256 public ghostForfeited;
    mapping(uint256 => MatchFactory.Status) public ghostTerminal;
    mapping(address => uint256[]) internal _rewardedAt;
    mapping(string => uint256) public calls;

    constructor(
        MatchFactory mf_,
        PrizeVault vault_,
        Buyback buyback_,
        MockERC20 imd_,
        LaunchToken risk_,
        MockVenue venue_,
        address owner_
    ) {
        mf = mf_;
        vault = vault_;
        buyback = buyback_;
        imd = imd_;
        risk = risk_;
        venue = venue_;
        owner = owner_;
        sponsor = makeAddr("sponsor");
        seatSigner = vm.addr(seatPk);
        for (uint256 i; i < N; ++i) {
            actors[i] = vm.addr(pks[i]);
            pkOf[actors[i]] = pks[i];
        }
    }

    function rewardedCount(address a) external view returns (uint256) {
        return _rewardedAt[a].length;
    }

    function rewardedAt(address a, uint256 i) external view returns (uint256) {
        return _rewardedAt[a][i];
    }

    // ------------------------------------------------------------------ actions

    function createMatch(uint256 actorSeed, uint8 maxPlayers, uint256 fee, bool payRisk, uint256 riskSeed) external {
        calls["createMatch"]++;
        fee = bound(fee, mf.MIN_ENTRY(), 1_000e18);
        (uint256 riskIn, uint256 minOut) = _riskArgs(payRisk, fee, riskSeed);
        _create(actors[actorSeed % N], uint8(bound(maxPlayers, 2, 6)), fee, riskIn, minOut);
    }

    function _create(address a, uint8 maxPlayers, uint256 fee, uint256 riskIn, uint256 minOut) internal {
        uint256 id = mf.nextMatchId();
        bytes32 c = mf.commitmentFor(id, a, _secret(id, a));
        uint256 imdBefore = imd.balanceOf(a);
        uint256 mfBefore = imd.balanceOf(address(mf));
        vm.prank(a);
        mf.createMatch(maxPlayers, uint96(fee), c, riskIn, minOut);
        assertEq(mf.nextMatchId(), id + 1, "match id");
        _afterJoin(a, fee, riskIn, imdBefore, mfBefore);
        MatchFactory.Match memory m = mf.getMatch(id);
        assertEq(m.creator, a);
        assertEq(m.playerCount, 1);
        assertEq(uint256(m.status), uint256(MatchFactory.Status.Open));
        assertEq(m.pot, fee);
    }

    function join(uint256 seed, uint256 actorSeed, bool payRisk, uint256 riskSeed, bool fillLobby) external {
        calls["join"]++;
        uint256 id = _find(seed, MatchFactory.Status.Open);
        if (id == 0) return;
        uint256 rounds = fillLobby ? 6 : 1;
        for (uint256 r; r < rounds; ++r) {
            if (!_joinOne(id, actorSeed % N + r, payRisk, riskSeed)) return;
        }
    }

    function _joinOne(uint256 id, uint256 actorSeed, bool payRisk, uint256 riskSeed) internal returns (bool) {
        MatchFactory.Match memory m = mf.getMatch(id);
        if (block.timestamp > m.joinDeadline || m.playerCount >= m.maxPlayers) return false;
        address a = _freeActor(id, actorSeed);
        if (a == address(0)) return false;
        uint256 fee = m.entryFee;
        (uint256 riskIn, uint256 minOut) = _riskArgs(payRisk, fee, riskSeed);
        bytes32 c = mf.commitmentFor(id, a, _secret(id, a));
        uint256 imdBefore = imd.balanceOf(a);
        uint256 mfBefore = imd.balanceOf(address(mf));
        vm.prank(a);
        mf.join(id, c, riskIn, minOut);
        calls["joinOk"]++;
        _afterJoin(a, fee, riskIn, imdBefore, mfBefore);
        MatchFactory.Match memory after_ = mf.getMatch(id);
        assertEq(after_.playerCount, m.playerCount + 1, "player count");
        if (after_.playerCount == after_.maxPlayers) {
            assertEq(uint256(after_.status), uint256(MatchFactory.Status.Revealing), "full lobby reveals");
        } else {
            assertEq(uint256(after_.status), uint256(MatchFactory.Status.Open), "lobby stays open");
        }
        return true;
    }

    function startReveal(uint256 seed, uint256 actorSeed) external {
        calls["startReveal"]++;
        uint256 id = _find(seed, MatchFactory.Status.Open);
        if (id == 0) return;
        MatchFactory.Match memory m = mf.getMatch(id);
        bool expired = block.timestamp > m.joinDeadline;
        address caller = expired ? actors[actorSeed % N] : m.creator;
        if (!expired && m.playerCount < mf.MIN_PLAYERS()) return;
        uint256 owedBefore = mf.totalRefundsOwed();
        vm.prank(caller);
        mf.startReveal(id);
        calls["startRevealOk"]++;
        MatchFactory.Match memory after_ = mf.getMatch(id);
        if (m.playerCount < mf.MIN_PLAYERS()) {
            assertEq(uint256(after_.status), uint256(MatchFactory.Status.Cancelled), "underfilled cancels");
            assertEq(mf.totalRefundsOwed() - owedBefore, m.pot, "underfilled refund");
            ghostCancelledPots += m.pot;
            ghostTerminal[id] = MatchFactory.Status.Cancelled;
        } else {
            assertEq(uint256(after_.status), uint256(MatchFactory.Status.Revealing), "closed lobby reveals");
            assertEq(after_.pot, m.pot, "pot unchanged");
        }
    }

    function reveal(uint256 seed, uint256 actorSeed, bool everyone) external {
        calls["reveal"]++;
        uint256 id = _find(seed, MatchFactory.Status.Revealing);
        if (id == 0) return;
        uint256 rounds = everyone ? 6 : 1;
        for (uint256 r; r < rounds; ++r) {
            if (!_revealOne(id, actorSeed % N + r)) return;
        }
    }

    function _revealOne(uint256 id, uint256 actorSeed) internal returns (bool) {
        MatchFactory.Match memory m = mf.getMatch(id);
        if (block.timestamp > m.revealDeadline) return false;
        address[] memory players = mf.playersOf(id);
        address a;
        for (uint256 k; k < players.length; ++k) {
            address c = players[(actorSeed % players.length + k) % players.length];
            if (!mf.revealed(id, c)) {
                a = c;
                break;
            }
        }
        if (a == address(0)) return false;
        vm.prank(a);
        mf.reveal(id, _secret(id, a));
        calls["revealOk"]++;
        MatchFactory.Match memory after_ = mf.getMatch(id);
        assertTrue(mf.revealed(id, a), "marked revealed");
        assertEq(after_.revealedCount, m.revealedCount + 1, "revealed count");
        assertEq(after_.seed, m.seed ^ keccak256(abi.encode(_secret(id, a))), "seed xor");
        if (after_.revealedCount == after_.playerCount) {
            assertEq(uint256(after_.status), uint256(MatchFactory.Status.Playing), "all revealed -> playing");
        } else {
            assertEq(uint256(after_.status), uint256(MatchFactory.Status.Revealing));
        }
        return true;
    }

    function cancelUnrevealed(uint256 seed) external {
        calls["cancelUnrevealed"]++;
        uint256 id = _find(seed, MatchFactory.Status.Revealing);
        if (id == 0) return;
        MatchFactory.Match memory m = mf.getMatch(id);
        if (block.timestamp <= m.revealDeadline) return;
        address[] memory players = mf.playersOf(id);
        uint256[] memory before = new uint256[](players.length);
        for (uint256 i; i < players.length; ++i) {
            before[i] = mf.refunds(players[i]);
        }
        uint256 owedBefore = mf.totalRefundsOwed();
        mf.cancelUnrevealed(id);
        calls["cancelOk"]++;
        uint256 revealers;
        for (uint256 i; i < players.length; ++i) {
            uint256 delta = mf.refunds(players[i]) - before[i];
            if (mf.revealed(id, players[i])) {
                ++revealers;
                assertGe(delta, m.entryFee, "revealer gets at least their entry");
            } else if (m.revealedCount != 0) {
                assertEq(delta, 0, "non-revealer forfeits");
            } else {
                assertEq(delta, m.entryFee, "nobody revealed: full refund");
            }
        }
        assertEq(mf.totalRefundsOwed() - owedBefore, m.pot, "whole pot refunded");
        assertEq(uint256(mf.getMatch(id).status), uint256(MatchFactory.Status.Cancelled));
        ghostCancelledPots += m.pot;
        ghostTerminal[id] = MatchFactory.Status.Cancelled;
    }

    function settle(uint256 seed, uint256 rankSeed, bool useSeat) external {
        calls["settle"]++;
        uint256 id = _find(seed, MatchFactory.Status.Playing);
        if (id == 0) return;
        MatchFactory.Match memory m = mf.getMatch(id);
        if (block.timestamp > uint256(m.playDeadline) + mf.SETTLE_GRACE()) return;
        address[] memory ranking = _ranking(mf.playersOf(id), rankSeed);
        bool seat = useSeat && mf.outcomeSigner() == seatSigner;
        bytes[] memory sigs = _sigs(id, ranking, seat);
        uint256 poolBefore = vault.bonusPool();
        uint256 bonus;
        if (seat) {
            bonus = poolBefore * vault.BONUS_POOL_BPS_PER_MATCH() / vault.BPS();
            uint256 cap = m.pot * vault.BONUS_MAX_POT_BPS() / vault.BPS();
            if (bonus > cap) bonus = cap;
        }
        (uint256[] memory before, bool[] memory eligible) = _snapshot(ranking);
        mf.settle(id, ranking, sigs);
        calls["settleOk"]++;
        _checkAward(id, ranking, m.pot + bonus, before, eligible);
        assertEq(vault.bonusPool(), poolBefore - bonus + (m.pot + bonus - _sumAwarded(ranking, before)), "pool delta");
        assertEq(mf.getMatch(id).pot, 0, "pot cleared");
        if (seat) calls["settleSeat"]++;
        ghostSettledPots += m.pot;
        ghostBonusTaken += bonus;
        ghostTerminal[id] = MatchFactory.Status.Settled;
    }

    function expire(uint256 seed) external {
        calls["expire"]++;
        uint256 id = _find(seed, MatchFactory.Status.Playing);
        if (id == 0) return;
        MatchFactory.Match memory m = mf.getMatch(id);
        if (block.timestamp <= uint256(m.playDeadline) + mf.SETTLE_GRACE()) return;
        address[] memory players = mf.playersOf(id);
        uint256[] memory before = new uint256[](players.length);
        for (uint256 i; i < players.length; ++i) {
            before[i] = mf.refunds(players[i]);
        }
        mf.expire(id);
        calls["expireOk"]++;
        for (uint256 i; i < players.length; ++i) {
            assertEq(mf.refunds(players[i]) - before[i], m.entryFee, "expired match refunds the entry");
        }
        ghostCancelledPots += m.pot;
        ghostTerminal[id] = MatchFactory.Status.Cancelled;
    }

    function withdrawRefund(uint256 actorSeed) external {
        calls["withdrawRefund"]++;
        address a = actors[actorSeed % N];
        uint256 owed = mf.refunds(a);
        if (owed == 0) return;
        uint256 before = imd.balanceOf(a);
        vm.prank(a);
        uint256 got = mf.withdrawRefund();
        assertEq(got, owed);
        assertEq(imd.balanceOf(a) - before, owed, "refund paid in full");
        assertEq(mf.refunds(a), 0);
        ghostImdOut += owed;
        ghostRefundsWithdrawn += owed;
    }

    function claim(uint256 actorSeed) external {
        calls["claim"]++;
        address a = actors[actorSeed % N];
        uint256 owed = vault.claimable(a);
        if (owed == 0) return;
        uint256 before = imd.balanceOf(a);
        vm.prank(a);
        uint256 got = vault.claim();
        assertEq(got, owed);
        assertEq(imd.balanceOf(a) - before, owed, "prize paid in full");
        assertEq(vault.claimable(a), 0);
        ghostImdOut += owed;
    }

    function fundBonus(uint256 amount) external {
        calls["fundBonus"]++;
        amount = bound(amount, 1, 500e18);
        imd.mint(sponsor, amount);
        vm.startPrank(sponsor);
        imd.approve(address(vault), amount);
        vault.fundBonus(amount);
        vm.stopPrank();
        ghostBonusFunded += amount;
    }

    function setSeatSigner(bool enabled) external {
        calls["setSeatSigner"]++;
        vm.prank(owner);
        mf.setOutcomeSigner(enabled ? seatSigner : address(0));
    }

    function warp(uint256 delta) external {
        calls["warp"]++;
        // Mostly short hops so lobbies fill and reveal; sometimes past every window so expiry paths run.
        delta = delta % 5 == 0 ? bound(delta, 0, 40 hours) : bound(delta, 0, 20 minutes);
        vm.warp(block.timestamp + delta);
    }

    // ------------------------------------------------------------------ helpers

    function _secret(uint256 id, address a) internal pure returns (bytes32) {
        return keccak256(abi.encode("pepe-risk-secret", id, a));
    }

    function secretOf(uint256 id, address a) external pure returns (bytes32) {
        return _secret(id, a);
    }

    function _riskArgs(bool payRisk, uint256 fee, uint256 seed) internal pure returns (uint256 riskIn, uint256 minOut) {
        if (!payRisk) return (0, 0);
        // venue is 1:1; 90% of riskIn must cover the fee
        riskIn = bound(seed, fee * 10 / 9 + 2, fee * 2);
        minOut = fee;
    }

    function _afterJoin(address a, uint256 fee, uint256 riskIn, uint256 imdBefore, uint256 mfBefore) internal {
        assertEq(imd.balanceOf(address(mf)) - mfBefore, fee, "factory gains exactly the fee");
        if (riskIn == 0) {
            assertEq(imdBefore - imd.balanceOf(a), fee, "IMD entry costs the fee");
            ghostImdPaidByActors += fee;
        } else {
            uint256 burned = riskIn * mf.RISK_ENTRY_BURN_BPS() / mf.BPS();
            uint256 routed = riskIn - burned;
            assertEq(imd.balanceOf(a) - imdBefore, routed - fee, "excess IMD returned");
            ghostRiskBurned += burned;
            ghostExcessReturned += routed - fee;
            calls["joinRisk"]++;
        }
        ghostImdIn += fee;
    }

    function _find(uint256 seed, MatchFactory.Status st) internal view returns (uint256) {
        uint256 n = mf.nextMatchId() - 1;
        if (n == 0) return 0;
        uint256 start = seed % n;
        for (uint256 k; k < n; ++k) {
            uint256 id = (start + k) % n + 1;
            if (mf.getMatch(id).status == st) return id;
        }
        return 0;
    }

    function _freeActor(uint256 id, uint256 seed) internal view returns (address) {
        for (uint256 k; k < N; ++k) {
            address a = actors[(seed % N + k) % N];
            if (mf.commitOf(id, a) == bytes32(0)) return a;
        }
        return address(0);
    }

    function _ranking(address[] memory players, uint256 seed) internal pure returns (address[] memory r) {
        uint256 n = players.length;
        for (uint256 i; i < n; ++i) {
            uint256 j = i + (uint256(keccak256(abi.encode(seed, i))) % (n - i));
            (players[i], players[j]) = (players[j], players[i]);
        }
        uint256 len = n < 3 ? n : 3;
        r = new address[](len);
        for (uint256 i; i < len; ++i) {
            r[i] = players[i];
        }
    }

    function _sigs(uint256 id, address[] memory ranking, bool seat) internal view returns (bytes[] memory sigs) {
        bytes32 digest = mf.outcomeDigest(id, ranking);
        if (seat) {
            sigs = new bytes[](1);
            sigs[0] = _sign(seatPk, digest);
            return sigs;
        }
        address[] memory players = mf.playersOf(id);
        sigs = new bytes[](players.length);
        for (uint256 i; i < players.length; ++i) {
            sigs[i] = _sign(pkOf[players[i]], digest);
        }
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _snapshot(address[] memory ranking)
        internal
        view
        returns (uint256[] memory before, bool[] memory eligible)
    {
        before = new uint256[](ranking.length);
        eligible = new bool[](ranking.length);
        for (uint256 i; i < ranking.length; ++i) {
            before[i] = vault.claimable(ranking[i]);
            eligible[i] = vault.remainingRewardedWins(ranking[i]) > 0;
        }
    }

    function _shares(uint256 prize, uint256 n) internal view returns (uint256[3] memory s) {
        s[1] = prize * vault.SECOND_BPS() / vault.BPS();
        if (n == 3) s[2] = prize * vault.THIRD_BPS() / vault.BPS();
        s[0] = prize - s[1] - s[2];
    }

    function _checkAward(
        uint256 id,
        address[] memory ranking,
        uint256 prize,
        uint256[] memory before,
        bool[] memory eligible
    ) internal {
        uint256[3] memory shares = _shares(prize, ranking.length);
        uint256 awarded;
        for (uint256 i; i < ranking.length; ++i) {
            uint256 delta = vault.claimable(ranking[i]) - before[i];
            if (eligible[i]) {
                assertEq(delta, shares[i], "placement paid its share");
                _rewardedAt[ranking[i]].push(block.timestamp);
            } else {
                assertEq(delta, 0, "capped placement is not paid");
                calls["forfeited"]++;
            }
            awarded += delta;
        }
        ghostAwarded += awarded;
        ghostForfeited += prize - awarded;
        assertEq(uint256(mf.getMatch(id).status), uint256(MatchFactory.Status.Settled));
    }

    function _sumAwarded(address[] memory ranking, uint256[] memory before) internal view returns (uint256 sum) {
        for (uint256 i; i < ranking.length; ++i) {
            sum += vault.claimable(ranking[i]) - before[i];
        }
    }
}

contract MatchFactoryInvariantTest is StdInvariant, Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    MockERC20 imd;
    LaunchToken risk;
    Buyback buyback;
    PrizeVault vault;
    MatchFactory mf;
    MockVenue venue;
    MatchHandler h;
    address owner = makeAddr("owner");
    address deployer = makeAddr("launchFactory");

    function setUp() public {
        vm.warp(1_800_000_000);
        imd = new MockERC20();
        vm.startPrank(deployer);
        risk = new LaunchToken();
        buyback = new Buyback(owner, address(imd), address(risk));
        vault = new PrizeVault(owner, address(imd));
        mf = new MatchFactory(owner, address(imd), address(risk), address(vault), address(buyback));
        vm.stopPrank();
        venue = new MockVenue();
        vm.startPrank(owner);
        vault.setMatchFactory(address(mf));
        buyback.setVenue(address(venue));
        vm.stopPrank();
        imd.mint(address(venue), 1e30);
        vm.prank(deployer);
        risk.transfer(address(venue), 1e26);

        h = new MatchHandler(mf, vault, buyback, imd, risk, venue, owner);
        for (uint256 i; i < 6; ++i) {
            address a = h.actors(i);
            imd.mint(a, 1e24);
            vm.prank(deployer);
            risk.transfer(a, 1e24);
            vm.startPrank(a);
            imd.approve(address(mf), type(uint256).max);
            risk.approve(address(mf), type(uint256).max);
            vm.stopPrank();
        }

        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](12);
        sel[0] = MatchHandler.createMatch.selector;
        sel[1] = MatchHandler.join.selector;
        sel[2] = MatchHandler.startReveal.selector;
        sel[3] = MatchHandler.reveal.selector;
        sel[4] = MatchHandler.cancelUnrevealed.selector;
        sel[5] = MatchHandler.settle.selector;
        sel[6] = MatchHandler.expire.selector;
        sel[7] = MatchHandler.withdrawRefund.selector;
        sel[8] = MatchHandler.claim.selector;
        sel[9] = MatchHandler.fundBonus.selector;
        sel[10] = MatchHandler.setSeatSigner.selector;
        sel[11] = MatchHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    function _livePots() internal view returns (uint256 sum) {
        uint256 n = mf.nextMatchId();
        for (uint256 id = 1; id < n; ++id) {
            MatchFactory.Match memory m = mf.getMatch(id);
            if (
                m.status == MatchFactory.Status.Open || m.status == MatchFactory.Status.Revealing
                    || m.status == MatchFactory.Status.Playing
            ) sum += m.pot;
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_factoryHoldsLivePotsPlusRefunds() public view {
        assertEq(imd.balanceOf(address(mf)), _livePots() + mf.totalRefundsOwed(), "factory IMD = live pots + owed");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_refundLedgerMatchesTotal() public view {
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            sum += mf.refunds(h.actors(i));
        }
        assertEq(sum, mf.totalRefundsOwed(), "sum refunds = totalRefundsOwed");
        assertEq(h.ghostCancelledPots(), mf.totalRefundsOwed() + h.ghostRefundsWithdrawn(), "cancelled pots = refunds");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_vaultSolventAndLedgerMatches() public view {
        assertEq(
            imd.balanceOf(address(vault)), vault.totalClaimable() + vault.bonusPool(), "vault IMD = claimable + pool"
        );
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            sum += vault.claimable(h.actors(i));
        }
        assertEq(sum, vault.totalClaimable(), "sum claimable = totalClaimable");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_imdConservation() public view {
        assertEq(
            imd.balanceOf(address(mf)) + imd.balanceOf(address(vault)) + h.ghostImdOut(),
            h.ghostImdIn() + h.ghostBonusFunded(),
            "IMD in = IMD held + IMD out"
        );
        assertEq(
            h.ghostSettledPots() + h.ghostBonusTaken(), h.ghostAwarded() + h.ghostForfeited(), "prize split conserves"
        );
        assertEq(vault.bonusPool(), h.ghostBonusFunded() + h.ghostForfeited() - h.ghostBonusTaken(), "pool ledger");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_riskBurnedNotStranded() public view {
        assertEq(risk.balanceOf(address(mf)), 0, "factory keeps no RISK");
        assertEq(risk.balanceOf(address(buyback)), 0, "buyback keeps no RISK");
        assertEq(mf.totalRiskBurned(), h.ghostRiskBurned(), "burn counter");
        assertEq(risk.balanceOf(DEAD), h.ghostRiskBurned(), "burned RISK sits at dEaD");
        assertEq(risk.totalSupply(), SUPPLY, "fixed supply");
        assertEq(buyback.circulatingSupply(), SUPPLY - risk.balanceOf(DEAD), "circulating = supply - dead");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_matchStateConsistent() public view {
        uint256 n = mf.nextMatchId();
        for (uint256 id = 1; id < n; ++id) {
            MatchFactory.Match memory m = mf.getMatch(id);
            address[] memory players = mf.playersOf(id);
            assertEq(players.length, m.playerCount, "players array = count");
            assertLe(m.playerCount, m.maxPlayers, "never over capacity");
            assertLe(m.revealedCount, m.playerCount, "reveals <= players");
            assertGe(m.playerCount, 1, "creator always joined");
            MatchFactory.Status term = h.ghostTerminal(id);
            if (term != MatchFactory.Status.None) {
                assertEq(uint256(m.status), uint256(term), "terminal state never reopens");
                assertEq(m.pot, 0, "terminal pot is zero");
            } else {
                assertEq(m.pot, uint256(m.playerCount) * m.entryFee, "live pot = players * fee");
                assertTrue(m.status != MatchFactory.Status.None, "created match has a status");
            }
            if (m.status == MatchFactory.Status.Playing) {
                assertEq(m.revealedCount, m.playerCount, "playing only after every reveal");
                bytes32 seed;
                for (uint256 i; i < players.length; ++i) {
                    seed ^= keccak256(abi.encode(h.secretOf(id, players[i])));
                }
                assertEq(m.seed, seed, "seed is the xor of every player's secret hash");
            }
            if (m.status == MatchFactory.Status.Open) assertLt(m.playerCount, m.maxPlayers, "open lobby is not full");
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_rewardedPlacementsCappedPerWindow() public view {
        for (uint256 i; i < 6; ++i) {
            address a = h.actors(i);
            uint256 start = vault.windowStart(a);
            uint256 inWindow;
            uint256 total = h.rewardedCount(a);
            for (uint256 k; k < total; ++k) {
                uint256 ts = h.rewardedAt(a, k);
                if (ts >= start && ts < start + vault.WINDOW()) ++inWindow;
            }
            assertLe(inWindow, vault.MAX_REWARDED_WINS_PER_WINDOW(), "at most 3 rewarded placements per window");
            assertEq(inWindow, vault.winsInWindow(a), "window counter matches paid placements");
            assertLe(uint256(vault.winsInWindow(a)), vault.MAX_REWARDED_WINS_PER_WINDOW());
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_actorBalancesReconcile() public view {
        // Actors only lose IMD through entry fees and only gain it through refunds, prizes and the
        // venue's excess on a RISK entry: nothing leaks to or from anyone else.
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            sum += imd.balanceOf(h.actors(i));
        }
        assertEq(
            sum + h.ghostImdPaidByActors(), 6e24 + h.ghostExcessReturned() + h.ghostImdOut(), "actor IMD reconciles"
        );
    }
}
