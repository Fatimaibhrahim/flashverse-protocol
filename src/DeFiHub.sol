// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  DeFiHub v3 – FlashVerse
/// @notice All-in-one DeFi protocol: staking, lending, swapping.
///         Phase 1: Staking + Swap active.
///         Phase 2: Lending (gated by phase2Enabled flag, off by default).
/// @author FlashVerse Core Team
/// @dev    Security stack:
///           • OpenZeppelin AccessControl   — role-based permissions
///           • OpenZeppelin Pausable        — circuit-breaker
///           • OpenZeppelin ReentrancyGuard — re-entry protection
///           • SafeERC20 + forceApprove     — safe token transfers
///           • Custom errors                — gas-efficient reverts
///           • Timelock (2 days)            — delayed sensitive changes
///           • On-chain health factor       — borrow safety check
///           • Max positions cap            — gas griefing protection
///           • Oracle interface ready       — Phase 2 price feeds
///           • Liquidation mechanism        — Phase 2

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  INTERFACES
// ─────────────────────────────────────────────────────────────────────────────

interface IDEXAdapter {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external returns (uint256 amountOut);
}

interface ILendingAdapter {
    function deposit(address token, uint256 amount) external;
    function withdraw(address token, uint256 amount, address to) external;
    function borrow(address token, uint256 amount, address to) external;
    function repay(address token, uint256 amount) external;
    function getAccountSnapshot(address account, address token)
        external view returns (uint256 collateral, uint256 debt);
}

/// @dev Phase 2 — Chainlink-compatible price oracle
interface IPriceOracle {
    function getPrice(address token) external view returns (uint256 price, uint8 decimals);
}

// ─────────────────────────────────────────────────────────────────────────────
//  CUSTOM ERRORS
// ─────────────────────────────────────────────────────────────────────────────

error ZeroAddress();
error ZeroAmount();
error SameAddress();
error InvalidAmount(uint256 min, uint256 max);
error InvalidFee(uint256 provided, uint256 max);
error InsufficientBalance(uint256 available, uint256 requested);
error NoStakeFound();
error NoActivePosition();
error SlippageExceeded(uint256 amountOut, uint256 minOut);
error ETHNotAccepted();
error EmergencyModeOff();
error NoPendingChange();
error AdapterNotWhitelisted(address adapter);
error ProtectedToken(address token);
error Phase2NotEnabled();
error HealthFactorTooLow(uint256 current, uint256 minimum);
error MaxPositionsReached(uint256 max);
error OracleNotSet();
error LiquidationNotAllowed(uint256 healthFactor);
error TimelockAlreadyQueued(bytes4 selector);

// ─────────────────────────────────────────────────────────────────────────────
//  DEFIHUB v3
// ─────────────────────────────────────────────────────────────────────────────

contract DeFiHub is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Roles ─────────────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE      = keccak256("ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE  = keccak256("EMERGENCY_ROLE");
    bytes32 public constant GUARDIAN_ROLE   = keccak256("GUARDIAN_ROLE");
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");

    // ── Protocol constants ─────────────────────────────────────────────────────
    uint256 public constant PRECISION              = 1e18;
    uint256 public constant SECONDS_PER_DAY        = 86_400;
    uint256 public constant MAX_REWARD_RATE        = 10e18;
    uint256 public constant TOTAL_REWARD_CAP       = 100_000_000e18;
    uint256 public constant MAX_FEE_BPS            = 100;
    uint256 public constant ABS_MIN_HEALTH_FACTOR  = 1e18;
    uint256 public constant TIMELOCK_DELAY         = 2 days;
    uint256 public constant MAX_POSITIONS_PER_USER = 10;
    uint256 public constant LIQUIDATION_BONUS      = 1.05e18;
    uint256 public constant LIQUIDATION_THRESHOLD  = 0.85e18;

    // ── Immutables ─────────────────────────────────────────────────────────────
    IERC20 public immutable STAKING_TOKEN;
    IERC20 public immutable REWARD_TOKEN;

    // ── Structs ────────────────────────────────────────────────────────────────
    struct StakeInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 totalClaimed;
        uint256 stakedAt;
    }

    struct LendingPosition {
        uint256 deposited;
        uint256 borrowed;
        bool    active;
    }

    struct TimelockEntry {
        uint256 unlocksAt;
        bytes   payload;
        bool    exists;
    }

    struct OracleConfig {
        address oracle;
        uint256 maxAge;
    }

    // ── Staking state ──────────────────────────────────────────────────────────
    mapping(address => StakeInfo) private _stakes;
    uint256 public totalStaked;
    uint256 public totalStakersCount;
    uint256 public accRewardPerShare;
    uint256 public lastRewardTime;
    uint256 public totalRewardsDistributed;
    uint256 public rewardRate;
    uint256 public minStakeAmount;

    // ── Fee / Treasury state ───────────────────────────────────────────────────
    uint256 public swapFeeBps;
    uint256 public depositFeeBps;
    address public treasury;
    mapping(address => uint256) public treasuryBalances;

    // ── Lending state (Phase 2) ────────────────────────────────────────────────
    mapping(address => mapping(address => LendingPosition)) private _positions;
    mapping(address => address[]) private _userActiveTokens;
    mapping(address => uint256)   public  userPositionCount;
    uint256 public minHealthFactor;
    mapping(address => bool)      public  isLendingToken;
    mapping(address => OracleConfig) public tokenOracles;

    // ── Adapter state ──────────────────────────────────────────────────────────
    address public dexAdapter;
    address public lendingAdapter;
    mapping(address => bool) public isAdapterWhitelisted;

    // ── Control flags ──────────────────────────────────────────────────────────
    bool public emergencyMode;
    bool public phase2Enabled;

    // ── Timelock ───────────────────────────────────────────────────────────────
    mapping(bytes4 => TimelockEntry) private _timelockQueue;

    // ── Events ─────────────────────────────────────────────────────────────────
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount, uint256 rewardsPaid);
    event RewardsClaimed(address indexed user, uint256 amount);
    event EmergencyUnstake(address indexed user, uint256 amount);
    event LendingDeposit(address indexed user, address indexed token, uint256 netAmount);
    event LendingWithdraw(address indexed user, address indexed token, uint256 amount);
    event LendingBorrow(address indexed user, address indexed token, uint256 amount);
    event LendingRepay(address indexed user, address indexed token, uint256 amount);
    event Liquidated(address indexed user, address indexed liquidator, address indexed token, uint256 repaid, uint256 seized);
    event SwapExecuted(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event AdaptersSet(address indexed dex, address indexed lending);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);
    event FeesUpdated(uint256 swapBps, uint256 depositBps);
    event MinStakeAmountUpdated(uint256 newMin);
    event MinHealthFactorUpdated(uint256 newFactor);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event Phase2Enabled(address indexed by);
    event OracleSet(address indexed token, address indexed oracle, uint256 maxAge);
    event TimelockQueued(bytes4 indexed selector, uint256 unlocksAt);
    event TimelockExecuted(bytes4 indexed selector);
    event TimelockCancelled(bytes4 indexed selector);
    event EmergencyModeToggled(bool active);
    event ProtocolPaused(address indexed by);
    event ProtocolUnpaused(address indexed by);
    event TokensRescued(address indexed token, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────
    //  CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────────

    constructor(
        address stakingToken_,
        address rewardToken_,
        uint256 rewardRate_,
        address treasury_
    ) {
        if (stakingToken_ == address(0) || rewardToken_ == address(0) || treasury_ == address(0))
            revert ZeroAddress();
        if (stakingToken_ == rewardToken_) revert SameAddress();
        if (rewardRate_ > MAX_REWARD_RATE)  revert InvalidAmount(0, MAX_REWARD_RATE);

        STAKING_TOKEN   = IERC20(stakingToken_);
        REWARD_TOKEN    = IERC20(rewardToken_);
        rewardRate      = rewardRate_;
        treasury        = treasury_;
        swapFeeBps      = 30;
        depositFeeBps   = 10;
        minHealthFactor = 1.2e18;
        minStakeAmount  = 1e6;
        lastRewardTime  = block.timestamp;
        phase2Enabled   = false;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE,         msg.sender);
        _grantRole(EMERGENCY_ROLE,     msg.sender);
        _grantRole(GUARDIAN_ROLE,      msg.sender);
        _grantRole(LIQUIDATOR_ROLE,    msg.sender);
    }

    receive() external payable { revert ETHNotAccepted(); }

    // ── Modifiers ──────────────────────────────────────────────────────────────
    modifier onlyAdmin()      { _checkRole(ADMIN_ROLE);      _; }
    modifier onlyEmergency()  { _checkRole(EMERGENCY_ROLE);  _; }
    modifier onlyGuardian()   { _checkRole(GUARDIAN_ROLE);   _; }
    modifier onlyLiquidator() { _checkRole(LIQUIDATOR_ROLE); _; }
    modifier notZeroAddress(address a)  { if (a == address(0)) revert ZeroAddress(); _; }
    modifier notZeroAmount(uint256 v)   { if (v == 0)          revert ZeroAmount();  _; }
    modifier onlyPhase2() { if (!phase2Enabled) revert Phase2NotEnabled(); _; }
    modifier validDexAdapter() {
        if (dexAdapter == address(0) || !isAdapterWhitelisted[dexAdapter])
            revert AdapterNotWhitelisted(dexAdapter);
        _;
    }
    modifier validLendingAdapter() {
        if (lendingAdapter == address(0) || !isAdapterWhitelisted[lendingAdapter])
            revert AdapterNotWhitelisted(lendingAdapter);
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  INTERNAL
    // ─────────────────────────────────────────────────────────────────────────

    function _updatePool() internal {
        if (totalStaked == 0) { lastRewardTime = block.timestamp; return; }
        uint256 elapsed  = block.timestamp - lastRewardTime;
        if (elapsed == 0) return;
        uint256 pending  = (totalStaked * rewardRate * elapsed) / (PRECISION * SECONDS_PER_DAY);
        uint256 remaining = TOTAL_REWARD_CAP > totalRewardsDistributed
            ? TOTAL_REWARD_CAP - totalRewardsDistributed : 0;
        if (pending > remaining) pending = remaining;
        if (pending > 0) accRewardPerShare += (pending * PRECISION) / totalStaked;
        lastRewardTime = block.timestamp;
    }

    function _settlePending(address user) internal returns (uint256 accrued) {
        StakeInfo storage s = _stakes[user];
        if (s.amount > 0) accrued = (s.amount * accRewardPerShare) / PRECISION - s.rewardDebt;
        s.rewardDebt = (s.amount * accRewardPerShare) / PRECISION;
    }

    function _transferRewards(address user, uint256 amount) internal {
        if (amount == 0) return;
        totalRewardsDistributed    += amount;
        _stakes[user].totalClaimed += amount;
        REWARD_TOKEN.safeTransfer(user, amount);
    }

    function _healthFactor(address user, address token) internal view returns (uint256) {
        LendingPosition storage pos = _positions[user][token];
        if (pos.borrowed == 0) return type(uint256).max;
        OracleConfig storage cfg = tokenOracles[token];
        if (cfg.oracle == address(0)) revert OracleNotSet();
        (uint256 price, uint8 decimals) = IPriceOracle(cfg.oracle).getPrice(token);
        uint256 normalizedPrice = price * PRECISION / (10 ** decimals);
        uint256 collateralUSD   = (pos.deposited * normalizedPrice) / PRECISION;
        uint256 debtUSD         = (pos.borrowed  * normalizedPrice) / PRECISION;
        return (collateralUSD * LIQUIDATION_THRESHOLD) / debtUSD;
    }

    function _removeActiveToken(address user, address token) internal {
        address[] storage tokens = _userActiveTokens[user];
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; i++) {
            if (tokens[i] == token) {
                tokens[i] = tokens[len - 1];
                tokens.pop();
                break;
            }
        }
    }

    function _closePositionIfEmpty(address user, address token) internal {
        LendingPosition storage pos = _positions[user][token];
        if (pos.deposited == 0 && pos.borrowed == 0) {
            pos.active = false;
            userPositionCount[user]--;
            _removeActiveToken(user, token);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  STAKING — Phase 1
    // ─────────────────────────────────────────────────────────────────────────

    function stake(uint256 amount) external nonReentrant whenNotPaused notZeroAmount(amount) {
        if (amount < minStakeAmount) revert InvalidAmount(minStakeAmount, type(uint256).max);
        _updatePool();
        _settlePending(msg.sender);
        StakeInfo storage s = _stakes[msg.sender];
        bool isNew = (s.amount == 0);
        STAKING_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        s.amount    += amount;
        s.stakedAt   = block.timestamp;
        s.rewardDebt = (s.amount * accRewardPerShare) / PRECISION;
        totalStaked += amount;
        if (isNew) totalStakersCount++;
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant whenNotPaused notZeroAmount(amount) {
        StakeInfo storage s = _stakes[msg.sender];
        if (s.amount < amount) revert InsufficientBalance(s.amount, amount);
        _updatePool();
        uint256 accrued = _settlePending(msg.sender);
        _transferRewards(msg.sender, accrued);
        s.amount    -= amount;
        totalStaked -= amount;
        s.rewardDebt = (s.amount * accRewardPerShare) / PRECISION;
        if (s.amount == 0) totalStakersCount--;
        STAKING_TOKEN.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount, accrued);
    }

    function claimRewards() external nonReentrant whenNotPaused {
        StakeInfo storage s = _stakes[msg.sender];
        if (s.amount == 0) revert NoStakeFound();
        _updatePool();
        uint256 accrued = _settlePending(msg.sender);
        if (accrued == 0) return;
        _transferRewards(msg.sender, accrued);
        emit RewardsClaimed(msg.sender, accrued);
    }

    function emergencyUnstake() external nonReentrant {
        if (!emergencyMode) revert EmergencyModeOff();
        StakeInfo storage s = _stakes[msg.sender];
        if (s.amount == 0) revert NoStakeFound();
        uint256 amount = s.amount;
        s.amount = 0; s.rewardDebt = 0;
        totalStaked -= amount;
        totalStakersCount--;
        STAKING_TOKEN.safeTransfer(msg.sender, amount);
        emit EmergencyUnstake(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  SWAPPING — Phase 1
    // ─────────────────────────────────────────────────────────────────────────

    function swapTokens(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external nonReentrant whenNotPaused notZeroAddress(tokenIn) notZeroAmount(amountIn)
        validDexAdapter returns (uint256 amountOut)
    {
        if (tokenOut == address(0)) revert ZeroAddress();
        if (tokenIn  == tokenOut)   revert SameAddress();
        uint256 fee   = (amountIn * swapFeeBps) / 10_000;
        uint256 netIn = amountIn - fee;
        IERC20(tokenIn).safeTransferFrom(msg.sender, treasury, fee);
        treasuryBalances[tokenIn] += fee;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), netIn);
        IERC20(tokenIn).forceApprove(dexAdapter, netIn);
        amountOut = IDEXAdapter(dexAdapter).swap(tokenIn, tokenOut, netIn, minOut, msg.sender);
        if (amountOut < minOut) revert SlippageExceeded(amountOut, minOut);
        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  LENDING — Phase 2 (gated)
    // ─────────────────────────────────────────────────────────────────────────

    function depositToLending(address token, uint256 amount)
        external nonReentrant whenNotPaused onlyPhase2
        notZeroAddress(token) notZeroAmount(amount) validLendingAdapter
    {
        if (userPositionCount[msg.sender] >= MAX_POSITIONS_PER_USER)
            revert MaxPositionsReached(MAX_POSITIONS_PER_USER);
        uint256 fee    = (amount * depositFeeBps) / 10_000;
        uint256 netAmt = amount - fee;
        IERC20(token).safeTransferFrom(msg.sender, treasury, fee);
        treasuryBalances[token] += fee;
        IERC20(token).safeTransferFrom(msg.sender, address(this), netAmt);
        IERC20(token).forceApprove(lendingAdapter, netAmt);
        ILendingAdapter(lendingAdapter).deposit(token, netAmt);
        LendingPosition storage pos = _positions[msg.sender][token];
        if (!pos.active) {
            pos.active = true;
            userPositionCount[msg.sender]++;
            _userActiveTokens[msg.sender].push(token);
        }
        pos.deposited += netAmt;
        if (!isLendingToken[token]) isLendingToken[token] = true;
        emit LendingDeposit(msg.sender, token, netAmt);
    }

    function withdrawFromLending(address token, uint256 amount)
        external nonReentrant whenNotPaused onlyPhase2
        notZeroAmount(amount) validLendingAdapter
    {
        LendingPosition storage pos = _positions[msg.sender][token];
        if (!pos.active)            revert NoActivePosition();
        if (pos.deposited < amount) revert InsufficientBalance(pos.deposited, amount);
        if (pos.borrowed > 0) {
            uint256 hf = _healthFactor(msg.sender, token);
            if (hf < minHealthFactor) revert HealthFactorTooLow(hf, minHealthFactor);
        }
        ILendingAdapter(lendingAdapter).withdraw(token, amount, msg.sender);
        pos.deposited -= amount;
        _closePositionIfEmpty(msg.sender, token);
        emit LendingWithdraw(msg.sender, token, amount);
    }

    function borrowFromLending(address token, uint256 amount)
        external nonReentrant whenNotPaused onlyPhase2
        notZeroAmount(amount) validLendingAdapter
    {
        LendingPosition storage pos = _positions[msg.sender][token];
        if (!pos.active) revert NoActivePosition();
        pos.borrowed += amount;
        uint256 hf    = _healthFactor(msg.sender, token);
        if (hf < minHealthFactor) {
            pos.borrowed -= amount;
            revert HealthFactorTooLow(hf, minHealthFactor);
        }
        ILendingAdapter(lendingAdapter).borrow(token, amount, msg.sender);
        emit LendingBorrow(msg.sender, token, amount);
    }

    function repayToLending(address token, uint256 amount)
        external nonReentrant whenNotPaused onlyPhase2
        notZeroAmount(amount) validLendingAdapter
    {
        LendingPosition storage pos = _positions[msg.sender][token];
        if (!pos.active)           revert NoActivePosition();
        if (pos.borrowed < amount) revert InsufficientBalance(pos.borrowed, amount);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).forceApprove(lendingAdapter, amount);
        ILendingAdapter(lendingAdapter).repay(token, amount);
        pos.borrowed -= amount;
        _closePositionIfEmpty(msg.sender, token);
        emit LendingRepay(msg.sender, token, amount);
    }

    function liquidate(address user, address token, uint256 repayAmount)
        external nonReentrant whenNotPaused onlyPhase2 onlyLiquidator
        notZeroAmount(repayAmount) validLendingAdapter
    {
        LendingPosition storage pos = _positions[user][token];
        if (!pos.active) revert NoActivePosition();
        uint256 hf = _healthFactor(user, token);
        if (hf >= minHealthFactor) revert LiquidationNotAllowed(hf);
        if (repayAmount > pos.borrowed) revert InsufficientBalance(pos.borrowed, repayAmount);
        IERC20(token).safeTransferFrom(msg.sender, address(this), repayAmount);
        IERC20(token).forceApprove(lendingAdapter, repayAmount);
        ILendingAdapter(lendingAdapter).repay(token, repayAmount);
        uint256 seized = (repayAmount * LIQUIDATION_BONUS) / PRECISION;
        if (seized > pos.deposited) seized = pos.deposited;
        pos.borrowed  -= repayAmount;
        pos.deposited -= seized;
        _closePositionIfEmpty(user, token);
        ILendingAdapter(lendingAdapter).withdraw(token, seized, msg.sender);
        emit Liquidated(user, msg.sender, token, repayAmount, seized);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  VIEW FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────────

    function getUserStakeInfo(address user) external view
        returns (uint256 staked, uint256 rewardDebt, uint256 totalClaimed, uint256 stakedAt)
    {
        StakeInfo storage s = _stakes[user];
        return (s.amount, s.rewardDebt, s.totalClaimed, s.stakedAt);
    }

    function pendingRewards(address user) external view returns (uint256) {
        StakeInfo storage s = _stakes[user];
        if (s.amount == 0) return 0;
        return (s.amount * _projectedAccRPS()) / PRECISION - s.rewardDebt;
    }

    function _projectedAccRPS() internal view returns (uint256) {
        if (totalStaked == 0) return accRewardPerShare;
        uint256 elapsed  = block.timestamp - lastRewardTime;
        if (elapsed == 0) return accRewardPerShare;
        uint256 pending  = (totalStaked * rewardRate * elapsed) / (PRECISION * SECONDS_PER_DAY);
        uint256 remaining = TOTAL_REWARD_CAP > totalRewardsDistributed
            ? TOTAL_REWARD_CAP - totalRewardsDistributed : 0;
        if (pending > remaining) pending = remaining;
        return accRewardPerShare + (pending * PRECISION / totalStaked);
    }

    function getLendingPosition(address user, address token) external view
        returns (uint256 deposited, uint256 borrowed, bool active)
    {
        LendingPosition storage pos = _positions[user][token];
        return (pos.deposited, pos.borrowed, pos.active);
    }

    function getHealthFactor(address user, address token) external view returns (uint256) {
        return _healthFactor(user, token);
    }

    function getUserActiveTokens(address user) external view returns (address[] memory) {
        return _userActiveTokens[user];
    }

    function getTimelockEntry(bytes4 selector) external view returns (uint256 unlocksAt, bool exists) {
        TimelockEntry storage e = _timelockQueue[selector];
        return (e.unlocksAt, e.exists);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  ADMIN — TIMELOCK
    // ─────────────────────────────────────────────────────────────────────────

    function queueTreasuryUpdate(address newTreasury) external onlyAdmin notZeroAddress(newTreasury) {
        bytes4 sel = this.executeTreasuryUpdate.selector;
        if (_timelockQueue[sel].exists) revert TimelockAlreadyQueued(sel);
        uint256 t = block.timestamp + TIMELOCK_DELAY;
        _timelockQueue[sel] = TimelockEntry({ unlocksAt: t, payload: abi.encode(newTreasury), exists: true });
        emit TimelockQueued(sel, t);
    }

    function executeTreasuryUpdate(address newTreasury) external onlyAdmin {
        bytes4 sel = this.executeTreasuryUpdate.selector;
        TimelockEntry storage e = _timelockQueue[sel];
        if (!e.exists || block.timestamp < e.unlocksAt) revert NoPendingChange();
        if (abi.decode(e.payload, (address)) != newTreasury) revert NoPendingChange();
        delete _timelockQueue[sel];
        address old = treasury; treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury); emit TimelockExecuted(sel);
    }

    function queueAdaptersUpdate(address dex, address lending) external onlyAdmin {
        bytes4 sel = this.executeAdaptersUpdate.selector;
        if (_timelockQueue[sel].exists) revert TimelockAlreadyQueued(sel);
        uint256 t = block.timestamp + TIMELOCK_DELAY;
        _timelockQueue[sel] = TimelockEntry({ unlocksAt: t, payload: abi.encode(dex, lending), exists: true });
        emit TimelockQueued(sel, t);
    }

    function executeAdaptersUpdate(address dex, address lending) external onlyAdmin {
        bytes4 sel = this.executeAdaptersUpdate.selector;
        TimelockEntry storage e = _timelockQueue[sel];
        if (!e.exists || block.timestamp < e.unlocksAt) revert NoPendingChange();
        (address qd, address ql) = abi.decode(e.payload, (address, address));
        if (qd != dex || ql != lending) revert NoPendingChange();
        delete _timelockQueue[sel];
        _applyAdapters(dex, lending); emit TimelockExecuted(sel);
    }

    function queueRewardRateUpdate(uint256 newRate) external onlyAdmin {
        if (newRate > MAX_REWARD_RATE) revert InvalidAmount(0, MAX_REWARD_RATE);
        bytes4 sel = this.executeRewardRateUpdate.selector;
        if (_timelockQueue[sel].exists) revert TimelockAlreadyQueued(sel);
        uint256 t = block.timestamp + TIMELOCK_DELAY;
        _timelockQueue[sel] = TimelockEntry({ unlocksAt: t, payload: abi.encode(newRate), exists: true });
        emit TimelockQueued(sel, t);
    }

    function executeRewardRateUpdate(uint256 newRate) external onlyAdmin {
        bytes4 sel = this.executeRewardRateUpdate.selector;
        TimelockEntry storage e = _timelockQueue[sel];
        if (!e.exists || block.timestamp < e.unlocksAt) revert NoPendingChange();
        if (abi.decode(e.payload, (uint256)) != newRate)   revert NoPendingChange();
        delete _timelockQueue[sel];
        _updatePool();
        uint256 old = rewardRate; rewardRate = newRate;
        emit RewardRateUpdated(old, newRate); emit TimelockExecuted(sel);
    }

    function cancelTimelock(bytes4 selector) external onlyAdmin {
        if (!_timelockQueue[selector].exists) revert NoPendingChange();
        delete _timelockQueue[selector];
        emit TimelockCancelled(selector);
    }

    function _applyAdapters(address dex, address lending) internal {
        if (dexAdapter     != address(0)) isAdapterWhitelisted[dexAdapter]     = false;
        if (lendingAdapter != address(0)) isAdapterWhitelisted[lendingAdapter] = false;
        dexAdapter = dex; lendingAdapter = lending;
        if (dex     != address(0)) isAdapterWhitelisted[dex]     = true;
        if (lending != address(0)) isAdapterWhitelisted[lending] = true;
        emit AdaptersSet(dex, lending);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  ADMIN — INSTANT
    // ─────────────────────────────────────────────────────────────────────────

    function updateFees(uint256 swapBps, uint256 depositBps) external onlyAdmin {
        if (swapBps    > MAX_FEE_BPS) revert InvalidFee(swapBps,    MAX_FEE_BPS);
        if (depositBps > MAX_FEE_BPS) revert InvalidFee(depositBps, MAX_FEE_BPS);
        swapFeeBps = swapBps; depositFeeBps = depositBps;
        emit FeesUpdated(swapBps, depositBps);
    }

    function updateMinStakeAmount(uint256 newMin) external onlyAdmin notZeroAmount(newMin) {
        minStakeAmount = newMin;
        emit MinStakeAmountUpdated(newMin);
    }

    function updateMinHealthFactor(uint256 newFactor) external onlyAdmin {
        if (newFactor < ABS_MIN_HEALTH_FACTOR) revert InvalidAmount(ABS_MIN_HEALTH_FACTOR, type(uint256).max);
        minHealthFactor = newFactor;
        emit MinHealthFactorUpdated(newFactor);
    }

    function setTokenOracle(address token, address oracle, uint256 maxAge)
        external onlyAdmin notZeroAddress(token) notZeroAddress(oracle)
    {
        tokenOracles[token] = OracleConfig({ oracle: oracle, maxAge: maxAge });
        emit OracleSet(token, oracle, maxAge);
    }

    function enablePhase2() external onlyAdmin {
        require(!phase2Enabled, "DeFiHub: already enabled");
        phase2Enabled = true;
        emit Phase2Enabled(msg.sender);
    }

    function rescueTokens(address token, uint256 amount) external onlyAdmin {
        if (token == address(STAKING_TOKEN) || token == address(REWARD_TOKEN) || isLendingToken[token])
            revert ProtectedToken(token);
        IERC20(token).safeTransfer(msg.sender, amount);
        emit TokensRescued(token, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  EMERGENCY / GUARDIAN
    // ─────────────────────────────────────────────────────────────────────────

    function toggleEmergencyMode() external onlyEmergency {
        emergencyMode = !emergencyMode;
        if (emergencyMode) _pause(); else _unpause();
        emit EmergencyModeToggled(emergencyMode);
    }

    function guardianPause() external onlyGuardian {
        _pause(); emit ProtocolPaused(msg.sender);
    }

    function guardianUnpause() external onlyGuardian {
        require(!emergencyMode, "DeFiHub: emergency mode active");
        _unpause(); emit ProtocolUnpaused(msg.sender);
    }
}