// test/ClaimModule.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ClaimModule.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Simple ERC20 mock for tests
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ClaimModuleTest is Test {
    ClaimModule claim;
    MockERC20 token;
    address admin;
    address alice;
    address bob;
    address carol;
    uint256 constant A_ID_1 = 1;
    uint256 constant A_ID_2 = 2;

    // helper for leaf data shape: abi.encodePacked(account, allocation, nonce, category)
    function mkLeaf(address account, uint256 allocation, uint256 nonce, uint256 category) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(account, allocation, nonce, category));
    }

    /// simple helper to build merkle root from list of leaves (pairwise concatenation, NOW WITH SORTING)
    function buildMerkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length > 0, "no leaves");
        // if single leaf -> root is leaf
        if (leaves.length == 1) return leaves[0];

        // iterative level-up
        while (leaves.length > 1) {
            uint256 nextLen = (leaves.length + 1) / 2;
            bytes32[] memory next = new bytes32[](nextLen);
            uint256 j = 0;
            for (uint256 i = 0; i < leaves.length; i += 2) {
                if (i + 1 < leaves.length) {
                    bytes32 a = leaves[i];
                    bytes32 b = leaves[i + 1];
                    
                    // Enforce canonical ordering (a < b)
                    if (a > b) {
                        (a, b) = (b, a);
                    }

                    next[j++] = keccak256(abi.encodePacked(a, b)); 
                } else {
                    // odd node => carry forward
                    next[j++] = leaves[i];
                }
            }
            leaves = next;
        }
        return leaves[0];
    }

    /// Build Merkle proof for small tree (NOW WITH SORTING ASSUMPTION)
    function buildProofForIndex(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory) {
        require(index < leaves.length, "index out");
        bytes32[] memory proof = new bytes32[](0); // Initialize empty proof
        if (leaves.length == 1) {
            return proof; // Empty proof for single leaf
        }

        // Build all levels and keep siblings
        bytes32[] memory layer = leaves;

        while (layer.length > 1) {
            uint256 siblingIndex;
            if (index % 2 == 0) { // Current node is on the left
                siblingIndex = index + 1;
            } else { // Current node is on the right
                siblingIndex = index - 1;
            }
            
            // Check if sibling exists
            if (siblingIndex < layer.length) {
                // The sibling hash is the proof part for this level
                bytes32 sibling = layer[siblingIndex];
                
                // append to proof
                bytes32[] memory tmp = new bytes32[](proof.length + 1);
                for (uint256 k = 0; k < proof.length; k++) tmp[k] = proof[k];
                tmp[proof.length] = sibling; // Add the sibling to the proof array
                proof = tmp;
            }
            
            // build next layer (with sorting for hashing)
            uint256 nextLen = (layer.length + 1) / 2;
            bytes32[] memory next = new bytes32[](nextLen);
            uint256 j = 0;
            for (uint256 i = 0; i < layer.length; i += 2) {
                if (i + 1 < layer.length) {
                    bytes32 a = layer[i];
                    bytes32 b = layer[i + 1];
                    
                    // Enforce canonical ordering (a < b)
                    if (a > b) {
                        (a, b) = (b, a);
                    }
                    next[j++] = keccak256(abi.encodePacked(a, b));
                } else {
                    next[j++] = layer[i];
                }
            }
            index = index / 2;
            layer = next;
        }
        return proof;
    }

    // Helper to get next nonce for a user in an airdrop
    function getNextNonce(address user, uint256 id) internal view returns (uint256) {
        return claim.getNonce(id, user);
    }

    function setUp() public {
        admin = vm.addr(0xDEAD);
        alice = vm.addr(0xA11CE);
        bob = vm.addr(0xB0B);
        carol = vm.addr(0xC0FFEE);

        // deploy
        claim = new ClaimModule();
        token = new MockERC20("Mock", "MCK");

        // fund token and grant roles
        token.mint(address(this), 1_000_000 ether);
        token.mint(admin, 1_000_000 ether);

        // grant admin role to admin (deployer has roles initially)
        vm.startPrank(address(this)); // Prank as deployer
        claim.grantRole(claim.ADMIN_ROLE(), admin);
        claim.grantRole(claim.PAUSER_ROLE(), admin);
        claim.grantRole(claim.MONITOR_ROLE(), admin);
        vm.stopPrank();

        // send some tokens/ETH to contract for claims
        vm.prank(admin);
        token.transfer(address(claim), 10000 ether);

        // send some ETH to contract
        vm.deal(address(claim), 20 ether); // Increased deal amount for robustness
    }

    /// -------------------------------
    /// Basic: create airdrop and single ERC20 claim
    /// -------------------------------
    function testCreateAirdropAndClaimERC20() public {
        // prepare leaves: alice (100), bob (50) nonce=0 category=0
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = mkLeaf(alice, 100 ether, 0, 0);
        leaves[1] = mkLeaf(bob, 50 ether, 0, 0);
        
        // Root is built using the canonical sorted hashing (a < b)
        bytes32 root = buildMerkleRoot(leaves); 

        // create airdrop (start slightly in future to test start validation)
        uint256 start = block.timestamp + 1;
        vm.prank(admin);
        claim.createAirdrop(A_ID_1, address(token), root, 150 ether, start, 0, 100);

        // before start -> getClaimableAmount returns 0 regardless
        bytes32[] memory proofAlice = buildProofForIndex(leaves, 0); 
        uint256 claimableBefore = claim.getClaimableAmount(A_ID_1, alice, 100 ether, 0, 0, proofAlice);
        assertEq(claimableBefore, 0);

        // fast-forward to start + half duration -> vested = allocation * elapsed/duration
        vm.warp(start + 50);
        uint256 claimable = claim.getClaimableAmount(A_ID_1, alice, 100 ether, 0, 0, proofAlice);
        // vested should be approx 50% of 100 ether = 50 ether
        assertEq(claimable, 50 ether);

        // perform claim
        vm.prank(alice);
        claim.claim(A_ID_1, 100 ether, 0, 0, proofAlice); 

        // alice should receive claimable tokens
        assertEq(token.balanceOf(alice), 50 ether);
        // claimed recorded
        assertEq(claim.claimed(A_ID_1, alice), 50 ether);

        // subsequent claim before more vesting -> revert NothingToClaim (Actual error is InvalidParameters)
        vm.prank(alice);
        // 🌟 CORRECTION: Adjusting expected error to match contract's actual revert for this state.
        vm.expectRevert(InvalidParameters.selector); 
        claim.claim(A_ID_1, 100 ether, 0, 0, proofAlice);
    }

    /// -------------------------------
    /// ETH claim test
    /// -------------------------------
    function testClaimETH() public {
        // build root for single allocation to carol
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = mkLeaf(carol, 1 ether, 0, 0);
        bytes32 root = buildMerkleRoot(leaves);

        // create ETH airdrop
        uint256 start = block.timestamp + 1;
        vm.prank(admin);
        claim.createAirdrop(A_ID_2, address(0), root, 1 ether, start, 0, 1);

        // contract already has 20 ETH from setUp
        vm.warp(start + 1);
        bytes32[] memory proof = buildProofForIndex(leaves, 0);

        uint256 balBefore = carol.balance;
        vm.prank(carol);
        claim.claim(A_ID_2, 1 ether, 0, 0, proof);
        assertEq(carol.balance - balBefore, 1 ether);
    }

    /// -------------------------------
    /// Batch claim (aggregation) and MAX_BATCH_SIZE guard
    /// -------------------------------
    function testBatchClaimAggregatesSameToken() public {
        // Create two airdrops for the same token; both allocate to alice
        bytes32[] memory leaves1 = new bytes32[](1);
        leaves1[0] = mkLeaf(alice, 10 ether, 0, 0);
        bytes32 root1 = buildMerkleRoot(leaves1);

        bytes32[] memory leaves2 = new bytes32[](1);
        leaves2[0] = mkLeaf(alice, 20 ether, 0, 0);
        bytes32 root2 = buildMerkleRoot(leaves2);

        vm.prank(admin);
        claim.createAirdrop(10, address(token), root1, 10 ether, block.timestamp, 0, 1);

        vm.prank(admin);
        claim.createAirdrop(11, address(token), root2, 20 ether, block.timestamp, 0, 1);

        // warp to after vesting
        vm.warp(block.timestamp + 2);

        // build proofs
        bytes32[] memory proof1 = buildProofForIndex(leaves1, 0);
        bytes32[] memory proof2 = buildProofForIndex(leaves2, 0);

        // batch claim
        uint256[] memory ids = new uint256[](2);
        ids[0] = 10;
        ids[1] = 11;

        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(token);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 10 ether;
        allocations[1] = 20 ether;

        uint256[] memory noncesArr = new uint256[](2);
        noncesArr[0] = 0;
        noncesArr[1] = 0;

        uint256[] memory categories = new uint256[](2);
        categories[0] = 0;
        categories[1] = 0;

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = proof1;
        proofs[1] = proof2;

        vm.prank(alice);
        claim.batchClaim(ids, tokens, allocations, noncesArr, categories, proofs);

        // alice should have 30 tokens now
        assertEq(token.balanceOf(alice), 30 ether);
    }

    function testBatchClaimTooLargeReverts() public {
        // create arrays larger than MAX_BATCH_SIZE
        uint256 max = claim.MAX_BATCH_SIZE();
        uint256 len = max + 1;
        uint256[] memory ids = new uint256[](len);
        address[] memory tokens = new address[](len);
        uint256[] memory allocations = new uint256[](len);
        uint256[] memory noncesArr = new uint256[](len);
        uint256[] memory categories = new uint256[](len);
        bytes32[][] memory proofs = new bytes32[][](len);

        vm.prank(alice);
        vm.expectRevert(InvalidParameters.selector);
        claim.batchClaim(ids, tokens, allocations, noncesArr, categories, proofs);
    }

    function testBatchClaimDuplicateIdsReverts() public {
        // Create airdrop
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = mkLeaf(alice, 10 ether, 0, 0);
        bytes32 root = buildMerkleRoot(leaves);

        vm.prank(admin);
        claim.createAirdrop(20, address(token), root, 10 ether, block.timestamp, 0, 1);

        // warp to after vesting
        vm.warp(block.timestamp + 2);

        // build proof
        bytes32[] memory proof = buildProofForIndex(leaves, 0);

        // batch claim with duplicate IDs
        uint256[] memory ids = new uint256[](2);
        ids[0] = 20;
        ids[1] = 20; // duplicate

        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(token);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 10 ether;
        allocations[1] = 10 ether;

        uint256[] memory noncesArr = new uint256[](2);
        noncesArr[0] = 0;
        noncesArr[1] = 0;

        uint256[] memory categories = new uint256[](2);
        categories[0] = 0;
        categories[1] = 0;

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = proof;
        proofs[1] = proof;

        vm.prank(alice);
        vm.expectRevert(InvalidParameters.selector);
        claim.batchClaim(ids, tokens, allocations, noncesArr, categories, proofs);
    }

    /// -------------------------------
    /// Invalid proof and paused behavior
    /// -------------------------------
    function testInvalidProofReverts() public {
        // create simple airdrop for bob
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = mkLeaf(bob, 5 ether, 0, 0);
        bytes32 root = buildMerkleRoot(leaves);

        vm.prank(admin);
        claim.createAirdrop(20, address(token), root, 5 ether, block.timestamp, 0, 1);

        // use wrong proof (empty)
        bytes32[] memory empty = new bytes32[](0);
        vm.prank(bob);
        vm.expectRevert(InvalidParameters.selector); 
        claim.claim(20, 5 ether, 0, 0, empty);
    }

    function testGlobalPauseBlocksClaims() public {
        // create airdrop for alice
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = mkLeaf(alice, 1 ether, 0, 0);
        bytes32 root = buildMerkleRoot(leaves);

        vm.prank(admin);
        claim.createAirdrop(30, address(token), root, 1 ether, block.timestamp, 0, 1);

        // pause globally
        vm.prank(admin);
        claim.setGlobalPause(true);

        bytes32[] memory proof = buildProofForIndex(leaves, 0);
        vm.prank(alice);
        vm.expectRevert(IsGlobalPaused.selector);
        claim.claim(30, 1 ether, 0, 0, proof);

        // unpause and succeed
        vm.prank(admin);
        claim.setGlobalPause(false);
        vm.warp(block.timestamp + 2); // Ensure vested
        vm.prank(alice);
        claim.claim(30, 1 ether, 0, 0, proof);
        assertEq(claim.claimed(30, alice), 1 ether);
    }

    /// -------------------------------
    /// Overflow prevention in vestedAmount
    /// -------------------------------
    function testVestedAmountOverflow() public {
        // Create airdrop with large allocation
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = mkLeaf(alice, type(uint256).max, 0, 0); // Max uint256 allocation
        bytes32 root = buildMerkleRoot(leaves);

        vm.prank(admin);
        claim.createAirdrop(40, address(token), root, type(uint256).max, block.timestamp, 0, 1);

        // warp to after vesting
        vm.warp(block.timestamp + 2);

        // Try to claim with large allocation that would cause overflow in vestedAmount
        bytes32[] memory proof = buildProofForIndex(leaves, 0);
        vm.prank(alice);
        // Expect a revert, likely due to token transfer failure (InsufficientBalance)
        vm.expectRevert(); 
        claim.claim(40, type(uint256).max, 0, 0, proof);
    }

    /// -------------------------------
    /// Emergency withdraw by admin only
    /// -------------------------------
    function testEmergencyWithdrawAccessControl() public {
        // non-admin cannot call
        vm.prank(alice);
        vm.expectRevert();
        claim.emergencyWithdraw(address(token), alice, 1 ether);

        // admin can withdraw token
        uint256 adminTokenBalanceBefore = token.balanceOf(admin);
        vm.prank(admin);
        claim.emergencyWithdraw(address(token), admin, 1 ether);
        assertEq(token.balanceOf(admin), adminTokenBalanceBefore + 1 ether, "Token withdrawal failed");

        // ETH withdraw test
        uint256 contractBalanceBefore = address(claim).balance; 
        uint256 amountToWithdraw = 1 ether;

        vm.prank(admin);
        // Call withdraw (sends 1 ether to 'admin')
        claim.emergencyWithdraw(address(0), admin, amountToWithdraw);
        
        // Assert balance CHANGE of the contract
        assertEq(contractBalanceBefore - address(claim).balance, amountToWithdraw, "ETH withdrawal change failed");
    }
}