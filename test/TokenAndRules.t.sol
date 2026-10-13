// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {RiskRules} from "../src/lib/RiskRules.sol";

contract LaunchTokenTest is Test {
    LaunchToken token;
    address factory = makeAddr("factory");

    function setUp() public {
        vm.prank(factory);
        token = new LaunchToken();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "IMD RISK");
        assertEq(token.symbol(), "RISK");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(factory), 1e27);
    }

    function test_transfer() public {
        address bob = makeAddr("bob");
        vm.prank(factory);
        assertTrue(token.transfer(bob, 5e18));
        assertEq(token.balanceOf(bob), 5e18);
        assertEq(token.balanceOf(factory), 1e27 - 5e18);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferFromAndAllowance() public {
        address bob = makeAddr("bob");
        vm.prank(factory);
        token.approve(bob, 10);
        vm.prank(bob);
        token.transferFrom(factory, bob, 4);
        assertEq(token.allowance(factory, bob), 6);
        vm.prank(bob);
        vm.expectRevert(LaunchToken.InsufficientAllowance.selector);
        token.transferFrom(factory, bob, 7);
    }

    function test_revertsOnOverspendAndZeroRecipient() public {
        vm.prank(makeAddr("poor"));
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transfer(factory, 1);
        vm.prank(factory);
        vm.expectRevert(LaunchToken.InvalidRecipient.selector);
        token.transfer(address(0), 1);
    }

    function test_noMintSelector() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", factory, 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), 1e27);
    }
}

contract RiskRulesTest is Test {
    function _cmp(uint8 a0, uint8 a1, uint8 a2, uint256 na, uint8 d0, uint8 d1, uint256 nd)
        internal
        pure
        returns (uint256, uint256)
    {
        return RiskRules.compare([a0, a1, a2], na, [d0, d1], nd);
    }

    function test_defenderWinsTies() public pure {
        (uint256 al, uint256 dl) = _cmp(6, 0, 0, 1, 6, 0, 1);
        assertEq(al, 1);
        assertEq(dl, 0);
        (al, dl) = _cmp(5, 5, 1, 3, 5, 5, 2);
        assertEq(al, 2);
        assertEq(dl, 0);
    }

    function test_highestDiceComparedPairwise() public pure {
        // attacker 6,4,1 vs defender 5,3 -> defender loses two
        (uint256 al, uint256 dl) = _cmp(1, 6, 4, 3, 3, 5, 2);
        assertEq(al, 0);
        assertEq(dl, 2);
        // attacker 6,2 vs defender 5,4 -> one each
        (al, dl) = _cmp(2, 6, 0, 2, 4, 5, 2);
        assertEq(al, 1);
        assertEq(dl, 1);
    }

    function test_resolveBattleIsDeterministicAndBounded() public pure {
        bytes32 seed = keccak256("seed");
        for (uint256 b; b < 50; ++b) {
            (uint256 al, uint256 dl) = RiskRules.resolveBattle(seed, b, 3, 2);
            assertEq(al + dl, 2);
            (uint256 al2, uint256 dl2) = RiskRules.resolveBattle(seed, b, 3, 2);
            assertEq(al, al2);
            assertEq(dl, dl2);
            uint8 d = RiskRules.die(seed, b, 0);
            assertTrue(d >= 1 && d <= 6);
        }
        (uint256 a1, uint256 d1) = RiskRules.resolveBattle(seed, 7, 1, 2);
        assertEq(a1 + d1, 1);
    }

    function testFuzz_lossesEqualMinDice(bytes32 seed, uint256 b, uint8 na, uint8 nd) public pure {
        na = uint8(bound(na, 1, 3));
        nd = uint8(bound(nd, 1, 2));
        (uint256 al, uint256 dl) = RiskRules.resolveBattle(seed, b, na, nd);
        assertEq(al + dl, na < nd ? na : nd);
    }

    function test_invalidDiceRevert() public {
        vm.expectRevert(RiskRules.InvalidDice.selector);
        this.resolve(4, 1);
        vm.expectRevert(RiskRules.InvalidDice.selector);
        this.resolve(1, 3);
        vm.expectRevert(RiskRules.InvalidDice.selector);
        this.resolve(0, 1);
    }

    function resolve(uint256 a, uint256 d) external pure {
        RiskRules.resolveBattle(bytes32(0), 0, a, d);
    }

    function test_mapHas42TerritoriesIn6Continents() public pure {
        uint256 total;
        for (uint256 c; c < 6; ++c) {
            (uint256 first, uint256 count,) = RiskRules.continent(c);
            assertEq(first, total);
            total += count;
            assertEq(RiskRules.continentOf(first), c);
            assertEq(RiskRules.continentOf(first + count - 1), c);
        }
        assertEq(total, 42);
    }

    function test_reinforcementsAndContinentBonus() public pure {
        assertEq(RiskRules.reinforcements(0), 3); // floor of 3
        // Australia (38..41) only: 4 territories -> 3 + 2
        uint64 aus = uint64(0xF) << 38;
        assertEq(RiskRules.reinforcements(aus), 5);
        // South America (9..12) + Australia: 8 territories -> 3 + 2 + 2
        uint64 sa = uint64(0xF) << 9;
        assertEq(RiskRules.reinforcements(aus | sa), 7);
        // whole map: 42/3 = 14 + 24 bonus
        uint64 all = uint64((uint256(1) << 42) - 1);
        assertEq(RiskRules.reinforcements(all), 38);
        // 12 scattered territories, no continent: 4
        uint64 scattered = 0;
        for (uint256 c; c < 6; ++c) {
            (uint256 first,,) = RiskRules.continent(c);
            scattered |= uint64(3) << first;
        }
        assertEq(RiskRules.reinforcements(scattered), 4);
    }

    function test_invalidTerritoryReverts() public {
        vm.expectRevert(RiskRules.InvalidTerritory.selector);
        this.continentOfExt(42);
        vm.expectRevert(RiskRules.InvalidTerritory.selector);
        this.reinforceExt(uint64(1) << 42);
    }

    function continentOfExt(uint256 t) external pure returns (uint256) {
        return RiskRules.continentOf(t);
    }

    function reinforceExt(uint64 m) external pure returns (uint256) {
        return RiskRules.reinforcements(m);
    }
}
