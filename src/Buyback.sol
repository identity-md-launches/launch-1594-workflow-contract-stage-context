// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, SafeTransfer, Owned, ReentrancyGuard, ISwapVenue} from "./lib/Common.sol";

/// @title Buyback
/// @notice Holds the IMD that cosmetics sales route to buy-and-burn, buys RISK through the configured
/// swap venue and sends it to 0x…dEaD in the same transaction. Also routes players' RISK entries into
/// IMD for MatchFactory.
/// @dev The venue (an adapter for the RISK/IMD pool or the IMD Community Coin curve) is a value only the
/// requester holds, so it is an owner setting, and every function that needs it reverts with
/// VenueNotConfigured until it is set.
contract Buyback is Owned, ReentrancyGuard {
    using SafeTransfer for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable imd;
    IERC20 public immutable risk;

    ISwapVenue public venue;
    uint256 public totalImdSpent;
    uint256 public totalRiskBurned;

    event VenueSet(address indexed venue);
    event BuybackBurned(uint256 imdIn, uint256 riskBurned);
    event RiskRouted(address indexed payer, address indexed recipient, uint256 riskIn, uint256 imdOut);

    error VenueNotConfigured();
    error ZeroAmount();
    error InsufficientOutput();

    constructor(address initialOwner, address imdToken, address riskToken) Owned(initialOwner) {
        if (imdToken == address(0) || riskToken == address(0) || imdToken == riskToken) revert ZeroAddress();
        imd = IERC20(imdToken);
        risk = IERC20(riskToken);
    }

    function setVenue(address newVenue) external onlyOwner {
        if (newVenue == address(0)) revert ZeroAddress();
        venue = ISwapVenue(newVenue);
        emit VenueSet(newVenue);
    }

    /// @notice Spend `imdIn` of the held IMD on RISK and burn all RISK received. Owner-only so the
    /// slippage bound `minRiskOut` is chosen by an accountable party (a permissionless call could be
    /// sandwiched with minRiskOut = 0).
    function executeBuyback(uint256 imdIn, uint256 minRiskOut)
        external
        onlyOwner
        nonReentrant
        returns (uint256 burned)
    {
        ISwapVenue v = venue;
        if (address(v) == address(0)) revert VenueNotConfigured();
        if (imdIn == 0) revert ZeroAmount();
        uint256 riskBefore = risk.balanceOf(address(this));
        imd.forceApprove(address(v), imdIn);
        v.swapExactInput(address(imd), address(risk), imdIn, minRiskOut, address(this));
        imd.forceApprove(address(v), 0);
        burned = risk.balanceOf(address(this)) - riskBefore;
        if (burned < minRiskOut || burned == 0) revert InsufficientOutput();
        risk.safeTransfer(DEAD, burned);
        totalImdSpent += imdIn;
        totalRiskBurned += burned;
        emit BuybackBurned(imdIn, burned);
    }

    /// @notice Burn any RISK that sits in this contract (e.g. sent by mistake or donated).
    function burnHeldRisk() external nonReentrant returns (uint256 amount) {
        amount = risk.balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();
        risk.safeTransfer(DEAD, amount);
        totalRiskBurned += amount;
        emit BuybackBurned(0, amount);
    }

    /// @notice Pull `riskIn` RISK from the caller, swap it to IMD and send the IMD to `recipient`.
    /// The caller sets its own slippage bound with `minImdOut`.
    function routeRiskToImd(uint256 riskIn, uint256 minImdOut, address recipient)
        external
        nonReentrant
        returns (uint256 imdOut)
    {
        ISwapVenue v = venue;
        if (address(v) == address(0)) revert VenueNotConfigured();
        if (riskIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        risk.safeTransferFrom(msg.sender, address(this), riskIn);
        uint256 before = imd.balanceOf(recipient);
        risk.forceApprove(address(v), riskIn);
        v.swapExactInput(address(risk), address(imd), riskIn, minImdOut, recipient);
        risk.forceApprove(address(v), 0);
        imdOut = imd.balanceOf(recipient) - before;
        if (imdOut < minImdOut || imdOut == 0) revert InsufficientOutput();
        emit RiskRouted(msg.sender, recipient, riskIn, imdOut);
    }

    /// @notice RISK held at 0x…dEaD.
    function burnedSupply() external view returns (uint256) {
        return risk.balanceOf(DEAD);
    }

    /// @notice Circulating RISK = totalSupply - balance of 0x…dEaD.
    function circulatingSupply() external view returns (uint256) {
        return risk.totalSupply() - risk.balanceOf(DEAD);
    }
}
