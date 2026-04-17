// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {AMMOracle} from "../src/AMMOracle.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {DroseraResponder} from "../src/DroseraResponder.sol";
import {OracleManipulationTrap} from "../src/OracleManipulationTrap.sol";

contract AttackSimulation is Test {
    AMMOracle oracle;
    LendingPool pool;
    OracleManipulationTrap trap;
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
        bool paused;
        uint256 blockNumber;
    }

    function setUp() public {
        vm.chainId(560048);

        vm.startPrank(owner);

        oracle = new AMMOracle(1000 ether, 1000 ether);
        pool = new LendingPool(owner, address(oracle));
        responder = new DroseraResponder(owner, relayer, address(pool));

        pool.setResponder(address(responder));

        vm.deal(owner, 200 ether);
        pool.fundLiquidity{value: 100 ether}();

        vm.stopPrank();

        trap = new OracleManipulationTrap();

        vm.deal(attacker, 50 ether);
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
                    paused: pool.paused(),
                    blockNumber: blk
                })
            );
    }

    /**
     * CORE TEST: Spike + TVL drop detection
     * Tests the primary trap logic: price manipulation + liquidity drain
     */
    function test_spike_and_tvl_drop_triggers_trap() public {
        // Build normal baseline over 4 blocks
        uint256 basePrice = 1e18;
        uint256 baseTvl = 100 ether;

        buffer[4] = _sample(basePrice, baseTvl, 100);
        buffer[3] = _sample(basePrice, baseTvl, 101);
        buffer[2] = _sample(basePrice, baseTvl, 102);
        buffer[1] = _sample(basePrice, baseTvl, 103);

        vm.roll(104);
        vm.startPrank(attacker);

        // Attack: massive price spike + TVL drain
        oracle.swap1For0(4000 ether);
        pool.depositCollateral{value: 5 ether}();
        pool.borrow(50 ether);

        vm.stopPrank();

        uint256 attackPrice = oracle.getLatestPrice();
        uint256 attackTvl = pool.getTvl();
        buffer[0] = _sample(attackPrice, attackTvl, 104);

        // Verify preconditions
        assertTrue(attackPrice >= basePrice * 5, "price should spike 5x+");
        assertTrue(attackTvl < (baseTvl * 9) / 10, "TVL should drop >10%");

        (bool trigger, bytes memory payload) = trap.shouldRespond(buffer);
        assertTrue(trigger, "trap should fire on spike + tvl drop");

        // Execute response
        OracleManipulationTrap.ResponsePayload memory resp = abi.decode(
            payload,
            (OracleManipulationTrap.ResponsePayload)
        );
        assertEq(resp.pool, address(pool));
        assertEq(
            uint256(resp.reason),
            uint256(OracleManipulationTrap.Reason.PriceSpikeAndTvlDrop)
        );

        vm.prank(relayer);
        responder.executeResponse(payload);

        assertTrue(pool.paused(), "pool should be paused");

        // Idempotence check
        vm.prank(relayer);
        responder.executeResponse(payload);
        assertTrue(pool.paused(), "pool should remain paused");
    }

    function test_no_false_positive_on_normal_operation() public {
        uint256 normalPrice = 1e18;
        uint256 normalTvl = 100 ether;

        for (uint256 i = 0; i < 5; i++) {
            buffer[4 - i] = _sample(normalPrice, normalTvl, 100 + i);
        }

        vm.roll(105);

        (bool trigger, ) = trap.shouldRespond(buffer);
        assertFalse(trigger, "trap should not fire on normal operation");
    }

    function test_no_false_positive_on_price_spike_alone() public {
        uint256 normalPrice = 1e18;
        uint256 normalTvl = 100 ether;

        buffer[4] = _sample(normalPrice, normalTvl, 100);
        buffer[3] = _sample(normalPrice, normalTvl, 101);
        buffer[2] = _sample(normalPrice, normalTvl, 102);
        buffer[1] = _sample(normalPrice, normalTvl, 103);

        vm.roll(104);

        // Price spike but TVL stays the same
        oracle.swap1For0(500 ether);
        buffer[0] = _sample(oracle.getLatestPrice(), normalTvl, 104);

        (bool trigger, ) = trap.shouldRespond(buffer);
        assertFalse(
            trigger,
            "trap should not fire on price spike alone (TVL must also drop)"
        );
    }

    function test_full_drain_caught() public {
        uint256 basePrice = 1e18;
        uint256 baseTvl = 100 ether;

        // Normal history
        buffer[4] = _sample(basePrice, baseTvl, 100);
        buffer[3] = _sample(basePrice, baseTvl, 101);
        buffer[2] = _sample(basePrice, baseTvl, 102);
        buffer[1] = _sample(basePrice, baseTvl, 103);

        vm.roll(104);

        // Price crash: use swap0For1 to decrease price
        // swap0For1 increases reserve0, decreases reserve1
        // price = reserve1 / reserve0, so price goes DOWN
        oracle.swap0For1(9000 ether);
        uint256 crashPrice = oracle.getLatestPrice();

        buffer[0] = _sample(crashPrice, 0, 104);

        // Verify crash: price <= baseline / 5
        assertTrue(
            crashPrice * 5 <= basePrice,
            "price should crash to <= 20% of baseline"
        );

        (bool trigger, bytes memory payload) = trap.shouldRespond(buffer);
        assertTrue(
            trigger,
            "trap should fire: price crash + full drain (TVL=0 allowed)"
        );

        OracleManipulationTrap.ResponsePayload memory resp = abi.decode(
            payload,
            (OracleManipulationTrap.ResponsePayload)
        );
        assertEq(
            uint256(resp.reason),
            uint256(OracleManipulationTrap.Reason.PriceCrashAndTvlDrop),
            "reason should be crash"
        );
        assertEq(resp.currentTvl, 0, "should record zero TVL");
    }

    function test_no_tvl_drop_means_no_trigger() public {
        uint256 basePrice = 1e18;
        uint256 baseTvl = 100 ether;

        buffer[4] = _sample(basePrice, baseTvl, 100);
        buffer[3] = _sample(basePrice, baseTvl, 101);
        buffer[2] = _sample(basePrice, baseTvl, 102);
        buffer[1] = _sample(basePrice, baseTvl, 103);

        vm.roll(104);

        // Massive price spike but TVL stays same
        oracle.swap1For0(5000 ether);
        buffer[0] = _sample(oracle.getLatestPrice(), baseTvl, 104);

        (bool trigger, ) = trap.shouldRespond(buffer);
        assertFalse(
            trigger,
            "trap should NOT fire: spike requires TVL drop as proof of attack"
        );
    }

    function test_tvl_drop_alone_without_price_anomaly() public {
        uint256 basePrice = 1e18;
        uint256 baseTvl = 100 ether;

        buffer[4] = _sample(basePrice, baseTvl, 100);
        buffer[3] = _sample(basePrice, baseTvl, 101);
        buffer[2] = _sample(basePrice, baseTvl, 102);
        buffer[1] = _sample(basePrice, baseTvl, 103);

        vm.roll(104);

        // TVL drops but price stays normal
        uint256 drainedTvl = (baseTvl * 85) / 100; // 15% drain
        buffer[0] = _sample(basePrice, drainedTvl, 104);

        (bool trigger, ) = trap.shouldRespond(buffer);
        assertFalse(
            trigger,
            "trap should NOT fire: TVL drop alone without price anomaly"
        );
    }
}
