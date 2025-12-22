// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/UniversalAirdropDistributor.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

///////////////////////////////////////////////////////////////
// MOCK TOKENS
///////////////////////////////////////////////////////////////

contract MockERC20 is ERC20 {
    constructor() ERC20("MockERC20", "M20") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

contract MockERC721 is ERC721 {
    uint256 public nextId = 1;

    constructor() ERC721("MockERC721", "M721") {}  

    function mint(address to) external returns (uint256) {  
        uint256 id = nextId++;  
        _mint(to, id);  
        return id;  
    }
}

contract MockERC1155 is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {  
        _mint(to, id, amount, "");  
    }
}

///////////////////////////////////////////////////////////////
// TEST SUITE
///////////////////////////////////////////////////////////////

contract UniversalAirdropDistributorTest is Test {
    UniversalAirdropDistributor distributor;

    MockERC20 erc20;  
    MockERC721 erc721;  
    MockERC1155 erc1155;  

    address owner;  
    address alice;  
    address bob;  

    function setUp() public {  
        owner = address(this);  
        alice = address(0x1);  
        bob   = address(0x2);  

        erc20 = new MockERC20();  
        erc721 = new MockERC721();  
        erc1155 = new MockERC1155();  

        distributor = new UniversalAirdropDistributor(  
            owner,  
            address(erc20),  
            UniversalAirdropDistributor.TokenType.ERC20  
        );  

        // Approvals  
        erc20.approve(address(distributor), type(uint256).max);  
        erc721.setApprovalForAll(address(distributor), true);  
        erc1155.setApprovalForAll(address(distributor), true);  
    }  

    /*//////////////////////////////////////////////////////////////  
                            ERC20  
    //////////////////////////////////////////////////////////////*/  

    function testERC20AirdropSingle() public {  
        distributor.airdrop(  
            address(erc20),  
            UniversalAirdropDistributor.TokenType.ERC20,  
            alice,  
            1_000 ether,  
            0  
        );  

        assertEq(erc20.balanceOf(alice), 1_000 ether);  
    }  

    function testERC20BatchAirdrop() public {  
        address[] memory recipients = new address[](2);  
        recipients[0] = alice;  
        recipients[1] = bob;  

        uint256[] memory amounts = new uint256[](2);  
        amounts[0] = 500 ether;  
        amounts[1] = 1_000 ether;  

        uint256[] memory emptyIds = new uint256[](2); 

        distributor.batchAirdrop(  
            address(erc20),  
            UniversalAirdropDistributor.TokenType.ERC20,  
            recipients,  
            amounts,  
            emptyIds  
        );  

        assertEq(erc20.balanceOf(alice), 500 ether);  
        assertEq(erc20.balanceOf(bob), 1_000 ether);  
    }  

    /*//////////////////////////////////////////////////////////////  
                            ERC721  
    //////////////////////////////////////////////////////////////*/  

    function testERC721SingleAirdrop() public {  
        uint256 tokenId = erc721.mint(owner);  

        distributor.airdrop(  
            address(erc721),  
            UniversalAirdropDistributor.TokenType.ERC721,  
            alice,  
            tokenId,  
            0  
        );  

        assertEq(erc721.ownerOf(tokenId), alice);  
    }  

    function testERC721BatchAirdrop() public {  
        uint256 id1 = erc721.mint(owner);  
        uint256 id2 = erc721.mint(owner);  

        address[] memory recipients = new address[](2);  
        recipients[0] = alice;  
        recipients[1] = bob;  

        uint256[] memory tokenIds = new uint256[](2);  
        tokenIds[0] = id1;  
        tokenIds[1] = id2;  

        distributor.batchAirdropERC721(  
            address(erc721),  
            recipients,  
            tokenIds  
        );  

        assertEq(erc721.ownerOf(id1), alice);  
        assertEq(erc721.ownerOf(id2), bob);  
    }  

    /*//////////////////////////////////////////////////////////////  
                            ERC1155  
    //////////////////////////////////////////////////////////////*/  

    function testERC1155Airdrop() public {  
        erc1155.mint(owner, 1, 100);  

        distributor.airdrop(  
            address(erc1155),  
            UniversalAirdropDistributor.TokenType.ERC1155,  
            alice,  
            10,    
            1      
        );  

        assertEq(erc1155.balanceOf(alice, 1), 10);  
    }  

    function testERC1155BatchAirdrop() public {  
        erc1155.mint(owner, 1, 100);  

        address[] memory recipients = new address[](2);  
        recipients[0] = alice;  
        recipients[1] = bob;  

        uint256[] memory amounts = new uint256[](2);  
        amounts[0] = 10;  
        amounts[1] = 20;  

        uint256[] memory tokenIds = new uint256[](2);  
        tokenIds[0] = 1;  
        tokenIds[1] = 1;  

        distributor.batchAirdrop(  
            address(erc1155),  
            UniversalAirdropDistributor.TokenType.ERC1155,  
            recipients,  
            amounts,  
            tokenIds  
        );  

        assertEq(erc1155.balanceOf(alice, 1), 10);  
        assertEq(erc1155.balanceOf(bob, 1), 20);  
    }  

    /*//////////////////////////////////////////////////////////////  
                            SECURITY  
    //////////////////////////////////////////////////////////////*/  

    function testOnlyOwnerCanAirdrop() public {  
        vm.prank(alice);  
        vm.expectRevert("Ownable: caller is not the owner");  

        distributor.airdrop(  
            address(erc20),  
            UniversalAirdropDistributor.TokenType.ERC20,  
            alice,  
            100 ether,  
            0  
        );  
    }  

    function testEmergencyWithdrawERC20() public {  
        distributor.airdrop(  
            address(erc20),  
            UniversalAirdropDistributor.TokenType.ERC20,  
            address(distributor), 
            1_000 ether,  
            0  
        );  

        uint256 ownerBefore = erc20.balanceOf(owner);  

        distributor.emergencyWithdraw(  
            address(erc20),  
            UniversalAirdropDistributor.TokenType.ERC20,  
            1_000 ether,  
            0  
        );  

        assertEq(erc20.balanceOf(owner), ownerBefore + 1_000 ether);  
    }
}