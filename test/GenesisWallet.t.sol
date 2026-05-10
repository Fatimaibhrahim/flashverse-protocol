// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ============================================================
//  FlashVerse – GenesisWallet Foundry Tests
//
//  Run all:       forge test --match-contract GenesisWalletTest -vv
//  Run one test:  forge test --match-test test_DistributeCorrectAmounts -vv
//  Run fuzz:      forge test --match-test testFuzz -vv
// ============================================================

import "forge-std/Test.sol";
import "../src/GenesisWallet.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ── Minimal MockERC20 inline (no separate file needed) ────────────────────────
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint256 supply)
        ERC20(name, symbol)
    {
        _mint(msg.sender, supply);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  GenesisWallet Tests
// ─────────────────────────────────────────────────────────────────────────────
contract GenesisWalletTest is Test {

    GenesisWallet public genesis;
    MockERC20     public token;

    address owner      = address(this);
    address airdrop    = makeAddr("airdrop");
    address publicSale = makeAddr("publicSale");
    address founders   = makeAddr("founders");
    address coreTeam   = makeAddr("coreTeam");
    address treasury   = makeAddr("treasury");
    address ecosystem  = makeAddr("ecosystem");
    address liquidity  = makeAddr("liquidity");
    address investors  = makeAddr("investors");
    address stranger   = makeAddr("stranger");

    uint256 constant TOTAL_SUPPLY = 18_000_000_000 ether;

    // ─────────────────────────────────────────
    //  Setup
    // ─────────────────────────────────────────
    function setUp() public {
        token   = new MockERC20("Flash Token", "FLASH", TOTAL_SUPPLY);
        genesis = new GenesisWallet(IERC20(address(token)));
        token.approve(address(genesis), TOTAL_SUPPLY);
    }

    // ─────────────────────────────────────────
    //  Helpers
    // ─────────────────────────────────────────
    function _configure() internal {
        genesis.configureAddresses(
            airdrop, publicSale, founders,
            coreTeam, treasury, ecosystem,
            liquidity, investors
        );
    }

    function _bps(uint256 bps) internal pure returns (uint256) {
        return (TOTAL_SUPPLY * bps) / 10_000;
    }

    // ─────────────────────────────────────────
    //  1. Deployment
    // ─────────────────────────────────────────
    function test_TokenAddressSet() public view {
        assertEq(address(genesis.token()), address(token));
    }

    function test_OwnerIsDeployer() public view {
        assertEq(genesis.owner(), owner);
    }

    function test_DistributedIsFalseAtStart() public view {
        assertFalse(genesis.distributed());
    }

    function test_ConstantsAreCorrect() public view {
        assertEq(genesis.TOTAL_SUPPLY(),              18_000_000_000 ether);
        assertEq(genesis.BASIS_POINTS(),              10_000);
        assertEq(genesis.COMMUNITY_REWARDS_BPS(),     1000);
        assertEq(genesis.PUBLIC_SALE_BPS(),           3300);
        assertEq(genesis.FOUNDERS_BPS(),               700);
        assertEq(genesis.CORE_TEAM_BPS(),              300);
        assertEq(genesis.RESERVES_BPS(),              1000);
        assertEq(genesis.ECOSYSTEM_GROWTH_BPS(),      1000);
        assertEq(genesis.LIQUIDITY_POOL_BPS(),         700);
        assertEq(genesis.STRATEGIC_INVESTORS_BPS(),   1000);
        assertEq(genesis.GOVERNANCE_RESERVE_BPS(),    1000);
    }

    function test_AllBpsSumTo10000() public view {
        uint256 sum =
            genesis.COMMUNITY_REWARDS_BPS()    +
            genesis.PUBLIC_SALE_BPS()           +
            genesis.FOUNDERS_BPS()              +
            genesis.CORE_TEAM_BPS()             +
            genesis.RESERVES_BPS()              +
            genesis.ECOSYSTEM_GROWTH_BPS()      +
            genesis.LIQUIDITY_POOL_BPS()        +
            genesis.STRATEGIC_INVESTORS_BPS()   +
            genesis.GOVERNANCE_RESERVE_BPS();
        assertEq(sum, 10_000);
    }

    // ─────────────────────────────────────────
    //  2. configureAddresses
    // ─────────────────────────────────────────
    function test_ConfigureAddresses() public {
        _configure();
        (
            address a, address b, address c, address d,
            address e, address f, address g, address h
        ) = genesis.getAddresses();
        assertEq(a, airdrop);
        assertEq(b, publicSale);
        assertEq(c, founders);
        assertEq(d, coreTeam);
        assertEq(e, treasury);
        assertEq(f, ecosystem);
        assertEq(g, liquidity);
        assertEq(h, investors);
    }

    function test_ConfigureCanBeCalledMultipleTimesBeforeDistribute() public {
        _configure();
        genesis.configureAddresses(
            stranger, publicSale, founders,
            coreTeam, treasury, ecosystem,
            liquidity, investors
        );
        (address a,,,,,,,) = genesis.getAddresses();
        assertEq(a, stranger);
    }

    function test_RevertConfigureIfNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        genesis.configureAddresses(
            airdrop, publicSale, founders,
            coreTeam, treasury, ecosystem,
            liquidity, investors
        );
    }

    function test_RevertConfigureAfterDistribute() public {
        _configure();
        genesis.distribute();
        vm.expectRevert("Already distributed");
        _configure();
    }

    function test_RevertConfigureZeroAddressAirdrop() public {
        vm.expectRevert("Invalid airdrop address");
        genesis.configureAddresses(
            address(0), publicSale, founders,
            coreTeam, treasury, ecosystem,
            liquidity, investors
        );
    }

    function test_RevertConfigureZeroAddressPublicSale() public {
        vm.expectRevert("Invalid public sale address");
        genesis.configureAddresses(
            airdrop, address(0), founders,
            coreTeam, treasury, ecosystem,
            liquidity, investors
        );
    }

    function test_RevertConfigureZeroAddressFounders() public {
        vm.expectRevert("Invalid founders address");
        genesis.configureAddresses(
            airdrop, publicSale, address(0),
            coreTeam, treasury, ecosystem,
            liquidity, investors
        );
    }

    function test_RevertConfigureZeroAddressCoreTeam() public {
        vm.expectRevert("Invalid core team address");
        genesis.configureAddresses(
            airdrop, publicSale, founders,
            address(0), treasury, ecosystem,
            liquidity, investors
        );
    }

    function test_RevertConfigureZeroAddressTreasury() public {
        vm.expectRevert("Invalid treasury address");
        genesis.configureAddresses(
            airdrop, publicSale, founders,
            coreTeam, address(0), ecosystem,
            liquidity, investors
        );
    }

    function test_RevertConfigureZeroAddressEcosystem() public {
        vm.expectRevert("Invalid ecosystem address");
        genesis.configureAddresses(
            airdrop, publicSale, founders,
            coreTeam, treasury, address(0),
            liquidity, investors
        );
    }

    function test_RevertConfigureZeroAddressLiquidity() public {
        vm.expectRevert("Invalid liquidity address");
        genesis.configureAddresses(
            airdrop, publicSale, founders,
            coreTeam, treasury, ecosystem,
            address(0), investors
        );
    }

    function test_RevertConfigureZeroAddressInvestors() public {
        vm.expectRevert("Invalid investors address");
        genesis.configureAddresses(
            airdrop, publicSale, founders,
            coreTeam, treasury, ecosystem,
            liquidity, address(0)
        );
    }

    function test_ConfigureEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit GenesisWallet.AddressesConfigured(owner);
        _configure();
    }

    // ─────────────────────────────────────────
    //  3. distribute
    // ─────────────────────────────────────────
    function test_DistributeCorrectAmounts() public {
        _configure();
        genesis.distribute();

        assertEq(token.balanceOf(airdrop),    _bps(1000)); // 10%
        assertEq(token.balanceOf(publicSale), _bps(3300)); // 33%
        assertEq(token.balanceOf(founders),   _bps(700));  //  7%
        assertEq(token.balanceOf(coreTeam),   _bps(300));  //  3%
        assertEq(token.balanceOf(treasury),   _bps(1000)); // 10%
        assertEq(token.balanceOf(ecosystem),  _bps(1000)); // 10%
        assertEq(token.balanceOf(liquidity),  _bps(700));  //  7%
        assertEq(token.balanceOf(investors),  _bps(1000)); // 10%
    }

    function test_GovernanceReserveStaysInContract() public {
        _configure();
        genesis.distribute();
        assertEq(token.balanceOf(address(genesis)), _bps(1000)); // 10%
    }

    function test_TotalDistributedEquals100Percent() public {
        _configure();
        genesis.distribute();

        uint256 total =
            token.balanceOf(airdrop)           +
            token.balanceOf(publicSale)        +
            token.balanceOf(founders)          +
            token.balanceOf(coreTeam)          +
            token.balanceOf(treasury)          +
            token.balanceOf(ecosystem)         +
            token.balanceOf(liquidity)         +
            token.balanceOf(investors)         +
            token.balanceOf(address(genesis));

        assertEq(total, TOTAL_SUPPLY);
    }

    function test_DistributedFlagSetAfterDistribute() public {
        _configure();
        genesis.distribute();
        assertTrue(genesis.distributed());
    }

    function test_RevertDistributeTwice() public {
        _configure();
        genesis.distribute();
        vm.expectRevert("Already distributed");
        genesis.distribute();
    }

    function test_RevertDistributeIfNotConfigured() public {
        vm.expectRevert("Addresses not configured");
        genesis.distribute();
    }

    function test_RevertDistributeIfNonOwner() public {
        _configure();
        vm.prank(stranger);
        vm.expectRevert();
        genesis.distribute();
    }

    function test_DistributeEmitsEvent() public {
        _configure();
        vm.expectEmit(false, false, false, true);
        emit GenesisWallet.TGEDistributed(
            _bps(1000), _bps(3300), _bps(700),  _bps(300),
            _bps(1000), _bps(1000), _bps(700),  _bps(1000),
            _bps(1000)
        );
        genesis.distribute();
    }

    // ─────────────────────────────────────────
    //  4. withdrawGovernanceTokens
    // ─────────────────────────────────────────
    function test_WithdrawGovernanceTokens() public {
        _configure();
        genesis.distribute();
        uint256 amount = 1_000_000 ether;
        genesis.withdrawGovernanceTokens(stranger, amount);
        assertEq(token.balanceOf(stranger), amount);
    }

    function test_WithdrawReducesContractBalance() public {
        _configure();
        genesis.distribute();
        uint256 before = token.balanceOf(address(genesis));
        uint256 amount = 500_000 ether;
        genesis.withdrawGovernanceTokens(stranger, amount);
        assertEq(token.balanceOf(address(genesis)), before - amount);
    }

    function test_RevertWithdrawBeforeDistribute() public {
        vm.expectRevert("TGE not done yet");
        genesis.withdrawGovernanceTokens(stranger, 100);
    }

    function test_RevertWithdrawZeroAmount() public {
        _configure();
        genesis.distribute();
        vm.expectRevert("Zero amount");
        genesis.withdrawGovernanceTokens(stranger, 0);
    }

    function test_RevertWithdrawToZeroAddress() public {
        _configure();
        genesis.distribute();
        vm.expectRevert("Invalid address");
        genesis.withdrawGovernanceTokens(address(0), 100);
    }

    function test_RevertWithdrawIfNonOwner() public {
        _configure();
        genesis.distribute();
        vm.prank(stranger);
        vm.expectRevert();
        genesis.withdrawGovernanceTokens(stranger, 100);
    }

    function test_WithdrawEmitsEvent() public {
        _configure();
        genesis.distribute();
        uint256 amount = 1_000_000 ether;
        vm.expectEmit(true, false, false, true);
        emit GenesisWallet.GovernanceTokensWithdrawn(stranger, amount);
        genesis.withdrawGovernanceTokens(stranger, amount);
    }

    // ─────────────────────────────────────────
    //  5. governanceBalance
    // ─────────────────────────────────────────
    function test_GovernanceBalanceAfterDistribute() public {
        _configure();
        genesis.distribute();
        assertEq(genesis.governanceBalance(), _bps(1000));
    }

    function test_GovernanceBalanceDecreasesAfterWithdraw() public {
        _configure();
        genesis.distribute();
        uint256 amount = 500_000 ether;
        genesis.withdrawGovernanceTokens(stranger, amount);
        assertEq(genesis.governanceBalance(), _bps(1000) - amount);
    }

    // ─────────────────────────────────────────
    //  6. Fuzz Tests
    // ─────────────────────────────────────────
    function testFuzz_WithdrawGovernanceAmount(uint256 amount) public {
        _configure();
        genesis.distribute();
        uint256 maxAmount = token.balanceOf(address(genesis));
        amount = bound(amount, 1, maxAmount);
        genesis.withdrawGovernanceTokens(stranger, amount);
        assertEq(token.balanceOf(stranger), amount);
    }

    function testFuzz_BpsAlwaysSumTo100Percent() public pure {
        uint256 sum =
            1000 + 3300 + 700 + 300 +
            1000 + 1000 + 700 + 1000 + 1000;
        assertEq(sum, 10_000);
    }
}