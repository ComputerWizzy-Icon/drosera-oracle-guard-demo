// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IPausablePool {
    function emergencyPause() external;

    function paused() external view returns (bool);
}

contract DroseraResponder is Ownable {
    uint256 public constant REASON_PRICE_SPIKE_AND_LIQUIDITY_DROP = 1;
    uint256 public constant REASON_PRICE_CRASH_AND_LIQUIDITY_DROP = 2;

    uint256 public constant RESPONSE_PAYLOAD_WORDS = 7;
    uint256 public constant RESPONSE_PAYLOAD_SIZE = RESPONSE_PAYLOAD_WORDS * 32;

    struct ResponsePayload {
        address pool;
        uint256 reason;
        uint256 currentPrice;
        uint256 baselinePrice;
        uint256 currentLiquidity;
        uint256 baselineLiquidity;
        uint256 currentBlockNumber;
    }

    address public relayer;
    uint256 public immutable COOLDOWN_BLOCKS;
    uint256 public lastResponseBlock;
    uint256 public responseCount;

    mapping(address => bool) public approvedPools;
    mapping(bytes32 => bool) public handledIncident;

    event RelayerUpdated(
        address indexed oldRelayer,
        address indexed newRelayer
    );
    event PoolApprovalUpdated(address indexed pool, bool approved);

    event ResponseExecuted(
        bytes32 indexed incidentId,
        address indexed pool,
        uint256 indexed reason,
        uint256 currentPrice,
        uint256 baselinePrice,
        uint256 currentLiquidity,
        uint256 baselineLiquidity,
        uint256 currentBlockNumber
    );

    error NotRelayer();
    error CooldownActive();
    error InvalidPayload();
    error PoolNotApproved();
    error InvalidReason();
    error PauseDidNotTakeEffect();

    modifier onlyRelayer() {
        if (msg.sender != relayer) revert NotRelayer();
        _;
    }

    constructor(
        address owner_,
        address relayer_,
        uint256 cooldownBlocks_
    ) Ownable(owner_) {
        require(owner_ != address(0), "zero owner");
        require(relayer_ != address(0), "zero relayer");

        relayer = relayer_;
        COOLDOWN_BLOCKS = cooldownBlocks_;
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
        if (rawPayload.length != RESPONSE_PAYLOAD_SIZE) {
            revert InvalidPayload();
        }

        bytes32 incidentId = keccak256(rawPayload);

        if (handledIncident[incidentId]) {
            return;
        }

        ResponsePayload memory payload = _decodePayload(rawPayload);

        if (!approvedPools[payload.pool]) revert PoolNotApproved();

        if (
            payload.reason != REASON_PRICE_SPIKE_AND_LIQUIDITY_DROP &&
            payload.reason != REASON_PRICE_CRASH_AND_LIQUIDITY_DROP
        ) {
            revert InvalidReason();
        }

        IPausablePool pool = IPausablePool(payload.pool);

        if (pool.paused()) {
            handledIncident[incidentId] = true;
            return;
        }

        if (
            lastResponseBlock != 0 &&
            block.number < lastResponseBlock + COOLDOWN_BLOCKS
        ) {
            revert CooldownActive();
        }

        handledIncident[incidentId] = true;
        lastResponseBlock = block.number;
        responseCount++;

        pool.emergencyPause();

        if (!pool.paused()) {
            revert PauseDidNotTakeEffect();
        }

        emit ResponseExecuted(
            incidentId,
            payload.pool,
            payload.reason,
            payload.currentPrice,
            payload.baselinePrice,
            payload.currentLiquidity,
            payload.baselineLiquidity,
            payload.currentBlockNumber
        );
    }

    function _decodePayload(
        bytes calldata raw
    ) internal pure returns (ResponsePayload memory payload) {
        payload.pool = _addressAt(raw, 0);
        payload.reason = _uintAt(raw, 1);
        payload.currentPrice = _uintAt(raw, 2);
        payload.baselinePrice = _uintAt(raw, 3);
        payload.currentLiquidity = _uintAt(raw, 4);
        payload.baselineLiquidity = _uintAt(raw, 5);
        payload.currentBlockNumber = _uintAt(raw, 6);

        if (payload.pool == address(0)) revert InvalidPayload();
    }

    function _wordAt(
        bytes calldata raw,
        uint256 index
    ) internal pure returns (bytes32 word) {
        assembly {
            word := calldataload(add(raw.offset, mul(index, 32)))
        }
    }

    function _uintAt(
        bytes calldata raw,
        uint256 index
    ) internal pure returns (uint256) {
        return uint256(_wordAt(raw, index));
    }

    function _addressAt(
        bytes calldata raw,
        uint256 index
    ) internal pure returns (address) {
        return address(uint160(uint256(_wordAt(raw, index))));
    }
}
