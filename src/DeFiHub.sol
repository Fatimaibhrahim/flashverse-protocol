// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DeFiHub - Unified DeFi Gateway for FlashVerse Ecosystem
/// @author Fatima / FlashVerse
/// @notice Provides modular integration for Swaps, Staking, and Lending.
/// @dev Fully modular, upgrade-safe design with external DeFi adapters.
///      Manual safe ERC20 wrappers implemented to bypass compiler link error (Error 9582).

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

error ZeroAddress();
error Unauthorized();
error InvalidAmount();
error OperationFailed();
error AlreadyStaked();
error NoStakeFound();
error InsufficientBalance(uint256 balance, uint256 required);

interface IDEXAdapter {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to) external returns (uint256);
}

interface ILendingAdapter {
    function deposit(address token, uint256 amount) external;
    function withdraw(address token, uint256 amount, address to) external;
    function borrow(address token, uint256 amount, address to) external;
    function repay(address token, uint256 amount) external;
}

contract DeFiHub is AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    struct StakeInfo {
        uint256 amount;
        uint256 since;
        uint256 rewardsClaimed; // Total rewards ever claimed/distributed
    }

    uint256 public rewardRate;
    address public rewardToken;
    address public stakingToken;
    mapping(address => StakeInfo) public stakes;

    address public dexAdapter;
    address public lendingAdapter;

    event AdapterUpdated(string adapterType, address adapter);
    event Swapped(address indexed user, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    event Deposited(address indexed user, address token, uint256 amount);
    event Withdrawn(address indexed user, address token, uint256 amount);
    event Borrowed(address indexed user, address token, uint256 amount);
    event Repaid(address indexed user, address token, uint256 amount);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount, uint256 rewards);
    event RewardTokenUpdated(address token);
    event RewardRateUpdated(uint256 newRate);
    event RewardsClaimed(address indexed user, uint256 rewards);
    event StakingTokenUpdated(address token);

    constructor(address _stakingToken, address _rewardToken, uint256 _rewardRate) {
        if (_stakingToken == address(0) || _rewardToken == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        rewardRate = _rewardRate;
    }

    /* ========== INTERNAL TOKEN SAFETY WRAPPERS ========== */

    function _safeTransferFrom(IERC20 token, address from, address to, uint256 value) private {
        (bool success, bytes memory data) = address(token).call(abi.encodeWithSelector(
            IERC20.transferFrom.selector,
            from,
            to,
            value
        ));
        if (!success) revert OperationFailed();
        if (data.length > 0 && abi.decode(data, (bool)) == false) revert OperationFailed();
    }

    function _safeTransfer(IERC20 token, address to, uint256 value) private {
        (bool success, bytes memory data) = address(token).call(abi.encodeWithSelector(
            IERC20.transfer.selector,
            to,
            value
        ));
        if (!success) revert OperationFailed();
        if (data.length > 0 && abi.decode(data, (bool)) == false) revert OperationFailed();
    }

    function _safeApprove(IERC20 token, address spender, uint256 value) private {
        (bool success, bytes memory data) = address(token).call(abi.encodeWithSelector(
            IERC20.approve.selector,
            spender,
            value
        ));
        if (!success) revert OperationFailed();
        if (data.length > 0 && abi.decode(data, (bool)) == false) revert OperationFailed();
    }

    /* ========== ADMIN CONFIG ========== */

    function setAdapters(address _dex, address _lending) external onlyRole(ADMIN_ROLE) {
        if (_dex == address(0) || _lending == address(0)) revert ZeroAddress();
        dexAdapter = _dex;
        lendingAdapter = _lending;
        emit AdapterUpdated("DEX", _dex);
        emit AdapterUpdated("LENDING", _lending);
    }

    function setRewardToken(address token) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        rewardToken = token;
        emit RewardTokenUpdated(token);
    }

    function setStakingToken(address token) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        stakingToken = token;
        emit StakingTokenUpdated(token);
    }

    function setRewardRate(uint256 newRate) external onlyRole(ADMIN_ROLE) {
        rewardRate = newRate;
        emit RewardRateUpdated(newRate);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /* ========== DEFI OPERATIONS (UNCHANGED) ========== */

    function swapTokens(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external nonReentrant whenNotPaused returns (uint256 amountOut)
    {
        if (tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();
        _safeTransferFrom(IERC20(tokenIn), msg.sender, address(this), amountIn);
        _safeApprove(IERC20(tokenIn), dexAdapter, amountIn);

        amountOut = IDEXAdapter(dexAdapter).swap(tokenIn, tokenOut, amountIn, minOut, msg.sender);
        if (amountOut < minOut) revert OperationFailed();

        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    function depositToLending(address token, uint256 amount)
        external nonReentrant whenNotPaused
    {
        _safeTransferFrom(IERC20(token), msg.sender, address(this), amount);
        _safeApprove(IERC20(token), lendingAdapter, amount);
        
        ILendingAdapter(lendingAdapter).deposit(token, amount);
        emit Deposited(msg.sender, token, amount);
    }

    function withdrawFromLending(address token, uint256 amount)
        external nonReentrant whenNotPaused
    {
        ILendingAdapter(lendingAdapter).withdraw(token, amount, msg.sender);
        emit Withdrawn(msg.sender, token, amount);
    }

    function borrowFromLending(address token, uint256 amount)
        external nonReentrant whenNotPaused
    {
        ILendingAdapter(lendingAdapter).borrow(token, amount, msg.sender);
        emit Borrowed(msg.sender, token, amount);
    }

    function repayToLending(address token, uint256 amount)
        external nonReentrant whenNotPaused
    {
        _safeTransferFrom(IERC20(token), msg.sender, address(this), amount);
        _safeApprove(IERC20(token), lendingAdapter, amount);
        
        ILendingAdapter(lendingAdapter).repay(token, amount);
        emit Repaid(msg.sender, token, amount);
    }

    /* ========== STAKING MODULE (FIXED) ========== */

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        StakeInfo storage s = stakes[msg.sender];
        
        // World-Class Fix: Claim pending rewards first to reset 'since' time.
        if (s.amount > 0) {
            _claimPendingRewards(msg.sender);
        }

        // If this is the first stake, set the starting time
        if (s.amount == 0) {
            s.since = block.timestamp;
        }
        
        s.amount += amount;
        
        _safeTransferFrom(IERC20(stakingToken), msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function unstake() external nonReentrant whenNotPaused {
        StakeInfo storage s = stakes[msg.sender];
        if (s.amount == 0) revert NoStakeFound();

        // 1. Claim and transfer all pending rewards (state is updated inside)
        uint256 rewardsToTransfer = _claimPendingRewards(msg.sender); 

        uint256 stakedAmount = s.amount;
        
        // 2. Transfer the Staking Token back
        _safeTransfer(IERC20(stakingToken), msg.sender, stakedAmount);
        
        // 3. Emit and clear state
        emit Unstaked(msg.sender, stakedAmount, rewardsToTransfer); 
        delete stakes[msg.sender];
    }

    function claimRewards() external nonReentrant whenNotPaused {
        uint256 rewards = _claimPendingRewards(msg.sender);
        if (rewards == 0) revert NoStakeFound();
        // Event is emitted inside _claimPendingRewards
    }

    /// @notice Helper function to calculate, transfer, and update state for pending rewards
    /// @param user The address of the staker
    /// @return rewards The amount of reward tokens transferred
    function _claimPendingRewards(address user) internal returns (uint256 rewards) {
        StakeInfo storage s = stakes[user];
        if (s.amount == 0) return 0;
        
        // Calculate the rewards accrued since the last update
        uint256 timeElapsed = block.timestamp - s.since;
        
        // Calculate total rewards based on time elapsed
        rewards = (s.amount * rewardRate * timeElapsed) / 1e18;
        
        if (rewards > 0) {
            // Update the state before transferring
            s.rewardsClaimed += rewards;
            s.since = block.timestamp; // Reset timer for the next claim/unstake/stake
            
            // Transfer the Reward Token
            _safeTransfer(IERC20(rewardToken), user, rewards);
            emit RewardsClaimed(user, rewards);
        }
        return rewards;
    }

    function calculateRewards(address user) public view returns (uint256) {
        StakeInfo memory s = stakes[user];
        if (s.amount == 0) return 0;
        uint256 timeElapsed = block.timestamp - s.since;
        // Total accrued rewards based on elapsed time
        return (s.amount * rewardRate * timeElapsed) / 1e18;
    }

    /* ========== UTILITIES (FIXED) ========== */

    /// @notice Returns the full stake info, including current pending rewards.
    function getStake(address user) external view returns (StakeInfo memory) {
        StakeInfo memory s = stakes[user];
        // Calculate pending rewards for an accurate view
        uint256 pendingRewards = calculateRewards(user);
        
        // Add pending rewards to the total claimed amount for the view function
        s.rewardsClaimed += pendingRewards; 
        return s;
    }

    receive() external payable {}
}