// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, SafeTransfer, Owned, ReentrancyGuard} from "./lib/Common.sol";

/// @title PrizeVault
/// @notice Pays match prizes in IMD only, by pull payment. Splits a settled match's prize 60/25/15
/// (75/25 for two-player matches) and enforces the anti-farming cap: at most 3 rewarded placements per
/// wallet in a rolling 24-hour window. A placement over the cap is not paid; its share goes to the bonus
/// pool for later matches. Nothing is minted: every IMD paid out was deposited first.
/// @dev The vault only accepts awards from the MatchFactory the owner links once after launch.
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
    mapping(address => uint64) public windowStart;
    mapping(address => uint8) public winsInWindow;

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

    constructor(address initialOwner, address imdToken) Owned(initialOwner) {
        if (imdToken == address(0)) revert ZeroAddress();
        imd = IERC20(imdToken);
    }

    /// @notice One-time link to the launch's MatchFactory (its address is in the deployment handoff).
    function setMatchFactory(address factory) external onlyOwner {
        if (factory == address(0)) revert ZeroAddress();
        if (matchFactory != address(0)) revert MatchFactoryAlreadySet();
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

    /// @notice Rewarded placements still available to `player` in the current window.
    function remainingRewardedWins(address player) external view returns (uint256) {
        if (block.timestamp >= uint256(windowStart[player]) + WINDOW) return MAX_REWARDED_WINS_PER_WINDOW;
        return MAX_REWARDED_WINS_PER_WINDOW - winsInWindow[player];
    }

    function _consumeRewardedWin(address player) private returns (bool) {
        if (block.timestamp >= uint256(windowStart[player]) + WINDOW) {
            windowStart[player] = uint64(block.timestamp);
            winsInWindow[player] = 1;
            return true;
        }
        if (winsInWindow[player] >= MAX_REWARDED_WINS_PER_WINDOW) return false;
        ++winsInWindow[player];
        return true;
    }
}
