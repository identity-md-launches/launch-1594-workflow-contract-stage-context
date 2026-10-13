// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title RiskRules
/// @notice Deterministic combat and reinforcement rules for IMD PEPE RISK. All functions are internal
/// (inlined into callers). The frontend replays the same rules from a match's commit-reveal seed, so an
/// outcome can be checked by anyone before it is signed.
/// @dev Map: 6 continents, 42 territories, numbered in contiguous continent blocks:
///   0  North America   territories 0..8   (9)   bonus 5
///   1  South America   territories 9..12  (4)   bonus 2
///   2  Europe          territories 13..19 (7)   bonus 5
///   3  Africa          territories 20..25 (6)   bonus 3
///   4  Asia            territories 26..37 (12)  bonus 7
///   5  Australia       territories 38..41 (4)   bonus 2
library RiskRules {
    uint256 internal constant TERRITORIES = 42;
    uint256 internal constant CONTINENTS = 6;
    uint256 internal constant MAX_ATTACK_DICE = 3;
    uint256 internal constant MAX_DEFEND_DICE = 2;
    uint256 internal constant MIN_REINFORCEMENTS = 3;

    error InvalidDice();
    error InvalidContinent();
    error InvalidTerritory();

    /// @return first first territory index of the continent
    /// @return count number of territories in it
    /// @return bonus extra Pepes granted per turn for holding all of it
    function continent(uint256 id) internal pure returns (uint256 first, uint256 count, uint256 bonus) {
        if (id == 0) return (0, 9, 5);
        if (id == 1) return (9, 4, 2);
        if (id == 2) return (13, 7, 5);
        if (id == 3) return (20, 6, 3);
        if (id == 4) return (26, 12, 7);
        if (id == 5) return (38, 4, 2);
        revert InvalidContinent();
    }

    function continentOf(uint256 territory) internal pure returns (uint256) {
        if (territory >= TERRITORIES) revert InvalidTerritory();
        if (territory < 9) return 0;
        if (territory < 13) return 1;
        if (territory < 20) return 2;
        if (territory < 26) return 3;
        if (territory < 38) return 4;
        return 5;
    }

    /// @notice One die (1..6) for roll `k` of battle `battleIndex` in a match with `seed`.
    function die(bytes32 seed, uint256 battleIndex, uint256 k) internal pure returns (uint8) {
        return uint8(uint256(keccak256(abi.encode(seed, battleIndex, k))) % 6) + 1;
    }

    /// @notice Resolve one attack roll. Highest dice are compared pairwise; the defender wins ties.
    /// @param attackDice 1..3 (attacker needs attackDice + 1 Pepes on the source territory)
    /// @param defendDice 1..2
    function resolveBattle(bytes32 seed, uint256 battleIndex, uint256 attackDice, uint256 defendDice)
        internal
        pure
        returns (uint256 attackerLosses, uint256 defenderLosses)
    {
        if (attackDice == 0 || attackDice > MAX_ATTACK_DICE || defendDice == 0 || defendDice > MAX_DEFEND_DICE) {
            revert InvalidDice();
        }
        uint8[3] memory a;
        uint8[2] memory d;
        for (uint256 i; i < attackDice; ++i) {
            a[i] = die(seed, battleIndex, i);
        }
        for (uint256 i; i < defendDice; ++i) {
            d[i] = die(seed, battleIndex, MAX_ATTACK_DICE + i);
        }
        return compare(a, attackDice, d, defendDice);
    }

    /// @notice Compare explicit dice (exposed for tests and replay). Defender wins ties.
    function compare(uint8[3] memory a, uint256 attackDice, uint8[2] memory d, uint256 defendDice)
        internal
        pure
        returns (uint256 attackerLosses, uint256 defenderLosses)
    {
        _sortDesc3(a);
        if (defendDice == 2 && d[1] > d[0]) (d[0], d[1]) = (d[1], d[0]);
        uint256 pairs = attackDice < defendDice ? attackDice : defendDice;
        for (uint256 i; i < pairs; ++i) {
            if (a[i] > d[i]) ++defenderLosses;
            else ++attackerLosses;
        }
    }

    /// @notice Pepes granted at the start of a turn for a bitmask of owned territories:
    /// max(3, owned / 3) plus each fully held continent's bonus.
    function reinforcements(uint64 ownedMask) internal pure returns (uint256 total) {
        if (ownedMask >> TERRITORIES != 0) revert InvalidTerritory();
        uint256 owned = _popcount(ownedMask);
        total = owned / 3;
        if (total < MIN_REINFORCEMENTS) total = MIN_REINFORCEMENTS;
        for (uint256 c; c < CONTINENTS; ++c) {
            (uint256 first, uint256 count, uint256 bonus) = continent(c);
            uint64 mask = uint64(((uint256(1) << count) - 1) << first);
            if (ownedMask & mask == mask) total += bonus;
        }
    }

    function _sortDesc3(uint8[3] memory a) private pure {
        if (a[1] > a[0]) (a[0], a[1]) = (a[1], a[0]);
        if (a[2] > a[1]) (a[1], a[2]) = (a[2], a[1]);
        if (a[1] > a[0]) (a[0], a[1]) = (a[1], a[0]);
    }

    function _popcount(uint64 x) private pure returns (uint256 n) {
        while (x != 0) {
            x &= x - 1;
            ++n;
        }
    }
}
