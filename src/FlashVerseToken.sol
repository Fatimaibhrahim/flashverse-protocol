// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  FlashVerseToken ($FLASH)
/// @notice Production-grade ERC20 token for the FlashVerse ecosystem.
/// @author FlashVerse Core Team
/// @dev    Feature stack:
///           • ERC20Votes      — on-chain governance (Compound/Uniswap standard)
///           • ERC20Permit     — gasless approvals (EIP-2612)
///           • ERC20Burnable   — deflationary burn mechanism
///           • ERC3156         — flash loans (Aave standard)
///           • Anti-whale      — max tx protection with exemption whitelist
///           • Vesting         — built-in linear vesting with cliff
///           • ReentrancyGuard — flash loan protection
///           • Ownable2Step    — safe ownership transfer (no accidental loss)
///           • RecoverTokens   — rescue stuck ERC20/ETH

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Nonces.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  CUSTOM ERRORS — gas-efficient reverts
// ─────────────────────────────────────────────────────────────────────────────

error ZeroAddress();
error ZeroAmount();
error ExceedsMaxTx(uint256 amount, uint256 max);
error CliffExceedsDuration();
error InsufficientBalance(uint256 available, uint256 required);
error NoVesting();
error NothingToClaim();
error UnsupportedToken(address token);
error InsufficientPool(uint256 available, uint256 requested);
error CallbackFailed();
error CannotRecoverSelf();
error ETHTransferFailed();
error StartInPast();
error FlashLoanFeeTooHigh(uint256 provided, uint256 max);
error MaxTxTooLow(uint256 provided, uint256 min);

// ─────────────────────────────────────────────────────────────────────────────
//  FLASHVERSE TOKEN
// ─────────────────────────────────────────────────────────────────────────────

contract FlashVerseToken is
    ERC20,
    ERC20Burnable,
    ERC20Permit,
    ERC20Votes,
    ReentrancyGuard,
    Ownable2Step,
    IERC3156FlashLender
{
    using SafeERC20 for IERC20;

    // ── Constants ─────────────────────────────────────────────────────────────
    uint256 public constant BASIS_POINTS        = 10_000;
    uint256 public constant MAX_FLASH_FEE_BP    = 100;   // 1% max flash loan fee
    uint256 public constant MIN_MAX_TX_BP       = 1;     // 0.01% min maxTx (safety floor)
    bytes32 public constant CALLBACK_SUCCESS    = keccak256("ERC3156FlashBorrower.onFlashLoan");

    // ── Anti-whale ────────────────────────────────────────────────────────────
    uint256 public maxTxAmount;
    mapping(address => bool) public isExempt;   // exempt from anti-whale

    // ── Vesting ───────────────────────────────────────────────────────────────
    struct Allocation {
        uint256 total;
        uint256 claimed;
        uint256 start;
        uint256 cliff;
        uint256 duration;
    }
    mapping(address => Allocation) public vestings;

    // ── Flash Loan ────────────────────────────────────────────────────────────
    uint256 public flashLoanFeeBP = 5; // 0.05% default

    // ── Events ────────────────────────────────────────────────────────────────
    event TokensRecovered(address indexed token, uint256 amount, address indexed to);
    event MaxTxAmountChanged(uint256 oldAmount, uint256 newAmount);
    event ExemptStatusChanged(address indexed account, bool exempt);
    event VestingSet(address indexed beneficiary, uint256 total, uint256 start, uint256 cliff, uint256 duration);
    event VestingClaimed(address indexed beneficiary, uint256 amount);
    event VestingRemoved(address indexed beneficiary, uint256 returnedAmount);
    event FlashLoanExecuted(address indexed borrower, uint256 amount, uint256 fee);
    event FlashLoanFeeChanged(uint256 oldFee, uint256 newFee);

    // ─────────────────────────────────────────────────────────────────────────
    //  CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────────

    /// @param name_                    Token name ("Flash Token")
    /// @param symbol_                  Token symbol ("FLASH")
    /// @param initialSupply_           Total supply in wei (18,000,000,000 * 1e18)
    /// @param maxTxPercentBasisPoints  Anti-whale max tx as BPS of total supply (e.g. 100 = 1%)
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply_,
        uint256 maxTxPercentBasisPoints
    )
        ERC20(name_, symbol_)
        ERC20Permit(name_)
        Ownable(msg.sender)
    {
        if (initialSupply_ == 0) revert ZeroAmount();
        if (maxTxPercentBasisPoints < MIN_MAX_TX_BP)
            revert MaxTxTooLow(maxTxPercentBasisPoints, MIN_MAX_TX_BP);

        _mint(msg.sender, initialSupply_);
        maxTxAmount = (initialSupply_ * maxTxPercentBasisPoints) / BASIS_POINTS;

        // Exempt deployer and contract itself by default
        isExempt[msg.sender]    = true;
        isExempt[address(this)] = true;

        emit ExemptStatusChanged(msg.sender,    true);
        emit ExemptStatusChanged(address(this), true);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  INTERNAL OVERRIDES
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Anti-whale check on every transfer, with exemption whitelist.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        // Anti-whale: skip for mints, burns, contract transfers, and exempt addresses
        if (
            from != address(0) &&
            to   != address(0) &&
            from != address(this) &&
            !isExempt[from] &&
            !isExempt[to]
        ) {
            if (value > maxTxAmount) revert ExceedsMaxTx(value, maxTxAmount);
        }

        super._update(from, to, value);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  ANTI-WHALE
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Update the max transaction amount
    /// @param newAmount New max tx in token units (wei)
    function setMaxTxAmount(uint256 newAmount) external onlyOwner {
        uint256 floor = (totalSupply() * MIN_MAX_TX_BP) / BASIS_POINTS;
        if (newAmount < floor) revert MaxTxTooLow(newAmount, floor);
        uint256 old = maxTxAmount;
        maxTxAmount = newAmount;
        emit MaxTxAmountChanged(old, newAmount);
    }

    /// @notice Set exemption status for an address (e.g. GenesisWallet, DEX, bridges)
    /// @param account Address to exempt or un-exempt
    /// @param exempt  True to exempt, false to remove exemption
    function setExempt(address account, bool exempt) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        isExempt[account] = exempt;
        emit ExemptStatusChanged(account, exempt);
    }

    /// @notice Batch set exemptions (e.g. exempt all contracts at once)
    function batchSetExempt(address[] calldata accounts, bool exempt) external onlyOwner {
        uint256 len = accounts.length;
        for (uint256 i = 0; i < len; i++) {
            if (accounts[i] == address(0)) revert ZeroAddress();
            isExempt[accounts[i]] = exempt;
            emit ExemptStatusChanged(accounts[i], exempt);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  VESTING
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Create or update a vesting schedule for a beneficiary
    /// @dev    Transfers tokens from owner to this contract for safekeeping
    function setVesting(
        address beneficiary,
        uint256 totalAmount,
        uint256 start,
        uint256 cliff,
        uint256 duration
    ) external onlyOwner {
        if (beneficiary == address(0))      revert ZeroAddress();
        if (totalAmount == 0)               revert ZeroAmount();
        if (cliff > duration)               revert CliffExceedsDuration();
        if (start < block.timestamp)        revert StartInPast();
        if (balanceOf(msg.sender) < totalAmount)
            revert InsufficientBalance(balanceOf(msg.sender), totalAmount);

        // If existing vesting, return remaining tokens first
        Allocation storage existing = vestings[beneficiary];
        if (existing.total > 0) {
            uint256 remaining = existing.total - existing.claimed;
            if (remaining > 0) {
                _transfer(address(this), owner(), remaining);
            }
        }

        vestings[beneficiary] = Allocation({
            total:    totalAmount,
            claimed:  0,
            start:    start,
            cliff:    cliff,
            duration: duration
        });

        _transfer(msg.sender, address(this), totalAmount);
        emit VestingSet(beneficiary, totalAmount, start, cliff, duration);
    }

    /// @notice Remove a vesting schedule and return unvested tokens to owner
    function removeVesting(address beneficiary) external onlyOwner {
        Allocation storage v = vestings[beneficiary];
        if (v.total == 0) revert NoVesting();

        uint256 remaining = v.total - v.claimed;
        delete vestings[beneficiary];

        if (remaining > 0) {
            _transfer(address(this), owner(), remaining);
        }

        emit VestingRemoved(beneficiary, remaining);
    }

    /// @notice Claim vested tokens
    function claimVested() external nonReentrant {
        Allocation storage v = vestings[msg.sender];
        if (v.total == 0) revert NoVesting();

        uint256 vested    = _vestedAmount(v);
        uint256 claimable = vested - v.claimed;
        if (claimable == 0) revert NothingToClaim();

        v.claimed += claimable;
        _transfer(address(this), msg.sender, claimable);
        emit VestingClaimed(msg.sender, claimable);
    }

    /// @dev Internal linear vesting calculation with cliff
    function _vestedAmount(Allocation memory v) internal view returns (uint256) {
        if (block.timestamp < v.start + v.cliff) return 0;
        if (block.timestamp >= v.start + v.duration) return v.total;
        uint256 elapsed      = block.timestamp - (v.start + v.cliff);
        uint256 vestingPeriod = v.duration - v.cliff;
        return (v.total * elapsed) / vestingPeriod;
    }

    /// @notice View vested amount for any beneficiary
    function vestedAmount(address beneficiary) external view returns (uint256) {
        return _vestedAmount(vestings[beneficiary]);
    }

    /// @notice View claimable amount for any beneficiary
    function claimableAmount(address beneficiary) external view returns (uint256) {
        Allocation storage v = vestings[beneficiary];
        if (v.total == 0) return 0;
        return _vestedAmount(v) - v.claimed;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  FLASH LOANS (ERC3156)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Max flash loan amount (full contract balance)
    function maxFlashLoan(address token) external view override returns (uint256) {
        return token == address(this) ? balanceOf(address(this)) : 0;
    }

    /// @notice Flash loan fee calculation
    function flashFee(address token, uint256 amount) external view override returns (uint256) {
        if (token != address(this)) revert UnsupportedToken(token);
        return (amount * flashLoanFeeBP) / BASIS_POINTS;
    }

    /// @notice Execute a flash loan
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override nonReentrant returns (bool) {
        if (token != address(this))             revert UnsupportedToken(token);
        uint256 available = balanceOf(address(this));
        if (amount > available)                 revert InsufficientPool(available, amount);

        uint256 fee = (amount * flashLoanFeeBP) / BASIS_POINTS;

        // Send tokens to borrower
        _transfer(address(this), address(receiver), amount);

        // Execute borrower callback
        if (receiver.onFlashLoan(msg.sender, token, amount, fee, data) != CALLBACK_SUCCESS)
            revert CallbackFailed();

        // Repay loan + fee
        IERC20(address(this)).safeTransferFrom(address(receiver), address(this), amount + fee);

        emit FlashLoanExecuted(address(receiver), amount, fee);
        return true;
    }

    /// @notice Update flash loan fee (max 1%)
    function setFlashLoanFee(uint256 newFeeBP) external onlyOwner {
        if (newFeeBP > MAX_FLASH_FEE_BP) revert FlashLoanFeeTooHigh(newFeeBP, MAX_FLASH_FEE_BP);
        uint256 old = flashLoanFeeBP;
        flashLoanFeeBP = newFeeBP;
        emit FlashLoanFeeChanged(old, newFeeBP);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  RESCUE FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Recover accidentally sent ERC20 tokens (not FLASH itself)
    function recoverERC20(address token, uint256 amount, address to) external onlyOwner {
        if (to == address(0))        revert ZeroAddress();
        if (token == address(this))  revert CannotRecoverSelf();
        IERC20(token).safeTransfer(to, amount);
        emit TokensRecovered(token, amount, to);
    }

    /// @notice Recover accidentally sent ETH
    function recoverETH(uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool success, ) = payable(to).call{value: amount}("");
        if (!success) revert ETHTransferFailed();
        emit TokensRecovered(address(0), amount, to);
    }

    receive() external payable {}

    // ─────────────────────────────────────────────────────────────────────────
    //  OVERRIDES
    // ─────────────────────────────────────────────────────────────────────────

    function nonces(address owner)
        public view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}