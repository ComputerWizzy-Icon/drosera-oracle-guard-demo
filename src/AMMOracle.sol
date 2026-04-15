// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract AMMOracle {
    uint256 private price;

    constructor(uint256 _initialPrice) {
        price = _initialPrice;
    }

    function getLatestPrice() external view returns (uint256) {
        return price;
    }

    // Simulates an attacker manipulating the AMM reserves to spike the price
    function manipulatePrice(uint256 _newPrice) external {
        price = _newPrice;
    }
}
