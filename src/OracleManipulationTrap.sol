// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ITrap} from "./interfaces/ITrap.sol";

interface IOracleView {
    function getLatestPrice() external view returns (uint256);
}

interface IPoolView {
    function getTvl() external view returns (uint256);

    function paused() external view returns (bool);
}

contract OracleManipulationTrap is ITrap {
    error UnsupportedChain();

    uint256 internal constant SAMPLE_SIZE = 5;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // 5x upward move = +400% over baseline => 50_000 bps of baseline price
    uint256 internal constant SPIKE_UPPER_BPS = 50_000;

    // 80% crash means current <= 20% of baseline
    uint256 internal constant CRASH_LOWER_BPS = 2_000;

    // current TVL must be more than 10% below baseline
    uint256 internal constant TVL_DROP_BPS = 1_000;

    // minimum historical samples that must also show abnormal price direction
    // to reduce one-block noise. Set to 0 for testing, 1 for production.
    uint256 internal constant MIN_ABNORMAL_HISTORY_COUNT = 1;

    // ignore tiny baseline values to avoid noisy triggers on dust systems
    uint256 internal constant MIN_BASELINE_PRICE = 1e12;
    uint256 internal constant MIN_BASELINE_TVL = 1 ether;

    enum Reason {
        Unknown,
        PriceSpikeAndTvlDrop,
        PriceCrashAndTvlDrop
    }

    struct TrapConfig {
        address oracle;
        address pool;
    }

    struct CollectOutput {
        address pool;
        address oracle;
        uint256 price;
        uint256 tvl;
        bool paused;
        uint256 blockNumber;
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

    address public immutable ORACLE;
    address public immutable POOL;

    constructor() {
        TrapConfig memory cfg = _configForChain(block.chainid);
        ORACLE = cfg.oracle;
        POOL = cfg.pool;
    }

    function _configForChain(
        uint256 chainId
    ) internal pure returns (TrapConfig memory cfg) {
        if (chainId == 560048) {
            // Hoodi Testnet — update with actual deployed addresses
            cfg.oracle = 0x264F7AaaB41513f893a924e3327E924017b57328;
            cfg.pool = 0x1BFc89dF7a3D78C36D8F57493bd5026d09DaDe31;
            return cfg;
        }

        revert UnsupportedChain();
    }

    function collect() external view returns (bytes memory) {
        return
            abi.encode(
                CollectOutput({
                    pool: POOL,
                    oracle: ORACLE,
                    price: IOracleView(ORACLE).getLatestPrice(),
                    tvl: IPoolView(POOL).getTvl(),
                    paused: IPoolView(POOL).paused(),
                    blockNumber: block.number
                })
            );
    }

    function shouldRespond(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {
        if (data.length != SAMPLE_SIZE) {
            return (false, bytes(""));
        }

        CollectOutput memory current = abi.decode(data[0], (CollectOutput));

        // structural validation only
        if (
            current.pool == address(0) ||
            current.oracle == address(0) ||
            current.blockNumber == 0
        ) {
            return (false, bytes(""));
        }

        // do not keep trying to pause an already paused pool
        if (current.paused) {
            return (false, bytes(""));
        }

        uint256 baselinePriceSum = 0;
        uint256 baselineTvlSum = 0;
        uint256 historyCount = data.length - 1;

        for (uint256 i = 0; i < data.length; i++) {
            CollectOutput memory sample = abi.decode(data[i], (CollectOutput));

            if (
                sample.pool != current.pool ||
                sample.oracle != current.oracle ||
                sample.blockNumber == 0
            ) {
                return (false, bytes(""));
            }

            if (i > 0) {
                CollectOutput memory prev = abi.decode(
                    data[i - 1],
                    (CollectOutput)
                );
                // Enforce contiguous block ordering (earlier samples in the array are newer blocks)
                if (prev.blockNumber != sample.blockNumber + 1) {
                    return (false, bytes(""));
                }

                // historical samples must be sane enough to build a baseline
                if (sample.tvl == 0) {
                    return (false, bytes(""));
                }

                baselinePriceSum += sample.price;
                baselineTvlSum += sample.tvl;
            }
        }

        uint256 baselinePrice = baselinePriceSum / historyCount;
        uint256 baselineTvl = baselineTvlSum / historyCount;

        if (
            baselineTvl < MIN_BASELINE_TVL || baselinePrice < MIN_BASELINE_PRICE
        ) {
            return (false, bytes(""));
        }

        bool spike = _isSpike(current.price, baselinePrice);
        bool crash = _isCrash(current.price, baselinePrice);
        bool tvlDropped = _isTvlDrop(current.tvl, baselineTvl);

        if (!tvlDropped) {
            return (false, bytes(""));
        }

        // Optional extra robustness:
        // require at least N historical samples to already be materially abnormal
        // in the same direction, which helps filter single-block blips.
        if (spike) {
            if (
                _abnormalHistoryCount(data, baselinePrice, true) <
                MIN_ABNORMAL_HISTORY_COUNT
            ) {
                return (false, bytes(""));
            }

            return (
                true,
                abi.encode(
                    ResponsePayload({
                        pool: current.pool,
                        reason: Reason.PriceSpikeAndTvlDrop,
                        currentPrice: current.price,
                        baselinePrice: baselinePrice,
                        currentTvl: current.tvl,
                        baselineTvl: baselineTvl,
                        currentBlockNumber: current.blockNumber
                    })
                )
            );
        }

        if (crash) {
            if (
                _abnormalHistoryCount(data, baselinePrice, false) <
                MIN_ABNORMAL_HISTORY_COUNT
            ) {
                return (false, bytes(""));
            }

            return (
                true,
                abi.encode(
                    ResponsePayload({
                        pool: current.pool,
                        reason: Reason.PriceCrashAndTvlDrop,
                        currentPrice: current.price,
                        baselinePrice: baselinePrice,
                        currentTvl: current.tvl,
                        baselineTvl: baselineTvl,
                        currentBlockNumber: current.blockNumber
                    })
                )
            );
        }

        return (false, bytes(""));
    }

    function _isSpike(
        uint256 currentPrice,
        uint256 baselinePrice
    ) internal pure returns (bool) {
        // current >= baseline * 5 => currentPrice * 10000 >= baselinePrice * 50000
        return
            currentPrice * BPS_DENOMINATOR >= baselinePrice * SPIKE_UPPER_BPS;
    }

    function _isCrash(
        uint256 currentPrice,
        uint256 baselinePrice
    ) internal pure returns (bool) {
        // current <= baseline * 20% => currentPrice * 10000 <= baselinePrice * 2000
        return
            currentPrice * BPS_DENOMINATOR <= baselinePrice * CRASH_LOWER_BPS;
    }

    function _isTvlDrop(
        uint256 currentTvl,
        uint256 baselineTvl
    ) internal pure returns (bool) {
        // allow currentTvl == 0 => full drain
        if (currentTvl >= baselineTvl) {
            return false;
        }

        uint256 dropBps = ((baselineTvl - currentTvl) * BPS_DENOMINATOR) /
            baselineTvl;
        return dropBps >= TVL_DROP_BPS;
    }

    function _abnormalHistoryCount(
        bytes[] calldata data,
        uint256 baselinePrice,
        bool upward
    ) internal pure returns (uint256 count) {
        for (uint256 i = 1; i < data.length; i++) {
            CollectOutput memory sample = abi.decode(data[i], (CollectOutput));

            if (upward) {
                // sample >= 150% of baseline
                if (sample.price * BPS_DENOMINATOR >= baselinePrice * 15_000) {
                    count++;
                }
            } else {
                // sample <= 50% of baseline
                if (sample.price * BPS_DENOMINATOR <= baselinePrice * 5_000) {
                    count++;
                }
            }
        }
    }
}
