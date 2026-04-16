// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract AMMOracle {
    uint256 public reserve0;
    uint256 public reserve1;

    event Swapped0For1(
        uint256 amount0In,
        uint256 newReserve0,
        uint256 newReserve1
    );
    event Swapped1For0(
        uint256 amount1In,
        uint256 newReserve0,
        uint256 newReserve1
    );

    constructor(uint256 _r0, uint256 _r1) {
        require(_r0 > 0 && _r1 > 0, "Invalid reserves");
        reserve0 = _r0;
        reserve1 = _r1;
    }

    function getLatestPrice() external view returns (uint256) {
        require(reserve0 > 0, "Invalid reserve0");
        return (reserve1 * 1e18) / reserve0;
    }

    function swap0For1(uint256 amount0In) external {
        require(amount0In > 0, "Zero amount");
        uint256 k = reserve0 * reserve1;
        reserve0 += amount0In;
        reserve1 = k / reserve0;
        emit Swapped0For1(amount0In, reserve0, reserve1);
    }

    function swap1For0(uint256 amount1In) external {
        require(amount1In > 0, "Zero amount");
        uint256 k = reserve0 * reserve1;
        reserve1 += amount1In;
        reserve0 = k / reserve1;
        require(reserve0 > 0, "Reserve underflow");
        emit Swapped1For0(amount1In, reserve0, reserve1);
    }
}
