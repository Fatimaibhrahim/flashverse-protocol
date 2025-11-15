// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Imports organized and from OpenZeppelin (global standards)
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockERC20
 * @dev ERC20 token with custom decimals, restricted minting, and burning.
 * Suitable for testing or production with security enhancements.
 * Supports global projects with audits.
 */
contract MockERC20 is ERC20, Ownable {
    uint8 private immutable _decimals;

    // Event to track minting
    event Minted(address indexed to, uint256 amount);

    /**
     * @dev Constructor to create the token.
     * @param name_ Name of the token.
     * @param symbol_ Symbol of the token.
     * @param decimals_ Number of decimal places (e.g., 18 for ETH).
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        _decimals = decimals_;
    }

    /**
     * @dev Returns the number of decimal places.
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /**
     * @dev Mint new tokens (restricted to owner only).
     * @param to Address to receive the tokens.
     * @param amount Amount to mint.
     */
    function mint(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "ERC20: mint to the zero address");
        require(amount > 0, "Amount must be greater than zero");
        _mint(to, amount);
        emit Minted(to, amount);
    }

    /**
     * @dev Burn tokens (anyone can burn their own tokens).
     * @param amount Amount to burn.
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}