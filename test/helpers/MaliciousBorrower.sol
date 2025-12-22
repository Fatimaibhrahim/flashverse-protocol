// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../src/FlashVerseToken.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

contract MaliciousBorrower is IERC3156FlashBorrower {
    FlashVerseToken public token;

    constructor(address payable _token) {
        token = FlashVerseToken(payable(_token));
    }

    // Attempt to steal funds or misbehave
    function executeMalicious(uint256 amount) external {
        token.flashLoan(this, address(token), amount, "malicious");
    }

    function onFlashLoan(
        address,
        address tokenAddress,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32) {
        require(msg.sender == address(token), "Only token can call");

        if (keccak256(data) == keccak256("malicious")) {
            // Do not repay or try to take extra tokens
            // This is meant to fail the flash loan check in the token contract
            return bytes32(0); 
        }

        // Default: repay normally
        FlashVerseToken(payable(tokenAddress)).transfer(address(token), amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}