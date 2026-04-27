// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract AMMOracle {
    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public lastUpdated;

    event Swap0For1(uint256 amount0In, uint256 amount1Out);
    event Swap1For0(uint256 amount1In, uint256 amount0Out);

    constructor(uint256 r0, uint256 r1) {
        require(r0 > 0 && r1 > 0, "invalid reserves");
        reserve0 = r0;
        reserve1 = r1;
        lastUpdated = block.timestamp;
    }

    function getLatestPrice()
        external
        view
        returns (uint256 price, uint256 updatedAt)
    {
        price = (reserve1 * 1e18) / reserve0;
        updatedAt = lastUpdated;
    }

    function swap0For1(uint256 amount0In) external {
        require(amount0In > 0, "zero input");

        uint256 newReserve0 = reserve0 + amount0In;
        uint256 k = reserve0 * reserve1;

        uint256 newReserve1 = k / newReserve0;

        uint256 amount1Out = reserve1 - newReserve1;

        reserve0 = newReserve0;
        reserve1 = newReserve1;

        lastUpdated = block.timestamp;

        emit Swap0For1(amount0In, amount1Out);
    }

    function swap1For0(uint256 amount1In) external {
        require(amount1In > 0, "zero input");

        uint256 newReserve1 = reserve1 + amount1In;
        uint256 k = reserve0 * reserve1;

        uint256 newReserve0 = k / newReserve1;

        uint256 amount0Out = reserve0 - newReserve0;

        reserve1 = newReserve1;
        reserve0 = newReserve0;

        lastUpdated = block.timestamp;

        emit Swap1For0(amount1In, amount0Out);
    }
}
