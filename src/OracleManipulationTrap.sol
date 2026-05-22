// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITrap} from "./interfaces/ITrap.sol";

interface IOracleView {
    function getLatestPrice()
        external
        view
        returns (uint256 price, uint256 updatedAt);
}

interface IPoolViewV2 {
    function getRiskMetrics()
        external
        view
        returns (
            uint256 availableLiquidity,
            uint256 totalBorrowed,
            uint256 totalCollateral,
            uint256 totalBadDebt,
            uint256 utilizationBps,
            uint256 totalAssets
        );

    function paused() external view returns (bool);
}

contract OracleManipulationTrap is ITrap {
    error UnsupportedChain();

    uint256 internal constant SCHEMA_VERSION = 1;
    uint256 internal constant SAMPLE_SIZE = 5;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    uint256 internal constant LIQUIDITY_DROP_BPS = 1_000;
    uint256 internal constant PRICE_SPIKE_MULT = 5;
    uint256 internal constant PRICE_CRASH_DIV = 5;
    uint256 internal constant EXTREME_PRICE_MULT = 10;
    uint256 internal constant EXTREME_LIQUIDITY_DROP_BPS = 2_500;

    uint256 internal constant MIN_BASELINE_PRICE = 1e12;
    uint256 internal constant MIN_BASELINE_LIQUIDITY = 1 ether;
    uint256 internal constant MAX_ORACLE_STALENESS = 1 hours;

    uint256 internal constant COLLECT_OUTPUT_WORDS = 17;
    uint256 internal constant COLLECT_OUTPUT_SIZE = COLLECT_OUTPUT_WORDS * 32;

    uint256 internal constant REASON_PRICE_SPIKE_AND_LIQUIDITY_DROP = 1;
    uint256 internal constant REASON_PRICE_CRASH_AND_LIQUIDITY_DROP = 2;
    uint256 internal constant REASON_READ_FAILURE_ALERT_ONLY = 3;
    uint256 internal constant REASON_STALE_ORACLE_ALERT_ONLY = 4;

    struct TrapConfig {
        address oracle;
        address pool;
    }

    struct CollectOutput {
        uint256 schemaVersion;
        address pool;
        address oracle;
        uint256 price;
        uint256 oracleUpdatedAt;
        uint256 availableLiquidity;
        uint256 totalBorrows;
        uint256 totalCollateral;
        uint256 totalBadDebt;
        uint256 utilizationBps;
        uint256 totalAssets;
        uint256 paused;
        uint256 blockNumber;
        uint256 blockTimestamp;
        uint256 oracleReadOk;
        uint256 metricsReadOk;
        uint256 pausedReadOk;
    }

    struct ResponsePayload {
        address pool;
        uint256 reason;
        uint256 currentPrice;
        uint256 baselinePrice;
        uint256 currentLiquidity;
        uint256 baselineLiquidity;
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
            cfg.oracle = 0xBDBDA35B9A159B7E109b4CCe037201D1D055FF30;
            cfg.pool = 0x74D909FA1bFCC2152ed7A99C343249cBB05247D2;
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
        if (!_allExactSize(data)) return (false, bytes(""));

        (bool okCurrent, CollectOutput memory current) = _decodeCollect(
            data[0]
        );
        if (!okCurrent) return (false, bytes(""));

        if (!_validSample(current)) return (false, bytes(""));
        if (current.paused == 1) return (false, bytes(""));
        if (_isStale(current.oracleUpdatedAt, current.blockTimestamp)) {
            return (false, bytes(""));
        }

        uint256 priceSum;
        uint256 liquiditySum;

        for (uint256 i = 1; i < data.length; i++) {
            (bool okSample, CollectOutput memory sample) = _decodeCollect(
                data[i]
            );
            (bool okPrev, CollectOutput memory prev) = _decodeCollect(
                data[i - 1]
            );

            if (!okSample || !okPrev) return (false, bytes(""));
            if (!_validSample(sample)) return (false, bytes(""));

            if (
                sample.pool != current.pool || sample.oracle != current.oracle
            ) {
                return (false, bytes(""));
            }

            if (!_isStrict(prev.blockNumber, sample.blockNumber)) {
                return (false, bytes(""));
            }

            if (_isStale(sample.oracleUpdatedAt, sample.blockTimestamp)) {
                return (false, bytes(""));
            }

            if (priceSum > type(uint256).max - sample.price)
                return (false, bytes(""));
            if (liquiditySum > type(uint256).max - sample.availableLiquidity) {
                return (false, bytes(""));
            }

            priceSum += sample.price;
            liquiditySum += sample.availableLiquidity;
        }

        uint256 baselinePrice = priceSum / (SAMPLE_SIZE - 1);
        uint256 baselineLiquidity = liquiditySum / (SAMPLE_SIZE - 1);

        if (
            baselinePrice < MIN_BASELINE_PRICE ||
            baselineLiquidity < MIN_BASELINE_LIQUIDITY
        ) {
            return (false, bytes(""));
        }

        uint256 dropBps = _dropBps(
            current.availableLiquidity,
            baselineLiquidity
        );
        if (dropBps < LIQUIDITY_DROP_BPS) return (false, bytes(""));

        bool spike = _isAtLeastMultiple(
            current.price,
            baselinePrice,
            PRICE_SPIKE_MULT
        );

        bool crash = current.price <= baselinePrice / PRICE_CRASH_DIV;

        bool extremePriceMove = _isAtLeastMultiple(
            current.price,
            baselinePrice,
            EXTREME_PRICE_MULT
        ) || current.price <= baselinePrice / EXTREME_PRICE_MULT;

        bool extremeLiquidityDrop = dropBps >= EXTREME_LIQUIDITY_DROP_BPS;

        if (extremePriceMove && extremeLiquidityDrop) {
            return (
                true,
                _payload(
                    current,
                    baselinePrice,
                    baselineLiquidity,
                    spike
                        ? REASON_PRICE_SPIKE_AND_LIQUIDITY_DROP
                        : REASON_PRICE_CRASH_AND_LIQUIDITY_DROP
                )
            );
        }

        if (spike || crash) {
            return (
                true,
                _payload(
                    current,
                    baselinePrice,
                    baselineLiquidity,
                    spike
                        ? REASON_PRICE_SPIKE_AND_LIQUIDITY_DROP
                        : REASON_PRICE_CRASH_AND_LIQUIDITY_DROP
                )
            );
        }

        return (false, bytes(""));
    }

    function shouldAlert(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {
        if (data.length == 0 || data[0].length != COLLECT_OUTPUT_SIZE) {
            return (false, bytes(""));
        }

        (bool ok, CollectOutput memory current) = _decodeCollect(data[0]);
        if (!ok) return (false, bytes(""));

        if (
            current.oracleReadOk != 1 ||
            current.metricsReadOk != 1 ||
            current.pausedReadOk != 1
        ) {
            return (
                true,
                _payload(
                    current,
                    current.price,
                    current.availableLiquidity,
                    REASON_READ_FAILURE_ALERT_ONLY
                )
            );
        }

        if (_isStale(current.oracleUpdatedAt, current.blockTimestamp)) {
            return (
                true,
                _payload(
                    current,
                    current.price,
                    current.availableLiquidity,
                    REASON_STALE_ORACLE_ALERT_ONLY
                )
            );
        }

        return (false, bytes(""));
    }

    function _collectFrom(
        address oracle_,
        address pool_
    ) internal view returns (bytes memory) {
        uint256 price;
        uint256 oracleUpdatedAt;

        uint256 availableLiquidity;
        uint256 totalBorrowed;
        uint256 totalCollateral;
        uint256 totalBadDebt;
        uint256 utilizationBps;
        uint256 totalAssets;

        bool isPaused;

        uint256 oracleReadOk;
        uint256 metricsReadOk;
        uint256 pausedReadOk;

        try IOracleView(oracle_).getLatestPrice() returns (
            uint256 p,
            uint256 updatedAt
        ) {
            price = p;
            oracleUpdatedAt = updatedAt;
            oracleReadOk = 1;
        } catch {
            oracleReadOk = 0;
        }

        try IPoolViewV2(pool_).getRiskMetrics() returns (
            uint256 liquidity,
            uint256 borrows,
            uint256 collateral,
            uint256 badDebt,
            uint256 util,
            uint256 assets
        ) {
            availableLiquidity = liquidity;
            totalBorrowed = borrows;
            totalCollateral = collateral;
            totalBadDebt = badDebt;
            utilizationBps = util;
            totalAssets = assets;
            metricsReadOk = 1;
        } catch {
            metricsReadOk = 0;
        }

        try IPoolViewV2(pool_).paused() returns (bool p) {
            isPaused = p;
            pausedReadOk = 1;
        } catch {
            pausedReadOk = 0;
        }

        return
            abi.encode(
                CollectOutput({
                    schemaVersion: SCHEMA_VERSION,
                    pool: pool_,
                    oracle: oracle_,
                    price: price,
                    oracleUpdatedAt: oracleUpdatedAt,
                    availableLiquidity: availableLiquidity,
                    totalBorrows: totalBorrowed,
                    totalCollateral: totalCollateral,
                    totalBadDebt: totalBadDebt,
                    utilizationBps: utilizationBps,
                    totalAssets: totalAssets,
                    paused: isPaused ? uint256(1) : uint256(0),
                    blockNumber: block.number,
                    blockTimestamp: block.timestamp,
                    oracleReadOk: oracleReadOk,
                    metricsReadOk: metricsReadOk,
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
        if (sample.oracleReadOk != 1) return false;
        if (sample.metricsReadOk != 1) return false;
        if (sample.pausedReadOk != 1) return false;
        if (sample.paused > 1) return false;
        if (sample.price == 0) return false;
        return true;
    }

    function _payload(
        CollectOutput memory current,
        uint256 baselinePrice,
        uint256 baselineLiquidity,
        uint256 reason
    ) internal pure returns (bytes memory) {
        return
            abi.encode(
                ResponsePayload({
                    pool: current.pool,
                    reason: reason,
                    currentPrice: current.price,
                    baselinePrice: baselinePrice,
                    currentLiquidity: current.availableLiquidity,
                    baselineLiquidity: baselineLiquidity,
                    currentBlockNumber: current.blockNumber
                })
            );
    }

    function _allExactSize(bytes[] calldata data) internal pure returns (bool) {
        for (uint256 i = 0; i < data.length; i++) {
            if (data[i].length != COLLECT_OUTPUT_SIZE) return false;
        }
        return true;
    }

    function _decodeCollect(
        bytes calldata raw
    ) internal pure returns (bool, CollectOutput memory out) {
        if (raw.length != COLLECT_OUTPUT_SIZE) return (false, out);

        out.schemaVersion = _uintAt(raw, 0);
        out.pool = _addressAt(raw, 1);
        out.oracle = _addressAt(raw, 2);
        out.price = _uintAt(raw, 3);
        out.oracleUpdatedAt = _uintAt(raw, 4);
        out.availableLiquidity = _uintAt(raw, 5);
        out.totalBorrows = _uintAt(raw, 6);
        out.totalCollateral = _uintAt(raw, 7);
        out.totalBadDebt = _uintAt(raw, 8);
        out.utilizationBps = _uintAt(raw, 9);
        out.totalAssets = _uintAt(raw, 10);
        out.paused = _uintAt(raw, 11);
        out.blockNumber = _uintAt(raw, 12);
        out.blockTimestamp = _uintAt(raw, 13);
        out.oracleReadOk = _uintAt(raw, 14);
        out.metricsReadOk = _uintAt(raw, 15);
        out.pausedReadOk = _uintAt(raw, 16);

        return (true, out);
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

    function _isStrict(
        uint256 newer,
        uint256 older
    ) internal pure returns (bool) {
        return newer > older && newer - older == 1;
    }

    function _isStale(
        uint256 oracleUpdatedAt,
        uint256 sampleTimestamp
    ) internal pure returns (bool) {
        if (oracleUpdatedAt == 0 || sampleTimestamp == 0) return true;
        return sampleTimestamp > oracleUpdatedAt + MAX_ORACLE_STALENESS;
    }

    function _dropBps(
        uint256 current,
        uint256 baseline
    ) internal pure returns (uint256) {
        if (baseline == 0 || current >= baseline) return 0;
        return ((baseline - current) * BPS_DENOMINATOR) / baseline;
    }

    function _isAtLeastMultiple(
        uint256 value,
        uint256 baseline,
        uint256 multiple
    ) internal pure returns (bool) {
        if (baseline == 0 || multiple == 0) return false;
        return value / multiple >= baseline;
    }
}
