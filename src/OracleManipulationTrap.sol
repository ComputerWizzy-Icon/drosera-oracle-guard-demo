// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ITrap} from "./interfaces/ITrap.sol";

interface IOracleView {
    function getLatestPrice() external view returns (uint256);
}

interface IPoolView {
    function getTvl() external view returns (uint256);
}

contract OracleManipulationTrap is ITrap {
    error UnsupportedChain();

    uint256 internal constant SAMPLE_SIZE = 5;
    uint256 internal constant PRICE_UPPER_MULTIPLE = 5;
    uint256 internal constant PRICE_LOWER_DIVISOR = 5;
    uint256 internal constant TVL_DROP_PCT = 10;

    address public immutable ORACLE;
    address public immutable POOL;

    struct CollectOutput {
        address pool;
        address oracle;
        uint256 price;
        uint256 tvl;
        uint256 blockNumber;
    }

    constructor() {
        if (block.chainid == 560048) {
            ORACLE = 0x217970434FD0108F4E9408B6A093e24Ba514CEAA;
            POOL = 0xa1CE89AB420d0ceeC587F713a798190e547FA5cE;
        } else {
            revert UnsupportedChain();
        }
    }

    function collect() external view returns (bytes memory) {
        return
            abi.encode(
                CollectOutput({
                    pool: POOL,
                    oracle: ORACLE,
                    price: IOracleView(ORACLE).getLatestPrice(),
                    tvl: IPoolView(POOL).getTvl(),
                    blockNumber: block.number
                })
            );
    }

    function shouldRespond(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {
        if (data.length != SAMPLE_SIZE) return (false, bytes(""));

        CollectOutput memory current = abi.decode(data[0], (CollectOutput));

        if (
            current.pool == address(0) ||
            current.oracle == address(0) ||
            current.price == 0 ||
            current.tvl == 0 ||
            current.blockNumber == 0
        ) return (false, bytes(""));

        for (uint256 i = 0; i < data.length; i++) {
            CollectOutput memory sample = abi.decode(data[i], (CollectOutput));

            if (sample.pool != current.pool || sample.oracle != current.oracle)
                return (false, bytes(""));

            if (sample.price == 0 || sample.tvl == 0 || sample.blockNumber == 0)
                return (false, bytes(""));

            if (i > 0) {
                CollectOutput memory prev = abi.decode(
                    data[i - 1],
                    (CollectOutput)
                );
                if (prev.blockNumber != sample.blockNumber + 1)
                    return (false, bytes(""));
            }
        }

        uint256 baselinePrice = 0;
        uint256 baselineTvl = 0;
        uint256 historyCount = data.length - 1;

        for (uint256 i = 1; i < data.length; i++) {
            CollectOutput memory sample = abi.decode(data[i], (CollectOutput));
            baselinePrice += sample.price;
            baselineTvl += sample.tvl;
        }

        if (baselineTvl == 0) return (false, bytes(""));

        baselinePrice /= historyCount;
        baselineTvl /= historyCount;

        bool spike = current.price > baselinePrice * PRICE_UPPER_MULTIPLE;
        bool crash = current.price < baselinePrice / PRICE_LOWER_DIVISOR;

        bool tvlStressed = false;
        if (current.tvl < baselineTvl) {
            uint256 dropPct = ((baselineTvl - current.tvl) * 100) / baselineTvl;
            tvlStressed = dropPct > TVL_DROP_PCT;
        }

        if ((spike || crash) && tvlStressed) {
            return (true, abi.encode(current.pool));
        }

        return (false, bytes(""));
    }
}
