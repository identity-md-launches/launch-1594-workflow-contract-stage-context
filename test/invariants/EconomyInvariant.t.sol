// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {Buyback} from "../../src/Buyback.sol";
import {PrizeVault} from "../../src/PrizeVault.sol";
import {Cosmetics} from "../../src/Cosmetics.sol";
import {MockERC20, MockVenue} from "../utils/Fixtures.sol";

/// @dev Drives the IMD economy around the game: cosmetics sales and their four-way split, seat-reward
/// flushes, buy-and-burn through a venue whose rate moves, RISK routing, donated RISK, sponsor bonus
/// funding, and prize awards (the handler is linked as the vault's MatchFactory so the vault's cap,
/// bonus and forfeit logic run over random rankings). fail-on-revert is on: every call pre-checks state.
contract EconomyHandler is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant N = 6;
    uint256 internal constant ITEMS = 4;

    Cosmetics public cosmetics;
    PrizeVault public vault;
    Buyback public buyback;
    MockERC20 public imd;
    LaunchToken public risk;
    MockVenue public venue;
    address public owner;
    address public seats;
    address public sponsor;
    address[N] public actors;

    // ---- ghost state
    uint256 public ghostMintedToActors; // IMD minted to actors for purchases / routing
    uint256 public ghostFlushed;
    uint256 public ghostImdDonatedToBuyback;
    uint256 public ghostImdSpent;
    uint256 public ghostRiskDonated;
    uint256 public ghostRiskBurned;
    uint256 public ghostSponsorFunded;
    uint256 public ghostPotsIn;
    uint256 public ghostBonusTaken;
    uint256 public ghostAwarded;
    uint256 public ghostForfeited;
    uint256 public ghostClaimed;
    uint256 public ghostRoutedImdOut; // IMD the venue paid actors for routed RISK
    uint256 public lastBurned;
    uint256 public nextMatchId = 1;
    mapping(address => uint256[]) internal _rewardedAt;
    mapping(string => uint256) public calls;

    constructor(
        Cosmetics c,
        PrizeVault v,
        Buyback b,
        MockERC20 imd_,
        LaunchToken risk_,
        MockVenue venue_,
        address owner_
    ) {
        cosmetics = c;
        vault = v;
        buyback = b;
        imd = imd_;
        risk = risk_;
        venue = venue_;
        owner = owner_;
        seats = makeAddr("seatRewards");
        sponsor = makeAddr("sponsor");
        for (uint256 i; i < N; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
            vm.startPrank(actors[i]);
            imd.approve(address(cosmetics), type(uint256).max);
            risk.approve(address(buyback), type(uint256).max);
            vm.stopPrank();
        }
    }

    function rewardedCount(address a) external view returns (uint256) {
        return _rewardedAt[a].length;
    }

    function rewardedAt(address a, uint256 i) external view returns (uint256) {
        return _rewardedAt[a][i];
    }

    // ------------------------------------------------------------------ cosmetics

    function configureItem(uint256 itemSeed, uint128 price, uint64 maxSupply, bool active) external {
        calls["configureItem"]++;
        uint256 itemId = itemSeed % ITEMS;
        price = uint128(bound(price, 1, 100e18));
        (,, uint64 sold,) = cosmetics.items(itemId);
        maxSupply = uint64(bound(maxSupply, 0, 40));
        if (maxSupply != 0 && maxSupply < sold) maxSupply = sold; // the contract refuses a cap below sold
        vm.prank(owner);
        cosmetics.configureItem(itemId, price, maxSupply, active);
        (uint128 p, uint64 ms,, bool act) = cosmetics.items(itemId);
        assertEq(p, price);
        assertEq(ms, maxSupply);
        assertEq(act, active);
    }

    function buy(uint256 actorSeed, uint256 itemSeed, uint64 quantity) external {
        calls["buy"]++;
        address a = actors[actorSeed % N];
        uint256 itemId = itemSeed % ITEMS;
        (uint128 price, uint64 maxSupply, uint64 sold, bool active) = cosmetics.items(itemId);
        if (!active) return;
        uint64 room = maxSupply == 0 ? 8 : maxSupply - sold;
        if (room == 0) return;
        quantity = uint64(bound(quantity, 1, room));
        uint256 cost = uint256(price) * quantity;
        imd.mint(a, cost);
        ghostMintedToActors += cost;

        Snap memory s = _snap(a, itemId);
        vm.prank(a);
        uint256 paid = cosmetics.buy(itemId, quantity);
        assertEq(paid, cost, "cost = price * qty");
        _checkBuy(a, itemId, quantity, cost, s);
    }

    struct Snap {
        uint256 bb;
        uint256 v;
        uint256 pool;
        uint256 c;
        uint256 owned;
        uint256 buyer;
        uint64 sold;
    }

    function _snap(address a, uint256 itemId) internal view returns (Snap memory s) {
        s.bb = imd.balanceOf(address(buyback));
        s.v = imd.balanceOf(address(vault));
        s.pool = vault.bonusPool();
        s.c = imd.balanceOf(address(cosmetics));
        s.owned = cosmetics.owned(a, itemId);
        s.buyer = imd.balanceOf(a);
        (,, s.sold,) = cosmetics.items(itemId);
    }

    function _checkBuy(address a, uint256 itemId, uint64 quantity, uint256 cost, Snap memory s) internal view {
        uint256 toBuyback = cost * (cosmetics.BURN_BPS() + cosmetics.BUYBACK_BPS()) / cosmetics.BPS();
        uint256 toSeats = cost * cosmetics.SEATS_BPS() / cosmetics.BPS();
        uint256 toVault = cost - toBuyback - toSeats;
        assertEq(imd.balanceOf(address(buyback)) - s.bb, toBuyback, "30% to buyback");
        assertEq(imd.balanceOf(address(vault)) - s.v, toVault, "35%+dust to vault");
        assertEq(vault.bonusPool() - s.pool, toVault, "vault share lands in the bonus pool");
        assertEq(imd.balanceOf(address(cosmetics)) - s.c, toSeats, "35% held for seats");
        assertEq(cosmetics.owned(a, itemId) - s.owned, quantity, "item owned");
        (,, uint64 soldAfter,) = cosmetics.items(itemId);
        assertEq(soldAfter, s.sold + quantity, "sold counter");
        assertEq(s.buyer - imd.balanceOf(a), cost, "buyer paid exactly the cost");
        assertEq(imd.allowance(address(cosmetics), address(vault)), 0, "vault allowance consumed");
    }

    function setSeatRecipient(bool enabled) external {
        calls["setSeatRecipient"]++;
        if (!enabled) return; // zero is refused by the contract; "disabled" is the initial state only
        vm.prank(owner);
        cosmetics.setSeatRewardsRecipient(seats);
    }

    function flushSeatRewards() external {
        calls["flushSeatRewards"]++;
        if (cosmetics.seatRewardsRecipient() == address(0)) return;
        uint256 pending = cosmetics.pendingSeatRewards();
        if (pending == 0) return;
        uint256 before = imd.balanceOf(seats);
        uint256 got = cosmetics.flushSeatRewards();
        assertEq(got, pending);
        assertEq(imd.balanceOf(seats) - before, pending, "seats paid in full");
        assertEq(cosmetics.pendingSeatRewards(), 0);
        ghostFlushed += pending;
    }

    // ------------------------------------------------------------------ buyback

    function setRate(uint256 n, uint256 d) external {
        calls["setRate"]++;
        venue.setRate(bound(n, 1, 4), bound(d, 1, 4));
    }

    function donateImdToBuyback(uint256 amount) external {
        calls["donateImd"]++;
        amount = bound(amount, 1, 100e18);
        imd.mint(address(buyback), amount);
        ghostImdDonatedToBuyback += amount;
    }

    function executeBuyback(uint256 imdIn) external {
        calls["executeBuyback"]++;
        uint256 held = imd.balanceOf(address(buyback));
        if (held < 4) return;
        imdIn = bound(imdIn, 4, held);
        uint256 expected = imdIn * venue.rateNum() / venue.rateDen();
        uint256 deadBefore = risk.balanceOf(DEAD);
        vm.prank(owner);
        uint256 burned = buyback.executeBuyback(imdIn, expected);
        assertEq(burned, expected, "burn = venue output");
        assertEq(risk.balanceOf(DEAD) - deadBefore, burned, "burned RISK reaches dEaD in the same tx");
        assertEq(imd.balanceOf(address(buyback)), held - imdIn, "IMD spent");
        assertEq(imd.allowance(address(buyback), address(venue)), 0, "allowance reset");
        ghostImdSpent += imdIn;
        ghostRiskBurned += burned;
    }

    function donateAndBurnRisk(uint256 amount) external {
        calls["burnHeldRisk"]++;
        amount = bound(amount, 1, 1_000e18);
        vm.prank(address(venue));
        risk.transfer(address(buyback), amount);
        ghostRiskDonated += amount;
        uint256 deadBefore = risk.balanceOf(DEAD);
        uint256 got = buyback.burnHeldRisk();
        assertEq(got, amount);
        assertEq(risk.balanceOf(DEAD) - deadBefore, amount);
        ghostRiskBurned += amount;
    }

    function routeRiskToImd(uint256 actorSeed, uint256 recipientSeed, uint256 riskIn) external {
        calls["routeRiskToImd"]++;
        address a = actors[actorSeed % N];
        address r = actors[recipientSeed % N];
        riskIn = bound(riskIn, 4, 1_000e18);
        uint256 expected = riskIn * venue.rateNum() / venue.rateDen();
        vm.prank(address(venue));
        risk.transfer(a, riskIn);
        uint256 before = imd.balanceOf(r);
        uint256 riskBefore = risk.balanceOf(a);
        vm.prank(a);
        uint256 out = buyback.routeRiskToImd(riskIn, expected, r);
        assertEq(out, expected, "quoted output");
        assertEq(imd.balanceOf(r) - before, expected, "recipient receives the IMD");
        assertEq(riskBefore - risk.balanceOf(a), riskIn, "payer spent exactly riskIn");
        assertEq(risk.balanceOf(address(buyback)), 0, "no RISK left in buyback");
        ghostRoutedImdOut += expected;
    }

    // ------------------------------------------------------------------ vault

    function fundBonus(uint256 amount) external {
        calls["fundBonus"]++;
        amount = bound(amount, 1, 200e18);
        imd.mint(sponsor, amount);
        vm.startPrank(sponsor);
        imd.approve(address(vault), amount);
        vault.fundBonus(amount);
        vm.stopPrank();
        ghostSponsorFunded += amount;
    }

    function award(uint256 rankSeed, uint256 count, uint256 pot, bool withBonus) external {
        calls["award"]++;
        count = bound(count, 2, 3);
        pot = bound(pot, 1, 500e18);
        address[3] memory ranking = _distinct(rankSeed, count);
        imd.mint(address(this), pot);
        imd.transfer(address(vault), pot);
        ghostPotsIn += pot;

        uint256 poolBefore = vault.bonusPool();
        uint256 bonus;
        if (withBonus) {
            bonus = poolBefore * vault.BONUS_POOL_BPS_PER_MATCH() / vault.BPS();
            uint256 cap = pot * vault.BONUS_MAX_POT_BPS() / vault.BPS();
            if (bonus > cap) bonus = cap;
        }
        uint256 prize = pot + bonus;
        uint256[3] memory before;
        bool[3] memory eligible;
        for (uint256 i; i < count; ++i) {
            before[i] = vault.claimable(ranking[i]);
            eligible[i] = vault.remainingRewardedWins(ranking[i]) > 0;
        }
        uint256 matchId = nextMatchId++;
        vault.awardMatch(matchId, ranking, count, pot, withBonus);

        uint256[3] memory shares;
        shares[1] = prize * vault.SECOND_BPS() / vault.BPS();
        if (count == 3) shares[2] = prize * vault.THIRD_BPS() / vault.BPS();
        shares[0] = prize - shares[1] - shares[2];
        uint256 awarded;
        for (uint256 i; i < count; ++i) {
            uint256 delta = vault.claimable(ranking[i]) - before[i];
            if (shares[i] == 0) {
                assertEq(delta, 0, "zero share pays nothing");
            } else if (eligible[i]) {
                assertEq(delta, shares[i], "eligible placement paid its share");
                _rewardedAt[ranking[i]].push(block.timestamp);
            } else {
                assertEq(delta, 0, "capped placement forfeits");
                calls["forfeited"]++;
            }
            awarded += delta;
        }
        assertEq(vault.bonusPool(), poolBefore - bonus + (prize - awarded), "pool delta");
        ghostBonusTaken += bonus;
        ghostAwarded += awarded;
        ghostForfeited += prize - awarded;
    }

    function claim(uint256 actorSeed) external {
        calls["claim"]++;
        address a = actors[actorSeed % N];
        uint256 owed = vault.claimable(a);
        if (owed == 0) return;
        uint256 before = imd.balanceOf(a);
        vm.prank(a);
        assertEq(vault.claim(), owed);
        assertEq(imd.balanceOf(a) - before, owed, "claim pays the ledger amount");
        ghostClaimed += owed;
    }

    function warp(uint256 delta) external {
        calls["warp"]++;
        delta = delta % 4 == 0 ? bound(delta, 0, 30 hours) : bound(delta, 0, 2 hours);
        vm.warp(block.timestamp + delta);
    }

    // ------------------------------------------------------------------ helpers

    function _distinct(uint256 seed, uint256 count) internal view returns (address[3] memory r) {
        uint256 first = seed % N;
        uint256 second = (first + 1 + (seed >> 8) % (N - 1)) % N;
        uint256 third = (seed >> 16) % N;
        while (third == first || third == second) {
            third = (third + 1) % N;
        }
        r[0] = actors[first];
        r[1] = actors[second];
        if (count == 3) r[2] = actors[third];
    }
}

contract EconomyInvariantTest is StdInvariant, Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant VENUE_RISK = 5e26;

    MockERC20 imd;
    LaunchToken risk;
    Buyback buyback;
    PrizeVault vault;
    Cosmetics cosmetics;
    MockVenue venue;
    EconomyHandler h;
    address owner = makeAddr("owner");
    address deployer = makeAddr("launchFactory");

    function setUp() public {
        vm.warp(1_800_000_000);
        imd = new MockERC20();
        vm.startPrank(deployer);
        risk = new LaunchToken();
        buyback = new Buyback(owner, address(imd), address(risk));
        vault = new PrizeVault(owner, address(imd));
        cosmetics = new Cosmetics(owner, address(imd), address(vault), address(buyback));
        vm.stopPrank();
        venue = new MockVenue();
        h = new EconomyHandler(cosmetics, vault, buyback, imd, risk, venue, owner);
        vm.startPrank(owner);
        buyback.setVenue(address(venue));
        vault.setMatchFactory(address(h));
        cosmetics.configureItem(0, 10e18, 0, true);
        cosmetics.configureItem(1, 1, 5, true);
        vm.stopPrank();
        imd.mint(address(venue), 1e30);
        vm.prank(deployer);
        risk.transfer(address(venue), VENUE_RISK);

        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](14);
        sel[0] = EconomyHandler.configureItem.selector;
        sel[1] = EconomyHandler.buy.selector;
        sel[2] = EconomyHandler.setSeatRecipient.selector;
        sel[3] = EconomyHandler.flushSeatRewards.selector;
        sel[4] = EconomyHandler.setRate.selector;
        sel[5] = EconomyHandler.donateImdToBuyback.selector;
        sel[6] = EconomyHandler.executeBuyback.selector;
        sel[7] = EconomyHandler.donateAndBurnRisk.selector;
        sel[8] = EconomyHandler.routeRiskToImd.selector;
        sel[9] = EconomyHandler.fundBonus.selector;
        sel[10] = EconomyHandler.award.selector;
        sel[11] = EconomyHandler.claim.selector;
        sel[12] = EconomyHandler.warp.selector;
        sel[13] = EconomyHandler.buy.selector; // weight purchases a little higher
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_cosmeticsSplitLedger() public view {
        assertEq(
            cosmetics.totalRevenue(),
            cosmetics.totalToBuyback() + cosmetics.totalToVault() + cosmetics.totalToSeats(),
            "revenue = buyback + vault + seats"
        );
        assertEq(
            imd.balanceOf(address(cosmetics)), cosmetics.pendingSeatRewards(), "cosmetics holds only pending seats"
        );
        assertEq(cosmetics.totalToSeats(), cosmetics.pendingSeatRewards() + h.ghostFlushed(), "seat share ledger");
        assertEq(imd.balanceOf(h.seats()), h.ghostFlushed(), "seats received every flush");
        uint256 rev = cosmetics.totalRevenue();
        assertLe(cosmetics.totalToBuyback(), rev * 3000 / 10000, "buyback share never above 30%");
        assertLe(cosmetics.totalToSeats(), rev * 3500 / 10000, "seats share never above 35%");
        assertGe(cosmetics.totalToVault(), rev * 3500 / 10000, "vault share at least 35% (gets dust)");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_itemSupplyAndOwnership() public view {
        for (uint256 item; item < 4; ++item) {
            (, uint64 maxSupply, uint64 sold,) = cosmetics.items(item);
            if (maxSupply != 0) assertLe(sold, maxSupply, "never oversold");
            uint256 owned;
            for (uint256 i; i < 6; ++i) {
                owned += cosmetics.owned(h.actors(i), item);
            }
            assertEq(owned, sold, "every unit sold is owned by a buyer");
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_buybackImdLedger() public view {
        assertEq(
            imd.balanceOf(address(buyback)),
            cosmetics.totalToBuyback() + h.ghostImdDonatedToBuyback() - buyback.totalImdSpent(),
            "buyback IMD = received - spent"
        );
        assertEq(buyback.totalImdSpent(), h.ghostImdSpent(), "spent counter");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_riskBurnsAreFinalAndCounted() public view {
        uint256 dead = risk.balanceOf(DEAD);
        assertEq(dead, h.ghostRiskBurned(), "every burn reached dEaD");
        assertEq(buyback.totalRiskBurned(), dead, "burn counter = dEaD balance");
        assertEq(buyback.burnedSupply(), dead);
        assertEq(risk.balanceOf(address(buyback)), 0, "buyback never keeps RISK");
        assertEq(risk.totalSupply(), SUPPLY, "fixed supply");
        assertEq(buyback.circulatingSupply(), SUPPLY - dead, "circulating = supply - dead");
        // dEaD only ever receives: nothing in the system holds an allowance to move it back
        assertEq(risk.allowance(DEAD, address(buyback)), 0);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_vaultSolventAndPoolLedger() public view {
        assertEq(
            imd.balanceOf(address(vault)), vault.totalClaimable() + vault.bonusPool(), "vault IMD = claimable + pool"
        );
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            sum += vault.claimable(h.actors(i));
        }
        assertEq(sum, vault.totalClaimable(), "claimable ledger");
        assertEq(
            vault.bonusPool(),
            cosmetics.totalToVault() + h.ghostSponsorFunded() + h.ghostForfeited() - h.ghostBonusTaken(),
            "pool = cosmetics + sponsors + forfeits - bonuses"
        );
        assertEq(h.ghostPotsIn() + h.ghostBonusTaken(), h.ghostAwarded() + h.ghostForfeited(), "prize conservation");
        assertEq(h.ghostAwarded(), vault.totalClaimable() + h.ghostClaimed(), "awarded = claimable + claimed");
        assertLe(h.ghostBonusTaken(), h.ghostPotsIn() / 2, "bonus never above half the pots");
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
            assertEq(
                vault.remainingRewardedWins(a),
                block.timestamp >= start + vault.WINDOW() ? 3 : 3 - inWindow,
                "remaining view agrees"
            );
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_actorImdReconciles() public view {
        // Actors spend every IMD minted for purchases, and gain only claims and routed-RISK proceeds.
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            sum += imd.balanceOf(h.actors(i));
        }
        assertEq(sum, h.ghostClaimed() + h.ghostRoutedImdOut(), "actor IMD = claims + routed proceeds");
    }
}
