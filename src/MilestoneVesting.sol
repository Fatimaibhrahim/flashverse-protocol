// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MilestoneVesting
 * @notice Releases tokens to team members based on project milestones, not time.
 * @dev Owner (Fatima) is the sole approver of milestones.
 *
 * Milestones:
 * 1. Testnet Launch     — Deploy all contracts on Amoy testnet + live testing
 * 2. Mainnet Launch     — Deploy on Polygon mainnet + App on iOS/Android
 * 3. Advanced Features  — FlashID 2.0 + DeFi + NFT Hubs live
 * 4. Mass Adoption      — DAO live + Exchange listing + 10,000 users
 *
 * Each milestone releases 25% of each beneficiary's total allocation.
 * If a milestone is not approved within 12 months of the previous one,
 * owner can cancel it and reclaim unvested tokens.
 */

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MilestoneVesting is Ownable(msg.sender), ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =======================
    //      CONSTANTS
    // =======================
    uint256 public constant TOTAL_MILESTONES = 4;
    uint256 public constant MILESTONE_EXPIRY = 365 days; // 12 months per milestone
    uint256 public constant RELEASE_PER_MILESTONE_BPS = 2500; // 25% per milestone
    uint256 public constant BASIS_POINTS = 10_000;

    // =======================
    //      STRUCTS
    // =======================
    struct Milestone {
        string  name;
        string  description;
        bool    approved;
        uint256 approvedAt;
        uint256 deadline;    // Must be approved before this timestamp
    }

    struct Beneficiary {
        uint256 totalAmount;         // Total tokens allocated
        uint256 claimed;             // Tokens claimed so far
        uint256 lastMilestoneClaimed;// Last milestone index claimed (0 = none)
        bool    exists;
        bool    revoked;
    }

    // =======================
    //      STATE
    // =======================
    IERC20 public immutable token;

    Milestone[4] public milestones;
    mapping(address => Beneficiary) public beneficiaries;
    address[] public beneficiaryList;

    uint256 public currentMilestone; // 0 = none approved yet, up to 4
    bool    public initialized;

    // =======================
    //      EVENTS
    // =======================
    event MilestoneApproved(uint256 indexed milestoneIndex, string name, uint256 timestamp);
    event TokensReleased(address indexed beneficiary, uint256 milestoneIndex, uint256 amount);
    event MilestoneCancelled(uint256 indexed milestoneIndex, string reason);
    event BeneficiaryAdded(address indexed beneficiary, uint256 totalAmount);
    event BeneficiaryRevoked(address indexed beneficiary, uint256 returnedAmount);
    event BatchBeneficiariesAdded(uint256 count);

    // =======================
    //      CONSTRUCTOR
    // =======================
    constructor(IERC20 _token) {
        require(address(_token) != address(0), "Invalid token");
        token = _token;

        // Define the 4 milestones
        milestones[0] = Milestone({
            name: "Testnet Launch",
            description: "Deploy all contracts on Amoy testnet + live testing complete",
            approved: false,
            approvedAt: 0,
            deadline: block.timestamp + MILESTONE_EXPIRY
        });

        milestones[1] = Milestone({
            name: "Mainnet Launch",
            description: "Deploy on Polygon mainnet + App live on iOS and Android",
            approved: false,
            approvedAt: 0,
            deadline: 0 // Set when previous milestone is approved
        });

        milestones[2] = Milestone({
            name: "Advanced Features",
            description: "FlashID 2.0 + DeFi Hub + NFT Hub all live and functional",
            approved: false,
            approvedAt: 0,
            deadline: 0
        });

        milestones[3] = Milestone({
            name: "Mass Adoption",
            description: "DAO live + Exchange listing + 10,000 active users reached",
            approved: false,
            approvedAt: 0,
            deadline: 0
        });

        initialized = true;
    }

    // =======================
    //    OWNER FUNCTIONS
    // =======================

    /**
     * @notice Add a single beneficiary
     * @param beneficiary The team member's wallet address
     * @param totalAmount Total tokens allocated to them across all 4 milestones
     */
    function addBeneficiary(address beneficiary, uint256 totalAmount) external onlyOwner {
        require(beneficiary != address(0), "Invalid address");
        require(!beneficiaries[beneficiary].exists, "Already exists");
        require(totalAmount > 0, "Zero amount");

        beneficiaries[beneficiary] = Beneficiary({
            totalAmount: totalAmount,
            claimed: 0,
            lastMilestoneClaimed: 0,
            exists: true,
            revoked: false
        });

        beneficiaryList.push(beneficiary);
        token.safeTransferFrom(msg.sender, address(this), totalAmount);

        emit BeneficiaryAdded(beneficiary, totalAmount);
    }

    /**
     * @notice Add multiple beneficiaries at once
     */
    function batchAddBeneficiaries(
        address[] calldata _beneficiaries,
        uint256[] calldata _amounts
    ) external onlyOwner {
        require(_beneficiaries.length == _amounts.length, "Length mismatch");

        uint256 totalToTransfer = 0;
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            require(_beneficiaries[i] != address(0), "Invalid address");
            require(!beneficiaries[_beneficiaries[i]].exists, "Already exists");
            require(_amounts[i] > 0, "Zero amount");
            totalToTransfer += _amounts[i];
        }

        token.safeTransferFrom(msg.sender, address(this), totalToTransfer);

        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            beneficiaries[_beneficiaries[i]] = Beneficiary({
                totalAmount: _amounts[i],
                claimed: 0,
                lastMilestoneClaimed: 0,
                exists: true,
                revoked: false
            });
            beneficiaryList.push(_beneficiaries[i]);
            emit BeneficiaryAdded(_beneficiaries[i], _amounts[i]);
        }

        emit BatchBeneficiariesAdded(_beneficiaries.length);
    }

    /**
     * @notice Owner approves a milestone — this is the key function
     * @dev Milestones must be approved in order (1 → 2 → 3 → 4)
     * @param milestoneIndex 0-based index (0 = Testnet, 1 = Mainnet, etc.)
     */
    function approveMilestone(uint256 milestoneIndex) external onlyOwner {
        require(milestoneIndex < TOTAL_MILESTONES, "Invalid milestone");
        require(!milestones[milestoneIndex].approved, "Already approved");
        require(milestoneIndex == currentMilestone, "Must approve in order");

        milestones[milestoneIndex].approved   = true;
        milestones[milestoneIndex].approvedAt = block.timestamp;

        // Set deadline for next milestone
        if (milestoneIndex + 1 < TOTAL_MILESTONES) {
            milestones[milestoneIndex + 1].deadline = block.timestamp + MILESTONE_EXPIRY;
        }

        currentMilestone++;

        emit MilestoneApproved(milestoneIndex, milestones[milestoneIndex].name, block.timestamp);
    }

    /**
     * @notice Cancel an expired milestone and reclaim tokens
     * @dev Can only cancel if deadline has passed and milestone not yet approved
     * @param milestoneIndex 0-based index
     */
    function cancelMilestone(uint256 milestoneIndex, string calldata reason) external onlyOwner {
        require(milestoneIndex < TOTAL_MILESTONES, "Invalid milestone");
        require(!milestones[milestoneIndex].approved, "Already approved");
        require(
            milestones[milestoneIndex].deadline > 0 &&
            block.timestamp > milestones[milestoneIndex].deadline,
            "Deadline not passed"
        );

        // Calculate unvested tokens across all beneficiaries for this milestone
        uint256 totalToReturn = 0;
        for (uint256 i = 0; i < beneficiaryList.length; i++) {
            address b = beneficiaryList[i];
            Beneficiary storage ben = beneficiaries[b];
            if (!ben.revoked && ben.exists) {
                uint256 perMilestone = (ben.totalAmount * RELEASE_PER_MILESTONE_BPS) / BASIS_POINTS;
                totalToReturn += perMilestone;
            }
        }

        if (totalToReturn > 0) {
            token.safeTransfer(owner(), totalToReturn);
        }

        emit MilestoneCancelled(milestoneIndex, reason);
    }

    /**
     * @notice Revoke a specific beneficiary (e.g. team member leaves)
     */
    function revokeBeneficiary(address beneficiary) external onlyOwner {
        Beneficiary storage ben = beneficiaries[beneficiary];
        require(ben.exists, "Not a beneficiary");
        require(!ben.revoked, "Already revoked");

        ben.revoked = true;
        uint256 remaining = ben.totalAmount - ben.claimed;

        if (remaining > 0) {
            token.safeTransfer(owner(), remaining);
        }

        emit BeneficiaryRevoked(beneficiary, remaining);
    }

    // =======================
    //     USER FUNCTION
    // =======================

    /**
     * @notice Beneficiary claims their tokens for all approved milestones
     */
    function claim() external nonReentrant {
        Beneficiary storage ben = beneficiaries[msg.sender];
        require(ben.exists, "Not a beneficiary");
        require(!ben.revoked, "Revoked");

        uint256 claimable = claimableAmount(msg.sender);
        require(claimable > 0, "Nothing to claim");

        ben.claimed += claimable;
        ben.lastMilestoneClaimed = currentMilestone;

        token.safeTransfer(msg.sender, claimable);

        emit TokensReleased(msg.sender, currentMilestone, claimable);
    }

    // =======================
    //     VIEW FUNCTIONS
    // =======================

    /**
     * @notice Returns how many tokens a beneficiary can claim right now
     */
    function claimableAmount(address beneficiary) public view returns (uint256) {
        Beneficiary memory ben = beneficiaries[beneficiary];
        if (!ben.exists || ben.revoked) return 0;

        uint256 approvedMilestones = currentMilestone;
        uint256 alreadyClaimed     = ben.lastMilestoneClaimed;

        if (approvedMilestones <= alreadyClaimed) return 0;

        uint256 milestonesUnClaimed = approvedMilestones - alreadyClaimed;
        uint256 perMilestone = (ben.totalAmount * RELEASE_PER_MILESTONE_BPS) / BASIS_POINTS;

        return milestonesUnClaimed * perMilestone;
    }

    /**
     * @notice Returns details of a specific milestone
     */
    function getMilestone(uint256 index) external view returns (
        string memory name,
        string memory description,
        bool approved,
        uint256 approvedAt,
        uint256 deadline
    ) {
        require(index < TOTAL_MILESTONES, "Invalid index");
        Milestone memory m = milestones[index];
        return (m.name, m.description, m.approved, m.approvedAt, m.deadline);
    }

    /**
     * @notice Returns all beneficiary details
     */
    function getBeneficiary(address beneficiary) external view returns (
        uint256 totalAmount,
        uint256 claimed,
        uint256 lastMilestoneClaimed,
        bool exists,
        bool revoked
    ) {
        Beneficiary memory ben = beneficiaries[beneficiary];
        return (ben.totalAmount, ben.claimed, ben.lastMilestoneClaimed, ben.exists, ben.revoked);
    }

    /**
     * @notice Returns total number of beneficiaries
     */
    function totalBeneficiaries() external view returns (uint256) {
        return beneficiaryList.length;
    }
}