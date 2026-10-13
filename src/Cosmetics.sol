// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, SafeTransfer, Owned, ReentrancyGuard} from "./lib/Common.sol";
import {PrizeVault} from "./PrizeVault.sol";

/// @title Cosmetics
/// @notice Sells cosmetic Pepe skins and gear for IMD. Purely cosmetic: items never affect combat.
/// Every sale is split at once:
///   20% burn share    → Buyback (spent on RISK that is burned to 0x…dEaD)
///   10% buyback share → Buyback (same buy-and-burn)
///   35%               → PrizeVault bonus pool
///   35%               → seats/stakers recipient (held here until the owner sets it)
/// Rounding dust goes to the PrizeVault share.
contract Cosmetics is Owned, ReentrancyGuard {
    using SafeTransfer for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant BURN_BPS = 2_000;
    uint256 public constant BUYBACK_BPS = 1_000;
    uint256 public constant SEATS_BPS = 3_500;
    // PrizeVault receives the remaining 3_500 bps plus rounding dust.

    struct Item {
        uint128 price; // IMD per unit
        uint64 maxSupply; // 0 = unlimited
        uint64 sold;
        bool active;
    }

    IERC20 public immutable imd;
    PrizeVault public immutable vault;
    address public immutable buyback;

    address public seatRewardsRecipient;
    uint256 public pendingSeatRewards;
    uint256 public totalRevenue;
    uint256 public totalToBuyback;
    uint256 public totalToVault;
    uint256 public totalToSeats;

    mapping(uint256 => Item) public items;
    mapping(address => mapping(uint256 => uint256)) public owned;

    event ItemConfigured(uint256 indexed itemId, uint256 price, uint256 maxSupply, bool active);
    event Purchased(address indexed buyer, uint256 indexed itemId, uint256 quantity, uint256 cost);
    event SeatRewardsRecipientSet(address indexed recipient);
    event SeatRewardsFlushed(address indexed recipient, uint256 amount);

    error ItemUnavailable();
    error SoldOut();
    error ZeroAmount();
    error SeatRecipientNotConfigured();
    error InvalidItem();

    constructor(address initialOwner, address imdToken, address prizeVault, address buybackAddr) Owned(initialOwner) {
        if (imdToken == address(0) || prizeVault == address(0) || buybackAddr == address(0)) revert ZeroAddress();
        imd = IERC20(imdToken);
        vault = PrizeVault(prizeVault);
        buyback = buybackAddr;
    }

    /// @notice Add or change an item. The supply cap cannot drop below what was already sold.
    function configureItem(uint256 itemId, uint128 price, uint64 maxSupply, bool active) external onlyOwner {
        if (price == 0) revert InvalidItem();
        Item storage it = items[itemId];
        if (maxSupply != 0 && maxSupply < it.sold) revert InvalidItem();
        it.price = price;
        it.maxSupply = maxSupply;
        it.active = active;
        emit ItemConfigured(itemId, price, maxSupply, active);
    }

    /// @notice Where the 35% seats/stakers share goes (a staking or seat-reward contract the owner
    /// chooses after launch). Until set, the share accumulates here.
    function setSeatRewardsRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        seatRewardsRecipient = recipient;
        emit SeatRewardsRecipientSet(recipient);
    }

    function buy(uint256 itemId, uint64 quantity) external nonReentrant returns (uint256 cost) {
        if (quantity == 0) revert ZeroAmount();
        Item storage it = items[itemId];
        if (!it.active) revert ItemUnavailable();
        uint64 sold = it.sold + quantity;
        if (it.maxSupply != 0 && sold > it.maxSupply) revert SoldOut();
        it.sold = sold;
        owned[msg.sender][itemId] += quantity;
        cost = uint256(it.price) * quantity;

        imd.safeTransferFrom(msg.sender, address(this), cost);
        uint256 toBuyback = cost * (BURN_BPS + BUYBACK_BPS) / BPS;
        uint256 toSeats = cost * SEATS_BPS / BPS;
        uint256 toVault = cost - toBuyback - toSeats;

        totalRevenue += cost;
        totalToBuyback += toBuyback;
        totalToVault += toVault;
        totalToSeats += toSeats;
        pendingSeatRewards += toSeats;

        if (toBuyback != 0) imd.safeTransfer(buyback, toBuyback);
        if (toVault != 0) {
            imd.forceApprove(address(vault), toVault);
            vault.fundBonus(toVault);
        }
        emit Purchased(msg.sender, itemId, quantity, cost);
    }

    /// @notice Send the accumulated seats/stakers share to the configured recipient. Anyone may call.
    function flushSeatRewards() external nonReentrant returns (uint256 amount) {
        address recipient = seatRewardsRecipient;
        if (recipient == address(0)) revert SeatRecipientNotConfigured();
        amount = pendingSeatRewards;
        if (amount == 0) revert ZeroAmount();
        pendingSeatRewards = 0;
        imd.safeTransfer(recipient, amount);
        emit SeatRewardsFlushed(recipient, amount);
    }
}
