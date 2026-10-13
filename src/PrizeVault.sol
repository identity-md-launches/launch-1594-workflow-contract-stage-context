// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, SafeTransfer, Owned, ReentrancyGuard} from "./lib/Common.sol";

/// @title PrizeVault
/// @notice Pays match prizes in IMD only, by pull payment. Splits a settled match's prize 60/25/15
/// (75/25 for two-player matches) and enforces the anti-farming cap: at most 3 rewarded placements per
/// wallet in any rolling 24-hour window. The vault keeps the timestamps of a wallet's last 3 rewarded
/// placements; a new placement is paid only if the oldest of them is at least 24 hours old (each rewarded
/// placement therefore has its own 24-hour cooldown). A placement over the cap is not paid; its share
/// goes to the bonus pool for later matches. Nothing is minted: every IMD paid out was deposited first.
/// @dev The vault only accepts awards from the MatchFactory the owner links once after launch. The bonus
/// pool leaves the vault only through seat-attested settlements (`withBonus`), so the economy depends on
/// the owner configuring the seat outcome signer in MatchFactory; the owner cannot withdraw it.
contract PrizeVault is Owned, ReentrancyGuard {
    using SafeTransfer for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant FIRST_BPS = 6_000;
    uint256 public constant SECOND_BPS = 2_500;
    uint256 public constant THIRD_BPS = 1_500;
    /// @notice Share of the bonus pool added to a seat-attested match, capped at half its pot.
    uint256 public constant BONUS_POOL_BPS_PER_MATCH = 100;
    uint256 public constant BONUS_MAX_POT_BPS = 5_000;
    uint256 public constant WINDOW = 24 hours;
    uint256 public constant MAX_REWARDED_WINS_PER_WINDOW = 3;

    IERC20 public immutable imd;

    address public matchFactory;
    uint256 public bonusPool;
    uint256 public totalClaimable;
    mapping(address => uint256) public claimable;
    /// @dev Timestamps of the wallet's last MAX_REWARDED_WINS_PER_WINDOW rewarded placements (0 = unused).
    mapping(address => uint64[MAX_REWARDED_WINS_PER_WINDOW]) internal _rewardedAt;

    event MatchFactorySet(address indexed matchFactory);
    event BonusFunded(address indexed from, uint256 amount);
    event PrizeAwarded(uint256 indexed matchId, address indexed player, uint256 place, uint256 amount);
    event PrizeForfeitedToPool(uint256 indexed matchId, address indexed player, uint256 place, uint256 amount);
    event Claimed(address indexed player, uint256 amount);

    error MatchFactoryNotConfigured();
    error MatchFactoryAlreadySet();
    error NotMatchFactory();
    error InvalidRanking();
    error NothingToClaim();
    error ZeroAmount();
    error Underfunded();
    error NotAContract();

    constructor(address initialOwner, address imdToken) Owned(initialOwner) {
        if (imdToken == address(0)) revert ZeroAddress();
        imd = IERC20(imdToken);
    }

    /// @notice One-time link to the launch's MatchFactory (its address is in the deployment handoff).
    /// The link is permanent: the owner must pass the deployed MatchFactory, and the address must be a
    /// contract (a mistyped EOA would otherwise brick settlement for good).
    function setMatchFactory(address factory) external onlyOwner {
        if (factory == address(0)) revert ZeroAddress();
        if (matchFactory != address(0)) revert MatchFactoryAlreadySet();
        if (factory.code.length == 0) revert NotAContract();
        matchFactory = factory;
        emit MatchFactorySet(factory);
    }

    /// @notice Anyone (Cosmetics, sponsors) can add IMD to the bonus pool.
    function fundBonus(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = imd.balanceOf(address(this));
        imd.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = imd.balanceOf(address(this)) - before;
        bonusPool += received;
        emit BonusFunded(msg.sender, received);
    }

    /// @notice Called by MatchFactory after transferring `pot` IMD here.
    /// @param ranking placed players, first to third; only the first `count` entries are read.
    /// @param count 2 or 3 placed players.
    /// @param withBonus true only for seat-attested settlements.
    function awardMatch(uint256 matchId, address[3] calldata ranking, uint256 count, uint256 pot, bool withBonus)
        external
        nonReentrant
    {
        address factory = matchFactory;
        if (factory == address(0)) revert MatchFactoryNotConfigured();
        if (msg.sender != factory) revert NotMatchFactory();
        if (count < 2 || count > 3) revert InvalidRanking();

        uint256 prize = pot;
        if (withBonus) {
            uint256 bonus = bonusPool * BONUS_POOL_BPS_PER_MATCH / BPS;
            uint256 cap = pot * BONUS_MAX_POT_BPS / BPS;
            if (bonus > cap) bonus = cap;
            bonusPool -= bonus;
            prize += bonus;
        }
        if (imd.balanceOf(address(this)) < bonusPool + totalClaimable + prize) revert Underfunded();

        uint256[3] memory shares;
        if (count == 2) {
            shares[1] = prize * SECOND_BPS / BPS;
            shares[0] = prize - shares[1];
        } else {
            shares[1] = prize * SECOND_BPS / BPS;
            shares[2] = prize * THIRD_BPS / BPS;
            shares[0] = prize - shares[1] - shares[2];
        }

        for (uint256 i; i < count; ++i) {
            address player = ranking[i];
            if (player == address(0)) revert InvalidRanking();
            if (shares[i] == 0) continue;
            if (_consumeRewardedWin(player)) {
                claimable[player] += shares[i];
                totalClaimable += shares[i];
                emit PrizeAwarded(matchId, player, i + 1, shares[i]);
            } else {
                bonusPool += shares[i];
                emit PrizeForfeitedToPool(matchId, player, i + 1, shares[i]);
            }
        }
    }

    function claim() external nonReentrant returns (uint256 amount) {
        amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        imd.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice Rewarded placements `player` can still be paid for right now: the number of slots whose
    /// last rewarded placement is at least WINDOW old (or never used).
    function remainingRewardedWins(address player) external view returns (uint256 free) {
        uint64[MAX_REWARDED_WINS_PER_WINDOW] storage slots = _rewardedAt[player];
        for (uint256 i; i < MAX_REWARDED_WINS_PER_WINDOW; ++i) {
            if (block.timestamp >= uint256(slots[i]) + WINDOW) ++free;
        }
    }

    /// @notice Timestamps of `player`'s last rewarded placements (0 = unused slot).
    function rewardedAt(address player) external view returns (uint64[MAX_REWARDED_WINS_PER_WINDOW] memory) {
        return _rewardedAt[player];
    }

    /// @notice Earliest time at which `player` can be paid for another placement (now if a slot is free).
    function nextRewardedWinAt(address player) external view returns (uint256) {
        (, uint64 oldest) = _oldestSlot(player);
        uint256 freeAt = uint256(oldest) + WINDOW;
        return freeAt > block.timestamp ? freeAt : block.timestamp;
    }

    /// @dev Rolling cap: take the oldest of the player's last 3 rewarded placements; if it is at least
    /// WINDOW old (or the slot is unused) the placement is paid and overwrites that slot.
    function _consumeRewardedWin(address player) private returns (bool) {
        (uint256 idx, uint64 oldest) = _oldestSlot(player);
        if (block.timestamp < uint256(oldest) + WINDOW) return false;
        _rewardedAt[player][idx] = uint64(block.timestamp);
        return true;
    }

    function _oldestSlot(address player) private view returns (uint256 idx, uint64 oldest) {
        uint64[MAX_REWARDED_WINS_PER_WINDOW] storage slots = _rewardedAt[player];
        oldest = slots[0];
        for (uint256 i = 1; i < MAX_REWARDED_WINS_PER_WINDOW; ++i) {
            if (slots[i] < oldest) {
                oldest = slots[i];
                idx = i;
            }
        }
    }
}
