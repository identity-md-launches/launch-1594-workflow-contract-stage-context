// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, SafeTransfer, Owned, ReentrancyGuard, SigLib} from "./lib/Common.sol";
import {PrizeVault} from "./PrizeVault.sol";
import {Buyback} from "./Buyback.sol";

/// @title MatchFactory
/// @notice Creates and settles IMD PEPE RISK matches (2–6 players) with IMD entry fees.
///
/// Lifecycle: Open (players join, each with a commitment to a secret) → Revealing (every player
/// reveals; the dice seed is the XOR of all secrets' hashes, so no single player picks it) → Playing
/// (the game runs off chain with dice derived from the seed by RiskRules) → Settled (the ranking is
/// signed by every player, or by the owner-configured seat outcome signer; the pot goes to PrizeVault).
/// Failure paths refund by pull payment: an under-filled lobby, a player who never reveals (their entry
/// is shared among those who did), and a match nobody settles in time.
///
/// Entry can be paid in RISK: 10% is burned to 0x…dEaD and 90% is routed to IMD through Buyback; any
/// IMD above the entry fee is returned to the player.
contract MatchFactory is Owned, ReentrancyGuard {
    using SafeTransfer for IERC20;

    enum Status {
        None,
        Open,
        Revealing,
        Playing,
        Settled,
        Cancelled
    }

    struct Match {
        address creator;
        uint96 entryFee;
        uint8 maxPlayers;
        uint8 playerCount;
        uint8 revealedCount;
        Status status;
        uint64 joinDeadline;
        uint64 revealDeadline;
        uint64 playDeadline;
        bytes32 seed;
        uint256 pot;
    }

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MIN_PLAYERS = 2;
    uint256 public constant MAX_PLAYERS = 6;
    uint256 public constant MIN_ENTRY = 1e17; // 0.1 IMD
    uint256 public constant MAX_ENTRY = 10_000e18;
    uint256 public constant JOIN_WINDOW = 30 minutes;
    uint256 public constant REVEAL_WINDOW = 10 minutes;
    uint256 public constant PLAY_WINDOW = 30 minutes;
    uint256 public constant SETTLE_GRACE = 1 days;
    uint256 public constant RISK_ENTRY_BURN_BPS = 1_000;
    uint256 public constant BPS = 10_000;

    bytes32 public constant OUTCOME_TYPEHASH = keccak256("Outcome(uint256 matchId,bytes32 seed,bytes32 rankingHash)");
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    IERC20 public immutable imd;
    IERC20 public immutable risk;
    PrizeVault public immutable vault;
    Buyback public immutable buyback;

    address public outcomeSigner;
    uint256 public nextMatchId = 1;
    uint256 public totalRiskBurned;
    uint256 public totalRefundsOwed;

    mapping(uint256 => Match) internal _matches;
    mapping(uint256 => address[]) internal _players;
    mapping(uint256 => mapping(address => bytes32)) public commitOf;
    mapping(uint256 => mapping(address => bool)) public revealed;
    mapping(address => uint256) public refunds;

    event OutcomeSignerSet(address indexed signer);
    event MatchCreated(uint256 indexed matchId, address indexed creator, uint256 maxPlayers, uint256 entryFee);
    event PlayerJoined(uint256 indexed matchId, address indexed player, bool paidInRisk, uint256 riskBurned);
    event RevealStarted(uint256 indexed matchId, uint256 revealDeadline);
    event SecretRevealed(uint256 indexed matchId, address indexed player);
    event MatchStarted(uint256 indexed matchId, bytes32 seed, uint256 playDeadline);
    event MatchSettled(uint256 indexed matchId, address[] ranking, bool seatAttested);
    event MatchCancelled(uint256 indexed matchId, uint8 reason);
    event RefundCredited(uint256 indexed matchId, address indexed player, uint256 amount);
    event RefundWithdrawn(address indexed player, uint256 amount);

    error InvalidPlayerCount();
    error InvalidEntryFee();
    error InvalidCommit();
    error WrongStatus();
    error MatchFull();
    error AlreadyJoined();
    error NotPlayer();
    error AlreadyRevealed();
    error BadReveal();
    error TooEarly();
    error TooLate();
    error NotAuthorized();
    error InvalidRanking();
    error InvalidSignatures();
    error OutcomeSignerNotConfigured();
    error InsufficientImdOut();
    error NothingToWithdraw();

    constructor(address initialOwner, address imdToken, address riskToken, address prizeVault, address buybackAddr)
        Owned(initialOwner)
    {
        if (
            imdToken == address(0) || riskToken == address(0) || prizeVault == address(0) || buybackAddr == address(0)
                || imdToken == riskToken
        ) revert ZeroAddress();
        imd = IERC20(imdToken);
        risk = IERC20(riskToken);
        vault = PrizeVault(prizeVault);
        buyback = Buyback(buybackAddr);
    }

    // ------------------------------------------------------------------ admin

    /// @notice Seat outcome signer (the swarm seats' attestation key). Zero disables the seat path.
    function setOutcomeSigner(address signer) external onlyOwner {
        outcomeSigner = signer;
        emit OutcomeSignerSet(signer);
    }

    // ------------------------------------------------------------------ lobby

    /// @param commit keccak256(abi.encode(matchId, player, secret)); see commitmentFor.
    /// @param riskIn 0 to pay the entry in IMD, otherwise RISK to route into IMD.
    /// @param minImdOut slippage bound for the RISK route (at least entryFee).
    function createMatch(uint8 maxPlayers, uint96 entryFee, bytes32 commit, uint256 riskIn, uint256 minImdOut)
        external
        nonReentrant
        returns (uint256 matchId)
    {
        if (maxPlayers < MIN_PLAYERS || maxPlayers > MAX_PLAYERS) revert InvalidPlayerCount();
        if (entryFee < MIN_ENTRY || entryFee > MAX_ENTRY) revert InvalidEntryFee();
        matchId = nextMatchId++;
        Match storage m = _matches[matchId];
        m.creator = msg.sender;
        m.entryFee = entryFee;
        m.maxPlayers = maxPlayers;
        m.status = Status.Open;
        m.joinDeadline = uint64(block.timestamp + JOIN_WINDOW);
        emit MatchCreated(matchId, msg.sender, maxPlayers, entryFee);
        _join(matchId, m, commit, riskIn, minImdOut);
    }

    function join(uint256 matchId, bytes32 commit, uint256 riskIn, uint256 minImdOut) external nonReentrant {
        Match storage m = _matches[matchId];
        if (m.status != Status.Open) revert WrongStatus();
        if (block.timestamp > m.joinDeadline) revert TooLate();
        if (m.playerCount >= m.maxPlayers) revert MatchFull();
        _join(matchId, m, commit, riskIn, minImdOut);
    }

    /// @notice Close the lobby early: the creator once two players are in, anyone after the join window.
    /// A lobby with fewer than two players after the window is cancelled and refunded.
    function startReveal(uint256 matchId) external nonReentrant {
        Match storage m = _matches[matchId];
        if (m.status != Status.Open) revert WrongStatus();
        bool expired = block.timestamp > m.joinDeadline;
        if (!expired && msg.sender != m.creator) revert NotAuthorized();
        if (m.playerCount < MIN_PLAYERS) {
            if (!expired) revert TooEarly();
            _cancelAndRefundAll(matchId, m, 1);
            return;
        }
        _beginReveal(matchId, m);
    }

    // ------------------------------------------------------------------ commit-reveal

    function reveal(uint256 matchId, bytes32 secret) external nonReentrant {
        Match storage m = _matches[matchId];
        if (m.status != Status.Revealing) revert WrongStatus();
        if (block.timestamp > m.revealDeadline) revert TooLate();
        bytes32 commit = commitOf[matchId][msg.sender];
        if (commit == bytes32(0)) revert NotPlayer();
        if (revealed[matchId][msg.sender]) revert AlreadyRevealed();
        if (commitmentFor(matchId, msg.sender, secret) != commit) revert BadReveal();
        revealed[matchId][msg.sender] = true;
        m.seed ^= keccak256(abi.encode(secret));
        emit SecretRevealed(matchId, msg.sender);
        if (++m.revealedCount == m.playerCount) {
            m.status = Status.Playing;
            m.playDeadline = uint64(block.timestamp + PLAY_WINDOW);
            emit MatchStarted(matchId, m.seed, m.playDeadline);
        }
    }

    /// @notice After the reveal window: revealers get their entry back plus an equal share of the
    /// entries of players who did not reveal. If nobody revealed, everyone is refunded.
    function cancelUnrevealed(uint256 matchId) external nonReentrant {
        Match storage m = _matches[matchId];
        if (m.status != Status.Revealing) revert WrongStatus();
        if (block.timestamp <= m.revealDeadline) revert TooEarly();
        uint256 revealers = m.revealedCount;
        if (revealers == 0) {
            _cancelAndRefundAll(matchId, m, 2);
            return;
        }
        m.status = Status.Cancelled;
        uint256 pot = m.pot;
        m.pot = 0;
        uint256 share = pot / revealers;
        uint256 dust = pot - share * revealers;
        address[] storage players = _players[matchId];
        bool dustPaid;
        for (uint256 i; i < players.length; ++i) {
            address p = players[i];
            if (!revealed[matchId][p]) continue;
            uint256 amount = share;
            if (!dustPaid) {
                amount += dust;
                dustPaid = true;
            }
            _credit(matchId, p, amount);
        }
        emit MatchCancelled(matchId, 2);
    }

    // ------------------------------------------------------------------ settlement

    /// @notice Settle with the final ranking (first, second[, third]); length is min(3, players).
    /// @param signatures either one signature per player in join order (unanimous), or a single
    /// signature from the seat outcome signer. Seat-attested matches also draw from the bonus pool.
    function settle(uint256 matchId, address[] calldata ranking, bytes[] calldata signatures) external nonReentrant {
        Match storage m = _matches[matchId];
        if (m.status != Status.Playing) revert WrongStatus();
        if (block.timestamp > uint256(m.playDeadline) + SETTLE_GRACE) revert TooLate();
        _checkRanking(matchId, m, ranking);

        bytes32 digest = outcomeDigest(matchId, ranking);
        address[] storage players = _players[matchId];
        bool seatAttested;
        if (signatures.length == players.length) {
            for (uint256 i; i < players.length; ++i) {
                if (SigLib.recover(digest, signatures[i]) != players[i]) revert InvalidSignatures();
            }
        } else if (signatures.length == 1) {
            address signer = outcomeSigner;
            if (signer == address(0)) revert OutcomeSignerNotConfigured();
            if (SigLib.recover(digest, signatures[0]) != signer) revert InvalidSignatures();
            seatAttested = true;
        } else {
            revert InvalidSignatures();
        }

        m.status = Status.Settled;
        uint256 pot = m.pot;
        m.pot = 0;
        address[3] memory rank3;
        for (uint256 i; i < ranking.length; ++i) {
            rank3[i] = ranking[i];
        }
        imd.safeTransfer(address(vault), pot);
        vault.awardMatch(matchId, rank3, ranking.length, pot, seatAttested);
        emit MatchSettled(matchId, ranking, seatAttested);
    }

    /// @notice Refund every player of a match that was not settled within the grace period.
    function expire(uint256 matchId) external nonReentrant {
        Match storage m = _matches[matchId];
        if (m.status != Status.Playing) revert WrongStatus();
        if (block.timestamp <= uint256(m.playDeadline) + SETTLE_GRACE) revert TooEarly();
        _cancelAndRefundAll(matchId, m, 3);
    }

    function withdrawRefund() external nonReentrant returns (uint256 amount) {
        amount = refunds[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        refunds[msg.sender] = 0;
        totalRefundsOwed -= amount;
        imd.safeTransfer(msg.sender, amount);
        emit RefundWithdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------------ views

    function getMatch(uint256 matchId) external view returns (Match memory) {
        return _matches[matchId];
    }

    function playersOf(uint256 matchId) external view returns (address[] memory) {
        return _players[matchId];
    }

    function commitmentFor(uint256 matchId, address player, bytes32 secret) public pure returns (bytes32) {
        return keccak256(abi.encode(matchId, player, secret));
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("IMD PEPE RISK"), keccak256("1"), block.chainid, address(this))
        );
    }

    /// @notice EIP-712 digest players or the seat signer sign for a ranking.
    function outcomeDigest(uint256 matchId, address[] calldata ranking) public view returns (bytes32) {
        bytes32 structHash =
            keccak256(abi.encode(OUTCOME_TYPEHASH, matchId, _matches[matchId].seed, keccak256(abi.encode(ranking))));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    // ------------------------------------------------------------------ internal

    function _join(uint256 matchId, Match storage m, bytes32 commit, uint256 riskIn, uint256 minImdOut) private {
        if (commit == bytes32(0)) revert InvalidCommit();
        if (commitOf[matchId][msg.sender] != bytes32(0)) revert AlreadyJoined();
        commitOf[matchId][msg.sender] = commit;
        _players[matchId].push(msg.sender);
        uint256 fee = m.entryFee;
        m.pot += fee;
        uint256 burned;
        if (riskIn == 0) {
            imd.safeTransferFrom(msg.sender, address(this), fee);
        } else {
            burned = _payWithRisk(fee, riskIn, minImdOut);
        }
        emit PlayerJoined(matchId, msg.sender, riskIn != 0, burned);
        if (++m.playerCount == m.maxPlayers) _beginReveal(matchId, m);
    }

    function _payWithRisk(uint256 fee, uint256 riskIn, uint256 minImdOut) private returns (uint256 burned) {
        if (minImdOut < fee) revert InsufficientImdOut();
        risk.safeTransferFrom(msg.sender, address(this), riskIn);
        burned = riskIn * RISK_ENTRY_BURN_BPS / BPS;
        risk.safeTransfer(DEAD, burned);
        totalRiskBurned += burned;
        uint256 routed = riskIn - burned;
        risk.forceApprove(address(buyback), routed);
        uint256 imdOut = buyback.routeRiskToImd(routed, minImdOut, address(this));
        if (imdOut < fee) revert InsufficientImdOut();
        if (imdOut > fee) imd.safeTransfer(msg.sender, imdOut - fee);
    }

    function _beginReveal(uint256 matchId, Match storage m) private {
        m.status = Status.Revealing;
        m.revealDeadline = uint64(block.timestamp + REVEAL_WINDOW);
        emit RevealStarted(matchId, m.revealDeadline);
    }

    function _checkRanking(uint256 matchId, Match storage m, address[] calldata ranking) private view {
        uint256 expected = m.playerCount < 3 ? m.playerCount : 3;
        if (ranking.length != expected) revert InvalidRanking();
        for (uint256 i; i < ranking.length; ++i) {
            if (commitOf[matchId][ranking[i]] == bytes32(0)) revert InvalidRanking();
            for (uint256 j; j < i; ++j) {
                if (ranking[j] == ranking[i]) revert InvalidRanking();
            }
        }
    }

    function _cancelAndRefundAll(uint256 matchId, Match storage m, uint8 reason) private {
        m.status = Status.Cancelled;
        m.pot = 0;
        address[] storage players = _players[matchId];
        uint256 fee = m.entryFee;
        for (uint256 i; i < players.length; ++i) {
            _credit(matchId, players[i], fee);
        }
        emit MatchCancelled(matchId, reason);
    }

    function _credit(uint256 matchId, address player, uint256 amount) private {
        refunds[player] += amount;
        totalRefundsOwed += amount;
        emit RefundCredited(matchId, player, amount);
    }
}
