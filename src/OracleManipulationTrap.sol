// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITrap} from "./interfaces/ITrap.sol";

interface IOracleView {
    function getLatestPrice()
        external
        view
        returns (uint256 price, uint256 updatedAt);
}

interface IPoolView {
    function getTvl() external view returns (uint256);

    function paused() external view returns (bool);
}

contract OracleManipulationTrap is ITrap {
    error UnsupportedChain();

    uint8 internal constant SCHEMA_VERSION = 1;
    uint256 internal constant SAMPLE_SIZE = 5;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant TVL_DROP_BPS = 1_000;
    uint256 internal constant PRICE_SPIKE_MULT = 5;
    uint256 internal constant PRICE_CRASH_DIV = 5;
    uint256 internal constant EXTREME_PRICE_MULT = 10;
    uint256 internal constant EXTREME_TVL_DROP_BPS = 2_500;
    uint256 internal constant MIN_BASELINE_PRICE = 1e12;
    uint256 internal constant MIN_BASELINE_TVL = 1 ether;
    uint256 internal constant MAX_ORACLE_STALENESS = 1 hours;
    uint256 internal constant MIN_ENCODED_COLLECT_SIZE = 12 * 32;

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
        uint8 schemaVersion;
        address pool;
        address oracle;
        uint256 price;
        uint256 oracleUpdatedAt;
        uint256 tvl;
        bool paused;
        uint256 blockNumber;
        uint256 blockTimestamp;
        bool oracleReadOk;
        bool tvlReadOk;
        bool pausedReadOk;
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
            cfg.oracle = 0x1836A3Ef74CaD2e4089917EDE462ec056e1B2ddC;
            cfg.pool = 0x71dC74681c14FB5943790a2b11A4167EEAf42040;
            return cfg;
        }

        revert UnsupportedChain();
    }

    function collect() external view virtual override returns (bytes memory) {
        return _collectFrom(ORACLE, POOL);
    }

    function shouldRespond(
        bytes[] calldata data
    ) external pure override returns (bool, bytes memory) {
        if (data.length != SAMPLE_SIZE) return (false, bytes(""));

        for (uint256 i = 0; i < data.length; i++) {
            if (data[i].length < MIN_ENCODED_COLLECT_SIZE) {
                return (false, bytes(""));
            }
        }

        CollectOutput memory current = abi.decode(data[0], (CollectOutput));

        if (!_validSample(current)) return (false, bytes(""));
        if (current.paused) return (false, bytes(""));

        uint256 priceSum;
        uint256 tvlSum;

        for (uint256 i = 1; i < data.length; i++) {
            CollectOutput memory sample = abi.decode(data[i], (CollectOutput));
            CollectOutput memory prev = abi.decode(
                data[i - 1],
                (CollectOutput)
            );

            if (!_validSample(sample)) return (false, bytes(""));
            if (sample.pool != current.pool || sample.oracle != current.oracle)
                return (false, bytes(""));
            if (!_isStrict(prev.blockNumber, sample.blockNumber))
                return (false, bytes(""));
            if (_isStale(sample.oracleUpdatedAt, sample.blockTimestamp))
                return (false, bytes(""));

            priceSum += sample.price;
            tvlSum += sample.tvl;
        }

        if (_isStale(current.oracleUpdatedAt, current.blockTimestamp)) {
            return (false, bytes(""));
        }

        uint256 baselinePrice = priceSum / (data.length - 1);
        uint256 baselineTvl = tvlSum / (data.length - 1);

        if (
            baselinePrice < MIN_BASELINE_PRICE || baselineTvl < MIN_BASELINE_TVL
        ) {
            return (false, bytes(""));
        }

        if (!_isTvlDrop(current.tvl, baselineTvl)) return (false, bytes(""));

        bool spike = current.price >= baselinePrice * PRICE_SPIKE_MULT;
        bool crash = current.price <= baselinePrice / PRICE_CRASH_DIV;
        bool extremePriceMove = current.price >=
            baselinePrice * EXTREME_PRICE_MULT ||
            current.price <= baselinePrice / EXTREME_PRICE_MULT;
        bool extremeTvlDrop = _tvlDropBps(current.tvl, baselineTvl) >=
            EXTREME_TVL_DROP_BPS;

        if (extremePriceMove && extremeTvlDrop) {
            return (true, _payload(current, baselinePrice, baselineTvl, spike));
        }

        if (spike || crash) {
            return (true, _payload(current, baselinePrice, baselineTvl, spike));
        }

        return (false, bytes(""));
    }

    function _collectFrom(
        address oracle_,
        address pool_
    ) internal view returns (bytes memory) {
        uint256 price;
        uint256 oracleUpdatedAt;
        uint256 tvl;
        bool isPaused;
        bool oracleReadOk;
        bool tvlReadOk;
        bool pausedReadOk;

        try IOracleView(oracle_).getLatestPrice() returns (
            uint256 p,
            uint256 updatedAt
        ) {
            price = p;
            oracleUpdatedAt = updatedAt;
            oracleReadOk = true;
        } catch {
            oracleReadOk = false;
        }

        try IPoolView(pool_).getTvl() returns (uint256 value) {
            tvl = value;
            tvlReadOk = true;
        } catch {
            tvlReadOk = false;
        }

        try IPoolView(pool_).paused() returns (bool p) {
            isPaused = p;
            pausedReadOk = true;
        } catch {
            pausedReadOk = false;
        }

        return
            abi.encode(
                CollectOutput({
                    schemaVersion: SCHEMA_VERSION,
                    pool: pool_,
                    oracle: oracle_,
                    price: price,
                    oracleUpdatedAt: oracleUpdatedAt,
                    tvl: tvl,
                    paused: isPaused,
                    blockNumber: block.number,
                    blockTimestamp: block.timestamp,
                    oracleReadOk: oracleReadOk,
                    tvlReadOk: tvlReadOk,
                    pausedReadOk: pausedReadOk
                })
            );
    }

    function _validSample(
        CollectOutput memory sample
    ) internal pure returns (bool) {
        if (sample.schemaVersion != SCHEMA_VERSION) return false;
        if (sample.pool == address(0) || sample.oracle == address(0))
            return false;
        if (!sample.oracleReadOk || !sample.tvlReadOk || !sample.pausedReadOk)
            return false;
        if (sample.price == 0) return false;
        return true;
    }

    function _isStale(
        uint256 oracleUpdatedAt,
        uint256 sampleTimestamp
    ) internal pure returns (bool) {
        if (oracleUpdatedAt == 0 || sampleTimestamp == 0) return true;
        return sampleTimestamp > oracleUpdatedAt + MAX_ORACLE_STALENESS;
    }

    function _payload(
        CollectOutput memory current,
        uint256 baselinePrice,
        uint256 baselineTvl,
        bool spike
    ) internal pure returns (bytes memory) {
        return
            abi.encode(
                ResponsePayload({
                    pool: current.pool,
                    reason: spike
                        ? Reason.PriceSpikeAndTvlDrop
                        : Reason.PriceCrashAndTvlDrop,
                    currentPrice: current.price,
                    baselinePrice: baselinePrice,
                    currentTvl: current.tvl,
                    baselineTvl: baselineTvl,
                    currentBlockNumber: current.blockNumber
                })
            );
    }

    function _isStrict(
        uint256 newer,
        uint256 older
    ) internal pure returns (bool) {
        return newer > older && newer - older == 1;
    }

    function _tvlDropBps(
        uint256 current,
        uint256 baseline
    ) internal pure returns (uint256) {
        if (baseline == 0 || current >= baseline) return 0;
        return ((baseline - current) * BPS_DENOMINATOR) / baseline;
    }

    function _isTvlDrop(
        uint256 current,
        uint256 baseline
    ) internal pure returns (bool) {
        return _tvlDropBps(current, baseline) >= TVL_DROP_BPS;
    }
}
