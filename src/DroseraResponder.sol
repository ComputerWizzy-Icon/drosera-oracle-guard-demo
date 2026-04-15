// src/DroseraResponder.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPool {
    function emergencyPause() external;
}

contract DroseraResponder {
    address public immutable relayer;

    event ResponseExecuted(address indexed pool);

    constructor(address _relayer) {
        require(_relayer != address(0), "Zero relayer");
        relayer = _relayer;
    }

    function executeResponse(address pool) external {
        require(msg.sender == relayer, "Not relayer");
        require(pool != address(0), "Zero pool");

        IPool(pool).emergencyPause();
        emit ResponseExecuted(pool);
    }
}
