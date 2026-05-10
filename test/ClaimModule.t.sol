// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {ClaimModule} from "../src/ClaimModule.sol";
import {ERC20Mock}   from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title  ClaimModuleTest
 * @notice Full Foundry test suite for ClaimModule.
 *
 * @dev    Merkle tree is built manually inside Solidity using the same
 * double-hash leaf formula used in ClaimModule._buildLeaf():
 *
 * leaf = keccak256(abi.encode(keccak256(abi.encodePacked(
 * account, allocation, nonce, category
 * ))))
 *
 * For single-leaf trees the root == leaf, so no sibling is needed
 * and the proof is an empty array — which is what MerkleProof.verify
 * accepts correctly for single-entry trees.
 *
 * For two-leaf trees we sort the pair (lower hash first) and pass the
 * sibling as a one-element proof.
 */
contract ClaimModuleTest is Test {

    // ═══════════════════════════════════════════════════════════════════════
    //  Accounts
    // ═══════════════════════════════════════════════════════════════════════

    address internal admin    = makeAddr("admin");
    address internal pauser   = makeAddr("pauser");
    address internal monitor  = makeAddr("monitor");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal carol    = makeAddr("carol");
    address internal attacker = makeAddr("attacker");

    // ═══════════════════════════════════════════════════════════════════════
    //  Contracts
    // ═══════════════════════════════════════════════════════════════════════

    ClaimModule internal cm;
    ERC20Mock   internal token;

    // ═══════════════════════════════════════════════════════════════════════
    //  Shared constants
    // ═══════════════════════════════════════════════════════════════════════

    uint256 internal constant ALLOCATION = 1_000 ether;
    uint256 internal constant CATEGORY   = 1;
    uint256 internal constant AIRDROP_ID = 1;

    uint256 internal constant DURATION   = 1_000; // seconds
    uint256 internal constant CLIFF      = 200;   // seconds

    bytes32 internal ADMIN_ROLE;
    bytes32 internal PAUSER_ROLE;
    bytes32 internal MONITOR_ROLE;

    // ═══════════════════════════════════════════════════════════════════════
    //  Setup
    // ═══════════════════════════════════════════════════════════════════════

    function setUp() public {
        // Deploy mock ERC-20
        token = new ERC20Mock();
        token.mint(admin, 1_000_000 ether);

        // Deploy ClaimModule
        vm.prank(admin);
        cm = new ClaimModule(admin);

        // Fund contract
        vm.prank(admin);
        token.transfer(address(cm), 500_000 ether);
        vm.deal(address(cm), 100 ether);

        // Grant secondary roles
        vm.startPrank(admin);
        cm.grantRole(cm.PAUSER_ROLE(),  pauser);
        cm.grantRole(cm.MONITOR_ROLE(), monitor);
        vm.stopPrank();

        // Cache roles
        ADMIN_ROLE   = cm.ADMIN_ROLE();
        PAUSER_ROLE  = cm.PAUSER_ROLE();
        MONITOR_ROLE = cm.MONITOR_ROLE();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Internal helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Mirror of ClaimModule._buildLeaf()
    function _leaf(
        address account,
        uint256 allocation,
        uint256 nonce,
        uint256 category
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(abi.encodePacked(account, allocation, nonce, category))
            )
        );
    }

    /// @dev For a single-leaf tree: root == leaf, proof == [].
    function _singleLeafRoot(bytes32 leaf) internal pure returns (bytes32) {
        return leaf;
    }

    /// @dev For a two-leaf tree: sort leaves, root = keccak256(abi.encodePacked(lo, hi)).
    function _twoLeafRoot(bytes32 a, bytes32 b) internal pure returns (bytes32 root, bytes32 sibling) {
        (bytes32 lo, bytes32 hi) = a < b ? (a, b) : (b, a);
        root    = keccak256(abi.encodePacked(lo, hi));
        // sibling of `a` is `b`, and vice-versa
        sibling = (a == lo) ? hi : lo;
    }

    /// @dev Create a single-leaf instant airdrop for `account` with `allocation`.
    function _createInstantAirdrop(
        uint256 id,
        address account,
        uint256 allocation,
        uint256 nonce,
        uint256 category
    ) internal returns (bytes32 root, bytes32[] memory proof) {
        bytes32 leaf = _leaf(account, allocation, nonce, category);
        root  = _singleLeafRoot(leaf);
        proof = new bytes32[](0);

        uint256 start = block.timestamp + 5;
        vm.prank(admin);
        cm.createAirdrop(id, address(token), root, allocation, start, 0, 0);
        vm.warp(block.timestamp + 10); // past start
    }

    /// @dev Create a single-leaf ETH instant airdrop.
    function _createEthAirdrop(
        uint256 id,
        address account,
        uint256 allocation
    ) internal returns (bytes32[] memory proof) {
        bytes32 leaf = _leaf(account, allocation, 0, CATEGORY);
        bytes32 root = _singleLeafRoot(leaf);
        proof = new bytes32[](0);

        uint256 start = block.timestamp + 5;
        vm.prank(admin);
        cm.createAirdrop(id, address(0), root, allocation, start, 0, 0);
        vm.warp(block.timestamp + 10);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  1. DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════

    function test_deployment_rolesGrantedToAdmin() public view {
        assertTrue(cm.hasRole(cm.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(cm.hasRole(ADMIN_ROLE,   admin));
        assertTrue(cm.hasRole(PAUSER_ROLE,  admin));
        assertTrue(cm.hasRole(MONITOR_ROLE, admin));
    }

    function test_deployment_notPaused() public view {
        assertFalse(cm.globalPaused());
    }

    function test_deployment_revertsOnZeroAdmin() public {
        vm.expectRevert(ClaimModule.ZeroAddress.selector);
        new ClaimModule(address(0));
    }

    function test_deployment_maxBatchSize() public view {
        assertEq(cm.MAX_BATCH_SIZE(), 50);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  2. CREATE AIRDROP — success paths
    // ═══════════════════════════════════════════════════════════════════════

    function test_createAirdrop_storesCorrectData() public {
        bytes32 leaf = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 root = _singleLeafRoot(leaf);
        uint256 start = block.timestamp + 60;

        vm.prank(admin);
        cm.createAirdrop(AIRDROP_ID, address(token), root, ALLOCATION, start, CLIFF, DURATION);

        (
            bytes32 storedRoot,
            address storedToken,
            uint256 storedAlloc,
            ,
            uint256 storedStart,
            uint256 storedCliff,
            uint256 storedDuration,
            bool    storedActive
        ) = cm.airdrops(AIRDROP_ID);

        assertEq(storedRoot,     root);
        assertEq(storedToken,    address(token));
        assertEq(storedAlloc,    ALLOCATION);
        assertEq(storedStart,    start);
        assertEq(storedCliff,    CLIFF);
        assertEq(storedDuration, DURATION);
        assertTrue(storedActive);
        assertTrue(cm.exists(AIRDROP_ID));
        assertTrue(cm.usedRoots(root));
    }

    function test_createAirdrop_emitsEvent() public {
        bytes32 leaf  = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 root  = _singleLeafRoot(leaf);
        uint256 start = block.timestamp + 60;

        vm.expectEmit(true, true, false, true);
        emit ClaimModule.AirdropCreated(
            AIRDROP_ID, address(token), root, ALLOCATION, start, CLIFF, DURATION
        );

        vm.prank(admin);
        cm.createAirdrop(AIRDROP_ID, address(token), root, ALLOCATION, start, CLIFF, DURATION);
    }

    function test_createAirdrop_ethToken() public {
        bytes32 leaf  = _leaf(alice, 1 ether, 0, CATEGORY);
        bytes32 root  = _singleLeafRoot(leaf);
        uint256 start = block.timestamp + 60;

        vm.prank(admin);
        cm.createAirdrop(AIRDROP_ID, address(0), root, 1 ether, start, 0, 0);

        (,address storedToken,,,,,, ) = cm.airdrops(AIRDROP_ID);
        assertEq(storedToken, address(0));
    }

    function test_createAirdrop_instantNoVesting() public {
        bytes32 leaf  = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 root  = _singleLeafRoot(leaf);
        uint256 start = block.timestamp + 60;

        vm.prank(admin);
        cm.createAirdrop(AIRDROP_ID, address(token), root, ALLOCATION, start, 0, 0);

        (,,,,,, uint256 storedDuration, ) = cm.airdrops(AIRDROP_ID);
        assertEq(storedDuration, 0);
    }

    function test_createAirdrop_appendsToIdList() public {
        bytes32 leaf  = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 root  = _singleLeafRoot(leaf);
        uint256 start = block.timestamp + 60;

        vm.prank(admin);
        cm.createAirdrop(AIRDROP_ID, address(token), root, ALLOCATION, start, 0, 0);

        uint256[] memory ids = cm.getAirdropIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], AIRDROP_ID);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  3. CREATE AIRDROP — revert paths
    // ═══════════════════════════════════════════════════════════════════════

    function test_createAirdrop_revertsOnDuplicateId() public {
        bytes32 leaf  = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 root  = _singleLeafRoot(leaf);
        uint256 start = block.timestamp + 60;

        vm.startPrank(admin);
        cm.createAirdrop(AIRDROP_ID, address(token), root, ALLOCATION, start, 0, 0);

        bytes32 leaf2 = _leaf(bob, ALLOCATION, 0, CATEGORY);
        bytes32 root2 = _singleLeafRoot(leaf2);

        vm.expectRevert(ClaimModule.InvalidParameters.selector);
        cm.createAirdrop(AIRDROP_ID, address(token), root2, ALLOCATION, start, 0, 0);
        vm.stopPrank();
    }

    function test_createAirdrop_revertsOnDuplicateMerkleRoot() public {
        bytes32 leaf = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 root = _singleLeafRoot(leaf);
        uint256 start = block.timestamp + 60;

        vm.startPrank(admin);
        cm.createAirdrop(AIRDROP_ID, address(token), root, ALLOCATION, start, 0, 0);

        vm.expectRevert(ClaimModule.RootAlreadyUsed.selector);
        cm.createAirdrop(2, address(token), root, ALLOCATION, start, 0, 0);
        vm.stopPrank();
    }

    function test_createAirdrop_revertsOnZeroId() public {
        bytes32 leaf = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 root = _singleLeafRoot(leaf);

        vm.expectRevert(ClaimModule.InvalidParameters.selector);
        vm.prank(admin);
        cm.createAirdrop(0, address(token), root, ALLOCATION, block.timestamp + 60, 0, 0);
    }

    function test_createAirdrop_revertsOnPastStart() public {
        bytes32 leaf = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 root = _singleLeafRoot(leaf);

        vm.expectRevert(ClaimModule.InvalidStartTime.selector);
        vm.prank(admin);
        cm.createAirdrop(AIRDROP_ID, address(token), root, ALLOCATION, block.timestamp - 1, 0, 0);
    }

    function test_createAirdrop_revertsCliffGtDuration() public {
        bytes32 leaf = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 root = _singleLeafRoot(leaf);

        vm.expectRevert(ClaimModule.InvalidParameters.selector);
        vm.prank(admin);
        cm.createAirdrop(AIRDROP_ID, address(token), root, ALLOCATION, block.timestamp + 60, 200, 100);
    }

    function test_createAirdrop_revertsCliffWithZeroDuration() public {
        bytes32 leaf = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 root = _singleLeafRoot(leaf);

        vm.expectRevert(ClaimModule.InvalidParameters.selector);
        vm.prank(admin);
        cm.createAirdrop(AIRDROP_ID, address(token), root, ALLOCATION, block.timestamp + 60, 10, 0);
    }

    function test_createAirdrop_revertsFromNonAdmin() public {
        bytes32 leaf = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 root = _singleLeafRoot(leaf);

        vm.expectRevert();
        vm.prank(attacker);
        cm.createAirdrop(AIRDROP_ID, address(token), root, ALLOCATION, block.timestamp + 60, 0, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  4. TOGGLE & GLOBAL PAUSE
    // ═══════════════════════════════════════════════════════════════════════

    function test_toggleAirdrop_setsActiveAndEmits() public {
        _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        vm.expectEmit(true, false, false, true);
        emit ClaimModule.AirdropToggled(AIRDROP_ID, false);

        vm.prank(admin);
        cm.toggleAirdrop(AIRDROP_ID, false);

        (,,,,,,, bool active) = cm.airdrops(AIRDROP_ID);
        assertFalse(active);
    }

    function test_toggleAirdrop_revertsOnNonExistentId() public {
        vm.expectRevert(ClaimModule.InvalidAirdrop.selector);
        vm.prank(admin);
        cm.toggleAirdrop(999, false);
    }

    function test_setGlobalPause_pauserCanPause() public {
        vm.expectEmit(false, false, false, true);
        emit ClaimModule.GlobalPauseSet(true);

        vm.prank(pauser);
        cm.setGlobalPause(true);
        assertTrue(cm.globalPaused());
    }

    function test_setGlobalPause_revertsFromNonPauser() public {
        vm.expectRevert();
        vm.prank(attacker);
        cm.setGlobalPause(true);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  5. VESTING MATH
    // ═══════════════════════════════════════════════════════════════════════

    function test_vestedAmount_zeroBeforeCliff() public {
        bytes32 leaf  = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 root  = _singleLeafRoot(leaf);
        uint256 start = block.timestamp + 10;

        vm.prank(admin);
        cm.createAirdrop(AIRDROP_ID, address(token), root, ALLOCATION, start, CLIFF, DURATION);

        // Still before cliff
        assertEq(cm.vestedAmount(AIRDROP_ID, ALLOCATION), 0);
    }

    function test_vestedAmount_linearMidway() public {
        bytes32 leaf  = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 root  = _singleLeafRoot(leaf);
        uint256 start = block.timestamp + 10;

        vm.prank(admin);
        cm.createAirdrop(AIRDROP_ID, address(token), root, ALLOCATION, start, 0, DURATION);

        // Advance to start + 500 (50% of duration)
        vm.warp(start + 500);

        uint256 vested = cm.vestedAmount(AIRDROP_ID, ALLOCATION);
        // Should be ~50% (500/1000 * ALLOCATION)
        assertApproxEqAbs(vested, ALLOCATION / 2, 1 ether);
    }

    function test_vestedAmount_fullAfterDuration() public {
        bytes32 leaf  = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 root  = _singleLeafRoot(leaf);
        uint256 start = block.timestamp + 10;

        vm.prank(admin);
        cm.createAirdrop(AIRDROP_ID, address(token), root, ALLOCATION, start, 0, DURATION);

        vm.warp(start + DURATION + 100);
        assertEq(cm.vestedAmount(AIRDROP_ID, ALLOCATION), ALLOCATION);
    }

    function test_vestedAmount_instantFullyVested() public {
        bytes32 leaf  = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 root  = _singleLeafRoot(leaf);
        uint256 start = block.timestamp + 5;

        vm.prank(admin);
        cm.createAirdrop(AIRDROP_ID, address(token), root, ALLOCATION, start, 0, 0);

        vm.warp(start + 1);
        assertEq(cm.vestedAmount(AIRDROP_ID, ALLOCATION), ALLOCATION);
    }

    function test_vestedAmount_zeroAtExactCliffBoundary() public {
        bytes32 leaf  = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 root  = _singleLeafRoot(leaf);
        uint256 start = block.timestamp + 10;

        vm.prank(admin);
        cm.createAirdrop(AIRDROP_ID, address(token), root, ALLOCATION, start, CLIFF, DURATION);

        // Exactly at cliff - 1 second: still 0
        vm.warp(start + CLIFF - 1);
        assertEq(cm.vestedAmount(AIRDROP_ID, ALLOCATION), 0);

        // Exactly at cliff: linear kicks in
        vm.warp(start + CLIFF);
        assertGt(cm.vestedAmount(AIRDROP_ID, ALLOCATION), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  6. SINGLE CLAIM — ERC-20
    // ═══════════════════════════════════════════════════════════════════════

    function test_claim_erc20_transfersTokens() public {
        (, bytes32[] memory proof) = _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        cm.claim(AIRDROP_ID, ALLOCATION, 0, CATEGORY, proof);

        assertEq(token.balanceOf(alice) - before, ALLOCATION);
    }

    function test_claim_erc20_emitsClaimedEvent() public {
        (, bytes32[] memory proof) = _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        vm.expectEmit(true, true, false, true);
        emit ClaimModule.Claimed(AIRDROP_ID, alice, ALLOCATION, 0);

        vm.prank(alice);
        cm.claim(AIRDROP_ID, ALLOCATION, 0, CATEGORY, proof);
    }

    function test_claim_erc20_incrementsNonce() public {
        (, bytes32[] memory proof) = _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        vm.prank(alice);
        cm.claim(AIRDROP_ID, ALLOCATION, 0, CATEGORY, proof);

        assertEq(cm.nonces(AIRDROP_ID, alice), 1);
    }

    function test_claim_erc20_updatesClaimedMapping() public {
        (, bytes32[] memory proof) = _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        vm.prank(alice);
        cm.claim(AIRDROP_ID, ALLOCATION, 0, CATEGORY, proof);

        assertEq(cm.claimed(AIRDROP_ID, alice), ALLOCATION);
    }

    function test_claim_revertsInvalidAirdrop() public {
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(ClaimModule.InvalidAirdrop.selector);
        vm.prank(alice);
        cm.claim(999, ALLOCATION, 0, CATEGORY, proof);
    }

    function test_claim_revertsInvalidProof() public {
        (, bytes32[] memory proof) = _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        // Bob uses Alice's proof — should fail
        vm.expectRevert(ClaimModule.InvalidProof.selector);
        vm.prank(bob);
        cm.claim(AIRDROP_ID, ALLOCATION, 0, CATEGORY, proof);
    }

    function test_claim_revertsInvalidNonce() public {
        (, bytes32[] memory proof) = _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        vm.prank(alice);
        cm.claim(AIRDROP_ID, ALLOCATION, 0, CATEGORY, proof);

        // Try to replay with old nonce
        vm.expectRevert(ClaimModule.InvalidNonce.selector);
        vm.prank(alice);
        cm.claim(AIRDROP_ID, ALLOCATION, 0, CATEGORY, proof);
    }

    function test_claim_revertsWhenGloballyPaused() public {
        (, bytes32[] memory proof) = _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        vm.prank(pauser);
        cm.setGlobalPause(true);

        vm.expectRevert(ClaimModule.GloballyPaused.selector);
        vm.prank(alice);
        cm.claim(AIRDROP_ID, ALLOCATION, 0, CATEGORY, proof);
    }

    function test_claim_revertsWhenAirdropInactive() public {
        (, bytes32[] memory proof) = _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        vm.prank(admin);
        cm.toggleAirdrop(AIRDROP_ID, false);

        vm.expectRevert(ClaimModule.AirdropNotActive.selector);
        vm.prank(alice);
        cm.claim(AIRDROP_ID, ALLOCATION, 0, CATEGORY, proof);
    }

    function test_claim_revertsNothingToClaimBeforeVesting() public {
        bytes32 leaf  = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 root  = _singleLeafRoot(leaf);
        bytes32[] memory proof = new bytes32[](0);
        uint256 start = block.timestamp + 100;

        vm.prank(admin);
        cm.createAirdrop(AIRDROP_ID, address(token), root, ALLOCATION, start, CLIFF, DURATION);

        // Do NOT advance time — before start
        vm.expectRevert(ClaimModule.NothingToClaim.selector);
        vm.prank(alice);
        cm.claim(AIRDROP_ID, ALLOCATION, 0, CATEGORY, proof);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  7. SINGLE CLAIM — ETH
    // ═══════════════════════════════════════════════════════════════════════

    function test_claim_eth_transfersNativeToken() public {
        uint256 ethAlloc = 1 ether;
        bytes32[] memory proof = _createEthAirdrop(AIRDROP_ID, alice, ethAlloc);

        uint256 before = alice.balance;
        vm.prank(alice);
        cm.claim(AIRDROP_ID, ethAlloc, 0, CATEGORY, proof);

        assertEq(alice.balance - before, ethAlloc);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  8. PROGRESSIVE VESTING
    // ═══════════════════════════════════════════════════════════════════════

    function test_progressiveVesting_twoPartialClaims() public {
        bytes32 leaf0  = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 leaf1  = _leaf(alice, ALLOCATION, 1, CATEGORY);

        // Build a two-leaf tree so both nonces are valid
        (bytes32 root, bytes32 sibling0) = _twoLeafRoot(leaf0, leaf1);
        bytes32[] memory proof0 = new bytes32[](1);
        proof0[0] = sibling0;

        uint256 start = block.timestamp + 10;
        vm.prank(admin);
        cm.createAirdrop(AIRDROP_ID, address(token), root, ALLOCATION, start, 0, DURATION);

        // ── Claim 1: at 25% ─────────────────────────────────────────────
        vm.warp(start + 250);
        vm.prank(alice);
        cm.claim(AIRDROP_ID, ALLOCATION, 0, CATEGORY, proof0);

        uint256 firstClaim = cm.claimed(AIRDROP_ID, alice);
        assertGt(firstClaim, 0);
        assertLt(firstClaim, ALLOCATION);

        // ── Claim 2 (nonce=1): at 75% ───────────────────────────────────
        vm.warp(start + 750);

        bytes32[] memory p1 = new bytes32[](1);
        p1[0] = leaf0 < leaf1 ? leaf0 : leaf1;

        vm.prank(alice);
        cm.claim(AIRDROP_ID, ALLOCATION, 1, CATEGORY, p1);

        uint256 totalClaimed = cm.claimed(AIRDROP_ID, alice);
        assertGt(totalClaimed, firstClaim);
        assertLe(totalClaimed, ALLOCATION);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  9. BATCH CLAIM
    // ═══════════════════════════════════════════════════════════════════════

    function _setupTwoInstantAirdrops()
        internal
        returns (
            bytes32[] memory proofA,
            bytes32[] memory proofB,
            uint256 allocA,
            uint256 allocB
        )
    {
        allocA = 500 ether;
        allocB = 300 ether;

        uint256 start = block.timestamp + 5;

        // Airdrop A
        bytes32 leafA = _leaf(alice, allocA, 0, CATEGORY);
        bytes32 rootA = _singleLeafRoot(leafA);
        vm.prank(admin);
        cm.createAirdrop(1, address(token), rootA, allocA, start, 0, 0);

        // Airdrop B
        bytes32 leafB = _leaf(alice, allocB, 0, CATEGORY);
        bytes32 rootB = _singleLeafRoot(leafB);
        vm.prank(admin);
        cm.createAirdrop(2, address(token), rootB, allocB, start, 0, 0);

        vm.warp(block.timestamp + 10);

        proofA = new bytes32[](0);
        proofB = new bytes32[](0);
    }

    function test_batchClaim_claimsFromMultipleAirdrops() public {
        (
            bytes32[] memory proofA,
            bytes32[] memory proofB,
            uint256 allocA,
            uint256 allocB
        ) = _setupTwoInstantAirdrops();

        uint256[] memory ids       = new uint256[](2);
        uint256[] memory allocs    = new uint256[](2);
        uint256[] memory noncesArr = new uint256[](2);
        uint256[] memory cats      = new uint256[](2);
        bytes32[][] memory proofs  = new bytes32[][](2);

        ids[0] = 1; ids[1] = 2;
        allocs[0] = allocA; allocs[1] = allocB;
        noncesArr[0] = 0; noncesArr[1] = 0;
        cats[0] = CATEGORY; cats[1] = CATEGORY;
        proofs[0] = proofA; proofs[1] = proofB;

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        cm.batchClaim(ids, allocs, noncesArr, cats, proofs);

        assertEq(token.balanceOf(alice) - before, allocA + allocB);
    }

    function test_batchClaim_emitsBatchClaimedEvent() public {
        (
            bytes32[] memory proofA,
            bytes32[] memory proofB,
            uint256 allocA,
            uint256 allocB
        ) = _setupTwoInstantAirdrops();

        uint256[] memory ids       = new uint256[](2);
        uint256[] memory allocs    = new uint256[](2);
        uint256[] memory noncesArr = new uint256[](2);
        uint256[] memory cats      = new uint256[](2);
        bytes32[][] memory proofs  = new bytes32[][](2);

        ids[0] = 1; ids[1] = 2;
        allocs[0] = allocA; allocs[1] = allocB;
        noncesArr[0] = 0; noncesArr[1] = 0;
        cats[0] = CATEGORY; cats[1] = CATEGORY;
        proofs[0] = proofA; proofs[1] = proofB;

        vm.expectEmit(true, false, false, false);
        emit ClaimModule.BatchClaimed(alice, ids, allocs);

        vm.prank(alice);
        cm.batchClaim(ids, allocs, noncesArr, cats, proofs);
    }

    function test_batchClaim_revertsDuplicateId() public {
        (, bytes32[] memory proof) = _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        uint256[] memory ids       = new uint256[](2);
        uint256[] memory allocs    = new uint256[](2);
        uint256[] memory noncesArr = new uint256[](2);
        uint256[] memory cats      = new uint256[](2);
        bytes32[][] memory proofs  = new bytes32[][](2);

        ids[0] = AIRDROP_ID; ids[1] = AIRDROP_ID; // duplicate!
        allocs[0] = ALLOCATION; allocs[1] = ALLOCATION;
        noncesArr[0] = 0; noncesArr[1] = 0;
        cats[0] = CATEGORY; cats[1] = CATEGORY;
        proofs[0] = proof; proofs[1] = proof;

        vm.expectRevert(
            abi.encodeWithSelector(ClaimModule.DuplicateIdInBatch.selector, AIRDROP_ID)
        );
        vm.prank(alice);
        cm.batchClaim(ids, allocs, noncesArr, cats, proofs);
    }

    function test_batchClaim_revertsEmptyBatch() public {
        uint256[] memory ids       = new uint256[](0);
        uint256[] memory allocs    = new uint256[](0);
        uint256[] memory noncesArr = new uint256[](0);
        uint256[] memory cats      = new uint256[](0);
        bytes32[][] memory proofs  = new bytes32[][](0);

        vm.expectRevert(ClaimModule.BatchSizeExceeded.selector);
        vm.prank(alice);
        cm.batchClaim(ids, allocs, noncesArr, cats, proofs);
    }

    function test_batchClaim_revertsMismatchedArrayLengths() public {
        uint256[] memory ids       = new uint256[](2);
        uint256[] memory allocs    = new uint256[](1); // mismatch
        uint256[] memory noncesArr = new uint256[](2);
        uint256[] memory cats      = new uint256[](2);
        bytes32[][] memory proofs  = new bytes32[][](2);

        vm.expectRevert(ClaimModule.BatchLengthMismatch.selector);
        vm.prank(alice);
        cm.batchClaim(ids, allocs, noncesArr, cats, proofs);
    }

    function test_batchClaim_revertsWhenGloballyPaused() public {
        (, bytes32[] memory proof) = _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        vm.prank(pauser);
        cm.setGlobalPause(true);

        uint256[] memory ids       = new uint256[](1);
        uint256[] memory allocs    = new uint256[](1);
        uint256[] memory noncesArr = new uint256[](1);
        uint256[] memory cats      = new uint256[](1);
        bytes32[][] memory proofs  = new bytes32[][](1);

        ids[0] = AIRDROP_ID; allocs[0] = ALLOCATION;
        noncesArr[0] = 0; cats[0] = CATEGORY; proofs[0] = proof;

        vm.expectRevert(ClaimModule.GloballyPaused.selector);
        vm.prank(alice);
        cm.batchClaim(ids, allocs, noncesArr, cats, proofs);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  10. EMERGENCY WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════

    function test_emergencyWithdraw_erc20() public {
        uint256 amount = 50 ether;
        uint256 before = token.balanceOf(admin);

        vm.prank(admin);
        cm.emergencyWithdraw(address(token), admin, amount);

        assertEq(token.balanceOf(admin) - before, amount);
    }

    function test_emergencyWithdraw_eth() public {
        uint256 amount = 1 ether;
        uint256 before = admin.balance;

        vm.prank(admin);
        cm.emergencyWithdraw(address(0), admin, amount);

        assertEq(admin.balance - before, amount);
    }

    function test_emergencyWithdraw_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit ClaimModule.EmergencyWithdraw(address(token), admin, 1 ether);

        vm.prank(admin);
        cm.emergencyWithdraw(address(token), admin, 1 ether);
    }

    function test_emergencyWithdraw_revertsFromNonAdmin() public {
        vm.expectRevert();
        vm.prank(attacker);
        cm.emergencyWithdraw(address(token), attacker, 1 ether);
    }

    function test_emergencyWithdraw_revertsZeroAddress() public {
        vm.expectRevert(ClaimModule.ZeroAddress.selector);
        vm.prank(admin);
        cm.emergencyWithdraw(address(token), address(0), 1 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  11. getClaimableAmount VIEW
    // ═══════════════════════════════════════════════════════════════════════

    function test_getClaimableAmount_returnsFullForUnclaimedValidProof() public {
        (, bytes32[] memory proof) = _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        uint256 claimable = cm.getClaimableAmount(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY, proof);
        assertEq(claimable, ALLOCATION);
    }

    function test_getClaimableAmount_returnsZeroAfterFullClaim() public {
        (, bytes32[] memory proof) = _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        vm.prank(alice);
        cm.claim(AIRDROP_ID, ALLOCATION, 0, CATEGORY, proof);

        uint256 claimable = cm.getClaimableAmount(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY, proof);
        assertEq(claimable, 0);
    }

    function test_getClaimableAmount_returnsZeroForInvalidProof() public {
        _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        bytes32[] memory badProof = new bytes32[](0);
        uint256 claimable = cm.getClaimableAmount(AIRDROP_ID, bob, ALLOCATION, 0, CATEGORY, badProof);
        assertEq(claimable, 0);
    }

    function test_getClaimableAmount_returnsZeroWhenPaused() public {
        (, bytes32[] memory proof) = _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        vm.prank(pauser);
        cm.setGlobalPause(true);

        uint256 claimable = cm.getClaimableAmount(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY, proof);
        assertEq(claimable, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  12. SECURITY
    // ═══════════════════════════════════════════════════════════════════════

    function test_security_attackerCannotUseStolenProof() public {
        (, bytes32[] memory proof) = _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        // Attacker tries Alice's proof with their own address
        vm.expectRevert(ClaimModule.InvalidProof.selector);
        vm.prank(attacker);
        cm.claim(AIRDROP_ID, ALLOCATION, 0, CATEGORY, proof);
    }

    function test_security_replayAttackRejected() public {
        (, bytes32[] memory proof) = _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        vm.prank(alice);
        cm.claim(AIRDROP_ID, ALLOCATION, 0, CATEGORY, proof);

        vm.expectRevert(ClaimModule.InvalidNonce.selector);
        vm.prank(alice);
        cm.claim(AIRDROP_ID, ALLOCATION, 0, CATEGORY, proof);
    }

    function test_security_reusedRootRejectedOnNewAirdrop() public {
        bytes32 leaf = _leaf(alice, ALLOCATION, 0, CATEGORY);
        bytes32 root = _singleLeafRoot(leaf);
        uint256 start = block.timestamp + 60;

        vm.startPrank(admin);
        cm.createAirdrop(AIRDROP_ID, address(token), root, ALLOCATION, start, 0, 0);

        vm.expectRevert(ClaimModule.RootAlreadyUsed.selector);
        cm.createAirdrop(2, address(token), root, ALLOCATION, start, 0, 0);
        vm.stopPrank();
    }

    function test_security_wrongAllocationRejected() public {
        (, bytes32[] memory proof) = _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        // Alice tries to claim more than her allocation
        vm.expectRevert(ClaimModule.InvalidProof.selector);
        vm.prank(alice);
        cm.claim(AIRDROP_ID, ALLOCATION * 2, 0, CATEGORY, proof);
    }

    function test_security_wrongCategoryRejected() public {
        (, bytes32[] memory proof) = _createInstantAirdrop(AIRDROP_ID, alice, ALLOCATION, 0, CATEGORY);

        vm.expectRevert(ClaimModule.InvalidProof.selector);
        vm.prank(alice);
        cm.claim(AIRDROP_ID, ALLOCATION, 0, CATEGORY + 1, proof);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  13. FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function testFuzz_createAirdrop_uniqueIds(uint256 idA, uint256 idB) public {
        vm.assume(idA != 0 && idB != 0 && idA != idB);

        bytes32 leafA = _leaf(alice, ALLOCATION, 0, 1);
        bytes32 rootA = _singleLeafRoot(leafA);
        bytes32 leafB = _leaf(bob, ALLOCATION, 0, 2);
        bytes32 rootB = _singleLeafRoot(leafB);

        uint256 start = block.timestamp + 60;

        vm.startPrank(admin);
        cm.createAirdrop(idA, address(token), rootA, ALLOCATION, start, 0, 0);
        cm.createAirdrop(idB, address(token), rootB, ALLOCATION, start, 0, 0);
        vm.stopPrank();

        assertTrue(cm.exists(idA));
        assertTrue(cm.exists(idB));
    }

    function testFuzz_vestedAmount_neverExceedsAllocation(
        uint256 elapsed,
        uint256 alloc
    ) public {
        alloc   = bound(alloc,   1 ether, 1_000_000 ether);
        elapsed = bound(elapsed, 0,       10_000);

        bytes32 leaf  = _leaf(alice, alloc, 0, CATEGORY);
        bytes32 root  = _singleLeafRoot(leaf);
        uint256 start = block.timestamp + 10;

        vm.prank(admin);
        cm.createAirdrop(AIRDROP_ID, address(token), root, alloc, start, 0, DURATION);

        vm.warp(start + elapsed);
        uint256 vested = cm.vestedAmount(AIRDROP_ID, alloc);
        assertLe(vested, alloc);
    }

    function testFuzz_claim_cannotClaimMoreThanAllocation(uint256 alloc) public {
        alloc = bound(alloc, 1 ether, 100_000 ether);

        (, bytes32[] memory proof) = _createInstantAirdrop(AIRDROP_ID, alice, alloc, 0, CATEGORY);

        vm.prank(alice);
        cm.claim(AIRDROP_ID, alloc, 0, CATEGORY, proof);

        // claimed must never exceed allocation
        assertLe(cm.claimed(AIRDROP_ID, alice), alloc);
    }
}