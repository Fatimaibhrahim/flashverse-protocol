// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title VestingSchedule
 * @notice Professional, clean, global-standard vesting contract for teams, investors, advisors, founders.
 * @dev Uses OpenZeppelin utils and ReentrancyGuard for safe claims. Includes batch creation and emergency withdrawal.
 */

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ⭐️ تم الإصلاح هنا: تمرير (msg.sender) لتعيين المالك الأولي لـ Ownable ⭐️
contract VestingSchedule is Ownable(msg.sender), ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using Math for uint256;
    using SafeCast for uint256;

    // =======================
    //      STRUCTS
    // =======================
    struct Vest {
        uint256 total;      // Total allocated tokens
        uint256 claimed;    // Tokens claimed so far
        uint64 start;       // Start timestamp
        uint64 cliff;       // Cliff duration in seconds
        uint64 duration;    // Total vesting duration in seconds
        bool exists;        // Flag to check if vesting exists
    }

    IERC20 public immutable token;
    mapping(address => Vest) public vestings;

    // =======================
    //        EVENTS
    // =======================
    event VestingCreated(address indexed beneficiary, uint256 total, uint64 start, uint64 cliff, uint64 duration);
    event VestingUpdated(address indexed beneficiary, uint256 newTotal, uint256 returnedAmount);
    event TokensClaimed(address indexed beneficiary, uint256 amount);
    event VestingRevoked(address indexed beneficiary, uint256 returnedAmount);
    event BatchVestingCreated(uint256 count);

    // =======================
    //      CONSTRUCTOR
    // =======================
    /**
     * @dev Constructor to set the ERC20 token for vesting.
     * @param _token The ERC20 token contract address.
     */
    constructor(IERC20 _token) {
        require(address(_token) != address(0), "Invalid token address");
        token = _token;
    }

    // =======================
    //    INTERNAL LOGIC
    // =======================
    /**
     * @dev Calculates the vested amount based on time elapsed.
     * @param v The vesting struct.
     * @return The amount of tokens vested so far.
     */
    function _vestedAmount(Vest memory v) internal view returns (uint256) {
        if (!v.exists) return 0;
        if (block.timestamp < v.start + v.cliff) return 0;
        if (block.timestamp >= v.start + v.duration) return v.total;

        uint256 elapsed = block.timestamp - (v.start + v.cliff);
        uint256 vestingPeriod = v.duration - v.cliff;
        require(vestingPeriod > 0, "Invalid vesting period");

        // Use Math.mulDiv for safe multiplication and division to prevent overflow
        return Math.mulDiv(v.total, elapsed, vestingPeriod);
    }

    // =======================
    //     VIEW FUNCTIONS
    // =======================
    /**
     * @notice Returns the total vested amount for a beneficiary.
     * @param beneficiary The address of the beneficiary.
     * @return The vested amount.
     */
    function vestedAmount(address beneficiary) external view returns (uint256) {
        return _vestedAmount(vestings[beneficiary]);
    }

    /**
     * @notice Returns the claimable amount for a beneficiary.
     * @param beneficiary The address of the beneficiary.
     * @return The amount available to claim.
     */
    function claimableAmount(address beneficiary) public view returns (uint256) {
        Vest memory v = vestings[beneficiary];
        if (!v.exists) return 0;
        uint256 vested = _vestedAmount(v);
        return vested - v.claimed;
    }

    /**
     * @notice Returns full details of a vesting schedule.
     * @param beneficiary The address of the beneficiary.
     * @return total Total tokens, claimed Claimed tokens, start Start time, cliff Cliff duration, duration Total duration, exists If vesting exists.
     */
    function getVestingDetails(address beneficiary) external view returns (
        uint256 total,
        uint256 claimed,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bool exists
    ) {
        Vest memory v = vestings[beneficiary];
        return (v.total, v.claimed, v.start, v.cliff, v.duration, v.exists);
    }

    // =======================
    //    OWNER FUNCTIONS
    // =======================
    /**
     * @notice Creates a new vesting schedule for a beneficiary.
     * @param beneficiary The address to receive tokens.
     * @param totalAmount Total tokens to vest.
     * @param start Start timestamp.
     * @param cliff Cliff duration in seconds.
     * @param duration Total vesting duration in seconds.
     */
    function createVesting(
        address beneficiary,
        uint256 totalAmount,
        uint64 start,
        uint64 cliff,
        uint64 duration
    ) external onlyOwner {
        require(beneficiary != address(0), "Zero address");
        require(!vestings[beneficiary].exists, "Already exists");
        require(totalAmount > 0, "Zero amount");
        require(duration > 0, "Invalid duration");
        require(cliff <= duration, "Invalid cliff");
        require(start >= block.timestamp, "Start < now");

        vestings[beneficiary] = Vest({
            total: totalAmount,
            claimed: 0,
            start: start,
            cliff: cliff,
            duration: duration,
            exists: true
        });

        token.safeTransferFrom(msg.sender, address(this), totalAmount);
        emit VestingCreated(beneficiary, totalAmount, start, cliff, duration);
    }

    /**
     * @notice Updates the total amount for an existing vesting.
     * @param beneficiary The beneficiary address.
     * @param newTotal The new total amount.
     */
    function updateTotal(address beneficiary, uint256 newTotal) external onlyOwner {
        Vest storage v = vestings[beneficiary];
        require(v.exists, "No vest");
        require(newTotal >= v.claimed, "Less than claimed");

        uint256 returnedAmount = 0;
        if (newTotal < v.total) {
            returnedAmount = v.total - newTotal;
            token.safeTransfer(owner(), returnedAmount);
        } else if (newTotal > v.total) {
            uint256 additional = newTotal - v.total;
            token.safeTransferFrom(msg.sender, address(this), additional);
        }

        v.total = newTotal;
        emit VestingUpdated(beneficiary, newTotal, returnedAmount);
    }

    /**
     * @notice Revokes a vesting schedule, returning unvested tokens to owner after claiming vested ones.
     * @param beneficiary The beneficiary address.
     */
    function revoke(address beneficiary) external onlyOwner {
        Vest storage v = vestings[beneficiary];
        require(v.exists, "No vest");

        uint256 available = claimableAmount(beneficiary);
        if (available > 0) {
            v.claimed += available;
            token.safeTransfer(beneficiary, available);
            emit TokensClaimed(beneficiary, available);
        }

        uint256 unvested = v.total - v.claimed;
        delete vestings[beneficiary];

        if (unvested > 0) {
            token.safeTransfer(owner(), unvested);
        }

        emit VestingRevoked(beneficiary, unvested);
    }

    /**
     * @notice Batch creates multiple vesting schedules in one transaction.
     * @param beneficiaries Array of beneficiary addresses.
     * @param totalAmounts Array of total amounts.
     * @param starts Array of start times.
     * @param cliffs Array of cliff durations.
     * @param durations Array of total durations.
     */
    function batchCreateVesting(
        address[] calldata beneficiaries,
        uint256[] calldata totalAmounts,
        uint64[] calldata starts,
        uint64[] calldata cliffs,
        uint64[] calldata durations
    ) external onlyOwner {
        uint256 length = beneficiaries.length;
        require(
            length == totalAmounts.length &&
            length == starts.length &&
            length == cliffs.length &&
            length == durations.length,
            "Array lengths mismatch"
        );

        // Pre-validate all inputs to avoid partial state changes
        for (uint256 i = 0; i < length; i++) {
            require(beneficiaries[i] != address(0), "Zero address");
            require(!vestings[beneficiaries[i]].exists, "Already exists");
            require(totalAmounts[i] > 0, "Zero amount");
            require(durations[i] > 0, "Invalid duration");
            require(cliffs[i] <= durations[i], "Invalid cliff");
            require(starts[i] >= block.timestamp, "Start < now");
        }

        uint256 totalToTransfer = 0;
        for (uint256 i = 0; i < length; i++) {
            vestings[beneficiaries[i]] = Vest({
                total: totalAmounts[i],
                claimed: 0,
                start: starts[i],
                cliff: cliffs[i],
                duration: durations[i],
                exists: true
            });

            totalToTransfer += totalAmounts[i];
            emit VestingCreated(beneficiaries[i], totalAmounts[i], starts[i], cliffs[i], durations[i]);
        }

        token.safeTransferFrom(msg.sender, address(this), totalToTransfer);
        emit BatchVestingCreated(length);
    }

    /**
     * @notice Emergency withdrawal of stuck tokens by owner (e.g., if token is not vesting-related).
     * @param amount Amount to withdraw.
     */
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(amount > 0, "Zero amount");
        token.safeTransfer(owner(), amount);
    }

    // =======================
    //     USER FUNCTION
    // =======================
    /**
     * @notice Allows the beneficiary to claim their vested tokens.
     */
    function claim() external nonReentrant {
        Vest storage v = vestings[msg.sender];
        require(v.exists, "No vest");

        uint256 available = claimableAmount(msg.sender);
        require(available > 0, "Nothing to claim");

        v.claimed += available;
        token.safeTransfer(msg.sender, available);

        emit TokensClaimed(msg.sender, available);
    }
}