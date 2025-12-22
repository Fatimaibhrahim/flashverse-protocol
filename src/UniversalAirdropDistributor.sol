// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title UniversalAirdropDistributor
 * @notice Professional, gas-optimized contract for distributing ERC20, ERC721, and ERC1155 tokens.
 * @dev Supports universal airdrops (any token type per call), batch distributions, emergency withdrawals, and multiple token types.
 * Uses OpenZeppelin utilities for security and efficiency.
 */

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

contract UniversalAirdropDistributor is Ownable, ReentrancyGuard, ERC721Holder, ERC1155Holder {
    using SafeERC20 for IERC20;
    using Address for address;

    enum TokenType { ERC20, ERC721, ERC1155 }

    struct TokenInfo {
        address tokenAddress;
        TokenType tokenType;
    }

    TokenInfo public tokenInfo; 
    uint256 public maxBatchRecipients = 100;

    event AirdropExecuted(address indexed token, TokenType tokenType, address indexed recipient, uint256 amount, uint256 tokenId);
    event BatchAirdropExecuted(address indexed token, TokenType tokenType, uint256 totalRecipients, uint256 totalAmount);
    event ERC721BatchAirdropExecuted(address indexed token, uint256 totalRecipients, uint256 totalTokenIds);
    event EmergencyWithdrawal(address indexed owner, address indexed token, TokenType tokenType, uint256 amount, uint256 tokenId);
    event TokenInfoUpdated(address indexed newToken, TokenType tokenType);
    event MaxBatchRecipientsUpdated(uint256 newMax);

    /**
     * @notice CONSTRUCTOR: Sets the initial owner and the default token type/address.
     * @param initialOwner The address that will be the contract owner (inherits from Ownable).
     */
    constructor(address initialOwner, address _tokenAddress, TokenType _tokenType) 
        Ownable(initialOwner) // CORRECTED: Passes initialOwner to the Ownable base contract
    {
        require(_tokenAddress != address(0), "Invalid token address");
        require(_tokenType <= TokenType.ERC1155, "Invalid token type");
        tokenInfo = TokenInfo(_tokenAddress, _tokenType);
    }

    function updateTokenInfo(address _tokenAddress, TokenType _tokenType) external onlyOwner {
        require(_tokenAddress != address(0), "Invalid token address");
        require(_tokenType <= TokenType.ERC1155, "Invalid token type");
        tokenInfo = TokenInfo(_tokenAddress, _tokenType);
        emit TokenInfoUpdated(_tokenAddress, _tokenType);
    }

    function setMaxBatchRecipients(uint256 _max) external onlyOwner {
        require(_max > 0, "Max must be > 0");
        maxBatchRecipients = _max;
        emit MaxBatchRecipientsUpdated(_max);
    }

    function airdrop(
        address tokenAddress,
        TokenType tokenType,
        address recipient,
        uint256 amountOrTokenId,
        uint256 tokenId
    ) external onlyOwner nonReentrant {
        require(tokenAddress != address(0), "Invalid token address");
        require(recipient != address(0), "Zero address");
        require(amountOrTokenId > 0, "Zero amount/id");
        require(tokenType <= TokenType.ERC1155, "Invalid token type");

        uint256 amount;
        uint256 actualTokenId;

        if (tokenType == TokenType.ERC20) {
            amount = amountOrTokenId;
            actualTokenId = 0;
        } else if (tokenType == TokenType.ERC1155) {
            amount = amountOrTokenId;
            actualTokenId = tokenId;
            require(actualTokenId > 0, "Token ID required for ERC1155");
        } else { // ERC721
            amount = 1;
            actualTokenId = amountOrTokenId;
            require(actualTokenId > 0, "Token ID required for ERC721");
        }

        _checkBalance(tokenAddress, tokenType, amount, actualTokenId);
        _transferFromSenderToContract(tokenAddress, tokenType, amount, actualTokenId);
        _transferFromContractToRecipient(tokenAddress, tokenType, recipient, amount, actualTokenId);

        emit AirdropExecuted(tokenAddress, tokenType, recipient, amount, actualTokenId);
    }

    function batchAirdrop(
        address tokenAddress,
        TokenType tokenType,
        address[] calldata recipients,
        uint256[] calldata amounts,
        uint256[] calldata tokenIds
    ) external onlyOwner nonReentrant {
        require(tokenAddress != address(0), "Invalid token address");
        require(tokenType == TokenType.ERC20 || tokenType == TokenType.ERC1155, "Use batchAirdropERC721 for ERC721");
        uint256 length = recipients.length;
        require(length == amounts.length, "Array length mismatch");
        require(length > 0 && length <= maxBatchRecipients, "Invalid recipients count");
        if (tokenType == TokenType.ERC1155) {
            require(length == tokenIds.length, "TokenIds array length mismatch");
        }

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < length; i++) {
            require(recipients[i] != address(0), "Zero address");
            require(amounts[i] > 0, "Zero amount");
            if (tokenType == TokenType.ERC1155) {
                require(tokenIds[i] > 0, "Token ID required for ERC1155");
            }
            totalAmount += amounts[i];
        }

        if (tokenType == TokenType.ERC20) {
            _checkBalance(tokenAddress, tokenType, totalAmount, 0);
            _transferFromSenderToContract(tokenAddress, tokenType, totalAmount, 0);
        } else { // ERC1155
            for (uint256 i = 0; i < length; i++) {
                _checkBalance(tokenAddress, tokenType, amounts[i], tokenIds[i]);
                _transferFromSenderToContract(tokenAddress, tokenType, amounts[i], tokenIds[i]);
            }
        }

        for (uint256 i = 0; i < length; i++) {
            uint256 useTokenId = (tokenType == TokenType.ERC20) ? 0 : tokenIds[i];
            _transferFromContractToRecipient(tokenAddress, tokenType, recipients[i], amounts[i], useTokenId);
            emit AirdropExecuted(tokenAddress, tokenType, recipients[i], amounts[i], useTokenId);
        }

        emit BatchAirdropExecuted(tokenAddress, tokenType, length, totalAmount);
    }

    function batchAirdropERC721(
        address tokenAddress,
        address[] calldata recipients,
        uint256[] calldata tokenIds
    ) external onlyOwner nonReentrant {
        require(tokenAddress != address(0), "Invalid token address");
        uint256 length = recipients.length;
        require(length == tokenIds.length, "Array length mismatch");
        require(length > 0 && length <= maxBatchRecipients, "Invalid recipients count");

        for (uint256 i = 0; i < length; i++) {
            require(recipients[i] != address(0), "Zero address");
            require(tokenIds[i] > 0, "Zero Token ID");

            _checkBalance(tokenAddress, TokenType.ERC721, 1, tokenIds[i]);
            _transferFromSenderToContract(tokenAddress, TokenType.ERC721, 1, tokenIds[i]);
            _transferFromContractToRecipient(tokenAddress, TokenType.ERC721, recipients[i], 1, tokenIds[i]);

            emit AirdropExecuted(tokenAddress, TokenType.ERC721, recipients[i], 1, tokenIds[i]);
        }

        emit ERC721BatchAirdropExecuted(tokenAddress, length, length);
    }

    function emergencyWithdraw(
        address tokenAddress,
        TokenType tokenType,
        uint256 amount,
        uint256 tokenId
    ) external onlyOwner nonReentrant {
        require(tokenAddress != address(0), "Invalid token address");
        require(amount > 0, "Zero amount");
        if (tokenType == TokenType.ERC721) {
            require(amount == 1, "ERC721 amount must be 1");
            require(tokenId > 0, "Token ID required");
        }
        _checkContractBalance(tokenAddress, tokenType, amount, tokenId);
        _transferFromContractToOwner(tokenAddress, tokenType, amount, tokenId);
        emit EmergencyWithdrawal(owner(), tokenAddress, tokenType, amount, tokenId);
    }

    function withdrawAll(
        address tokenAddress,
        TokenType tokenType,
        uint256 tokenId
    ) external onlyOwner nonReentrant {
        require(tokenAddress != address(0), "Invalid token address");
        require(tokenType != TokenType.ERC721, "Use emergencyWithdraw with specific tokenId for ERC721");
        uint256 balance = contractBalance(tokenAddress, tokenType, tokenId);
        require(balance > 0, "No tokens to withdraw");
        _transferFromContractToOwner(tokenAddress, tokenType, balance, tokenId);
        emit EmergencyWithdrawal(owner(), tokenAddress, tokenType, balance, tokenId);
    }

    function contractBalance(
        address tokenAddress,
        TokenType tokenType,
        uint256 tokenId
    ) public view returns (uint256) {
        require(tokenAddress != address(0), "Invalid token address");
        if (tokenType == TokenType.ERC20) {
            return IERC20(tokenAddress).balanceOf(address(this));
        } else if (tokenType == TokenType.ERC721) {
            return IERC721(tokenAddress).balanceOf(address(this)); 
        } else {
            require(tokenId > 0, "Token ID required for ERC1155 balance");
            return IERC1155(tokenAddress).balanceOf(address(this), tokenId);
        }
    }

    // --- Internal Transfer Functions ---
    function _transferFromSenderToContract(
        address tokenAddress,
        TokenType tokenType,
        uint256 amount,
        uint256 tokenId
    ) internal {
        if (tokenType == TokenType.ERC20) {
            IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        } else if (tokenType == TokenType.ERC721) {
            IERC721(tokenAddress).safeTransferFrom(msg.sender, address(this), tokenId);
        } else {
            IERC1155(tokenAddress).safeTransferFrom(msg.sender, address(this), tokenId, amount, "");
        }
    }

    function _transferFromContractToRecipient(
        address tokenAddress,
        TokenType tokenType,
        address recipient,
        uint256 amount,
        uint256 tokenId
    ) internal {
        if (tokenType == TokenType.ERC20) {
            IERC20(tokenAddress).safeTransfer(recipient, amount);
        } else if (tokenType == TokenType.ERC721) {
            IERC721(tokenAddress).safeTransferFrom(address(this), recipient, tokenId);
        } else {
            IERC1155(tokenAddress).safeTransferFrom(address(this), recipient, tokenId, amount, "");
        }
    }

    function _transferFromContractToOwner(
        address tokenAddress,
        TokenType tokenType,
        uint256 amount,
        uint256 tokenId
    ) internal {
        if (tokenType == TokenType.ERC20) {
            IERC20(tokenAddress).safeTransfer(owner(), amount);
        } else if (tokenType == TokenType.ERC721) {
            IERC721(tokenAddress).safeTransferFrom(address(this), owner(), tokenId);
        } else {
            IERC1155(tokenAddress).safeTransferFrom(address(this), owner(), tokenId, amount, "");
        }
    }

    // --- Internal Balance Checks ---
    function _checkBalance(
        address tokenAddress,
        TokenType tokenType,
        uint256 amount,
        uint256 tokenId
    ) internal view {
        if (tokenType == TokenType.ERC20) {
            require(IERC20(tokenAddress).balanceOf(msg.sender) >= amount, "Insufficient ERC20 balance");
        } else if (tokenType == TokenType.ERC721) {
            require(IERC721(tokenAddress).ownerOf(tokenId) == msg.sender, "Sender does not own NFT ID");
        } else {
            require(IERC1155(tokenAddress).balanceOf(msg.sender, tokenId) >= amount, "Insufficient ERC1155 tokens");
        }
    }

    function _checkContractBalance(
        address tokenAddress,
        TokenType tokenType,
        uint256 amount,
        uint256 tokenId
    ) internal view {
        if (tokenType == TokenType.ERC20) {
            require(IERC20(tokenAddress).balanceOf(address(this)) >= amount, "Insufficient contract ERC20 balance");
        } else if (tokenType == TokenType.ERC721) {
            require(IERC721(tokenAddress).ownerOf(tokenId) == address(this), "Contract does not own NFT ID");
        } else {
            require(IERC1155(tokenAddress).balanceOf(address(this), tokenId) >= amount, "Insufficient contract ERC1155 tokens");
        }
    }
}