// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IPoolEmergency {
    function emergencyPause() external;

    function paused() external view returns (bool);
}

contract DroseraResponder is Ownable {
    enum Reason {
        Unknown,
        PriceSpikeAndTvlDrop,
        PriceCrashAndTvlDrop
    }

    struct ResponsePayload {
        address pool;
        Reason reason;
        uint256 currentPrice;
        uint256 baselinePrice;
        uint256 currentTvl;
        uint256 baselineTvl;
        uint256 currentBlockNumber;
    }

    address public relayer;
    mapping(address => bool) public approvedPools;

    event RelayerUpdated(
        address indexed oldRelayer,
        address indexed newRelayer
    );
    event PoolApprovalUpdated(address indexed pool, bool approved);
    event ResponseExecuted(
        address indexed pool,
        Reason indexed reason,
        uint256 currentPrice,
        uint256 baselinePrice,
        uint256 currentTvl,
        uint256 baselineTvl,
        uint256 currentBlockNumber
    );

    constructor(
        address initialOwner,
        address initialRelayer,
        address initialPool
    ) Ownable(initialOwner) {
        require(initialOwner != address(0), "zero owner");
        require(initialRelayer != address(0), "zero relayer");
        require(initialPool != address(0), "zero pool");

        relayer = initialRelayer;
        approvedPools[initialPool] = true;

        emit PoolApprovalUpdated(initialPool, true);
    }

    modifier onlyRelayer() {
        require(msg.sender == relayer, "not relayer");
        _;
    }

    function setRelayer(address newRelayer) external onlyOwner {
        require(newRelayer != address(0), "zero relayer");
        emit RelayerUpdated(relayer, newRelayer);
        relayer = newRelayer;
    }

    function setApprovedPool(address pool, bool approved) external onlyOwner {
        require(pool != address(0), "zero pool");
        approvedPools[pool] = approved;
        emit PoolApprovalUpdated(pool, approved);
    }

    function executeResponse(bytes calldata rawPayload) external onlyRelayer {
        ResponsePayload memory payload = abi.decode(
            rawPayload,
            (ResponsePayload)
        );

        require(payload.pool != address(0), "zero pool");
        require(approvedPools[payload.pool], "pool not approved");

        if (IPoolEmergency(payload.pool).paused()) {
            return;
        }

        IPoolEmergency(payload.pool).emergencyPause();

        emit ResponseExecuted(
            payload.pool,
            payload.reason,
            payload.currentPrice,
            payload.baselinePrice,
            payload.currentTvl,
            payload.baselineTvl,
            payload.currentBlockNumber
        );
    }
}
