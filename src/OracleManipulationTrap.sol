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

    uint256 internal constant SPIKE_UPPER_BPS = 50_000;
    uint256 internal constant CRASH_LOWER_BPS = 2_000;
    uint256 internal constant TVL_DROP_BPS = 1_000;

    uint256 internal constant MIN_ABNORMAL_HISTORY_COUNT = 0;

    uint256 internal constant MIN_BASELINE_PRICE = 1e12;
    uint256 internal constant MIN_BASELINE_TVL = 1 ether;

    uint256 internal constant EXTREME_SPIKE_MULT = 10;
    uint256 internal constant EXTREME_TVL_DROP_BPS = 2_500;

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
            cfg.oracle = 0x046F0FCF3eF8156F30074D46a0F79011d849F919;
            cfg.pool = 0x9965101009Ee25f1BA316CDcFEd7dC6c9559e9be;
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
        if (data.length != SAMPLE_SIZE) return (false, "");

        CollectOutput memory current = abi.decode(data[0], (CollectOutput));
        if (current.paused) return (false, "");

        uint256 priceSum;
        uint256 tvlSum;

        for (uint256 i = 1; i < data.length; i++) {
            CollectOutput memory s = abi.decode(data[i], (CollectOutput));
            CollectOutput memory prev = abi.decode(
                data[i - 1],
                (CollectOutput)
            );

            if (s.pool != current.pool || s.oracle != current.oracle) {
                return (false, "");
            }

            if (!_isStrict(prev.blockNumber, s.blockNumber)) {
                return (false, "");
            }

            priceSum += s.price;
            tvlSum += s.tvl;
        }

        uint256 baselinePrice = priceSum / (data.length - 1);
        uint256 baselineTvl = tvlSum / (data.length - 1);

        if (
            baselinePrice < MIN_BASELINE_PRICE || baselineTvl < MIN_BASELINE_TVL
        ) {
            return (false, "");
        }

        bool tvlDrop = _isTvlDrop(current.tvl, baselineTvl);
        if (!tvlDrop) return (false, "");

        bool spike = current.price >= baselinePrice * 5;
        bool crash = current.price <= baselinePrice / 5;

        // extreme trigger
        if (
            (current.price >= baselinePrice * EXTREME_SPIKE_MULT ||
                current.price <= baselinePrice / EXTREME_SPIKE_MULT) &&
            _tvlDropBps(current.tvl, baselineTvl) >= EXTREME_TVL_DROP_BPS
        ) {
            return (true, _payload(current, baselinePrice, baselineTvl, spike));
        }

        if (spike || crash) {
            return (true, _payload(current, baselinePrice, baselineTvl, spike));
        }

        return (false, "");
    }

    function _payload(
        CollectOutput memory c,
        uint256 bp,
        uint256 bt,
        bool spike
    ) internal pure returns (bytes memory) {
        return
            abi.encode(
                ResponsePayload({
                    pool: c.pool,
                    reason: spike
                        ? Reason.PriceSpikeAndTvlDrop
                        : Reason.PriceCrashAndTvlDrop,
                    currentPrice: c.price,
                    baselinePrice: bp,
                    currentTvl: c.tvl,
                    baselineTvl: bt,
                    currentBlockNumber: c.blockNumber
                })
            );
    }

    function _isStrict(
        uint256 newer,
        uint256 older
    ) internal pure returns (bool) {
        return newer > older && newer - older == 1;
    }

    function _tvlDropBps(uint256 c, uint256 b) internal pure returns (uint256) {
        if (c >= b) return 0;
        return ((b - c) * BPS_DENOMINATOR) / b;
    }

    function _isTvlDrop(uint256 c, uint256 b) internal pure returns (bool) {
        return _tvlDropBps(c, b) >= TVL_DROP_BPS;
    }
}
