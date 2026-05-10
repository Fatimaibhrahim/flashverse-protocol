// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title GenesisWallet
 * @notice Handles the initial token distribution after TGE (Token Generation Event)
 * @dev Distributes FLASH tokens automatically based on whitepaper allocations
 *
 * Total Supply: 18,000,000,000 FLASH
 * Distribution:
 * - Community Rewards & Airdrops: 10% → AirdropDistributor
 * - Public Sale:                  33% → Public Sale Wallet
 * - Founders:                      7% → VestingSchedule (TGE 10%, then 2yr vesting)
 * - Core Team & Developers:        3% → VestingSchedule
 *   (Fatima/Lead: 6 months vesting | Others: 12mo cliff, 18mo vesting)
 * - Reserves:                     10% → TreasuryVault (locked 24 months)
 * - Ecosystem Growth:             10% → TreasuryVault (12mo lock, linear release)
 * - Liquidity Pool:                7% → Liquidity Wallet (fully unlocked at TGE)
 * - Strategic Investors:          10% → VestingSchedule (12mo cliff, 12mo vesting)
 * Total accounted:               90% (remaining 10% held in GenesisWallet for governance)
 */

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract GenesisWallet is Ownable(msg.sender), ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =======================
    //      CONSTANTS
    // =======================
    uint256 public constant TOTAL_SUPPLY = 18_000_000_000 * 1e18;

    // Allocation percentages (in basis points, 100 = 1%)
    uint256 public constant COMMUNITY_REWARDS_BPS   = 1000; // 10%
    uint256 public constant PUBLIC_SALE_BPS          = 3300; // 33%
    uint256 public constant FOUNDERS_BPS             =  700; //  7%
    uint256 public constant CORE_TEAM_BPS            =  300; //  3%
    uint256 public constant RESERVES_BPS             = 1000; // 10%
    uint256 public constant ECOSYSTEM_GROWTH_BPS     = 1000; // 10%
    uint256 public constant LIQUIDITY_POOL_BPS       =  700; //  7%
    uint256 public constant STRATEGIC_INVESTORS_BPS  = 1000; // 10%
    uint256 public constant GOVERNANCE_RESERVE_BPS   = 1000; // 10% held in GenesisWallet

    uint256 public constant BASIS_POINTS = 10_000;

    // =======================
    //      STATE
    // =======================
    IERC20 public immutable token;
    bool public distributed;

    // Destination addresses
    address public airdropDistributor;
    address public publicSaleWallet;
    address public foundersVesting;
    address public coreTeamVesting;
    address public treasuryVault;
    address public ecosystemVault;
    address public liquidityWallet;
    address public investorsVesting;

    // =======================
    //      EVENTS
    // =======================
    event AddressesConfigured(address indexed configuredBy);
    event TGEDistributed(
        uint256 communityAmount,
        uint256 publicSaleAmount,
        uint256 foundersAmount,
        uint256 coreTeamAmount,
        uint256 reservesAmount,
        uint256 ecosystemAmount,
        uint256 liquidityAmount,
        uint256 investorsAmount,
        uint256 governanceAmount
    );
    event GovernanceTokensWithdrawn(address indexed to, uint256 amount);

    // =======================
    //      CONSTRUCTOR
    // =======================
    /**
     * @param _token The FLASH ERC-20 token address
     */
    constructor(IERC20 _token) {
        require(address(_token) != address(0), "Invalid token");
        token = _token;
    }

    // =======================
    //    OWNER FUNCTIONS
    // =======================

    /**
     * @notice Configure all destination addresses before TGE
     * @dev Must be called before distribute()
     */
    function configureAddresses(
        address _airdropDistributor,
        address _publicSaleWallet,
        address _foundersVesting,
        address _coreTeamVesting,
        address _treasuryVault,
        address _ecosystemVault,
        address _liquidityWallet,
        address _investorsVesting
    ) external onlyOwner {
        require(!distributed, "Already distributed");
        require(_airdropDistributor != address(0), "Invalid airdrop address");
        require(_publicSaleWallet   != address(0), "Invalid public sale address");
        require(_foundersVesting    != address(0), "Invalid founders address");
        require(_coreTeamVesting    != address(0), "Invalid core team address");
        require(_treasuryVault      != address(0), "Invalid treasury address");
        require(_ecosystemVault     != address(0), "Invalid ecosystem address");
        require(_liquidityWallet    != address(0), "Invalid liquidity address");
        require(_investorsVesting   != address(0), "Invalid investors address");

        airdropDistributor = _airdropDistributor;
        publicSaleWallet   = _publicSaleWallet;
        foundersVesting    = _foundersVesting;
        coreTeamVesting    = _coreTeamVesting;
        treasuryVault      = _treasuryVault;
        ecosystemVault     = _ecosystemVault;
        liquidityWallet    = _liquidityWallet;
        investorsVesting   = _investorsVesting;

        emit AddressesConfigured(msg.sender);
    }

    /**
     * @notice Execute TGE distribution — sends tokens to all destinations automatically
     * @dev Can only be called once. Requires configureAddresses() first.
     *      Caller must have approved this contract to spend TOTAL_SUPPLY tokens.
     */
    function distribute() external onlyOwner nonReentrant {
        require(!distributed, "Already distributed");
        require(airdropDistributor != address(0), "Addresses not configured");

        distributed = true;

        // Calculate amounts
        uint256 communityAmount  = (TOTAL_SUPPLY * COMMUNITY_REWARDS_BPS)  / BASIS_POINTS;
        uint256 publicSaleAmount = (TOTAL_SUPPLY * PUBLIC_SALE_BPS)         / BASIS_POINTS;
        uint256 foundersAmount   = (TOTAL_SUPPLY * FOUNDERS_BPS)            / BASIS_POINTS;
        uint256 coreTeamAmount   = (TOTAL_SUPPLY * CORE_TEAM_BPS)           / BASIS_POINTS;
        uint256 reservesAmount   = (TOTAL_SUPPLY * RESERVES_BPS)            / BASIS_POINTS;
        uint256 ecosystemAmount  = (TOTAL_SUPPLY * ECOSYSTEM_GROWTH_BPS)    / BASIS_POINTS;
        uint256 liquidityAmount  = (TOTAL_SUPPLY * LIQUIDITY_POOL_BPS)      / BASIS_POINTS;
        uint256 investorsAmount  = (TOTAL_SUPPLY * STRATEGIC_INVESTORS_BPS) / BASIS_POINTS;
        uint256 governanceAmount = (TOTAL_SUPPLY * GOVERNANCE_RESERVE_BPS)  / BASIS_POINTS;

        // Pull all tokens from minter/owner into this contract first
        token.safeTransferFrom(msg.sender, address(this), TOTAL_SUPPLY);

        // Distribute to each destination
        token.safeTransfer(airdropDistributor, communityAmount);
        token.safeTransfer(publicSaleWallet,   publicSaleAmount);
        token.safeTransfer(foundersVesting,    foundersAmount);
        token.safeTransfer(coreTeamVesting,    coreTeamAmount);
        token.safeTransfer(treasuryVault,      reservesAmount);
        token.safeTransfer(ecosystemVault,     ecosystemAmount);
        token.safeTransfer(liquidityWallet,    liquidityAmount);
        token.safeTransfer(investorsVesting,   investorsAmount);
        // governanceAmount stays in this contract

        emit TGEDistributed(
            communityAmount,
            publicSaleAmount,
            foundersAmount,
            coreTeamAmount,
            reservesAmount,
            ecosystemAmount,
            liquidityAmount,
            investorsAmount,
            governanceAmount
        );
    }

    /**
     * @notice Withdraw governance reserve tokens (the 10% held here)
     * @param to Destination address
     * @param amount Amount to withdraw
     */
    function withdrawGovernanceTokens(address to, uint256 amount) external onlyOwner nonReentrant {
        require(distributed, "TGE not done yet");
        require(to != address(0), "Invalid address");
        require(amount > 0, "Zero amount");
        token.safeTransfer(to, amount);
        emit GovernanceTokensWithdrawn(to, amount);
    }

    // =======================
    //     VIEW FUNCTIONS
    // =======================

    /**
     * @notice Returns current governance reserve balance held in this contract
     */
    function governanceBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /**
     * @notice Returns all configured destination addresses
     */
    function getAddresses() external view returns (
        address _airdropDistributor,
        address _publicSaleWallet,
        address _foundersVesting,
        address _coreTeamVesting,
        address _treasuryVault,
        address _ecosystemVault,
        address _liquidityWallet,
        address _investorsVesting
    ) {
        return (
            airdropDistributor,
            publicSaleWallet,
            foundersVesting,
            coreTeamVesting,
            treasuryVault,
            ecosystemVault,
            liquidityWallet,
            investorsVesting
        );
    }
}