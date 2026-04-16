// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPool {
    function emergencyPause() external;

    function paused() external view returns (bool);
}

contract DroseraResponder {
    address public immutable relayer;

    mapping(address => bool) public approvedPools;

    event ResponseExecuted(address indexed pool);

    constructor(address _relayer, address _pool) {
        require(_relayer != address(0), "Zero relayer");
        relayer = _relayer;
        approvedPools[_pool] = true;
    }

    function executeResponse(address pool) external {
        require(msg.sender == relayer, "Not relayer");
        require(approvedPools[pool], "Not approved");

        if (IPool(pool).paused()) return;

        IPool(pool).emergencyPause();

        emit ResponseExecuted(pool);
    }
}
