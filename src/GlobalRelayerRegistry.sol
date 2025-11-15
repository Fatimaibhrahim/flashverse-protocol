// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

error AlreadyRegistered(address relayer);
error NotRegistered(address relayer);
error Unauthorized();
error ZeroAddress();
error InvalidTier(uint8 tier);
error InvalidChainId(uint256 chainId);
error InsufficientStake(uint256 required, uint256 provided);
error LengthMismatch();
error InvalidRange();
error AlreadyVoted(address voter, address relayer);
error UnlockPending(uint256 availableAt);
error BatchTooLarge(uint256 provided, uint256 maxAllowed);
error ZeroAmount();
error NotMarkedForWithdrawal(address relayer);
error DecisionNotReady();

contract GlobalRelayerRegistry is
    Ownable, 
    ReentrancyGuard,
    Pausable 
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    /* ============================
       CONSTANTS
       ============================ */
    uint8 public constant MAX_TIER = 5;
    uint256 public constant MAX_BATCH = 50;

    /* ============================
       CONFIGURABLE STORAGE
       ============================ */
    uint256 public minStake;
    uint256 public unstakeCooldown;
    uint256 public voteThresholdPct;
    IERC20 public stakeToken;

    /* ============================
       EVENTS
       ============================ */
    event RelayerAdded(address indexed relayer, uint256 chainId, uint8 tier, uint256 stake, uint256 timestamp);
    event RelayerMarkedRemoved(address indexed relayer, uint256 timestamp, uint256 unlockAt);
    event RelayerWithdrawnStake(address indexed relayer, uint256 amount);
    event RelayerStaked(address indexed relayer, uint256 amount);
    event VoteCast(address indexed voter, address indexed relayer, bool approve, uint256 totalFor, uint256 totalAgainst);
    event GovernanceDecisionReady(address indexed relayer, bool approved, uint256 totalVotes, uint256 timestamp);
    event RelayerRemovedByGovernance(address indexed relayer, uint256 timestamp);
    event MinStakeUpdated(uint256 oldValue, uint256 newValue);
    event UnstakeCooldownUpdated(uint256 oldValue, uint256 newValue);
    event VoteThresholdUpdated(uint256 oldValue, uint256 newValue);

    /* ============================
       STORAGE
       ============================ */
    struct RelayerInfo {
        bool active;
        bool markedForRemoval;
        uint256 addedAt;
        uint8 tier;
        uint256 chainId;
        uint256 stake;
        uint256 votesFor;
        uint256 votesAgainst;
    }

    EnumerableSet.AddressSet private _relayerSet;
    mapping(address => RelayerInfo) private _relayers;
    mapping(address => mapping(address => bool)) private _voted;
    mapping(address => uint256) private _unlockTimestamp;

    /* ============================
       INTERNAL VALIDATORS
       ============================ */
    function _onlyActiveRelayer(address r) internal view {
        if (!_relayers[r].active) revert NotRegistered(r);
    }

    /* ============================
       MODIFIERS
       ============================ */
    modifier onlyActiveRelayer(address r) {
        _onlyActiveRelayer(r);
        _;
    }

    /* ============================
       CONSTRUCTOR
       ============================ */
    constructor(
        address _stakeToken,
        uint256 _minStake,
        uint256 _unstakeCooldown,
        uint256 _voteThresholdPct
    ) Ownable(msg.sender) {
        if (_stakeToken == address(0)) revert ZeroAddress();
        if (_voteThresholdPct > 100) revert InvalidRange();

        stakeToken = IERC20(_stakeToken);
        minStake = _minStake;
        unstakeCooldown = _unstakeCooldown;
        voteThresholdPct = _voteThresholdPct;
    }

    /* ============================
       ADMIN: parameter setters
       ============================ */
    function setMinStake(uint256 _minStake) external onlyOwner {
        emit MinStakeUpdated(minStake, _minStake);
        minStake = _minStake;
    }

    function setUnstakeCooldown(uint256 _cooldown) external onlyOwner {
        emit UnstakeCooldownUpdated(unstakeCooldown, _cooldown);
        unstakeCooldown = _cooldown;
    }

    function setVoteThresholdPct(uint256 _pct) external onlyOwner {
        if (_pct > 100) revert InvalidRange();
        emit VoteThresholdUpdated(voteThresholdPct, _pct);
        voteThresholdPct = _pct;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* ============================
       INTERNAL HELPERS
       ============================ */
    function _getRequiredStake(uint8 tier) internal view returns (uint256) {
        if (tier == 0 || tier > MAX_TIER) revert InvalidTier(tier);
        uint256 required = minStake * (uint256(tier));
        return (required == 0) ? minStake : required;
    }

    function _addRelayerInternal(address relayer, uint256 chainId, uint8 tier, uint256 stakeAmount) internal {
        if (relayer == address(0)) revert ZeroAddress();
        if (chainId == 0) revert InvalidChainId(chainId);
        if (_relayers[relayer].active || _relayers[relayer].markedForRemoval) revert AlreadyRegistered(relayer);

        _relayers[relayer] = RelayerInfo({
            active: true,
            markedForRemoval: false, 
            addedAt: block.timestamp,
            tier: tier,
            chainId: chainId,
            stake: stakeAmount,
            votesFor: 0,
            votesAgainst: 0
        });
        
        _relayerSet.add(relayer);
        emit RelayerAdded(relayer, chainId, tier, stakeAmount, block.timestamp);
    }

    function _markRemovedInternal(address relayer) internal {
        RelayerInfo storage info = _relayers[relayer];
        if (!info.active) revert NotRegistered(relayer);
        
        info.active = false;
        info.markedForRemoval = true;
        
        uint256 unlockAt = block.timestamp + unstakeCooldown;
        _unlockTimestamp[relayer] = unlockAt;
        
        _relayerSet.remove(relayer);

        emit RelayerMarkedRemoved(relayer, block.timestamp, unlockAt);
    }

    /* ============================
       EXTERNAL OPERATIONS
       ============================ */

    function addRelayer(uint256 chainId, uint8 tier) external whenNotPaused nonReentrant {
        address relayer = msg.sender;
        uint256 requiredStake = _getRequiredStake(tier);

        uint256 relayerBalance = stakeToken.balanceOf(relayer);
        if (relayerBalance < requiredStake) revert InsufficientStake(requiredStake, relayerBalance);

        stakeToken.safeTransferFrom(relayer, address(this), requiredStake);

        _addRelayerInternal(relayer, chainId, tier, requiredStake);
    }

    function removeRelayer(address relayer) external whenNotPaused onlyOwner nonReentrant {
        _markRemovedInternal(relayer);
    }

    function stakeMore(uint256 amount) external whenNotPaused nonReentrant {
        if (!_relayers[msg.sender].active && !_relayers[msg.sender].markedForRemoval) revert NotRegistered(msg.sender);
        if (amount == 0) revert ZeroAmount();
        
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        _relayers[msg.sender].stake += amount;
        
        emit RelayerStaked(msg.sender, amount);
    }

    function withdrawStake() external nonReentrant {
        address relayer = msg.sender;
        uint256 unlockAt = _unlockTimestamp[relayer];

        if (unlockAt == 0) revert NotMarkedForWithdrawal(relayer);
        if (block.timestamp < unlockAt) revert UnlockPending(unlockAt);
        
        RelayerInfo memory info = _relayers[relayer];

        delete _relayers[relayer];
        delete _unlockTimestamp[relayer];

        if (info.stake == 0) return;
        
        stakeToken.safeTransfer(relayer, info.stake);
        emit RelayerWithdrawnStake(relayer, info.stake);
    }

    /* ============================
       VOTING / GOVERNANCE
       ============================ */

    function voteOnRelayer(address relayer, bool approve) external whenNotPaused onlyActiveRelayer(msg.sender) {
        
        if (!_relayers[relayer].active) revert NotRegistered(relayer); 

        if (_voted[msg.sender][relayer]) revert AlreadyVoted(msg.sender, relayer);
        _voted[msg.sender][relayer] = true;

        RelayerInfo storage info = _relayers[relayer];

        if (approve) {
            info.votesFor += 1;
        } else {
            info.votesAgainst += 1;
        }

        emit VoteCast(msg.sender, relayer, approve, info.votesFor, info.votesAgainst);

        uint256 activeCount = _relayerSet.length();
        uint256 totalVotes = info.votesFor + info.votesAgainst;
        uint256 required = (activeCount * voteThresholdPct) / 100;

        if (required == 0 && activeCount > 0 && voteThresholdPct > 0) required = 1;

        if (totalVotes >= required) {
            bool decision = info.votesAgainst > info.votesFor;
            
            emit GovernanceDecisionReady(relayer, decision, totalVotes, block.timestamp);
            
            info.votesFor = 0;
            info.votesAgainst = 0;
        }
    }

    function executeGovernanceDecision(address relayer) external onlyOwner whenNotPaused nonReentrant {
        RelayerInfo storage info = _relayers[relayer];

        if (info.votesFor != 0 || info.votesAgainst != 0) revert DecisionNotReady();
        
        if (!_relayers[relayer].active) revert NotRegistered(relayer);

        _markRemovedInternal(relayer);
        emit RelayerRemovedByGovernance(relayer, block.timestamp);
    }

    /* ============================
       BATCH OPERATIONS
       ============================ */

    function addRelayersBatch(
        address[] calldata relayers,
        uint256[] calldata chainIds,
        uint8[] calldata tiers
    ) external whenNotPaused onlyOwner {
        uint256 n = relayers.length;
        if (n == 0) return;
        if (n != chainIds.length || n != tiers.length) revert LengthMismatch();
        if (n > MAX_BATCH) revert BatchTooLarge(n, MAX_BATCH);
        
        uint256 totalRequiredStake = 0;
        uint256[] memory requiredStakes = new uint256[](n);
        
        for (uint256 i = 0; i < n; i++) {
            uint256 required = _getRequiredStake(tiers[i]);
            requiredStakes[i] = required;
            totalRequiredStake += required;
        }

        if (totalRequiredStake > 0) {
            stakeToken.safeTransferFrom(msg.sender, address(this), totalRequiredStake);
        }

        for (uint256 i = 0; i < n; i++) {
            _addRelayerInternal(relayers[i], chainIds[i], tiers[i], requiredStakes[i]);
        }
    }

    function removeRelayersBatch(address[] calldata relayers) external whenNotPaused onlyOwner {
        uint256 n = relayers.length;
        if (n == 0) return;
        if (n > MAX_BATCH) revert BatchTooLarge(n, MAX_BATCH);
        
        for (uint256 i = 0; i < n; i++) {
            _markRemovedInternal(relayers[i]);
        }
    }

    /* ============================
       VIEWS / GETTERS
       ============================ */
    function isRelayer(address relayer) external view returns (bool) {
        return _relayers[relayer].active;
    }

    function getRelayerInfo(address relayer) external view returns (RelayerInfo memory) {
        return _relayers[relayer];
    }

    function totalRelayers() public view returns (uint256) {
        return _relayerSet.length();
    }

    function listRelayers(uint256 start, uint256 end) external view returns (address[] memory) {
        uint256 len = _relayerSet.length();
        if (start >= len) return new address[](0);
        if (end > len) end = len;
        if (end <= start) revert InvalidRange();

        address[] memory out = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = _relayerSet.at(i);
        }
        return out;
    }

    function unlockTimestampOf(address relayer) external view returns (uint256) {
        return _unlockTimestamp[relayer];
    }
}