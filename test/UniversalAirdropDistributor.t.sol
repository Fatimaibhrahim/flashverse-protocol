// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  UniversalAirdropDistributor — Full Test Suite
 * @notice Zero external Merkle dependencies.
 * Merkle trees are built manually inside the test using
 * the same double-hash formula as the contract.
 *
 * @dev    Run:  forge test -vvv
 * Fuzz: forge test --fuzz-runs 1000
 */

import {Test, console2}              from "forge-std/Test.sol";
import {UniversalAirdropDistributor} from "../src/UniversalAirdropDistributor.sol";

// ─────────────────────────────────────────────────────────────
//  OZ v5 removed ERC20Mock / ERC721Mock / ERC1155Mock from the
//  public package. We roll our own minimal versions here.
// ─────────────────────────────────────────────────────────────
import {ERC20}   from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721}  from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

contract ERC20Mock is ERC20 {
    constructor() ERC20("MockToken", "MCK") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ERC721Mock is ERC721 {
    constructor(string memory name, string memory symbol) ERC721(name, symbol) {}
    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

contract ERC1155Mock is ERC1155 {
    constructor(string memory uri) ERC1155(uri) {}
    function mint(address to, uint256 id, uint256 amount, bytes memory data) external {
        _mint(to, id, amount, data);
    }
}

// ─── Custom errors (mirror contract — lets us use .selector) ───
error UAD__ZeroAddress();
error UAD__ZeroAmount();
error UAD__ZeroTokenId();
error UAD__InvalidTokenType();
error UAD__ArrayLengthMismatch();
error UAD__BatchTooLarge(uint256 given, uint256 max);
error UAD__BatchEmpty();
error UAD__InsufficientBalance(address token, uint256 required, uint256 available);
error UAD__NotTokenOwner(address token, uint256 tokenId);
error UAD__ERC721AmountMustBeOne();
error UAD__UseERC721BatchFunction();
error UAD__UseEmergencyWithdrawForERC721();
error UAD__NothingToWithdraw();
error UAD__AlreadyClaimed(uint256 campaignId, address claimant);
error UAD__InvalidMerkleProof();
error UAD__CampaignNotActive();
error UAD__MaxBatchMustBePositive();

/*//////////////////////////////////////////////////////////////
            INLINE MERKLE HELPER (no external lib)
//////////////////////////////////////////////////////////////*/

library MerkleHelper {
    function buildTree(bytes32[] memory leaves)
        internal
        pure
        returns (bytes32 root, bytes32[] memory paddedLeaves)
    {
        uint256 n = _nextPow2(leaves.length);
        paddedLeaves = new bytes32[](n);

        for (uint256 i; i < leaves.length; i++) paddedLeaves[i] = leaves[i];
        for (uint256 i = leaves.length; i < n; i++) paddedLeaves[i] = leaves[leaves.length - 1];

        bytes32[] memory tree = paddedLeaves;
        while (tree.length > 1) {
            uint256 half = tree.length / 2;
            bytes32[] memory next = new bytes32[](half);
            for (uint256 i; i < half; i++) {
                next[i] = _hashPair(tree[2 * i], tree[2 * i + 1]);
            }
            tree = next;
        }
        root = tree[0];
    }

    function getProof(bytes32[] memory paddedLeaves, uint256 index)
        internal
        pure
        returns (bytes32[] memory proof)
    {
        uint256 n = paddedLeaves.length;
        uint256 depth;
        uint256 tmp = n;
        while (tmp > 1) { tmp >>= 1; depth++; }

        proof = new bytes32[](depth);
        bytes32[] memory layer = paddedLeaves;

        for (uint256 d; d < depth; d++) {
            uint256 sibling = (index % 2 == 0) ? index + 1 : index - 1;
            proof[d] = layer[sibling];
            uint256 half = layer.length / 2;
            bytes32[] memory next = new bytes32[](half);
            for (uint256 i; i < half; i++) {
                next[i] = _hashPair(layer[2 * i], layer[2 * i + 1]);
            }
            layer = next;
            index >>= 1;
        }
    }

    function makeLeaf(address addr, uint256 amount, uint256 tokenId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(bytes.concat(keccak256(abi.encodePacked(addr, amount, tokenId))));
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _nextPow2(uint256 x) private pure returns (uint256 n) {
        n = 1;
        while (n < x) n <<= 1;
    }
}

/*//////////////////////////////////////////////////////////////
                        TEST CONTRACT
//////////////////////////////////////////////////////////////*/

contract UniversalAirdropDistributorTest is Test {
    using MerkleHelper for bytes32[];

    UniversalAirdropDistributor public distributor;
    ERC20Mock                   public erc20;
    ERC721Mock                  public erc721;
    ERC1155Mock                 public erc1155;

    address public owner   = makeAddr("owner");
    address public alice   = makeAddr("alice");
    address public bob     = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    uint256 constant MINT_AMOUNT = 1_000_000e18;
    uint256 constant DROP_AMT    = 100e18;

    function setUp() public {
        vm.startPrank(owner);
        distributor = new UniversalAirdropDistributor(owner);
        erc20       = new ERC20Mock();
        erc721      = new ERC721Mock("TestNFT", "TNFT");
        erc1155     = new ERC1155Mock("");

        erc20.mint(owner, MINT_AMOUNT);
        erc1155.mint(owner, 1, 1_000, "");
        for (uint256 i = 1; i <= 10; i++) erc721.mint(owner, i);

        erc20.approve(address(distributor), type(uint256).max);
        erc721.setApprovalForAll(address(distributor), true);
        erc1155.setApprovalForAll(address(distributor), true);
        vm.stopPrank();
    }

    // ─── Tests ───

    function test_SingleAirdrop_ERC20_TransfersCorrectly() public {
        vm.prank(owner);
        distributor.airdropSingle(address(erc20), UniversalAirdropDistributor.TokenType.ERC20, alice, DROP_AMT, 0);
        assertEq(erc20.balanceOf(alice), DROP_AMT);
    }

    function test_SingleAirdrop_ERC721_TransfersNFT() public {
        vm.prank(owner);
        distributor.airdropSingle(address(erc721), UniversalAirdropDistributor.TokenType.ERC721, alice, 1, 1);
        assertEq(erc721.ownerOf(1), alice);
    }

    function test_BatchAirdrop_ERC20_AllBalancesCorrect() public {
        UniversalAirdropDistributor.AirdropEntry[] memory entries = new UniversalAirdropDistributor.AirdropEntry[](2);
        entries[0] = UniversalAirdropDistributor.AirdropEntry(alice, 100e18, 0);
        entries[1] = UniversalAirdropDistributor.AirdropEntry(bob, 200e18, 0);

        vm.prank(owner);
        distributor.batchAirdrop(address(erc20), UniversalAirdropDistributor.TokenType.ERC20, entries);

        assertEq(erc20.balanceOf(alice), 100e18);
        assertEq(erc20.balanceOf(bob), 200e18);
    }

    function test_Merkle_ClaimSuccessfully() public {
        address[] memory recipients = new address[](2);
        recipients[0] = alice; recipients[1] = bob;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18; amounts[1] = 200e18;

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = MerkleHelper.makeLeaf(alice, 100e18, 0);
        leaves[1] = MerkleHelper.makeLeaf(bob, 200e18, 0);

        (bytes32 root, bytes32[] memory padded) = MerkleHelper.buildTree(leaves);
        bytes32[] memory proofAlice = MerkleHelper.getProof(padded, 0);

        vm.prank(owner);
        uint256 cid = distributor.createMerkleCampaign(address(erc20), UniversalAirdropDistributor.TokenType.ERC20, root, 300e18, 0);

        vm.prank(alice);
        distributor.claimMerkle(cid, 100e18, 0, proofAlice);
        assertEq(erc20.balanceOf(alice), 100e18);
    }

    function test_Revert_SingleAirdrop_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert(); // Should revert due to Ownable
        distributor.airdropSingle(address(erc20), UniversalAirdropDistributor.TokenType.ERC20, bob, DROP_AMT, 0);
    }

    function test_EmergencyWithdraw_ERC20() public {
        vm.prank(owner);
        erc20.transfer(address(distributor), 500e18);
        
        vm.prank(owner);
        distributor.emergencyWithdraw(address(erc20), UniversalAirdropDistributor.TokenType.ERC20, 500e18, 0);
        assertEq(erc20.balanceOf(owner), MINT_AMOUNT);
    }
}