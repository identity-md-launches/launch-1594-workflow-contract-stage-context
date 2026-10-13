// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {Buyback} from "../../src/Buyback.sol";
import {PrizeVault} from "../../src/PrizeVault.sol";
import {MatchFactory} from "../../src/MatchFactory.sol";
import {Cosmetics} from "../../src/Cosmetics.sol";
import {IERC20} from "../../src/lib/Common.sol";

/// @dev Stand-in for IMD in tests only (the launch uses the real IMD address).
contract MockERC20 {
    string public name = "Mock IMD";
    string public symbol = "mIMD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function transferFrom(address f, address to, uint256 v) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= v;
        balanceOf[f] -= v;
        balanceOf[to] += v;
        return true;
    }
}

/// @dev Fixed-rate venue: pays `rateNum/rateDen` of tokenOut per tokenIn from its own inventory.
contract MockVenue {
    uint256 public rateNum = 1;
    uint256 public rateDen = 1;
    bool public reenter;
    address public reenterTarget;
    bytes public reenterData;

    function setRate(uint256 n, uint256 d) external {
        rateNum = n;
        rateDen = d;
    }

    function setReenter(address target, bytes calldata data) external {
        reenter = true;
        reenterTarget = target;
        reenterData = data;
    }

    function swapExactInput(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 out)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        if (reenter) {
            (bool ok, bytes memory ret) = reenterTarget.call(reenterData);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        out = amountIn * rateNum / rateDen;
        require(out >= minOut, "slippage");
        IERC20(tokenOut).transfer(recipient, out);
    }
}

abstract contract Fixtures is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal owner = makeAddr("owner");
    address internal factoryDeployer = makeAddr("launchFactory");

    LaunchToken internal risk;
    MockERC20 internal imd;
    Buyback internal buyback;
    PrizeVault internal vault;
    MatchFactory internal mf;
    Cosmetics internal cosmetics;
    MockVenue internal venue;

    uint256[6] internal pks = [uint256(0xA11CE), 0xB0B, 0xCA401, 0xD00D, 0xE11E, 0xF00D];
    address[6] internal p;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        imd = new MockERC20();
        vm.startPrank(factoryDeployer);
        risk = new LaunchToken();
        buyback = new Buyback(owner, address(imd), address(risk));
        vault = new PrizeVault(owner, address(imd));
        mf = new MatchFactory(owner, address(imd), address(risk), address(vault), address(buyback));
        cosmetics = new Cosmetics(owner, address(imd), address(vault), address(buyback));
        vm.stopPrank();
        venue = new MockVenue();

        for (uint256 i; i < 6; ++i) {
            p[i] = vm.addr(pks[i]);
            imd.mint(p[i], 1_000e18);
            vm.prank(factoryDeployer);
            risk.transfer(p[i], 1_000e18);
            vm.startPrank(p[i]);
            imd.approve(address(mf), type(uint256).max);
            imd.approve(address(cosmetics), type(uint256).max);
            risk.approve(address(mf), type(uint256).max);
            vm.stopPrank();
        }
        imd.mint(address(venue), 1_000_000e18);
        vm.prank(factoryDeployer);
        risk.transfer(address(venue), 1_000_000e18);
    }

    function _linkVault() internal {
        vm.prank(owner);
        vault.setMatchFactory(address(mf));
    }

    function _setVenue() internal {
        vm.prank(owner);
        buyback.setVenue(address(venue));
    }

    function _secret(uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("secret", i));
    }

    /// @dev Create a match with players 0..n-1 joining in IMD; full lobby moves to Revealing.
    function _openFull(uint8 n, uint96 fee) internal returns (uint256 id) {
        id = mf.nextMatchId();
        vm.prank(p[0]);
        mf.createMatch(n, fee, _commit(id, 0), 0, 0);
        for (uint256 i = 1; i < n; ++i) {
            vm.prank(p[i]);
            mf.join(id, _commit(id, i), 0, 0);
        }
    }

    function _commit(uint256 id, uint256 i) internal view returns (bytes32) {
        return keccak256(abi.encode(id, p[i], _secret(i)));
    }

    function _revealAll(uint256 id, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.prank(p[i]);
            mf.reveal(id, _secret(i));
        }
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _ranking(uint256 a, uint256 b, uint256 c, uint256 len) internal view returns (address[] memory r) {
        r = new address[](len);
        r[0] = p[a];
        r[1] = p[b];
        if (len > 2) r[2] = p[c];
    }

    function _unanimous(uint256 id, address[] memory ranking, uint256 n) internal view returns (bytes[] memory sigs) {
        bytes32 digest = mf.outcomeDigest(id, ranking);
        sigs = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            sigs[i] = _sign(pks[i], digest);
        }
    }
}
