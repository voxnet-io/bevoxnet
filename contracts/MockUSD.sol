// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockUSDC is ERC20, Ownable {
    uint8 private _decimals;

    constructor() ERC20("USD Coin", "USDC") Ownable(msg.sender) {
        _decimals = 6; // USDC has 6 decimals

        // Mint initial supply to deployer (1 million USDC)
        _mint(msg.sender, 1_000_000 * 10 ** _decimals);
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    // Mint function for testing (only owner can mint)
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    // Faucet function - anyone can get 1000 USDC for testing
    function faucet() external {
        require(balanceOf(msg.sender) < 10000 * 10 ** _decimals, "Already have enough USDC");
        _mint(msg.sender, 1000 * 10 ** _decimals); // Mint 1000 USDC
    }

    // Batch mint for testing multiple accounts
    function batchMint(address[] calldata recipients, uint256 amount) external onlyOwner {
        for (uint256 i = 0; i < recipients.length; i++) {
            _mint(recipients[i], amount);
        }
    }
}
