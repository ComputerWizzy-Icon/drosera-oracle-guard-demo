// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {AMMOracle} from "../src/AMMOracle.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {DroseraResponder} from "../src/DroseraResponder.sol";

contract TestTrap {
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

    constructor(address _oracle, address _pool) {
        ORACLE = _oracle;
        POOL = _pool;
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

contract AttackSimulation is Test {
    AMMOracle oracle;
    LendingPool pool;
    TestTrap trap;
    DroseraResponder responder;

    address owner = address(1);
    address relayer = address(999);
    address attacker = address(666);

    bytes[] buffer;

    struct CollectOutput {
        address pool;
        address oracle;
        uint256 price;
        uint256 tvl;
        uint256 blockNumber;
    }

    function setUp() public {
        vm.startPrank(owner);

        oracle = new AMMOracle(1000 ether, 1000 ether);
        pool = new LendingPool(owner, address(oracle));
        responder = new DroseraResponder(owner, relayer, address(pool));

        pool.setResponder(address(responder));

        vm.deal(owner, 200 ether);
        pool.fundLiquidity{value: 100 ether}();

        vm.stopPrank();

        trap = new TestTrap(address(oracle), address(pool));

        vm.deal(attacker, 10 ether);
        buffer = new bytes[](5);
    }

    function _sample(
        uint256 price,
        uint256 tvl,
        uint256 blk
    ) internal view returns (bytes memory) {
        return
            abi.encode(
                CollectOutput({
                    pool: address(pool),
                    oracle: address(oracle),
                    price: price,
                    tvl: tvl,
                    blockNumber: blk
                })
            );
    }

    function test_attack_detected_and_stopped() public {
        uint256 normalPrice = 1e18;
        uint256 normalTvl = 100 ether;

        buffer[4] = _sample(normalPrice, normalTvl, 100);
        buffer[3] = _sample(normalPrice, normalTvl, 101);
        buffer[2] = _sample(normalPrice, normalTvl, 102);
        buffer[1] = _sample(normalPrice, normalTvl, 103);

        vm.roll(104);
        vm.startPrank(attacker);

        oracle.swap1For0(9000 ether);

        pool.depositCollateral{value: 1 ether}();
        pool.borrow(15 ether);

        vm.stopPrank();

        buffer[0] = _sample(oracle.getLatestPrice(), pool.getTvl(), 104);

        (bool trigger, bytes memory data) = trap.shouldRespond(buffer);
        assertTrue(trigger, "trap should fire: price spike + TVL drop");

        vm.prank(relayer);
        responder.executeResponse(abi.decode(data, (address)));

        assertTrue(pool.paused(), "pool should be paused after response");

        vm.prank(relayer);
        responder.executeResponse(address(pool));
        assertTrue(pool.paused(), "pool should remain paused");
    }
}
