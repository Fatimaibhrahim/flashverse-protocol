// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockERC20
 * @dev Adjusted to handle large initial supply values and fixed decimals for DeFi testing.
 */
contract MockERC20 is ERC20, Ownable {
    uint8 private immutable _fixedDecimals;

    event Minted(address indexed to, uint256 amount);

    /**
     * @param name_ Token Name
     * @param symbol_ Token Symbol
     * @param initialSupply_ Total amount to mint during deployment (uint256)
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply_ 
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        _fixedDecimals = 18; 
        
        if (initialSupply_ > 0) {
            _mint(msg.sender, initialSupply_);
            emit Minted(msg.sender, initialSupply_);
        }
    }

    /**
     * @dev Overrides the default 18 decimals with our fixed value.
     */
    function decimals() public view virtual override returns (uint8) {
        return _fixedDecimals;
    }

    /**
     * @dev Allows the owner to mint more tokens if required by the test case.
     */
    function mint(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "ERC20: mint to the zero address");
        _mint(to, amount);
        emit Minted(to, amount);
    }

    /**
     * @dev Allows users to burn their own tokens.
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}