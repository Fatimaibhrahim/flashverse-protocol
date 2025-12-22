// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Nonces.sol";

contract FlashVerseToken is
    ERC20,
    ERC20Burnable,
    ERC20Permit,
    ERC20Votes,
    ReentrancyGuard,
    Ownable,
    IERC3156FlashLender
{
    using SafeERC20 for ERC20;

    uint256 public constant BASIS_POINTS = 10000;

    // --- Anti-whale ---
    uint256 public maxTxAmount;

    // --- Vesting ---
    struct Allocation {
        uint256 total;
        uint256 claimed;
        uint256 start;
        uint256 cliff;
        uint256 duration;
    }
    mapping(address => Allocation) public vestings;

    // --- Flash Loan ---
    uint256 public flashLoanFeeBP = 5;
    address public flashLoanPool;
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    // --- Events ---
    event TokensRecovered(address token, uint256 amount, address to);
    event MaxTxAmountChanged(uint256 oldAmount, uint256 newAmount);
    event VestingSet(address indexed beneficiary, uint256 total, uint256 start, uint256 cliff, uint256 duration);
    event VestingClaimed(address indexed beneficiary, uint256 amount);
    event VestingRemoved(address indexed beneficiary);
    event FlashLoanExecuted(address indexed borrower, uint256 amount, uint256 fee);

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
        _mint(msg.sender, initialSupply_);
        maxTxAmount = (initialSupply_ * maxTxPercentBasisPoints) / BASIS_POINTS;

        flashLoanPool = address(this);
    }

    function _update(
        address from,
        address to,
        uint256 value
    )
        internal
        override(ERC20, ERC20Votes)
    {
        // Anti-whale Logic
        if (from != address(0) && to != address(0) && from != address(this)) {
            require(value <= maxTxAmount, "Anti-whale: exceeds maxTxAmount");
        }

        super._update(from, to, value);
    }

    function setMaxTxAmount(uint256 newAmount) external onlyOwner {
        require(newAmount > 0, "MaxTxAmount must > 0");
        uint256 old = maxTxAmount;
        maxTxAmount = newAmount;
        emit MaxTxAmountChanged(old, newAmount);
    }

    // --- Vesting ---
    function setVesting(address beneficiary, uint256 totalAmount, uint256 start, uint256 cliff, uint256 duration) external onlyOwner {
        require(beneficiary != address(0), "Zero address");
        require(totalAmount > 0, "Amount must > 0");
        require(cliff <= duration, "Cliff must <= duration");
        require(start >= block.timestamp || start + 1 >= block.timestamp, "Start must be in the future or now");
        require(balanceOf(msg.sender) >= totalAmount, "Insufficient balance");

        vestings[beneficiary] = Allocation(totalAmount, 0, start, cliff, duration);
        _transfer(msg.sender, address(this), totalAmount);
        emit VestingSet(beneficiary, totalAmount, start, cliff, duration);
    }

    function removeVesting(address beneficiary) external onlyOwner {
        Allocation storage v = vestings[beneficiary];
        require(v.total > 0, "No vesting to remove");
        uint256 remaining = v.total - v.claimed;
        if (remaining > 0) {
            _transfer(address(this), owner(), remaining);
        }
        delete vestings[beneficiary];
        emit VestingRemoved(beneficiary);
    }

    function claimVested() external {
        Allocation storage v = vestings[msg.sender];
        require(v.total > 0, "No vesting");
        uint256 vested = _vestedAmount(v);
        uint256 claimable = vested - v.claimed;
        require(claimable > 0, "Nothing to claim");

        v.claimed += claimable;
        _transfer(address(this), msg.sender, claimable);
        emit VestingClaimed(msg.sender, claimable);
    }

    function _vestedAmount(Allocation memory v) internal view returns (uint256) {
        if (block.timestamp < v.start + v.cliff) return 0;
        if (block.timestamp >= v.start + v.duration) return v.total;
        uint256 elapsed = block.timestamp - (v.start + v.cliff);
        uint256 totalVesting = v.duration - v.cliff;
        return (v.total * elapsed) / totalVesting;
    }

    function vestedAmount(address beneficiary) external view returns (uint256) {
        return _vestedAmount(vestings[beneficiary]);
    }

    // --- Flash Loans ---
    function maxFlashLoan(address token) external view override returns (uint256) {
        return token == address(this) ? ERC20(flashLoanPool).balanceOf(flashLoanPool) : 0;
    }

    function flashFee(address token, uint256 amount) external view override returns (uint256) {
        require(token == address(this), "FlashLoan: unsupported token");
        return (amount * flashLoanFeeBP) / BASIS_POINTS;
    }

    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        override
        nonReentrant
        returns (bool)
    {
        require(token == address(this), "FlashLoan: only this token supported");
        require(amount <= ERC20(flashLoanPool).balanceOf(flashLoanPool), "FlashLoan: insufficient pool");

        uint256 fee = (amount * flashLoanFeeBP) / BASIS_POINTS;

        ERC20(flashLoanPool).safeTransfer(address(receiver), amount);
        require(receiver.onFlashLoan(msg.sender, token, amount, fee, data) == CALLBACK_SUCCESS, "FlashLoan: callback failed");
        ERC20(flashLoanPool).safeTransferFrom(address(receiver), address(this), amount + fee);

        emit FlashLoanExecuted(address(receiver), amount, fee);
        return true;
    }

    // --- Recover ERC20 / ETH ---
    function recoverERC20(address token, uint256 amount, address to) external onlyOwner {
        require(to != address(0), "Zero address");
        require(token != address(this), "Cannot recover self token");
        ERC20(token).safeTransfer(to, amount);
        emit TokensRecovered(token, amount, to);
    }

    function recoverETH(uint256 amount, address to) external onlyOwner {
        require(to != address(0), "Zero address");
        (bool success, ) = payable(to).call{value: amount}("");
        require(success, "ETH transfer failed");
        emit TokensRecovered(address(0), amount, to);
    }

    receive() external payable {}
    
    // --- ERC20Permit Nonces Override ---
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
    
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}