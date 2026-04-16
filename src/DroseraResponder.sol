// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IPool {
    function emergencyPause() external;

    function paused() external view returns (bool);
}

contract DroseraResponder is Ownable {
    address public relayer;
    mapping(address => bool) public approvedPools;

    event RelayerUpdated(
        address indexed oldRelayer,
        address indexed newRelayer
    );
    event PoolApprovalUpdated(address indexed pool, bool approved);
    event ResponseExecuted(address indexed pool);

    constructor(
        address initialOwner,
        address initialRelayer,
        address initialPool
    ) Ownable(initialOwner) {
        require(initialOwner != address(0), "Zero owner");
        require(initialRelayer != address(0), "Zero relayer");
        require(initialPool != address(0), "Zero pool");

        relayer = initialRelayer;
        approvedPools[initialPool] = true;
        emit PoolApprovalUpdated(initialPool, true);
    }

    modifier onlyRelayer() {
        _onlyRelayer();
        _;
    }

    function _onlyRelayer() internal view {
        require(msg.sender == relayer, "Not relayer");
    }

    function setRelayer(address newRelayer) external onlyOwner {
        require(newRelayer != address(0), "Zero relayer");
        emit RelayerUpdated(relayer, newRelayer);
        relayer = newRelayer;
    }

    function setApprovedPool(address pool, bool approved) external onlyOwner {
        require(pool != address(0), "Zero pool");
        approvedPools[pool] = approved;
        emit PoolApprovalUpdated(pool, approved);
    }

    function executeResponse(address pool) external onlyRelayer {
        require(pool != address(0), "Zero pool");
        require(approvedPools[pool], "Pool not approved");

        if (IPool(pool).paused()) return;

        IPool(pool).emergencyPause();
        emit ResponseExecuted(pool);
    }
}
