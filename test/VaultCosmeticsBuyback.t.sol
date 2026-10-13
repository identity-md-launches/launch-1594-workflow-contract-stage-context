// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixtures} from "./utils/Fixtures.sol";
import {PrizeVault} from "../src/PrizeVault.sol";
import {Cosmetics} from "../src/Cosmetics.sol";
import {Buyback} from "../src/Buyback.sol";
import {Owned} from "../src/lib/Common.sol";

contract PrizeVaultTest is Fixtures {
    uint96 constant FEE = 10e18;

    function _playAndSettle(uint256 a, uint256 b) internal {
        uint256 id = mf.nextMatchId();
        vm.prank(p[a]);
        mf.createMatch(2, FEE, _commit(id, a), 0, 0);
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

    function test_setMatchFactoryOnlyOwnerOnce() public {
        vm.prank(p[0]);
        vm.expectRevert(Owned.NotOwner.selector);
        vault.setMatchFactory(address(mf));
        _linkVault();
        vm.prank(owner);
        vm.expectRevert(PrizeVault.MatchFactoryAlreadySet.selector);
        vault.setMatchFactory(address(1));
    }

    function test_onlyMatchFactoryAwards() public {
        _linkVault();
        address[3] memory r = [p[0], p[1], address(0)];
        vm.prank(p[0]);
        vm.expectRevert(PrizeVault.NotMatchFactory.selector);
        vault.awardMatch(1, r, 2, 0, false);
    }

    function test_dailyCapThreeRewardedWinsPerWindow() public {
        _linkVault();
        // p0 places in 4 matches within the window; the 4th placement is forfeited to the bonus pool
        for (uint256 i; i < 3; ++i) {
            _playAndSettle(0, 1 + i);
        }
        assertEq(vault.remainingRewardedWins(p[0]), 0);
        uint256 claimBefore = vault.claimable(p[0]);
        assertEq(claimBefore, 3 * 15e18);
        _playAndSettle(0, 4);
        assertEq(vault.claimable(p[0]), claimBefore);
        assertEq(vault.bonusPool(), 15e18);
        assertEq(vault.claimable(p[4]), 5e18);
        // conservation: balance == claimable + bonus
        assertEq(imd.balanceOf(address(vault)), vault.totalClaimable() + vault.bonusPool());

        // after 24h the window resets
        vm.warp(block.timestamp + 24 hours);
        assertEq(vault.remainingRewardedWins(p[0]), 3);
        _playAndSettle(0, 5);
        assertEq(vault.claimable(p[0]), claimBefore + 15e18);
    }

    function test_bonusOnlyForSeatAttestedAndCapped() public {
        _linkVault();
        imd.mint(address(this), 10_000e18);
        imd.approve(address(vault), type(uint256).max);
        vault.fundBonus(10_000e18);
        assertEq(vault.bonusPool(), 10_000e18);

        // unanimous settlement: no bonus
        _playAndSettle(0, 1);
        assertEq(vault.claimable(p[0]), 15e18);
        assertEq(vault.bonusPool(), 10_000e18);

        // seat-attested: bonus = min(1% of pool = 100, 50% of pot = 10) = 10
        uint256 seatPk = 0x5EA7;
        vm.prank(owner);
        mf.setOutcomeSigner(vm.addr(seatPk));
        uint256 id = _openFull(2, FEE);
        _revealAll(id, 2);
        address[] memory ranking = _ranking(1, 0, 0, 2);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(seatPk, mf.outcomeDigest(id, ranking));
        mf.settle(id, ranking, sigs);
        assertEq(vault.bonusPool(), 10_000e18 - 10e18);
        assertEq(vault.claimable(p[1]), 5e18 + 22.5e18);
        assertEq(vault.claimable(p[0]), 15e18 + 7.5e18);
        assertEq(imd.balanceOf(address(vault)), vault.totalClaimable() + vault.bonusPool());
    }

    function test_claimNothingReverts() public {
        vm.prank(p[0]);
        vm.expectRevert(PrizeVault.NothingToClaim.selector);
        vault.claim();
    }
}

contract CosmeticsTest is Fixtures {
    function _item() internal {
        vm.prank(owner);
        cosmetics.configureItem(1, 100e18, 2, true);
    }

    function test_onlyOwnerConfigures() public {
        vm.prank(p[0]);
        vm.expectRevert(Owned.NotOwner.selector);
        cosmetics.configureItem(1, 1, 0, true);
        vm.prank(owner);
        vm.expectRevert(Cosmetics.InvalidItem.selector);
        cosmetics.configureItem(1, 0, 0, true);
    }

    function test_buySplitsRevenue() public {
        _item();
        vm.prank(p[0]);
        uint256 cost = cosmetics.buy(1, 1);
        assertEq(cost, 100e18);
        assertEq(cosmetics.owned(p[0], 1), 1);
        assertEq(imd.balanceOf(address(buyback)), 30e18); // 20% burn share + 10% buyback
        assertEq(vault.bonusPool(), 35e18);
        assertEq(imd.balanceOf(address(vault)), 35e18);
        assertEq(cosmetics.pendingSeatRewards(), 35e18);
        assertEq(imd.balanceOf(address(cosmetics)), 35e18);
        assertEq(
            cosmetics.totalRevenue(), cosmetics.totalToBuyback() + cosmetics.totalToVault() + cosmetics.totalToSeats()
        );
    }

    function test_supplyCapAndInactive() public {
        _item();
        vm.prank(p[0]);
        vm.expectRevert(Cosmetics.SoldOut.selector);
        cosmetics.buy(1, 3);
        vm.prank(p[0]);
        vm.expectRevert(Cosmetics.ItemUnavailable.selector);
        cosmetics.buy(2, 1);
        vm.prank(p[0]);
        vm.expectRevert(Cosmetics.ZeroAmount.selector);
        cosmetics.buy(1, 0);
    }

    function test_seatRewardsUnsetThenSet() public {
        _item();
        vm.prank(p[0]);
        cosmetics.buy(1, 2);
        vm.expectRevert(Cosmetics.SeatRecipientNotConfigured.selector);
        cosmetics.flushSeatRewards();
        address seats = makeAddr("seatRewards");
        vm.prank(p[0]);
        vm.expectRevert(Owned.NotOwner.selector);
        cosmetics.setSeatRewardsRecipient(seats);
        vm.prank(owner);
        cosmetics.setSeatRewardsRecipient(seats);
        cosmetics.flushSeatRewards();
        assertEq(imd.balanceOf(seats), 70e18);
        assertEq(imd.balanceOf(address(cosmetics)), 0);
        vm.expectRevert(Cosmetics.ZeroAmount.selector);
        cosmetics.flushSeatRewards();
    }

    function testFuzz_splitConserves(uint128 price, uint8 qty) public {
        price = uint128(bound(price, 1, 1e20));
        qty = uint8(bound(qty, 1, 5));
        vm.prank(owner);
        cosmetics.configureItem(9, price, 0, true);
        imd.mint(p[0], uint256(price) * qty);
        uint256 before = imd.balanceOf(p[0]);
        vm.prank(p[0]);
        cosmetics.buy(9, qty);
        uint256 cost = uint256(price) * qty;
        assertEq(before - imd.balanceOf(p[0]), cost);
        assertEq(
            imd.balanceOf(address(buyback)) + imd.balanceOf(address(vault)) + imd.balanceOf(address(cosmetics)), cost
        );
    }
}

contract BuybackTest is Fixtures {
    function test_buybackNotConfiguredThenBurnsSameTx() public {
        imd.mint(address(buyback), 50e18);
        vm.prank(owner);
        vm.expectRevert(Buyback.VenueNotConfigured.selector);
        buyback.executeBuyback(50e18, 1);

        vm.prank(p[0]);
        vm.expectRevert(Owned.NotOwner.selector);
        buyback.setVenue(address(venue));
        _setVenue();

        vm.prank(p[0]);
        vm.expectRevert(Owned.NotOwner.selector);
        buyback.executeBuyback(50e18, 1);

        venue.setRate(2, 1);
        vm.prank(owner);
        uint256 burned = buyback.executeBuyback(50e18, 100e18);
        assertEq(burned, 100e18);
        assertEq(risk.balanceOf(DEAD), 100e18);
        assertEq(risk.balanceOf(address(buyback)), 0);
        assertEq(buyback.totalRiskBurned(), 100e18);
        assertEq(buyback.burnedSupply(), 100e18);
        assertEq(buyback.circulatingSupply(), 1e27 - 100e18);
    }

    function test_buybackSlippageReverts() public {
        imd.mint(address(buyback), 50e18);
        _setVenue();
        vm.prank(owner);
        vm.expectRevert(bytes("slippage"));
        buyback.executeBuyback(50e18, 51e18);
        assertEq(risk.balanceOf(DEAD), 0);
    }

    function test_cosmeticsToBuybackToBurn() public {
        vm.prank(owner);
        cosmetics.configureItem(1, 100e18, 0, true);
        vm.prank(p[0]);
        cosmetics.buy(1, 1);
        _setVenue();
        vm.prank(owner);
        buyback.executeBuyback(30e18, 30e18);
        assertEq(risk.balanceOf(DEAD), 30e18);
    }

    function test_burnHeldRisk() public {
        vm.expectRevert(Buyback.ZeroAmount.selector);
        buyback.burnHeldRisk();
        vm.prank(p[0]);
        risk.transfer(address(buyback), 7e18);
        buyback.burnHeldRisk();
        assertEq(risk.balanceOf(DEAD), 7e18);
    }

    function test_routeRequiresVenueAndRecipient() public {
        vm.prank(p[0]);
        risk.approve(address(buyback), type(uint256).max);
        vm.prank(p[0]);
        vm.expectRevert(Buyback.VenueNotConfigured.selector);
        buyback.routeRiskToImd(1e18, 1, p[0]);
        _setVenue();
        vm.prank(p[0]);
        vm.expectRevert(Owned.ZeroAddress.selector);
        buyback.routeRiskToImd(1e18, 1, address(0));
        uint256 before = imd.balanceOf(p[1]);
        vm.prank(p[0]);
        buyback.routeRiskToImd(1e18, 1e18, p[1]);
        assertEq(imd.balanceOf(p[1]), before + 1e18);
    }

    function test_constructorsRejectZero() public {
        vm.expectRevert(Owned.ZeroAddress.selector);
        new Buyback(address(0), address(imd), address(risk));
        vm.expectRevert(Owned.ZeroAddress.selector);
        new Buyback(owner, address(imd), address(imd));
        vm.expectRevert(Owned.ZeroAddress.selector);
        new PrizeVault(owner, address(0));
    }

    function test_ownershipTwoStep() public {
        address n = makeAddr("newOwner");
        vm.prank(owner);
        buyback.transferOwnership(n);
        assertEq(buyback.owner(), owner);
        vm.prank(p[0]);
        vm.expectRevert(Owned.NotOwner.selector);
        buyback.acceptOwnership();
        vm.prank(n);
        buyback.acceptOwnership();
        assertEq(buyback.owner(), n);
    }
}
