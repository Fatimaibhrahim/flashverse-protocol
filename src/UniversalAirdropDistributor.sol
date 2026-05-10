// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  UniversalAirdropDistributor v2.1
 * @author FlashVerse Team
 * @notice Production-grade contract for ERC20 / ERC721 / ERC1155 airdrops.
 * Supports single, batch, and Merkle-proof-gated distributions.
 *
 * @dev    Architecture decisions:
 * ─ OpenZeppelin v5 only (no external Merkle lib needed)
 * ─ Custom errors  → cheaper gas than require strings
 * ─ SafeERC20      → handles non-standard ERC20 tokens safely
 * ─ ReentrancyGuard + Pausable → layered security
 * ─ Merkle lane uses OZ MerkleProof (battle-tested, audited)
 * ─ ERC721 gets its own batch function (different transfer semantics)
 * ─ All leaf hashing: keccak256(keccak256(...)) to prevent second
 * pre-image attacks (same pattern as OZ MerkleProof docs)
 */

import {Ownable}         from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable}        from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof}     from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {SafeERC20}       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721Holder}    from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder}   from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721}         from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155}        from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/*//////////////////////////////////////////////////////////////
                        CUSTOM ERRORS
//////////////////////////////////////////////////////////////*/

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
                    UNIVERSAL AIRDROP DISTRIBUTOR
//////////////////////////////////////////////////////////////*/

contract UniversalAirdropDistributor is
    Ownable,
    Pausable,
    ReentrancyGuard,
    ERC721Holder,
    ERC1155Holder
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Supported token standards
    enum TokenType { ERC20, ERC721, ERC1155 }

    /// @notice One entry in a batch airdrop
    struct AirdropEntry {
        address recipient; // Who receives
        uint256 amount;    // ERC20 / ERC1155 quantity  |  ignored for ERC721
        uint256 tokenId;   // ERC721 / ERC1155 token ID |  ignored for ERC20
    }

    /// @notice A registered Merkle drop campaign
    struct MerkleCampaign {
        address   token;
        TokenType tokenType;
        bytes32   root;
        uint256   totalBudget;
        uint256   claimed;
        bool      active;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum recipients per batch call (gas-safety valve)
    uint256 public maxBatchSize = 200;

    /// @notice Merkle campaigns, keyed by campaign ID
    mapping(uint256 => MerkleCampaign) public campaigns;
    uint256 public nextCampaignId;

    /// @notice campaignId => claimant => claimed?
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event SingleAirdrop(
        address   indexed token,
        TokenType indexed tokenType,
        address   indexed recipient,
        uint256           amount,
        uint256           tokenId
    );

    event BatchAirdrop(
        address   indexed token,
        TokenType indexed tokenType,
        uint256           recipientCount,
        uint256           totalAmount
    );

    event MerkleCampaignCreated(
        uint256   indexed campaignId,
        address   indexed token,
        TokenType         tokenType,
        bytes32           root,
        uint256           totalBudget
    );

    event MerkleClaimed(
        uint256 indexed campaignId,
        address indexed claimant,
        uint256         amount,
        uint256         tokenId
    );

    event EmergencyWithdraw(
        address   indexed token,
        TokenType         tokenType,
        address   indexed to,
        uint256           amount,
        uint256           tokenId
    );

    event MaxBatchSizeUpdated(uint256 oldMax, uint256 newMax);

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param initialOwner Address that owns the contract.
     */
    constructor(address initialOwner) Ownable(initialOwner) {}

    /*//////////////////////////////////////////////////////////////
                        ADMIN: CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update the per-call recipient cap.
     * @param newMax Must be > 0.
     */
    function setMaxBatchSize(uint256 newMax) external onlyOwner {
        if (newMax == 0) revert UAD__MaxBatchMustBePositive();
        emit MaxBatchSizeUpdated(maxBatchSize, newMax);
        maxBatchSize = newMax;
    }

    /// @notice Pause all state-changing functions (emergency brake).
    function pause()   external onlyOwner { _pause();   }

    /// @notice Resume operations.
    function unpause() external onlyOwner { _unpause(); }

    /*//////////////////////////////////////////////////////////////
                        CORE: SINGLE AIRDROP
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Send tokens to one recipient.
     *
     * @param token      Token contract address.
     * @param tokenType  ERC20 | ERC721 | ERC1155.
     * @param recipient  Destination address.
     * @param amount     ERC20 → quantity.
     * ERC721 → must be 1 (auto-normalised).
     * ERC1155 → quantity of `tokenId`.
     * @param tokenId    ERC20 → ignored (pass 0).
     * ERC721 / ERC1155 → the token ID to transfer.
     */
    function airdropSingle(
        address   token,
        TokenType tokenType,
        address   recipient,
        uint256   amount,
        uint256   tokenId
    )
        external
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        _validateToken(token, tokenType);
        _validateRecipient(recipient);

        if (tokenType == TokenType.ERC20) {
            if (amount == 0) revert UAD__ZeroAmount();
        } else if (tokenType == TokenType.ERC721) {
            if (tokenId == 0) revert UAD__ZeroTokenId();
            amount = 1;
        } else {
            if (tokenId == 0) revert UAD__ZeroTokenId();
            if (amount  == 0) revert UAD__ZeroAmount();
        }

        _pullFromSender(token, tokenType, amount, tokenId);
        _pushToAddress(token, tokenType, recipient, amount, tokenId);

        emit SingleAirdrop(token, tokenType, recipient, amount, tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                CORE: BATCH AIRDROP (ERC20 / ERC1155)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Send tokens to multiple recipients in one call.
     * ERC721 must use `batchAirdropERC721` instead.
     */
    function batchAirdrop(
        address            token,
        TokenType          tokenType,
        AirdropEntry[] calldata entries
    )
        external
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        if (tokenType == TokenType.ERC721) revert UAD__UseERC721BatchFunction();
        _validateToken(token, tokenType);

        uint256 len = entries.length;
        if (len == 0)           revert UAD__BatchEmpty();
        if (len > maxBatchSize) revert UAD__BatchTooLarge(len, maxBatchSize);

        uint256 totalAmount;

        for (uint256 i; i < len; ++i) {
            _validateRecipient(entries[i].recipient);
            if (entries[i].amount == 0) revert UAD__ZeroAmount();
            if (tokenType == TokenType.ERC1155 && entries[i].tokenId == 0)
                revert UAD__ZeroTokenId();
            totalAmount += entries[i].amount;
        }

        // Pull in bulk for ERC20, per-item for ERC1155
        if (tokenType == TokenType.ERC20) {
            _checkSenderERC20Balance(token, totalAmount);
            IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);
        } else {
            for (uint256 i; i < len; ++i) {
                _pullFromSender(token, TokenType.ERC1155, entries[i].amount, entries[i].tokenId);
            }
        }

        for (uint256 i; i < len; ++i) {
            uint256 tid = (tokenType == TokenType.ERC20) ? 0 : entries[i].tokenId;
            _pushToAddress(token, tokenType, entries[i].recipient, entries[i].amount, tid);
            emit SingleAirdrop(token, tokenType, entries[i].recipient, entries[i].amount, tid);
        }

        emit BatchAirdrop(token, tokenType, len, totalAmount);
    }

    /*//////////////////////////////////////////////////////////////
                    CORE: BATCH AIRDROP (ERC721)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transfer multiple ERC721 tokens to individual recipients.
     * @param token       ERC721 contract address.
     * @param recipients  Array of destination addresses.
     * @param tokenIds    Array of token IDs (1-to-1 with recipients).
     */
    function batchAirdropERC721(
        address           token,
        address[] calldata recipients,
        uint256[] calldata tokenIds
    )
        external
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        if (token == address(0)) revert UAD__ZeroAddress();

        uint256 len = recipients.length;
        if (len == 0)               revert UAD__BatchEmpty();
        if (len > maxBatchSize)     revert UAD__BatchTooLarge(len, maxBatchSize);
        if (len != tokenIds.length) revert UAD__ArrayLengthMismatch();

        for (uint256 i; i < len; ++i) {
            _validateRecipient(recipients[i]);
            if (tokenIds[i] == 0) revert UAD__ZeroTokenId();

            if (IERC721(token).ownerOf(tokenIds[i]) != msg.sender)
                revert UAD__NotTokenOwner(token, tokenIds[i]);

            IERC721(token).safeTransferFrom(msg.sender, recipients[i], tokenIds[i]);
            emit SingleAirdrop(token, TokenType.ERC721, recipients[i], 1, tokenIds[i]);
        }

        emit BatchAirdrop(token, TokenType.ERC721, len, len);
    }

    /*//////////////////////////////////////////////////////////////
                MERKLE DROP — TRUSTLESS CLAIM LANE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register a new Merkle-gated airdrop campaign.
     *
     * @dev    Leaf format (double-hashed to prevent second pre-image attacks):
     * leaf = keccak256(keccak256(abi.encodePacked(claimant, amount, tokenId)))
     *
     * Build the tree off-chain with any standard Merkle library
     * using the same leaf formula.
     *
     * @param token       Token to distribute.
     * @param tokenType   ERC20 | ERC721 | ERC1155.
     * @param merkleRoot  Root of the off-chain constructed Merkle tree.
     * @param totalBudget Total tokens locked into this campaign.
     * @param tokenId     ERC1155 token ID (pass 0 for ERC20).
     * @return campaignId Newly assigned campaign identifier.
     */
    function createMerkleCampaign(
        address   token,
        TokenType tokenType,
        bytes32   merkleRoot,
        uint256   totalBudget,
        uint256   tokenId
    )
        external
        onlyOwner
        nonReentrant
        whenNotPaused
        returns (uint256 campaignId)
    {
        _validateToken(token, tokenType);
        if (totalBudget == 0) revert UAD__ZeroAmount();

        _pullFromSender(token, tokenType, totalBudget, tokenId);

        campaignId = nextCampaignId++;
        campaigns[campaignId] = MerkleCampaign({
            token:       token,
            tokenType:   tokenType,
            root:        merkleRoot,
            totalBudget: totalBudget,
            claimed:     0,
            active:      true
        });

        emit MerkleCampaignCreated(campaignId, token, tokenType, merkleRoot, totalBudget);
    }

    /**
     * @notice Claim tokens from a Merkle campaign.
     *
     * @dev    Leaf is double-hashed: keccak256(keccak256(abi.encodePacked(msg.sender, amount, tokenId)))
     *
     * @param campaignId  The campaign to claim from.
     * @param amount      Amount allocated to msg.sender in the tree.
     * @param tokenId     ERC1155 token ID (pass 0 for ERC20).
     * @param proof       Merkle proof for this claim.
     */
    function claimMerkle(
        uint256            campaignId,
        uint256            amount,
        uint256            tokenId,
        bytes32[] calldata proof
    )
        external
        nonReentrant
        whenNotPaused
    {
        MerkleCampaign storage campaign = campaigns[campaignId];

        if (!campaign.active)
            revert UAD__CampaignNotActive();

        if (hasClaimed[campaignId][msg.sender])
            revert UAD__AlreadyClaimed(campaignId, msg.sender);

        // Double-hash leaf: prevents second pre-image attacks
        bytes32 leaf = keccak256(
            bytes.concat(keccak256(abi.encodePacked(msg.sender, amount, tokenId)))
        );

        if (!MerkleProof.verify(proof, campaign.root, leaf))
            revert UAD__InvalidMerkleProof();

        hasClaimed[campaignId][msg.sender] = true;
        campaign.claimed += amount;

        _pushToAddress(campaign.token, campaign.tokenType, msg.sender, amount, tokenId);

        emit MerkleClaimed(campaignId, msg.sender, amount, tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                    EMERGENCY: RECOVERY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Recover a specific ERC20 or ERC1155 amount from the contract.
     * For ERC721 use `emergencyWithdrawERC721`.
     */
    function emergencyWithdraw(
        address   token,
        TokenType tokenType,
        uint256   amount,
        uint256   tokenId
    )
        external
        onlyOwner
        nonReentrant
    {
        if (tokenType == TokenType.ERC721) revert UAD__UseEmergencyWithdrawForERC721();
        if (token  == address(0)) revert UAD__ZeroAddress();
        if (amount == 0)          revert UAD__ZeroAmount();

        _checkContractBalance(token, tokenType, amount, tokenId);
        _pushToAddress(token, tokenType, owner(), amount, tokenId);

        emit EmergencyWithdraw(token, tokenType, owner(), amount, tokenId);
    }

    /**
     * @notice Recover a specific ERC721 token held by this contract.
     */
    function emergencyWithdrawERC721(
        address token,
        uint256 tokenId
    )
        external
        onlyOwner
        nonReentrant
    {
        if (token   == address(0)) revert UAD__ZeroAddress();
        if (tokenId == 0)          revert UAD__ZeroTokenId();
        if (IERC721(token).ownerOf(tokenId) != address(this))
            revert UAD__NotTokenOwner(token, tokenId);

        IERC721(token).safeTransferFrom(address(this), owner(), tokenId);
        emit EmergencyWithdraw(token, TokenType.ERC721, owner(), 1, tokenId);
    }

    /**
     * @notice Drain the contract's entire balance of an ERC20 or ERC1155 token.
     */
    function withdrawAll(
        address   token,
        TokenType tokenType,
        uint256   tokenId
    )
        external
        onlyOwner
        nonReentrant
    {
        if (tokenType == TokenType.ERC721) revert UAD__UseEmergencyWithdrawForERC721();
        if (token == address(0)) revert UAD__ZeroAddress();

        uint256 bal = contractBalance(token, tokenType, tokenId);
        if (bal == 0) revert UAD__NothingToWithdraw();

        _pushToAddress(token, tokenType, owner(), bal, tokenId);
        emit EmergencyWithdraw(token, tokenType, owner(), bal, tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the contract's current token balance.
     */
    function contractBalance(
        address   token,
        TokenType tokenType,
        uint256   tokenId
    ) public view returns (uint256) {
        if (token == address(0)) revert UAD__ZeroAddress();
        if (tokenType == TokenType.ERC20)
            return IERC20(token).balanceOf(address(this));
        if (tokenType == TokenType.ERC721)
            return IERC721(token).balanceOf(address(this));
        if (tokenId == 0) revert UAD__ZeroTokenId();
        return IERC1155(token).balanceOf(address(this), tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                    PRIVATE: TRANSFER HELPERS
    //////////////////////////////////////////////////////////////*/

    function _pullFromSender(
        address   token,
        TokenType tokenType,
        uint256   amount,
        uint256   tokenId
    ) private {
        if (tokenType == TokenType.ERC20) {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        } else if (tokenType == TokenType.ERC721) {
            IERC721(token).safeTransferFrom(msg.sender, address(this), tokenId);
        } else {
            IERC1155(token).safeTransferFrom(msg.sender, address(this), tokenId, amount, "");
        }
    }

    function _pushToAddress(
        address   token,
        TokenType tokenType,
        address   to,
        uint256   amount,
        uint256   tokenId
    ) private {
        if (tokenType == TokenType.ERC20) {
            IERC20(token).safeTransfer(to, amount);
        } else if (tokenType == TokenType.ERC721) {
            IERC721(token).safeTransferFrom(address(this), to, tokenId);
        } else {
            IERC1155(token).safeTransferFrom(address(this), to, tokenId, amount, "");
        }
    }

    /*//////////////////////////////////////////////////////////////
                    PRIVATE: VALIDATION HELPERS
    //////////////////////////////////////////////////////////////*/

    function _validateToken(address token, TokenType tokenType) private pure {
        if (token == address(0))   revert UAD__ZeroAddress();
        if (uint8(tokenType) > 2)  revert UAD__InvalidTokenType();
    }

    function _validateRecipient(address recipient) private pure {
        if (recipient == address(0)) revert UAD__ZeroAddress();
    }

    function _checkSenderERC20Balance(address token, uint256 amount) private view {
        uint256 bal = IERC20(token).balanceOf(msg.sender);
        if (bal < amount) revert UAD__InsufficientBalance(token, amount, bal);
    }

    function _checkContractBalance(
        address   token,
        TokenType tokenType,
        uint256   amount,
        uint256   tokenId
    ) private view {
        if (tokenType == TokenType.ERC20) {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal < amount) revert UAD__InsufficientBalance(token, amount, bal);
        } else if (tokenType == TokenType.ERC721) {
            if (IERC721(token).ownerOf(tokenId) != address(this))
                revert UAD__NotTokenOwner(token, tokenId);
        } else {
            uint256 bal = IERC1155(token).balanceOf(address(this), tokenId);
            if (bal < amount) revert UAD__InsufficientBalance(token, amount, bal);
        }
    }
}