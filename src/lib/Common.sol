// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @notice Internal-only safe ERC-20 helpers (inlined; no linking).
library SafeTransfer {
    error TransferFailed();

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _call(token, abi.encodeCall(IERC20.transfer, (to, value)));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _call(token, abi.encodeCall(IERC20.transferFrom, (from, to, value)));
    }

    /// @dev Sets the allowance to zero first so USDT-style tokens are accepted too.
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        _call(token, abi.encodeCall(IERC20.approve, (spender, 0)));
        if (value != 0) _call(token, abi.encodeCall(IERC20.approve, (spender, value)));
    }

    function _call(IERC20 token, bytes memory data) private {
        if (address(token).code.length == 0) revert TransferFailed();
        (bool ok, bytes memory ret) = address(token).call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}

/// @notice Two-step ownership. The owner is always a constructor argument ($owner), never msg.sender.
abstract contract Owned {
    address public owner;
    address public pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error ZeroAddress();

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }
}

abstract contract ReentrancyGuard {
    uint256 private _lock = 1;

    error Reentrancy();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }
}

/// @notice Minimal ECDSA recovery with malleability checks (internal only).
library SigLib {
    error BadSignature();

    function recover(bytes32 digest, bytes memory sig) internal pure returns (address signer) {
        if (sig.length != 65) revert BadSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) revert BadSignature();
        if (v != 27 && v != 28) revert BadSignature();
        signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert BadSignature();
    }
}

/// @notice Swap venue the owner configures after launch (an adapter in front of the RISK/IMD pool or
/// the IMD Community Coin curve). Must pull `amountIn` of `tokenIn` from msg.sender and send at least
/// `minAmountOut` of `tokenOut` to `recipient`.
interface ISwapVenue {
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);
}
