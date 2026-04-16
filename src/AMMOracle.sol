// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract AMMOracle {
    uint256 public reserve0;
    uint256 public reserve1;

    constructor(uint256 _r0, uint256 _r1) {
        reserve0 = _r0;
        reserve1 = _r1;
    }

    function getLatestPrice() external view returns (uint256) {
        require(reserve0 > 0, "Invalid reserve");
        return (reserve1 * 1e18) / reserve0;
    }

    // Simulate AMM manipulation
    function swap(uint256 amount0In) external {
        require(amount0In > 0, "Zero swap");

        uint256 k = reserve0 * reserve1;

        reserve0 += amount0In;
        reserve1 = k / reserve0;
    }
}
