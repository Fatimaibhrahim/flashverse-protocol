// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../src/FlashVerseToken.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

contract ReentrantBorrower is IERC3156FlashBorrower {
    FlashVerseToken public token;
    bool private attackInProgress;

    constructor(address payable _token) {
        token = FlashVerseToken(payable(_token));
    }

    function attack(uint256 amount) external {
        token.flashLoan(this, address(token), amount, "");
    }

    function onFlashLoan(
        address initiator,
        address tokenAddress,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external returns (bytes32) {
        if (!attackInProgress) {
            attackInProgress = true;
            // Attempt reentrancy
            token.flashLoan(this, tokenAddress, amount, "");
        }

        // Repay normally after attack
        FlashVerseToken(payable(tokenAddress)).transfer(address(token), amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}