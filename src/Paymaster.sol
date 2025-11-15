// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Paymaster (Professional Version - Non-upgradeable)
/// @author Fatima / FlashVerse
/// @notice Advanced Gas Sponsorship contract for ETH & ERC20, with roles, cooldown, atomic batches, and fee tracking.
/// @dev Uses OpenZeppelin standard (non-upgradeable): AccessControl, ReentrancyGuard, SafeERC20.
/// @custom:note Batch operations are atomic for full consistency.

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol"; // تم التعديل إلى utils
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

error ZeroAddress();
error InvalidAmount();
error Unauthorized();
error InsufficientBalance(uint256 available, uint256 requested);
error TransferFailed();
error LengthMismatch();
error BatchTooLarge(uint256 maxAllowed);
error CooldownActive(uint256 remainingTime);

contract Paymaster is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------------
    // Constants
    // -----------------------------
    uint256 public constant MAX_BATCH_SIZE = 100;
    uint256 public constant FEE_PERCENT = 1; // 1%
    uint256 public constant COOLDOWN_PERIOD = 1 hours;

    // -----------------------------
    // Roles
    // -----------------------------
    bytes32 public constant SPONSOR_ROLE = keccak256("SPONSOR_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // -----------------------------
    // Storage
    // -----------------------------
    uint256 public totalSponsoredEth;
    mapping(address => uint256) public totalSponsoredERC20;
    uint256 public totalFeesEth;
    mapping(address => uint256) public totalFeesERC20;
    mapping(address => uint256) public lastSponsorshipTime;

    // -----------------------------
    // Events
    // -----------------------------
    event EthSponsored(address indexed sponsor, address indexed user, uint256 netAmount, uint256 fee);
    event ERC20Sponsored(address indexed sponsor, address indexed user, address indexed token, uint256 netAmount, uint256 fee);
    event BatchEthSponsored(address indexed sponsor, uint256 count, uint256 totalSent, uint256 totalFees);
    event BatchERC20Sponsored(address indexed sponsor, address indexed token, uint256 count, uint256 totalSent, uint256 totalFees);
    event EthDeposited(address indexed from, uint256 amount);
    event ERC20Deposited(address indexed from, address indexed token, uint256 amount);
    event FeesWithdrawnEth(address indexed to, uint256 amount);
    event FeesWithdrawnERC20(address indexed token, address indexed to, uint256 amount);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    // -----------------------------
    // Constructor
    // -----------------------------
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(SPONSOR_ROLE, msg.sender);
    }

    // -----------------------------
    // Internal Helper Functions for Modifiers
    // -----------------------------
    function _onlySponsor() internal view {
        if (!hasRole(SPONSOR_ROLE, msg.sender)) revert Unauthorized();
    }

    function _cooldownBefore() internal view {
        uint256 lastTime = lastSponsorshipTime[msg.sender];
        uint256 cooldownEndsAt = lastTime + COOLDOWN_PERIOD;
        if (block.timestamp < cooldownEndsAt) {
            revert CooldownActive(cooldownEndsAt - block.timestamp);
        }
    }

    function _cooldownAfter() internal {
        lastSponsorshipTime[msg.sender] = block.timestamp;
    }

    // -----------------------------
    // Modifiers
    // -----------------------------
    modifier onlySponsor() {
        _onlySponsor();
        _;
    }

    modifier cooldown() {
        _cooldownBefore();
        _;
        _cooldownAfter();
    }

    // -----------------------------
    // Helpers
    // -----------------------------
    function _feeOf(uint256 amount) internal pure returns (uint256) {
        return (amount * FEE_PERCENT) / 100;
    }

    // -----------------------------
    // Deposits
    // -----------------------------
    function depositEth() external payable {
        if (msg.value == 0) revert InvalidAmount();
        emit EthDeposited(msg.sender, msg.value);
    }

    function depositERC20(address token, uint256 amount) external {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit ERC20Deposited(msg.sender, token, amount);
    }

    // -----------------------------
    // Sponsorship - ETH
    // -----------------------------
    function sponsorEth(address user, uint256 amount)
        external
        onlySponsor
        nonReentrant
        cooldown
    {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        uint256 fee = _feeOf(amount);
        uint256 net = amount - fee;
        uint256 balance = address(this).balance;
        if (amount > balance) revert InsufficientBalance(balance, amount);

        (bool success, ) = payable(user).call{value: net}("");
        if (!success) revert TransferFailed();

        totalSponsoredEth += net;
        totalFeesEth += fee;

        emit EthSponsored(msg.sender, user, net, fee);
    }

    function batchSponsorEth(address[] calldata users, uint256[] calldata amounts)
        external
        onlySponsor
        nonReentrant
        cooldown
    {
        uint256 len = users.length;
        if (len != amounts.length) revert LengthMismatch();
        if (len == 0 || len > MAX_BATCH_SIZE) revert BatchTooLarge(MAX_BATCH_SIZE);

        uint256 totalRequired;
        for (uint256 i = 0; i < len; ++i) {
            if (users[i] == address(0)) revert ZeroAddress();
            if (amounts[i] == 0) revert InvalidAmount();
            totalRequired += amounts[i];
        }

        uint256 balance = address(this).balance;
        if (totalRequired > balance) revert InsufficientBalance(balance, totalRequired);

        uint256 totalSent;
        uint256 totalFees;

        for (uint256 i = 0; i < len; ++i) {
            uint256 fee = _feeOf(amounts[i]);
            uint256 net = amounts[i] - fee;

            (bool success, ) = payable(users[i]).call{value: net}("");
            if (!success) revert TransferFailed();

            totalSent += net;
            totalFees += fee;

            emit EthSponsored(msg.sender, users[i], net, fee);
        }

        totalSponsoredEth += totalSent;
        totalFeesEth += totalFees;

        emit BatchEthSponsored(msg.sender, len, totalSent, totalFees);
    }

    // -----------------------------
    // Sponsorship - ERC20
    // -----------------------------
    function sponsorERC20(address token, address user, uint256 amount)
        external
        onlySponsor
        nonReentrant
        cooldown
    {
        if (token == address(0) || user == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        uint256 fee = _feeOf(amount);
        uint256 net = amount - fee;
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance(balance, amount);

        IERC20(token).safeTransfer(user, net);

        totalSponsoredERC20[token] += net;
        totalFeesERC20[token] += fee;

        emit ERC20Sponsored(msg.sender, user, token, net, fee);
    }

    function batchSponsorERC20(address token, address[] calldata users, uint256[] calldata amounts)
        external
        onlySponsor
        nonReentrant
        cooldown
    {
        if (token == address(0)) revert ZeroAddress();
        uint256 len = users.length;
        if (len != amounts.length) revert LengthMismatch();
        if (len == 0 || len > MAX_BATCH_SIZE) revert BatchTooLarge(MAX_BATCH_SIZE);

        uint256 totalRequired;
        for (uint256 i = 0; i < len; ++i) {
            if (users[i] == address(0)) revert ZeroAddress();
            if (amounts[i] == 0) revert InvalidAmount();
            totalRequired += amounts[i];
        }

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (totalRequired > balance) revert InsufficientBalance(balance, totalRequired);

        uint256 totalSent;
        uint256 totalFees;

        for (uint256 i = 0; i < len; ++i) {
            uint256 fee = _feeOf(amounts[i]);
            uint256 net = amounts[i] - fee;

            IERC20(token).safeTransfer(users[i], net);

            totalSent += net;
            totalFees += fee;

            emit ERC20Sponsored(msg.sender, users[i], token, net, fee);
        }

        totalSponsoredERC20[token] += totalSent;
        totalFeesERC20[token] += totalFees;

        emit BatchERC20Sponsored(msg.sender, token, len, totalSent, totalFees);
    }

    // -----------------------------
    // Fees withdrawal (admin)
    // -----------------------------
    function withdrawFeesEth(address payable to, uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (amount > totalFeesEth) revert InsufficientBalance(totalFeesEth, amount);
        uint256 contractBalance = address(this).balance;
        if (amount > contractBalance) revert InsufficientBalance(contractBalance, amount);

        totalFeesEth -= amount;
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit FeesWithdrawnEth(to, amount);
    }

    function withdrawFeesERC20(address token, address to, uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
    {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (amount > totalFeesERC20[token]) revert InsufficientBalance(totalFeesERC20[token], amount);
        uint256 contractBalance = IERC20(token).balanceOf(address(this));
        if (amount > contractBalance) revert InsufficientBalance(contractBalance, amount);

        totalFeesERC20[token] -= amount;
        IERC20(token).safeTransfer(to, amount);

        emit FeesWithdrawnERC20(token, to, amount);
    }

    // -----------------------------
    // Emergency (admin)
    // -----------------------------
    function emergencyWithdraw(address token, address to, uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        if (token == address(0)) {
            uint256 balance = address(this).balance;
            if (amount > balance) revert InsufficientBalance(balance, amount);
            (bool success, ) = payable(to).call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (amount > balance) revert InsufficientBalance(balance, amount);
            IERC20(token).safeTransfer(to, amount);
        }

        emit EmergencyWithdraw(token, to, amount);
    }

    // -----------------------------
    // Views
    // -----------------------------
    function balanceEth() external view returns (uint256) {
        return address(this).balance;
    }

    function balanceERC20(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    // -----------------------------
    // Receive / Fallback
    // -----------------------------
    receive() external payable {
        emit EthDeposited(msg.sender, msg.value);
    }

    fallback() external payable {
        if (msg.value > 0) {
            emit EthDeposited(msg.sender, msg.value);
        }
    }
}