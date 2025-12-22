// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../src/FlashVerseToken.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

contract FlashBorrower is IERC3156FlashBorrower {
    FlashVerseToken public token;

    constructor(address payable _token) {
        token = FlashVerseToken(payable(_token));
    }

    // Execute a normal flash loan
    function executeFlashLoan(uint256 amount) external {
        token.flashLoan(this, address(token), amount, "");
    }

    // Execute flash loan but fail to repay (for testing failure)
    function executeFlashLoanWithFailure(uint256 amount) external {
        token.flashLoan(this, address(token), amount, "fail"); 
    }

    function onFlashLoan(
        address initiator,
        address tokenAddress,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32) {
        require(msg.sender == address(token), "Only token can call");

        // If data is "fail", do not repay
        if (keccak256(data) == keccak256("fail")) {
            return bytes32(0);
        }

        // Normal repayment: amount + fee
        FlashVerseToken(payable(tokenAddress)).transfer(address(token), amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}