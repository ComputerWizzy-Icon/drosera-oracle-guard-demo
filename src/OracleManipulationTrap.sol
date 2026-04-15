// src/OracleManipulationTrap.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/ITrap.sol";

interface IOracleView {
    function getLatestPrice() external view returns (uint256);
}

interface IPoolView {
    function totalValueLocked() external view returns (uint256);
}

contract OracleManipulationTrap is ITrap {
    address public immutable oracle;
    address public immutable pool;

    uint256 public constant MAX_TVL_DROP_PCT = 20;

    struct CollectOutput {
        address pool; // Added to avoid state reading in shouldRespond
        uint256 price;
        uint256 tvl;
        uint256 blockNumber;
    }

    constructor(address _oracle, address _pool) {
        oracle = _oracle;
        pool = _pool;
    }

    function collect() external view returns (bytes memory) {
        return
            abi.encode(
                CollectOutput({
                    pool: pool,
                    price: IOracleView(oracle).getLatestPrice(),
                    tvl: IPoolView(pool).totalValueLocked(),
                    blockNumber: block.number
                })
            );
    }

    function shouldRespond(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {
        // Must have at least 5 samples for the moving average bonus logic
        if (data.length < 5) return (false, bytes(""));

        CollectOutput memory current = abi.decode(data[0], (CollectOutput));
        CollectOutput memory oldest = abi.decode(
            data[data.length - 1],
            (CollectOutput)
        );

        if (oldest.price == 0 || oldest.tvl == 0) return (false, bytes(""));

        // 1. Check TVL Drop
        uint256 tvlDropPct = 0;
        if (current.tvl < oldest.tvl) {
            tvlDropPct = ((oldest.tvl - current.tvl) * 100) / oldest.tvl;
        }

        // 2. Multi-sample Price Average Calculation
        uint256 baselinePrice = 0;
        for (uint i = 1; i < data.length; i++) {
            baselinePrice += abi.decode(data[i], (CollectOutput)).price;
        }
        baselinePrice = baselinePrice / (data.length - 1);

        // 3. Trigger Logic
        if (
            current.price > (baselinePrice * 5) || tvlDropPct > MAX_TVL_DROP_PCT
        ) {
            // We return current.pool from the decoded data to remain 'pure'
            return (true, abi.encode(current.pool));
        }

        return (false, bytes(""));
    }
}
