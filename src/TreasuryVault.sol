// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TreasuryVault
/// @author Fatima / FlashVerse (Improved Version)
/// @notice A simplified vault for managing ETH and ERC20 assets with basic owner-based access, simple fee logic, and manual reentrancy/pause functions.
/// @dev Uses OpenZeppelin for basic utilities (IERC20, Address) but avoids security contracts. Includes improvements like ownership transfer, configurable fees, and batch limits.
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

error ZeroAddress();
error InsufficientBalance(uint256 available, uint256 requested);
error TimelockActive(uint256 unlockTime);
error LengthMismatch();
error InvalidAmount();
error TransferFailed();
error Unauthorized(); 
error ZeroFees();
error Paused(); 
error NotPaused();
error ReentrancyLock();
error FeeTooHigh();
error BatchTooLarge();

contract TreasuryVault {

    // --- State Variables ---
    address public owner;
    address public pendingOwner; 
    bool private _paused;
    bool private _reentrancyLock;

    uint256 public withdrawalFeeBasisPoints; 
    uint256 public constant MAX_FEE_BASIS_POINTS = 1000; 
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_BATCH_SIZE = 100; 

    uint256 public timelockEnd;
    mapping(address => uint256) public totalFeesCollected;

    // --- Modifier Internal Logic (for Gas Efficiency) ---
    function _onlyOwner() internal view {
        if (msg.sender != owner) revert Unauthorized();
    }

    function _whenNotPaused() internal view {
        if (_paused) revert Paused();
    }
    
    function _notLocked() internal view {
        if (block.timestamp < timelockEnd) revert TimelockActive(timelockEnd);
    }
    
    function _nonReentrantBefore() internal {
        if (_reentrancyLock) revert ReentrancyLock();
        _reentrancyLock = true;
    }

    function _nonReentrantAfter() internal {
        _reentrancyLock = false;
    }

    // --- Modifiers ---
    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    modifier whenNotPaused() {
        _whenNotPaused();
        _;
    }

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    modifier notLocked() {
        _notLocked();
        _;
    }

    // --- Events ---
    event ETHDeposited(address indexed sender, uint256 amount);
    event ETHWithdrawn(address indexed to, uint256 amount, uint256 fee);
    event ERC20Deposited(address indexed token, address indexed sender, uint256 amount);
    event ERC20Withdrawn(address indexed token, address indexed to, uint256 amount, uint256 fee);
    event BatchWithdrawal(address indexed to, address token, uint256 amount, uint256 fee, uint256 timestamp);
    event TimelockSet(uint256 unlockTime);
    event PausedStatus(address account); 
    event Unpaused(address account);
    event EmergencyWithdraw(address token, address to, uint256 amount);
    event FeesWithdrawn(address indexed token, address indexed to, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferInitiated(address indexed currentOwner, address indexed pendingOwner);
    event FeeUpdated(uint256 oldFee, uint256 newFee);

    constructor(uint256 initialFeeBasisPoints) {
        if (initialFeeBasisPoints > MAX_FEE_BASIS_POINTS) revert FeeTooHigh();
        owner = msg.sender;
        withdrawalFeeBasisPoints = initialFeeBasisPoints;
        _paused = false;
        _reentrancyLock = false;
    }

    // --- Ownership Functions ---
    /// @notice Initiates ownership transfer (two-step process).
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferInitiated(owner, newOwner);
    }

    /// @notice Accepts ownership transfer.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        address oldOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }

    // --- Fee Management ---
    /// @notice Updates the withdrawal fee (owner only).
    function setWithdrawalFee(uint256 newFeeBasisPoints) external onlyOwner {
        if (newFeeBasisPoints > MAX_FEE_BASIS_POINTS) revert FeeTooHigh();
        uint256 oldFee = withdrawalFeeBasisPoints;
        withdrawalFeeBasisPoints = newFeeBasisPoints;
        emit FeeUpdated(oldFee, newFeeBasisPoints);
    }

    // --- Core Owner/Pause Functions ---
    function setTimelock(uint256 delaySeconds) external onlyOwner {
        if (delaySeconds == 0) revert InvalidAmount();
        timelockEnd = block.timestamp + delaySeconds;
        emit TimelockSet(timelockEnd);
    }

    function pause() external onlyOwner {
        if (_paused) revert Paused(); 
        _paused = true;
        emit PausedStatus(msg.sender); 
    }

    function unpause() external onlyOwner {
        if (!_paused) revert NotPaused(); 
        _paused = false;
        emit Unpaused(msg.sender);
    }

    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        if (token == address(0)) {
            uint256 balance = address(this).balance;
            if (amount > balance) revert InsufficientBalance(balance, amount);
            
            (bool success,) = payable(to).call{value: amount}("");
            if (!success) revert TransferFailed(); 
            
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (amount > balance) revert InsufficientBalance(balance, amount);
            bool success = IERC20(token).transfer(to, amount);
            if (!success) revert TransferFailed();
        }
        emit EmergencyWithdraw(token, to, amount);
    }

    function withdrawFees(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = totalFeesCollected[token];
        if (amount == 0) revert ZeroFees();
        totalFeesCollected[token] = 0;

        if (token == address(0)) {
            (bool success,) = payable(to).call{value: amount}("");
            if (!success) revert TransferFailed(); 
        } else {
            bool success = IERC20(token).transfer(to, amount);
            if (!success) revert TransferFailed();
        }
        emit FeesWithdrawn(token, to, amount);
    }

    // --- Deposit Functions ---
    receive() external payable whenNotPaused {
        emit ETHDeposited(msg.sender, msg.value);
    }

    function depositERC20(address token, uint256 amount) external whenNotPaused {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
        emit ERC20Deposited(token, msg.sender, amount);
    }

    // --- Withdrawal Functions ---
    // 🚀 FIX: Function name changed to mixedCase
    function withdrawEth(address to, uint256 amount) external onlyOwner notLocked whenNotPaused nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        uint256 fee;
        uint256 netAmount;
        unchecked {
            fee = (amount * withdrawalFeeBasisPoints) / BASIS_POINTS;
            netAmount = amount - fee;
        }
        uint256 balance = address(this).balance;
        if (amount > balance) revert InsufficientBalance(balance, amount);

        totalFeesCollected[address(0)] += fee;
        
        (bool success,) = payable(to).call{value: netAmount}("");
        if (!success) revert TransferFailed(); 
        
        emit ETHWithdrawn(to, netAmount, fee);
    }

    // 🚀 FIX: Function name changed to mixedCase
    function batchWithdrawEth(address[] calldata to, uint256[] calldata amounts) external onlyOwner notLocked whenNotPaused nonReentrant {
        if (to.length == 0 || to.length != amounts.length || to.length > MAX_BATCH_SIZE) revert BatchTooLarge();

        uint256 totalRequested = 0;
        for (uint256 i = 0; i < to.length; i++) {
            if (to[i] == address(0)) revert ZeroAddress();
            if (amounts[i] == 0) revert InvalidAmount();
            totalRequested += amounts[i];
        }

        uint256 totalFees;
        unchecked {
            totalFees = (totalRequested * withdrawalFeeBasisPoints) / BASIS_POINTS;
        }
        uint256 totalBalance = address(this).balance;
        if (totalRequested > totalBalance) revert InsufficientBalance(totalBalance, totalRequested);

        totalFeesCollected[address(0)] += totalFees;

        for (uint256 i = 0; i < to.length; i++) {
            uint256 fee;
            uint256 netAmount;
            unchecked {
                fee = (amounts[i] * withdrawalFeeBasisPoints) / BASIS_POINTS;
                netAmount = amounts[i] - fee;
            }
            (bool success,) = payable(to[i]).call{value: netAmount}("");
            if (!success) revert TransferFailed(); 
            
            emit BatchWithdrawal(to[i], address(0), netAmount, fee, block.timestamp);
        }
    }

    function withdrawERC20(address token, address to, uint256 amount) external onlyOwner notLocked whenNotPaused nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        uint256 fee;
        uint256 netAmount;
        unchecked {
            fee = (amount * withdrawalFeeBasisPoints) / BASIS_POINTS;
            netAmount = amount - fee;
        }
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance(balance, amount);

        totalFeesCollected[token] += fee;
        bool success = IERC20(token).transfer(to, netAmount);
        if (!success) revert TransferFailed();
        emit ERC20Withdrawn(token, to, netAmount, fee);
    }

    function batchWithdrawERC20(address token, address[] calldata to, uint256[] calldata amounts) external onlyOwner notLocked whenNotPaused nonReentrant {
        if (to.length == 0 || to.length != amounts.length || to.length > MAX_BATCH_SIZE) revert BatchTooLarge();

        uint256 totalRequested = 0;
        for (uint256 i = 0; i < to.length; i++) {
            if (to[i] == address(0)) revert ZeroAddress();
            if (amounts[i] == 0) revert InvalidAmount();
            totalRequested += amounts[i];
        }

        uint256 totalFees;
        unchecked {
            totalFees = (totalRequested * withdrawalFeeBasisPoints) / BASIS_POINTS;
        }
        uint256 totalBalance = IERC20(token).balanceOf(address(this));
        if (totalRequested > totalBalance) revert InsufficientBalance(totalBalance, totalRequested);

        totalFeesCollected[token] += totalFees;

        for (uint256 i = 0; i < to.length; i++) {
            uint256 fee;
            uint256 netAmount;
            unchecked {
                fee = (amounts[i] * withdrawalFeeBasisPoints) / BASIS_POINTS;
                netAmount = amounts[i] - fee;
            }
            bool success = IERC20(token).transfer(to[i], netAmount);
            if (!success) revert TransferFailed();
            emit BatchWithdrawal(to[i], token, netAmount, fee, block.timestamp);
        }
    }

    // --- View Functions ---
    // 🚀 FIX: Function name changed to mixedCase
    function balanceEth() external view returns (uint256) {
        return address(this).balance;
    }

    function balanceERC20(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function getTotalFeesCollected(address token) external view returns (uint256) {
        return totalFeesCollected[token];
    }

    function calculateNetAmount(uint256 amount) external view returns (uint256 netAmount, uint256 fee) {
        unchecked {
            fee = (amount * withdrawalFeeBasisPoints) / BASIS_POINTS;
            netAmount = amount - fee;
        }
    }

    function isPaused() external view returns (bool) {
        return _paused;
    }

    function isLocked() external view returns (bool) {
        return block.timestamp < timelockEnd;
    }

    function getTimelockEnd() external view returns (uint256) {
        return timelockEnd;
    }
}