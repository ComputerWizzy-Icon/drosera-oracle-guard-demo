// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/ITrap.sol";

interface IOracleView {
    function getLatestPrice() external view returns (uint256);
}

interface IPoolView {
    function getTVL() external view returns (uint256);
}

contract OracleManipulationTrap is ITrap {
    address public immutable ORACLE;
    address public immutable POOL;

    uint256 public constant MAX_TVL_DROP_PCT = 20;

    struct CollectOutput {
        address pool;
        uint256 price;
        uint256 tvl;
        uint256 blockNumber;
    }

    constructor(address _oracle, address _pool) {
        require(_oracle != address(0), "Invalid oracle");
        require(_pool != address(0), "Invalid pool");

        ORACLE = _oracle;
        POOL = _pool;
    }

    function collect() external view returns (bytes memory) {
        return
            abi.encode(
                CollectOutput({
                    pool: POOL,
                    price: IOracleView(ORACLE).getLatestPrice(),
                    tvl: IPoolView(POOL).getTVL(),
                    blockNumber: block.number
                })
            );
    }

    function shouldRespond(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {
        if (data.length < 5) return (false, "");

        CollectOutput memory current = abi.decode(data[0], (CollectOutput));
        CollectOutput memory oldest = abi.decode(
            data[data.length - 1],
            (CollectOutput)
        );

        // ✅ validation
        for (uint i = 0; i < data.length; i++) {
            CollectOutput memory sample = abi.decode(data[i], (CollectOutput));

            if (sample.pool != current.pool) return (false, "");
            if (sample.blockNumber == 0) return (false, "");

            if (i > 0) {
                CollectOutput memory prev = abi.decode(
                    data[i - 1],
                    (CollectOutput)
                );

                if (sample.blockNumber >= prev.blockNumber) {
                    return (false, "");
                }
            }
        }

        if (oldest.price == 0 || oldest.tvl == 0) return (false, "");

        // TVL drop %
        uint256 tvlDropPct = 0;
        if (current.tvl < oldest.tvl) {
            tvlDropPct = ((oldest.tvl - current.tvl) * 100) / oldest.tvl;
        }

        // baseline price (moving average)
        uint256 baseline = 0;
        for (uint i = 1; i < data.length; i++) {
            baseline += abi.decode(data[i], (CollectOutput)).price;
        }
        baseline = baseline / (data.length - 1);

        uint256 upper = baseline * 5;
        uint256 lower = baseline / 5;

        bool spike = current.price > upper;
        bool crash = current.price < lower;

        if ((spike || crash) && tvlDropPct > 10) {
            return (true, abi.encode(current.pool));
        }

        return (false, "");
    }
}
