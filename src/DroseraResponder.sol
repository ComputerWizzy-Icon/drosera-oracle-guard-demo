// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IPausablePool {
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

    modifier onlyRelayer() {
        require(msg.sender == relayer, "not relayer");
        _;
    }

    constructor(address owner_, address relayer_) Ownable(owner_) {
        require(owner_ != address(0), "zero owner");
        require(relayer_ != address(0), "zero relayer");
        relayer = relayer_;
    }

    function setRelayer(address newRelayer) external onlyOwner {
        require(newRelayer != address(0), "zero relayer");

        address oldRelayer = relayer;
        relayer = newRelayer;

        emit RelayerUpdated(oldRelayer, newRelayer);
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

        require(approvedPools[payload.pool], "pool not approved");
        require(
            payload.reason == Reason.PriceSpikeAndTvlDrop ||
                payload.reason == Reason.PriceCrashAndTvlDrop,
            "invalid reason"
        );

        IPausablePool pool = IPausablePool(payload.pool);

        if (!pool.paused()) {
            pool.emergencyPause();
        }

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
